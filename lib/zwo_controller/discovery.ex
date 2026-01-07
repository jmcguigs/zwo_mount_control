defmodule ZwoController.Discovery do
  @moduledoc """
  Auto-discovery of ZWO AM5 mounts on serial ports.

  ## Usage

      # List all serial ports
      ZwoController.Discovery.list_ports()

      # Find AM5 mount (probes ports)
      {:ok, port} = ZwoController.Discovery.find_mount()

      # Start mount with auto-discovery
      {:ok, mount} = ZwoController.start_mount(port: :auto)
  """

  require Logger

  @probe_timeout 2000
  @baud_rate 9600

  @doc """
  List all available serial ports on the system.

  Returns a list of `{port_name, info}` tuples where info contains
  metadata like vendor_id, product_id, manufacturer, description, etc.

  ## Example

      iex> ZwoController.Discovery.list_ports()
      [
        {"/dev/cu.usbserial-1110", %{vendor_id: 1027, product_id: 24577, ...}},
        {"/dev/cu.Bluetooth-Incoming-Port", %{}}
      ]
  """
  @spec list_ports() :: [{String.t(), map()}]
  def list_ports do
    Circuits.UART.enumerate()
    |> Enum.to_list()
  end

  @doc """
  List serial ports that look like they could be USB serial devices.

  Filters out Bluetooth ports and other non-USB serial ports.
  """
  @spec list_usb_ports() :: [{String.t(), map()}]
  def list_usb_ports do
    list_ports()
    |> Enum.filter(fn {name, info} ->
      # Filter for USB serial ports
      usb_port?(name, info)
    end)
  end

  @doc """
  Find a ZWO AM5 mount by probing available serial ports.

  Returns `{:ok, port_name}` if found, or `{:error, :not_found}`.

  ## Options
    - `:timeout` - Probe timeout per port in ms (default: 2000)
    - `:ports` - List of ports to probe (default: all USB ports)

  ## Example

      {:ok, "/dev/cu.usbserial-1110"} = ZwoController.Discovery.find_mount()
  """
  @spec find_mount(keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def find_mount(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @probe_timeout)
    ports = Keyword.get(opts, :ports, nil)

    ports_to_probe = if ports, do: ports, else: Enum.map(list_usb_ports(), &elem(&1, 0))

    Logger.info("Searching for ZWO AM5 mount on #{length(ports_to_probe)} port(s)...")

    result =
      Enum.find_value(ports_to_probe, {:error, :not_found}, fn port ->
        case probe_port(port, timeout) do
          {:ok, _info} ->
            Logger.info("Found ZWO AM5 on #{port}")
            {:ok, port}

          {:error, reason} ->
            Logger.debug("Port #{port}: #{inspect(reason)}")
            nil
        end
      end)

    case result do
      {:ok, _} = success -> success
      {:error, :not_found} = error ->
        Logger.warning("No ZWO AM5 mount found")
        error
    end
  end

  @doc """
  Find all ZWO AM5 mounts on the system.

  Useful if you have multiple mounts connected.
  """
  @spec find_all_mounts(keyword()) :: [{String.t(), map()}]
  def find_all_mounts(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @probe_timeout)
    ports = Keyword.get(opts, :ports, nil)

    ports_to_probe = if ports, do: ports, else: Enum.map(list_usb_ports(), &elem(&1, 0))

    ports_to_probe
    |> Enum.map(fn port ->
      case probe_port(port, timeout) do
        {:ok, info} -> {port, info}
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Probe a specific port to check if it's a ZWO AM5 mount.

  Returns `{:ok, info}` with mount model and version if found.
  """
  @spec probe_port(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def probe_port(port_name, timeout \\ @probe_timeout) do
    Logger.debug("Probing #{port_name}...")

    with {:ok, uart} <- start_uart(),
         :ok <- open_port(uart, port_name),
         {:ok, info} <- identify_mount(uart, timeout) do
      Circuits.UART.close(uart)
      Circuits.UART.stop(uart)
      {:ok, info}
    else
      {:error, reason} = error ->
        Logger.debug("Probe failed for #{port_name}: #{inspect(reason)}")
        error
    end
  end

  # =============================================================================
  # PRIVATE FUNCTIONS
  # =============================================================================

  defp start_uart do
    case Circuits.UART.start_link() do
      {:ok, uart} -> {:ok, uart}
      error -> error
    end
  end

  defp open_port(uart, port_name) do
    opts = [
      speed: @baud_rate,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
      flow_control: :none,
      active: false
    ]

    case Circuits.UART.open(uart, port_name, opts) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  defp identify_mount(uart, timeout) do
    # Send mount model query
    :ok = Circuits.UART.write(uart, ":GVP#")

    case read_response(uart, timeout) do
      {:ok, model} when byte_size(model) > 0 ->
        model = String.trim(model, "#")

        # Check if it looks like a ZWO mount
        if zwo_mount?(model) do
          # Get version too
          :ok = Circuits.UART.write(uart, ":GV#")

          version =
            case read_response(uart, timeout) do
              {:ok, v} -> String.trim(v, "#")
              _ -> "unknown"
            end

          {:ok, %{model: model, version: version}}
        else
          {:error, {:not_zwo_mount, model}}
        end

      {:ok, ""} ->
        {:error, :no_response}

      {:error, _} = error ->
        error
    end
  end

  defp read_response(uart, timeout, acc \\ "") do
    case Circuits.UART.read(uart, timeout) do
      {:ok, ""} ->
        if acc == "", do: {:error, :timeout}, else: {:ok, acc}

      {:ok, data} ->
        response = acc <> data

        if String.ends_with?(response, "#") do
          {:ok, response}
        else
          read_response(uart, timeout, response)
        end

      {:error, _} = error ->
        error
    end
  end

  defp usb_port?(name, info) do
    # Filter out Bluetooth and other non-USB ports
    not String.contains?(name, "Bluetooth") and
      not String.contains?(name, "bluetooth") and
      (
        # Has USB vendor/product IDs
        Map.has_key?(info, :vendor_id) or
        # Or looks like a USB serial port by name
        String.contains?(name, "usbserial") or
        String.contains?(name, "USB") or
        String.contains?(name, "ttyUSB") or
        String.contains?(name, "ttyACM") or
        String.contains?(name, "cu.") or
        String.contains?(name, "COM")
      )
  end

  defp zwo_mount?(model) do
    model_up = String.upcase(model)

    String.contains?(model_up, "ZWO") or
      String.contains?(model_up, "AM5") or
      String.contains?(model_up, "AM3")
  end
end
