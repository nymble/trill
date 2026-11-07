# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Raspberry Pi and Seeed XIAO nRF52840 wiring designs for Trill Flex (proposals, not hardware-validated).
- `trill-driver`: `no_std` embedded-hal 1.0 driver with Identify, configuration commands, acknowledgement polling, and 1-axis centroid and 16-bit channel decoding.
- `trill-cli`: Linux `trill identify` / `trill read` bring-up tool.
- CI (fmt, clippy, tests, thumbv7em and ARM cross builds) and a tag-driven release workflow with SHA-256 checksums.
- `lsm6ds3trc`: `no_std` LSM6DS3TR-C IMU driver (identify, reset, ODR/full-scale, BDU, INT1 data-ready, burst read, scaling).
- `motion-synth`: `no_std` motion processing (gyro calibration, complementary filter, taps), gesture mapping, block-based synth (PolyBLEP saw + sub, TPT SVF, pluck envelope, smoothing), control mailbox and PCM stream framing; WAV demo.
- `firmware/xiao-sense`: Embassy firmware for the XIAO nRF52840 Sense with USB CDC diagnostics and PCM test stream, IMU and Trill tasks with fault recovery, priority-isolated audio task, crash capture and safe mode. Not yet run on hardware.
- `status-led`: `no_std` RGB status LED (digital colour mixes, prioritised fault/activity indications, wrap-safe blink timing, embedded-hal pin driver). The XIAO Sense firmware drives the active-low user RGB LED (P0.26/P0.30/P0.06) with it and adds USB debug keys `L`, `0`–`7` and `a`. Not yet observed on hardware.
- `tools/xiao_uf2.py` (application-only UF2 convert/inspect/backup/flash with target checks) and `tools/pcm_capture.py`.
- Docs: XIAO Sense firmware, motion synth, Omi integration and licensing analysis.
- `instrument-events`: `no_std` single-voice touch + motion → MIDI 1.0 engine (bend or stepped pitch, chromatic/pentatonic, contact-size pressure, CC74 rotation, CC1 tilt, optional tap percussion), critical note queue with note-off reserve, coalesced rate-limited controllers, connect/panic reset sequence with RPN 0, USB-MIDI 1.0 packet encoder; 24 host tests including a golden trace.
- `trill-usb`: USB-MIDI 1.0 + CDC ACM composite layout (pid.codes test PIDs 1209:0002 / 1209:0003), with host descriptor tests against a mock nRF52840 driver.
- `trill-driver`: `read_frame()` reads status (frame ID) and centroids in one transaction.
- XIAO Sense firmware: class-compliant USB-MIDI + diagnostics by default; Trill and IMU decoupled (touch works without IMU); Trill at 10-bit ultra-fast scan with frame-ID filtering; MIDI writer with disconnect detection and stall counting; diagnostics keys `m`, `p`, `k`, `q`, `t`, `x`; optional `timing-gpio` feature. Not yet run on hardware.
- Docs: USB MIDI setup and acceptance procedure, MIDI mapping, XIAO power and battery (BQ25101 charger, P0.13 charge-current select, power switch-over) with the diagram extended.

### Changed
- XIAO Sense firmware: the on-board synth, its high-priority audio task and the PCM CDC port moved behind the optional `pcm-synth` feature. The default build renders no audio. USB PID changed from 1209:0001 to 1209:0002 (default) / 1209:0003 (`pcm-synth`).
