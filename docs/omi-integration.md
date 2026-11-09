# Omi integration: evidence, reuse and licensing

Can the Trill/motion work reuse, extend or coexist with [Omi](https://docs.omi.me) on the same XIAO nRF52840 Sense, and what does each choice mean for licensing? Everything below was read from Omi's repository at commit [`28c785960fa7`](https://github.com/BasedHardware/omi/tree/28c785960fa702b1f2794f6ebe49e5829b5e8a86) (2026-11) and from docs.omi.me. Line links are pinned to that commit. **No Omi code is copied into this repository.**

## What Omi ships

| Item | Hardware | Framework | Bootloader / image | Evidence |
|---|---|---|---|---|
| **DevKit 1 / DevKit 2** firmware (`omi/firmware/devkit`) | Seeed XIAO nRF52840 **Sense** (Zephyr board `xiao_ble_sense`) | Zephyr via nRF Connect SDK **2.7.0** | Seeed/Adafruit UF2 bootloader with S140 7.3.0; app built as `zephyr.uf2` | [CMakePresets.json](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/CMakePresets.json), [Compile firmware](https://docs.omi.me/doc/developer/firmware/Compile_firmware), [Update firmware](https://docs.omi.me/doc/get_started/Flash_device) |
| **Consumer (CV1)** firmware (`omi/firmware/omi`) | Custom board, **nRF5340** | NCS 2.9.0 + sysbuild | MCUboot, signed DFU zip (not UF2) | Compile firmware doc |
| **omiGlass** | XIAO **ESP32-S3** Sense | PlatformIO / Arduino | ESP32 | [omiGlass docs](https://docs.omi.me/doc/hardware/omiGlass) |

"ESP device used as an Omi" therefore means one of two different things. An **XIAO nRF52840 Sense running DevKit firmware** is the board this repository targets. An **XIAO ESP32-S3 Sense running omiGlass** is a different CPU, and nothing in `firmware/xiao-sense` runs on it. Check which one you have: `tools/xiao_uf2.py info` on the bootloader drive (nRF52840 boards show an nRF52840 Board-ID and `SoftDevice: S140 7.3.0`). The ESP32-S3 does not present that drive.

### DevKit firmware facts (nRF52840)

| Aspect | Omi DevKit | Evidence |
|---|---|---|
| Mic | On-board PDM, CLK P1.00, DATA P0.16, power P1.10, 16 kHz, 1.28 MHz PDM clock, gain 64, 100 ms DMA buffers | [config.h](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/config.h#L3-L15), [mic.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/mic.c#L59-L68) |
| Codec | Opus 1.2.1 (vendored), CELT mode, restricted low-delay, 32 kbit/s VBR, 160-sample (10 ms) frames, codec ID **20** | [config.h](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/config.h#L18-L38), [codec.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/codec.c#L97-L99) |
| Audio service | `19B10000-E8F2-537E-4F6C-D104768A1214`: data `…0001` (read/notify), codec `…0002` (read, 1 byte), speaker `…0003` (write/notify, DevKit 2) | [transport.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/transport.c#L76-L116) |
| Packet framing | Each notification: `[packet index lo, packet index hi, fragment index]` + up to MTU−3 bytes of the codec frame | [transport.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/transport.c#L499-L594) |
| Advertising | Audio service UUID + name ("Friend" on DK1 config, "Omi DevKit 2"); scan response with DIS + Nordic legacy DFU UUID | [transport.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/transport.c#L268-L278), [DK2 conf](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf#L23) |
| Other services | Battery (BAS), DIS, Nordic legacy DFU `00001530-…`, speaker/haptic `CAB1AB95-…`, accelerometer `32403790-…` | [transport.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/transport.c#L120-L150), [speaker.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/speaker.c#L60-L63) |
| IMU | LSM6DS3TR-C via Zephyr's `st,lsm6dsl` driver on i2c0 (0x6A, INT P0.11). Feature `OMI_ENABLE_ACCELEROMETER` **defaults to off** and, when on, notifies accel + gyro **once per second** | [overlay](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/overlay/xiao_ble_sense_devkitv2-adafruit.overlay#L75-L84), [Kconfig](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/Kconfig#L22-L26), [transport.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/transport.c#L186-L205) |
| Phone app | Reads the codec characteristic: 1 → PCM8, 20 → Opus, 21 → Opus (320-sample frames); unknown values fall back to PCM8 | [omi_connection.dart](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/app/lib/services/devices/connectors/omi_connection.dart#L427-L445), [bt_device.dart](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/app/lib/backend/schema/bt_device/bt_device.dart#L39-L45) |
| Recording | DevKit 2: SD card offline storage, speaker (I²S on A1–A3) and haptics | [DK2 conf](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/prj_xiao_ble_sense_devkitv2-adafruit.conf#L204-L211), [overlay](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/overlay/xiao_ble_sense_devkitv2-adafruit.overlay#L1-L16) |

The phone link is a **custom GATT service with Opus over notifications**. It is not LE Audio and not a Bluetooth audio profile. It carries speech to the Omi app for transcription. Design latency is several connection intervals plus 10 ms codec frames plus app buffering, which suits recording and is unsuitable for live instrument audio.

## Licences, component by component

The repository root [LICENSE](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/LICENSE) is **MIT** ("Copyright (c) 2024 Based Hardware Contributors"), and [docs](https://docs.omi.me/doc/info/License) say the same. There is no `.gitmodules` and no LICENSE inside `omi/firmware`. Subdirectories with their own LICENSE files include `omi/hardware/consumer` (MIT), `omiGlass`, `plugins/*`, `sdks/python-cli`, `mcp` and `web/personas-open-source`. The repository umbrella licence does not settle what a built DevKit firmware image contains:

| Component in a DevKit build | Licence | Source of the statement |
|---|---|---|
| Omi DevKit sources (`src/*.c`, no per-file headers) | MIT (root LICENSE applies; no headers = no contrary notice) | root LICENSE |
| `src/lib/battery` | **Apache-2.0**, © 2024 Marcus Alexander Tjomsaas | [battery.c header](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/lib/battery/battery.c) |
| `src/lib/opus-1.2.1` (vendored) | **BSD-3-Clause**, © Xiph.Org, Skype, CSIRO et al. (per-file headers; the vendored copy omits Opus's COPYING file) | [celt.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/lib/opus-1.2.1/celt.c), [NSQ.c](https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit/src/lib/opus-1.2.1/NSQ.c) |
| Zephyr RTOS (fetched by west, not in repo) | Apache-2.0 | [zephyr/LICENSE](https://github.com/zephyrproject-rtos/zephyr/blob/main/LICENSE) |
| nrfx drivers | BSD-3-Clause | [nrfx/LICENSE](https://github.com/NordicSemiconductor/nrfx/blob/master/LICENSE) |
| nRF Connect SDK, incl. SoftDevice Controller (BLE link layer) | **LicenseRef-Nordic-5-Clause**: use only with Nordic ICs; binaries must not be reverse engineered | [sdk-nrf v2.7.0 LICENSE](https://github.com/nrfconnect/sdk-nrf/blob/v2.7.0/LICENSE) |
| Bootloader (`bootloader0.9.0.uf2`, prebuilt) | Not stated next to the file; upstream Adafruit nRF52 bootloader is MIT; SoftDevice S140 is under Nordic's licence | treat as ambiguous, do not redistribute |
| Omi app (`app/`), backend | MIT (root, no own LICENSE). Use of Omi's **cloud service** is governed by its terms of service, not by the code licence | root LICENSE |

Consequences for this GPL-3.0 + commercial project (engineering analysis, not legal advice):

1. **MIT, BSD-3 and Apache-2.0** code may be combined into GPL-3.0 work, with attribution and licence text kept (Apache-2.0 is GPLv3-compatible, not GPLv2-compatible). Copying such code would be allowed but would add notice duties. None has been copied.
2. **Nordic-5-Clause** components are binary-only and restricted to Nordic ICs. GPL-3.0 does not allow further restrictions on a conveyed work and requires its Corresponding Source (§§1, 7, 10). A single binary that combines **GPL-3.0-only** code from this repository with the **NCS SoftDevice Controller** (for example, our GPL modules built into Omi's firmware) is therefore at high risk of being undistributable under GPL-3.0-only alone. Whether an exception such as the System Library clause applies is a legal question we have not resolved. Routes open to the copyright holder (Nymble), for our own code only:
   - license the module for that build under **MIT** or the commercial licence;
   - add a narrowly scoped GPL §7 additional permission;
   - use an open-source BLE controller.
   
   The same question applies to adding BLE to this firmware; see [music-connectivity.md](music-connectivity.md#licensing-notes-for-ble-engineering-analysis-not-legal-advice).
3. **Permissive upstream cannot be relicensed away.** Our GPL or commercial licence covers only our code. Omi's MIT notices, the Opus BSD notices and the battery Apache-2.0 notice stay with any copy of those files.
4. **Copyleft upstream** (for example, GPL code in another project) could not be relicensed commercially without its authors' permission. No copyleft component was found in the DevKit firmware path.
5. **Facts are not copyrightable.** UUIDs, the codec ID, packet header layout and pin assignments can be implemented independently in our own code (protocol compatibility) without copying Omi source.
6. **This repository's firmware** links only crates under MIT, Apache-2.0, BSD (nrf-pac: BSD-3-Clause), Zlib or Unlicense (`cargo metadata` on `firmware/xiao-sense`). It contains no Nordic SDK code, and the SoftDevice already on the board is neither included nor enabled.

## Reuse matrix

| Omi piece | Reuse? | How |
|---|---|---|
| Hardware pin facts (PDM pins/power, IMU bus/INT, I²S A1–A3) | **Yes, as facts** | Already consistent with Seeed schematics and Zephyr board files used here |
| UF2 flash flow, S140 7.3.0, `XIAO-SENSE` drive | **Yes, as facts** | Basis of `tools/xiao_uf2.py` and the backup/restore procedure |
| BLE audio service (UUIDs, codec ID, 3-byte header) | **Later, protocol-compatible clean implementation** if phone-app compatibility is wanted | Needs a Rust BLE stack (`trouble-host` or `nrf-softdevice`) and an Opus encoder or PCM8 (codec 1). Must preserve exact UUIDs, attribute order and advertising for the app to recognise it |
| Opus 1.2.1 sources | Avoid for now | Large, C, BSD-3 notices. Only needed for Omi-app compatibility at 32 kbit/s |
| Accelerometer service | No | 1 Hz notifications, off by default: not usable for music |
| Zephyr/NCS firmware as a base (add our motion synth into Omi firmware) | Possible, with licence constraint 2 above | Our module would be C or Rust-in-Zephyr and licensed MIT/commercially for that build |
| `bootloader0.9.0.uf2` | **No** | Bootloader update. Never needed for application work |
| Omi app / backend | No (out of scope) | Separate MIT codebase plus cloud terms |

## Architecture decision

One XIAO runs one application image at a time. Omi's Zephyr firmware and this Rust firmware cannot run side by side, and the UF2 bootloader has no dual-slot boot. Options:

| Option | Omi app keeps working? | Live motion synth? | Cost / risk |
|---|---|---|---|
| A. **Separate boards**: keep one XIAO as the Omi DevKit and use a second XIAO Sense for the instrument | Yes | Yes | One extra board (inexpensive). No licence coupling |
| B. **Swap images** on one board (this repo's flow: backup → flash → restore) | Only while Omi is flashed | Only while ours is flashed | Manual reflashing. The backup must succeed first |
| C. Extend **Omi's firmware** with motion features (Zephyr) | Yes | Constrained: shares CPU and RAM with Opus encoding (~7 KB encoder state, 32 KB audio ring) and BLE | C/Zephyr work. Our code licensed MIT/commercial for that build. Live audio still has no low-latency path to the phone |
| D. **Omi-protocol-compatible Rust firmware** (our image speaks Omi's GATT service) | Partly: only what we re-implement | Yes | Needs BLE stack + Opus/PCM8 + exact service layout, plus compatibility testing against the app. Large |

**Decision:** the Rust image in `firmware/xiao-sense` is an **alternative development image**. It is **not** a drop-in Omi replacement. Keep Omi's firmware on the Omi board (option A). Use option B only with a verified backup. Revisit D only if the Omi app must receive this device's audio, and C only if one physical device must do both, accepting the licensing route in point 2.

## Staged plan

1. **Now (this repo):** standalone Rust firmware, USB diagnostics, IMU, Trill, motion synth, USB PCM test stream. Omi untouched.
2. I²S output (DevKit 2's A1–A3 wiring is a known-good reference for an amp), latency measurement on hardware.
3. Control over BLE-MIDI (phone synthesises) or USB-MIDI. Low latency, standard, no Omi coupling.
4. Optional: PDM mic capture in our firmware (16 kHz, separate buffer), for example for sound-reactive mapping.
5. Optional (D): Omi-compatible audio service as a clean Rust implementation, verified against the Omi app at a pinned app version.

## Pinned references

- Repository: <https://github.com/BasedHardware/omi/tree/28c785960fa702b1f2794f6ebe49e5829b5e8a86>
- DevKit firmware: <https://github.com/BasedHardware/omi/blob/28c785960fa702b1f2794f6ebe49e5829b5e8a86/omi/firmware/devkit>
- Docs: [Compile firmware](https://docs.omi.me/doc/developer/firmware/Compile_firmware), [Update firmware](https://docs.omi.me/doc/get_started/Flash_device), [DevKit 2](https://docs.omi.me/doc/hardware/DevKit2), [License](https://docs.omi.me/doc/info/License)
