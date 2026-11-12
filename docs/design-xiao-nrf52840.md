# Design: Trill Flex → Seeed Studio XIAO nRF52840

**Status:** design proposal, **not hardware-validated** as a complete build. Firmware 0.5.0 has been run on one XIAO nRF52840 Sense (IMU and USB MIDI); a Trill Flex was not attached, and battery operation has not been measured. See [firmware-xiao-sense.md](firmware-xiao-sense.md). The shareable build guide, including both the motion-only and Flex variants and the battery switch, is [Trillium Zero](hardware/trillium-zero.md).

![Trillium Zero schematic: XIAO nRF52840 Sense, Bela Trill Flex, LiPo, and battery switch](images/trillium-zero.svg)

## Scope

This design connects one Trill Flex to the XIAO's I²C pins. It applies to the **XIAO nRF52840** and **XIAO nRF52840 Sense**, which share the same 14-pin edge pinout and the same D4/D5 I²C pins. The *Plus* variants keep D4/D5 as SDA/SCL but add pins; their extra pins are not covered here.

The MCU is a Nordic nRF52840 (Arm Cortex-M4F, 64 MHz, Bluetooth LE). It has **no Wi-Fi**. ESP32 pin and bus conventions do not apply.

## Pin mapping

| Trill pin | Signal | XIAO pin | XIAO name | nRF52840 pin |
|---|---|---|---|---|
| 1 | GND | 13 | GND | — |
| 2 | VCC | 12 | 3V3 (3V3_OUT) | — |
| 3 | SDA | 5 | D4 / SDA | P0.04 |
| 4 | SCL | 6 | D5 / SCL | P0.05 |
| — | — | 14 | 5V (VBUS) | **do not connect to Trill** |

Pin numbers follow the XIAO symbol in Seeed's schematic: pins 1–7 = D0–D6 down one edge, 8–11 = D7–D10, 12 = 3V3, 13 = GND, 14 = 5V. In the diagram the board is seen from the front with USB-C at the top. Check against the Seeed pinout sheet before soldering.

Wire colours are not authoritative (see [the Raspberry Pi design](design-raspberry-pi.md#pin-mapping)). Identify each signal by position or label.

## Electrical

| Parameter | Value | Source |
|---|---|---|
| nRF52840 VDD | 1.7–3.6 V, 3.0 V nominal. XIAO supplies 3.3 V | nRF52840 PS v1.5 |
| I/O voltage | VDD + 0.3 V max: **not 5 V tolerant** | nRF52840 PS v1.5 |
| Trill supply | **XIAO 3V3** (pin 12). Trill draws about 4 mA | Trill datasheet Table 4 |
| Ground | Common ground (pin 13) | — |
| Address | 0x48 | Trill datasheet Table 8 |
| I²C controller | TWIM, 100/250/400 kbps. Trill supports 50/100/400 kHz, so use **100 or 400 kHz** | nRF52840 PS v1.5; Trill datasheet |

### Pull-up resistors

The Trill sensor has **no** I²C pull-ups (datasheet §7). Seeed's schematics (XIAO nRF52840 v1.2 and Sense) show **no pull-up resistors on the D4/D5 nets**. The 10 kΩ resistors R14/R15 pull up the separate internal IMU bus and are powered from the IMU supply. The nRF52840 internal GPIO pull-ups are 11–16 kΩ (PS v1.5), which is weaker than Bela's recommended 2.2–4.7 kΩ.

The design therefore includes **R1 = 4.7 kΩ from SDA (D4) to 3V3** and **R2 = 4.7 kΩ from SCL (D5) to 3V3**, in line with Bela's guidance (*All about I²C*). Fit only one pair per bus. Omit them if a Trill Hub (2.2 kΩ) or another board on the same bus already provides pull-ups.

Checks before power-up:
1. With the board unpowered, measure D4→3V3 and D5→3V3. You should read about 4.7 kΩ with R1/R2 fitted, and high resistance without them, which confirms there are no on-board pull-ups.
2. Confirm 3V3 and GND are not shorted, and that no ADR pads on the Trill base are bridged to both sides.

The current capability of the XIAO 3V3 output is not stated on the Seeed wiki page cited here. A single Trill (about 4 mA) is a small load, but check the regulator's datasheet before adding other loads to the rail.

## Power, USB and battery

The XIAO nRF52840 Sense can run from USB, from one rechargeable lithium cell on its rear battery pads, or both. **Charging is done entirely by on-board hardware** (TI BQ25101) whenever USB VBUS is present. It needs no firmware, and this project's firmware does not control, measure or report it. The table is transcribed from the Seeed **XIAO nRF52840 Sense schematic, Rev V1.1** (KiCad, sheet 3 "Battery charge" and "System 3.3V"). Check the revision printed on your board's documentation; other revisions may differ.

| Block | Part (schematic) | What it does |
|---|---|---|
| Charger | U2 **BQ25101** (`BQ25101YFPT`) | Linear single-cell Li-ion charger. IN = VBUS, OUT = VBAT. Regulation (full-charge) voltage **4.20 V** (BQ25101; the `H` variant would be 4.35 V). Fixed 10-hour safety timer, input over-voltage protection at 6.5 V, thermal regulation (TI datasheet) |
| Charge current | ISET: R18 2.7 kΩ to GND, plus R12 2.7 kΩ to **P0.13** (`HICHG`) | I = K<sub>ISET</sub> / R<sub>ISET</sub>, K<sub>ISET</sub> = 135 AΩ typ. (129–145). P0.13 high-impedance: 2.7 kΩ → **≈ 50 mA** (≈ 48–54 mA). P0.13 driven low: 1.35 kΩ → **≈ 100 mA** (≈ 96–107 mA). Seeed's wiki gives the same 50/100 mA. These are fast-charge (constant-current) values; current tapers near full |
| Battery temperature | TS: R20 fixed 10 kΩ to GND | NTC monitoring **disabled** (schematic note). The board does not measure cell temperature |
| Charge status | `~CHG` → **P0.17** and the red charge LED (R5 2.2 kΩ) | Low while charging (Seeed wiki). Read-only status |
| Battery sense | R16 1 MΩ / R17 510 kΩ from VBAT to **P0.14** (`READ_BAT`), tap to **P0.31** (AIN7) | Drive P0.14 low, then read AIN7. Seeed warns that P0.14 driven **high** can push P0.31 past its 3.6 V limit |
| Battery ↔ USB switch-over | Q1 P-MOSFET (VBAT → VIN, gate = VBUS, R9 100 kΩ to GND) and D1 Schottky (VBUS → VIN) | With USB: the system runs from VBUS through D1, Q1 is off, and the charger charges the cell. Without USB: Q1 conducts and the cell feeds VIN. This is a simple switch-over, **not** a charger with an integrated power path (load sharing) |
| 3.3 V rail | U6 **SGM2040-3.3** LDO, VIN → 3V3 | Labelled 3.3 V / 250 mA on the schematic. 3V3 is the XIAO 3V3 pin (pin 12) that powers the Trill and R1/R2 |

**Firmware state of these pins.** The firmware never configures P0.13, P0.14, P0.17 or P0.31, so they stay in the nRF52840 reset state (input, disconnected). With P0.13 high-impedance the charger runs at the ≈ 50 mA setting. Battery voltage and charge status are **not measured or reported**. Adding them is a [roadmap](roadmap.md) item, not part of this design.

**Rules:**
- One **rechargeable** Li-ion / LiPo cell only, 3.7 V nominal class, 4.2 V full charge. Never primary (non-rechargeable) cells and never multi-cell packs.
- Use a cell with **its own protection circuit** (over-charge, over-discharge, short circuit). The board has no NTC input and no battery-side protection beyond the charger's own functions.
- **Polarity is critical:** battery + to pad `BAT0` (VBAT), battery − to pad `GND0` (GND). These are schematic names. Confirm the rear-side silkscreen and pad positions on your board and on Seeed's back-side photo before soldering. The canonical diagram does not draw the pad positions.
- The [Trillium Zero](hardware/trillium-zero.md) build adds a user-supplied SPST switch in the **battery+** lead only (between the cell and `BAT0`). That switch is not part of the XIAO module. With the switch open, the cell is isolated from VBAT: the board can still run from USB, and the charger cannot reach the cell.
- **Never** connect the battery, or VBAT, to the 3V3 pin, the 5V pin, the Trill, or a Raspberry Pi. The Trill stays on 3V3 only.
- Capacity is not specified here. With ≈ 50 mA charge current and the 10-hour safety timer, large cells may not reach full charge in one session.

**USB host power.** The charger's input is VBUS itself, so it charges whenever VBUS is present, whether or not the host has configured the USB device. The firmware requests 100 mA (`bMaxPower`). MCU, IMU, Trill and LED current plus the charge current have **not been measured**. A host that strictly limits current, such as an iPhone or iPad through a camera adapter, may not supply both, so use a powered adapter or hub (see [USB MIDI](usb-midi.md#hardware-acceptance-procedure)). Plugging in a battery while connected to a phone charges the battery from the phone. The firmware does not select the 100 mA setting.

**Battery bring-up (in this order):**
1. With no battery, power from USB and check `3V3` ≈ 3.3 V on pin 12. Note whether the red charge LED is on or flickering with no battery: absent-battery behaviour is not documented here.
2. With USB unplugged, check the cell's open-circuit voltage and polarity with a meter at its leads.
3. Fit the cell to `BAT0` / `GND0` with the polarity confirmed on the board.
4. Plug USB in: the red charge LED should light while charging and go out when charge ends (Seeed wiki).
5. Unplug USB: the board should keep running from the cell (Q1 switch-over), with `3V3` still ≈ 3.3 V.
6. Record charge time, cell voltage and any USB-host problems in the bring-up issue. None of this has been done in this project yet.

| Qty | Item | Notes |
|---|---|---|
| 1 | Single-cell Li-ion/LiPo, 3.7 V nominal, 4.2 V full charge, with protection circuit | Capacity chosen by the user (not specified here) |
| — | Leads or a connector suited to the pads | Not specified: follow Seeed's guidance for the board |

## Flex sensor attachment, modes, and address

These are the same as in the Raspberry Pi design: [FFC attachment](design-raspberry-pi.md#flex-sensor-attachment), [stock vs custom sensors](design-raspberry-pi.md#stock-strip-vs-custom-sensors), [address selection](design-raspberry-pi.md#address-selection). The stock strip uses `Mode::Centroid`; custom flex PCBs use `Mode::Diff`.

## Bill of materials

| Qty | Ref | Item | Notes |
|---|---|---|---|
| 1 | — | Bela Trill Flex (base + flex sensor) | 160706-FLEX |
| 1 | — | QWIIC-to-pin cable | Supplied with Trill Flex |
| 1 | U1 | Seeed Studio XIAO nRF52840 or nRF52840 Sense | — |
| 2 | R1, R2 | 4.7 kΩ resistor, 1/8 W or larger, 5 % or better | SDA and SCL to 3V3 |
| — | — | Headers or wire, optional single-cell LiPo, optional battery+ switch | See [Power, USB and battery](#power-usb-and-battery) and [Trillium Zero](hardware/trillium-zero.md) |

## Firmware

[`firmware/xiao-sense`](../firmware/xiao-sense) (Embassy, `embassy-nrf` 0.11) implements this design on the XIAO nRF52840 Sense: TWIM0 on P0.04/P0.05 at 100 kHz with external R1/R2, Trill identified at 0x48 and polled every 5 ms, the on-board IMU, and a class-compliant [USB-MIDI](usb-midi.md) output ([mapping](midi-mapping.md)). The [motion synth](motion-synth.md) is an optional debug build. Loading uses the factory UF2 bootloader with an application-only image at `0x27000`, after a read-only backup. See [firmware-xiao-sense.md](firmware-xiao-sense.md). BLE transport is not designed yet ([roadmap](roadmap.md)).

## Known limits

- Wiring, pull-up values, and orientation have not been tested on hardware.
- The firmware has not been run on hardware. No BLE service or mobile app exists yet.
- Battery operation, charge current and power draw have not been tested or measured.
- The *Plus* variants and the XIAO expansion board are not covered.

## Sources

- Seeed Studio XIAO nRF52840 series wiki (pin map, interfaces): <https://wiki.seeedstudio.com/XIAO_BLE/>
- XIAO nRF52840 schematic v1.2: <https://files.seeedstudio.com/wiki/XIAO-BLE/Res/260828_XIAO_nRF52840.pdf>
- XIAO nRF52840 Sense schematic (Rev V1.1; battery charge, system 3.3 V): <https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_PDF.pdf>
- Seeed wiki, "Battery Charging current" and FAQ Q3/Q4 (P0.13 50/100 mA, P0.14/P0.31 battery read, P0.17 charge status): <https://wiki.seeedstudio.com/XIAO_BLE/>
- TI BQ25101 datasheet (V<sub>O(REG)</sub> 4.20 V, K<sub>ISET</sub>, TS, safety timer): <https://www.ti.com/lit/ds/symlink/bq25101.pdf>
- Nordic nRF52840 Product Specification v1.5 (VDD, I/O limits, RPU, TWIM): <https://files.seeedstudio.com/wiki/XIAO-BLE/nRF52840_PS_v1.5.pdf>
- Trill datasheet Rev C v1.3: <https://github.com/BelaPlatform/Trill/raw/master/trill_datasheet.pdf>
- All about I²C (Trill, pull-up guidance): <https://learn.bela.io/using-trill/all-about-i2c/>
