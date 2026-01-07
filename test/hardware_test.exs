defmodule ZwoController.HardwareTest do
  @moduledoc """
  Hardware tests that require a real ZWO AM5/AM3N mount connected.

  These tests are excluded by default. To run them:

      mix test test/hardware_test.exs --include hardware

  You can override the port with an environment variable:

      ZWO_PORT=/dev/ttyUSB0 mix test test/hardware_test.exs --include hardware
  """

  use ExUnit.Case, async: false

  @moduletag :hardware

  # Test configuration
  @move_duration_ms 2000
  @slew_rate 8

  defp get_port do
    System.get_env("ZWO_PORT") || :auto
  end

  defp log(msg), do: IO.puts(msg)

  describe "sequential mount control" do
    @tag timeout: 120_000
    test "home, move axes, and home again" do
      log("\n" <> String.duplicate("=", 60))
      log("🔌 CONNECTING TO MOUNT")
      log(String.duplicate("=", 60))

      {:ok, mount} = ZwoController.start_mount(port: get_port())

      # Get mount info
      {:ok, info} = ZwoController.info(mount)
      log("📡 Connected to: #{info.model} (firmware #{info.version})")

      # Get initial status
      {:ok, status} = ZwoController.status(mount)
      log("📊 Status: #{inspect(status)}")

      # Get initial position
      {:ok, pos} = ZwoController.position(mount)
      log("📍 Initial position: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      # === HOME THE MOUNT ===
      log("\n" <> String.duplicate("-", 60))
      log("🏠 HOMING MOUNT (first time)")
      log(String.duplicate("-", 60))

      :ok = ZwoController.home(mount)
      Process.sleep(3000)  # Wait for homing to complete

      {:ok, pos} = ZwoController.position(mount)
      log("📍 Position after home: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      # === MOVE RA AXIS (EAST/WEST) ===
      log("\n" <> String.duplicate("-", 60))
      log("➡️  MOVING RA AXIS (East) at rate #{@slew_rate} for #{@move_duration_ms}ms")
      log(String.duplicate("-", 60))

      :ok = ZwoController.set_rate(mount, @slew_rate)
      :ok = ZwoController.move(mount, :east)
      Process.sleep(@move_duration_ms)
      :ok = ZwoController.stop(mount)

      {:ok, pos} = ZwoController.position(mount)
      log("📍 Position after East move: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      log("\n⬅️  MOVING RA AXIS (West) at rate #{@slew_rate} for #{@move_duration_ms}ms")

      :ok = ZwoController.move(mount, :west)
      Process.sleep(@move_duration_ms)
      :ok = ZwoController.stop(mount)

      {:ok, pos} = ZwoController.position(mount)
      log("📍 Position after West move: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      # === MOVE DEC AXIS (NORTH/SOUTH) ===
      log("\n" <> String.duplicate("-", 60))
      log("⬆️  MOVING DEC AXIS (North) at rate #{@slew_rate} for #{@move_duration_ms}ms")
      log(String.duplicate("-", 60))

      :ok = ZwoController.move(mount, :north)
      Process.sleep(@move_duration_ms)
      :ok = ZwoController.stop(mount)

      {:ok, pos} = ZwoController.position(mount)
      log("📍 Position after North move: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      log("\n⬇️  MOVING DEC AXIS (South) at rate #{@slew_rate} for #{@move_duration_ms}ms")

      :ok = ZwoController.move(mount, :south)
      Process.sleep(@move_duration_ms)
      :ok = ZwoController.stop(mount)

      {:ok, pos} = ZwoController.position(mount)
      log("📍 Position after South move: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      # === HOME AGAIN ===
      log("\n" <> String.duplicate("-", 60))
      log("🏠 HOMING MOUNT (second time)")
      log(String.duplicate("-", 60))

      :ok = ZwoController.home(mount)
      Process.sleep(5000)  # Wait for homing to complete

      {:ok, pos} = ZwoController.position(mount)
      log("📍 Final position: RA=#{Float.round(pos.ra, 4)}h, DEC=#{Float.round(pos.dec, 2)}°")

      {:ok, status} = ZwoController.status(mount)
      log("📊 Final status: #{inspect(status)}")

      # === DISCONNECT ===
      log("\n" <> String.duplicate("=", 60))
      log("👋 DISCONNECTING")
      log(String.duplicate("=", 60))

      GenServer.stop(mount)

      log("✅ Test complete!\n")
    end

    @tag timeout: 60_000
    test "alt/az tracking simulation" do
      log("\n" <> String.duplicate("=", 60))
      log("🛰️  ALT/AZ TRACKING SIMULATION")
      log(String.duplicate("=", 60))

      {:ok, mount} = ZwoController.start_mount(port: get_port())

      # Get mount info
      {:ok, info} = ZwoController.info(mount)
      log("📡 Connected to: #{info.model}")

      # Home the mount first
      log("\n🏠 Homing mount...")
      :ok = ZwoController.home(mount)
      Process.sleep(5000)

      # Move away from the pole to get meaningful az changes
      # The DEC axis controls altitude in alt-az configuration
      log("\n📐 Moving away from pole for meaningful tracking test...")
      :ok = ZwoController.set_rate(mount, 8)
      :ok = ZwoController.move(mount, :south)
      Process.sleep(3000)
      :ok = ZwoController.stop(mount)
      Process.sleep(500)

      # Get initial alt/az position
      {:ok, start_altaz} = ZwoController.altaz(mount)
      log("📍 Starting position: Alt=#{Float.round(start_altaz.alt, 2)}° Az=#{Float.round(start_altaz.az, 2)}°")

      # Simulate tracking a target moving at ~1°/sec in azimuth
      # This is a simple proportional control loop
      log("\n🎯 Tracking simulation: target moving in azimuth for 5 seconds")
      log("Using pulse-based control with position feedback\n")

      # Set moderate slew rate
      :ok = ZwoController.set_rate(mount, 6)

      # Track for 5 iterations
      for i <- 1..5 do
        # Target moves ~1° per second in azimuth
        target_az = start_altaz.az + (i * 1.0)
        target_alt = start_altaz.alt  # Keep altitude constant

        # Get current position
        {:ok, current} = ZwoController.altaz(mount)

        # Calculate errors
        az_error = target_az - current.az
        _alt_error = target_alt - current.alt

        log("Step #{i}: Target Az=#{Float.round(target_az, 2)}° | Current Az=#{Float.round(current.az, 2)}° | Error=#{Float.round(az_error, 2)}°")

        # Apply corrections using pulsed movement on the DEC axis
        # North increases azimuth (in our configuration), South decreases it
        if abs(az_error) > 0.1 do
          direction = if az_error > 0, do: :north, else: :south
          # Pulse duration proportional to error
          pulse_ms = min(round(abs(az_error) * 150), 500)
          :ok = ZwoController.move(mount, direction)
          Process.sleep(pulse_ms)
          :ok = ZwoController.stop_motion(mount, direction)
        end

        # Small delay before next iteration
        Process.sleep(700)
      end

      # Final position
      {:ok, final_altaz} = ZwoController.altaz(mount)
      log("\n📍 Final position: Alt=#{Float.round(final_altaz.alt, 2)}° Az=#{Float.round(final_altaz.az, 2)}°")
      log("📊 Total movement: ΔAlt=#{Float.round(final_altaz.alt - start_altaz.alt, 2)}° ΔAz=#{Float.round(final_altaz.az - start_altaz.az, 2)}°")

      # Home again
      log("\n🏠 Returning home...")
      :ok = ZwoController.home(mount)
      Process.sleep(5000)

      GenServer.stop(mount)
      log("✅ Alt/Az tracking test complete!\n")
    end
  end
end
