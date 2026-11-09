# Firmware: XIAO nRF52840 Sense

Rust ([Embassy](https://embassy.dev)) application image for the **Seeed Studio XIAO nRF52840 Sense**: a class-compliant **USB-MIDI 1.0** instrument driven by a Trill on D4/D5 and the on-board LSM6DS3TR-C accelerometer + gyroscope, plus a USB diagnostics port. The audio-rate [motion synth](motion-synth.md) is an optional debug build (`pcm-synth`). Setup and acceptance tests: [USB MIDI](usb-midi.md); exact event mapping: [MIDI mapping](midi-mapping.md); power and battery: [XIAO design](design-xiao-nrf52840.md#power-usb-and-battery).

> **Status:** builds, links and passes the UF2 safety checks in CI. **It has not been run on hardware.** Every rate, pin and timing below is a design value taken from datasheets and board files, not a measurement.

Source: [`firmware/xiao-sense`](../firmware/xiao-sense) (its own Cargo workspace and lockfile, target `thumbv7em-none-eabihf`).

## Which board this is for

| Board | MCU | This firmware |
|---|---|---|
| XIAO nRF52840 **Sense** (XIAO BLE Sense) | nRF52840 | **Yes** |
| XIAO nRF52840 (no Sense) | nRF52840 | Boots, but has no IMU (IMU state stays `retry`) |
| XIAO **ESP32-S3** Sense (used by omiGlass) | ESP32-S3 | **No.** Different CPU architecture. The UF2 tool refuses it because its bootloader does not report an nRF52840 |
| Omi Consumer (CV1) | nRF5340 | **No.** Different chip and MCUboot bootloader |

An Omi DevKit 1/2 is an XIAO nRF52840 Sense running Omi's Zephyr firmware. Loading this image **replaces** Omi's application until you restore it. See [Omi integration](omi-integration.md) before doing that.

## What runs

Default build (USB-MIDI + diagnostics):

| Executor (NVIC priority) | Task | Rate / deadline |
|---|---|---|
| Medium (`EGU0_SWI0`, P6) | USB device, diagnostics port, MIDI writer (engine tick, packet fill, IN-endpoint write) | USB full speed; writer wakes on new input or every 2 ms |
| Thread (lowest) | IMU: data-ready wait, 14-byte burst read, motion processing, engine `motion()` | **416 Hz ODR**; every sample is read and processed (~2.4 ms period) |
| Thread | Trill: identify, configure (ultra-fast, 10 bit), status + centroid read, engine `touch()` for new frames only | Poll every 5 ms; frame ID filters repeats |
| Thread | [Status LED](#status-led): select indication, write pins on change; crash-counter reset after 30 s | 50 Hz tick (20 ms) |

With `--features pcm-synth` a high-priority executor (`EGU1_SWI1`, P5) also runs the audio task (64 samples @ 32 kHz = 2 ms blocks) and a second CDC port streams the PCM. The default build has no high-priority executor and renders no audio.

Touch and IMU are independent tasks; each hands timestamped samples to the [event engine](midi-mapping.md) (`crates/instrument-events`) through a short critical section. Touch therefore works with the IMU absent or failing. Sensor I/O blocks for bounded time (every I²C transaction has a 5 ms timeout), and USB preempts it. The MIDI writer never blocks a sensor task: if the host stops reading, the engine coalesces controllers and holds note messages in a bounded queue (see [MIDI mapping](midi-mapping.md#priority-coalescing-and-backpressure)).

**Trill scan vs poll.** A 30-channel Flex scan takes ≈ 30 × 205 µs ≈ 6.2 ms at the Trill-Linux default of 12 bits, longer than the 5 ms poll, so many polls would return the previous frame. The firmware uses 10 bits (≈ 30 × 78 µs ≈ 2.3 ms, Bela scan-time table) and reads the status byte with the centroids in one 21-byte transaction (≈ 2.3 ms at 100 kHz). A poll that returns the same 6-bit frame ID as the previous one is counted (`stale=`) and not passed on. Touch sensitivity at 10 bits (noise threshold 0.03 of full scale, size divided by 1200 × 2<sup>bits−12</sup> = 300) has **not** been tuned on hardware.

## Pins

| Function | nRF52840 | Source |
|---|---|---|
| IMU SDA / SCL (internal bus, TWISPI1, 400 kHz) | P0.07 / P0.27 | Sense schematic; Zephyr `xiao_ble` pinctrl |
| IMU power (push-pull, high drive '1') | P1.08 | Schematic `6D_PWR`; Zephyr `lsm6ds3tr-c-en` (`NRF_GPIO_DRIVE_S0H1`) |
| IMU INT1 (data ready) | P0.11 | Zephyr `irq-gpios` |
| IMU address | 0x6A (SDO/SA0 to GND) | Schematic |
| Trill SDA / SCL (D4 / D5, TWISPI0, 100 kHz) | P0.04 / P0.05 | [XIAO design](design-xiao-nrf52840.md) (external 4.7 kΩ pull-ups) |
| User RGB LED red / green / blue (active low) | P0.26 / P0.30 / P0.06 | See [Status LED](#status-led) |
| PDM mic CLK / DATA / power (unused) | P1.00 / P0.16 / P1.10 | Schematic; Omi `config.h` uses the same pins |

HFCLK runs from the 32 MHz crystal (USB needs it) and LFCLK from the 32.768 kHz crystal X1, so audio block timing is crystal-accurate.

## Memory layout

| Range | Contents | Written by this project |
|---|---|---|
| `0x00000000–0x00027000` | MBR + SoftDevice S140 7.3.0 | **Never** |
| `0x00027000–0x000EC000` | Application (this image: ~94 KB default, ~105 KB `pcm-synth`) | Yes |
| `0x000EC000–0x000F4000` | Storage partition (Zephyr/Omi settings) | Never |
| `0x000F4000–0x00100000` | UF2 bootloader, MBR params, settings | **Never** |
| RAM `0x20000008–0x20040000` | Application (first 8 bytes kept for the MBR) | — |

The application window comes from Zephyr's `nrf52840_partition_uf2_sdv7.dtsi`, which is the layout of the `xiao_ble` board that Omi's DevKit firmware builds on. Seeed and Omi both document S140 7.3.0 for this bootloader. The firmware never enables the SoftDevice, so it uses all of RAM. It sets `VTOR` to its own vector table at reset (`cortex-m-rt` `set-vtor`).

**Why the UF2 tool is strict.** The Adafruit-derived UF2 bootloader treats everything from the end of the MBR (`0x1000`) up as writable application space, SoftDevice included. A UF2 file with blocks below `0x27000` would overwrite the SoftDevice. [`tools/xiao_uf2.py`](../tools/xiao_uf2.py) refuses any image with data outside `0x27000–0xEC000`, any bootloader-family image (`0xD663823C`), any image without the nRF52840 family ID (`0xADA52840`), and any image whose vector table does not point into RAM and the application.

## Build

Requirements: Rust stable (edition-2024 dependencies, so 1.85 or newer), `rustup target add thumbv7em-none-eabihf`, and `python3` for the UF2 step. No vendor SDK is needed.

```sh
make fw-uf2          # default USB-MIDI build -> dist/xiao-sense-fw-<version>.uf2 (validated)
make fw-uf2-pcm      # optional debug synth build -> dist/xiao-sense-fw-pcm-synth-<version>.uf2
# without make:
cd firmware/xiao-sense && cargo build --release --locked && cd ../..
python3 tools/xiao_uf2.py convert firmware/xiao-sense/target/thumbv7em-none-eabihf/release/xiao-sense-fw -o dist/xiao-sense-fw.uf2
python3 tools/xiao_uf2.py inspect dist/xiao-sense-fw.uf2
```

Cargo features: `pcm-synth` (debug synth + PCM port, USB PID `1209:0003`), `timing-gpio` (logic-analyser outputs on D0/D1, see [USB MIDI](usb-midi.md#measuring-latency)). Neither is on by default.

`cargo run` has no runner configured, so it never touches a device. CI uploads both ELFs, both UF2s and `SHA256SUMS` as a workflow artifact named `xiao-sense-fw-unvalidated-on-hardware`. Artifacts are not releases.

## Loading over USB (explicit steps only)

Nothing loads automatically. Every write needs an explicit drive path, the Board-ID you read from that drive, and `--write`.

1. **Enter the bootloader.** Connect USB-C and double-press RESET quickly. A drive appears: `XIAO-SENSE` on Omi DevKits (`/Volumes/XIAO-SENSE` on macOS, usually `/media/$USER/XIAO-SENSE` on Linux). Use the exact path. The tool rejects wildcards.
2. **Identify (read-only).**
   ```sh
   python3 tools/xiao_uf2.py info /Volumes/XIAO-SENSE
   ```
   Check that `Board-ID` or `Model` names an nRF52840 board and that `SoftDevice` is `S140 7.3.0`. If the drive does not appear, or reports anything else, stop.
3. **Back up the current application (read-only).** The bootloader exposes the current flash contents as `CURRENT.UF2`:
   ```sh
   python3 tools/xiao_uf2.py backup /Volumes/XIAO-SENSE -o backups/
   ```
   This writes the full `CURRENT.UF2` copy, an application-only UF2 split from it (`0x27000–0xEC000`, validated), `INFO_UF2.TXT`, and SHA-256 sums. On an Omi DevKit, also download the matching official DevKit firmware UF2 from the [Omi releases](https://github.com/BasedHardware/omi/releases) as a second restore source.
4. **Dry run**, then write:
   ```sh
   python3 tools/xiao_uf2.py flash dist/xiao-sense-fw.uf2 --drive /Volumes/XIAO-SENSE --board-id <Board-ID from step 2>
   python3 tools/xiao_uf2.py flash dist/xiao-sense-fw.uf2 --drive /Volumes/XIAO-SENSE --board-id <Board-ID from step 2> --write
   ```
   The board reboots into the new application when the last block lands. A "drive went away" message at that point is expected.
5. **Restore.** Double-press RESET again and flash the `*-app-only.uf2` from step 3 (or Omi's release UF2) the same way.

Never copy a `bootloader*.uf2` (for example Omi's `bootloader0.9.0.uf2`) or a full `CURRENT.UF2` backup to the drive. Neither is needed for this workflow, and the tool refuses both.

**Debug probe (optional, not required).** With an SWD probe on the XIAO's bottom pads, `probe-rs run --chip nRF52840_xxAA <ELF>` programs only the sectors the ELF occupies. Before using a probe, dump the whole 1 MB flash as a backup. Never use chip-erase or `--erase-all`: either one removes the SoftDevice and the bootloader, which then have to be restored over SWD.

## USB interfaces

Layout and descriptors live in [`crates/trill-usb`](../crates/trill-usb), whose host tests build the exact firmware layout against a mock driver with the nRF52840 endpoint budget and check the descriptors (IADs, Audio Control / MIDI Streaming headers, jack IDs, bulk endpoints, `wTotalLength`).

| Build | VID:PID (pid.codes **test** IDs) | Product string | Functions (interface numbers) |
|---|---|---|---|
| default | `1209:0002` | `Trill XIAO MIDI (dev)` | CDC ACM diagnostics (0–1), USB-MIDI 1.0 (2–3) |
| `pcm-synth` | `1209:0003` | `Trill XIAO MIDI+PCM (dev)` | diagnostics (0–1), USB-MIDI (2–3), CDC ACM PCM (4–5) |

pid.codes test PIDs are for private development only. Distributed hardware needs its own assigned PID. Each layout has its own PID so a host that caches descriptors per VID:PID does not mix them up. Bus power requested: 100 mA.

**Diagnostics port** (first `ttyACM` / `cu.usbmodem…`; only this port prints text). Banner, boot report, status line every 1 s. Keys:

| Key | Action |
|---|---|
| `s` | Status now. Also any unlisted key |
| `m` | MIDI map and all engine counters |
| `p` | MIDI panic: CC123, CC120, bend centre, pressure 0, RPN 0 (lift finger before the next note) |
| `k` / `q` | Toggle pitch mode bend/steps; toggle scale chromatic/pentatonic (not persisted) |
| `t` / `x` | Toggle tap percussion; toggle motion controllers (not persisted) |
| `c` | Recalibrate gyro (hold still) |
| `b`, `v`, `h`/`?` | Boot report, version + USB IDs, help |
| `L`, `0`–`7`, `a` | LED self-test, manual colour, automatic ([Status LED](#status-led)) |

The status line reports IMU state and counters, scaled accel/gyro, pitch, roll, rotation, calibration, Trill state, reads, errors, repeated frames (`stale=`), touch, then `midi=up|down` (host configured the MIDI function), active note, note on/off counts, packets, events, stalls (`stall=`, write pending > 100 ms), write errors, deferred note ons and coalesced controller updates, then taps and LED. With `pcm-synth` the audio and PCM counters follow.

**USB-MIDI function** (firmware 0.2.0+, `bcdDevice` 0x0200): two virtual cables, embedded IN + OUT jacks each, 64-byte bulk endpoints. Cable 0 carries the instrument (device → host). Cable 1 carries the [configuration protocol](config-protocol.md): SysEx requests from the host are assembled (bounded, realtime bytes passed over) and answered on cable 1 only, in spare packet slots after instrument events, so notes are never delayed by replies. Everything else from the host is read and discarded (counted as `rx_pk`; ignored config messages as `cfg=…`). Settings changed this way are applied atomically through the engine (sounding notes released first) and live in RAM only: a reset restores the defaults. The banner names the config cable. Setup on macOS/iOS: [USB MIDI](usb-midi.md).

**Sensor telemetry** (firmware 0.3.0+): a host can subscribe on cable 1 to 1–100 Hz snapshots of the IMU, orientation, touch and counters ([telemetry](config-protocol.md#sensor-telemetry-firmware-030)). The IMU task publishes one atomic snapshot per sample; the USB writer builds a frame only when it is due, no reply is waiting and instrument events have gone first, so telemetry cannot delay notes or change the mapping. The subscription ends 5 s after the last renewal, on STOP, on USB disconnect and at reset. The status line shows `tlm=<rate>Hz/<frames sent>`. Checked on hardware with 0.3.0.

**Sensor modes and gestures** (firmware 0.4.0, simulation-tested only): tilt notes, theremin, configurable controllers, tap threshold/cooldown and flick gestures are set over SysEx page 1 ([parameters](config-protocol.md#parameters)); the `m` report shows `mode=`, the controller A/B CC numbers and sources, `flick_axis=` and the gesture count. The tap detector takes its threshold and refractory time from the engine configuration on the next IMU sample. 0.4.0 also fixes tap notes stopping after 35.8 min ([details](midi-mapping.md#inputs)).

**PCM port (`pcm-synth` only)** is a test transport, **not** USB Audio. Capture it with:

```sh
python3 tools/pcm_capture.py /dev/ttyACM1 -o take.wav --seconds 10
```

which also reports CRC errors, sequence gaps, device-side drops, and the sample rate measured against the host clock.

## Fault handling

- **IMU:** WHO_AM_I check and software reset at init. After five consecutive read errors, or an init failure, the sensor is powered off and the bias estimate discarded, then retried with exponential backoff (100 ms → 2 s). A missing data-ready edge for 20 ms is counted and the sample is polled anyway.
- **Trill:** optional; firmware ≥ 3 required (frame ID). If absent or failing (4 consecutive read errors), the engine releases any touch note, touch reads as "not touched", and the sensor is retried every 1–2 s. If frames simply stop, the engine releases after 50 ms. A finger still on the strip when the sensor returns does not sound until lifted.
- **IMU absent or failing:** touch MIDI is unaffected. The engine ends any percussion note and returns CC74/CC1 to 0 (also after 100 ms without IMU frames).
- **USB unplug, bus reset, suspend or deconfigure:** the engine drops everything queued and sounding. On the next configuration it sends the reset sequence first ([MIDI mapping](midi-mapping.md#connect-disconnect-and-panic)).
- **Panics and HardFaults** write a short record to non-initialised RAM and reset. The next boot prints it on the diagnostics port. After three consecutive crash resets the firmware starts in **safe mode**: USB diagnostics only, red LED fast blink, no sensors or audio. The counter clears after 30 s of healthy running or on a pin/power-on reset. The record is best effort, because the UF2 bootloader runs between resets and may reuse that RAM. The bootloader stays reachable by double-pressing RESET in every case.
- **Watchdog:** not enabled yet. A running nRF52 watchdog survives reset into the bootloader, and its interaction with this bootloader has not been verified.

## Status LED

> **Hardware-unvalidated.** Pins and polarity are taken from the Seeed schematic and board files below; no LED has been observed on a board running this firmware yet.

**Hardware.** The user LED is one common-anode RGB LED (`RGB6`) with its anode on 3V3 and each cathode on a GPIO through its own resistor, so a channel lights when its pin is driven **low**:

| Channel | nRF52840 | Series R | Sources |
|---|---|---|---|
| Red | P0.26 | R7 2.2 kΩ | [Seeed Sense schematic](https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_PDF.pdf) sheet 02, "LED" block: `P0.26_USER_RED`; [Seeed Arduino variant](https://github.com/Seeed-Studio/Adafruit_nRF52_Arduino/blob/master/variants/Seeed_XIAO_nRF52840_Sense/variant.cpp) `LED_RED` = D11 = P0.26; [Zephyr `xiao_ble_common.dtsi`](https://github.com/zephyrproject-rtos/zephyr/blob/main/boards/seeed/xiao_ble/xiao_ble_common.dtsi) `led0` `GPIO_ACTIVE_LOW` |
| Green | P0.30 | R4 10 kΩ | Same; `P0.30_USER_GREEN`, `LED_GREEN` = D13, `led1` `GPIO_ACTIVE_LOW` |
| Blue | P0.06 | R3 2.2 kΩ | Same; `P0.06_USER_BLUE`, `LED_BLUE` = D12, `led2` `GPIO_ACTIVE_LOW` |

The Seeed variant's `initVariant()` drives all three pins high (off) at boot, which confirms active-low. Its `LED_STATE_ON (1)` define is misleading for this board and is not used here.

The separate red **charge LED** (`CHG0`, R5 2.2 kΩ from 3V3) sits on the BQ25101 `~CHG` net, which is also routed to P0.17 as an input. The charger drives it, so firmware cannot control it and this code does not touch P0.17. If it is lit, the battery is charging. It is not a status indication.

**Driver.** `crates/status-led` (`no_std`, no `unsafe`) splits the work in two:

- `RgbLed` wraps three embedded-hal `OutputPin`s with a polarity and only writes a pin when its channel changes.
- `StatusLed` turns a snapshot of system state into one indication and colour.

The firmware creates all three pins at `Level::High` (off) before the LED task runs, so nothing lights during start-up. The LED task runs on the lowest-priority (thread) executor with a 20 ms `Ticker`, so it never busy-waits and never runs above the audio or USB executors. A blocking sensor I²C timeout can delay it by up to about 5 ms.

**Colours are digital mixes only**, with each channel fully on or off: there is no PWM and no brightness control. PWM would cost a PWM peripheral and an EasyDMA sequence for a status light, and the unequal series resistors already unbalance the mixes. Expect yellow and white to look reddish because green is fed through 10 kΩ.

**Indications, highest priority first.** The first matching row wins, so activity never hides a fault. Blink timings are on/period in ms, and every blink starts "on" when the state changes.

| # | Indication (`led=`) | Colour | Pattern | Condition (from real firmware state) |
|---|---|---|---|---|
| 1 | `manual` / `selftest` | chosen / sequence | solid | Debug key (below). Manual times out after 60 s. |
| 2 | `safe_mode` | red | 100/200 fast blink | Crash loop detected (`safe_mode=1`) |
| 3 | `imu_fault` | red | 500/1000 | IMU in `retry`, or back in `init`/`off` after it had run |
| 4 | `audio_fault` | magenta | 500/1000 | `late` or `resync` counter rose; held 3 s after the last one |
| 5 | `trill_lost` | yellow | 500/1000 | Trill was `run` and now fails. A Trill that was never detected is not shown, because it is optional. |
| 6 | `prev_crash` | yellow | 100/200 fast blink | Previous run ended in a panic or HardFault (boot report `last=`), first 10 s only |
| 7 | `booting` | white | solid | IMU not running yet |
| 8 | `calibrating` | cyan | 500/1000 | IMU running and the gyro bias is not estimated yet (`cal=0`). Hold still. Happens at start, after an IMU recovery, and after `c`. |
| 9 | `tap` | white | 120 ms flash | Tap counter rose |
| 10 | `touch` | green | solid | Finger on the Trill |
| 11 | `motion` | blue | solid | Rotation > 60 dps |
| 12 | `ready_stream` | blue | 50/1000 heartbeat | Idle, with a USB host that has configured the MIDI function (or holds the `pcm-synth` PCM port open). USB-level state only: it does not show that an app is listening. |
| 13 | `ready` | green | 50/1000 heartbeat | Idle |

There is no BLE indication, because BLE is not implemented. Time is a wrapping 32-bit millisecond count, and blink phase and hold timers are tested across the wrap at about 49.7 days.

**Debug keys** on diagnostics port 0:

| Key | Action |
|---|---|
| `L` | Self-test: red, green, blue, yellow, cyan, magenta, white, off, 400 ms each, then automatic |
| `0`–`7` | Manual colour by channel bits: 1 red, 2 green, 4 blue (`3` yellow, `5` magenta, `6` cyan, `7` white, `0` off). Overrides every status, including faults, for 60 s or until `a`. |
| `a` | Back to automatic |

The status line shows `led=<indication>/<colour>`, so the override is always visible over USB.

**Current draw** (estimate, not measured): I ≈ (3.3 V − V<sub>f</sub>) / R. That gives about 0.5–0.6 mA for red, about 0.1–0.3 mA for blue and under 0.1 mA for green, or about 1 mA at most with all three on. This is well within GPIO standard drive. Idle heartbeats have a 5 % duty cycle, so they average tens of µA. The solid states (`booting`, `touch`, `motion`, manual) draw the full amount for as long as they last. For battery builds, prefer `0` (off) or a future "LED off when idle" setting.

## Hardware bring-up checklist

Record the result of each step in the PR or issue that marks this design validated.

1. `xiao_uf2.py info` output (Board-ID, bootloader version, SoftDevice).
2. Enumeration: one CDC port and one MIDI port (`lsusb -v -d 1209:0002`, macOS System Information, or Audio MIDI Setup). Then run the [USB-MIDI acceptance procedure](usb-midi.md#hardware-acceptance-procedure).
3. Diagnostics banner: `consecutive_crashes=0`, `safe_mode=0`.
4. IMU: `imu=run`, `n` increasing by about 416 per second, `err=0`. Flat on a table: `a≈[0,0,1]g`. Hold still for 1 s: `cal=1`, `rot` near 0.
5. Axis signs: tilt the USB end down, then up, and note the sign of `pitch`. Roll left and right and note `roll`. Fix the mapping in `motion-synth` if the instrument should respond the other way.
6. Trill (if fitted): `trill=run`, `touch=yes` while touching, `reads` rising by ~200/s, `stale` small compared with `reads` (a large ratio means the scan is slower than the poll).
7. Audio (`pcm-synth` build only): `late=0`, `resync=0`, render time well below 2000 µs. Capture 10 s with `pcm_capture.py`: `crc_errors 0`, `seq_gaps 0`, measured rate within 0.1 % of 32000 Hz.
8. LED: press `L` and confirm red, green, blue, yellow, cyan, magenta, white, then off, in that order (this checks pins and polarity). The LED must be dark before the firmware starts. Then confirm `cyan` until still, then the `ready` green heartbeat. Record whether the mixes are distinguishable.
9. Leave it running for 10 minutes and compare counters.

## Latency measurement

The firmware measures on target:

- `ctl_age` (`pcm-synth` only): time from the IMU sample timestamp (data-ready wake) to the start of the audio block that consumed it.
- `render` (`pcm-synth` only): CPU time per block.

For the MIDI path see [USB MIDI: measuring latency](usb-midi.md#measuring-latency).

End-to-end motion → sound needs an external reference:

1. **I²S/DAC path (when added):** tap the board on a piezo or second accelerometer recorded on one channel of an audio interface, record the DAC output on the other, and measure onset to onset over 50+ taps. Report median and 95th percentile.
2. **USB PCM path:** the host side adds unbounded buffering, so only device-side numbers (`ctl_age` + one block + USB frame) are meaningful there. Do not quote host playback latency as instrument latency.
3. **Scope method:** the `timing-gpio` feature drives D0/D1 (see `src/timing.rs`); measure both on a scope or logic analyser.

Design budget (estimates, not measurements): [motion-synth.md](motion-synth.md#latency-budget).

## Not implemented yet

- PDM microphone capture. Pins and peripheral are free; the planned path is 16 kHz mono into a separate ring buffer, so it cannot disturb synth timing.
- I²S DAC or PWM audio output ([options](motion-synth.md#output-paths)).
- USB Audio Class (sound card) output, BLE (any service, including BLE-MIDI), MPE, multi-touch voices, Omi protocol compatibility.
- Watchdog, low-power modes, settings storage.
- Battery voltage or charge-status reading. Charging is done by the board's charger IC without firmware ([XIAO design: power](design-xiao-nrf52840.md#power-usb-and-battery)); the firmware does not read `P0.17` (charge status), `P0.14`/`P0.31` (battery divider) or drive `P0.13` (charge current).
