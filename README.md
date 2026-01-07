# ZwoController

An Elixir library for controlling ZWO AM5 telescope mounts via serial communication.

## Features

- **GoTo/Slewing**: Command the mount to slew to any celestial coordinates
- **Manual Motion**: Control axis motion at various speeds (guide to max slew)
- **Tracking**: Enable/disable tracking with sidereal, lunar, or solar rates
- **Autoguiding**: Send guide pulses for autoguiding applications
- **Mock Mount**: Test your application without physical hardware

## Installation

Add `zwo_controller` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zwo_controller, path: "path/to/zwo_controller"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### Connect to a Real Mount

```elixir
# Connect via serial port (typical on Linux/Mac)
{:ok, mount} = ZwoController.start_mount(port: "/dev/ttyUSB0")

# On Windows
{:ok, mount} = ZwoController.start_mount(port: "COM3")
```

### Use the Mock for Testing

```elixir
{:ok, mount} = ZwoController.start_mock()
```

### Basic Operations

```elixir
# Get current position (RA in decimal hours, DEC in decimal degrees)
{:ok, pos} = ZwoController.position(mount)
IO.puts("RA: #{pos.ra}h, DEC: #{pos.dec}°")

# Slew to coordinates
ZwoController.goto(mount, 12.5, 45.0)

# Slew to Vega using HMS/DMS
ra = ZwoController.ra(18, 36, 56)   # 18h 36m 56s
dec = ZwoController.dec(38, 47, 1)  # +38° 47' 01"
ZwoController.goto(mount, ra, dec)

# Enable sidereal tracking
ZwoController.track(mount, :sidereal)

# Manual motion
ZwoController.set_rate(mount, 5)    # Set medium speed
ZwoController.move(mount, :north)   # Start moving north
Process.sleep(1000)
ZwoController.stop(mount)           # Emergency stop
```

### Autoguiding

```elixir
# Set guide rate to 0.5x sidereal
ZwoController.set_guide_rate(mount, 0.5)

# Send guide pulses (direction, duration in ms)
ZwoController.guide(mount, :north, 200)
ZwoController.guide(mount, :east, 150)
```

### Tracking Modes

```elixir
ZwoController.track(mount, :sidereal)  # For stars
ZwoController.track(mount, :lunar)     # For the Moon
ZwoController.track(mount, :solar)     # For the Sun

ZwoController.track_off(mount)         # Disable tracking
```

### Home and Park

```elixir
ZwoController.home(mount)  # Go to home position
ZwoController.park(mount)  # Go to park position
```

## Coordinate System

All coordinates use:
- **Right Ascension (RA)**: Decimal hours (0-24)
- **Declination (DEC)**: Decimal degrees (-90 to +90)

### Converting Coordinates

```elixir
alias ZwoController.Coordinates

# HMS to decimal hours
ra = Coordinates.hms_to_ra(12, 30, 45)  # 12h 30m 45s → 12.5125

# DMS to decimal degrees
dec = Coordinates.dms_to_dec(-23, 26, 21)  # -23° 26' 21" → -23.439...

# Decimal to HMS/DMS
Coordinates.ra_to_hms(12.5)   # → %{hours: 12, minutes: 30, seconds: 0.0}
Coordinates.dec_to_dms(-23.5) # → %{degrees: -23, minutes: 30, seconds: 0.0}
```

## Module Overview

| Module | Description |
|--------|-------------|
| `ZwoController` | High-level convenience API |
| `ZwoController.Mount` | GenServer-based mount controller |
| `ZwoController.Mock` | Simulated mount for testing |
| `ZwoController.Protocol` | Serial command definitions |
| `ZwoController.Coordinates` | Coordinate conversion utilities |

## Low-Level Access

For advanced usage, you can send raw commands:

```elixir
alias ZwoController.Protocol

# Send any command
{:ok, response} = ZwoController.raw(mount, Protocol.get_version())

# Or construct custom commands
{:ok, response} = ZwoController.raw(mount, ":GVP#")  # Get mount model
```

## Hardware Requirements

- ZWO AM5 mount (or compatible)
- USB-serial connection to the mount
- Serial port permissions (on Linux, add user to `dialout` group)

```bash
# Linux: Add user to dialout group for serial access
sudo usermod -a -G dialout $USER
# Log out and back in for changes to take effect
```

## License

MIT

