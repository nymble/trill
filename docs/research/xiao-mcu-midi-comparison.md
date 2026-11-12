# Seeed Studio XIAO MCUs for Multi-Mode Musical Controllers (BT + Sensors → MIDI)

A product-design comparison of Seeed Studio XIAO microcontroller boards for motion and sensor instruments that read sensors, buttons and potentiometers in several modes and send MIDI, preferably over Bluetooth Low Energy (BLE MIDI).

Specifications are taken from the official Seeed Studio Wiki and product pages as of November 2026 (see [Sources](#9-sources)). Where Seeed does not publish a value, the table says "not published" or names the source used.

**Terms used in this document**

| Term | Meaning |
|---|---|
| MIDI | Musical Instrument Digital Interface, the standard protocol for notes and controller data |
| BLE | Bluetooth Low Energy |
| BLE MIDI | MIDI over Bluetooth Low Energy, the MIDI Association BLE-MIDI 1.0 specification |
| USB MIDI | MIDI over USB using the class-compliant USB MIDI device class (no driver needed) |
| MIDI CC | MIDI Control Change, a 7-bit continuous controller message (for example CC1, the mod wheel) |
| RPN | Registered Parameter Number, a standard MIDI parameter such as pitch-bend range (RPN 0) |
| MPE | MIDI Polyphonic Expression |
| IMU | Inertial Measurement Unit (accelerometer plus gyroscope) |
| PDM | Pulse Density Modulation, the digital output format of many MEMS microphones |
| ADC | Analog-to-Digital Converter |
| GPIO | General-Purpose Input/Output pin |
| PWM | Pulse-Width Modulation |
| SoC / MCU | System-on-Chip / Microcontroller Unit |
| LiPo | Lithium-polymer battery (3.7 V nominal) |
| SDK / NCS | Software Development Kit / Nordic nRF Connect SDK (based on the Zephyr RTOS) |
| Grove | Seeed's 4-pin connector system for sensors and actuators |

## Contents

1. [Executive summary](#1-executive-summary)
2. [Hardware specifications](#2-hardware-specifications)
3. [Connectivity, power and suitability](#3-connectivity-power-and-suitability)
4. [Plus variants for production I/O](#4-plus-variants-for-production-io)
5. [Product-design notes](#5-product-design-notes)
6. [Real-world examples](#6-real-world-examples)
7. [Ranked recommendations](#7-ranked-recommendations)
8. [Facts not published or corrected](#8-facts-not-published-or-corrected)
9. [Sources](#9-sources)

## 1. Executive summary

For a battery-powered, multi-mode controller that speaks BLE MIDI and also plugs in as a class-compliant USB MIDI device, the deciding factors are: a native USB device controller, a mature BLE MIDI library, an onboard IMU for gesture modes, enough ADC inputs for pots, and low sleep current.

| Rank | Board | Why |
|---|---|---|
| 1 | **XIAO nRF52840 Sense** | Onboard 6-axis IMU and PDM microphone, native USB (USB MIDI and BLE MIDI from one chip), mature Arduino BLE MIDI support through the Adafruit Bluefruit nRF52 library, 5 µA published low-power figure. Best for wearable, gesture and expression instruments. |
| 2 | **XIAO ESP32-S3** | Dual-core 240 MHz, 8 MB PSRAM, native USB OTG plus BLE 5. Best for dense controllers, heavy per-mode processing and simultaneous USB + BLE MIDI. Wi-Fi adds RTP-MIDI or OSC options. Choose the Sense version only if a camera or microphone is needed. |
| 3 | **XIAO ESP32-C3** | Lowest cost, BLE 5, mature ESP32 BLE MIDI libraries. No native USB device, so BLE MIDI only (or serial MIDI). Good for quick prototypes. |
| 4 | **XIAO nRF54L15 Sense** | Newest Nordic part: BLE 6.0, 128 MHz Cortex-M33, same IMU and microphone class as the nRF52840 Sense. No native USB on the chip, so BLE MIDI only. Toolchain is NCS/Zephyr, with a community Arduino core maturing in 2026. |
| 5 | **XIAO MG24 Sense** | Alternative low-power option: BLE 5.3, IMU and analog microphone, 22 pins with 18 analog, 1.95 µA published low-power figure. No native USB and no ready-made Arduino BLE MIDI library. |

The XIAO nRF52840 (non-Sense) and XIAO ESP32-C6 are viable but are dominated for this use case by the boards above: the nRF52840 lacks the IMU, and the ESP32-C6 has no native USB device controller.

## 2. Hardware specifications

All boards share the 21 × 17.8 mm XIAO footprint (Seeed Wiki).

| Model | MCU / core | Clock | RAM | Flash | Built-in sensors | GPIO (PWM) / analog |
|---|---|---|---|---|---|---|
| XIAO nRF52840 Sense | Nordic nRF52840, Arm Cortex-M4 with FPU | 64 MHz | 256 KB | 1 MB on-chip + 2 MB onboard | 6-axis IMU (LSM6DS3TR-C), PDM microphone | 11 / 6 |
| XIAO nRF52840 | Nordic nRF52840, Arm Cortex-M4 with FPU | 64 MHz | 256 KB | 1 MB on-chip + 2 MB onboard | None | 11 / 6 |
| XIAO nRF54L15 Sense | Nordic nRF54L15, Arm Cortex-M33 + RISC-V coprocessor | 128 MHz (both cores) | 256 KB | 1.5 MB NVM (non-volatile memory) | 6-axis IMU (LSM6DS3TR-C), PDM microphone (MSM261DGT006) | 14 / 4 (comparison table; 16 / 4 for the non-Sense board) |
| XIAO ESP32-S3 | Espressif ESP32-S3R8, dual-core Xtensa LX7 | 240 MHz | 512 KB SRAM + 8 MB PSRAM | 8 MB | None | 11 / 9 |
| XIAO ESP32-S3 Sense | Espressif ESP32-S3R8, dual-core Xtensa LX7 | 240 MHz | 512 KB SRAM + 8 MB PSRAM | 8 MB + microSD slot on the expansion board | Camera on detachable board (OV5640 current; OV3660 and OV2640 compatible), digital microphone | 13 / 11 (comparison table; 11 GPIO plus 2 on the B2B connector per the getting-started page) |
| XIAO ESP32-C3 | Espressif ESP32-C3, single-core RISC-V | 160 MHz | 400 KB | 4 MB | None | 11 / 4 (A3 uses ADC2; Seeed recommends A0–A2 for reliable reads) |
| XIAO ESP32-C6 | Espressif ESP32-C6, RISC-V high-power core + RISC-V low-power core | 160 MHz + 20 MHz | 512 KB | 4 MB | None | 11 / 7 |
| XIAO MG24 Sense | Silicon Labs EFR32MG24, Arm Cortex-M33 with FPU and MVP ML accelerator | 78 MHz | 256 KB | 1536 KB on-chip + 4 MB onboard | 6-axis IMU (LSM6DS3TR-C), analog MEMS microphone (MSM381ACT001) | 22 / 18 (comparison table; the MG24 getting-started page lists 19 analog) |

Notes:

- The nRF52840 Sense IMU has an accelerometer and gyroscope but no magnetometer, so firmware can estimate tilt (pitch and roll) from gravity but has no absolute heading (yaw). The same applies to every board above with an LSM6DS3TR-C.
- On the MG24 Sense the IMU sits behind a power-enable pin (PD5) that must be driven high before use, per the Seeed MG24 Sense sensor wiki.

## 3. Connectivity, power and suitability

| Model | Bluetooth | Wi-Fi | Native USB device (USB MIDI) | Battery / LiPo charging | Published low-power figure (Seeed) | Suitability for BLE MIDI + multi-mode inputs |
|---|---|---|---|---|---|---|
| XIAO nRF52840 Sense | BLE 5 (Seeed spec table and store page: BLE 5.4; feature list: Bluetooth 5.0), Bluetooth Mesh, NFC | No | Yes, USB 2.0 full speed on the SoC | Yes, BQ25101 charger, 50 or 100 mA selectable | 5 µA ("standby less than 5 µA") | Excellent. IMU gestures, BLE MIDI and USB MIDI on one chip. Six ADC pins; use a multiplexer for more pots. |
| XIAO nRF52840 | Same as above | No | Yes | Yes, BQ25101 | 5 µA | Very good for button and pot controllers; add an external IMU over I²C if motion is needed. |
| XIAO nRF54L15 Sense | BLE 6.0 (including Channel Sounding), Thread, Zigbee, Matter, 2.4 GHz proprietary | No | No. The nRF54L15 has no USB peripheral; the board's USB-C port goes through a SAMD11 bridge for serial and programming | Yes, lithium battery charging | Not published by Seeed (store page: "will be announced soon"). Chip datasheet: 0.7 µA System OFF with pin wake. Community measurements report about 1.7 µA board-level System OFF, and note that the onboard RF switch draws about 100 µA if left powered | Good for BLE MIDI only. Four ADC inputs; a 14-bit ADC. Plan for a multiplexer. |
| XIAO ESP32-S3 | BLE 5.0, Bluetooth Mesh | 2.4 GHz 802.11 b/g/n | Yes, USB OTG full speed (TinyUSB device stack in ESP-IDF and Arduino-ESP32) | Yes | 14 µA deep sleep (3.8 V supply) | Excellent for dense controllers and dual USB + BLE MIDI. Nine ADC pins plus 11 capacitive-touch pins. Higher active current than the Nordic parts. |
| XIAO ESP32-S3 Sense | BLE 5.0, Bluetooth Mesh | 2.4 GHz 802.11 b/g/n | Yes, USB OTG | Yes | Deep sleep 3 mA with the camera board attached (getting-started page); the comparison table lists 26.5 mA | Use only when the camera or microphone is part of the instrument; otherwise the plain S3 is smaller in power and cost. |
| XIAO ESP32-C3 | BLE 5.0, Bluetooth Mesh | 2.4 GHz 802.11 b/g/n | No. Fixed-function USB Serial/JTAG controller only, so no class-compliant USB MIDI | Yes; 380 mA fast charge | 44 µA deep sleep (feature list says about 43 µA). No battery-voltage pin; Seeed shows an external divider on A0 | Good budget BLE MIDI controller. Only four ADC pins, three of them reliable. |
| XIAO ESP32-C6 | BLE 5 (intro text: Bluetooth 5.3; comparison table: BLE 5.0), 802.15.4 (Thread, Zigbee) | 2.4 GHz Wi-Fi 6 (802.11ax) | No. USB Serial/JTAG only | Yes | 15 µA deep sleep (3.8 V supply) | Workable BLE MIDI board with seven ADC pins; choose it when Matter or Thread matters, not for MIDI alone. |
| XIAO MG24 Sense | BLE 5.3, Bluetooth Mesh, Matter, Thread, Zigbee | No | No. USB-C goes through a SAMD11 bridge | Yes | 1.95 µA "Low Power (Typ.)"; 1.91 mA "Sleep (Typ.)"; 6.71 mA "Normal (Typ.)". Seeed documents a recovery procedure for boards that fail to wake from deep sleep (EM4) | Good I/O count (18 analog) and very low sleep current. BLE MIDI must be implemented on the Silicon Labs BLE stack; no ready-made Arduino BLE MIDI library targets it. |

Power figures are Seeed's published typical values. Measurement conditions differ between boards (supply voltage, peripherals powered, wake source), so compare them as orders of magnitude, not exact values. None of these figures includes an attached LED, display or sensor.

## 4. Plus variants for production I/O

Seeed's XIAO Plus boards keep the XIAO outline but add castellated pads and back-side pads for surface-mount assembly: 23 castellated pins (20 GPIO and 3 power). As of the August 2026 update, five Plus boards exist: **XIAO ESP32-S3 Plus, XIAO nRF52840 Plus, XIAO nRF52840 Sense Plus, XIAO SAMD21 Plus and XIAO RP2040 Plus**. There is no Plus version of the nRF54L15, ESP32-C3, ESP32-C6 or MG24.

| Plus board | Extra I/O versus the standard board | Other differences |
|---|---|---|
| XIAO nRF52840 Plus / nRF52840 Sense Plus | 20 PWM GPIO, 6 ADC; 2 × UART, 1 × I²C, 2 × SPI, 1 × I²S (standard: 11 GPIO, 1 UART, 1 SPI) | Sense Plus keeps the IMU and PDM microphone. NFC pads become GPIO D14/D15 (UART1). Battery-voltage pin broken out (D16). |
| XIAO ESP32-S3 Plus | 9 additional GPIO via castellations (20 total), 2 × UART, I²S | 16 MB flash (standard: 8 MB). B2B connector works with the Wio-SX1262 LoRa board, not the camera board. Published deep sleep: 33.51 µA at 3.8 V. |

For production, a Plus board reflowed onto a carrier PCB removes pin headers, frees pins for an analog multiplexer, LED driver and mode buttons, and keeps the certified radio module. Seeed publishes KiCad files and "XIAO Plus Base" footprints with and without the bottom-pad lead-out.

## 5. Product-design notes

### 5.1 Grove ecosystem and input expansion

- **Seeed Studio Expansion Base for XIAO:** OLED display, real-time clock, buzzer, user button, microSD slot and several Grove connectors. Useful for a bench prototype with a display for the current mode.
- **Grove Shield for XIAO (with battery management):** breaks out Grove I²C, UART and analog/digital ports and adds a LiPo connector, for plug-in pots, buttons, rotary encoders and I²C sensors (distance, light, pressure, extra IMUs).
- **Analog multiplexers for many pots:** a CD74HC4051 (8:1) or CD74HC4067 (16:1) feeds many potentiometers, force-sensitive resistors (FSRs) or flex sensors into one ADC pin with three or four select lines. Allow a short settling delay after each channel change.
- **Digital expansion:** I²C GPIO expanders, shift registers or a key matrix for many buttons; a WS2812/SK6812 LED strip on one GPIO for mode feedback.
- **ADC caveats:** on the ESP32-C3, A3 uses ADC2 and Seeed recommends A0–A2 for reliable reads; on the ESP32-S3, the pins labelled A11 and A12 do not support ADC.

### 5.2 BLE MIDI and USB MIDI software

| Platform | BLE MIDI | USB MIDI | Notes |
|---|---|---|---|
| nRF52840 (Arduino) | `BLEMidi` service in the Adafruit Bluefruit nRF52 library (Seeed nRF52 Boards package), used with the Arduino MIDI Library | Adafruit TinyUSB (`Adafruit_USBD_MIDI`) in the same core | The mature path for a combined USB + BLE MIDI device. Seeed recommends the non-mbed "Seeed nRF52 Boards" package for Bluetooth and low power. |
| nRF52840 / nRF54L15 (NCS / Zephyr) | No BLE MIDI sample ships in the nRF Connect SDK. Community options: `zephyr-ble-midi` (full BLE-MIDI packet encoding, requests a 7.5 ms connection interval, optional transmit-on-connection-event mode for NCS 2.6 and later) and `NCS-MIDI` (central and peripheral samples) | Zephyr USB device stack (nRF52840 only; the nRF54L15 has no USB) | The `zephyr-ble-midi` connection-event mode assumes the BLE controller and the MIDI service run on the same core. |
| nRF54L15 (Arduino) | A community Arduino core (`nrf54-arduino-core`, linked from the Seeed Wiki) includes a Bluefruit52Lib compatibility layer for BLE; no dedicated BLE MIDI example was found | Not applicable | Register-level core without Zephyr; Thread, Matter, Zigbee and Channel Sounding are marked experimental. |
| ESP32-S3 / C3 / C6 (Arduino) | Arduino-BLE-MIDI (supports the ESP32 Bluedroid and NimBLE back ends), ESP32-BLE-MIDI, or a custom service on NimBLE-Arduino | ESP32-S3 only: TinyUSB MIDI through the Arduino-ESP32 USB stack | Control Surface supports BLE, USB and serial MIDI and ships multiplexer, button, pot and encoder abstractions with filtering and hysteresis. |
| ESP32 (ESP-IDF) | Espressif `esp-iot-solution` includes a BLE MIDI profile example | TinyUSB in ESP-IDF (S3 only) | On macOS, devices connected through Audio MIDI Setup may need a manual step before they appear as MIDI ports with this example (reported in issue #658). |
| MG24 (Arduino or Simplicity SDK) | No ready-made Arduino BLE MIDI library targets the Silicon Labs core. Silicon Labs publishes a "MIDI over BLE" code example for its Bluetooth SDK | Not applicable | The Arduino core exposes the Silicon Labs BLE stack (Tools → Protocol Stack → BLE (Silabs)). |

### 5.3 BLE MIDI latency and host support

- **Connection interval:** BLE MIDI events wait for the next connection event, so average added latency is about half the connection interval plus queuing. The BLE-MIDI specification requires the peripheral to request an interval of 15 ms or less; 7.5 ms is the Bluetooth minimum, and the central (phone or computer) decides what it grants. Apple's accessory guidelines constrain the intervals an accessory may request, so plan for 11.25–15 ms on Apple hosts and measure the granted value.
- **Timestamps:** BLE MIDI packets carry a 13-bit millisecond timestamp. Send events with accurate timestamps and batch several messages per packet to reduce jitter.
- **macOS:** connect through Audio MIDI Setup → MIDI Studio → Bluetooth Configuration; the device then appears to every app.
- **iOS and iPadOS:** there is no system-wide pairing screen for BLE MIDI. The host app must present Apple's Bluetooth MIDI connection view (CoreAudioKit) or its own device list. Many synth and DAW apps, including GarageBand, provide one.
- **Windows:** BLE MIDI support arrives through Windows MIDI Services; check the current status of the host OS before promising Windows support.
- **USB MIDI as fallback:** a wired class-compliant USB MIDI connection is lower and more stable in latency, and works with iPhone and iPad over USB-C. This is the main reason to prefer a board with a native USB device controller (nRF52840 or ESP32-S3).

### 5.4 Multi-mode implementation patterns

- **Mode state machine:** an explicit enum of modes (for example Notes, CC, Pitch-bend, Gesture, Setup) with entry and exit actions. On exit, send Note Off for every held note and return pitch bend to centre to avoid stuck notes.
- **Mode selection:** a dedicated mode button, a long-press (about 1–2 s) on a shared button, or a button chord. The XIAO MIDI Synthesizer firmware uses a 2-second long-press to cycle modes.
- **Per-mode mapping tables:** a table per mode mapping each input (pot, button, IMU axis) to a message type (note, CC number, pitch bend, aftertouch), channel, range and curve. This keeps the scan loop mode-independent.
- **Feedback:** an RGB LED colour per mode, or an LED strip or small OLED for the mode name and value. Confirm saves with a short flash.
- **Persistent settings:** store mappings and the last mode in flash (Adafruit InternalFS/LittleFS on nRF52, NVS or Preferences on ESP32, the Zephyr settings subsystem on NCS). Write only on change to limit flash wear.
- **Analog conditioning:** oversample, low-pass filter (exponential moving average), add hysteresis or a deadzone, and send a CC only when the 7-bit value changes. Use 14-bit CC pairs or pitch bend where resolution matters.
- **IMU gestures:** derive tilt from the accelerometer for continuous control; detect taps, flicks or shakes from acceleration peaks with a cooldown; integrate the gyroscope only for short relative turns, because without a magnetometer yaw drifts. Provide a "set current orientation as level" calibration action.
- **Note versus CC versus pitch bend:** quantise continuous inputs to a scale in note modes; send CC (for example CC1 or CC74) in expression modes; send pitch bend with the bend range announced via RPN 0 in theremin-style modes. Consider MPE when several expressive voices are needed.
- **Rate limiting:** cap continuous streams (for example 100–200 messages per second per control) so BLE MIDI packets stay small and buttons are not delayed behind controller data.

### 5.5 Form-factor advantages

- 21 × 17.8 mm footprint across the family, with single-sided components and castellated pads for direct surface mounting on a carrier board.
- Onboard LiPo charging on every board in this report, so a wearable needs only a cell and a switch.
- Onboard antennas; the ESP32 boards and the nRF54L15 also offer a U.FL/IPEX connector for an external antenna, useful inside metal enclosures.
- Board-to-board pin compatibility lets one carrier PCB accept several XIAO boards during evaluation, with firmware differences isolated behind a hardware abstraction layer.

## 6. Real-world examples

| Example | Board | What it shows | Link |
|---|---|---|---|
| Sneaky Gestures V2 (open-source BLE MIDI glove) | XIAO nRF52840 Sense | 12 conductive finger pads through a CD74HC4067 multiplexer, flex-sensor glissando, FSR aftertouch, two accelerometer CCs, 20 scales, 63 presets in flash, LED mode display, tap tempo and MIDI clock sync, stuck-note prevention. Built with PlatformIO on the Adafruit nRF52 core. | <https://github.com/sneak-thief/Sneaky-Gestures-V2> |
| slim208 (high-density BLE MIDI controller, MIDI Innovation Awards entry) | XIAO ESP32-S3 Plus | 64 potentiometers and 144 switches read through 13 multiplexers, 208 MIDI CCs over BLE, 18650 battery rated at 35–40 hours, aimed at iPad modular synthesis. Handmade prototype. | <https://midi.org/innovation-award/slim208> |
| XIAO MIDI Synthesizer (official Seeed gadget) | XIAO ESP32-C3 + SAM2695 synth chip | A MIDI sound module, not a BLE MIDI controller: the ESP32-C3 drives a SAM2695 General MIDI synthesizer over a 31250-baud serial link, with 64-voice polyphony, a speaker and headphone jack, four buttons and long-press mode switching (Sound Test, Beat Keeper, Multi-Track Play). Arduino library: Seeed_Arduino_MIDIMaster. | <https://wiki.seeedstudio.com/xiao_midi_synthesizer/> |
| Trill (open-source motion instrument) | XIAO nRF52840 Sense | Class-compliant USB MIDI instrument using the onboard LSM6DS3TR-C IMU, with touch, tilt-to-scale, theremin-style pitch-bend and tap modes. BLE MIDI is planned but not yet implemented. | <https://github.com/nymble/trill> |

## 7. Ranked recommendations

| Category | Pick | Alternative | Rationale |
|---|---|---|---|
| Best overall for wearable, gesture and expression products | **XIAO nRF52840 Sense** | XIAO nRF52840 Sense Plus for production | Onboard IMU and microphone, native USB MIDI plus BLE MIDI, the most mature Arduino BLE MIDI stack, 5 µA published low-power figure, and a proven open-source BLE MIDI glove on the same board. |
| Best for complex multi-mode processing or dual USB + BLE MIDI | **XIAO ESP32-S3** | XIAO ESP32-S3 Plus (20 GPIO, 16 MB flash); ESP32-S3 Sense only when a camera or microphone is required | Dual 240 MHz cores and 8 MB PSRAM for large mapping tables, sequencers or displays; native USB OTG; nine ADC pins and 11 capacitive-touch inputs; Wi-Fi for RTP-MIDI or OSC. Add an I²C IMU for motion. |
| Budget / quick-start | **XIAO ESP32-C3** | XIAO nRF52840 (non-Sense) when USB MIDI is required | Lowest price, BLE 5, mature Arduino BLE MIDI libraries and the Control Surface library. BLE MIDI only; four ADC pins. |
| Newest / future-proof low-power | **XIAO nRF54L15 Sense** | XIAO MG24 Sense (more analog pins, 1.95 µA published) | BLE 6.0, 128 MHz Cortex-M33 plus RISC-V coprocessor, same IMU class as the nRF52840 Sense. No native USB, and BLE MIDI relies on community Zephyr modules or the maturing community Arduino core. Board-level sleep figures not yet published by Seeed. The newer XIAO nRF54LM20A (Sense) adds 512 KB RAM, 28 GPIO, an nPM1300 power-management IC and published System OFF current of about 4.76 µA, and is worth evaluating for the same role. |

## 8. Facts not published or corrected

- **nRF54L15 Sense sleep current:** Seeed has not published a board-level figure (the store page says it is pending, and the comparison table shows "-"). The values above come from the Nordic datasheet (chip only) and Seeed forum measurements.
- **Bluetooth versions:** Seeed pages disagree. The nRF52840 is listed as BLE 5.4 in the specification table and store page but Bluetooth 5.0 in the feature list. The ESP32-C6 is listed as Bluetooth 5.3 in the introduction and BLE 5.0 in the specification table. Both are reported here as "BLE 5" with the variants noted.
- **ESP32-S3 Sense deep sleep:** the getting-started page lists 3 mA with the camera board attached, while the series comparison table lists 26.5 mA.
- **GPIO and analog counts:** the comparison table and individual wikis differ for the nRF54L15 Sense (14 versus 16 GPIO), the ESP32-S3 Sense (13 / 11 versus 11 / 9 plus 2 on the B2B connector) and the MG24 (18 versus 19 analog). Comparison-table values are used, with the alternative noted.
- **Native USB:** the ESP32-C3 and ESP32-C6 have only a fixed-function USB Serial/JTAG controller, and the nRF54L15 and EFR32MG24 have no USB controller (their XIAO boards use a SAMD11 bridge). None of these four can act as a class-compliant USB MIDI device without extra hardware.
- **Prices:** not listed. Seeed store prices differ between the product pages and the XIAO landing page and change often; check the product page at the time of purchase.
- **BLE MIDI on nRF54L15 and MG24:** no official vendor BLE MIDI sample was found for the nRF Connect SDK. The Silicon Labs "MIDI over BLE" example targets an older Bluetooth SDK release (v2.13), and its current-SDK status was not confirmed.

## 9. Sources

All accessed November 2026.

**Seeed Studio (official)**

- XIAO Series introduction and comparison table: <https://wiki.seeedstudio.com/SeeedStudio_XIAO_Series_Introduction/>
- XIAO product landing page: <https://www.seeedstudio.com/xiao-series-page/products/>
- XIAO nRF52840 (Sense) getting started: <https://wiki.seeedstudio.com/XIAO_BLE/>
- XIAO nRF52840 (Sense) Bluetooth usage: <https://wiki.seeedstudio.com/XIAO-BLE-Sense-Bluetooth-Usage/>
- XIAO nRF54L15 (Sense) getting started: <https://wiki.seeedstudio.com/xiao_nrf54l15_sense_getting_started/>
- XIAO nRF54L15 power consumption example: <https://wiki.seeedstudio.com/xiao_nrf54l15_sense_power_consumptions/>
- Arduino for XIAO nRF54L15: <https://wiki.seeedstudio.com/xiao_nrf54l15_sense_arduino/>
- XIAO nRF54L15 Sense product page: <https://www.seeedstudio.com/XIAO-nRF54L15-Sense-p-6494.html>
- XIAO nRF54LM20A getting started: <https://wiki.seeedstudio.com/xiao_nrf54lm20a_getting_started/>
- XIAO ESP32-S3 (Sense, Plus) getting started: <https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/>
- XIAO ESP32-S3 Plus product page: <https://www.seeedstudio.com/Seeed-Studio-XIAO-ESP32S3-Plus-p-6361.html>
- XIAO ESP32-C3 getting started: <https://wiki.seeedstudio.com/XIAO_ESP32C3_Getting_Started/>
- XIAO ESP32-C6 getting started: <https://wiki.seeedstudio.com/xiao_esp32c6_getting_started/>
- XIAO MG24 (Sense) getting started: <https://wiki.seeedstudio.com/xiao_mg24_getting_started/>
- XIAO MG24 Sense built-in sensors: <https://wiki.seeedstudio.com/xiao_mg24_sense_built_in_sensor/>
- XIAO Plus series announcement (August 2026 update): <https://www.seeedstudio.com/blog/2025/01/02/seeed-studio-xiao-plus-more-castellation-ios-for-smd-soldering/>
- XIAO MIDI Synthesizer: <https://wiki.seeedstudio.com/xiao_midi_synthesizer/>
- Expansion Base for XIAO: <https://wiki.seeedstudio.com/Seeeduino-XIAO-Expansion-Board/>
- Grove Shield for XIAO: <https://wiki.seeedstudio.com/Grove-Shield-for-Seeeduino-XIAO-embedded-battery-management-chip/>
- Seeed_Arduino_MIDIMaster: <https://github.com/Seeed-Studio/Seeed_Arduino_MIDIMaster>

**Silicon vendors and standards**

- Nordic nRF54L15 datasheet, sleep current: <https://docs.nordicsemi.com/r/bundle/ps_nrf54l15/page/chapters/current_consumption/doc/current_consumption.html-unique_1307930676>
- Nordic DevZone, "Optimizing BLE-MIDI with regards to timing": <https://devzone.nordicsemi.com/nordic/nordic-blog/b/blog/posts/optimizing-ble-midi-with-regards-to-timing-1293631358>
- Silicon Labs, MIDI over BLE code example (Bluetooth SDK v2.13): <https://docs.silabs.com/bluetooth/2.13/bluetooth-code-examples-applications/midi-over-ble>
- Silicon Labs Arduino core: <https://github.com/SiliconLabs/arduino>
- MIDI Association, BLE-MIDI specification: <https://midi.org/midi-over-bluetooth-low-energy-ble-midi>
- Apple, Accessory Design Guidelines (MIDI and BLE connection parameters): <https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf>
- Apple, Technical Q&A QA1931, BLE advertising and connection parameters: <https://developer.apple.com/library/archive/qa/qa1931/_index.html>
- Microsoft, BLE MIDI transport in Windows MIDI Services: <https://microsoft.github.io/MIDI/kb/ble-midi-transport-architecture/>
- Espressif esp-iot-solution BLE MIDI issue #658: <https://github.com/espressif/esp-iot-solution/issues/658>

**Libraries**

- Adafruit nRF52 Arduino core (Bluefruit `BLEMidi`): <https://github.com/adafruit/Adafruit_nRF52_Arduino>
- Arduino MIDI Library: <https://github.com/FortySevenEffects/arduino_midi_library>
- Arduino-BLE-MIDI: <https://github.com/lathoub/Arduino-BLE-MIDI>
- ESP32-BLE-MIDI: <https://github.com/max22-/ESP32-BLE-MIDI>
- NimBLE-Arduino: <https://github.com/h2zero/NimBLE-Arduino>
- TinyUSB: <https://github.com/hathach/tinyusb>
- Control Surface: <https://github.com/tttapa/Control-Surface>
- zephyr-ble-midi: <https://github.com/stuffmatic/zephyr-ble-midi>
- NCS-MIDI: <https://github.com/BLE-MIDI/NCS-MIDI>
- nRF54L Arduino core: <https://github.com/lolren/nrf54-arduino-core>

**Community measurements and projects**

- Seeed forum, sleep current comparison of XIAO nRF54L15, nRF52840 and MG24: <https://forum.seeedstudio.com/t/comparison-of-sleep-current-for-xiao-nrf54l15-nrf52840-and-mg24/294007>
- Seeed forum, XIAO MG24 versus nRF54L15 (RF switch current): <https://forum.seeedstudio.com/t/xiao-mg24-vs-nrf54l15-for-low-power-matter-zigbee-actuator/294608>
- Sneaky Gestures V2: <https://github.com/sneak-thief/Sneaky-Gestures-V2>
- slim208: <https://midi.org/innovation-award/slim208>
- Trill: <https://github.com/nymble/trill>
