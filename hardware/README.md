# Trillium hardware

**Status:** the model lineup below is current as of 2026-11-17. The starting instrument is [Trillium Zero (T0)](../docs/hardware/trillium-zero.md). Revision A drawings in `t1/` and `f1/` (2026-11-11) are prototype designs for the planned T2 and F1; they have not been built or measured. Values marked *tune* are starting points for bring-up. Folder names have not been renamed; see [Revision A mapping](#revision-a-mapping).

Trillium instruments are hand-held musical controllers. A Seeed Studio XIAO nRF52840 Sense reads its own motion sensor and, in some models, a Bela Trill Flex linear touch sensor. It sends class-compliant USB-MIDI today and BLE-MIDI later. Every instrument works on its own as a MIDI device. The Trillium app (see [`docs/apple-app.md`](../docs/apple-app.md)) adds configuration, presets, monitoring and, later, firmware updates.

The T0 showcase and its wiring diagram live in [`docs/hardware/trillium-zero.md`](../docs/hardware/trillium-zero.md). This folder holds the model lineup and the revision A designs for later models. [`docs/design-xiao-nrf52840.md`](../docs/design-xiao-nrf52840.md) remains the reference for the XIAO's on-board charger and power circuit.

## Model lineup

A board is described by its **model** plus a **capability list** (battery, BLE, LED, buttons, linear touch sensor, microphone). Other combinations than the four named models are possible.

| Model | What it is | Status | Where it is documented |
|---|---|---|---|
| **T0 — Trillium Zero** | One Seeed Studio XIAO nRF52840 Sense on a USB-C cable. Class-compliant USB-MIDI from the onboard IMU. No extra parts. | The showcase starting point, and the primary development configuration to date. Firmware and the Trillium app run on this board. | [`docs/hardware/trillium-zero.md`](../docs/hardware/trillium-zero.md) |
| **T1** | T0 plus a battery and BLE. | Built and tested on an early Omi DIY board. A clean T1 drawing (cell and switch only, without the extra LED and buttons) is not yet in this folder. | T0 guide (optional battery section); tested unit is an Omi DIY board, not the revision A `t1/` design |
| **T2** | T1 plus a better LED and buttons. The next motion build. | Planned. Not built. | Revision A electronics and enclosure are filed under [`t1/`](t1/) (historical folder name) |
| **F1** | T2 plus a Bela Trill Flex linear touch sensor. | Planned. Not built. The only Flex testing to date is a breadboard T0 plus a Trill Flex. | [`f1/`](f1/) |

## Revision A mapping

The revision A designs were drawn when "T1" meant the motion instrument with a cell, a power switch, an RGB status LED and buttons, and "F1" meant that board plus a Trill Flex. The lineup above is narrower: T1 is battery and BLE only; the LED and buttons belong to T2; F1 is T2 plus the Flex.

| Revision A path | What the files actually describe | Lineup name |
|---|---|---|
| [`t1/`](t1/) (schematic, layout, BOM, printed enclosure) | Shared core board: XIAO nRF52840 Sense, cell, power switch, RGB status LED, two buttons (plus two optional). Enclosure 32.5 x 52.2 x 22.1 mm. **Not built.** | **T2** (planned) |
| [`f1/`](f1/) (schematic, layout, BOM, F1p printed and F1w wood bodies) | The same core board plus Bela Trill Flex (R1, R2, J2, optional JP1). **Not built.** | **F1** (planned), which is T2 plus the Flex |

Those folders and filenames are unchanged. A rename of `hardware/t1/` (and the `t1-*` files) to `t2/` is proposed and is not done here.

The revision A design still rests on one decision: **the planned T2 and F1 use the same core board.** It has the same perfboard layout, the same pin allocation and the same part positions. F1 fits four extra parts (R1, R2, J2, optional JP1) into holes that T2 leaves empty. One firmware image can serve both models, one build procedure can cover both, and a T2 can be upgraded to an F1 with a soldering iron.

The tested T1 (the early Omi DIY board) is a different physical unit. It is not the unbuilt revision A `t1/` design.

## Design rules

- **Hand-buildable.** Every board-level part is through-hole or a module on 2.54 mm headers. No surface-mount soldering is needed. The XIAO itself is a pre-assembled module.
- **Seeed-first.** The XIAO's own charger, battery switch-over and 3.3 V regulator are used as they are. The board adds only a power switch, a status LED, buttons and the I2C pull-ups.
- **Shared mechanics.** Four corner zones of the board are kept free of parts. Every enclosure supports the board from below and clamps it from above at those four places. The planned T2 (`t1/` drawings) and F1p share the same button caps and LED standoff.
- **Parametric and regenerable.** All drawings, lists and laser files are generated from one model ([`tools/hw_model.py`](tools/hw_model.py), [`tools/mech_params.py`](tools/mech_params.py)). The enclosures are parametric OpenSCAD sources.

## Pin allocation (revision A core board: planned T2 and F1)

| XIAO pin | nRF52840 | Net | Use |
|---|---|---|---|
| D0 | P0.02 | `TP_D0` | Reserved: firmware `timing-gpio` output (logic analyser). Not connected |
| D1 | P0.03 | `TP_D1` | Reserved: firmware `timing-gpio` output. Not connected |
| D2 | P0.28 | `BTN_A` | Button A (SW2) to GND, active low, internal pull-up |
| D3 | P0.29 | `BTN_B` | Button B (SW3) to GND, active low, internal pull-up |
| D4 | P0.04 | `SDA` | I2C data: Trill (F1); expansion (planned T2). 4.7 kΩ pull-up R1 on F1 |
| D5 | P0.05 | `SCL` | I2C clock: Trill (F1); expansion (planned T2). 4.7 kΩ pull-up R2 on F1 |
| D6 | P1.11 | `AUX_C` | Optional button C via J3, **or** Trill EVT via JP1 (F1). Never both |
| D7 | P1.12 | `BTN_D` | Optional button D via J3, active low |
| D8 | P1.13 | `LED_R_DRV` | Status LED red, active low, through R3 |
| D9 | P1.14 | `LED_G_DRV` | Status LED green, active low, through R4 |
| D10 | P1.15 | `LED_B_DRV` | Status LED blue, active low, through R5 |
| 3V3 | — | `+3V3` | Output of the XIAO's LDO: LED anode, pull-ups, Trill supply |
| GND | — | `GND` | Ground |
| 5V | — | — | USB VBUS. **Not connected** |
| BAT+ pad (underside) | — | `VBAT_SW` | Cell + after the power switch (flying lead) |

The LEDs and buttons use the P1.xx pins (D6–D10) on purpose. Nordic recommends them for low-frequency signals only, which suits LEDs and buttons, and that keeps D0–D5 free for faster or analog use. The XIAO's on-board RGB LED (P0.26/P0.30/P0.06), charger status (P0.17), battery-sense divider (P0.14/P0.31) and charge-current select (P0.13) are unchanged and remain available to firmware.

## Power, charging and the on/off switch

The cell connects through J1 and the slide switch SW1 to the XIAO's BAT+ pad. The XIAO's own charger (TI BQ25101, 4.20 V) charges it whenever USB is present. Its own switch-over runs the board from USB when plugged in and from the cell otherwise.

| SW1 | USB | Result |
|---|---|---|
| ON | connected | Runs from USB and charges the cell (≈ 50 mA; ≈ 100 mA if firmware drives P0.13 low) |
| ON | not connected | Runs from the cell |
| OFF | connected | Runs from USB. **Does not charge**: the cell is disconnected |
| OFF | not connected | Off. The cell is fully isolated: no standby drain, safe to store and ship |

Because the XIAO has no enable pin, breaking the battery lead is the only through-hole way to switch it off. The cost is that the switch must be ON to charge. That is documented on the case and in the build guides. A firmware "soft off" (System OFF, ~5 µA) can be added later behind a long press on button A without changing the hardware.

Cells must be single-cell LiPo with a built-in protection circuit. Recommended sizes: planned T2 (`t1/` drawings) 502030 (≈ 250 mAh, charges in ≈ 5–6 h at 50 mA); F1 503035 (≈ 500 mAh). At 50 mA the 500 mAh cell can reach the charger's 10-hour safety timer before it is full. For F1, firmware should select the 100 mA setting (P0.13 low) once charging is validated. **JST-PH polarity is not standardised between cell vendors: check every cell with a meter before plugging it in.**

Runtime has not been measured. Once current draw has been measured at bring-up, estimate it as capacity ÷ average current. Firmware does not yet use sleep modes.

## Status LED

D1 is a 5 mm diffused common-anode RGB LED powered from 3V3 and driven active low, the same polarity as the XIAO's on-board LED. That means the existing `status-led` crate only needs three new pin assignments. Green and blue dice need about 2.8–3.3 V, so on a 3.3 V rail they run at a few milliamps: R4/R5 = 150 Ω is a starting point (*tune* 82–220 Ω), R3 = 680 Ω for red. Configure P1.13–P1.15 as high-drive outputs. With all three on, the total stays at or below about 10 mA. If brightness turns out to be inadequate, the upgrade is three small NPN transistors with the anode on the battery side. That is a later revision, not part of this prototype.

## Files

| Path | Content |
|---|---|
| [`t1/README.md`](t1/README.md) | Planned **T2** build guide (folder still named `t1/`): schematic, BOM, layout, wiring, enclosure, bring-up |
| [`f1/README.md`](f1/README.md) | Planned **F1** build guide: Trill Flex additions, F1p and F1w bodies |
| `t1/t1-schematic.svg`, `f1/f1-schematic.svg` | Schematics |
| `t1/t1-layout.svg`, `f1/f1-layout.svg` | Perfboard placement, underside wiring view, wiring list |
| `t1/t1-bom.csv`, `f1/f1-bom.csv` | Bills of materials |
| `t1/t1-enclosure.scad` | Planned T2 enclosure (OpenSCAD; file still named `t1-enclosure`) and `t1-enclosure-drawing.svg` |
| `f1/f1p-body.scad` | F1p printed body (OpenSCAD) and `f1p-body-drawing.svg` |
| `f1/f1w-sheet-3mm.svg`, `f1/f1w-sheet-1.5mm.svg` | F1w laser-cut files and `f1w-body-drawing.svg` |
| `tools/` | Generator (`gen_hw.py`) and the hardware model |

Regenerate everything and run the checks from the repository root:

```sh
python3 hardware/tools/gen_hw.py
```

Requirements: Python 3.10+ and matplotlib (used to turn engraving text into outlines). The script checks that no two parts share a hole, that the corner zones are clear and that nothing sits under the XIAO. It also lints the `.scad` files and checks that their key numbers match `mech_params.py`. STL export is done in OpenSCAD (2021.01 or later), which is not needed to run the generator.

## Open items before revision B

1. Build one T2 (from the `t1/` drawings) and one F1. Measure current draw, charge time, LED brightness and USB-C opening fit. A cleaner T1 drawing (battery and BLE only) can follow the tested Omi DIY unit.
2. Measure the stock Trill Flex sensor and its tail on a dry fit. Distributor listings give 145.5 mm overall, but Bela's own table quotes 117 mm for the sensor, which suggests revisions differ. Set `sensor_l` / `tail_len`.
3. Confirm SW1 direction (which side is ON) and mark the cases. Confirm D1's lead order.
4. Firmware: external LED on D8–D10, buttons on D2/D3 (+D6/D7), optional Trill EVT on D6, battery voltage and charge status, 100 mA charge for F1, soft off.
5. Decide whether revision B moves to a small custom PCB (the netlist in `tools/hw_model.py` exports directly).

## Sources

- Seeed Studio, XIAO nRF52840 series wiki (pin map, battery, charging): <https://wiki.seeedstudio.com/XIAO_BLE/>
- Seeed Studio, XIAO nRF52840 Sense schematic: <https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_PDF.pdf>
- Pin to port mapping cross-check: TinyGo XIAO BLE reference <https://tinygo.org/docs/reference/microcontrollers/boards/xiao-ble/>, Apache NuttX XIAO nRF52840 board page <https://nuttx.apache.org/docs/12.9.0/platforms/arm/nrf52/boards/xiao-nrf52840/index.html>
- Bela, Trill datasheet (supply 1.71–5.5 V, ~4 mA, Qwiic pinout, EVT behaviour): <https://bela.io/datasheets/trill_datasheet.pdf>
- Trill Flex dimensions (base 36.3 x 22.4 mm, sensor 145.5 x 21.6 mm): Pimoroni product page <https://wholesale.pimoroni.com/en-us/products/trill-flex>; Bela revision table (sensor 117 x 22 mm) <https://blog.bela.io/trill-new-revision/>
- C&K OS series slide switch: <https://www.ckswitches.com/media/1428/os.pdf>
- Omron B3F tactile switch (6 x 6 x 4.3 mm, 6.5 x 4.5 mm pins): <https://www.rcscomponents.kiev.ua/datasheets/B3F.pdf>
- 5 mm RGB common-anode LED forward voltages (≈ 2.2 V red, ≈ 3.3 V green/blue at 20 mA): Kingbright WP154A4 series listing <https://www.digikey.com/en/products/detail/kingbright/WP154A4AVS-RGB-CA/16842328>
