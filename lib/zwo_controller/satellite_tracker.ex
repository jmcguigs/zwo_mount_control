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
          timer_ref: nil,
          last_position: nil
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:tle_fetch_failed, reason}}
    end
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
  def handle_call(:start_tracking, _from, state) do
    Logger.info("Starting satellite tracking for NORAD #{state.norad_id}")

    # Cancel any existing timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Start the tracking loop
    timer_ref = schedule_update(state.update_interval)

    {:reply, :ok, %{state | tracking: true, timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:stop_tracking, _from, state) do
    Logger.info("Stopping satellite tracking")

    # Cancel timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Stop mount motion
    ZwoController.stop(state.mount)

    {:reply, :ok, %{state | tracking: false, timer_ref: nil}}
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
  def handle_info(:update_tracking, state) do
    state = if state.tracking do
      case compute_current_position(state) do
        {:ok, pos} ->
          if pos.visible do
            # Move mount to satellite position
            move_to_position(state.mount, pos)
          else
            Logger.debug("Satellite below horizon (el=#{Float.round(pos.el, 1)}°), waiting...")
          end

          # Schedule next update
          timer_ref = schedule_update(state.update_interval)
          %{state | last_position: pos, timer_ref: timer_ref}

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

  defp move_to_position(mount, pos) do
    # Get current mount position
    case ZwoController.altaz(mount) do
      {:ok, current} ->
        az_error = pos.az - current.az
        el_error = pos.el - current.alt

        Logger.debug("Target: Az=#{Float.round(pos.az, 2)}° El=#{Float.round(pos.el, 2)}° | " <>
                     "Error: Az=#{Float.round(az_error, 2)}° El=#{Float.round(el_error, 2)}°")

        # Apply corrections using pulsed movement
        # This is a simple proportional controller - could be improved with PID
        apply_correction(mount, :azimuth, az_error)
        apply_correction(mount, :elevation, el_error)

      {:error, reason} ->
        Logger.warning("Failed to get mount position: #{inspect(reason)}")
    end
  end

  defp apply_correction(mount, axis, error) when abs(error) > 0.5 do
    # Determine direction and pulse duration
    {direction, pulse_ms} = case {axis, error > 0} do
      {:azimuth, true} -> {:west, min(round(abs(error) * 50), 300)}
      {:azimuth, false} -> {:east, min(round(abs(error) * 50), 300)}
      {:elevation, true} -> {:north, min(round(abs(error) * 50), 300)}
      {:elevation, false} -> {:south, min(round(abs(error) * 50), 300)}
    end

    # Apply pulse
    ZwoController.move(mount, direction)
    Process.sleep(pulse_ms)
    ZwoController.stop_motion(mount, direction)
  end

  defp apply_correction(_mount, _axis, _error), do: :ok

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
