# Roadmap and design status

Longer-range ideas, not yet prioritized, are collected in [vision.md](vision.md).

## Design status

| Item | State |
|---|---|
| Trillium Zero (T0) ([guide](hardware/trillium-zero.md)) | One Seeed Studio XIAO nRF52840 Sense on a USB cable, USB-MIDI from the onboard IMU. Showcase starting point, and the primary development configuration to date. Firmware through 0.6.0 has run on Sense boards |
| Model T1 | T0 plus a battery and BLE. Built and tested on an early Omi DIY board. A clean T1 drawing (no extra LED or buttons) is not yet in `hardware/` |
| Model T2 (planned) | T1 plus a better LED and buttons. Not built. Revision A electronics and enclosure are filed under [`hardware/t2/`](../hardware/t2/README.md) (historical folder name) |
| Model F1 (planned) | T2 plus a Bela Trill Flex linear touch sensor. Not built. The only Flex testing to date is a breadboard T0 plus a Trill Flex. Drawings: [`hardware/f1/`](../hardware/f1/README.md) |
| Raspberry Pi wiring ([design](design-raspberry-pi.md)) | Proposal. Pins checked against Bela, Raspberry Pi docs. **Not tested on hardware** |
| XIAO nRF52840 wiring ([design](design-xiao-nrf52840.md)) | Proposal. Pins and pull-ups checked against Seeed schematics and Nordic PS; power/battery section transcribed from the Sense schematic Rev V1.1. Used as the reference for T0 optional battery notes and for breadboard Flex wiring |
| `trill-driver` | Implemented. Host-tested against datasheet byte sequences with mock I²C. Compiles for `thumbv7em-none-eabihf`. Has run against a Trill Flex on at least one Sense board (`trill=run` with firmware 0.6.0) |
| `trill` CLI (Linux) | Implemented. Host build and argument tests. Cross-built for ARMv6 and aarch64 musl. **Not run on a Pi with a sensor** |
| `lsm6ds3trc` IMU driver | Implemented from the ST datasheet. Mock-I²C tests. Has run on Sense hardware through the firmware |
| `motion-synth` | Implemented. Host test vectors and WAV demo. **No on-target timing yet** |
| `status-led` + firmware LED task | Implemented. Host tests for priority, timing, wrap and pin writes. Shipped firmware drives the on-board XIAO LED. A systematic check of indications is not recorded here. The external T2 LED has not been built |
| `instrument-events` ([mapping](midi-mapping.md)) | Implemented: single-voice touch + motion → MIDI engine, USB-MIDI encoder. Host-tested (unplug/reconnect, missing IMU, sensor loss, queue flood, note order, deadband, scaling, invalid input, timestamp wrap) |
| `trill-usb` | Implemented: USB-MIDI + CDC layout; descriptors checked by host tests. Enumeration tested on macOS with shipped firmware |
| XIAO Sense firmware ([doc](firmware-xiao-sense.md), [USB MIDI](usb-midi.md)) | Implemented: class-compliant USB-MIDI + diagnostics (default), IMU and Trill as independent tasks, Trill frame-ID filtering; debug synth + PCM stream behind `pcm-synth`. Links and passes UF2 checks in CI. Shipped firmware has run on Sense hardware |
| `trill-config` ([protocol](config-protocol.md)) | Implemented: SysEx configuration v1 on USB-MIDI cable 1; Rust and Swift codecs checked against shared vectors; firmware handler host-tested via the crate. Exercised from the Trillium app on macOS |
| Apple app ([doc](apple-app.md)) | Implemented: Mac + iPhone/iPad SwiftUI app and `TrillKit`; built unsigned and tested in CI on macOS; run against hardware on a Mac. No signing, App Store, BLE or OTA. A physical iPhone or iPad install has not been tested |
| Omi integration ([doc](omi-integration.md)) | Investigated. Decision: separate development image, Omi untouched |
| I²S output, MPE, instrument settings persistence | Not started as product features (BLE-MIDI with its two stored switches, multi-touch, the microphone test and battery monitoring are now in; see below and [battery.md](battery.md)). BLE-MIDI, device identification and a testing-only microphone path are planned below. Researched: [music-connectivity.md](music-connectivity.md) recommends host synth + USB-MIDI first, BLE-MIDI second; [microphone.md](research/microphone.md) recommends a USB PCM test path for the next release |

## Model lineup

The named models, and how a board should be described, are in the [hardware README](../hardware/README.md#model-lineup).

| Model | Meaning |
|---|---|
| **T0 — Trillium Zero** | One inexpensive part: a Seeed Studio XIAO nRF52840 Sense on a USB cable. USB-MIDI. Free open Trillium app. Suits many DIY cases |
| **T1** | T0 plus a battery and BLE |
| **T2** | T1 plus a better LED and buttons |
| **F1** | T2 plus a Bela Trill Flex linear touch sensor |

Other combinations are possible. Describe a board by its model plus a capability list (battery, BLE, LED, buttons, linear touch sensor, microphone), not by the model name alone.

## Planned terminology (UI and docs)

These are planned wording changes. They are recorded here only; **this change does not edit the app**.

- The Home page and docs should talk about **instruments** (interactive setups) and **configurations** (saved settings), not different "sounds". The Home page becomes an instrument picker. Settings such as *Sound & mapping* and *Change sound* should follow the same wording.
- The Sensors chart label **Bela** should become **Linear sensor**. Bela remains credited in the hardware docs, because the Trill Flex is the part in use.

## Device identification

Planned. The board should report what it is, rather than the app guessing.

- Firmware self-reports a **model** (unprogrammed, T0, T1, T2, F1, or another combination) and a **capability list**. Carry that in the existing configuration channel, and later in the BLE advertisement.
- The firmware can detect much of this itself (battery voltage, a Trill sensor on the I²C bus, the IMU, later the microphone). The model can also be set by hand where automatic detection is not enough.
- On every connection the Trillium app identifies the board and records it, keyed by serial number, as unprogrammed, T, or F, with its configuration. The UI then shows only what that board can do.
- Protocol 0.6.0 already reserves variant bit 2 for the microphone and reports IMU presence. That is a starting point, not a complete model report.

## BLE-MIDI and discovery

**Started:** the `ble-midi` firmware build and the app's Bluetooth MIDI pairing are in ([ble-midi.md](ble-midi.md)); separate Discoverable and Bluetooth MIDI switches (stored on the board) and battery detection are in, with Bluetooth running only when a battery is detected ([battery.md](battery.md)); hardware testing on a T1 and app-side discovery are next. BLE builds are published in public releases ([licence decision of 2026-11-19](music-connectivity.md#licensing-notes-for-ble-engineering-analysis-not-legal-advice)).

- Use standard BLE-MIDI so a Mac, iPhone, iPad or DAW sees the board as a regular MIDI port.
- **Initial configuration is over USB:** install firmware, name the board, set or confirm its model, and pair it with that Mac or iPhone.
- After that, the app finds the board wirelessly by scanning for its advertisement. Settings changes should work over BLE as well as USB.
- Latency and battery drain should be measured on a battery-powered board (the tested T1) before calling the feature done.

## Microphone (next release)

Goal for the next release, research in [microphone.md](research/microphone.md):

- A testing-only on/off switch in Trillium. It is **not** part of any instrument or configuration.
- When on, bring the Sense onboard PDM microphone into the app, show a live chart, and play the signal through the Mac audio output.
- Later: record in the app and reuse recorded audio there. MIDI from the microphone is not required initially.
- Recommended path: 16 kHz, 16-bit mono PCM over the existing USB framed-PCM style transport (CDC or equivalent), not USB Audio Class and not compressed BLE audio, for this test feature.

## Instrument pipeline

```
sensors (IMU, optional linear touch, later mic)
        ──> driver ──> frames ──> mapping ──> instrument / control output
                         (pos, size,          (pitch, gate,     (host synth, MIDI,
                          motion, …)           expression)       later BLE-MIDI)
```

1. **Acquisition:** done (`trill-driver`, IMU driver), including status-byte frame ID. Next: EVT-pin or timer-driven scanning, channel masks. Microphone acquisition is a separate test path (above).
2. **Touch tracking:** the sensor reports touches in no stable order. Planned: persistent touch IDs across frames, size-based onset and release detection, and smoothing.
3. **Mapping:** location to pitch (continuous, or quantised to a scale), size to velocity or aftertouch, number of touches to voicing. Custom flex PCBs: diff channels grouped into pads or sliders on the host.
4. **Outputs (future):**
   - **Local synth** on a Linux host through ALSA.
   - **MIDI:** USB-MIDI from the XIAO is implemented (single voice, [mapping](midi-mapping.md)); next: MPE with multi-touch tracking. ALSA sequencer on Linux.
   - **BLE (nRF52840):** standard BLE-MIDI to iPhone/iPad/Mac (licence decided 2026-11-19), after USB first-time setup ([why](music-connectivity.md#4-custom-ble-messages-gatt)). The nRF52840 has no Wi-Fi; a Wi-Fi transport would need a different host.
   - **OSC/network** from a Linux host over Wi-Fi to iPad apps.
   - **Contrail:** integration surface to be defined with the Contrail project.

## Milestones

| Version | Goal |
|---|---|
| 0.1 | Designs, driver, Linux CLI, CI and release workflow (this version) |
| 0.2 | Hardware bring-up on a Pi: record `identify`/`read` logs, confirm pin mapping and FFC orientation, mark the Pi design *validated* |
| 0.3 | XIAO Sense firmware on hardware: bring-up checklist, IMU axis signs, Trill on D4/D5, measured render time and latency. Validate the XIAO design |
| 0.4 | USB-MIDI on hardware (implemented, to be accepted: [procedure](usb-midi.md#hardware-acceptance-procedure)); touch tracking, MPE; battery voltage/charge status reading; MIDI output on Linux; latency tests ([plan](music-connectivity.md#7-plan-minimum-viable-order)) |
| 0.4.x | Apple app against hardware: two-port enumeration on Mac and iPhone, configuration round trip, preset apply; optional virtual MIDI routing in the Mac app; settings persistence on the device |
| 0.5 | BLE-MIDI from the XIAO to iPhone/iPad/Mac after the licence decision; optional I²S output and PDM mic input |
| next | Docs lineup (T0 as showcase, T1/T2/F1). Then, in separate work: terminology in the UI; device identification; testing-only microphone chart and play-through ([research](research/microphone.md)); BLE-MIDI after USB setup |
| later | Synth app for ZPOD, Contrail integration; recording and reuse of microphone audio in Trillium; microphone as an instrument input |

## ZPOD

ZPOD (Pi Zero W host) facts are recorded in the [Raspberry Pi design](design-raspberry-pi.md#zpod-host-compatibility). What remains for running Trill on ZPOD:

- Confirm physical access to header pins 1/3/5/6 inside the case, or solder to the I²C lines.
- Keep the Trill at **0x48**. Never use 0x4D, which is the PCM5122 DAC.
- Run the static `arm-unknown-linux-musleabihf` `trill` binary from a writable path, or package it as a `.zpa` app (ZPOD project).
- Sound output depends on ZPOD's planned shared-audio work, because MPD currently has exclusive use of the ALSA DAC. This repository does not modify ZPOD.
