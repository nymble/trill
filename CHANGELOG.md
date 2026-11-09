# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- The Apple companion app is now named **Trillium** (`Trillium.app`, schemes `TrilliumMac`/`TrilliumIOS`, artifacts `Trillium-macOS-…`, `trillium-*` CI artifacts, test kit `Trillium-<version>-<commit>`). Trill remains the name of the Bela sensor, the firmware, USB device, protocol, `TrillKit` package and repository. Bundle ID unchanged (`com.nymble.trill`).

### Fixed
- **Tap percussion stopped after 35.8 min** of continuous calibration (and returned 35.8 min later): the 1 s arm delay used a signed `u32` µs comparison that flips at 2³¹ µs. Now a latch. The same class of bug could hold a controller unchanged for over 35.8 min, or a sensor returning after a 35.8 min gap; elapsed times are now `wrapping_sub` intervals and only samples up to 1 s older are treated as backwards. Tests at 37/60/72/100/150 min and across the u32 wrap. (Firmware 0.4.0; not yet run on hardware.)

### Added
- Firmware/protocol 0.4.0 (simulation-tested, **not hardware-tested**): sensor modes (touch, tilt notes with scale steps, gate and hysteresis, theremin with continuous tilt pitch and expression CC); configurable controllers A/B (source, CC number, deadzone, bounded smoothing); tap threshold and cooldown; optional flick / zig-zag gestures (off by default; circle/twirl deferred); orientation zero (action 5). Paged configuration (capability bit 4, page 1 = parameters 14–30); page 0 and 0.3.0 hosts unchanged. Status line shows mode, controllers and gestures.
- Apple app 0.4.0: built-in presets, sensor-mode / controller / tap / gesture controls (disabled and never sent on firmware < 0.4.0), per-page apply; MIDI monitor hides Trill sensor SysEx by default, shows display vs sent channels and active channels, and shows any CC.
- Sensor telemetry (protocol v1 messages `05`/`06`/`45`/`50`, capability bit 3, firmware 0.3.0): lease-based subscription (5 s), 1–100 Hz (default 50), 54-byte frames with accel, gyro, pitch/roll, touch, states and counters; lowest priority on cable 1, skipped rather than queued; `tlm=` in the status line. Shared fixtures `protocol/telemetry-v1-frames.txt` tested in Rust and Swift.
- Apple app: Sensors tab (live charts that break at gaps, orientation, touch, stream health, events, CSV export, unsupported-firmware state) and a MIDI monitor with real-time filter, rates, SysEx counts and CSV export.
- `make test-kit` and CI artifact `trill-test-kit-unsigned-dev`: Mac app + matching application-only UF2 + tool + docs + manifest + checksums.
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

- `trill-config`: `no_std` versioned SysEx configuration protocol (dev manufacturer ID 0x7D, request IDs, ack/error codes, 64-byte bound, atomic SET_CONFIG with 13 RAM-only parameters, actions panic / recalibrate / LED self-test / restore defaults), bounded USB-MIDI SysEx assembler that passes over realtime bytes, `protocol/config-v1-vectors.txt` shared with Swift (`make protocol-vectors`).
- XIAO Sense firmware 0.2.0: second USB-MIDI cable for configuration, replies interleaved after instrument events, boot ID and config generation, `cfg=` counters.
- `apple/`: Trill companion app for macOS 13+ and iOS 16+ (SwiftUI, CoreMIDI): endpoint discovery and hotplug, MIDI monitor with SysEx reassembly, configuration with requested vs acknowledged state, JSON presets through user-selected files, read-only firmware assistant on the Mac. `TrillKit` Swift package with tests. Xcode project from pinned XcodeGen 2.45.4; bundle ID `com.nymble.trill`; no team or signing in the repository.
- Make targets `apple-test`, `apple-test-ios-sim`, `apple-project`, `apple-mac`, `apple-ios-sim`, `apple-ios-device`, `apple`, `apple-dist`; CI job on macOS building unsigned apps and uploading `trill-apple-apps-unsigned-dev`.
- Docs: Apple app, configuration protocol.

### Changed
- USB layout: two MIDI cables per direction; `bcdDevice` 0x0200. Workspace version 0.3.0 (0.2.0 added configuration; `bcdDevice` stays 0x0200 because the USB layout did not change).
- XIAO Sense firmware: the on-board synth, its high-priority audio task and the PCM CDC port moved behind the optional `pcm-synth` feature. The default build renders no audio. USB PID changed from 1209:0001 to 1209:0002 (default) / 1209:0003 (`pcm-synth`).
