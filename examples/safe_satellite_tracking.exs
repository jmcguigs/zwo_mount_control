# Safe Satellite Tracking Demo
# This script demonstrates tracking a GPS satellite with proper homing and safety limits

# Configuration
norad_id = "54132"
min_altitude = 5.0  # Don't track below 10° elevation
latitude = 39.7392
longitude = -104.9903
altitude_km = 1.6

# Store mount reference for cleanup on crash
defmodule SafetyCleanup do
  def register(mount) do
    Process.put(:safety_mount, mount)
  end

  def stop_mount do
    case Process.get(:safety_mount) do
      nil -> :ok
      mount ->
        IO.puts("\nSAFETY: Stopping mount motion...")
        try do
          ZwoController.stop(mount)
          IO.puts("   Mount stopped.")
        rescue
          _ -> :ok
        end
    end
  end
end

# Trap exits to ensure mount stops on crash
Process.flag(:trap_exit, true)

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
SafetyCleanup.register(mount)
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

IO.puts("Starting tracking (with initial GOTO alignment)...\n")

# Start tracking - this will automatically:
# 1. Perform initial GOTO to satellite position (status: :slewing)
# 2. Begin pulse-based tracking (status: :tracking)
:ok = ZwoController.start_satellite_tracking(tracker)

# Wait for initial GOTO to complete before proceeding
IO.puts("Waiting for initial alignment to complete...")
case ZwoController.wait_for_satellite_tracking(tracker, timeout_ms: 120_000) do
  :ok ->
    IO.puts("   Mount aligned and tracking!\n")
  {:error, :timeout} ->
    IO.puts("   Alignment timed out, stopping mount and exiting...\n")
    SafetyCleanup.stop_mount()
    System.halt(1)
end

IO.puts("Tracking for 60 seconds...")
IO.puts("Press Ctrl+C to stop early\n")

try do
  # Let the tracker run for 60 seconds
  Process.sleep(60_000)
rescue
  _ ->
    SafetyCleanup.stop_mount()
    reraise "Tracking interrupted", __STACKTRACE__
end

IO.puts("\nTracking session complete!")
IO.puts("Stopping tracking...")
ZwoController.stop_satellite_tracking(tracker)

IO.puts("Returning mount to home position...")
ZwoController.home(mount)

GenServer.stop(tracker)
ZwoController.Mount.disconnect(mount)
IO.puts("Done!\n")
