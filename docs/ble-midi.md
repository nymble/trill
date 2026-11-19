# MIDI over Bluetooth LE (BLE-MIDI)

A build option for battery-powered boards (T1 and up). The board keeps
its USB-MIDI device and also advertises as a standard BLE-MIDI
instrument, so a Mac, iPhone, iPad or DAW can use it without a cable.

USB stays the setup path: firmware installs, configuration, sensor
telemetry and the microphone test use USB only. Bluetooth carries the
instrument MIDI (port 1) and nothing else.

## Build

```sh
make fw-uf2-ble        # dist/xiao-sense-fw-ble-midi-<version>.uf2
# or
cd firmware/xiao-sense && cargo build --release --locked --features ble-midi
```

The result is an application-only UF2 (`0x27000–0xEC000`), checked by
`tools/xiao_uf2.py` like every other image. CI and releases publish it
next to the USB-only UF2. Install it the same way (double-press RESET,
copy the UF2 to `XIAO-SENSE`); the app's built-in installer still
carries the USB-only image.

## How it works

| Item | Value |
|---|---|
| Stack | `nrf-softdevice` (pinned commit) on the S140 7.3.0 SoftDevice that the factory bootloader keeps below `0x27000`. Nothing is written there; this image only enables the SoftDevice at run time |
| RAM | `0x20000000–0x20008000` belongs to the SoftDevice (`firmware/xiao-sense/link/memory-ble.x`); the application starts at `0x20008000` |
| Interrupts | VTOR goes back to the MBR at boot so the SoftDevice sees its interrupts first; it forwards the rest to this image. Application interrupts run at P2, P3 and P5–P7. The IMU executor moved from `EGU2_SWI2` (SoftDevice events) to `EGU3_SWI3` in every build |
| USB power | Reported by the SoftDevice (`USBDETECTED`, `USBREMOVED`, `USBPWRRDY`) and fed to embassy-usb through a software detector |
| Service | BLE-MIDI `03B80E5A-EDE8-4B33-A751-6CE34EC4C700`, characteristic `7772E5DB-3868-4112-A1A9-F2669D106BF3` (read, write without response, notify) |
| Packets | `crates/ble-midi`: header byte with timestamp bits 12–7, a timestamp byte (bits 6–0) before every message, full status bytes, one 13-bit millisecond timestamp per packet, up to ATT MTU − 3 bytes (MTU offered: 131) |
| Name | `Trillium XXXX`, where `XXXX` is the low 16 bits of the chip's factory BLE address in hex. The advertisement carries the BLE-MIDI service UUID; the scan response carries the name |
| Link | One central at a time, no pairing or bonding; preferred connection interval 7.5–15 ms; advertising every 100 ms |
| MIDI | The same instrument messages USB sends on cable 0, produced once by the event engine. Writes from the central are ignored |
| Report | HELLO variant bit 4 (`0x10`) is set while BLE-MIDI is running. The diagnostics banner shows `ble-midi: <state> name="Trillium XXXX" packets=… dropped=…` |
| Fallback | After repeated crashes (safe mode), or when no SoftDevice is found in flash (its info-struct magic), the board boots USB-only without enabling it. The banner line reports the SoftDevice found (e.g. `softdevice S140 7.3.0 fwid=0x0123`) |

When both USB and a Bluetooth central are listening, every instrument
message goes to both. If USB appears during a Bluetooth session, the
engine restarts so both hosts get the reset sequence.

There is no runtime switch yet: the BLE image always advertises. A
configuration action to turn it off (to save power on a USB-only T0)
needs a new action code, protocol vectors and an app control.

## Pairing

- **iPhone and iPad:** Settings › Connection › Bluetooth MIDI… in the app
  opens the system Bluetooth MIDI panel (`CABTMIDICentralViewController`).
  Tap `Trillium XXXX`. Other MIDI apps then see it as a MIDI source.
- **Mac:** Bluetooth MIDI… opens the system panel
  (`CABTLEMIDIWindowController`), or use Audio MIDI Setup › Window › Show
  MIDI Studio › Bluetooth Configuration and click Connect.
- The app's MIDI monitor uses the USB instrument port when it is present
  and the Bluetooth source otherwise. Settings › Detected hardware shows
  "BLE MIDI" when the connected firmware reports it.

## Licence note

The BLE image contains only this project's code and permissively
licensed Rust crates; the SoftDevice it calls is the Nordic-licensed
binary already in the board's flash and is not distributed by this
project. Whether that is enough for distributing BLE builds under
GPL-3.0-only is an open decision for the copyright holder (see
[music-connectivity.md](music-connectivity.md#licensing-notes-for-ble-engineering-analysis-not-legal-advice)).

## Not yet measured

Latency and battery drain on a battery-powered board, the connection
intervals macOS and iOS actually grant, and how hosts schedule by the
BLE-MIDI timestamps.
