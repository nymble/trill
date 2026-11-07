# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Raspberry Pi and Seeed XIAO nRF52840 wiring designs for Trill Flex (proposals, not hardware-validated).
- `trill-driver`: `no_std` embedded-hal 1.0 driver with Identify, configuration commands, acknowledgement polling, and 1-axis centroid and 16-bit channel decoding.
- `trill-cli`: Linux `trill identify` / `trill read` bring-up tool.
- CI (fmt, clippy, tests, thumbv7em and ARM cross builds) and a tag-driven release workflow with SHA-256 checksums.
