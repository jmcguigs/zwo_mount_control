defmodule ZwoController.Coordinates do
  @moduledoc """
  Coordinate conversion utilities for telescope control.

  Provides functions to convert between decimal degrees/hours and
  sexagesimal (degrees/hours, minutes, seconds) representations.
  """

  @type ra :: %{hours: integer(), minutes: integer(), seconds: number()}
  @type dec :: %{degrees: integer(), minutes: integer(), seconds: number()}

  @doc """
  Convert RA decimal hours to sexagesimal format.

  ## Examples

      iex> ZwoController.Coordinates.ra_to_hms(6.5)
      %{hours: 6, minutes: 30, seconds: 0.0}

      iex> ZwoController.Coordinates.ra_to_hms(12.7525)
      %{hours: 12, minutes: 45, seconds: 9.0}
  """
  @spec ra_to_hms(number()) :: ra()
  def ra_to_hms(decimal_hours) when is_number(decimal_hours) do
    decimal_hours = normalize_ra(decimal_hours)
    hours = trunc(decimal_hours)
    remaining_minutes = (decimal_hours - hours) * 60
    minutes = trunc(remaining_minutes)
    seconds = (remaining_minutes - minutes) * 60

    %{hours: hours, minutes: minutes, seconds: Float.round(seconds, 1)}
  end

  @doc """
  Convert DEC decimal degrees to sexagesimal format.

  ## Examples

      iex> ZwoController.Coordinates.dec_to_dms(45.5)
      %{degrees: 45, minutes: 30, seconds: 0.0}

      iex> ZwoController.Coordinates.dec_to_dms(-23.4394)
      %{degrees: -23, minutes: 26, seconds: 21.8}
  """
  @spec dec_to_dms(number()) :: dec()
  def dec_to_dms(decimal_degrees) when is_number(decimal_degrees) do
    sign = if decimal_degrees >= 0, do: 1, else: -1
    abs_degrees = abs(decimal_degrees)
    degrees = trunc(abs_degrees)
    remaining_minutes = (abs_degrees - degrees) * 60
    minutes = trunc(remaining_minutes)
    seconds = (remaining_minutes - minutes) * 60

    %{degrees: sign * degrees, minutes: minutes, seconds: Float.round(seconds, 1)}
  end

  @doc """
  Convert sexagesimal RA to decimal hours.

  ## Examples

      iex> ZwoController.Coordinates.hms_to_ra(6, 30, 0)
      6.5

      iex> ZwoController.Coordinates.hms_to_ra(%{hours: 12, minutes: 45, seconds: 9})
      12.7525
  """
  @spec hms_to_ra(integer(), integer(), number()) :: float()
  def hms_to_ra(hours, minutes, seconds) do
    hours + minutes / 60 + seconds / 3600
  end

  @spec hms_to_ra(ra()) :: float()
  def hms_to_ra(%{hours: h, minutes: m, seconds: s}), do: hms_to_ra(h, m, s)

  @doc """
  Convert sexagesimal DEC to decimal degrees.

  ## Examples

      iex> ZwoController.Coordinates.dms_to_dec(45, 30, 0)
      45.5

      iex> ZwoController.Coordinates.dms_to_dec(%{degrees: -23, minutes: 26, seconds: 21.8})
      -23.439388888888887
  """
  @spec dms_to_dec(integer(), integer(), number()) :: float()
  def dms_to_dec(degrees, minutes, seconds) do
    sign = if degrees >= 0, do: 1, else: -1
    sign * (abs(degrees) + minutes / 60 + seconds / 3600)
  end

  @spec dms_to_dec(dec()) :: float()
  def dms_to_dec(%{degrees: d, minutes: m, seconds: s}), do: dms_to_dec(d, m, s)

  @doc """
  Normalize RA to 0-24 hours range.
  """
  @spec normalize_ra(number()) :: float()
  def normalize_ra(ra) when is_number(ra) do
    ra = :math.fmod(ra, 24.0)
    if ra < 0, do: ra + 24.0, else: ra
  end

  @doc """
  Clamp DEC to -90 to +90 range.
  """
  @spec normalize_dec(number()) :: float()
  def normalize_dec(dec) when is_number(dec) do
    cond do
      dec > 90.0 -> 90.0
      dec < -90.0 -> -90.0
      true -> dec / 1
    end
  end

  @doc """
  Validate that coordinates are within valid ranges.
  """
  @spec valid_coordinates?(number(), number()) :: boolean()
  def valid_coordinates?(ra, dec) when is_number(ra) and is_number(dec) do
    ra >= 0 and ra < 24 and dec >= -90 and dec <= 90
  end
end
