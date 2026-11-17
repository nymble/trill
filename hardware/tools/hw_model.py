"""Trillium hardware model: the single source of truth for the core board.

Everything that the schematics, the perfboard layout, the wiring list, the
bills of materials and the enclosures need is defined here once:

* PIN_MAP      XIAO edge pins -> nRF52840 port pins and their Trillium use
* PARTS        every component, its value, its pins and the nets they join
* PLACEMENT    the perfboard hole that every pin is soldered into
* stack-up     heights used by all three enclosures

Units are millimetres. Perfboard holes are addressed (column, row), with
(0, 0) the top-left hole seen from the component side, USB-C at the top.
"""

from __future__ import annotations

from dataclasses import dataclass, field

PITCH = 2.54

# --------------------------------------------------------------------------
# Perfboard
# --------------------------------------------------------------------------
BOARD_COLS = 11
BOARD_ROWS = 18
BOARD_W = BOARD_COLS * PITCH  # 27.94
BOARD_L = BOARD_ROWS * PITCH  # 45.72
BOARD_T = 1.6

# Corner zones kept free of parts and solder so that enclosures can support
# the board from below and clamp it from above at the same four places.
# Each is (col, row_first, row_last).
CORNER_ZONES = [(0, 0, 1), (10, 0, 1), (0, 16, 17), (10, 16, 17)]


def hole_xy(col: float, row: float) -> tuple[float, float]:
    """Centre of a hole, measured from the board's top-left corner."""
    return ((col + 0.5) * PITCH, (row + 0.5) * PITCH)


# --------------------------------------------------------------------------
# Seeed Studio XIAO nRF52840 (Sense)
# --------------------------------------------------------------------------
XIAO_L = 21.0          # along the pin rows
XIAO_W = 17.8
XIAO_PCB_T = 1.2
XIAO_LEFT_COL = 2      # D0..D6, top to bottom
XIAO_RIGHT_COL = 8     # 5V, GND, 3V3, D10, D9, D8, D7, top to bottom
XIAO_HEADER_SPACER = 2.5   # plastic of a standard male header
USB_C_W, USB_C_H = 8.94, 3.2
USB_C_PROTRUSION = 0.6     # receptacle face beyond the XIAO PCB edge (measure)

_xiao_pin_row_span = 6 * PITCH
XIAO_OVERHANG = (XIAO_L - _xiao_pin_row_span) / 2          # 2.88 beyond pin centres
XIAO_TOP_Y = hole_xy(0, 0)[1] - XIAO_OVERHANG                # -1.61: past board edge
USB_FACE_Y = XIAO_TOP_Y - USB_C_PROTRUSION                   # -2.21
USB_SETBACK = -USB_FACE_Y                                    # board edge to USB face
XIAO_CX = (hole_xy(XIAO_LEFT_COL, 0)[0] + hole_xy(XIAO_RIGHT_COL, 0)[0]) / 2  # 13.97
# USB-C centre height above the perfboard's top surface
USB_Z_ABOVE_BOARD = XIAO_HEADER_SPACER + XIAO_PCB_T + USB_C_H / 2               # 5.3
XIAO_TOP_Z_ABOVE_BOARD = XIAO_HEADER_SPACER + XIAO_PCB_T + 1.6                  # parts on top


@dataclass(frozen=True)
class XiaoPin:
    num: int          # Seeed schematic pin number
    name: str         # silkscreen name
    port: str         # nRF52840 pin
    col: int
    row: int
    use: str          # Trillium allocation
    net: str


# Seeed numbering: 1-7 = D0-D6 down the left edge, 8-11 = D7-D10 up the
# right edge, 12 = 3V3, 13 = GND, 14 = 5V (anticlockwise from USB, top view).
PIN_MAP: list[XiaoPin] = [
    XiaoPin(1, "D0", "P0.02", 2, 0, "Reserved: timing-gpio debug output (logic analyser)", "TP_D0"),
    XiaoPin(2, "D1", "P0.03", 2, 1, "Reserved: timing-gpio debug output (logic analyser)", "TP_D1"),
    XiaoPin(3, "D2", "P0.28", 2, 2, "Button A (SW2), active low", "BTN_A"),
    XiaoPin(4, "D3", "P0.29", 2, 3, "Button B (SW3), active low", "BTN_B"),
    XiaoPin(5, "D4", "P0.04", 2, 4, "I2C SDA: Trill (F1) / expansion (T1)", "SDA"),
    XiaoPin(6, "D5", "P0.05", 2, 5, "I2C SCL: Trill (F1) / expansion (T1)", "SCL"),
    XiaoPin(7, "D6", "P1.11", 2, 6, "Button C (external, J3) or Trill EVT (F1, via JP1)", "AUX_C"),
    XiaoPin(8, "D7", "P1.12", 8, 6, "Button D (external, J3), active low", "BTN_D"),
    XiaoPin(9, "D8", "P1.13", 8, 5, "Status LED red (active low)", "LED_R_DRV"),
    XiaoPin(10, "D9", "P1.14", 8, 4, "Status LED green (active low)", "LED_G_DRV"),
    XiaoPin(11, "D10", "P1.15", 8, 3, "Status LED blue (active low)", "LED_B_DRV"),
    XiaoPin(12, "3V3", "-", 8, 2, "3.3 V supply out (on-board LDO)", "+3V3"),
    XiaoPin(13, "GND", "-", 8, 1, "Ground", "GND"),
    XiaoPin(14, "5V", "-", 8, 0, "USB VBUS: not connected", "NC_5V"),
]

# Pads on the underside of the XIAO (not on the edge connector)
XIAO_PADS = [
    ("BAT+", "VBAT_SW", "Battery + pad, underside. Flying lead to SW1 common"),
    ("BAT-", "GND", "Battery - pad, underside. Already common with GND"),
]

# On-board resources the design relies on but does not wire
ONBOARD = [
    ("P0.26 / P0.30 / P0.06", "On-board RGB LED (active low), driven by current firmware"),
    ("P0.13", "Charge current select: Hi-Z = ~50 mA, low = ~100 mA (BQ25101 ISET)"),
    ("P0.14 / P0.31", "Battery voltage divider enable / ADC input (AIN7)"),
    ("P0.17", "Charger status (low while charging); also drives the red charge LED"),
    ("P0.07 / P0.27 / P0.11 / P1.08", "Sense IMU bus, interrupt and power"),
]


# --------------------------------------------------------------------------
# Parts and netlist
# --------------------------------------------------------------------------
@dataclass
class Part:
    ref: str
    value: str
    desc: str
    pins: dict          # pin name -> net
    holes: dict = field(default_factory=dict)   # pin name -> (col,row) or None (off-board)
    models: tuple = ("T1", "F1")                 # where it is fitted
    optional: bool = False
    example: str = ""
    qty: int = 1
    mech_holes: tuple = ()    # holes soldered for strength only


def _xiao_part() -> Part:
    pins = {p.name: p.net for p in PIN_MAP}
    holes = {p.name: (p.col, p.row) for p in PIN_MAP}
    for pad, net, _ in XIAO_PADS:
        pins[pad] = net
        holes[pad] = None
    return Part(
        "U1", "XIAO nRF52840 Sense",
        "Seeed Studio XIAO nRF52840 Sense (nRF52840, BLE 5, LSM6DS3TR-C IMU, PDM mic, "
        "BQ25101 Li-ion charger). Soldered on 2 x 7-pin 2.54 mm male headers",
        pins, holes, example="Seeed Studio XIAO nRF52840 Sense (not the non-Sense or Plus variants)",
    )


PARTS: list[Part] = [
    _xiao_part(),
    Part("BT1", "LiPo 1S", "Rechargeable lithium-polymer cell, 3.7 V nominal, 4.2 V full, "
         "with built-in protection circuit (PCM) and 2-pin JST-PH lead",
         {"+": "VBAT", "-": "GND"}, {"+": None, "-": None},
         example="T1: 502030 (~250 mAh)  F1: 503035 (~500 mAh)"),
    Part("J1", "JST-PH 2", "Battery connector: JST-PH 2.0 mm 2-pin male plug on a wire pigtail, "
         "wires soldered into the board (PH pitch is 2.0 mm and does not fit 2.54 mm perfboard)",
         {"1": "VBAT", "2": "GND"}, {"1": (1, 16), "2": (2, 16)},
         example="JST-PH 2-pin pigtail (mates with the cell's PHR-2 housing)"),
    Part("SW1", "SPDT slide", "Power switch, SPDT slide, through-hole right angle, 2.5 mm pitch, "
         "actuator over the board's right edge. Breaks the battery + lead",
         {"1": "VBAT", "2": "VBAT_SW", "3": "NC_SW1"},
         {"1": (9, 9), "2": (9, 10), "3": (9, 11)},
         example="C&K OS102011MA1QN1"),
    Part("D1", "RGB 5 mm CA", "Status LED, 5 mm diffused RGB, common anode, through-hole. "
         "Lead order assumed R, A (longest), G, B: confirm with a meter's diode test",
         {"R": "LED_R", "A": "+3V3", "G": "LED_G", "B": "LED_B"},
         {"R": (3, 11), "A": (4, 11), "G": (5, 11), "B": (6, 11)},
         example="Adafruit 159 / SparkFun COM-10821"),
    Part("R3", "680 Ω", "LED red series resistor, carbon/metal film, 1/4 W mini (body ≤ 3.6 mm), 0.3\" span",
         {"1": "LED_R_DRV", "2": "LED_R"}, {"1": (0, 8), "2": (3, 8)}),
    Part("R4", "150 Ω", "LED green series resistor, 1/4 W mini, 0.3\" span (tune 82-220 Ω)",
         {"1": "LED_G", "2": "LED_G_DRV"}, {"1": (4, 8), "2": (7, 8)}),
    Part("R5", "150 Ω", "LED blue series resistor, 1/4 W mini, 0.3\" span (tune 82-220 Ω)",
         {"1": "LED_B_DRV", "2": "LED_B"}, {"1": (0, 9), "2": (3, 9)}),
    Part("SW2", "Button A", "Tactile switch 6 x 6 mm, through-hole, 4.3 mm height. "
         "Wired diagonally so orientation does not matter",
         {"1": "BTN_A", "2": "GND"}, {"1": (0, 13), "2": (3, 15)},
         example="Omron B3F-1000", mech_holes=((3, 13), (0, 15))),
    Part("SW3", "Button B", "Tactile switch 6 x 6 mm, through-hole, 4.3 mm height, wired diagonally",
         {"1": "BTN_B", "2": "GND"}, {"1": (7, 13), "2": (10, 15)},
         example="Omron B3F-1000", mech_holes=((10, 13), (7, 15))),
    Part("J3", "AUX 3", "Optional external buttons C and D: 1 x 3 pin 2.54 mm header or wire pads "
         "(C = D6, D = D7, GND)",
         {"1": "AUX_C", "2": "BTN_D", "3": "GND"}, {"1": (4, 14), "2": (5, 14), "3": (6, 14)},
         optional=True),
    Part("R1", "4.7 kΩ", "I2C SDA pull-up to 3V3, 1/4 W mini, 0.3\" span. Required for Trill",
         {"1": "SDA", "2": "+3V3"}, {"1": (4, 9), "2": (7, 9)}, models=("F1",)),
    Part("R2", "4.7 kΩ", "I2C SCL pull-up to 3V3, 1/4 W mini, 0.3\" span. Required for Trill",
         {"1": "SCL", "2": "+3V3"}, {"1": (0, 10), "2": (3, 10)}, models=("F1",)),
    Part("J2", "TRILL 5", "Trill / I2C connection: 5 wire pads (GND, 3V3, SDA, SCL, EVT), "
         "Qwiic colour order. Solder a cut Qwiic cable, or fit a 1 x 5 right-angle header for bench use",
         {"1": "GND", "2": "+3V3", "3": "SDA", "4": "SCL", "5": "TRILL_EVT"},
         {"1": (3, 17), "2": (4, 17), "3": (5, 17), "4": (6, 17), "5": (7, 17)}, models=("F1",)),
    Part("JP1", "EVT link", "Optional wire link: Trill EVT to D6. Fit only if the Trill EVT pad is "
         "wired; then J3 pin 1 (button C) must stay unused",
         {"1": "AUX_C", "2": "TRILL_EVT"}, {"1": (6, 16), "2": (7, 16)},
         models=("F1",), optional=True),
]

# Off-board parts of F1 (connected through J2)
F1_EXTERNAL = [
    ("U2", "Bela Trill Flex", "Trill Flex base (36.3 x 22.4 mm) with 32-pin 0.5 mm FFC socket; "
     "I2C address 0x48; 1.71-5.5 V, ~4 mA", "Bela 160706-FLEX"),
    ("S1", "Flex sensor", "Trill Flex 1-axis flex-PCB sensor, plugs into U2's FFC socket", "supplied with U2"),
    ("W1", "Qwiic cable", "JST-SH 4-pin (Qwiic) cable, one end cut and soldered to J2 1-4", "supplied with U2, or any Qwiic cable"),
]


def parts_for(model: str) -> list[Part]:
    return [p for p in PARTS if model in p.models]


def nets_for(model: str) -> dict[str, list[tuple[str, str]]]:
    nets: dict[str, list[tuple[str, str]]] = {}
    for p in parts_for(model):
        for pin, net in p.pins.items():
            nets.setdefault(net, []).append((p.ref, pin))
    return nets


# --------------------------------------------------------------------------
# Footprints for the layout drawing (component-side outlines, board coords)
# --------------------------------------------------------------------------
def body_outlines(model: str) -> list[tuple]:
    """(kind, ref, geometry...) in board millimetres, component side."""
    out = []
    x0 = XIAO_CX - XIAO_W / 2
    out.append(("rect", "U1", x0, XIAO_TOP_Y, XIAO_W, XIAO_L))
    out.append(("rect", "USB", XIAO_CX - USB_C_W / 2, USB_FACE_Y, USB_C_W, 7.4))
    cx, cy = (hole_xy(3, 11)[0] + hole_xy(6, 11)[0]) / 2, hole_xy(0, 11)[1]
    out.append(("circle", "D1", cx, cy, 2.9))
    for ref, (c0, r0) in (("SW2", (0, 13)), ("SW3", (7, 13))):
        x = (hole_xy(c0, 0)[0] + hole_xy(c0 + 3, 0)[0]) / 2
        y = (hole_xy(0, r0)[1] + hole_xy(0, r0 + 2)[1]) / 2
        out.append(("rect", ref, x - 3, y - 3, 6, 6))
        out.append(("circle", ref + "cap", x, y, 1.75))
    # SW1 right-angle slide: body 8.2 x ~4 deep, sitting on the right edge
    y1, y3 = hole_xy(0, 9)[1], hole_xy(0, 11)[1]
    out.append(("rect", "SW1", BOARD_W - 4.2, (y1 + y3) / 2 - 4.1, 4.2, 8.2))
    out.append(("rect", "SW1act", BOARD_W, (y1 + y3) / 2 - 1.0, 4.0, 2.0))
    for p in parts_for(model):
        if p.ref.startswith("R") and p.ref[1:].isdigit():
            (c1, r1), (c2, r2) = p.holes["1"], p.holes["2"]
            xa, ya = hole_xy(c1, r1)
            xb, yb = hole_xy(c2, r2)
            out.append(("resistor", p.ref, (xa + xb) / 2, (ya + yb) / 2, abs(xb - xa)))
    return out


# --------------------------------------------------------------------------
# Shared mechanical stack-up
# --------------------------------------------------------------------------
TACT_H = 4.3          # B3F-1000 body + plunger height above board
TACT_ACT_D = 3.5
LED_H = 8.6           # 5 mm LED, flange to dome tip
LED_D = 5.0
COMP_CLEAR = 9.5      # board top to lid underside (printed enclosures)
LID_T = 2.0           # printed lid / top thickness (T1 and F1p share caps)
CAP_GAP = 0.3         # button-cap shoulder clearance under the lid
CAP_PROUD = 1.0       # how far a cap stands above the lid
SW1_ACT_Z = 2.0       # slide actuator centre above board top (OS102011MA1QN1, approx.)

# Batteries (thickness, width, length)
CELL_T1 = (5.0, 20.0, 30.0)   # 502030
CELL_F1 = (5.0, 30.0, 35.0)   # 503035

# Trill Flex
TRILL_BASE = (36.3, 22.4, 1.6)        # length (FFC edge on a short side), width, PCB
TRILL_SENSOR_L = 145.5                # stock sensor overall length (measure yours)
TRILL_SENSOR_W = 21.6


def check_layout() -> list[str]:
    """Sanity checks: one net per hole, holes on the board, corner zones clear."""
    problems = []
    used: dict[tuple, tuple] = {}
    zone_holes = {(c, r) for c, r0, r1 in CORNER_ZONES for r in range(r0, r1 + 1)}
    for p in PARTS:
        all_holes = [(pin, h) for pin, h in p.holes.items() if h] + [("mech", h) for h in p.mech_holes]
        for pin, h in all_holes:
            c, r = h
            if not (0 <= c < BOARD_COLS and 0 <= r < BOARD_ROWS):
                problems.append(f"{p.ref}.{pin} off board at {h}")
            if h in used and used[h] != (p.ref, pin):
                problems.append(f"hole {h} used by {used[h]} and {p.ref}.{pin}")
            used[h] = (p.ref, pin)
            if h in zone_holes:
                problems.append(f"{p.ref}.{pin} in a corner zone {h}")
            # row 7 under the XIAO body edge must stay free (cols 2..8 are the XIAO itself)
            if r == 7:
                problems.append(f"{p.ref}.{pin} on row 7 under the XIAO edge")
            if p.ref != "U1" and r <= 6 and 2 <= c <= 8:
                problems.append(f"{p.ref}.{pin} under the XIAO at {h}")
    return problems


if __name__ == "__main__":
    print("problems:", check_layout() or "none")
    for m in ("T1", "F1"):
        print(m, {k: v for k, v in nets_for(m).items()})
