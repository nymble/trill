# Firmware: XIAO nRF52840 Sense

Rust ([Embassy](https://embassy.dev)) application image for the **Seeed Studio XIAO nRF52840 Sense**: USB diagnostics, the on-board LSM6DS3TR-C accelerometer + gyroscope, an optional Trill on D4/D5, and the audio-rate [motion synth](motion-synth.md).

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

| Executor (NVIC priority) | Task | Rate / deadline |
|---|---|---|
| High (`EGU1_SWI1`, P5) | audio: take control snapshot, render one block, queue it for USB | 64 samples @ 32 kHz = **2 ms** per block, deadline from sample count |
| Medium (`EGU0_SWI0`, P6) | USB device, diagnostics port, PCM port | USB full speed |
| Thread (lowest) | IMU: data-ready wait, 14-byte burst read, motion processing, mapping | **416 Hz** (2.4 ms) |
| Thread | Trill: identify, configure, centroid read | 200 Hz (5 ms) |
| Thread | [Status LED](#status-led): select indication, write pins on change; crash-counter reset after 30 s | 50 Hz tick (20 ms) |

Sensor I/O blocks for bounded time (every I²C transaction has a 5 ms timeout), and audio and USB preempt it. Control → audio hand-off is a fixed-size mailbox: continuous values are latest-wins, taps accumulate so none is lost. The audio → USB queue holds 8 blocks (16 ms). The audio task never waits on it: when it is full, the block is dropped and counted.

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
| `0x00027000–0x000EC000` | Application (this image, ~88 KB) | Yes |
| `0x000EC000–0x000F4000` | Storage partition (Zephyr/Omi settings) | Never |
| `0x000F4000–0x00100000` | UF2 bootloader, MBR params, settings | **Never** |
| RAM `0x20000008–0x20040000` | Application (first 8 bytes kept for the MBR) | — |

The application window comes from Zephyr's `nrf52840_partition_uf2_sdv7.dtsi`, which is the layout of the `xiao_ble` board that Omi's DevKit firmware builds on. Seeed and Omi both document S140 7.3.0 for this bootloader. The firmware never enables the SoftDevice, so it uses all of RAM. It sets `VTOR` to its own vector table at reset (`cortex-m-rt` `set-vtor`).

**Why the UF2 tool is strict.** The Adafruit-derived UF2 bootloader treats everything from the end of the MBR (`0x1000`) up as writable application space, SoftDevice included. A UF2 file with blocks below `0x27000` would overwrite the SoftDevice. [`tools/xiao_uf2.py`](../tools/xiao_uf2.py) refuses any image with data outside `0x27000–0xEC000`, any bootloader-family image (`0xD663823C`), any image without the nRF52840 family ID (`0xADA52840`), and any image whose vector table does not point into RAM and the application.

## Build

Requirements: Rust stable (edition-2024 dependencies, so 1.85 or newer), `rustup target add thumbv7em-none-eabihf`, and `python3` for the UF2 step. No vendor SDK is needed.

```sh
make fw-uf2          # clippy-clean release ELF -> dist/xiao-sense-fw-<version>.uf2 (validated)
# without make:
cd firmware/xiao-sense && cargo build --release --locked && cd ../..
python3 tools/xiao_uf2.py convert firmware/xiao-sense/target/thumbv7em-none-eabihf/release/xiao-sense-fw -o dist/xiao-sense-fw.uf2
python3 tools/xiao_uf2.py inspect dist/xiao-sense-fw.uf2
```

`cargo run` has no runner configured, so it never touches a device. CI uploads the ELF, the UF2 and `SHA256SUMS` as a workflow artifact named `xiao-sense-fw-unvalidated-on-hardware`.

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

Development identifiers: VID:PID `1209:0001` (pid.codes test ID, testing only; get a real PID before distributing hardware). The device enumerates as two CDC ACM ports:

| Port | Content |
|---|---|
| 0 (first function) | Text diagnostics: banner, boot report, status line every 1 s. Keys: `s` status, `c` recalibrate gyro, `b` boot report, `v` version, `h` help; LED: `L` self-test, `0`–`7` manual colour, `a` automatic ([Status LED](#status-led)) |
| 1 (second function) | Framed PCM test stream, active while the host holds DTR |

On Linux they usually appear as `/dev/ttyACM0` and `/dev/ttyACM1`, and on macOS as two `/dev/cu.usbmodem…` entries. Port names are not guaranteed, so confirm with the banner: only port 0 prints text.

The status line reports IMU state, sample/error/power-cycle counters, scaled accel/gyro, pitch, roll, rotation, calibration flag, Trill state and touch, audio blocks, late blocks, resyncs, starved blocks, render time (last/max, DWT cycle counter), control age (last/max), PCM sent/dropped, tap count and the LED indication/colour (`led=ready/green`).

The PCM port is a test transport, **not** a USB Audio or MIDI device. iPhone/iPad and DAWs will not see it as audio. Capture it with:

```sh
python3 tools/pcm_capture.py /dev/ttyACM1 -o take.wav --seconds 10
```

which also reports CRC errors, sequence gaps, device-side drops, and the sample rate measured against the host clock.

## Fault handling

- **IMU:** WHO_AM_I check and software reset at init. After five consecutive read errors, or an init failure, the sensor is powered off and the bias estimate discarded, then retried with exponential backoff (100 ms → 2 s). A missing data-ready edge for 20 ms is counted and the sample is polled anyway.
- **Trill:** optional. If absent or failing, it is retried every 1–2 s and touch input reads as "not touched".
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
| 12 | `ready_stream` | blue | 50/1000 heartbeat | Idle, with the host holding the PCM port open |
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
2. Enumeration: two CDC ports (`lsusb -v -d 1209:0001` or System Information).
3. Diagnostics banner: `consecutive_crashes=0`, `safe_mode=0`.
4. IMU: `imu=run`, `n` increasing by about 416 per second, `err=0`. Flat on a table: `a≈[0,0,1]g`. Hold still for 1 s: `cal=1`, `rot` near 0.
5. Axis signs: tilt the USB end down, then up, and note the sign of `pitch`. Roll left and right and note `roll`. Fix the mapping in `motion-synth` if the instrument should respond the other way.
6. Trill (if fitted): `trill=run`, `touch=yes` while touching.
7. Audio: `late=0`, `resync=0`, render time well below 2000 µs. Capture 10 s with `pcm_capture.py`: `crc_errors 0`, `seq_gaps 0`, measured rate within 0.1 % of 32000 Hz.
8. LED: press `L` and confirm red, green, blue, yellow, cyan, magenta, white, then off, in that order (this checks pins and polarity). The LED must be dark before the firmware starts. Then confirm `cyan` until still, then the `ready` green heartbeat. Record whether the mixes are distinguishable.
9. Leave it running for 10 minutes and compare counters.

## Latency measurement

The firmware measures on target:

- `ctl_age`: time from the IMU sample timestamp (data-ready wake) to the start of the audio block that consumed it.
- `render`: CPU time per block.

End-to-end motion → sound needs an external reference:

1. **I²S/DAC path (when added):** tap the board on a piezo or second accelerometer recorded on one channel of an audio interface, record the DAC output on the other, and measure onset to onset over 50+ taps. Report median and 95th percentile.
2. **USB PCM path:** the host side adds unbounded buffering, so only device-side numbers (`ctl_age` + one block + USB frame) are meaningful there. Do not quote host playback latency as instrument latency.
3. **Scope method:** add a GPIO toggle at IMU data-ready and at block start, and measure both on a scope.

Design budget (estimates, not measurements): [motion-synth.md](motion-synth.md#latency-budget).

## Not implemented yet

- PDM microphone capture. Pins and peripheral are free; the planned path is 16 kHz mono into a separate ring buffer, so it cannot disturb synth timing.
- I²S DAC or PWM audio output ([options](motion-synth.md#output-paths)).
- USB Audio Class or USB-MIDI device, BLE (any service), Omi protocol compatibility.
- Watchdog, low-power modes, battery monitoring, settings storage.
