# Handoff: Trillium 0.6.0 (board identification, firmware installs from the app)

Checkpoint written 2026-11-15 (PST). Facts were checked against the repository, CI and the device at the time of writing. Re-verify anything that may have changed (`git log`, `gh pr list`, `gh run list`).

## 1. Checkpoint

| Item | Value |
|---|---|
| Repository | `github.com/nymble/trill`, default branch `main` |
| Last release | [v0.5.1](https://github.com/nymble/trill/releases/tag/v0.5.1) (Grok, PR #14, merge `57ba69f`): adds the macOS DMG. **Releases are now always published (Latest), with the DMG**, not left as drafts/prereleases. v0.5.0 (`3387a11`) stays a prerelease |
| Work in progress | Branch `board-install-main` (rebased on `57ba69f`): 0.6.0 board identification and firmware installs from the app. Worktree `~/cb/scratch/trill-claude-board` |
| Local checks on that branch | `make ci` parts (fmt, clippy excl. `trill-cli`, test, tools-test, check-thumb, fw-check), protocol vectors current, `make apple-test` 66 tests, macOS and iOS Simulator builds. CI not run yet |
| Stale | Local branch `feature/board-firmware-install` (commit `122d5e4`, an earlier copy of the same work) in the main checkout; superseded by `board-install-main`, delete after the PR is open |
| Other remote branches | `docs/trillium-zero`, `docs/xiao-mcu-comparison`, `feature/app-ux-fw-0.5`, `feature/ipad-testing`, `feature/motion-play` (merged or superseded) |
| App Store / TestFlight | Nothing submitted. Apps are unsigned / ad-hoc development builds, not notarized |

**Rollback points:** `57ba69f` = 0.5.1 (released). `3387a11` = 0.5.0. `0670634` = 0.4.0. `f48b01c` = 0.3.0.

Never force-push or rewrite pushed history. Revert with new commits.

## 2. Objective and scope

Open hardware designs and Rust software for a motion and touch musical instrument: a **Seeed XIAO nRF52840 Sense** (onboard LSM6DS3TR-C IMU, no magnetometer) with an optional **Bela Trill Flex** strip, acting as a class-compliant USB-MIDI device. A **companion app, Trillium** (SwiftUI + CoreMIDI, macOS 13+, iOS/iPadOS 16+), configures the board over SysEx, shows the sensors, keeps presets, and since 0.6.0 carries and installs the firmware.

**One supported board: the XIAO nRF52840 Sense** (the model with microphone and motion sensor). The plain XIAO nRF52840 has no IMU; firmware 0.6.0 reports `imu=absent` on it and the app says the board is not supported (decided by Paul, 2026-11-14).

**Naming:** the app is **Trillium**. **Trill** is the Bela sensor, and also stays for the firmware (`xiao-sense-fw`), USB product string, protocol, Rust crates, `TrillKit`, internal Swift types, the preset format id and the repository. Bundle ID still `com.nymble.trill` (an open App Store decision, section 9).

Licence: **GPL-3.0-only**, plus a separate commercial licence offer (`LICENSE`, `COMMERCIAL-LICENSE.md`, `NOTICE.md`). Keep that model; do not import incompatible or ambiguously licensed code.

## 3. Where things are

| Place | What |
|---|---|
| `~/Developer/trill` | Main checkout. Has the user's own **uncommitted** changes (`docs/design-xiao-nrf52840.md`, `docs/roadmap.md`, `hardware/`): never touch, stage or stash them |
| A worktree for `board-install-main` | Created per session (last one was in a session scratchpad); recreate with `git worktree add <dir> board-install-main` if needed |
| `~/Downloads/Trill-hwtest-20261107/` | Hardware-test tools and **firmware backups** (`backup/`). Never commit or publish |
| `~/Library/Application Support/Trill/firmware-backups/` | Backups the app makes before each install (`<yyyyMMdd-HHmmss>-<Board-ID>/`: `CURRENT.UF2`, `INFO_UF2.TXT`, `app-only.uf2`). Never commit |

## 4. Architecture

| Path | Role |
|---|---|
| `crates/trill-driver` | `no_std` Trill I²C driver (embedded-hal 1.0) |
| `crates/lsm6ds3trc` | `no_std` IMU driver |
| `crates/motion-synth` | Gyro calibration, complementary filter (pitch/roll), tap detector; optional on-board synth |
| `crates/instrument-events` | Sensor → MIDI engine: modes, voice, controllers, taps, gestures, priority queue. Tests in `tests/engine.rs`, `tests/modes.rs` |
| `crates/trill-config` | SysEx config protocol v1 (paged settings, actions, telemetry). Vectors: `protocol/config-v1-vectors.txt`, `protocol/telemetry-v1-frames.txt` (shared with Swift) |
| `crates/trill-usb`, `crates/status-led`, `crates/trill-cli` | USB-MIDI descriptors, LED, Linux bring-up CLI |
| `firmware/xiao-sense` | Embassy firmware (own `Cargo.lock`, target `thumbv7em-none-eabihf`) |
| `apple/TrillKit` | Swift package: protocol codec, `ConfigSession`, presets, monitor, telemetry, UF2 checks, `FirmwareInstall.swift` (versions, bundled firmware manifest, backup + install to a UF2 drive). Tests in `apple/TrillKit/Tests/TrillKitTests` |
| `apple/App/{Shared,macOS,iOS}` | SwiftUI app. Firmware installs: `AppModel+Firmware.swift`, `FirmwareCard.swift`, `FirmwareView.swift`, `USBBoards.swift` (IOKit scan for boards with other firmware). Bundled firmware: `apple/Firmware/` (generated). `apple/project.yml` (XcodeGen); the `.xcodeproj` is generated, not committed |
| `tools/xiao_uf2.py` | Application-only UF2 convert/inspect/backup/flash with safety checks |
| `docs/` | `midi-mapping.md`, `config-protocol.md`, `apple-app.md`, `test-kit.md`, `firmware-xiao-sense.md`, `usb-midi.md`, `releasing.md`, `roadmap.md` |

Ports:
- **Port 1** (cable 0) = instrument MIDI.
- **Port 2** (cable 1) = configuration SysEx and sensor telemetry (dev manufacturer ID `0x7D`; development only, not for a commercial product).

## 5. Build and test (repeatable)

| What | Version / command |
|---|---|
| Rust | stable (CI installs latest stable); targets host + `thumbv7em-none-eabihf` (`rustup target add thumbv7em-none-eabihf`) |
| Xcode | CI: Xcode 16.4 (16F6), Swift 6.1.2, `macos-15` runner |
| XcodeGen | pinned **2.45.4**, zip SHA-256 `090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef` (`.github/workflows/ci.yml`) |

```sh
make ci                 # fmt-check clippy test tools-test check-thumb fw-check (fw-check builds both UF2s)
make protocol-vectors   # regenerate shared vectors after protocol changes (tests fail if stale)
make apple-test         # swift test for TrillKit (macOS: also CoreMIDI loopback tests)
make apple-project      # xcodegen generate
make apple-mac apple-ios-sim apple-dist   # unsigned builds + zips in dist/apple
make fw-uf2             # dist/xiao-sense-fw-<version>.uf2 (never written to a device)
make test-kit           # dist/Trillium-<version>-<sha>/ (needs the app zip and UF2 from the same commit)
```

Firmware bundling (0.6.0): `make apple-firmware` runs `apple/scripts/bundle_firmware.py`, which copies the UF2 into `apple/Firmware/` with `firmware.json` (version, file, sha256, board) and refuses a version that differs from `MARKETING_VERSION`. `apple-mac`, `apple-ios-sim`, `apple-ios-device` and `apple-ios-ipa` depend on it. In CI and releases the Apple job downloads the firmware artifact built from the same commit. Both files are git-ignored.

Versions move together: root `Cargo.toml`, `firmware/xiao-sense/Cargo.toml`, and `MARKETING_VERSION` in `apple/Config/Base.xcconfig` (`make test-kit` checks the app version).

## 6. Evidence: CI versus hardware

| Item | Evidence |
|---|---|
| 0.5.0 builds, tests, release artifacts | CI and release run green (v0.5.0) |
| 0.5.0 on the Sense (board 1): fw 0.5.0, IMU ~790 samples/s, calibrated | Hardware, 2026-11-12 |
| **0.6.0 app install on the Sense**: 0.5.0 → 0.6.0, one click after a RESET double-press, no file or drive picked; backup's `app-only.uf2` identical to the `xiao_uf2.py` split; reconnected with fw 0.6.0, `imu=run`, `cal=1` | Hardware, 2026-11-14, macOS, unsigned build from `board-install-main` |
| 0.6.0 (early build, before action 6) on a plain XIAO nRF52840 (board 2, bootloader 0.9.0): `imu: absent`, internal bus scan found no devices, USB MIDI up, no fault LED | Hardware, 2026-11-14 |
| **Reinstall without RESET** (action 6, Settings › Firmware › *Reinstall firmware 0.6.0*) | **Not tested.** Next hardware step |
| New Sense with Seeed's factory firmware (*New board found* card, IOKit detection) | **Not tested** |
| iOS/iPadOS install (folder picker), iPhone/iPad on a device | **Not tested** (iPad Simulator screenshots only) |
| Signed, sandboxed build (CoreMIDI access, drive entitlement) | **Not tested** |
| Motion modes (tilt notes, theremin, tilt + strike, directional strikes, gestures, CC mapping) | Simulation and unit tests; only light hands-on use |
| Trill Flex sensor | **Not detected** (`trill=retry`); touch mode untested with a real strip |

### Known issues
- CI's iPad Simulator screenshot step once hung for 55 min (cancelled; the rerun passed). Consider a timeout on that step.
- `cargo clippy` for `trill-cli` fails on macOS (pre-existing; Linux-only crate). CI runs on Linux.
- The release UF2 (Linux build) and a local macOS build of the same commit differ in sha256; compare against the `SHA256SUMS` of the artifact you use.

## 7. Device facts and limits

- **Board identification (0.6.0):** HELLO capability bit 6 (`0x40`, board report + action 6) and variant bit 1 (`0x02`, IMU fitted); variant bit 2 (`0x04`) reserved for the microphone. Sensor state `absent` = not fitted (no fault). The app reads these; older firmware has neither, so the app falls back to asking for a RESET double-press.
- **Action 6, enter bootloader:** panic-stops notes, ACKs, waits 250 ms, writes GPREGRET `0x57` and resets into the UF2 bootloader. Writes no flash.

- **Settings are RAM only.** Unplug or reset → firmware defaults (mode touch, CC A = rotation → CC74, CC B = forward tilt → CC1, taps off, gestures off). Presets live in the app.
- **Sensors:**
  - Pitch and roll from gravity; rotation speed magnitude; per-axis gyro; taps.
  - **No yaw/heading** (no magnetometer).
  - **No position.**
  - **No microphone** use (reserved in the protocol).
  - **No battery level.**
  - **No BLE-MIDI** (deferred for BLE-stack licensing).
  - **Circle/twirl gestures not implemented.**
- **Theremin mode** (actual defaults / built-in preset):
  - Gate opens at 15° forward pitch and closes below 12°.
  - Roll ±45° spans the range: preset base note 48, range 24 semitones.
  - The note is chosen at the gate, then pitch-bend follows roll.
  - Bend range ±24 is sent as RPN 0; **set the synth to ±24**.
  - Preset extras: expression CC11 mirrors tilt depth; rotation → CC74; smoothing 30 ms.
- **Tilt notes mode:** same gate and span; stepped notes with 20% hysteresis (preset 25%, pentatonic).
- **Tap:** threshold 0.80 g, cooldown 120 ms. Notes need calibration + 1 s and a connected host. The LED flashes on every tap, even with percussion off.

## 8. Firmware flashing: only with explicit user approval each time

Every install, from the app or the command line, needs the user's explicit approval for that specific install.

**From the app (normal path, 0.6.0+):** Home or Settings › Firmware offers the bundled version. On 0.6.0+ the app sends action 6; on older firmware the user double-presses RESET. When the drive mounts the app checks `INFO_UF2.TXT` (nRF52840, SoftDevice S140 7.3.0), backs up `CURRENT.UF2` plus an app-only restore image into Application Support (never overwriting), writes `TRILLIUM.UF2` (application-only, 0x27000+, validated against the manifest sha256), then waits up to 45 s for the board to reconnect with the bundled version. Unsigned builds use a temporary-exception entitlement for `/Volumes/XIAO-SENSE/`; without access the app falls back to an open panel (macOS) or folder picker (iOS).

**From the command line:**
- The board is in the UF2 bootloader: the user double-presses RESET (or the app's action 6). Never use the 1200-baud trick.
- `xiao_uf2.py info` shows the Board-ID: `Seeed_XIAO_nRF52840_Sense` (bootloader 0.6.1, board 1) or `nRF52840-SeeedXiaoSense-v1` (bootloader 0.9.0). SoftDevice S140 7.3.0.

```sh
python3 tools/xiao_uf2.py info /Volumes/XIAO-SENSE
python3 tools/xiao_uf2.py backup -o <new timestamped dir> /Volumes/XIAO-SENSE   # full + app-only + INFO; add SHA256SUMS
python3 tools/xiao_uf2.py inspect <image.uf2>        # must say application-only 0x27000..
python3 tools/xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id <Board-ID> <image.uf2>          # dry run
python3 tools/xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id <Board-ID> <image.uf2> --write  # once
```

Never write the bootloader or SoftDevice, never erase, never overwrite existing backups. Do not touch Omi firmware on other devices. Never send anything to other serial devices (e.g. a radio cable); the Trill board enumerates as `/dev/cu.usbmodem*` with product `Trill XIAO MIDI (dev)`, so check before opening a port.

Backups under `~/Downloads/Trill-hwtest-20261107/backup/` (plus the app's folder, section 3):

| Folder | Board | What |
|---|---|---|
| `20261107-211802` | 1 (Sense) | Original |
| `20261108-074454-pre030` | 1 | Before 0.3.0 |
| `20261108-105230-pre040` | 1 | 0.3.0, before 0.4.0 |
| `20261112-171922-pre050c` | 1 | 0.4.0, before 0.5.0 |
| `20261114-090744-board2-zephyr-demo` | 2 (plain XIAO) | Seeed's Zephyr/NCS demo as delivered |
| `20261114-092804-board2-pre060` | 2 | 0.5.0, before 0.6.0 |

**Rollback** = flash the backup's app-only file with the procedure above (with approval).

## 9. App Store: current reality and what must be verified

**Today:** there is **no App Store, TestFlight or notarized build**. CI produces unsigned / ad-hoc-signed development builds only, for Mac and the iOS Simulator. "A new version on the App Store" therefore means a **first submission**. All of the following are unverified and need the user (or their organisation) to confirm or provide them. Do not assume any from memory:

1. **Apple Developer Program:** enrolment (individual or organisation), team ID, and the user's App Store Connect role (Account Holder/Admin/App Manager).
2. **Bundle ID:** still `com.nymble.trill` after the rename to Trillium. Whether to keep it or move to e.g. a `…trillium` ID is Paul's decision before the first App Store record (it cannot change after publishing). It is configured (`apple/Config/Base.xcconfig`, `TRILL_BUNDLE_ID`); whether it is registered to the user's team is unknown. There is no team in the repo; `Config/Local.xcconfig` is git-ignored.
3. **App Store Connect app record(s):** macOS and iOS (or one universal purchase), name availability, SKU, pricing/free.
4. **Signing and provisioning:**
   - Distribution certificates and profiles.
   - Automatic vs manual signing.
   - An archive/export path. No `xcodebuild archive` / `-exportArchive` target exists yet; one must be added.
5. **Entitlements and sandbox:**
   - macOS has `app-sandbox` + `files.user-selected.read-write` only.
   - Verify that CoreMIDI USB-MIDI access works in a **properly signed sandboxed** build. Dev-kit testing used ad-hoc signing.
   - **Since 0.6.0 the app writes firmware** to the UF2 drive. The macOS build uses `com.apple.security.temporary-exception.files.absolute-path.read-write` for `/Volumes/XIAO-SENSE/` so installs need no picking. App Review often rejects temporary exceptions; a store build may have to drop it and rely on the open-panel fallback (already implemented). Decide before submission, and explain the firmware install in review notes.
   - iOS: USB MIDI works through CoreMIDI (camera adapter / USB-C); test on a device.
6. **Missing assets and metadata (not in the repo):**
   - App icon exists (drawn by `apple/scripts/make_app_icon.swift`); check it covers every required size.
   - Privacy manifest `PrivacyInfo.xcprivacy` and App Privacy answers.
   - Screenshots, description, support URL, privacy policy URL.
   - Age rating, export-compliance answer.
   - Review notes explaining that the hardware is required (likely a demo video for review).
7. **SysEx ID:** `0x7D` is non-commercial/development only. A commercial or store product needs its own MIDI manufacturer ID (MMA/AMEI) or a documented decision.
8. **Licensing (no legal conclusion here):**
   - App Store terms are widely considered to conflict with GPL distribution.
   - Shipping on the store likely requires distributing under the commercial licence. That requires the rights holder to hold the rights to all included code, which is to be confirmed with contributor/third-party review.
   - Check every dependency licence.
   - Get a decision from the user (and counsel if needed) before any submission.
9. **Release process:**
   - Version/build numbers (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`).
   - Changelog and a tag plan (`docs/releasing.md`). Only with approval.
   - Notarization for any direct Mac download is separate from the App Store.

## 10. Next priorities (proposed order)

1. **Hardware, with the user:** reinstall 0.6.0 without RESET (Settings › Firmware › *Reinstall firmware 0.6.0*; leave the board alone and watch it return).
2. With approval: push `board-install-main`, open the PR, get CI green, merge when the user asks. Then delete the stale `feature/board-firmware-install`.
3. Release 0.6.0 (CHANGELOG date, tag, published release with DMG) only with approval for each step. `release.yml` still creates a draft prerelease; publish it as Latest (or change the workflow to publish directly).
4. Test the *New board found* path with a factory-new Sense, and the iOS install on a device.
5. Trill Flex: find out why it is not detected; test touch mode.
6. Microphone support (variant bit 2), when wanted.
7. App Store preparation after the user decides the items in section 9 (signing, sandbox entitlement, bundle ID, licensing).

## 11. Rules for any agent

- Do not flash any device, publish, tag, release, merge, or change Apple / App Store Connect accounts without the user's explicit approval for that specific action.
- Never force-push or rewrite pushed history. Work on a branch and open or update PRs.
- No credentials, team IDs, device serials or firmware backups in the repository.
- Keep instrument (Port 1) output ahead of telemetry. Keep RAM-only semantics unless persistence is designed for the Omi storage partition (`0xEC000`–`0xF4000` must not be touched).
- Older firmware must never receive unsupported settings or actions (capability bits gate them: `0x10` page 1 and action 5, `0x20` page 2, `0x40` action 6).
- Before claiming a feature works on hardware, test it on hardware and say what was tested.
- Screenshots: capture only the app window, never the full screen, and delete them afterwards.

## 12. Prompt to paste into Claude Code

```
Read CLAUDE.md and docs/CLAUDE_HANDOFF.md in this repository first.
Then inspect the current state yourself: git status, git log -5, gh pr list,
the latest CI runs, and run `make ci` and `make apple-test`.
Report what you verified and any differences from the handoff, then propose
the next steps in priority order.
Do not flash firmware, publish, tag, release, merge, submit to App Store Connect
or change any Apple account without my explicit approval for that specific step.
```
