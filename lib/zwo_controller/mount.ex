defmodule ZwoController.Mount do
  @moduledoc """
  GenServer-based controller for the ZWO AM5 telescope mount.

  Provides a high-level API for controlling the mount including:
  - GoTo/Slewing to coordinates
  - Manual motion control (NSEW)
  - Tracking control
  - Guiding pulses
  - Status queries

  ## Usage

      # Start the mount controller
      {:ok, pid} = ZwoController.Mount.start_link(port: "/dev/ttyUSB0")

      # Slew to coordinates (RA in hours, DEC in degrees)
      ZwoController.Mount.goto(pid, 12.5, 45.0)

      # Get current position
      {:ok, %{ra: ra, dec: dec}} = ZwoController.Mount.get_position(pid)

      # Set tracking
      ZwoController.Mount.set_tracking(pid, :sidereal)

      # Manual motion
      ZwoController.Mount.move(pid, :north)
      ZwoController.Mount.stop_motion(pid, :north)
  """

  use GenServer
  require Logger

  alias ZwoController.{Protocol, Coordinates}

  @default_baud 9600
  @default_timeout 5000
  @read_timeout 2000

  # =============================================================================
  # TYPE DEFINITIONS
  # =============================================================================

  @type tracking_rate :: :sidereal | :lunar | :solar
  @type direction :: :north | :south | :east | :west
  @type slew_rate :: 0..9

  @type mount_state :: %{
          port: port() | pid() | nil,
          port_name: String.t(),
          connected: boolean(),
          tracking: boolean(),
          slewing: boolean()
        }

  @type position :: %{ra: float(), dec: float()}
  @type position_hms :: %{ra: map(), dec: map()}

  # =============================================================================
  # CLIENT API
  # =============================================================================

  @doc """
  Start the mount controller.

  ## Options
    - `:port` - Serial port device path (e.g., "/dev/ttyUSB0", "COM3")
    - `:baud` - Baud rate (default: 9600)
    - `:name` - GenServer registration name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Connect to the mount. Usually called automatically on start.
  """
  @spec connect(GenServer.server()) :: :ok | {:error, term()}
  def connect(server) do
    GenServer.call(server, :connect, @default_timeout)
  end

  @doc """
  Disconnect from the mount.
  """
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server) do
    GenServer.call(server, :disconnect)
  end

  @doc """
  Get the current mount position in decimal hours (RA) and degrees (DEC).
  """
  @spec get_position(GenServer.server()) :: {:ok, position()} | {:error, term()}
  def get_position(server) do
    GenServer.call(server, :get_position, @default_timeout)
  end

  @doc """
  Get the current mount position in sexagesimal format (HMS/DMS).
  """
  @spec get_position_hms(GenServer.server()) :: {:ok, position_hms()} | {:error, term()}
  def get_position_hms(server) do
    GenServer.call(server, :get_position_hms, @default_timeout)
  end

  @doc """
  Get the current mount position in horizontal coordinates (altitude/azimuth).
  Returns altitude and azimuth in decimal degrees.
  """
  @spec get_altaz(GenServer.server()) :: {:ok, %{alt: float(), az: float()}} | {:error, term()}
  def get_altaz(server) do
    GenServer.call(server, :get_altaz, @default_timeout)
  end

  @doc """
  Slew (GoTo) to the specified coordinates.

  ## Parameters
    - `ra` - Right Ascension in decimal hours (0-24)
    - `dec` - Declination in decimal degrees (-90 to +90)

  ## Example

      ZwoController.Mount.goto(mount, 12.5, 45.0)
  """
  @spec goto(GenServer.server(), number(), number()) :: :ok | {:error, term()}
  def goto(server, ra, dec) when is_number(ra) and is_number(dec) do
    GenServer.call(server, {:goto, ra, dec}, @default_timeout)
  end

  @doc """
  Sync the mount to the specified coordinates (for alignment).

  ## Parameters
    - `ra` - Right Ascension in decimal hours (0-24)
    - `dec` - Declination in decimal degrees (-90 to +90)
  """
  @spec sync(GenServer.server(), number(), number()) :: :ok | {:error, term()}
  def sync(server, ra, dec) when is_number(ra) and is_number(dec) do
    GenServer.call(server, {:sync, ra, dec}, @default_timeout)
  end

  @doc """
  Start moving in the specified direction at current slew rate.
  """
  @spec move(GenServer.server(), direction()) :: :ok | {:error, term()}
  def move(server, direction) when direction in [:north, :south, :east, :west] do
    GenServer.call(server, {:move, direction}, @default_timeout)
  end

  @doc """
  Stop movement in the specified direction.
  """
  @spec stop_motion(GenServer.server(), direction()) :: :ok | {:error, term()}
  def stop_motion(server, direction) when direction in [:north, :south, :east, :west] do
    GenServer.call(server, {:stop_motion, direction}, @default_timeout)
  end

  @doc """
  Stop all mount movement.
  """
  @spec stop_all(GenServer.server()) :: :ok | {:error, term()}
  def stop_all(server) do
    GenServer.call(server, :stop_all, @default_timeout)
  end

  @doc """
  Set the slew rate preset (0-9).

  - 0: Guide rate
  - 1-3: Centering rates
  - 4-6: Find rates
  - 7-9: Max slew rates
  """
  @spec set_slew_rate(GenServer.server(), slew_rate()) :: :ok | {:error, term()}
  def set_slew_rate(server, rate) when rate in 0..9 do
    GenServer.call(server, {:set_slew_rate, rate}, @default_timeout)
  end

  @doc """
  Enable or disable tracking.
  """
  @spec set_tracking(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def set_tracking(server, enabled) when is_boolean(enabled) do
    GenServer.call(server, {:set_tracking, enabled}, @default_timeout)
  end

  @doc """
  Set the tracking rate.
  """
  @spec set_tracking_rate(GenServer.server(), tracking_rate()) :: :ok | {:error, term()}
  def set_tracking_rate(server, rate) when rate in [:sidereal, :lunar, :solar] do
    GenServer.call(server, {:set_tracking_rate, rate}, @default_timeout)
  end

  @doc """
  Get tracking status.
  """
  @spec get_tracking(GenServer.server()) :: {:ok, boolean()} | {:error, term()}
  def get_tracking(server) do
    GenServer.call(server, :get_tracking, @default_timeout)
  end

  @doc """
  Send a guide pulse in the specified direction for the given duration.

  ## Parameters
    - `direction` - :north, :south, :east, or :west
    - `duration_ms` - Duration in milliseconds (0-9999)
  """
  @spec guide_pulse(GenServer.server(), direction(), non_neg_integer()) ::
          :ok | {:error, term()}
  def guide_pulse(server, direction, duration_ms)
      when direction in [:north, :south, :east, :west] and
             duration_ms >= 0 and duration_ms <= 9999 do
    GenServer.call(server, {:guide_pulse, direction, duration_ms}, @default_timeout)
  end

  @doc """
  Set the guide rate as a fraction of sidereal rate.
  """
  @spec set_guide_rate(GenServer.server(), float()) :: :ok | {:error, term()}
  def set_guide_rate(server, rate) when is_float(rate) and rate > 0 and rate <= 1.0 do
    GenServer.call(server, {:set_guide_rate, rate}, @default_timeout)
  end

  @doc """
  Go to the home position.
  """
  @spec home(GenServer.server()) :: :ok | {:error, term()}
  def home(server) do
    GenServer.call(server, :home, @default_timeout)
  end

  @doc """
  Go to the park position.
  """
  @spec park(GenServer.server()) :: :ok | {:error, term()}
  def park(server) do
    GenServer.call(server, :park, @default_timeout)
  end

  @doc """
  Set the observing site location.

  ## Parameters
    - `latitude` - decimal degrees (-90 to +90, positive = North)
    - `longitude` - decimal degrees (-180 to +180 or 0 to 360)
  """
  @spec set_site(GenServer.server(), number(), number()) :: :ok | {:error, term()}
  def set_site(server, latitude, longitude)
      when is_number(latitude) and is_number(longitude) do
    GenServer.call(server, {:set_site, latitude, longitude}, @default_timeout)
  end

  @doc """
  Set buzzer volume.

  ## Parameters
    - `volume` - 0 (off), 1 (low), or 2 (high)
  """
  @spec set_buzzer(GenServer.server(), 0..2) :: :ok | {:error, term()}
  def set_buzzer(server, volume) when volume in 0..2 do
    GenServer.call(server, {:set_buzzer, volume}, @default_timeout)
  end

  @doc """
  Set mount to Alt-Az mode.

  This configures the mount to operate in altitude-azimuth mode, suitable
  when the mount is physically installed on a tripod without an equatorial wedge.

  Note: This is a software configuration setting - the mount must be physically
  installed in an appropriate orientation for Alt-Az operation to work correctly.
  """
  @spec set_altaz_mode(GenServer.server()) :: :ok | {:error, term()}
  def set_altaz_mode(server) do
    GenServer.call(server, :set_altaz_mode, @default_timeout)
  end

  @doc """
  Set mount to Polar/Equatorial mode.

  This configures the mount to operate in equatorial mode, suitable when
  the mount is physically installed on an equatorial wedge and polar aligned.

  Note: This is a software configuration setting - the mount must be physically
  installed on a wedge for equatorial operation to work correctly.
  """
  @spec set_polar_mode(GenServer.server()) :: :ok | {:error, term()}
  def set_polar_mode(server) do
    GenServer.call(server, :set_polar_mode, @default_timeout)
  end

  @doc """
  Get mount information (model and version).
  """
  @spec get_info(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_info(server) do
    GenServer.call(server, :get_info, @default_timeout)
  end

  @doc """
  Get mount status including tracking, slewing, home position, and mount type.

  Returns `{:ok, %{tracking: boolean, slewing: boolean, at_home: boolean, mount_type: atom}}`

  Mount type reflects the physical installation:
    - `:altaz` - Mount on tripod (no wedge)
    - `:equatorial` - Mount on equatorial wedge or polar aligned

  Mount type cannot be changed via software - it requires physically reconfiguring
  the mount hardware (e.g., adding/removing an equatorial wedge).
  """
  @spec get_status(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_status(server) do
    GenServer.call(server, :get_status, @default_timeout)
  end

  @doc """
  Send a raw command to the mount and receive the response.
  Useful for debugging or accessing commands not wrapped by the API.
  """
  @spec send_command(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_command(server, command) when is_binary(command) do
    GenServer.call(server, {:send_command, command}, @default_timeout)
  end

  # =============================================================================
  # GENSERVER CALLBACKS
  # =============================================================================

  @impl true
  def init(opts) do
    port_name = Keyword.fetch!(opts, :port)
    baud = Keyword.get(opts, :baud, @default_baud)

    state = %{
      port: nil,
      port_name: port_name,
      baud: baud,
      connected: false,
      tracking: false,
      slewing: false
    }

    # Attempt to connect on init
    case do_connect(state) do
      {:ok, new_state} ->
        Logger.info("Connected to ZWO AM5 mount on #{port_name}")
        {:ok, new_state}

      {:error, reason} ->
        Logger.warning("Failed to connect to mount: #{inspect(reason)}, starting disconnected")
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case do_connect(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    new_state = do_disconnect(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_position, _from, state) do
    with {:ok, ra_response} <- send_and_receive(state, Protocol.get_ra()),
         {:ok, {ra_h, ra_m, ra_s}} <- Protocol.parse_ra(ra_response),
         {:ok, dec_response} <- send_and_receive(state, Protocol.get_dec()),
         {:ok, {dec_d, dec_m, dec_s}} <- Protocol.parse_dec(dec_response) do
      ra_decimal = Coordinates.hms_to_ra(ra_h, ra_m, ra_s)
      dec_decimal = Coordinates.dms_to_dec(dec_d, dec_m, dec_s)
      {:reply, {:ok, %{ra: ra_decimal, dec: dec_decimal}}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_position_hms, _from, state) do
    with {:ok, ra_response} <- send_and_receive(state, Protocol.get_ra()),
         {:ok, {ra_h, ra_m, ra_s}} <- Protocol.parse_ra(ra_response),
         {:ok, dec_response} <- send_and_receive(state, Protocol.get_dec()),
         {:ok, {dec_d, dec_m, dec_s}} <- Protocol.parse_dec(dec_response) do
      result = %{
        ra: %{hours: ra_h, minutes: ra_m, seconds: ra_s},
        dec: %{degrees: dec_d, minutes: dec_m, seconds: dec_s}
      }

      {:reply, {:ok, result}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_altaz, _from, state) do
    with {:ok, alt_response} <- send_and_receive(state, Protocol.get_altitude()),
         {:ok, {alt_d, alt_m, alt_s}} <- Protocol.parse_altitude(alt_response),
         {:ok, az_response} <- send_and_receive(state, Protocol.get_azimuth()),
         {:ok, {az_d, az_m, az_s}} <- Protocol.parse_azimuth(az_response) do
      alt_decimal = Coordinates.dms_to_dec(alt_d, alt_m, alt_s)
      az_decimal = Coordinates.dms_to_dec(az_d, az_m, az_s)
      {:reply, {:ok, %{alt: alt_decimal, az: az_decimal}}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:goto, ra, dec}, _from, state) do
    ra = Coordinates.normalize_ra(ra)
    dec = Coordinates.normalize_dec(dec)

    with {:ok, _} <- send_and_receive(state, Protocol.set_target_ra(ra)),
         {:ok, _} <- send_and_receive(state, Protocol.set_target_dec(dec)),
         {:ok, response} <- send_and_receive(state, Protocol.goto()) do
      result = Protocol.parse_goto_response(response)
      {:reply, result, %{state | slewing: result == :ok}}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:sync, ra, dec}, _from, state) do
    ra = Coordinates.normalize_ra(ra)
    dec = Coordinates.normalize_dec(dec)

    with {:ok, _} <- send_and_receive(state, Protocol.set_target_ra(ra)),
         {:ok, _} <- send_and_receive(state, Protocol.set_target_dec(dec)),
         {:ok, _} <- send_and_receive(state, Protocol.sync()) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:move, direction}, _from, state) do
    cmd =
      case direction do
        :north -> Protocol.move_north()
        :south -> Protocol.move_south()
        :east -> Protocol.move_east()
        :west -> Protocol.move_west()
      end

    case send_command_only(state, cmd) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop_motion, direction}, _from, state) do
    cmd =
      case direction do
        :north -> Protocol.stop_north()
        :south -> Protocol.stop_south()
        :east -> Protocol.stop_east()
        :west -> Protocol.stop_west()
      end

    case send_command_only(state, cmd) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stop_all, _from, state) do
    case send_command_only(state, Protocol.stop_all()) do
      :ok -> {:reply, :ok, %{state | slewing: false}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:set_slew_rate, rate}, _from, state) do
    case send_command_only(state, Protocol.set_slew_rate(rate)) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:set_tracking, enabled}, _from, state) do
    cmd = if enabled, do: Protocol.tracking_on(), else: Protocol.tracking_off()

    case send_and_receive(state, cmd) do
      {:ok, _} -> {:reply, :ok, %{state | tracking: enabled}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:set_tracking_rate, rate}, _from, state) do
    cmd =
      case rate do
        :sidereal -> Protocol.tracking_sidereal()
        :lunar -> Protocol.tracking_lunar()
        :solar -> Protocol.tracking_solar()
      end

    case send_command_only(state, cmd) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_tracking, _from, state) do
    case send_and_receive(state, Protocol.get_tracking_status()) do
      {:ok, response} ->
        {:reply, Protocol.parse_tracking_status(response), state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:guide_pulse, direction, duration_ms}, _from, state) do
    cmd =
      case direction do
        :north -> Protocol.guide_pulse_north(duration_ms)
        :south -> Protocol.guide_pulse_south(duration_ms)
        :east -> Protocol.guide_pulse_east(duration_ms)
        :west -> Protocol.guide_pulse_west(duration_ms)
      end

    case send_command_only(state, cmd) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:set_guide_rate, rate}, _from, state) do
    case send_and_receive(state, Protocol.set_guide_rate(rate)) do
      {:ok, _} -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:home, _from, state) do
    case send_and_receive(state, Protocol.find_home()) do
      {:ok, _response} -> {:reply, :ok, %{state | slewing: true}}
      {:error, :timeout} ->
        # Some commands don't return a response, that's OK
        {:reply, :ok, %{state | slewing: true}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:park, _from, state) do
    case send_and_receive(state, Protocol.goto_park()) do
      {:ok, _response} -> {:reply, :ok, %{state | slewing: true}}
      {:error, :timeout} ->
        # Some commands don't return a response, that's OK
        {:reply, :ok, %{state | slewing: true}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:set_site, latitude, longitude}, _from, state) do
    with {:ok, _} <- send_and_receive(state, Protocol.set_latitude(latitude)),
         {:ok, _} <- send_and_receive(state, Protocol.set_longitude(longitude)) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:set_buzzer, volume}, _from, state) do
    case send_and_receive(state, Protocol.set_buzzer_volume(volume)) do
      {:ok, _} -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:set_altaz_mode, _from, state) do
    case send_and_receive(state, Protocol.set_altaz_mode()) do
      {:ok, _} -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:set_polar_mode, _from, state) do
    case send_and_receive(state, Protocol.set_polar_mode()) do
      {:ok, _} -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    with {:ok, model} <- send_and_receive(state, Protocol.get_mount_model()),
         {:ok, version} <- send_and_receive(state, Protocol.get_version()) do
      {:reply,
       {:ok,
        %{
          model: String.trim(model, "#"),
          version: String.trim(version, "#")
        }}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    with {:ok, response} <- send_and_receive(state, Protocol.get_status()),
         {:ok, status} <- Protocol.parse_status(response) do
      {:reply, {:ok, status}, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:send_command, command}, _from, state) do
    {:reply, send_and_receive(state, command), state}
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) do
    Logger.debug("Received async data: #{inspect(data)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  # =============================================================================
  # PRIVATE FUNCTIONS
  # =============================================================================

  defp do_connect(%{port: nil, port_name: port_name, baud: baud} = state) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        opts = [
          speed: baud,
          data_bits: 8,
          stop_bits: 1,
          parity: :none,
          flow_control: :none,
          active: false
        ]

        case Circuits.UART.open(uart, port_name, opts) do
          :ok ->
            {:ok, %{state | port: uart, connected: true}}

          {:error, reason} ->
            Circuits.UART.stop(uart)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_connect(%{connected: true} = state), do: {:ok, state}

  defp do_disconnect(%{port: nil} = state), do: state

  defp do_disconnect(%{port: uart} = state) do
    Circuits.UART.close(uart)
    Circuits.UART.stop(uart)
    %{state | port: nil, connected: false}
  end

  defp send_and_receive(%{port: nil}, _cmd), do: {:error, :not_connected}

  defp send_and_receive(%{port: uart}, cmd) do
    :ok = Circuits.UART.write(uart, cmd)
    Logger.debug("Sent: #{inspect(cmd)}")

    case read_response(uart) do
      {:ok, response} ->
        Logger.debug("Received: #{inspect(response)}")
        {:ok, response}

      {:error, _} = error ->
        error
    end
  end

  defp send_command_only(%{port: nil}, _cmd), do: {:error, :not_connected}

  defp send_command_only(%{port: uart}, cmd) do
    case Circuits.UART.write(uart, cmd) do
      :ok ->
        Logger.debug("Sent: #{inspect(cmd)}")
        :ok

      error ->
        error
    end
  end

  defp read_response(uart, acc \\ "") do
    case Circuits.UART.read(uart, @read_timeout) do
      {:ok, ""} ->
        if acc == "", do: {:error, :timeout}, else: {:ok, acc}

      {:ok, data} ->
        response = acc <> data

        if String.ends_with?(response, "#") do
          {:ok, response}
        else
          read_response(uart, response)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
