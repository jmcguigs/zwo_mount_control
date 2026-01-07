#!/usr/bin/env elixir
# Satellite Tracking Demo
# Run with: mix run examples/track_satellite.exs

defmodule SatelliteDemo do
  @moduledoc """
  Demonstrates satellite tracking with the ZWO mount.

  This example:
  1. Fetches the ISS TLE from Celestrak
  2. Computes its current position
  3. Predicts upcoming visible passes
  4. Optionally tracks the satellite with the mount (if connected)
  """

  def run do
    # Configuration - adjust to your location!
    latitude = 37.7749      # San Francisco
    longitude = -122.4194
    altitude_km = 0.01      # ~10 meters

    norad_id = "25544"      # ISS

    IO.puts("""
    ╔══════════════════════════════════════════════════════════════╗
    ║                   SATELLITE TRACKING DEMO                    ║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    # Create observer location
    observer = ZwoController.observer(latitude, longitude, altitude_km)
    IO.puts("📍 Observer Location:")
    IO.puts("   Latitude:  #{latitude}°")
    IO.puts("   Longitude: #{longitude}°")
    IO.puts("   Altitude:  #{altitude_km * 1000}m\n")

    # Fetch TLE
    IO.puts("🛰️  Fetching TLE for NORAD #{norad_id}...")
    {:ok, tle} = ZwoController.fetch_tle(norad_id)
    IO.puts("   Catalog: #{tle.catalogNumber}")
    IO.puts("   Designator: #{tle.internationalDesignator}")
    IO.puts("   TLE Epoch: #{tle.epoch}")
    IO.puts("   Inclination: #{tle.inclinationDeg}°")
    IO.puts("   Period: #{Float.round(1440 / tle.meanMotion, 1)} minutes\n")

    # Current position
    now = DateTime.utc_now()
    {:ok, pos} = ZwoController.satellite_position_at(tle, observer, now)

    IO.puts("📡 Current Position (#{Calendar.strftime(now, "%H:%M:%S UTC")}):")
    IO.puts("   Azimuth:   #{Float.round(pos.az, 2)}° (#{compass_direction(pos.az)})")
    IO.puts("   Elevation: #{Float.round(pos.el, 2)}°")
    IO.puts("   Range:     #{Float.round(pos.range_km, 1)} km")
    IO.puts("   Status:    #{if pos.el > 0, do: "🟢 Above Horizon", else: "🔴 Below Horizon"}\n")

    # Pass predictions
    IO.puts("📅 Upcoming Visible Passes (next 24 hours, min 10° elevation):\n")
    passes = ZwoController.predict_satellite_passes(tle, observer, hours: 24, min_elevation: 10.0)

    if length(passes) == 0 do
      IO.puts("   No visible passes in the next 24 hours")
    else
      Enum.take(passes, 5)
      |> Enum.with_index(1)
      |> Enum.each(fn {pass, i} ->
        quality = cond do
          pass.max_elevation >= 60 -> "⭐ Excellent"
          pass.max_elevation >= 45 -> "✨ Good"
          pass.max_elevation >= 30 -> "👍 Fair"
          true -> "👀 Low"
        end

        IO.puts("   Pass ##{i}: #{quality}")
        IO.puts("   ├─ Rise:    #{Calendar.strftime(pass.aos, "%b %d %H:%M:%S")} at #{Float.round(pass.aos_azimuth, 0)}° (#{compass_direction(pass.aos_azimuth)})")
        IO.puts("   ├─ Peak:    #{Calendar.strftime(pass.max_elevation_time, "%H:%M:%S")} at #{Float.round(pass.max_elevation, 1)}° elevation")
        IO.puts("   ├─ Set:     #{Calendar.strftime(pass.los, "%H:%M:%S")} at #{Float.round(pass.los_azimuth, 0)}° (#{compass_direction(pass.los_azimuth)})")
        IO.puts("   └─ Duration: #{div(pass.duration_seconds, 60)}m #{rem(pass.duration_seconds, 60)}s\n")
      end)
    end

    # Try to connect to mount
    IO.puts("🔌 Checking for mount...")
    case ZwoController.find_mount() do
      {:ok, port} ->
        IO.puts("   Found mount at #{port}")
        IO.puts("\n   To start tracking, run:")
        IO.puts("   {:ok, mount} = ZwoController.start_mount(port: \"#{port}\")")
        IO.puts("   {:ok, tracker} = ZwoController.track_satellite(")
        IO.puts("     mount: mount,")
        IO.puts("     norad_id: \"#{norad_id}\",")
        IO.puts("     observer: ZwoController.observer(#{latitude}, #{longitude}, #{altitude_km})")
        IO.puts("   )")
        IO.puts("   ZwoController.start_satellite_tracking(tracker)")

      {:error, :not_found} ->
        IO.puts("   No mount found - connect a ZWO AM5/AM3 mount to enable tracking")
    end

    IO.puts("\n✅ Demo complete!")
  end

  defp compass_direction(azimuth) do
    directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                  "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    index = round(azimuth / 22.5) |> rem(16)
    Enum.at(directions, index)
  end
end

SatelliteDemo.run()
