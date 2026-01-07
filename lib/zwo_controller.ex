defmodule ZwoController do
  @moduledoc """
  High-level interface for controlling ZWO AM5 telescope mounts.

  This module provides a convenient API for common mount operations. For more
  advanced control, use `ZwoController.Mount` directly.

  ## Quick Start

      # Connect to a real mount
      {:ok, mount} = ZwoController.start_mount(port: "/dev/ttyUSB0")

      # Or use the mock for testing
      {:ok, mount} = ZwoController.start_mock()

      # Slew to coordinates (RA in decimal hours, DEC in decimal degrees)
      ZwoController.goto(mount, 12.5, 45.0)

      # Get current position
      {:ok, pos} = ZwoController.position(mount)
      IO.puts("RA: \#{pos.ra}h, DEC: \#{pos.dec}°")

      # Control tracking
      ZwoController.track(mount, :sidereal)

      # Manual motion at different speeds
      ZwoController.set_rate(mount, 5)  # Mid-speed
      ZwoController.move(mount, :north)
      Process.sleep(1000)
      ZwoController.stop(mount)

  ## Coordinate Systems

  All coordinates use:
  - **Right Ascension (RA)**: Decimal hours (0-24)
  - **Declination (DEC)**: Decimal degrees (-90 to +90)

  To convert from HMS/DMS, use `ZwoController.Coordinates`:

      ra = ZwoController.Coordinates.hms_to_ra(12, 30, 45)   # 12h 30m 45s
      dec = ZwoController.Coordinates.dms_to_dec(-23, 26, 21) # -23° 26' 21"
  """

  alias ZwoController.{Mount, Mock, Coordinates, Discovery, SatelliteTracker}

  # =============================================================================
  # STARTING THE MOUNT
  # =============================================================================

  @doc """
  Start a connection to a real ZWO AM5 mount.

  ## Options
    - `:port` - Serial port (required), e.g., "/dev/ttyUSB0", "COM3", or `:auto` for auto-discovery
    - `:baud` - Baud rate (default: 9600)
    - `:name` - Optional GenServer name for registration

  ## Examples

      # Specify port directly
      {:ok, mount} = ZwoController.start_mount(port: "/dev/ttyUSB0")

      # Auto-discover the mount
      {:ok, mount} = ZwoController.start_mount(port: :auto)

      # With registration name
      {:ok, mount} = ZwoController.start_mount(port: "COM3", name: :my_mount)
  """
  @spec start_mount(keyword()) :: GenServer.on_start() | {:error, :not_found}
  def start_mount(opts) do
    case Keyword.fetch!(opts, :port) do
      :auto ->
        case Discovery.find_mount() do
          {:ok, port} ->
            opts = Keyword.put(opts, :port, port)
            Mount.start_link(opts)

          {:error, :not_found} = error ->
            error
        end

      _port ->
        Mount.start_link(opts)
    end
  end

  @doc """
  Start a mock mount for testing without hardware.

  ## Options
    - `:name` - Optional GenServer name for registration

  ## Examples

      {:ok, mock} = ZwoController.start_mock()
      {:ok, mock} = ZwoController.start_mock(name: :test_mount)
  """
  @spec start_mock(keyword()) :: GenServer.on_start()
  def start_mock(opts \\ []) do
    Mock.start_link(opts)
  end

  # =============================================================================
  # POSITION & SLEWING
  # =============================================================================

  @doc """
  Get the current mount position.

  Returns `{:ok, %{ra: float, dec: float}}` with RA in decimal hours
  and DEC in decimal degrees.
  """
  @spec position(GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate position(mount), to: Mount, as: :get_position

  @doc """
  Get the current altitude/azimuth position of the mount.

  Returns `{:ok, %{alt: float, az: float}}` with altitude and azimuth
  in decimal degrees.

  ## Examples

      {:ok, pos} = ZwoController.altaz(mount)
      IO.puts("Altitude: \#{pos.alt}°, Azimuth: \#{pos.az}°")
  """
  @spec altaz(GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate altaz(mount), to: Mount, as: :get_altaz

  @doc """
  Slew (GoTo) to the specified coordinates.

  ## Parameters
    - `ra` - Right Ascension in decimal hours (0-24)
    - `dec` - Declination in decimal degrees (-90 to +90)

  ## Examples

      # Go to Vega (approximately)
      ZwoController.goto(mount, 18.615, 38.783)

      # Go to coordinates from HMS/DMS
      ra = ZwoController.Coordinates.hms_to_ra(18, 36, 56)
      dec = ZwoController.Coordinates.dms_to_dec(38, 47, 1)
      ZwoController.goto(mount, ra, dec)
  """
  @spec goto(GenServer.server(), number(), number()) :: :ok | {:error, term()}
  defdelegate goto(mount, ra, dec), to: Mount

  @doc """
  Sync the mount position to specified coordinates (for alignment).
  """
  @spec sync(GenServer.server(), number(), number()) :: :ok | {:error, term()}
  defdelegate sync(mount, ra, dec), to: Mount

  # =============================================================================
  # MOTION CONTROL
  # =============================================================================

  @doc """
  Start moving the mount in the specified direction.

  ## Parameters
    - `direction` - One of `:north`, `:south`, `:east`, `:west`

  Use `set_rate/2` to control the speed before calling this function.
  """
  @spec move(GenServer.server(), :north | :south | :east | :west) :: :ok | {:error, term()}
  defdelegate move(mount, direction), to: Mount

  @doc """
  Stop movement in a specific direction.
  """
  @spec stop_motion(GenServer.server(), :north | :south | :east | :west) :: :ok | {:error, term()}
  defdelegate stop_motion(mount, direction), to: Mount

  @doc """
  Emergency stop - halt all mount movement immediately.
  """
  @spec stop(GenServer.server()) :: :ok | {:error, term()}
  defdelegate stop(mount), to: Mount, as: :stop_all

  @doc """
  Set the slew/motion rate (0-9).

  - 0: Guide rate (slowest)
  - 1-3: Centering rates
  - 4-6: Find rates
  - 7-9: Max slew rates (fastest)
  """
  @spec set_rate(GenServer.server(), 0..9) :: :ok | {:error, term()}
  defdelegate set_rate(mount, rate), to: Mount, as: :set_slew_rate

  # =============================================================================
  # TRACKING
  # =============================================================================

  @doc """
  Enable tracking at the specified rate.

  ## Parameters
    - `rate` - `:sidereal`, `:lunar`, or `:solar`

  ## Examples

      ZwoController.track(mount, :sidereal)
  """
  @spec track(GenServer.server(), :sidereal | :lunar | :solar) :: :ok | {:error, term()}
  def track(mount, rate) when rate in [:sidereal, :lunar, :solar] do
    with :ok <- Mount.set_tracking_rate(mount, rate),
         :ok <- Mount.set_tracking(mount, true) do
      :ok
    end
  end

  @doc """
  Disable tracking.
  """
  @spec track_off(GenServer.server()) :: :ok | {:error, term()}
  def track_off(mount) do
    Mount.set_tracking(mount, false)
  end

  @doc """
  Get current tracking status.
  """
  @spec tracking?(GenServer.server()) :: {:ok, boolean()} | {:error, term()}
  defdelegate tracking?(mount), to: Mount, as: :get_tracking

  # =============================================================================
  # GUIDING
  # =============================================================================

  @doc """
  Send a guide pulse in the specified direction.

  ## Parameters
    - `direction` - One of `:north`, `:south`, `:east`, `:west`
    - `duration_ms` - Duration in milliseconds (0-9999)

  ## Examples

      # Guide north for 500ms
      ZwoController.guide(mount, :north, 500)
  """
  @spec guide(GenServer.server(), :north | :south | :east | :west, non_neg_integer()) ::
          :ok | {:error, term()}
  defdelegate guide(mount, direction, duration_ms), to: Mount, as: :guide_pulse

  @doc """
  Set the autoguider rate as a fraction of sidereal rate.

  ## Parameters
    - `rate` - Guide rate multiplier (0.1 to 1.0, typical: 0.5)
  """
  @spec set_guide_rate(GenServer.server(), float()) :: :ok | {:error, term()}
  defdelegate set_guide_rate(mount, rate), to: Mount

  # =============================================================================
  # HOME & PARK
  # =============================================================================

  @doc "Slew to the home position."
  @spec home(GenServer.server()) :: :ok | {:error, term()}
  defdelegate home(mount), to: Mount

  @doc "Slew to the park position."
  @spec park(GenServer.server()) :: :ok | {:error, term()}
  defdelegate park(mount), to: Mount

  @doc """
  Set the observing site location.

  ## Parameters
    - `latitude` - decimal degrees (-90 to +90, positive = North)
    - `longitude` - decimal degrees (-180 to +180 or 0 to 360)

  ## Examples

      # Geneva, Switzerland
      ZwoController.set_site(mount, 46.2044, 6.1432)
  """
  @spec set_site(GenServer.server(), number(), number()) :: :ok | {:error, term()}
  defdelegate set_site(mount, latitude, longitude), to: Mount

  @doc """
  Set the buzzer volume.

  ## Parameters
    - `volume` - 0 (off), 1 (low), or 2 (high)
  """
  @spec set_buzzer(GenServer.server(), 0..2) :: :ok | {:error, term()}
  defdelegate set_buzzer(mount, volume), to: Mount

  # =============================================================================
  # UTILITIES
  # =============================================================================

  @doc "Get mount model and firmware version."
  @spec info(GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate info(mount), to: Mount, as: :get_info

  @doc """
  Get mount status including tracking, slewing, home position, and mount type.

  ## Return Value

  Returns `{:ok, %{tracking: boolean, slewing: boolean, at_home: boolean, mount_type: atom}}`

  Mount types:
    - `:altaz` - Mount on tripod (Alt-Az configuration)
    - `:equatorial` - Mount on equatorial wedge

  Note: Mount type is determined by physical installation, not software.
  To switch between Alt-Az and Equatorial modes, you need to physically
  add/remove an equatorial wedge.

  ## Examples

      {:ok, status} = ZwoController.status(mount)
      # => %{tracking: true, slewing: false, at_home: false, mount_type: :altaz}
  """
  @spec status(GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate status(mount), to: Mount, as: :get_status

  @doc """
  Send a raw command to the mount.

  Use this for commands not exposed through the high-level API.
  See `ZwoController.Protocol` for command definitions.
  """
  @spec raw(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate raw(mount, command), to: Mount, as: :send_command

  # =============================================================================
  # DISCOVERY
  # =============================================================================

  @doc """
  List all available serial ports.

  Returns a list of `{port_name, info}` tuples.
  """
  @spec list_ports() :: [{String.t(), map()}]
  defdelegate list_ports(), to: Discovery

  @doc """
  Find a ZWO AM5 mount by probing available USB serial ports.

  Returns `{:ok, port_name}` if found.

  ## Examples

      {:ok, "/dev/cu.usbserial-1110"} = ZwoController.find_mount()
  """
  @spec find_mount(keyword()) :: {:ok, String.t()} | {:error, :not_found}
  defdelegate find_mount(opts \\ []), to: Discovery

  # =============================================================================
  # COORDINATE HELPERS (re-exported for convenience)
  # =============================================================================

  @doc """
  Convert RA from hours/minutes/seconds to decimal hours.

  ## Examples

      iex> ZwoController.ra(12, 30, 0)
      12.5
  """
  @spec ra(integer(), integer(), number()) :: float()
  defdelegate ra(hours, minutes, seconds), to: Coordinates, as: :hms_to_ra

  @doc """
  Convert DEC from degrees/minutes/seconds to decimal degrees.

  ## Examples

      iex> ZwoController.dec(-23, 30, 0)
      -23.5
  """
  @spec dec(integer(), integer(), number()) :: float()
  defdelegate dec(degrees, minutes, seconds), to: Coordinates, as: :dms_to_dec

  # =============================================================================
  # SATELLITE TRACKING
  # =============================================================================

  @doc """
  Create an observer location for satellite tracking.

  ## Parameters
    - `latitude` - Latitude in degrees (-90 to +90, positive North)
    - `longitude` - Longitude in degrees (-180 to +180, positive East)
    - `altitude_km` - Altitude above sea level in kilometers (default: 0)

  ## Example

      observer = ZwoController.observer(37.7749, -122.4194, 0.01)
  """
  @spec observer(float(), float(), float()) :: SpaceDust.State.GeodeticState.t()
  def observer(latitude, longitude, altitude_km \\ 0.0) do
    SatelliteTracker.observer(latitude, longitude, altitude_km)
  end

  @doc """
  Start tracking a satellite by NORAD ID.

  ## Options
    - `:mount` - The mount process (required)
    - `:norad_id` - NORAD catalog ID as string (required)
    - `:observer` - Observer location from `observer/3` (required)
    - `:update_interval_ms` - How often to update position (default: 500)
    - `:min_elevation` - Minimum elevation to consider visible (default: 10°)
    - `:name` - Optional GenServer name

  ## Well-Known NORAD IDs

      | Satellite              | NORAD ID |
      |------------------------|----------|
      | ISS                    | 25544    |
      | Hubble Space Telescope | 20580    |
      | GOES-16                | 41866    |

  ## Example

      observer = ZwoController.observer(37.7749, -122.4194, 0.01)
      {:ok, mount} = ZwoController.start_mount(port: :auto)
      {:ok, tracker} = ZwoController.track_satellite(
        mount: mount,
        norad_id: "25544",
        observer: observer
      )
  """
  @spec track_satellite(keyword()) :: GenServer.on_start()
  defdelegate track_satellite(opts), to: SatelliteTracker, as: :start_link

  @doc """
  Fetch the latest TLE for a satellite from Celestrak.

  ## Example

      {:ok, tle} = ZwoController.fetch_tle("25544")
      IO.puts("Tracking: \#{tle.objectName}")
  """
  @spec fetch_tle(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate fetch_tle(norad_id), to: SatelliteTracker

  @doc """
  Get the current position of a tracked satellite.

  ## Returns

      {:ok, %{
        az: 180.5,        # Azimuth in degrees
        el: 45.2,         # Elevation in degrees
        range_km: 500.0,  # Distance in kilometers
        visible: true     # Above minimum elevation
      }}
  """
  @spec satellite_position(GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate satellite_position(tracker), to: SatelliteTracker, as: :current_position

  @doc """
  Start actively tracking a satellite with the mount.

  The mount will continuously move to follow the satellite.
  """
  @spec start_satellite_tracking(GenServer.server()) :: :ok
  defdelegate start_satellite_tracking(tracker), to: SatelliteTracker, as: :start_tracking

  @doc """
  Stop satellite tracking and halt mount motion.
  """
  @spec stop_satellite_tracking(GenServer.server()) :: :ok
  defdelegate stop_satellite_tracking(tracker), to: SatelliteTracker, as: :stop_tracking

  @doc """
  Check if the tracked satellite is currently visible.
  """
  @spec satellite_visible?(GenServer.server()) :: boolean()
  defdelegate satellite_visible?(tracker), to: SatelliteTracker, as: :visible?

  @doc """
  Get the next pass information for a tracked satellite.
  """
  @spec next_satellite_pass(GenServer.server()) :: {:ok, map()} | {:error, term()}
  defdelegate next_satellite_pass(tracker), to: SatelliteTracker, as: :next_pass

  @doc """
  Compute satellite position at a specific time.

  Useful for pass prediction without starting a tracker.

  ## Example

      observer = ZwoController.observer(37.7749, -122.4194, 0.01)
      {:ok, tle} = ZwoController.fetch_tle("25544")
      {:ok, pos} = ZwoController.satellite_position_at(tle, observer, DateTime.utc_now())
  """
  @spec satellite_position_at(map(), SpaceDust.State.GeodeticState.t(), DateTime.t()) ::
    {:ok, map()} | {:error, term()}
  defdelegate satellite_position_at(tle, observer, time), to: SatelliteTracker, as: :position_at

  @doc """
  Generate pass predictions for a satellite.

  ## Options
    - `:hours` - How many hours to predict (default: 24)
    - `:step_seconds` - Time step for predictions (default: 30)
    - `:min_elevation` - Minimum elevation to consider visible (default: 10°)

  ## Example

      observer = ZwoController.observer(37.7749, -122.4194, 0.01)
      {:ok, tle} = ZwoController.fetch_tle("25544")
      passes = ZwoController.predict_satellite_passes(tle, observer, hours: 12)

      Enum.each(passes, fn pass ->
        IO.puts("Pass at \#{pass.aos}: max el \#{pass.max_elevation}°")
      end)
  """
  @spec predict_satellite_passes(map(), SpaceDust.State.GeodeticState.t(), keyword()) :: [map()]
  defdelegate predict_satellite_passes(tle, observer, opts \\ []), to: SatelliteTracker, as: :predict_passes
end
