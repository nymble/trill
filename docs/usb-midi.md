# USB MIDI (XIAO nRF52840 Sense)

The default firmware build is a **class-compliant USB-MIDI 1.0** device plus a CDC ACM diagnostics port. macOS and iOS use their built-in drivers, so no driver install is needed. The instrument sends MIDI only; sound comes from a synth on the host. Event mapping: [MIDI mapping](midi-mapping.md). Firmware details: [firmware-xiao-sense.md](firmware-xiao-sense.md).

> **Status:** descriptors are checked by host tests, and both builds link and pass the UF2 checks in CI. **Enumeration on macOS, iOS or any host has not been tested**. No DAW or app has been tested. All timings below are targets or estimates.

## What the device presents

| Item | Value |
|---|---|
| VID:PID | `1209:0002` (pid.codes **test** PID: development only; a product needs its own PID). `pcm-synth` build: `1209:0003` |
| Product / manufacturer | `Trill XIAO MIDI (dev)` / `nymble/trill` |
| Device class | `EF/02/01` composite with IADs |
| Functions | CDC ACM diagnostics (interfaces 0–1); Audio Control (2) + MIDI Streaming (3), two virtual cables (embedded IN + OUT jacks each): cable 0 = instrument, cable 1 = configuration ([protocol](config-protocol.md)); bulk endpoints of 64 bytes |
| Device release (`bcdDevice`) | `0x0200` (firmware 0.2.0) |
| Power request | 100 mA |
| Not present | USB Audio streaming (no sound card), MIDI 2.0 / UMP, MPE, BLE |

Built with `embassy-usb` 0.6 `class::midi` (MIT/Apache-2.0). `crates/trill-usb` holds the layout, and its tests check it against USB 2.0 ch. 9, the IAD ECN and USB-MIDI 1.0: interface numbering, IAD class codes, AC header (bcdADC 1.00, `baInterfaceNr` = MS interface), MS header (bcdMSC 1.00, `wTotalLength` = actual bytes), jack IDs and sources, endpoint/jack association, and endpoint budget within the nRF52840 limit (7 IN + 7 OUT). The MIDI endpoints use 7-byte standard endpoint descriptors, which `embassy-usb` emits. The USB-MIDI 1.0 spec examples show 9-byte audio-class endpoint descriptors. Whether Apple hosts accept the 7-byte form is part of the acceptance test below.

## Build and load

```sh
make fw-uf2        # or: cd firmware/xiao-sense && cargo build --release --locked, then tools/xiao_uf2.py convert/inspect
```

Load **only** after the target is confirmed: read `INFO_UF2.TXT` from the bootloader drive with `tools/xiao_uf2.py info` (nRF52840 board, SoftDevice S140 7.3.0) and take the backup, as in [Loading over USB](firmware-xiao-sense.md#loading-over-usb-explicit-steps-only). Nothing in this repository flashes automatically. On an Omi DevKit this replaces Omi's application ([Omi integration](omi-integration.md)).

## Hardware acceptance procedure

Record results (host model, OS version, adapter, pass/fail, counters) in the bring-up issue. None of these steps have been done yet.

**A. macOS (Audio MIDI Setup / CoreMIDI)**
1. Plug in the board (direct USB-C, then through a hub). *System Information → USB* should show `Trill XIAO MIDI (dev)`, `1209:0002`.
2. *Audio MIDI Setup → Window → Show MIDI Studio*: a device `Trill XIAO MIDI (dev)` with two ports appears and is not greyed out. The first port carries the instrument and the second the configuration replies. Earlier 0.1 builds showed one port; if macOS still shows one, remove the stale device in MIDI Studio and replug.
3. Open the diagnostics port (`screen /dev/cu.usbmodem… 115200`; the baud rate is ignored). The banner shows `usb 1209:0002`. Status shows `midi=up` and the LED shows the blue heartbeat when idle.
4. Watch the port with a CoreMIDI monitor app (for example *MIDI Monitor*). Touch the strip: one pitch bend, then Note On; slide: bend; lift: Note Off and pressure 0. The connect sequence (CC123, CC120, bend 8192, pressure 0, RPN 0 = 24) appears on (re)plug. Compare with the [example trace](midi-mapping.md#example-trace).
5. Press `p`: the reset sequence appears. Unplug while holding a note, replug: no note starts until the finger is lifted and touched again.
6. Quit the monitor and leave the device plugged in for 1 minute with touches. Then check `stall=` and `defer=` in `s`/`m`. This records how macOS behaves when no app reads the port.
7. IMU independence: on a plain XIAO nRF52840 (no IMU), touch MIDI must still work while the status shows `imu=retry`.

**B. iPhone / iPad over USB-C** (USB-C to USB-C cable, then through a powered USB-C hub)
1. Open a CoreMIDI app that lists sources. `Trill XIAO MIDI (dev)` should appear.
2. Touch → notes. Record whether the device enumerates when bus-powered directly and whether it needs the hub.

**C. iPhone / iPad with Lightning** (Apple Lightning to USB 3 Camera Adapter **with** its power input connected; then the Lightning to USB Camera Adapter without power)
1. As B. Record whether iOS reports that the accessory needs too much power. The firmware requests 100 mA. A battery on the board also charges from VBUS, which adds about 50 mA nominal, not measured ([power](design-xiao-nrf52840.md#power-usb-and-battery)).

**Pass criteria:** enumerates on every host tested; all four message types (note, bend, pressure, CC) arrive and decode as in the trace; no stuck note after unplug/replug, panic, Trill disconnect (pull SDA) or IMU absence; `werr=0` and `emerg_off=0` after 10 minutes of playing.

## Latency

**Target:** gesture-to-sound under **10 ms at the 95th percentile**. This is a goal, not a measured result.

| Stage | Bound / estimate (not measured) | Notes |
|---|---|---|
| Touch acquisition | ≤ 5 ms poll + ≈ 2.3 ms scan + ≈ 2.3 ms I²C read | Worst case: a touch begins just after a scan starts. Polling and scanning are not synchronised (EVT pin unused) |
| IMU acquisition | 2.4 ms ODR + ≈ 0.4 ms read | Every 416 Hz sample is read |
| Filtering | Note onset: none. Pressure τ 15 ms, rotation τ 30 ms, tilt τ 0.5 s | Smoothing shapes continuous controls, not onsets |
| Engine → USB | Writer wakes on each new sample (2 ms tick only for timeouts); continuous controllers ≤ 1 per 4 ms each | Note messages bypass the rate limit |
| USB-MIDI transport | ≤ 1 ms full-speed frame for bulk IN under light bus load (provisional assumption) | Host-controller scheduling varies; measure |
| Host MIDI → synth | Host/app dependent | Unknown |
| Synth audio buffer + output | Host/app setting (for example 64–256 frames at 48 kHz ≈ 1.3–5.3 ms per buffer) | Set by the app or DAW, outside this project |

### Measuring latency

- `timing-gpio` build (D0/D1 must have nothing else connected): D0 goes high when a processed frame has a touch, and D1 is high while a packet containing a Note On is handed to USB. A logic analyser on D0, D1 and the USB D+/D− lines (or a USB analyser) separates firmware time from host time.
- End to end: record a contact microphone on the strip and the host's audio output on two channels of one interface, 50+ taps, report median and p95.
- Do not publish numbers without the method and raw data.

## Deferred

Bluetooth LE MIDI (licensing decision pending), MPE, multi-touch voices, PDM microphone input, USB Audio output.
