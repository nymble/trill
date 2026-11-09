# Handoff: Trill 0.4.0 → next changes and App Store preparation

Checkpoint written 2026-11-08 (PST). Facts here were checked against the repository, PR, CI and the device at the time of writing. Re-verify anything that may have changed since (`git log`, `gh pr view 4`, `gh run list`).

## 1. Checkpoint

| Item | Value |
|---|---|
| Repository | `github.com/nymble/trill` |
| Working branch | `feature/apple-app` (open PR [#4](https://github.com/nymble/trill/pull/4) → `main`, not merged) |
| Code checkpoint (0.4.0) | `0670634afec4d345dfca9e59812d13e0fb657333`: firmware, crates and app are all 0.4.0 |
| CI for that commit | [run 42511341554](https://github.com/nymble/trill/actions/runs/42511341554): all 6 jobs green (Rust fmt/clippy/test/thumbv7em, firmware link + UF2, Apple macOS + iOS build and TrillKit tests, 2 ARM cross builds, test kit) |
| This handoff | The docs-only commit after `0670634` on the same branch (see `git log -- docs/CLAUDE_HANDOFF.md`) |
| Other open PR | #2 `docs/music-connectivity` (docs only, not merged) |
| Other remote branches | `main`, `feature/usb-midi`, `feature/xiao-sense-motion-synth` (older work, merged or superseded) |
| Tags / releases | None created for 0.4.0. No GitHub release, no App Store or TestFlight build |

**Rollback points:**
- `0670634` = 0.4.0.
- `f48b01c` = 0.3.0 app + firmware (CI green: run 42453667412).

Never force-push or rewrite pushed history. Revert with new commits.

## 2. Objective and scope

Open hardware designs and Rust software for using a **Bela Trill Flex** capacitive strip as a musical controller. The current target is a **Seeed XIAO nRF52840 Sense** (onboard LSM6DS3TR-C IMU) acting as a class-compliant USB-MIDI device. There is also a **companion app for macOS 13+ and iOS 16+** (SwiftUI + CoreMIDI) for configuration, monitoring and sensor visualisation.

**Naming (decided by Paul, 2026-11-08):**
- **The app is "Trillium"**: `Trillium.app`, display name, schemes `TrilliumMac`/`TrilliumIOS`, `Trillium.xcodeproj`, artifacts `Trillium-macOS-unsigned-dev-<v>.zip` / `Trillium-iOS-Simulator-<v>.zip`, CI artifacts `trillium-apple-apps-unsigned-dev` / `trillium-test-kit-unsigned-dev`, test kit `Trillium-<v>-<sha>`.
- **"Trill" is only Bela's sensor name.** It stays for the hardware, firmware (`xiao-sense-fw`), the USB product string `Trill XIAO MIDI (dev)` and USB IDs, the protocol, Rust crates, the `TrillKit` Swift package (kept to avoid churn), internal Swift type names, the preset format id `trill-preset`, the preset storage folder, and the repository `nymble/trill`.
- **The rename is app-only.** The firmware did not change, so the board does not need a reflash.
- **Bundle ID left as `com.nymble.trill`.** Nothing is published, and changing it is an open App Store decision for Paul (see section 9).

Licence: **GPL-3.0-only**, plus a separate commercial licence offer (`LICENSE`, `COMMERCIAL-LICENSE.md`, `NOTICE.md`). Keep that model; do not import incompatible or ambiguously licensed code.

## 3. Where to start Claude (directories)

| Place | Exists? | What |
|---|---|---|
| `~/Developer/trill` on the Mac | **No, recommended.** No repository checkout exists on the Mac today | Clone here for Claude Code |
| `~/Downloads/Trillium-0.4.0-<sha>/` | Yes (from the rename commit) | Current distribution kit (Trillium.app, UF2, tool, docs, checksums). Not a repository |
| `~/Downloads/Trill-0.4.0-0670634/` | Yes | Previous kit (app still named Trill), kept untouched |
| `~/Downloads/Trill-hwtest-20261107/` | Yes | Hardware-test tools (`tools/`) and **firmware backups** (`backup/`). Never commit or publish these |

```sh
mkdir -p ~/Developer && cd ~/Developer
git clone https://github.com/nymble/trill.git
cd trill
git checkout feature/apple-app
git log --oneline -3        # expect the handoff commit on top of 0670634
claude                      # start Claude Code in the repository root
```

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
| `apple/TrillKit` | Swift package: protocol codec, `ConfigSession`, presets, monitor, telemetry, UF2 checks. Tests in `apple/TrillKit/Tests/TrillKitTests` |
| `apple/App/{Shared,macOS,iOS}` | SwiftUI app. `apple/project.yml` (XcodeGen); the `.xcodeproj` is generated, not committed |
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

Versions move together: root `Cargo.toml`, `firmware/xiao-sense/Cargo.toml`, and `MARKETING_VERSION` in `apple/Config/Base.xcconfig` (`make test-kit` checks the app version).

## 6. Evidence: CI versus hardware

| Item | Evidence |
|---|---|
| All Rust, Swift and firmware builds and tests | CI green at `0670634` |
| 0.4.0 flashed on the user's XIAO Sense | 2026-11-08 10:52 PST, application-only |
| 0.4.0 boot, IMU (394 Hz, calibrated), MIDI up, no stalls | Hardware, read-only checks |
| HELLO: fw 0.4.0, caps `0x1b`, 30 params; page 0/1 defaults; bad page / out-of-range / unknown param / unknown action rejected, generation unchanged | Hardware, non-mutating probe |
| Telemetry 50.0 frames/s, no gaps, lease 5 s, STOP, HELLO 0.66 ms while streaming, no SysEx on Port 1 | Hardware |
| **Tilt notes, theremin, CC remap/deadzone/smoothing, tap threshold/cooldown, flick/zig-zag, orientation zero, the 35.8 min tap fix over a long run, stuck-note behaviour** | **Simulation/unit tests only. Not hardware-tested** |
| Trill Flex sensor | **Not detected** on this board (`trill=retry`); touch mode untested with a real strip |
| iPhone app on a device | Not run |

### Known issues
- **Fixed in 0.4.0, not hardware-confirmed:** tap notes stopped after 35.8 min. The cause was a signed u32 µs compare in the 1 s arm delay; it is now a latch, with tests at 37/60/72/100/150 min and a clock wrap.
- **Unresolved:** earlier "no channel 10" reports. The user saw taps once sensor output was off, so some were monitor visibility (sensor SysEx flooding the view). The app now hides Trill SysEx by default. Whether every earlier dropout is explained is **unknown**.
- **Unexplained, harmless:** after boot the firmware counted 17 ignored (non-protocol) SysEx messages. The source is unknown, and ignored messages have no effect.
- **Latency:** the user reported long tap-to-sound latency in GarageBand earlier. No firmware or app wait was found; the host audio setup was not verified.

## 7. Device facts and limits

- **Settings are RAM only.** Unplug or reset → firmware defaults (mode touch, CC A = rotation → CC74, CC B = forward tilt → CC1, taps off, gestures off). Presets live in the app.
- **Sensors:**
  - Pitch and roll from gravity; rotation speed magnitude; per-axis gyro; taps.
  - **No yaw/heading** (no magnetometer).
  - **No position.**
  - **No microphone** use.
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

Prerequisites:
- The user explicitly approves this specific flash.
- The board is in the UF2 bootloader. The user double-presses RESET; never use the 1200-baud trick.
- `INFO_UF2.TXT` shows `Board-ID: Seeed_XIAO_nRF52840_Sense`, `SoftDevice: S140 version 7.3.0`, bootloader 0.6.1.

```sh
python3 tools/xiao_uf2.py info /Volumes/XIAO-SENSE
python3 tools/xiao_uf2.py backup -o <new timestamped dir> /Volumes/XIAO-SENSE   # full + app-only + INFO; add SHA256SUMS
python3 tools/xiao_uf2.py inspect <image.uf2>        # must say application-only 0x27000..
python3 tools/xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id Seeed_XIAO_nRF52840_Sense <image.uf2>          # dry run
python3 tools/xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id Seeed_XIAO_nRF52840_Sense <image.uf2> --write  # once
```

Never write the bootloader or SoftDevice, never erase, and never overwrite existing backups. The Omi firmware/bootloader on other devices must not be touched.

Backups on the Mac, under `~/Downloads/Trill-hwtest-20261107/backup/`:

| Folder | What | Key file |
|---|---|---|
| `20261107-211802` | Original | |
| `20261108-074454-pre030` | Before 0.3.0 | |
| `20261108-105230-pre040` | 0.3.0, before 0.4.0 | `backup-20261108-105233-app-only.uf2`, sha256 `f1a66c99…ca23e` |

**Rollback to 0.3.0** = flash that app-only file with the procedure above (with approval).

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
   - The firmware page reads the UF2 drive via the user-selected file entitlement; check that review accepts this and that it is not a "write firmware" feature (it is read-only).
   - iOS: USB MIDI works through CoreMIDI (camera adapter / USB-C); test on a device.
6. **Missing assets and metadata (not in the repo):**
   - App icon set (no `.xcassets` exists).
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

1. **With the user on hardware**, exercise the 0.4.0 modes:
   - Default, Tilt scale, Theremin, Expressive controllers, Tap percussion, Flicks.
   - No stuck notes on preset change / recalibrate / unplug.
   - Taps after more than 36 min and more than 72 min.
   - Port 1 timing while telemetry streams.
   - Usability of the motion mapping (gate angle, span, smoothing, mounting direction).
   
   Fix what that finds, with tests first.
2. Connect a real Trill Flex and test touch mode.
3. App Store preparation **after** the user confirms the items in section 9:
   - Icons, privacy manifest.
   - Archive/export make targets.
   - Signed sandbox test on Mac and iPhone.
   - A licensing decision.
4. Merge PR #4 only when the user asks.

## 11. Rules for any agent

- Do not flash any device, publish, tag, release, merge, or change Apple / App Store Connect accounts without the user's explicit approval for that specific action.
- Never force-push or rewrite pushed history. Commit on `feature/apple-app` (or a new branch) and open or update PRs.
- No credentials, team IDs, device serials or firmware backups in the repository.
- Keep instrument (Port 1) output ahead of telemetry. Keep RAM-only semantics unless persistence is designed for the Omi storage partition (`0xEC000`–`0xF4000` must not be touched).
- Older firmware must never receive unsupported settings (capability bit `0x10` gates page 1 and action 5).
- Before claiming a feature works on hardware, test it on hardware and say what was tested.

## 12. Prompt to paste into Claude Code

```
Read CLAUDE.md and docs/CLAUDE_HANDOFF.md in this repository first.
Then inspect the current state yourself: git status, git log -5, gh pr view 4,
the latest CI run for feature/apple-app, and run `make ci` and `make apple-test`.
Report what you verified and any differences from the handoff.
Then propose the next changes in priority order (hardware testing plan for the
0.4.0 modes with me, fixes, then App Store preparation steps with the
questions I must answer about Apple account, signing, bundle ID and licensing).
Do not flash firmware, publish, tag, release, merge, submit to App Store Connect
or change any Apple account without my explicit approval for that specific step.
```
