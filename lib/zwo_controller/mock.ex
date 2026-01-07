defmodule ZwoController.Mock do
  @moduledoc """
  Mock mount for testing and development without physical hardware.

  Simulates the ZWO AM5 mount behavior including:
  - Position tracking
  - Slewing simulation
  - Tracking states

  ## Usage

      {:ok, mock} = ZwoController.Mock.start_link(name: :mock_mount)
      ZwoController.Mock.goto(mock, 12.5, 45.0)
  """

  use GenServer
  require Logger

  alias ZwoController.Coordinates

  @slew_speed_deg_per_sec 3.0
  @tracking_rate_arcsec_per_sec 15.04  # Sidereal rate

  defstruct [
    :ra,
    :dec,
    :target_ra,
    :target_dec,
    :tracking,
    :tracking_rate,
    :slewing,
    :slew_rate,
    :guide_rate,
    :latitude,
    :longitude,
    :last_update
  ]

  # =============================================================================
  # CLIENT API - Same interface as ZwoController.Mount
  # =============================================================================

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  def connect(server), do: GenServer.call(server, :connect)
  def disconnect(server), do: GenServer.call(server, :disconnect)

  def get_position(server), do: GenServer.call(server, :get_position)
  def get_position_hms(server), do: GenServer.call(server, :get_position_hms)
  def get_altaz(server), do: GenServer.call(server, :get_altaz)

  def goto(server, ra, dec), do: GenServer.call(server, {:goto, ra, dec})
  def sync(server, ra, dec), do: GenServer.call(server, {:sync, ra, dec})

  def move(server, direction), do: GenServer.call(server, {:move, direction})
  def stop_motion(server, direction), do: GenServer.call(server, {:stop_motion, direction})
  def stop_all(server), do: GenServer.call(server, :stop_all)

  def set_slew_rate(server, rate), do: GenServer.call(server, {:set_slew_rate, rate})
  def set_tracking(server, enabled), do: GenServer.call(server, {:set_tracking, enabled})
  def set_tracking_rate(server, rate), do: GenServer.call(server, {:set_tracking_rate, rate})
  def get_tracking(server), do: GenServer.call(server, :get_tracking)

  def guide_pulse(server, direction, duration_ms),
    do: GenServer.call(server, {:guide_pulse, direction, duration_ms})

  def set_guide_rate(server, rate), do: GenServer.call(server, {:set_guide_rate, rate})

  def home(server), do: GenServer.call(server, :home)
  def park(server), do: GenServer.call(server, :park)
  def set_site(server, latitude, longitude), do: GenServer.call(server, {:set_site, latitude, longitude})
  def set_buzzer(server, volume), do: GenServer.call(server, {:set_buzzer, volume})

  def get_info(server), do: GenServer.call(server, :get_info)
  def get_status(server), do: GenServer.call(server, :get_status)
  def send_command(server, command), do: GenServer.call(server, {:send_command, command})

  # =============================================================================
  # GENSERVER CALLBACKS
  # =============================================================================

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      ra: 0.0,
      dec: 0.0,
      target_ra: nil,
      target_dec: nil,
      tracking: false,
      tracking_rate: :sidereal,
      slewing: false,
      slew_rate: 5,
      guide_rate: 0.5,
      latitude: 0.0,
      longitude: 0.0,
      last_update: System.monotonic_time(:millisecond)
    }

    # Start simulation update loop
    schedule_update()
    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_position, _from, state) do
    state = update_position(state)
    {:reply, {:ok, %{ra: state.ra, dec: state.dec}}, state}
  end

  @impl true
  def handle_call(:get_position_hms, _from, state) do
    state = update_position(state)
    ra_hms = Coordinates.ra_to_hms(state.ra)
    dec_dms = Coordinates.dec_to_dms(state.dec)
    {:reply, {:ok, %{ra: ra_hms, dec: dec_dms}}, state}
  end

  @impl true
  def handle_call(:get_altaz, _from, state) do
    # Mock returns simulated alt/az values
    # In a real scenario, these would be converted from RA/DEC based on location and time
    state = update_position(state)
    # Simple mock: alt = dec + 45, az = ra * 15 (rough approximation)
    alt = max(-90.0, min(90.0, state.dec + 45.0))
    az = rem(trunc(state.ra * 15), 360) |> abs() |> Kernel.+(0.0)
    {:reply, {:ok, %{alt: alt, az: az}}, state}
  end

  @impl true
  def handle_call({:goto, ra, dec}, _from, state) do
    ra = Coordinates.normalize_ra(ra)
    dec = Coordinates.normalize_dec(dec)

    Logger.info("Mock: Slewing to RA=#{ra}h, DEC=#{dec}°")

    state = %{state | target_ra: ra, target_dec: dec, slewing: true}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:sync, ra, dec}, _from, state) do
    ra = Coordinates.normalize_ra(ra)
    dec = Coordinates.normalize_dec(dec)

    Logger.info("Mock: Synced to RA=#{ra}h, DEC=#{dec}°")

    state = %{state | ra: ra, dec: dec}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:move, direction}, _from, state) do
    Logger.info("Mock: Moving #{direction}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:stop_motion, direction}, _from, state) do
    Logger.info("Mock: Stopped #{direction}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop_all, _from, state) do
    Logger.info("Mock: Emergency stop")
    {:reply, :ok, %{state | slewing: false, target_ra: nil, target_dec: nil}}
  end

  @impl true
  def handle_call({:set_slew_rate, rate}, _from, state) do
    {:reply, :ok, %{state | slew_rate: rate}}
  end

  @impl true
  def handle_call({:set_tracking, enabled}, _from, state) do
    Logger.info("Mock: Tracking #{if enabled, do: "enabled", else: "disabled"}")
    {:reply, :ok, %{state | tracking: enabled}}
  end

  @impl true
  def handle_call({:set_tracking_rate, rate}, _from, state) do
    Logger.info("Mock: Tracking rate set to #{rate}")
    {:reply, :ok, %{state | tracking_rate: rate}}
  end

  @impl true
  def handle_call(:get_tracking, _from, state) do
    {:reply, {:ok, state.tracking}, state}
  end

  @impl true
  def handle_call({:guide_pulse, direction, duration_ms}, _from, state) do
    Logger.info("Mock: Guide pulse #{direction} for #{duration_ms}ms")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_guide_rate, rate}, _from, state) do
    {:reply, :ok, %{state | guide_rate: rate}}
  end

  @impl true
  def handle_call(:home, _from, state) do
    Logger.info("Mock: Going home")
    {:reply, :ok, %{state | target_ra: 0.0, target_dec: 90.0, slewing: true}}
  end

  @impl true
  def handle_call(:park, _from, state) do
    Logger.info("Mock: Parking")
    {:reply, :ok, %{state | target_ra: 0.0, target_dec: 0.0, slewing: true}}
  end

  @impl true
  def handle_call({:set_site, latitude, longitude}, _from, state) do
    Logger.info("Mock: Site set to lat=#{latitude}°, lon=#{longitude}°")
    {:reply, :ok, %{state | latitude: latitude, longitude: longitude}}
  end

  @impl true
  def handle_call({:set_buzzer, volume}, _from, state) do
    Logger.info("Mock: Buzzer volume set to #{volume}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    {:reply, {:ok, %{model: "ZWO AM5 (Mock)", version: "1.0-mock"}}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      tracking: state.tracking,
      slewing: state.slewing,
      at_home: state.ra == 0.0 and state.dec == 90.0,
      mount_type: :altaz  # Mock defaults to alt-az
    }
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:send_command, command}, _from, state) do
    Logger.info("Mock: Raw command #{inspect(command)}")
    {:reply, {:ok, "1#"}, state}
  end

  @impl true
  def handle_info(:update, state) do
    state = update_position(state)
    schedule_update()
    {:noreply, state}
  end

  # =============================================================================
  # PRIVATE FUNCTIONS
  # =============================================================================

  defp schedule_update do
    Process.send_after(self(), :update, 100)
  end

  defp update_position(state) do
    now = System.monotonic_time(:millisecond)
    dt = (now - state.last_update) / 1000.0  # seconds
    state = %{state | last_update: now}

    state =
      if state.slewing and state.target_ra != nil and state.target_dec != nil do
        simulate_slew(state, dt)
      else
        state
      end

    # Apply tracking if enabled
    if state.tracking and not state.slewing do
      apply_tracking(state, dt)
    else
      state
    end
  end

  defp simulate_slew(state, dt) do
    ra_diff = state.target_ra - state.ra
    dec_diff = state.target_dec - state.dec

    # Handle RA wraparound
    ra_diff =
      cond do
        ra_diff > 12 -> ra_diff - 24
        ra_diff < -12 -> ra_diff + 24
        true -> ra_diff
      end

    # Convert RA hours to degrees for speed calculation
    ra_diff_deg = ra_diff * 15

    distance = :math.sqrt(ra_diff_deg * ra_diff_deg + dec_diff * dec_diff)

    if distance < 0.01 do
      # Arrived at target
      Logger.info("Mock: Slew complete")
      %{state | ra: state.target_ra, dec: state.target_dec, slewing: false}
    else
      # Move towards target
      max_move = @slew_speed_deg_per_sec * dt
      factor = min(max_move / distance, 1.0)

      new_ra = state.ra + ra_diff * factor
      new_dec = state.dec + dec_diff * factor

      %{state | ra: Coordinates.normalize_ra(new_ra), dec: new_dec}
    end
  end

  defp apply_tracking(state, dt) do
    # Sidereal rate: 15.04 arcsec/sec = 15.04/3600 deg/sec = 15.04/(3600*15) hours/sec
    rate_hours_per_sec = @tracking_rate_arcsec_per_sec / (3600 * 15)
    new_ra = state.ra + rate_hours_per_sec * dt
    %{state | ra: Coordinates.normalize_ra(new_ra)}
  end
end
