# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-01-12

### Added
- Initial release
- ZWO AM5 mount control via serial communication (Meade LX200 protocol)
- GoTo/slewing to RA/Dec coordinates
- Manual motion control in all directions (NSEW)
- Tracking modes: sidereal, lunar, solar
- Autoguiding with configurable guide rate and pulse commands
- Alt-Az and Equatorial mount modes
- Horizontal coordinate support (azimuth/altitude)
- Home and park position commands
- Mount status queries (tracking, slewing, position, mount type)
- Site location configuration
- Mock mount for testing without hardware
- Satellite tracking with TLE propagation via `space_dust`
- Coordinate conversion utilities (HMS/DMS to decimal and vice versa)
- Auto-discovery of mount on USB serial ports
- Comprehensive examples and documentation

### Features
- `ZwoController` - High-level convenience API
- `ZwoController.Mount` - GenServer-based mount controller
- `ZwoController.Mock` - Simulated mount for testing
- `ZwoController.Protocol` - Serial command definitions
- `ZwoController.Coordinates` - Coordinate conversion utilities
- `ZwoController.SatelliteTracker` - Satellite tracking with TLE propagation
- `ZwoController.Discovery` - USB serial port auto-discovery

[0.1.0]: https://github.com/jmcguigs/zwo_controller/releases/tag/v0.1.0
