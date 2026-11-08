# Apple app (macOS and iOS)

`apple/` contains **Trill**, a SwiftUI companion app for Mac, iPhone and iPad. It monitors and configures the XIAO nRF52840 Sense instrument over class-compliant USB MIDI. **You do not need the app to play.** The instrument is a standard USB-MIDI device and plays straight into GarageBand, Logic, AUM or any CoreMIDI app.

> **Status:** CI builds the macOS app and the iOS app for the Simulator and for devices (compile check, unsigned). The TrillKit tests run on macOS (41 tests; this includes two CoreMIDI loopback tests against a simulated Trill on virtual endpoints) and on the iOS Simulator (same tests; the two loopback tests are skipped there because the Simulator refuses virtual MIDI endpoints, OSStatus -10844). On both, the real-firmware UF2 check is skipped unless `dist/*.uf2` was built first. Firmware 0.2.0 has run on a real XIAO Sense with a hardware harness on a Mac (handshake, set/readback/restore, errors, panic, and an ERROR UnknownType answer to the 0.3.0 telemetry request). **Sensor telemetry (firmware 0.3.0) and the app's Sensors tab have not yet run on hardware.** Configuration needs firmware 0.2.0 or newer; the Sensors tab needs 0.3.0 or newer.

## What it does

| Area | Implemented | Notes |
|---|---|---|
| Endpoints | Lists MIDI sources and destinations and follows hot-plug (CoreMIDI setup notifications). Shows device name, port number and offline state | Suggests the Trill's port 1 for monitoring and port 2 for configuration. **Sends nothing until you press Connect**, and then only to the one destination you selected |
| Sensors | Live acceleration (X/Y/Z, \|a\|, g), rotation rate (°/s), pitch/roll, Trill touch position and size, IMU/calibration/safe-mode state, tap and calibration events, IMU rate (device clock), frame rate, sequence gaps, skipped/dropped frames, data age. 10 s rolling charts redrawn at 30 Hz, pause/reset, CSV export | Needs firmware 0.3.0+ ([telemetry](config-protocol.md#sensor-telemetry-firmware-030)); older firmware gets an explanation, not empty charts. Streams only while the tab is open (lease renewed every ~2 s). Series are labelled and dashed, not colour-only. Lines break at gaps and invalid samples and stop at the last real frame. "Trill not detected" is shown separately from "no touch". Microphone, battery and yaw are listed as unavailable |
| MIDI monitor | Notes, pitch bend (in semitones), channel pressure, CC74 and CC1 per channel, plus a bounded log (2000 events) with CoreMIDI timestamps, port, channel and decoded names | Real-time/clock filter (still counted), events/s, SysEx counts and summaries (first 24 bytes), pause, clear, CSV export. Never routes MIDI anywhere |
| Configuration | Handshake, read and apply the 13 mapping parameters ([protocol](config-protocol.md)), with "device:" badges for values not yet acknowledged | One request in flight, 1 s timeout, request IDs. Detects a device restart from its boot ID |
| Actions | MIDI panic, gyro recalibration, LED self-test, restore defaults (with confirmation) | Each is a real firmware command and is acknowledged |
| Presets | Named presets saved in the app, JSON export and import through the system file dialogs | Ranges are validated on import. Loading a preset fills the editor; **Apply** sends it |
| Firmware (Mac only) | Read-only assistant: validates a UF2 you pick, reads `INFO_UF2.TXT` from the bootloader drive you pick, then shows the exact `tools/xiao_uf2.py` commands with Copy buttons | **It never writes to the board.** The checks are the same as in `xiao_uf2.py`: nRF52840 family, application window `0x27000–0xEC000`, vector table, bootloader images refused, SoftDevice S140 7.3.0. SHA-256 is an integrity check, not a signature |

**Not in this version:** Bluetooth MIDI or any wireless link (the firmware has no BLE, and the app asks for no Bluetooth permission); over-the-air updates; an iPhone firmware updater; settings stored on the device (they are RAM only); microphone audio, battery level and heading (not measured by the firmware/board); host-side processing or virtual MIDI ports; MPE. Virtual endpoints are left out on purpose for now. A processed route would need an off-by-default virtual source with loop prevention, and on iOS the app's lifetime limits it.

## How it fits together

```text
Trill XIAO ──USB-MIDI──► CoreMIDI ──► DAW / synth            (no app needed)
   port 1: instrument (notes, bend, pressure, CC74, CC1)
   port 2: configuration SysEx only  ◄──► Trill app (optional)
```

- **TrillKit** (`apple/TrillKit`, Swift package, Apple frameworks only) holds:
  - the protocol codec;
  - a UMP decoder (CoreMIDI delivers MIDI 1.0 as Universal MIDI Packets and has already resolved running status; SysEx7 is reassembled with a hard 256-byte limit, or 64 bytes on the configuration port);
  - the monitor model and the configuration session state machine;
  - presets and the UF2 / `INFO_UF2.TXT` validators;
  - the CoreMIDI adapter `MIDIClient`.
- **Threading:**
  - CoreMIDI delivers input on its own high-priority thread.
  - The monitor port only decodes and appends to a bounded, locked buffer (4096 events). The UI drains it 30 times a second and keeps the last 400 events, so a dense stream cannot flood the main thread.
  - Configuration replies are dispatched to the main queue; they are rare.
- **Timestamps** are CoreMIDI host times converted with `mach_timebase_info`. They are monotonic seconds since boot, shown relative to the first event, not wall-clock time.
- **Ports and connections:**
  - The adapter creates two input ports (monitor and config) and one output port.
  - Each input port is connected to exactly one selected source.
  - Output goes only to the selected destination (`MIDISendEventList`).
  - The app creates no virtual endpoints and forwards nothing, so it cannot form a MIDI loop. The firmware also ignores reply-typed messages.
- **iOS background:**
  - The app declares no background modes, so iOS may suspend it in the background. Monitoring and configuration then pause.
  - The instrument keeps playing into other apps, because that path does not involve this app.
  - The app does not run an audio session to stay awake.

## Requirements

| To | You need |
|---|---|
| Run on a Mac | macOS 13 Ventura or newer, Apple Silicon or Intel (the Release build is universal) |
| Run on iPhone/iPad | iOS/iPadOS 16 or newer. A USB-C cable, or Apple's Lightning to USB 3 Camera Adapter with power ([USB MIDI](usb-midi.md#hardware-acceptance-procedure)) |
| Build | Xcode 16 or newer (CI: Xcode 16.4 on macOS 15) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.4 (`brew install xcodegen`, or the pinned, checksum-checked download in `.github/workflows/ci.yml`). `make` and `python3` from the Xcode Command Line Tools |
| Simulator or your own Mac | No Apple Developer Program membership |
| Your own iPhone/iPad | An Apple ID added in Xcode (a free Personal Team works) and Developer Mode on the device |

## Build

The Xcode project is generated from `apple/project.yml` and is not committed:

```sh
make apple-project        # apple/Trill.xcodeproj (schemes TrillMac, TrillIOS)
open apple/Trill.xcodeproj
```

The same builds CI runs (unsigned, `CODE_SIGNING_ALLOWED=NO`, output in `build/apple`):

```sh
make apple-test           # TrillKit tests on this Mac (incl. CoreMIDI loopback)
make apple-test-ios-sim   # TrillKit tests on an available iPhone Simulator
make apple-mac            # Release, universal macOS app
make apple-ios-sim        # iOS app for the Simulator
make apple-ios-device     # iOS app for devices: compile check only, NOT an installable IPA
make apple-dist           # dist/apple/*.zip + SHA256SUMS
make apple                # all of the above (except the Simulator tests)
```

On Linux, `make apple-test` runs the platform-independent TrillKit tests (protocol vectors, UMP, session, presets, UF2). That proves nothing about SwiftUI or CoreMIDI, which only build on macOS.

## Run and install

**Mac, from Xcode:**
1. Select the **TrillMac** scheme and press Run.
2. The project signs Mac builds ad hoc ("Sign to Run Locally"), so no account is needed.
3. The app runs in the App Sandbox. Its only entitlement is access to files you pick in open/save dialogs.

**iPhone/iPad, from Xcode:**
1. Add your Apple ID in *Xcode › Settings › Accounts*.
2. Copy `apple/Config/Local.xcconfig.example` to `apple/Config/Local.xcconfig`. That file is git-ignored.
3. In it, set `DEVELOPMENT_TEAM` to your team ID. If `com.nymble.trill` is not available to your team, set `TRILL_BUNDLE_ID` to your own reverse-DNS ID. Run `make apple-project` again afterwards. Alternatively, choose the team in *Signing & Capabilities* for this session only.
4. Connect the device, enable *Settings › Privacy & Security › Developer Mode*, select the **TrillIOS** scheme and the device, then press Run.
5. With a free Personal Team the provisioning profile expires after about a week, and Apple limits how many apps and devices it can be used with. Re-run from Xcode to renew it. A paid membership removes these limits but is not needed for development.

No team, certificate or profile is committed, and CI never signs.

**CI artifacts:** the workflow artifact `trill-apple-apps-unsigned-dev` holds:
- `Trill-macOS-unsigned-dev-<version>.zip`: the macOS app. It is not notarized and carries only the linker's ad-hoc signature, so entitlements (sandbox) are not applied. Gatekeeper blocks it after download. Only if you trust the build and its checksum: on macOS 15 try to open it once, then use *System Settings › Privacy & Security › Open Anyway*; on macOS 13/14 use *right-click › Open*; or run `xattr -dr com.apple.quarantine Trill.app`.
- `Trill-iOS-Simulator-<version>.zip`: for the Simulator only. Install it with `xcrun simctl install booted Trill.app`. It cannot be installed on a device.
- `README.txt` with this disclaimer, and `SHA256SUMS` (for the zips).

**Test kit:** the artifact `trill-test-kit-unsigned-dev` holds `Trill-<version>-<commit>.zip`: the macOS app zip and the application-only firmware UF2 from the same CI run, `tools/xiao_uf2.py`, docs, `MANIFEST.txt` and `SHA256SUMS` ([kit README](test-kit.md)). Locally on a Mac: `make apple-mac apple-dist fw-uf2 test-kit`.

There is no App Store or TestFlight build. The code is GPL-3.0-only, and App Store distribution of GPL software has known licence conflicts, so any store release would need a decision under the commercial licence ([COMMERCIAL-LICENSE.md](../COMMERCIAL-LICENSE.md)).

## Using it

1. **Load firmware 0.3.0 or newer** for the Sensors tab ([loading](firmware-xiao-sense.md#loading-over-usb-explicit-steps-only)); 0.2.0 is enough for configuration and the MIDI monitor. Firmware before 0.2.0 has one MIDI port and ignores configuration. The handshake then times out and the app says so.
2. Plug in the Trill. Audio MIDI Setup shows `Trill XIAO MIDI (dev)` with two ports.
3. **Device tab:**
   - The monitor source is preselected to port 1. The configuration source and destination are preselected to port 2.
   - Press **Connect**. The status shows the firmware version, the protocol, and "Settings are kept in device RAM only".
4. **Mapping tab:** load a built-in preset or edit, then press **Apply to device**. Orange "device:" badges show what the device last acknowledged. Sounding notes are released and changed controllers return to 0 when a change is applied.
   - **Built-in presets:** Default (touch + motion), Tilt scale, Theremin, Expressive controllers, Tap percussion, Flick gestures (experimental). Loading only fills the editor.
   - **Sensor mode** (touch / tilt notes / theremin), **controllers A and B** (source, CC number, deadzone, smoothing), **tap sensitivity and cooldown**, **flick gestures** (off by default) and **Set current orientation as level** need firmware 0.4.0. With 0.3.0 or older they are disabled, the tab says so, and the app never sends them (the device would reject the whole request). They are tested against simulated devices only, not on hardware yet.
   - Theremin: set your synth's pitch-bend range to the value shown (default ±24).
   - Circle and twirl gestures, yaw/heading and position are not available (no magnetometer, and position cannot be tracked from this IMU).
5. **Presets:** keep mappings across device restarts. Export or import them as `.trill.json` files.
6. **Sensors tab:** move the board and watch acceleration, rotation and orientation; touch the Trill. The banner says whether data is live, stale, paused (the device keeps streaming) or unsupported.
7. **MIDI tab:** watch and log what the instrument sends. Pick **port 1** as the monitor source (Device tab): it carries the instrument notes and controllers. Port 2 carries only configuration and the 50 Hz sensor stream. Trill sensor SysEx is counted but hidden from the log by default ("Hide Trill sensor SysEx"), so tap notes stay visible while the Sensors tab streams. The channel picker only chooses which channel's state is *displayed*. The line under it shows the channels the device *sends* on (notes on the touch channel, taps and flicks on the percussion channel, 10 by default) and the channels that actually had activity.

   In a DAW (GarageBand, Logic): enable the `…Port 1` input (GarageBand: Settings › Audio/MIDI; Logic: MIDI inputs, all enabled by default), put a software-instrument track in record/monitor, and for taps use a drum kit on, or a track receiving, channel 10. Port 2 should not be routed to an instrument.

A diagnostics terminal (`screen /dev/cu.usbmodem…`) is optional. The protocol does not use it.

## Presets

```json
{
  "format" : "trill-preset",
  "id" : "…",
  "name" : "Lead",
  "protocol_version" : 1,
  "values" : { "base_note" : 48, "bend_range_semitones" : 24, "channel" : 0, "motion_enabled" : 1, "percussion_channel" : 9, "percussion_enabled" : 0, "percussion_note" : 39, "pitch_mode" : 0, "range_semitones" : 24, "rotation_full_dps" : 360, "scale" : 0, "tilt_full_deg" : 60, "velocity_min" : 30 },
  "version" : 1
}
```

Import rejects files that are the wrong format or version, have unknown keys, or have out-of-range values. Missing keys take the firmware defaults, so 0.3.0 presets load in 0.4.0 unchanged. Presets saved by app 0.4.0 include the page-1 keys (`mode`, `cc_a_source`, `cc_a_number`, `cc_b_source`, `cc_b_number`, `cc_deadzone_percent`, `cc_smoothing_ms`, `tilt_span_deg`, `gate_deg`, `step_hysteresis_percent`, `expression_cc`, `tap_threshold_cg`, `tap_cooldown_ms`, `gesture_axis`, `gesture_threshold_dps`, `gesture_cooldown_ms`, `gesture_base_note`), so app 0.3.0 rejects them as unknown keys. Presets are stored in the app's own container (`Application Support/Trill/presets.json`).
