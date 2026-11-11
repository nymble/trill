# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **iPad Simulator testing**: `make apple-test-ipad-sim` runs the TrillKit tests on an available iPad Simulator; `make apple-ipad-sim` boots an iPad Simulator, installs the app, and captures portrait and landscape screenshots of Home, Presets, Sensors and Settings. CI uploads them as `trillium-ipad-simulator-screenshots`. The Simulator has no USB MIDI device, so Home shows the plug-in prompt.
- The iOS Simulator app (`Trillium-iOS-Simulator-X.Y.Z.zip`) is included in GitHub Release downloads, the test kit and `SHA256SUMS`. It runs on iPhone and iPad Simulators and cannot be installed on a physical device.
- `make apple-ios-ipa` archives and exports a development IPA on a Mac with Xcode, reading the team from the git-ignored `apple/Config/Local.xcconfig`. An optional, manual-dispatch workflow (`.github/workflows/ios-dev-ipa.yml`) can build a signed IPA when signing secrets are present; it is untested, because this repository has no such secrets. No physical iPad install has been tested.

## [0.5.0]

The first release published on GitHub, so it also lists the 0.4.0 work that was never released separately.

### Added (0.5.0)
- **App icon** for macOS and iOS: three petals over three leaves, drawn in code by `apple/scripts/make_app_icon.swift` (no image assets or third-party art).
- **GitHub Releases**: pushing a `vX.Y.Z` tag builds the Mac app, firmware UF2, test kit and `trill` CLI, checks that all versions match, and creates a **draft** release with these downloads, `SHA256SUMS` and notes from this changelog. A maintainer publishes it by hand.
- **Directional strikes** (firmware/protocol 0.5.0, simulation- and unit-tested): a tap also reports the board's direction of travel relative to gravity, and with 2, 4 or 6 directions each direction plays its own note on the percussion channel; ambiguous strikes play the plain percussion note. Off by default. Configuration page 2 (parameters 31–37) behind capability bit 5 (`0x20`); 0.4.0 hosts and firmware are unaffected. New vectors in `protocol/config-v1-vectors.txt`.
- **Apple app 0.5.0 interface**: splash, then a Home screen (plug-in prompt, "Trillium found" + Connect, optional automatic connection, current sound with input → MIDI summary and quick actions); one Presets screen for built-in and saved presets that applies immediately when connected; Settings holds Sound & mapping (reorganised as what plays the notes → notes → controllers → taps and strikes → gestures), Connection (ports), MIDI monitor, Device, Firmware and About. New built-in preset *Drum strikes*. About and status texts no longer describe version history.
- **Editing presets** (app): Edit on every preset card; changes play live on Trillium while editing (switchable). Built-in presets can be refined and saved in place (*Edited* badge, *Restore original*, export to share); New preset, Save as new, Duplicate. The editor gains section 6, *Configuration data*: every parameter by number with range and default, and the whole set as editable JSON.
- **Sensors › Overview** (app): board pose in 3D, bubble level with the tilt-note zone, turning and impact meters, position on the note range, and a strike-direction compass driven by the notes on port 1. The previous charts are under *Charts*.
- `MappingSummary` in TrillKit (plain-language input → MIDI lines) with tests.

### Changed (0.5.0)
- Firmware 0.5.0 (with the calibration fix) has been flashed on one XIAO Sense: it boots, the IMU runs at ≈ 790 samples/s (833 Hz nominal), USB MIDI works and a forced recalibration finishes in about 1 s. Directional strikes and the new app screens have not yet been tried on hardware.
- Firmware: the IMU task runs on its own interrupt executor (`EGU2_SWI2`, P7) so blocking Trill I²C reads in thread mode no longer delay IMU samples; IMU at **833 Hz** (was 416 Hz) and accelerometer **±8 g** (was ±4 g) so hard taps do not clip. Gyro calibration uses 800 samples (≈ 1 s). Worst-case motion-to-sample wait falls from ≈ 2.4 ms plus a possible 2.3 ms Trill read to ≈ 1.2 ms (calculated, not measured).
- `trill-config`: duplicate-parameter tracking widened to 64 bits (parameter IDs above 31).
- Gyro calibration judges stillness around the run's own mean (each axis within 4 dps, raw |ω| < 15 dps) instead of raw |ω| < 3 dps. Found on hardware: the first 0.5.0 build never calibrated on the user's board (bias ≈ 2.6 dps plus 833 Hz noise kept breaking the run). The sensor's zero-rate spec is ±10 dps, so the old rule could fail on any board.

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
- Docs: current design and status (`docs/current-design.md`), and Mac/iPhone connectivity research and plan (`docs/music-connectivity.md`). The Omi BLE licensing note now states its scope precisely.

### Changed
- USB layout: two MIDI cables per direction; `bcdDevice` 0x0200. Workspace version 0.3.0 (0.2.0 added configuration; `bcdDevice` stays 0x0200 because the USB layout did not change).
- XIAO Sense firmware: the on-board synth, its high-priority audio task and the PCM CDC port moved behind the optional `pcm-synth` feature. The default build renders no audio. USB PID changed from 1209:0001 to 1209:0002 (default) / 1209:0003 (`pcm-synth`).
