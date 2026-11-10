# Apple app: Trillium (macOS and iOS)

The app is named **Trillium** (bundle `Trillium.app`). *Trill* is Bela's touch-sensor product; the hardware, firmware, USB device name (`Trill XIAO MIDI (dev)`), protocol, the `TrillKit` Swift package and the repository keep the Trill name.

`apple/` contains **Trillium**, a SwiftUI companion app for Mac, iPhone and iPad. It monitors and configures the XIAO nRF52840 Sense instrument over class-compliant USB MIDI. **You do not need the app to play.** The instrument is a standard USB-MIDI device and plays straight into GarageBand, Logic, AUM or any CoreMIDI app.

> **Status:** CI builds the macOS app and the iOS app for the Simulator and for devices (compile check, unsigned). The TrillKit tests run on macOS (53 tests; this includes two CoreMIDI loopback tests against a simulated Trill on virtual endpoints) and on the iOS Simulator (same tests; the two loopback tests are skipped there because the Simulator refuses virtual MIDI endpoints, OSStatus -10844). On both, the real-firmware UF2 check is skipped unless `dist/*.uf2` was built first. Firmware 0.2.0–0.4.0 has run on one XIAO Sense from a Mac (handshake, configuration, telemetry at 50 frames/s). **The 0.5.0 screens (Home, merged Presets, Settings) have only been built and unit-tested; they have not been tried against a device, and firmware 0.5.0 has not been flashed.**

## What it does

The app has four tabs. The first three are for everyday use; everything detailed is under **Settings**.

| Screen | What it shows |
|---|---|
| Splash, then **Home** | Trillium mark and a one-line description. A connection card: **"Connect your Trillium"** (plug in the USB cable) when no instrument is on the MIDI bus; **"Trillium found"** with a **Connect** button (and an optional *Connect automatically*) when its two ports appear; then **Connected** with the firmware version. Once connected, **Current sound** names the active preset (or "Custom"), says in one sentence how the mode plays, lists each input → MIDI output, and offers *Change sound*, *Edit…*, *All notes off* and *Recalibrate* |
| **Presets** | Built-in and saved presets on one screen as cards. Choosing one applies it straight away when connected (otherwise it loads the editor). The active preset is ticked. *Save current sound…*, *Import…*, and export/delete from each saved preset's context menu. A preset that needs newer firmware says which version |
| **Sensors** | Live acceleration, rotation, pitch/roll, touch, states, events and stream health (unchanged), with plain-language banners |
| **Settings › Sound & mapping** | The full editor, in the order the signal flows: a live **What this sound does** summary (input → MIDI), then **1 What plays the notes** (mode: touch strip / tilt notes / theremin, with its own settings), **2 Notes**, **3 Motion controllers**, **4 Taps and strikes** (including strike directions and one note per direction), **5 Flick gestures**. Apply / Revert / Read from Trillium, with orange badges for values the device has not taken yet. Settings the firmware lacks are disabled with an "update the firmware" note |
| **Settings › Connection** | MIDI ports (port 1 instrument, port 2 settings), Connect / Disconnect, automatic connection |
| **Settings › MIDI monitor** | Per-channel state and a bounded log with CoreMIDI timestamps, filters and CSV export |
| **Settings › Device** | Status, MIDI panic, recalibrate, LED self-test, restore defaults (confirmed), activity log |
| **Settings › Firmware** (Mac) | Read-only UF2 assistant: validates an image and the bootloader drive, then shows the exact `tools/xiao_uf2.py` commands. **It never writes to the board** |
| **Settings › About** | What Trillium is, hardware, licence |

Protocol behaviour is unchanged: one request in flight, 1 s timeout, request IDs, boot-ID restart detection, and **nothing is sent until you connect**, either by pressing Connect or by turning on *Connect automatically*. Only the configuration pages the firmware advertises are read or written.

**Not in this version:** Bluetooth MIDI or any wireless link (the firmware has no BLE, and the app asks for no Bluetooth permission); over-the-air updates; an iPhone firmware updater; settings stored on the device (they are RAM only); microphone audio, battery level and heading (not measured by the firmware/board); host-side processing or virtual MIDI ports; MPE. Virtual endpoints are left out on purpose for now. A processed route would need an off-by-default virtual source with loop prevention, and on iOS the app's lifetime limits it.

## How it fits together

```text
Trill XIAO ──USB-MIDI──► CoreMIDI ──► DAW / synth            (no app needed)
   port 1: instrument (notes, bend, pressure, CC74, CC1)
   port 2: configuration SysEx only  ◄──► Trillium app (optional)
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
make apple-project        # apple/Trillium.xcodeproj (schemes TrilliumMac, TrilliumIOS)
open apple/Trillium.xcodeproj
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

The app icon (`apple/App/Shared/Assets.xcassets/AppIcon.appiconset`) is drawn in code: after changing `apple/scripts/make_app_icon.swift`, run `make apple-icon` and commit the PNGs. Tagged versions are packaged as GitHub Releases ([releasing.md](releasing.md)).

## Run and install

**Mac, from Xcode:**
1. Select the **TrilliumMac** scheme and press Run.
2. The project signs Mac builds ad hoc ("Sign to Run Locally"), so no account is needed.
3. The app runs in the App Sandbox. Its only entitlement is access to files you pick in open/save dialogs.

**iPhone/iPad, from Xcode:**
1. Add your Apple ID in *Xcode › Settings › Accounts*.
2. Copy `apple/Config/Local.xcconfig.example` to `apple/Config/Local.xcconfig`. That file is git-ignored.
3. In it, set `DEVELOPMENT_TEAM` to your team ID. If `com.nymble.trill` is not available to your team, set `TRILL_BUNDLE_ID` to your own reverse-DNS ID. Run `make apple-project` again afterwards. Alternatively, choose the team in *Signing & Capabilities* for this session only.
4. Connect the device, enable *Settings › Privacy & Security › Developer Mode*, select the **TrilliumIOS** scheme and the device, then press Run.
5. With a free Personal Team the provisioning profile expires after about a week, and Apple limits how many apps and devices it can be used with. Re-run from Xcode to renew it. A paid membership removes these limits but is not needed for development.

No team, certificate or profile is committed, and CI never signs.

**CI artifacts:** the workflow artifact `trillium-apple-apps-unsigned-dev` holds:
- `Trillium-macOS-unsigned-dev-<version>.zip`: the macOS app. It is not notarized and carries only the linker's ad-hoc signature, so entitlements (sandbox) are not applied. Gatekeeper blocks it after download. Only if you trust the build and its checksum: on macOS 15 try to open it once, then use *System Settings › Privacy & Security › Open Anyway*; on macOS 13/14 use *right-click › Open*; or run `xattr -dr com.apple.quarantine Trillium.app`.
- `Trillium-iOS-Simulator-<version>.zip`: for the Simulator only. Install it with `xcrun simctl install booted Trillium.app`. It cannot be installed on a device.
- `README.txt` with this disclaimer, and `SHA256SUMS` (for the zips).

**Test kit:** the artifact `trillium-test-kit-unsigned-dev` holds `Trillium-<version>-<commit>.zip`: the macOS app zip and the application-only firmware UF2 from the same CI run, `tools/xiao_uf2.py`, docs, `MANIFEST.txt` and `SHA256SUMS` ([kit README](test-kit.md)). Locally on a Mac: `make apple-mac apple-dist fw-uf2 test-kit`.

There is no App Store or TestFlight build. The code is GPL-3.0-only, and App Store distribution of GPL software has known licence conflicts, so any store release would need a decision under the commercial licence ([COMMERCIAL-LICENSE.md](../COMMERCIAL-LICENSE.md)).

## Using it

1. Plug in Trillium. Home changes from "Connect your Trillium" to "Trillium found".
2. Press **Connect** (or turn on *Connect automatically*). Home shows the current sound.
3. **Presets:** choose a sound; it is sent immediately.
   - **Edit** (on every card) opens the preset in the editor. With *Play changes on Trillium as you edit* on (the default), each change is sent as you make it.
   - Built-in presets are refined in place: **Save** keeps your version, marked *Edited*, and *Restore original* brings back the shipped one. Export an edited built-in to send it in for the next release.
   - Your own presets: **New preset** starts from the current sound; **Save as new…** in the editor makes a copy of anything; right-click (or touch and hold) a card to duplicate, export or delete.
4. **Settings › Sound & mapping** is the same editor for the current sound. Section 6, *Configuration data*, lists every parameter by number with its range, and *Edit as text (JSON)* edits the whole set in the preset file format. Settings last until the instrument is unplugged; presets keep them on the Mac or iPhone.
   - Theremin: set your synth's pitch-bend range to the value shown (default ±24).
   - Strike directions (firmware 0.5.0+): with 2, 4 or 6 directions, the direction Trillium moves when it is stopped picks the note; an unclear strike plays the "unclear direction" note.
   - Not available: circle/twirl gestures, heading (no magnetometer) and position.
5. **Sensors › Overview:** the board drawn tilting like the real one, a bubble level (with the note zone in tilt modes), turning and impact meters against the sound's settings, where the current tilt or touch falls on the note range, and a compass that lights up the direction of each strike (read from the notes on port 1). **Charts** has the raw acceleration, gyro and orientation plots, stream health and CSV export. The banner says whether data is live, stale, paused or unsupported.
6. **Settings › MIDI monitor:** watch what the instrument sends on port 1. Trill sensor SysEx is hidden by default so tap notes stay visible.

Firmware requirements: settings and the monitor need 0.2.0+, Sensors 0.3.0+, modes/controllers/gestures 0.4.0+, strike directions 0.5.0+. On older firmware the matching controls are disabled and never sent.

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

Import rejects files that are the wrong format or version, have unknown keys, or have out-of-range values. Missing keys take the firmware defaults, so 0.3.0 presets load in 0.4.0 unchanged. Presets saved by app 0.4.0 include the page-1 keys (`mode`, `cc_a_source`, `cc_a_number`, `cc_b_source`, `cc_b_number`, `cc_deadzone_percent`, `cc_smoothing_ms`, `tilt_span_deg`, `gate_deg`, `step_hysteresis_percent`, `expression_cc`, `tap_threshold_cg`, `tap_cooldown_ms`, `gesture_axis`, `gesture_threshold_dps`, `gesture_cooldown_ms`, `gesture_base_note`), so app 0.3.0 rejects them as unknown keys. App 0.5.0 adds the page-2 keys `strike_directions` and `strike_note_down`/`_up`/`_left`/`_right`/`_forward`/`_back`; app 0.4.0 rejects such files as unknown keys. Presets are stored in the app's own container (`Application Support/Trill/presets.json`); refined built-ins in `builtin-edits.json` beside it (one preset per built-in, named by its id).
