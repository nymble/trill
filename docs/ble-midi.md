# MIDI over Bluetooth LE (BLE-MIDI)

A build option for battery-powered boards (T1 and up). The board keeps
its USB-MIDI device and also advertises as a standard BLE-MIDI
instrument, so a Mac, iPhone, iPad or DAW can use it without a cable.

USB stays the setup path: firmware installs, configuration, sensor
telemetry and the microphone test use USB only. Bluetooth carries the
instrument MIDI (port 1) and the battery level, nothing else.

**Bluetooth needs a battery.** The board advertises and keeps a link only
while a battery is detected ([battery.md](battery.md)); without one it
stays USB-only and the app says "Bluetooth needs a battery". USB MIDI
works in every case.

## Settings and defaults

Two separate switches, set from the app (Settings › Detected hardware or
Settings › Connection) with protocol actions 10–13 and reported by
`GET_STATUS` ([config-protocol.md](config-protocol.md#battery-and-bluetooth-status-variant-bit-5)):

| Setting | Default | On | Off |
|---|---|---|---|
| **Discoverable** | on | Advertises every 100 ms so hosts can find `Trillium XXXX` | Stops advertising at once. A host that is already connected stays connected until it leaves or Bluetooth MIDI is turned off |
| **Bluetooth MIDI** | on | The advertisement carries the BLE-MIDI service UUID; instrument MIDI goes to a host that opens the port | A connected host is disconnected; no MIDI is sent over Bluetooth; the board may still advertise its name and Battery Service |

Both on by default, so a battery board with this firmware shows up in
Bluetooth MIDI panels without any setup. Discoverable off is the way to
make the board invisible; both off means Bluetooth is idle.

The settings are stored on the board in one flash page at `0xEC000`
(start of the storage area, `0xEC000–0xF4000`; the UF2 bootloader at
`0xF4000` and the SoftDevice below `0x27000` are never written). The
page is an append-only log of 8-byte records (`trill_board::settings`):
a change costs one write, the page is erased once every 512 changes, and
a torn record is skipped, so a power cut keeps the previous value.
Installing a UF2 does not touch the page (images stop at `0xEC000`).
Arduino sketches keep their file system at `0xED000` and up; firmware
that used the Zephyr storage partition from `0xEC000` (for example an
Omi DevKit image) loses whatever it kept in that first page.

Status reported to the app: battery present/absent/checking, voltage,
percent, charging, USB power; discoverable, Bluetooth MIDI, stored;
link (off, advertising, connected, streaming) and why Bluetooth is off
(no battery, turned off, still checking, unavailable, not in this
firmware).

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
| Service | BLE-MIDI `03B80E5A-EDE8-4B33-A751-6CE34EC4C700`, characteristic `7772E5DB-3868-4112-A1A9-F2669D106BF3` (read, write without response, notify). Battery Service `0x180F`, Battery Level `0x2A19` (read, notify) |
| Packets | `crates/ble-midi`: header byte with timestamp bits 12–7, a timestamp byte (bits 6–0) before every message, full status bytes, one 13-bit millisecond timestamp per packet, up to ATT MTU − 3 bytes (MTU offered: 131) |
| Name | `Trillium XXXX`, where `XXXX` is the low 16 bits of the chip's factory BLE address in hex. The advertisement carries the BLE-MIDI service UUID (Battery Service UUID when Bluetooth MIDI is off); the scan response carries the name |
| Link | One central at a time, no pairing or bonding; preferred connection interval 7.5–15 ms; advertising every 100 ms |
| MIDI | The same instrument messages USB sends on cable 0, produced once by the event engine. Writes from the central are ignored |
| Report | HELLO variant bit 4 (`0x10`) is set when the Bluetooth stack started (whether it advertises depends on the battery and the settings); `GET_STATUS` gives the live state. The diagnostics banner shows `ble-midi: <state> discoverable=… midi=… stored=… reason=… name="Trillium XXXX" packets=… dropped=…` |
| Fallback | After repeated crashes (safe mode), or when no SoftDevice is found in flash (its info-struct magic), the board boots USB-only without enabling it. The banner line reports the SoftDevice found (e.g. `softdevice S140 7.3.0 fwid=0x0123`) |

When both USB and a Bluetooth central are listening, every instrument
message goes to both. If USB appears during a Bluetooth session, the
engine restarts so both hosts get the reset sequence.

On a board without a battery (T0) the BLE image never advertises, so
it costs only the idle SoftDevice.

## Pairing

- **iPhone and iPad:** Settings › Connection › Bluetooth MIDI… in the app
  opens the system Bluetooth MIDI panel (`CABTMIDICentralViewController`).
  Tap `Trillium XXXX`. Other MIDI apps then see it as a MIDI source.
- **Mac:** Bluetooth MIDI… opens the system panel
  (`CABTLEMIDIWindowController`), or use Audio MIDI Setup › Window › Show
  MIDI Studio › Bluetooth Configuration and click Connect.
- The app's MIDI monitor uses the USB instrument port when it is present
  and the Bluetooth source otherwise. Settings › Detected hardware shows
  the Discoverable and Bluetooth MIDI switches, "Discoverable: on/off",
  "Bluetooth MIDI: on/off/connected" and the battery when the connected
  firmware reports them. The switches are disabled, with the reason,
  when no battery is detected.

## Licence note

The BLE image contains only this project's code and permissively
licensed Rust crates; the SoftDevice it calls is the Nordic-licensed
binary already in the board's flash and is not distributed by this
project.

**Decision 2026-11-19:** BLE-MIDI firmware is published in public releases; the image contains no Nordic code and uses the SoftDevice already on the board. Releases attach
`xiao-sense-fw-ble-midi-<version>.uf2` next to the USB-only
`xiao-sense-fw-<version>.uf2` (see
[music-connectivity.md](music-connectivity.md#licensing-notes-for-ble-engineering-analysis-not-legal-advice)).

## Not yet measured

Latency and battery drain on a battery-powered board, the connection
intervals macOS and iOS actually grant, how hosts schedule by the
BLE-MIDI timestamps, and the battery readings on real hardware.
