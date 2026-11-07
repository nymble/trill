# Roadmap and design status

## Design status

| Item | State |
|---|---|
| Raspberry Pi wiring ([design](design-raspberry-pi.md)) | Proposal. Pins checked against Bela, Raspberry Pi docs. **Not tested on hardware** |
| XIAO nRF52840 wiring ([design](design-xiao-nrf52840.md)) | Proposal. Pins and pull-ups checked against Seeed schematics and Nordic PS. **Not tested on hardware** |
| `trill-driver` | Implemented. Host-tested against datasheet byte sequences with mock I²C. Compiles for `thumbv7em-none-eabihf`. **Not run against a sensor** |
| `trill` CLI (Linux) | Implemented. Host build and argument tests. Cross-built for ARMv6 and aarch64 musl. **Not run on a Pi with a sensor** |
| `lsm6ds3trc` IMU driver | Implemented from the ST datasheet. Mock-I²C tests. **Not run against a sensor** |
| `motion-synth` | Implemented. Host test vectors and WAV demo. **No on-target timing yet** |
| XIAO Sense firmware ([doc](firmware-xiao-sense.md)) | Implemented: USB diagnostics, IMU, Trill, audio-rate synth, USB PCM test stream. Links for nRF52840 and passes UF2 checks in CI. **Never flashed or run** |
| Omi integration ([doc](omi-integration.md)) | Investigated. Decision: separate development image, Omi untouched |
| I²S output, MIDI, BLE, mobile apps | Not started |

## Instrument pipeline

```
Trill Flex ──I²C──> driver ──> touch frames ──> mapping ──> sound / control output
 (30 ch)         (centroid      (pos 0..1,     (pitch, gate,   (local synth, MIDI,
                  or diff)       size, n)        expression)     BLE, OSC …)
```

1. **Acquisition:** done (`trill-driver`). Next: status-byte frame ID, EVT-pin or timer-driven scanning, channel masks.
2. **Touch tracking:** the sensor reports touches in no stable order. Planned: persistent touch IDs across frames, size-based onset and release detection, and smoothing.
3. **Mapping:** location to pitch (continuous, or quantised to a scale), size to velocity or aftertouch, number of touches to voicing. Custom flex PCBs: diff channels grouped into pads or sliders on the host.
4. **Outputs (future):**
   - **Local synth** on a Linux host through ALSA.
   - **MIDI:** USB-MIDI or ALSA sequencer on Linux. MPE suits multi-touch expression.
   - **BLE (nRF52840):** BLE-MIDI or a custom GATT service to iPhone/iPad. The nRF52840 has no Wi-Fi; Wi-Fi transport would need a different host.
   - **OSC/network** from a Linux host over Wi-Fi to iPad apps.
   - **Contrail:** integration surface to be defined with the Contrail project.

## Milestones

| Version | Goal |
|---|---|
| 0.1 | Designs, driver, Linux CLI, CI and release workflow (this version) |
| 0.2 | Hardware bring-up on a Pi: record `identify`/`read` logs, confirm pin mapping and FFC orientation, mark the Pi design *validated* |
| 0.3 | XIAO Sense firmware on hardware: bring-up checklist, IMU axis signs, Trill on D4/D5, measured render time and latency. Validate the XIAO design |
| 0.4 | I²S audio output, touch tracking, USB-MIDI; MIDI output on Linux |
| 0.5 | BLE-MIDI from the XIAO to iPhone/iPad; optional PDM mic input |
| later | Synth app for ZPOD, Contrail integration |

## ZPOD

ZPOD (Pi Zero W host) facts are recorded in the [Raspberry Pi design](design-raspberry-pi.md#zpod-host-compatibility). What remains for running Trill on ZPOD:

- Confirm physical access to header pins 1/3/5/6 inside the case, or solder to the I²C lines.
- Keep the Trill at **0x48**. Never use 0x4D, which is the PCM5122 DAC.
- Run the static `arm-unknown-linux-musleabihf` `trill` binary from a writable path, or package it as a `.zpa` app (ZPOD project).
- Sound output depends on ZPOD's planned shared-audio work, because MPD currently has exclusive use of the ALSA DAC. This repository does not modify ZPOD.
