defmodule ZwoController.SatelliteTracker do
  @moduledoc """
  Satellite tracking using TLE propagation and mount control.

  Uses the `space_dust` library to fetch TLEs from Celestrak, propagate
  satellite positions, and generate tracking commands for the ZWO mount.

  ## Example

      # Create an observer location (lat, lon, altitude_km)
      observer = ZwoController.SatelliteTracker.observer(37.7749, -122.4194, 0.01)

      # Track the ISS (NORAD ID 25544)
      {:ok, mount} = ZwoController.start_mount(port: :auto)
      {:ok, tracker} = ZwoController.SatelliteTracker.start_link(
        mount: mount,
        norad_id: "25544",
        observer: observer
      )

      # Get current satellite position
      {:ok, pos} = ZwoController.SatelliteTracker.current_position(tracker)
      # => %{az: 180.5, el: 45.2, range_km: 500.0, visible: true}

      # Start tracking (moves mount to follow satellite)
      :ok = ZwoController.SatelliteTracker.start_tracking(tracker)

      # Stop tracking
      :ok = ZwoController.SatelliteTracker.stop_tracking(tracker)

  ## Well-Known NORAD IDs

      | Satellite              | NORAD ID |
      |------------------------|----------|
      | ISS                    | 25544    |
      | Hubble Space Telescope | 20580    |
      | Starlink satellites    | Various  |
      | GOES-16                | 41866    |
      | Landsat 9              | 49260    |
  """

  use GenServer
  require Logger

  alias SpaceDust.Ingest.Celestrak
  alias SpaceDust.Utils.Tle
  alias SpaceDust.State.{TEMEState, GeodeticState, Transforms}
  alias SpaceDust.Observations
  alias SpaceDust.Observations.AzEl

  @default_update_interval_ms 500
  @default_min_elevation 10.0  # degrees

  # PID tuning constants (tuned for pulse-based control)
  # Output is pulse duration in milliseconds
  @pid_kp 80.0          # Proportional gain: ms per degree error
  @pid_ki 15.0          # Integral gain: ms per degree*second
  @pid_kd 20.0          # Derivative gain: ms per degree/second
  @pid_max_integral 5.0 # Anti-windup: max accumulated integral in degrees*seconds
  @pid_deadband 0.05    # Ignore errors smaller than this (degrees)

  # =============================================================================
  # PUBLIC API
  # =============================================================================

  @doc """
  Create an observer location for tracking calculations.

  ## Parameters
    - `latitude` - Latitude in degrees (-90 to +90, positive North)
    - `longitude` - Longitude in degrees (-180 to +180, positive East)
    - `altitude_km` - Altitude above sea level in kilometers

  ## Example

      observer = ZwoController.SatelliteTracker.observer(37.7749, -122.4194, 0.01)
  """
  @spec observer(float(), float(), float()) :: GeodeticState.t()
  def observer(latitude, longitude, altitude_km) do
    GeodeticState.new(latitude, longitude, altitude_km)
  end

  @doc """
  Start a satellite tracker process.

  ## Options
    - `:mount` - The mount process (required)
    - `:norad_id` - NORAD catalog ID as string (required)
    - `:observer` - GeodeticState for observer location (required)
    - `:update_interval_ms` - How often to update position (default: 500)
    - `:min_elevation` - Minimum elevation to consider visible (default: 10°)
    - `:name` - Optional GenServer name

  ## Example

      observer = ZwoController.SatelliteTracker.observer(37.7749, -122.4194, 0.01)
      {:ok, tracker} = ZwoController.SatelliteTracker.start_link(
        mount: mount,
        norad_id: "25544",
        observer: observer
      )
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fetch the latest TLE for a satellite by NORAD ID.

  ## Example

      {:ok, tle} = ZwoController.SatelliteTracker.fetch_tle("25544")
  """
  @spec fetch_tle(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_tle(norad_id) do
    Celestrak.pullLatestTLE(norad_id)
  end

  @doc """
  Get the current position of the tracked satellite.

  Returns azimuth, elevation, range, and visibility status.
  """
  @spec current_position(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def current_position(server) do
    GenServer.call(server, :current_position)
  end

  @doc """
  Get the current TLE being used for tracking.
  """
  @spec get_tle(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_tle(server) do
    GenServer.call(server, :get_tle)
  end

  @doc """
  Refresh the TLE from Celestrak.

  Call this periodically (e.g., every few hours) to keep predictions accurate.
  """
  @spec refresh_tle(GenServer.server()) :: :ok | {:error, term()}
  def refresh_tle(server) do
    GenServer.call(server, :refresh_tle)
  end

  @doc """
  Start actively tracking the satellite with the mount.

  The mount will continuously move to follow the satellite's predicted position.
  Tracking will only occur when the satellite is above the minimum elevation.
  """
  @spec start_tracking(GenServer.server()) :: :ok
  def start_tracking(server) do
    GenServer.call(server, :start_tracking)
  end

  @doc """
  Stop tracking and halt mount motion.
  """
  @spec stop_tracking(GenServer.server()) :: :ok
  def stop_tracking(server) do
    GenServer.call(server, :stop_tracking)
  end

  @doc """
  Get the current tracker status.

  Returns one of:
  - `:idle` - Tracker created but not actively tracking
  - `:slewing` - Performing initial GOTO to satellite position
  - `:tracking` - Actively tracking satellite with pulse corrections

  ## Example

      {:ok, status} = ZwoController.SatelliteTracker.status(tracker)
      # => :tracking
  """
  @spec status(GenServer.server()) :: {:ok, :idle | :slewing | :tracking}
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Wait for the tracker to reach the `:tracking` state.

  Useful for waiting until the initial GOTO completes before taking
  actions like capturing photos.

  ## Options
  - `timeout_ms` - Maximum time to wait (default: 60_000ms)
  - `poll_interval_ms` - How often to check status (default: 500ms)

  ## Example

      :ok = ZwoController.start_satellite_tracking(tracker)
      :ok = ZwoController.wait_for_tracking(tracker)
      # Now safe to take photos
  """
  @spec wait_for_tracking(GenServer.server(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_tracking(server, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 500)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_for_tracking_loop(server, deadline, poll_interval)
  end

  defp wait_for_tracking_loop(server, deadline, poll_interval) do
    case status(server) do
      {:ok, :tracking} ->
        :ok

      {:ok, _other} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(poll_interval)
          wait_for_tracking_loop(server, deadline, poll_interval)
        end
    end
  end

  @doc """
  Check if the satellite is currently visible (above minimum elevation).
  """
  @spec visible?(GenServer.server()) :: boolean()
  def visible?(server) do
    GenServer.call(server, :visible?)
  end

  @doc """
  Get the next pass information for the satellite.

  Returns the approximate time until the satellite rises above minimum elevation,
  or time remaining if currently visible.
  """
  @spec next_pass(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def next_pass(server) do
    GenServer.call(server, :next_pass)
  end

  @doc """
  Compute satellite position at a specific time without starting a tracker.

  Useful for pass prediction and planning.

  ## Example

      observer = ZwoController.SatelliteTracker.observer(37.7749, -122.4194, 0.01)
      {:ok, tle} = ZwoController.SatelliteTracker.fetch_tle("25544")
      {:ok, pos} = ZwoController.SatelliteTracker.position_at(tle, observer, DateTime.utc_now())
  """
  @spec position_at(map(), GeodeticState.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def position_at(tle, observer, time) do
    try do
      az_el = compute_az_el(tle, observer, time)
      {az_deg, el_deg} = AzEl.to_degrees(az_el)

      {:ok, %{
        az: az_deg,
        el: el_deg,
        range_km: az_el.range,
        epoch: time,
        visible: el_deg > 0
      }}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Generate a pass prediction for the next N hours.

  Returns a list of positions at regular intervals.

  ## Example

      observer = ZwoController.SatelliteTracker.observer(37.7749, -122.4194, 0.01)
      {:ok, tle} = ZwoController.SatelliteTracker.fetch_tle("25544")
      passes = ZwoController.SatelliteTracker.predict_passes(tle, observer, hours: 12, step_seconds: 60)
  """
  @spec predict_passes(map(), GeodeticState.t(), keyword()) :: [map()]
  def predict_passes(tle, observer, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    step_seconds = Keyword.get(opts, :step_seconds, 30)
    min_elevation = Keyword.get(opts, :min_elevation, 10.0)

    now = DateTime.utc_now()
    total_steps = div(hours * 3600, step_seconds)

    0..total_steps
    |> Enum.map(fn step ->
      time = DateTime.add(now, step * step_seconds, :second)
      case position_at(tle, observer, time) do
        {:ok, pos} -> Map.put(pos, :visible, pos.el >= min_elevation)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> find_passes(min_elevation)
  end

  # =============================================================================
  # GENSERVER CALLBACKS
  # =============================================================================

  @impl true
  def init(opts) do
    mount = Keyword.fetch!(opts, :mount)
    norad_id = Keyword.fetch!(opts, :norad_id)
    observer = Keyword.fetch!(opts, :observer)
    update_interval = Keyword.get(opts, :update_interval_ms, @default_update_interval_ms)
    min_elevation = Keyword.get(opts, :min_elevation, @default_min_elevation)

    # Trap exits so terminate/2 is called on crash
    Process.flag(:trap_exit, true)

    # Fetch TLE immediately
    case fetch_tle(norad_id) do
      {:ok, tle} ->
        Logger.info("Loaded TLE for NORAD #{norad_id} (#{tle.internationalDesignator})")

        state = %{
          mount: mount,
          norad_id: norad_id,
          observer: observer,
          tle: tle,
          update_interval: update_interval,
          min_elevation: min_elevation,
          tracking: false,
          status: :idle,
          timer_ref: nil,
          last_position: nil,
          goto_target: nil,
          # PID controller state
          pid: %{
            az_integral: 0.0,
            el_integral: 0.0,
            az_last_error: 0.0,
            el_last_error: 0.0,
            last_time: nil
          }
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:tle_fetch_failed, reason}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning("SatelliteTracker terminating: #{inspect(reason)}")
    # SAFETY: Always stop mount motion when tracker terminates
    try do
      ZwoController.stop(state.mount)
      Logger.info("Mount motion stopped")
    rescue
      _ -> :ok
    end
    :ok
  end

  @impl true
  def handle_call(:current_position, _from, state) do
    case compute_current_position(state) do
      {:ok, pos} ->
        {:reply, {:ok, pos}, %{state | last_position: pos}}
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_tle, _from, state) do
    {:reply, {:ok, state.tle}, state}
  end

  @impl true
  def handle_call(:refresh_tle, _from, state) do
    case fetch_tle(state.norad_id) do
      {:ok, tle} ->
        Logger.info("Refreshed TLE for NORAD #{state.norad_id}")
        {:reply, :ok, %{state | tle: tle}}
      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call(:start_tracking, _from, state) do
    Logger.info("Starting satellite tracking for NORAD #{state.norad_id}")

    # Cancel any existing timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Compute initial position and defer GOTO to handle_continue
    case compute_current_position(state) do
      {:ok, pos} when pos.visible ->
        # Return immediately, perform GOTO asynchronously via handle_continue
        # Status is :slewing until GOTO completes
        {:reply, :ok, %{state | tracking: true, status: :slewing, last_position: pos}, {:continue, {:initial_goto, pos}}}

      {:ok, pos} ->
        Logger.warning("Satellite not visible (El=#{Float.round(pos.el, 1)}°), starting tracking anyway...")
        timer_ref = schedule_update(state.update_interval)
        {:reply, :ok, %{state | tracking: true, status: :tracking, timer_ref: timer_ref, last_position: pos}}

      {:error, reason} ->
        Logger.error("Failed to compute initial position: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop_tracking, _from, state) do
    Logger.info("Stopping satellite tracking")

    # Cancel timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Stop mount motion
    ZwoController.stop(state.mount)

    # Reset PID state
    pid = %{az_integral: 0.0, el_integral: 0.0, az_last_error: 0.0, el_last_error: 0.0, last_time: nil}

    {:reply, :ok, %{state | tracking: false, status: :idle, timer_ref: nil, goto_target: nil, pid: pid}}
  end

  @impl true
  def handle_call(:visible?, _from, state) do
    case compute_current_position(state) do
      {:ok, pos} -> {:reply, pos.visible, state}
      _ -> {:reply, false, state}
    end
  end

  @impl true
  def handle_call(:next_pass, _from, state) do
    passes = predict_passes(state.tle, state.observer, hours: 24, min_elevation: state.min_elevation)

    case passes do
      [] -> {:reply, {:ok, %{status: :no_passes, message: "No visible passes in next 24 hours"}}, state}
      [next | _] -> {:reply, {:ok, next}, state}
    end
  end

  @impl true
  def handle_continue({:initial_goto, pos}, state) do
    Logger.info("Performing initial GOTO to satellite position: Az=#{Float.round(pos.az, 1)}° El=#{Float.round(pos.el, 1)}°")

    # Set maximum slew rate for initial positioning
    ZwoController.set_rate(state.mount, 9)
    Process.sleep(100)

    # Start non-blocking GOTO loop via handle_info
    send(self(), {:goto_step, 1})
    {:noreply, %{state | goto_target: pos}}
  end

  @impl true
  def handle_info({:goto_step, iteration}, state) when state.status == :slewing do
    # Convergence threshold in degrees
    threshold = 1.0
    # Maximum iterations to prevent infinite loops
    max_iterations = 60
    target = state.goto_target

    {:ok, current} = ZwoController.altaz(state.mount)

    # Normalize azimuth error to -180..+180 range
    az_err = target.az - current.az
    az_err = cond do
      az_err > 180 -> az_err - 360
      az_err < -180 -> az_err + 360
      true -> az_err
    end
    el_err = target.el - current.alt

    Logger.debug("[GOTO #{iteration}] Target: #{Float.round(target.az, 1)}°/#{Float.round(target.el, 1)}° | " <>
                 "Current: #{Float.round(current.az, 1)}°/#{Float.round(current.alt, 1)}° | " <>
                 "Err: #{Float.round(az_err, 2)}°/#{Float.round(el_err, 2)}°")

    cond do
      abs(az_err) < threshold and abs(el_err) < threshold ->
        # GOTO complete - transition to tracking
        {:ok, aligned_pos} = ZwoController.altaz(state.mount)
        Logger.info("Initial alignment complete! Mount: Az=#{Float.round(aligned_pos.az, 1)}° Alt=#{Float.round(aligned_pos.alt, 1)}°")
        Logger.info("Beginning pulse-based tracking...")
        timer_ref = schedule_update(state.update_interval)
        {:noreply, %{state | status: :tracking, timer_ref: timer_ref, goto_target: nil}}

      iteration >= max_iterations ->
        # Max iterations reached - transition to tracking anyway
        Logger.warning("GOTO max iterations reached, starting tracking with current position")
        timer_ref = schedule_update(state.update_interval)
        {:noreply, %{state | status: :tracking, timer_ref: timer_ref, goto_target: nil}}

      true ->
        # Continue GOTO - move both axes and schedule next iteration
        move_both_axes(state.mount, az_err, el_err, current.alt)
        Process.send_after(self(), {:goto_step, iteration + 1}, 100)
        {:noreply, state}
    end
  end

  # Ignore stale goto steps if we're no longer slewing
  @impl true
  def handle_info({:goto_step, _iteration}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:update_tracking, state) do
    state = if state.tracking do
      case compute_current_position(state) do
        {:ok, pos} ->
          # Get current mount position for safety checks and error calculation
          {:ok, mnt} = ZwoController.altaz(state.mount)

          # SAFETY CHECK: Abort if mount goes too low
          if mnt.alt < 0.0 do
            Logger.error("SAFETY ABORT: Mount altitude #{Float.round(mnt.alt, 1)}° is below horizon!")
            ZwoController.stop(state.mount)
            %{state | tracking: false, status: :idle, timer_ref: nil}
          else
            state = if pos.visible do
              # Use PID controller for tracking
              {new_pid, az_pulse, el_pulse} = compute_pid_output(state.pid, pos, mnt)
              apply_pid_pulses(state.mount, az_pulse, el_pulse, mnt.alt)
              %{state | pid: new_pid}
            else
              Logger.debug("Satellite below horizon (el=#{Float.round(pos.el, 1)}°), waiting...")
              state
            end

            # Schedule next update
            timer_ref = schedule_update(state.update_interval)
            %{state | last_position: pos, timer_ref: timer_ref}
          end

        {:error, reason} ->
          Logger.warning("Failed to compute position: #{inspect(reason)}")
          timer_ref = schedule_update(state.update_interval)
          %{state | timer_ref: timer_ref}
      end
    else
      state
    end

    {:noreply, state}
  end

  # =============================================================================
  # PRIVATE FUNCTIONS
  # =============================================================================

  defp compute_current_position(state) do
    position_at(state.tle, state.observer, DateTime.utc_now())
    |> case do
      {:ok, pos} ->
        {:ok, Map.put(pos, :visible, pos.el >= state.min_elevation)}
      error ->
        error
    end
  end

  defp compute_az_el(tle, observer, time) do
    # Propagate TLE to get position/velocity in TEME frame
    {pos, vel} = Tle.getRVatTime(tle, time)

    # Convert TEME -> ECI
    teme = TEMEState.new(time, pos, vel)
    eci = Transforms.teme_to_eci(teme)

    # Compute Az/El from observer to satellite
    Observations.compute_az_el(observer, eci)
  end

  # Compute PID output for both axes
  defp compute_pid_output(pid, sat_pos, mnt_pos) do
    now = System.monotonic_time(:millisecond)

    # Normalize azimuth error to -180..+180 range
    az_err = sat_pos.az - mnt_pos.az
    az_err = cond do
      az_err > 180 -> az_err - 360
      az_err < -180 -> az_err + 360
      true -> az_err
    end
    el_err = sat_pos.el - mnt_pos.alt

    # Calculate dt in seconds
    dt = case pid.last_time do
      nil -> 0.5  # Default to update interval on first iteration
      last -> (now - last) / 1000.0
    end

    # PID calculation for azimuth
    {az_pulse, az_integral, az_last_error} = pid_axis(
      az_err, pid.az_integral, pid.az_last_error, dt
    )

    # PID calculation for elevation
    {el_pulse, el_integral, el_last_error} = pid_axis(
      el_err, pid.el_integral, pid.el_last_error, dt
    )

    new_pid = %{
      az_integral: az_integral,
      el_integral: el_integral,
      az_last_error: az_last_error,
      el_last_error: el_last_error,
      last_time: now
    }

    Logger.debug("PID: Az err=#{Float.round(az_err, 3)}° pulse=#{round(az_pulse)}ms | " <>
                 "El err=#{Float.round(el_err, 3)}° pulse=#{round(el_pulse)}ms | " <>
                 "I_az=#{Float.round(az_integral, 2)} I_el=#{Float.round(el_integral, 2)}")

    {new_pid, az_pulse, el_pulse}
  end

  # Single axis PID calculation
  defp pid_axis(error, integral, last_error, dt) do
    # Apply deadband - ignore very small errors
    if abs(error) < @pid_deadband do
      # Within deadband, decay integral slowly
      new_integral = integral * 0.9
      {0.0, new_integral, error}
    else
      # Proportional term
      p_term = @pid_kp * error

      # Integral term with anti-windup
      new_integral = integral + (error * dt)
      new_integral = max(-@pid_max_integral, min(@pid_max_integral, new_integral))
      i_term = @pid_ki * new_integral

      # Derivative term (on error, not measurement, for simplicity)
      derivative = if dt > 0, do: (error - last_error) / dt, else: 0.0
      d_term = @pid_kd * derivative

      # Combined output (pulse duration in ms)
      output = p_term + i_term + d_term

      # Clamp output to reasonable pulse range
      output = max(-3000.0, min(3000.0, output))

      {output, new_integral, error}
    end
  end

  # Apply PID-computed pulses to both axes
  defp apply_pid_pulses(mount, az_pulse, el_pulse, current_alt) do
    # Convert signed pulse to direction + absolute duration
    # Minimum pulse threshold to avoid tiny ineffective movements
    min_pulse = 30

    az_pulse_abs = abs(round(az_pulse))
    el_pulse_abs = abs(round(el_pulse))

    # Safety: don't move down if altitude is low
    el_pulse_abs = if el_pulse < 0 and current_alt < 5.0, do: 0, else: el_pulse_abs

    # Apply minimum threshold
    az_pulse_final = if az_pulse_abs >= min_pulse, do: az_pulse_abs, else: 0
    el_pulse_final = if el_pulse_abs >= min_pulse, do: el_pulse_abs, else: 0

    # Determine directions
    az_dir = if az_pulse > 0, do: :east, else: :west
    el_dir = if el_pulse > 0, do: :north, else: :south

    # Start both axes moving simultaneously
    if az_pulse_final > 0, do: ZwoController.move(mount, az_dir)
    if el_pulse_final > 0, do: ZwoController.move(mount, el_dir)

    # Wait for the longer pulse duration
    max_pulse = max(az_pulse_final, el_pulse_final)

    if max_pulse > 0 do
      if az_pulse_final > 0 and el_pulse_final > 0 and az_pulse_final != el_pulse_final do
        shorter_pulse = min(az_pulse_final, el_pulse_final)
        Process.sleep(shorter_pulse)

        if az_pulse_final < el_pulse_final do
          ZwoController.stop_motion(mount, az_dir)
          Process.sleep(el_pulse_final - az_pulse_final)
          ZwoController.stop_motion(mount, el_dir)
        else
          ZwoController.stop_motion(mount, el_dir)
          Process.sleep(az_pulse_final - el_pulse_final)
          ZwoController.stop_motion(mount, az_dir)
        end
      else
        Process.sleep(max_pulse)
        if az_pulse_final > 0, do: ZwoController.stop_motion(mount, az_dir)
        if el_pulse_final > 0, do: ZwoController.stop_motion(mount, el_dir)
      end
    end
  end

  # Move both azimuth and altitude axes simultaneously (simple P control for GOTO)
  defp move_both_axes(mount, az_err, el_err, current_alt) do
    # Calculate pulse durations for each axis
    az_pulse = if abs(az_err) > 0.3 do
      max_pulse = if abs(az_err) > 10.0, do: 3000, else: 800
      min(round(abs(az_err) * 100), max_pulse)
    else
      0
    end

    el_pulse = if abs(el_err) > 0.3 do
      # SAFETY: prevent moving below horizon (pier collision)
      if el_err < 0 and current_alt < 5.0 do
        0
      else
        min(round(abs(el_err) * 100), 800)
      end
    else
      0
    end

    # Determine directions
    az_dir = if az_err > 0, do: :east, else: :west
    el_dir = if el_err > 0, do: :north, else: :south

    # Start both axes moving simultaneously
    if az_pulse > 0, do: ZwoController.move(mount, az_dir)
    if el_pulse > 0, do: ZwoController.move(mount, el_dir)

    # Wait for the longer pulse duration
    max_pulse = max(az_pulse, el_pulse)

    if max_pulse > 0 do
      # Stop the shorter axis first if needed
      if az_pulse > 0 and el_pulse > 0 and az_pulse != el_pulse do
        shorter_pulse = min(az_pulse, el_pulse)
        Process.sleep(shorter_pulse)

        if az_pulse < el_pulse do
          ZwoController.stop_motion(mount, az_dir)
          Process.sleep(el_pulse - az_pulse)
          ZwoController.stop_motion(mount, el_dir)
        else
          ZwoController.stop_motion(mount, el_dir)
          Process.sleep(az_pulse - el_pulse)
          ZwoController.stop_motion(mount, az_dir)
        end
      else
        # Same duration or only one axis - simple case
        Process.sleep(max_pulse)
        if az_pulse > 0, do: ZwoController.stop_motion(mount, az_dir)
        if el_pulse > 0, do: ZwoController.stop_motion(mount, el_dir)
      end
    end
  end

  defp schedule_update(interval) do
    Process.send_after(self(), :update_tracking, interval)
  end

  defp find_passes(positions, min_elevation) do
    # Group consecutive visible positions into passes
    positions
    |> Enum.chunk_by(fn pos -> pos.el >= min_elevation end)
    |> Enum.filter(fn chunk ->
      case chunk do
        [%{el: el} | _] -> el >= min_elevation
        _ -> false
      end
    end)
    |> Enum.map(fn pass_positions ->
      aos = List.first(pass_positions)
      los = List.last(pass_positions)
      max_el = Enum.max_by(pass_positions, & &1.el)

      %{
        aos: aos.epoch,           # Acquisition of signal (rise)
        los: los.epoch,           # Loss of signal (set)
        max_elevation: max_el.el,
        max_elevation_time: max_el.epoch,
        duration_seconds: DateTime.diff(los.epoch, aos.epoch),
        aos_azimuth: aos.az,
        los_azimuth: los.az
      }
    end)
  end
end
