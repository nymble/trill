# Onboard microphone: constraints and a path for the next release

Question: how should the Seeed Studio XIAO nRF52840 Sense onboard PDM microphone be brought into the Trillium app, first as a testing feature (live chart and play-through on a Mac) and later for recording and reuse? This note looks at the microphone part, the nRF52840 PDM peripheral, RAM, USB and BLE transports, latency, CPU and power, and the Mac-side audio APIs.

Sources were checked on **2026-11-17** and are listed at the end as [S1]–[S20]. Every numeric figure is labelled as one of:

- *specification*: a value from a manufacturer datasheet or product specification;
- *calculation*: arithmetic from a spec or a configuration;
- *library behaviour*: what a named library implements, which may go beyond the official specification;
- *third-party measurement*: someone else's figure, not ours;
- *target*: a goal for our tests.

**No figure is our own measurement.** The PDM microphone is not used by the current Trill firmware ([S19]).

## Recommendation in brief

For the **next release**, add a testing-only on/off switch in Trillium that is **not** part of any instrument or configuration. When the switch is on, the firmware powers the microphone, captures **16 kHz, 16-bit mono PCM**, and sends it to the app over USB as a framed PCM stream in the same style as the existing `pcm-synth` debug port. The app draws a live chart and plays the signal through the Mac audio output with `AVAudioEngine`. MIDI from the microphone is not required for this step. Recording and reuse of that audio in the app come after the test path works.

Do **not** add USB Audio Class 1, and do **not** send microphone audio over BLE, in this first step.

Why this path:

- The nRF52840 PDM hardware is specified for 16 kHz, 16-bit PCM, with EasyDMA into RAM ([S4]). Omi's DevKit firmware already uses 16 kHz and a 1.28 MHz PDM clock on this same board ([S11]).
- 16-bit mono at 16 kHz is 32 kB/s (*calculation*). USB full speed is 12 Mbit/s with 1 ms frames ([S5]); 32 bytes per frame is a small load next to the existing USB-MIDI and CDC interfaces.
- The repository already has a framed PCM-over-CDC path and a host capture tool, used today for the optional debug synth, not for the microphone ([S19]).
- The pinned `embassy-usb` 0.6.0 exposes a UAC 1.0 **speaker** class only, not a microphone/source class ([S13]). Adding a class-compliant USB microphone would mean writing descriptors or upgrading the crate, and it would change the composite device that already enumerates as USB-MIDI. That risk is not worth it for a test switch.
- Raw 16 kHz PCM over BLE is 256 kbit/s (*calculation*). Omi compresses to Opus at 32 kbit/s with 10 ms frames on a custom GATT service, which suits recording and is not a low-latency instrument path ([S11]). BLE audio is a later, wireless concern, not the next release.

## 1. Goal

| Now (next release) | Later |
|---|---|
| Testing-only on/off switch in Trillium, not attached to an instrument | Record in the app and reuse the recording there (loops, playback, maybe mapping) |
| Live waveform or level chart in the Sensors views | Optional on-board features (level, onsets, later pitch) as MIDI or telemetry |
| Play-through on the Mac audio output | iOS play-through and recording |
| USB only, MIDI not required to run at the same time | Decide whether a class-compliant USB microphone or a BLE compressed path is wanted |

When the switch is off, the microphone should be powered down (the Sense board has a dedicated enable pin, [S2][S10][S19]).

## 2. The microphone and the PDM pins

The Sense board (not the non-Sense XIAO nRF52840) carries an onboard digital PDM microphone ([S1][S2]). Pins used in this repository and in Zephyr agree ([S10][S19]):

| Function | nRF52840 pin | Notes |
|---|---|---|
| PDM clock | P1.00 | Driven by the nRF52840 PDM peripheral |
| PDM data | P0.16 | From the microphone |
| Microphone power | P1.10 | Active high, high-drive output in the Zephyr board file |

**Part number.** The Seeed Sense schematic Rev V1.1 labels MIC1 as **MSM261D3526H1CPM** ([S3]). Zephyr's `xiao_ble_nrf52840_sense` board file names the enable regulator `MSM261D3526HICPM-C-EN` ([S10]). Seeed's product-page documents include a file named `mic-MSM261D3526H1CPM` ([S1]). That is the part this note uses for electrical and acoustic figures.

The Seeed XIAO nRF52840 series wiki resource list, as retrieved on 2026-11-17, also names a datasheet **Mic-WMM7035DTTJ0** ([S2]). A production change or a wiki substitution has not been confirmed here. **Unknown:** which part is fitted on a given board, and whether the two parts are equivalent. Confirm on hardware (marking or a current Seeed PCN) before treating acoustic figures as final.

MSM261D3526H1CPM figures, from the Memsensing datasheet V1.2 ([S6]), *specification*:

| Item | Value |
|---|---|
| Output | PDM, omnidirectional, top port |
| Supply | 1.6–3.6 V (the Sense board powers it from the switched 3.3 V rail) |
| Standard-performance clock | 1.1–4.0 MHz (test condition 2.4 MHz) |
| Low-power clock | 150–900 kHz (test condition 768 kHz) |
| Sleep | clock ≤ 50 kHz, typ. 1 µA |
| Standard mode | typ. 670 µA at 2.4 MHz; sensitivity typ. −26 dBFS at 94 dB SPL, 1 kHz; SNR typ. 64 dB(A); AOP typ. 120 dB SPL |
| Low-power mode | typ. 290 µA at 768 kHz; SNR typ. 62 dB(A) |
| Wake-up | typ. max 200 µs after the clock is ≥ 151 kHz; power-up typ. 6 ms, max 20 ms after VDD is valid |

**Clock-mode warning.** The official 16 kHz nRF52840 setting uses a 1.280 MHz PDM clock ([S4]; see below). 1.280 MHz lies inside the microphone's standard-performance range (1.1–4.0 MHz), so the part should be in standard mode. It is not the 2.4 MHz test condition, so the 64 dB(A) SNR and 670 µA current are not guaranteed at 1.280 MHz. The alternative official clock, 1.032 MHz (RATIO 64), sits in the gap between low-power (≤ 900 kHz) and standard (≥ 1.1 MHz) and should **not** be used.

## 3. The nRF52840 PDM peripheral

From the nRF52840 Product Specification ([S4]), *specification*:

- One PDM interface; one or two microphones on the same data line (left/right edges).
- Hardware decimation to **16-bit PCM**.
- The feature list gives a **16 kHz output sample rate**.
- RATIO of 64 or 80 between PDM_CLK and the output sample rate.
- EasyDMA into a RAM buffer. The application must swap the destination pointer when a buffer fills.
- Digital gain, −20 dB to +20 dB around a default of typ. 3.2 dB.
- Decimation filter delay **t<sub>PDM,DATA</sub>**, max **5 ms**.
- Documented PDM clocks: typ. 1.032 MHz (`PDMCLKCTRL` default, for 16 kHz at RATIO 64) and typ. 1.280 MHz (`1280K`, for 16 kHz at RATIO 80).

The Sense board has a single microphone, so the peripheral should run in mono and the edge should be chosen to match the part's L/R tying (not verified on a board here).

**16 kHz** is the rate this note recommends. It is the rate the Product Specification documents, and it is the rate Omi uses on this board (1.28 MHz clock, gain 64 in their firmware, 100 ms DMA buffers, [S11]).

**Other rates.** The Arduino / Seeed PDM library accepts 16 000 and 41 667 Hz only ([S7][S8]). 41 667 Hz is *library behaviour*: `PDMCLKCTRL = 0x15000000` (32 MHz / 12 ≈ 2.667 MHz) with RATIO 64. 2.667 MHz is inside the microphone's standard-performance range and is closer to the 2.4 MHz test condition. Those higher `PDMCLKCTRL` values are not in the Product Specification's enumerated list ([S4][S9]). They may be useful later if 16 kHz sounds dull; they are not the conservative first setting.

The firmware already depends on `embassy-nrf` 0.11.0, which has an `embassy_nrf::pdm` driver for the nRF52840 ([S14]).

## 4. RAM, CPU and power

| Item | Figure | Kind |
|---|---|---|
| nRF52840 RAM | 256 KB, of which this firmware may use `256 KB − 8` (the MBR keeps the first 8 bytes). The SoftDevice is in flash and is never enabled by this image ([S5][S19]) | *specification* / project layout |
| 16 kHz, 16-bit mono, one 10 ms buffer | 160 samples × 2 bytes = 320 bytes (*calculation*) | A pair of buffers is 640 bytes, negligible against 256 KB |
| 5 ms pair | 320 bytes total (*calculation*) | Preferred for play-through |
| CPU work at 16 kHz PCM | The PDM hardware decimates and DMA writes the buffer. The CPU only swaps buffers and copies to USB. No codec is required on this path | Qualitative; measure later |
| Microphone current | typ. 670 µA at 2.4 MHz in standard mode ([S6]); **unknown** at 1.280 MHz | *specification* at a different clock |
| Board current, 16 kHz capture | 17 mA average over a minute, 14 mA when decimated to 8 kHz, 10 mA with the on-chip DC/DC enabled, reported on the Seeed forum ([S8]) | *third-party measurement*, whole board, not this firmware |
| Off state | Drive P1.10 low so the microphone is unpowered ([S10][S19]) | Plan |

Current firmware RAM headroom with IMU, USB-MIDI, CDC and (if enabled) the 32 kHz debug synth has not been read from a live ELF in this note. **Unknown**, but a few hundred bytes for microphone buffers is not the likely limiter. Measure `readelf` / stack use when the feature is written.

Omi also runs an Opus encoder on this same MCU (they quote about 7 KB of encoder state and a 32 KB audio ring, [S11]). That is evidence that the Cortex-M4F can process audio at 16 kHz, not a reason to encode for the USB test path.

## 5. USB transport

The nRF52840 USB device is USB 2.0 **full speed, 12 Mbit/s**, with 1 ms frames. It has seven bulk/interrupt IN and seven OUT endpoints (64-byte buffers) and **one isochronous IN and one isochronous OUT** (up to 1023 bytes) ([S5]). *Specification.*

Payload for 16-bit mono:

| Rate | Bytes/s | Bytes per 1 ms frame |
|---|---|---|
| 16 kHz | 32 000 | 32 |
| 41.667 kHz | 83 334 | ≈ 83.3 |

Both sit far below a 1023-byte isochronous packet and far below full-speed bulk capacity (*calculation*). The existing optional debug synth already streams 32 kHz, 16-bit PCM (64 kB/s) on a second CDC port ([S19]).

### Option A — framed PCM over CDC or a dedicated bulk endpoint (recommended)

The firmware already has a versioned, CRC'd PCM frame and `tools/pcm_capture.py` ([S19]). Use that framing, either on a CDC ACM port (as `pcm-synth` does) or on a dedicated bulk endpoint if CDC flow control gets in the way.

Pros: no change to how macOS sees the USB-MIDI device; the app already talks to this board over USB; the switch can start and stop the stream; 32 kB/s is easy; work is confined to firmware and Trillium.

Cons: the operating system does not list a microphone. Only Trillium (or a script using the capture tool) can hear it. That is acceptable for a test feature.

Interface budget: the default device is CDC (2 interfaces) plus USB-MIDI (2). `pcm-synth` adds a second CDC (6 interfaces, which is the current `embassy-usb` `max-interface-count-6`). A microphone stream can replace or share that optional port, or the limit can be raised. Not a hardware limit ([S5][S19]).

### Option B — USB Audio Class 1 microphone, composite with USB-MIDI

UAC 1 records as a system input on macOS and iOS, and other apps could use it. Isochronous IN at 32 bytes per frame is well within the nRF52840's single ISO IN endpoint ([S5]).

This is **not** recommended for the next release:

- `embassy-usb` 0.6.0, the version this firmware pins, implements UAC 1.0 **playback** (`uac1::speaker`) only ([S13]). A later Embassy tree adds a UAC source class ([S15]); using it means an upgrade, or hand-written descriptors.
- A new Audio Control + Audio Streaming pair changes the composite layout that already enumerates as MIDI on macOS. That is untested here.
- For a test switch that only Trillium needs to see, a system microphone is unnecessary.

It remains a reasonable later option if the microphone should appear in Audio MIDI Setup.

### Option C — a wholly custom USB protocol

No advantage over option A for this feature.

## 6. BLE transport (not for the next release)

The nRF52840 has no classic Bluetooth and therefore no A2DP ([S16]). BLE Audio / LC3 is out of scope here.

| Path | Payload | Notes |
|---|---|---|
| Raw 16-bit/16 kHz PCM | 256 kbit/s (*calculation*) | Tight on typical BLE notification throughput and connection intervals. Not a standard audio profile |
| IMA/DVI ADPCM, 4-bit, 16 kHz | 64 kbit/s (*calculation*) | Lower CPU than Opus; still a custom format |
| Opus, as Omi does | 32 kbit/s VBR, CELT, 10 ms (160-sample) frames, codec ID 20, custom GATT service ([S11]) | *library / product behaviour* on this board. Good for recording. Design latency is several connection intervals plus 10 ms frames plus app buffering, "unsuitable for live instrument audio" ([S11]) |

The next release is a USB test feature on T0 (and any USB-connected board). Compressed BLE audio can be revisited when wireless recording is a goal. It is separate from BLE-MIDI, which carries notes and controllers, not a microphone stream.

## 7. Latency budget

For test play-through, a monitoring delay of a few tens of milliseconds is acceptable. This is not a low-latency instrument path.

| Stage | Allowance | Kind |
|---|---|---|
| PDM decimation filter | up to 5 ms | *specification*, t<sub>PDM,DATA</sub> max ([S4]) |
| DMA / USB packetisation | 5–10 ms (80–160 samples at 16 kHz). Do **not** use Omi's 100 ms buffers ([S11]) for play-through | *target* |
| USB full-speed scheduling | about 1 ms per frame, plus the host stack | *specification* + unmeasured host |
| App jitter buffer | one or two blocks, 5–10 ms | *target* |
| Mac output buffer | often 5–10 ms, depending on `AVAudioEngine` / Core Audio buffer size | *calculation* / typical; **unmeasured** |
| **Suggested total** | about 20–40 ms | *target*, not a measurement |

Recording for later reuse has no live-latency constraint. End-to-end play-through delay must be measured (a clap, or a GPIO and a loopback) before any numeric claim is made.

## 8. macOS (and later iOS)

For option A the app is the audio client. It should **not** try to select a system input device. Official APIs ([S17][S18]):

- Read the framed PCM stream from the USB port (the same class of I/O the app already uses for MIDI is not enough by itself; a serial/USB reader is needed for CDC).
- Convert to an `AVAudioPCMBuffer` and play with `AVAudioEngine` plus `AVAudioPlayerNode` or `AVAudioSourceNode`.
- Chart from the same buffers (a downsampled peak or waveform).
- Output format can stay at 16 kHz or be converted to the hardware rate (often 44.1 or 48 kHz) with `AVAudioConverter`.

iOS is later: the same engine can play, but a play-and-record audio session, background behaviour, and USB access on a physical device have not been tested. A signed iPhone or iPad install of Trillium has not been tested ([S19]). If a UAC microphone is added later, `AVAudioEngine.inputNode` follows the system default input; using a non-default device is awkward and may need an aggregate device ([S17]). That is another reason to keep the test path inside the app.

## 9. Interaction with the rest of the firmware

- USB-MIDI and the configuration protocol should keep working while the test switch is on. They are not required for the microphone test to be useful.
- The IMU already runs at 833 Hz in current firmware ([S19]). EasyDMA from PDM should not stall that path; confirm with the existing timing counters when implemented.
- The `pcm-synth` debug synth, if built, already uses a high-priority audio executor and a second CDC port. The microphone test and that synth should not fight over the same port or the same time slot without a plan.
- Protocol variant bit 2 is already reserved for the microphone ([S20]). Use it when the firmware can actually capture.

## 10. Open questions

1. Which microphone is on the boards in use: MSM261D3526H1CPM as in schematic Rev V1.1, or WMM7035DTTJ0 as named on the current wiki resource list?
2. Is 16 kHz / 1.280 MHz quality good enough, or is the unofficial 41.667 kHz clock worth a second mode?
3. Measured play-through latency, CPU load, RAM use and current with the microphone on, next to IMU and USB-MIDI.
4. Whether a later release should also expose a class-compliant UAC 1 microphone, once a source class is available, so other Mac apps can record it.
5. File format, location and lifespan for recordings in Trillium, when that work starts.
6. iOS: USB access, audio session, and whether play-through is wanted there at all.

## Sources

- [S1] Seeed Studio, XIAO nRF52840 Sense product page (onboard PDM microphone, documents include `mic-MSM261D3526H1CPM`; 256 KB RAM, 1 MB flash): <https://www.seeedstudio.com/Seeed-XIAO-BLE-Sense-nRF52840-p-5253.html>
- [S2] Seeed Studio, *Getting Started with Seeed Studio XIAO nRF52840 Series* (wiki). Features, pin map, and a resource list that names Mic-WMM7035DTTJ0, retrieved 2026-11-17: <https://wiki.seeedstudio.com/XIAO_BLE/>
- [S3] Seeed Studio, XIAO nRF52840 Sense schematic Rev V1.1, MIC1 = MSM261D3526H1CPM, nets `P1.00_PDM_CLK`, `P0.16_PDM_DATA`, `P1.10_MIC_PWR`: <https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_PDF.pdf>
- [S4] Nordic Semiconductor, nRF52840 Product Specification, PDM chapter (16 kHz, 16-bit, RATIO 64/80, EasyDMA, t<sub>PDM,DATA</sub> max 5 ms, 1.032 / 1.280 MHz clocks): <https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/pdm.html>. A copy is also filed by Seeed as nRF52840 PS v1.5: <https://files.seeedstudio.com/wiki/XIAO-BLE/nRF52840_PS_v1.5.pdf>
- [S5] Nordic Semiconductor, nRF52840 Product Specification, USBD chapter (full-speed 12 Mbit/s, 7+7 bulk/interrupt, 1+1 isochronous, 64-byte bulk buffers, ISO up to 1023 bytes) and memory: <https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/usbd.html>. Product brief (256 KB RAM, 64 MHz Cortex-M4F, full-speed USB): <https://nsscprodmedia.blob.core.windows.net/prod/software-and-other-downloads/product-briefs/nrf52840-soc-pb-23.pdf>
- [S6] Memsensing, *MSM261D3526H1CPM* datasheet V1.2 (December 2018), clock modes, current, SNR: <https://cdn-reichelt.de/documents/datenblatt/A300/MIC-MSM261D3526H1CPM-ENG.pdf>
- [S7] Arduino Core mbed, `libraries/PDM/src/nrf52/PDM.cpp` (supported rates 16 000 and 41 667 Hz; 1.280 MHz at RATIO 80, and 2.667 MHz for 41 667 Hz): <https://github.com/arduino/ArduinoCore-mbed/blob/main/libraries/PDM/src/nrf52/PDM.cpp>
- [S8] Seeed Studio forum, *Variable PDM Microphone Sample Rates on nRF52840 Sense* (library rates; third-party current figures): <https://forum.seeedstudio.com/t/variable-pdm-microphone-sample-rates-on-nrf52840-sense/279497>
- [S9] `nrf52840-pac` `PDMCLKCTRL` enumerated frequencies (1.000–1.333 MHz): <https://docs.rs/nrf52840-pac/latest/src/nrf52840_pac/pdm/pdmclkctrl.rs.html>
- [S10] Zephyr, `boards/seeed/xiao_ble/xiao_ble_nrf52840_sense.dts` (microphone enable on P1.10, PDM pins, part name in the regulator label): <https://github.com/zephyrproject-rtos/zephyr/blob/main/boards/seeed/xiao_ble/xiao_ble_nrf52840_sense.dts>
- [S11] This repository, [Omi integration](../omi-integration.md): DevKit mic at 16 kHz, 1.28 MHz PDM clock, 100 ms DMA buffers, Opus 32 kbit/s / 10 ms frames, custom GATT, latency suitable for recording not live audio. Evidence pinned to Omi commit `28c785960fa7`
- [S12] Seeed Studio, *The PDM Microphone Usage on Seeed Studio XIAO nRF52840 Sense* (Arduino examples; plotter and SD-card recording): <https://wiki.seeedstudio.com/XIAO-BLE-Sense-PDM-Usage/>
- [S13] `embassy-usb` 0.6.0, `class::uac1` (speaker / playback only): <https://docs.embassy.dev/embassy-usb/0.6.0/default/class/uac1/index.html>
- [S14] `embassy-nrf` 0.11.0, `pdm` for nRF52840: <https://docs.embassy.dev/embassy-nrf/0.11.0/nrf52840/pdm/index.html>
- [S15] Embassy documentation, later `embassy_usb::class::uac::device::source` (UAC 1.0 microphone; not in the 0.6.0 tree used here): <https://docs.embassy.dev/embassy-usb/git/default/class/uac/device/source/index.html>
- [S16] This repository, [music-connectivity.md](../music-connectivity.md): no classic Bluetooth / A2DP on the nRF52840; USB PCM today is a test port, not USB Audio
- [S17] Apple, `AVAudioEngine`: <https://developer.apple.com/documentation/avfaudio/avaudioengine>. `AVAudioPlayerNode`: <https://developer.apple.com/documentation/avfaudio/avaudioplayernode>. `AVAudioSourceNode`: <https://developer.apple.com/documentation/avfaudio/avaudiosourcenode>. `AVAudioInputNode`: <https://developer.apple.com/documentation/avfaudio/avaudioinputnode>
- [S18] Apple, `AVAudioConverter`: <https://developer.apple.com/documentation/avfaudio/avaudioconverter>. Core Audio overview: <https://developer.apple.com/documentation/coreaudio>
- [S19] This repository: `firmware/xiao-sense/src/board.rs` (PDM pins "not used yet"; `pcm-synth` at 32 kHz / 64-sample blocks), `firmware/xiao-sense/memory.x`, [firmware-xiao-sense.md](../firmware-xiao-sense.md), `crates/trill-usb`, `tools/pcm_capture.py`
- [S20] This repository, [CHANGELOG](../../CHANGELOG.md) 0.6.0: variant bit 2 reserved for the microphone
