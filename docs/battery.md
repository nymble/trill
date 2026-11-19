# Battery detection and level

Every firmware build measures the battery of the Seeed Studio XIAO
nRF52840 (Sense) and reports it to the app (`GET_STATUS`, variant bit 5,
[config-protocol.md](config-protocol.md#battery-and-bluetooth-status-variant-bit-5)).
The `ble-midi` build also publishes it over Bluetooth with the standard
Battery Service and uses it to decide whether Bluetooth may run:
**Bluetooth needs a battery** ([ble-midi.md](ble-midi.md)).

## Circuit

Sources: Seeed Studio XIAO nRF52840 KiCad project v1.2
(`260828_Seeed_Studio_XIAO_nRF52840_v1.2.zip` on the
[Seeed wiki](https://wiki.seeedstudio.com/XIAO_BLE/), nets `VBAT`,
`P0.14_~{READ_BAT}`, `P0.31_AIN7_BAT`, `P0.17_~{CHG}`, `P0.13_HICHG`,
resistors `1M_1%` and `510k_1%`), the wiki pin table and FAQ Q3/Q4, and
Seeed's Arduino board variant (`variant.cpp`: D14 = P0.14 READ_BAT,
D22 = P0.13 HICHG, D23 = P0.17 ~CHG, D32 = P0.31 VBAT).

| Signal | Pin | Use in this firmware |
|---|---|---|
| READ_BAT (divider enable, active low) | P0.14 | Output **LOW from boot, always** |
| Battery voltage | P0.31 / AIN7 | VBAT × 510 k / (1 M + 510 k), read once a second |
| Charger status ~CHG (BQ25101, open drain; also the red charge LED) | P0.17 | Input, no pull. LOW = charging; released when not charging or done |
| Charge current select HICHG | P0.13 | Not driven. Input (reset default) = about 50 mA; output LOW would select about 100 mA |

## Safety: keep P0.14 LOW

Seeed's FAQ: with P0.14 HIGH the reading path is disabled and P0.31 may
reach its 3.6 V input limit, which risks damaging the pin; keep P0.14
LOW when reading and never set it HIGH while the battery charges. A
floating P0.14 (the reset state, and what firmware 0.7.0 and earlier
left it in) is no better.

This firmware therefore drives P0.14 LOW immediately after the HAL
starts, in every build and in safe mode, and never releases it (the
pin is owned by the battery task, or deliberately leaked in safe mode).
The divider then draws about 4.2 V / 1.51 MΩ ≈ 2.8 µA from the battery.
The bootloader and other firmware are outside this guarantee.

## Measurement

SAADC, AIN7 single-ended, internal 0.6 V reference, gain 1/6 (3.6 V full
scale), 12 bit, 8× oversampling, 40 µs acquisition (the source impedance
is about 340 kΩ; the nRF52840 datasheet allows 800 kΩ at 40 µs), offset
calibration at start. `mV = code × 3600 / 4096 × 1510 / 510`
(`trill_board::battery::mv_from_adc`).

**Percentage** is interpolated from a typical single-cell LiPo resting
curve (`trill_board::battery::LIPO_CURVE`: 3.30 V = 0 %, 3.84 V = 50 %,
4.18 V = 100 %). It is approximate: the curve depends on the cell, load
and temperature, and readings while charging are higher than the
resting voltage, so the percentage reads high then.

## Is a battery present?

The XIAO has no battery-detect pin, and with USB power and no battery
the charger output on VBAT can read like a full cell. The firmware
judges presence from charger status and voltage behaviour
(`trill_board::battery::Detector`), one observation per second:

1. **No USB power:** the board is running, so it runs from a battery:
   *present* at once (if the reading is a plausible cell, 2.5–4.35 V).
2. **USB power:** a 10-second window is collected first (state
   *unknown*, shown as "checking"). Then:
   - *absent* if ~CHG toggles 4 or more times in the window (the
     charger cycling with no cell: the red charge LED flickers), the
     voltage swings by more than 150 mV, or it reads above 4.35 V or
     below 2.5 V;
   - *present* if it is steady at 3.0–4.35 V, charging or not.
3. A new judgement must repeat for 3 seconds before it replaces the old
   one, except the first judgement and any judgement made without USB
   power.

**Limits, honestly:**

- A board with no battery whose charger output happens to sit steady
  in the cell range with ~CHG quiet reads as a *full battery on USB*.
  This depends on the charger and the load; it has not yet been
  observed on hardware either way.
- A board with a battery that is plugged into USB waits about 10 s
  before Bluetooth starts.
- Cells that rest above 4.35 V (not LiPo) read as absent.
- ~CHG only means something with USB power; without it the line floats
  and is ignored.

Tested so far: host unit tests (`crates/trill-board/tests/battery.rs`)
and CI builds. Not yet measured on hardware: the readings of a real
battery board, and the no-battery behaviour on USB.

## Where it shows

- **App:** Settings › Detected hardware › Battery shows present/none,
  percent, volts and charging, and a battery indicator next to the
  section title. A board with a battery and Bluetooth is listed as T1.
- **Bluetooth:** Battery Service `0x180F`, Battery Level `0x2A19` (read,
  notify; updated at least every 30 s while connected).
- **Diagnostics port:** `battery: present 3987 mV charging usb=1` and
  `battery: ~76 %` in the banner.
