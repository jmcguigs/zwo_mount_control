#!/usr/bin/env elixir

# Test script to set mount to Alt-Az mode
# This tests the new :AA# command

# Compile the library first
System.cmd("mix", ["compile"], cd: Path.expand(".."))

# Add the build path to the code loader
Code.prepend_path("../_build/dev/lib/zwo_controller/ebin")
Code.prepend_path("../_build/dev/lib/circuits_uart/ebin")

port = "/dev/cu.usbmodem1234561"

IO.puts("Connecting to mount at #{port}...")
{:ok, mount} = ZwoController.start_mount(port: port)

# Get current status
IO.puts("\n=== Current Mount Status ===")
case ZwoController.status(mount) do
  {:ok, status} ->
    IO.puts("  Tracking: #{status[:tracking]}")
    IO.puts("  Slewing: #{status[:slewing]}")
    IO.puts("  At Home: #{status[:at_home]}")
    IO.puts("  Mount Type: #{status[:mount_type]}")
  {:error, reason} ->
    IO.puts("  Error: #{inspect(reason)}")
end

# Set to Alt-Az mode
IO.puts("\n=== Setting Mount to Alt-Az Mode ===")
case ZwoController.set_altaz_mode(mount) do
  :ok ->
    IO.puts("✓ Alt-Az mode command sent successfully")
  {:error, reason} ->
    IO.puts("✗ Error: #{inspect(reason)}")
end

# Wait a moment for the mount to process
Process.sleep(1000)

# Check status again
IO.puts("\n=== Updated Mount Status ===")
case ZwoController.status(mount) do
  {:ok, status} ->
    IO.puts("  Tracking: #{status[:tracking]}")
    IO.puts("  Slewing: #{status[:slewing]}")
    IO.puts("  At Home: #{status[:at_home]}")
    IO.puts("  Mount Type: #{status[:mount_type]}")

    if status[:mount_type] == :altaz do
      IO.puts("\n✓ Mount is now in Alt-Az mode!")
    else
      IO.puts("\n⚠ Mount type: #{status[:mount_type]} (expected :altaz)")
    end
  {:error, reason} ->
    IO.puts("  Error: #{inspect(reason)}")
end

IO.puts("\n=== Testing Azimuth Motion ===")
IO.puts("Current position:")
case ZwoController.altaz(mount) do
  {:ok, %{azimuth: az, altitude: alt}} ->
    IO.puts("  Az: #{Float.round(az, 1)}°, Alt: #{Float.round(alt, 1)}°")
  {:error, reason} ->
    IO.puts("  Error: #{inspect(reason)}")
end

IO.puts("\nSending east (clockwise) pulse for 3 seconds...")
ZwoController.set_rate(mount, 9)  # Maximum rate
ZwoController.move(mount, :east)
Process.sleep(3000)
ZwoController.stop(mount)

IO.puts("\nWaiting 500ms for mount to stabilize...")
Process.sleep(500)

IO.puts("New position:")
case ZwoController.altaz(mount) do
  {:ok, %{azimuth: az, altitude: alt}} ->
    IO.puts("  Az: #{Float.round(az, 1)}°, Alt: #{Float.round(alt, 1)}°")
  {:error, reason} ->
    IO.puts("  Error: #{inspect(reason)}")
end

IO.puts("\nTest complete!")
