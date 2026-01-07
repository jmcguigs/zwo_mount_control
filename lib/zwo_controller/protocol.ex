defmodule ZwoController.Protocol do
  @moduledoc """
  Serial protocol definitions for the ZWO AM5 telescope mount.

  The AM5 uses a subset of the LX200 protocol with some ZWO-specific extensions.
  Commands are ASCII strings starting with `:` and ending with `#`.

  All angle-setting functions accept decimal values:
  - RA: decimal hours (0-24)
  - DEC, latitude, longitude: decimal degrees

  Conversions to the required DMS/HMS formats are handled internally.
  """

  alias ZwoController.Coordinates

  # =============================================================================
  # GETTER COMMANDS
  # =============================================================================

  @doc "Get mount firmware version"
  def get_version, do: ":GV#"

  @doc "Get mount model name"
  def get_mount_model, do: ":GVP#"

  @doc "Get current Right Ascension (RA) coordinates"
  def get_ra, do: ":GR#"

  @doc "Get current Declination (DEC) coordinates"
  def get_dec, do: ":GD#"

  @doc "Get date in MM/DD/YY format"
  def get_date, do: ":GC#"

  @doc "Get local time in HH:MM:SS format"
  def get_time, do: ":GL#"

  @doc "Get UTC offset"
  def get_timezone, do: ":GG#"

  @doc "Get sidereal time"
  def get_sidereal_time, do: ":GS#"

  @doc "Get site latitude"
  def get_latitude, do: ":Gt#"

  @doc "Get site longitude"
  def get_longitude, do: ":Gg#"

  @doc "Get meridian flip settings"
  def get_meridian_settings, do: ":GTa#"

  @doc "Get guide rate"
  def get_guide_rate, do: ":Ggr#"

  @doc "Get tracking status"
  def get_tracking_status, do: ":GAT#"

  @doc "Get mount status/mode"
  def get_status_mode, do: ":GU#"

  @doc "Get cardinal direction (pier side)"
  def get_cardinal_direction, do: ":Gm#"

  @doc "Get buzzer volume"
  def get_buzzer_volume, do: ":GBu#"

  @doc "Get altitude (elevation) in degrees/arcmin/arcsec format"
  def get_altitude, do: ":GA#"

  @doc "Get azimuth in degrees/arcmin/arcsec format"
  def get_azimuth, do: ":GZ#"

  @doc """
  Get mount status flags.

  Returns a string of status flags (ZWO-specific):
    - `n` = not tracking
    - `N` = not slewing/moving
    - `H` = at home position
    - `G` = equatorial (German equatorial) mode
    - `Z` = alt-az mode

  Note: Mount mode (Alt-Az vs Equatorial) is determined by physical installation,
  not software configuration. Alt-Az = tripod mount, Equatorial = wedge mount.
  """
  def get_status, do: ":GU#"

  # =============================================================================
  # SETTER COMMANDS - Slewing & GoTo
  # =============================================================================

  @doc """
  Set target RA for slew/goto.

  ## Parameters
    - ra: Right Ascension in decimal hours (0-24)

  ## Examples

      iex> ZwoController.Protocol.set_target_ra(12.5)
      ":Sr12:30:00#"
  """
  def set_target_ra(ra) when is_number(ra) do
    %{hours: h, minutes: m, seconds: s} = Coordinates.ra_to_hms(ra)
    ":Sr#{pad2(h)}:#{pad2(m)}:#{pad2(trunc(s))}#"
  end

  @doc """
  Set target DEC for slew/goto.

  ## Parameters
    - dec: Declination in decimal degrees (-90 to +90)

  ## Examples

      iex> ZwoController.Protocol.set_target_dec(45.5)
      ":Sd+45*30:00#"

      iex> ZwoController.Protocol.set_target_dec(-23.5)
      ":Sd-23*30:00#"
  """
  def set_target_dec(dec) when is_number(dec) do
    %{degrees: d, minutes: m, seconds: s} = Coordinates.dec_to_dms(dec)
    sign = if d >= 0, do: "+", else: "-"
    ":Sd#{sign}#{pad2(abs(d))}*#{pad2(m)}:#{pad2(trunc(s))}#"
  end

  @doc "Execute GoTo to the previously set target coordinates"
  def goto, do: ":MS#"

  @doc "Sync mount to the previously set target coordinates"
  def sync, do: ":CM#"

  @doc "Stop all mount movement"
  def stop_all, do: ":Q#"

  # =============================================================================
  # SETTER COMMANDS - Motion Control
  # =============================================================================

  @doc "Start moving north"
  def move_north, do: ":Mn#"

  @doc "Start moving south"
  def move_south, do: ":Ms#"

  @doc "Start moving east"
  def move_east, do: ":Me#"

  @doc "Start moving west"
  def move_west, do: ":Mw#"

  @doc "Stop moving north"
  def stop_north, do: ":Qn#"

  @doc "Stop moving south"
  def stop_south, do: ":Qs#"

  @doc "Stop moving east"
  def stop_east, do: ":Qe#"

  @doc "Stop moving west"
  def stop_west, do: ":Qw#"

  @doc """
  Set slew rate preset (0-9).

  Rate mappings:
    - 0: Guide rate (~0.5x sidereal)
    - 1-3: Centering rates (1-8x sidereal)
    - 4-6: Find rates (16-64x sidereal)
    - 7-9: Slew rates (up to 1440x sidereal - fastest)
  """
  def set_slew_rate(rate) when rate >= 0 and rate <= 9 do
    ":R#{rate}#"
  end

  # =============================================================================
  # SETTER COMMANDS - Guiding
  # =============================================================================

  @doc "Guide pulse north for duration_ms milliseconds (0-9999)"
  def guide_pulse_north(duration_ms) when duration_ms >= 0 and duration_ms <= 9999 do
    ":Mgn#{pad4(duration_ms)}#"
  end

  @doc "Guide pulse south for duration_ms milliseconds (0-9999)"
  def guide_pulse_south(duration_ms) when duration_ms >= 0 and duration_ms <= 9999 do
    ":Mgs#{pad4(duration_ms)}#"
  end

  @doc "Guide pulse east for duration_ms milliseconds (0-9999)"
  def guide_pulse_east(duration_ms) when duration_ms >= 0 and duration_ms <= 9999 do
    ":Mge#{pad4(duration_ms)}#"
  end

  @doc "Guide pulse west for duration_ms milliseconds (0-9999)"
  def guide_pulse_west(duration_ms) when duration_ms >= 0 and duration_ms <= 9999 do
    ":Mgw#{pad4(duration_ms)}#"
  end

  @doc """
  Set guide rate as a multiplier of sidereal rate.

  ## Parameters
    - rate: 0.1 to 0.9 (typical values: 0.5 for 0.5x sidereal)
  """
  def set_guide_rate(rate) when is_float(rate) do
    ":Rg#{:erlang.float_to_binary(rate, decimals: 1)}#"
  end

  # =============================================================================
  # SETTER COMMANDS - Tracking
  # =============================================================================

  @doc "Enable tracking"
  def tracking_on, do: ":Te#"

  @doc "Disable tracking"
  def tracking_off, do: ":Td#"

  @doc "Set sidereal tracking rate"
  def tracking_sidereal, do: ":TQ#"

  @doc "Set lunar tracking rate"
  def tracking_lunar, do: ":TL#"

  @doc "Set solar tracking rate"
  def tracking_solar, do: ":TS#"

  # =============================================================================
  # SETTER COMMANDS - Home & Park
  # =============================================================================

  @doc """
  Find home position (slews both axes to limit switches for calibration).

  This command initiates homing - the mount will slew to find the home
  position sensors on both axes.
  """
  def find_home, do: ":hC#"

  @doc "Go to park position"
  def goto_park, do: ":hP#"

  @doc "Unpark the mount"
  def unpark, do: ":hR#"

  @doc "Clear alignment data"
  def clear_alignment, do: ":NSC#"

  # =============================================================================
  # SETTER COMMANDS - Site & Time Configuration
  # =============================================================================

  @doc "Set date (MM/DD/YY)"
  def set_date(month, day, year) do
    ":SC#{pad2(month)}/#{pad2(day)}/#{pad2(rem(year, 100))}#"
  end

  @doc "Set local time (HH:MM:SS)"
  def set_time(hour, minute, second) do
    ":SL#{pad2(hour)}:#{pad2(minute)}:#{pad2(second)}#"
  end

  @doc "Set UTC offset (hours from UTC)"
  def set_timezone(offset) when offset >= -12 and offset <= 12 do
    sign = if offset >= 0, do: "+", else: ""
    ":SG#{sign}#{pad2(abs(offset))}#"
  end

  @doc """
  Set site latitude.

  ## Parameters
    - latitude: decimal degrees (-90 to +90, positive = North)

  ## Examples

      iex> ZwoController.Protocol.set_latitude(46.5)
      ":St+46*30#"
  """
  def set_latitude(latitude) when is_number(latitude) do
    %{degrees: d, minutes: m, seconds: _s} = Coordinates.dec_to_dms(latitude)
    sign = if d >= 0, do: "+", else: "-"
    ":St#{sign}#{pad2(abs(d))}*#{pad2(m)}#"
  end

  @doc """
  Set site longitude.

  ## Parameters
    - longitude: decimal degrees (0-360, or -180 to +180)

  ## Examples

      iex> ZwoController.Protocol.set_longitude(6.25)
      ":Sg006*15#"
  """
  def set_longitude(longitude) when is_number(longitude) do
    # Normalize to 0-360 range if negative
    longitude = if longitude < 0, do: longitude + 360, else: longitude
    %{degrees: d, minutes: m, seconds: _s} = Coordinates.dec_to_dms(longitude)
    ":Sg#{pad3(abs(d))}*#{pad2(m)}#"
  end

  # =============================================================================
  # SETTER COMMANDS - Meridian Settings
  # =============================================================================

  @doc """
  Set meridian action.

  ## Parameters
    - action: 0 = stop at meridian, 1 = flip at meridian
  """
  def set_meridian_action(action) when action in [0, 1] do
    ":STa#{action}#"
  end

  # =============================================================================
  # SETTER COMMANDS - Buzzer
  # =============================================================================

  @doc "Set buzzer volume (0-2)"
  def set_buzzer_volume(volume) when volume >= 0 and volume <= 2 do
    ":SBu#{volume}#"
  end

  # =============================================================================
  # RESPONSE PARSING
  # =============================================================================

  @doc """
  Parse RA response in HH:MM:SS or HH:MM.S format.
  Returns {:ok, {hours, minutes, seconds}} or {:error, reason}
  """
  def parse_ra(response) do
    response = String.trim(response, "#")

    cond do
      # Format: HH:MM:SS
      Regex.match?(~r/^\d{2}:\d{2}:\d{2}$/, response) ->
        [h, m, s] = String.split(response, ":")
        {:ok, {String.to_integer(h), String.to_integer(m), String.to_integer(s)}}

      # Format: HH:MM.S
      Regex.match?(~r/^\d{2}:\d{2}\.\d$/, response) ->
        [hm, s] = String.split(response, ".")
        [h, m] = String.split(hm, ":")
        {:ok, {String.to_integer(h), String.to_integer(m), String.to_integer(s) * 6}}

      true ->
        {:error, {:invalid_ra_format, response}}
    end
  end

  @doc """
  Parse DEC response in sDD*MM:SS or sDD*MM format.
  Returns {:ok, {degrees, minutes, seconds}} or {:error, reason}
  """
  def parse_dec(response) do
    response = String.trim(response, "#")

    cond do
      # Format: sDD*MM:SS or sDD°MM:SS
      Regex.match?(~r/^[+-]?\d{2}[*°]\d{2}:\d{2}$/, response) ->
        [deg_part, rest] = String.split(response, ~r/[*°]/)
        [m, s] = String.split(rest, ":")
        {:ok, {String.to_integer(deg_part), String.to_integer(m), String.to_integer(s)}}

      # Format: sDD*MM or sDD°MM
      Regex.match?(~r/^[+-]?\d{2}[*°]\d{2}$/, response) ->
        [deg_part, m] = String.split(response, ~r/[*°]/)
        {:ok, {String.to_integer(deg_part), String.to_integer(m), 0}}

      true ->
        {:error, {:invalid_dec_format, response}}
    end
  end

  @doc """
  Parse altitude response in sDD*MM:SS format (same as DEC but can be 0-90).
  Returns {:ok, {degrees, minutes, seconds}} or {:error, reason}
  """
  def parse_altitude(response), do: parse_dec(response)

  @doc """
  Parse azimuth response in DDD*MM:SS format (0-360 degrees).
  Returns {:ok, {degrees, minutes, seconds}} or {:error, reason}
  """
  def parse_azimuth(response) do
    response = String.trim(response, "#")

    cond do
      # Format: DDD*MM:SS (e.g., "360*00:00" or "045*30:15")
      Regex.match?(~r/^\d{2,3}[*°]\d{2}:\d{2}$/, response) ->
        [deg_part, rest] = String.split(response, ~r/[*°]/)
        [m, s] = String.split(rest, ":")
        {:ok, {String.to_integer(deg_part), String.to_integer(m), String.to_integer(s)}}

      true ->
        {:error, {:invalid_azimuth_format, response}}
    end
  end

  @doc """
  Parse tracking status response.
  Returns {:ok, boolean} or {:error, reason}
  """
  def parse_tracking_status(response) do
    case String.trim(response, "#") do
      "0" -> {:ok, false}
      "1" -> {:ok, true}
      other -> {:error, {:invalid_tracking_status, other}}
    end
  end

  @doc """
  Parse goto response.
  Returns :ok on success, {:error, reason} on failure.
  """
  def parse_goto_response(response) do
    case String.trim(response, "#") do
      "0" -> :ok
      "1" -> {:error, :object_below_horizon}
      "2" -> {:error, :object_below_minimum_elevation}
      "4" -> {:error, :position_unreachable}
      "5" -> {:error, :not_aligned}
      "6" -> {:error, :outside_limits}
      "7" -> {:error, :pier_side_limit}  # ZWO-specific
      "e7" -> {:error, :pier_side_limit}  # ZWO-specific alternate format
      other -> {:error, {:unknown_goto_error, other}}
    end
  end

  @doc """
  Parse simple acknowledgment response (1 = success, 0 = failure).
  """
  def parse_ack(response) do
    case String.trim(response, "#") do
      "1" -> :ok
      "0" -> {:error, :command_failed}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Parse mount status response from :GU# command.

  Returns `{:ok, %{tracking: boolean, slewing: boolean, at_home: boolean, mount_type: atom}}`

  Mount type is `:altaz` or `:equatorial` based on physical installation.
  This cannot be changed via software - requires adding/removing equatorial wedge.

  ## Status Flags
    - `n` = not tracking
    - `N` = not slewing/moving
    - `H` = at home position
    - `G` = equatorial (German equatorial) mode
    - `Z` = alt-az mode
  """
  def parse_status(response) do
    flags = String.trim(response, "#")

    status = %{
      tracking: not String.contains?(flags, "n"),
      slewing: not String.contains?(flags, "N"),
      at_home: String.contains?(flags, "H"),
      mount_type: cond do
        String.contains?(flags, "G") -> :equatorial
        String.contains?(flags, "Z") -> :altaz
        true -> :unknown
      end
    }

    {:ok, status}
  end

  # =============================================================================
  # HELPERS
  # =============================================================================

  defp pad2(n), do: String.pad_leading(to_string(n), 2, "0")
  defp pad3(n), do: String.pad_leading(to_string(n), 3, "0")
  defp pad4(n), do: String.pad_leading(to_string(n), 4, "0")
end
