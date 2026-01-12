# Safe Satellite Tracking Demo
# This script demonstrates tracking a GPS satellite with proper homing and safety limits

# Configuration
norad_id = "23398"  # GPS IIF-7
min_altitude = 10.0  # Don't track below 10° elevation
latitude = 39.7392
longitude = -104.9903
altitude_km = 1.6

IO.puts("╔══════════════════════════════════════════════════════════════╗")
IO.puts("║      SAFE SATELLITE TRACKING DEMO                           ║")
IO.puts("╚══════════════════════════════════════════════════════════════╝\n")

# Check satellite visibility first
observer = ZwoController.observer(latitude, longitude, altitude_km)
{:ok, tle} = ZwoController.fetch_tle(norad_id)
{:ok, sat_pos} = ZwoController.satellite_position_at(tle, observer, DateTime.utc_now())

IO.puts("Satellite Position:")
IO.puts("   Az=#{Float.round(sat_pos.az, 1)}° El=#{Float.round(sat_pos.el, 1)}°\n")

if sat_pos.el < min_altitude do
  IO.puts("Satellite is too low (< #{min_altitude}°)")
  IO.puts("   Cannot track safely. Exiting.\n")
  System.halt(0)
end

# Connect to mount
IO.puts("🔌 Connecting to mount...")
{:ok, mount} = ZwoController.start_mount(port: "/dev/cu.usbmodem1234561")
IO.puts("   Connected!\n")

# SET MOUNT TO ALT-AZ MODE - Required for azimuth tracking
IO.puts("Setting mount to Alt-Az mode...")
case ZwoController.set_altaz_mode(mount) do
  :ok -> :ok
  {:error, :timeout} -> :ok  # Command doesn't send response but works
  error -> raise "Failed to set Alt-Az mode: #{inspect(error)}"
end
Process.sleep(1000)  # Wait for mode change to take effect

# Verify the mode change worked
case ZwoController.status(mount) do
  {:ok, %{mount_type: :altaz}} ->
    IO.puts("   Alt-Az mode enabled\n")
  {:ok, %{mount_type: other}} ->
    IO.puts("   Mount is in #{other} mode, not Alt-Az!")
    ZwoController.Mount.disconnect(mount)
    System.halt(1)
  {:error, reason} ->
    IO.puts("   Failed to verify mode: #{inspect(reason)}")
    ZwoController.Mount.disconnect(mount)
    System.halt(1)
end

# HOME THE MOUNT - Critical for safety
IO.puts("HOMING MOUNT (this may take 30-60 seconds)...")
IO.puts("   Please ensure mount has clear path to home position")
:ok = ZwoController.home(mount)

# CRITICAL: Wait for homing to complete before any other operations
IO.puts("   Waiting for home operation to complete...")
case ZwoController.wait_for_idle(mount, 120_000) do
  :ok ->
    IO.puts("   Homing complete!\n")
  {:error, :timeout} ->
    IO.puts("   Homing timed out after 2 minutes!")
    ZwoController.Mount.disconnect(mount)
    System.halt(1)
end

{:ok, home_pos} = ZwoController.altaz(mount)
IO.puts("Home Position: Az=#{Float.round(home_pos.az, 1)}° Alt=#{Float.round(home_pos.alt, 1)}°\n")

# Start tracker
{:ok, tracker} = ZwoController.track_satellite(
  mount: mount,
  norad_id: norad_id,
  observer: observer,
  min_elevation: min_altitude
)

IO.puts("Starting 60-second tracking session\n")
IO.puts("Press Ctrl+C to stop early\n")

# Set to maximum slew rate for initial positioning
IO.puts("Setting slew rate to maximum (9)...")
ZwoController.set_rate(mount, 9)
Process.sleep(100)  # Give command time to process

start_time = System.monotonic_time(:second)

try do
  Stream.iterate(0, &(&1 + 1))
  |> Enum.reduce_while(:ok, fn _, _ ->
    elapsed = System.monotonic_time(:second) - start_time

    if elapsed >= 60 do
      {:halt, :done}
    else
      {:ok, sat} = ZwoController.satellite_position(tracker)
      {:ok, mnt} = ZwoController.altaz(mount)

      # SAFETY CHECK: Abort if mount goes too low
      if mnt.alt < 0.0 do
        IO.puts("\nSAFETY ABORT: Mount altitude #{Float.round(mnt.alt, 1)}° is below horizon!")
        {:halt, :safety_abort}
      else
        # Normalize azimuth error
        az_err = sat.az - mnt.az
        az_err = cond do
          az_err > 180 -> az_err - 360
          az_err < -180 -> az_err + 360
          true -> az_err
        end
        el_err = sat.el - mnt.alt

        IO.puts("[#{String.pad_leading("#{elapsed}", 2)}s] Sat: #{Float.round(sat.az, 1)}°/#{Float.round(sat.el, 1)}° | Mnt: #{Float.round(mnt.az, 1)}°/#{Float.round(mnt.alt, 1)}° | Err: #{Float.round(az_err, 2)}°/#{Float.round(el_err, 2)}°")

        # Azimuth corrections - use longer pulses for large errors
        if abs(az_err) > 0.3 do
          # IMPORTANT: EAST increases azimuth (clockwise), WEST decreases azimuth (counterclockwise)
          dir = if az_err > 0, do: :east, else: :west
          # For large errors (>10°), use longer pulses up to 3 seconds
          # For small errors (<10°), use shorter pulses for precision
          max_pulse = if abs(az_err) > 10.0, do: 3000, else: 800
          pulse = min(round(abs(az_err) * 100), max_pulse)
          ZwoController.move(mount, dir)
          Process.sleep(pulse)
          ZwoController.stop_motion(mount, dir)
        end

        # Altitude corrections - SAFETY: prevent moving below horizon (pier collision)
        if abs(el_err) > 0.3 do
          if el_err < 0 and mnt.alt < 5.0 do
            # Don't move down if already low - prevents pier collision
            :skip
          else
            dir = if el_err > 0, do: :north, else: :south
            pulse = min(round(abs(el_err) * 100), 800)
            ZwoController.move(mount, dir)
            Process.sleep(pulse)
            ZwoController.stop_motion(mount, dir)
          end
        end

        Process.sleep(1000)
        {:cont, :ok}
      end
    end
  end)
rescue
  _error ->
    IO.puts("\nError during tracking")
end

IO.puts("\nTracking session complete!")
IO.puts("Returning mount to home position...")
ZwoController.home(mount)

GenServer.stop(tracker)
ZwoController.Mount.disconnect(mount)
IO.puts("Done!\n")
