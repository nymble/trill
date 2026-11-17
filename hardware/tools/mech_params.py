"""Derived mechanical geometry shared by the OpenSCAD sources and the drawings.

The .scad files carry the same formulas so they stay editable on their own;
`check_scad_constants()` (run by gen_hw.py) confirms the numbers agree.
"""

from __future__ import annotations

from dataclasses import dataclass

import hw_model as hw

# Feature positions in board coordinates (mm from the board's top-left, component side)
LED_B = ((hw.hole_xy(3, 11)[0] + hw.hole_xy(6, 11)[0]) / 2, hw.hole_xy(0, 11)[1])
SW2_B = ((hw.hole_xy(0, 0)[0] + hw.hole_xy(3, 0)[0]) / 2, (hw.hole_xy(0, 13)[1] + hw.hole_xy(0, 15)[1]) / 2)
SW3_B = ((hw.hole_xy(7, 0)[0] + hw.hole_xy(10, 0)[0]) / 2, SW2_B[1])
SW1_B_Y = hw.hole_xy(0, 10)[1]
J3_B = (hw.hole_xy(5, 0)[0], hw.hole_xy(0, 14)[1])
ZONES_B = [  # (x0, y0, x1, y1) board coords of the four corner zones
    (c * hw.PITCH, r0 * hw.PITCH, (c + 1) * hw.PITCH, (r1 + 1) * hw.PITCH) for c, r0, r1 in hw.CORNER_ZONES
]

USB_OPEN_W, USB_OPEN_H = 12.5, 7.0     # clears a typical USB-C plug overmould
SW1_SLOT_L, SW1_SLOT_H = 6.0, 3.2
LED_HOLE_D = 5.3
BTN_HOLE_D = 5.2
CAP_BIG_D, CAP_STEM_D = 7.0, 4.6


@dataclass
class T1:
    wall: float = 2.0
    floor: float = 2.0
    lid: float = hw.LID_T
    clr: float = 0.3
    corner_r: float = 2.0
    batt_gap: float = 2.0          # cell top to board bottom (foam + trimmed leads)

    def __post_init__(self):
        c = hw.CELL_T1
        self.in_x = hw.BOARD_W + 2 * self.clr
        self.in_y = hw.USB_SETBACK + hw.BOARD_L + self.clr
        self.out_x = self.in_x + 2 * self.wall
        self.out_y = self.in_y + 2 * self.wall
        self.board_z0 = self.floor + c[0] + self.batt_gap
        self.board_top = self.board_z0 + hw.BOARD_T
        self.lid_under = self.board_top + hw.COMP_CLEAR
        self.out_z = self.lid_under + self.lid
        self.cap_big_h = self.lid_under - hw.CAP_GAP - (self.board_top + hw.TACT_H)
        self.cap_stem_h = hw.CAP_GAP + self.lid + hw.CAP_PROUD
        self.led_standoff = self.out_z - hw.LED_H - self.board_top

    # board -> enclosure (outer origin at the -X/-Y corner, USB wall at +Y)
    def X(self, bx):
        return self.wall + self.clr + bx

    def Y(self, by):
        return self.wall + self.in_y - (hw.USB_SETBACK + by)


@dataclass
class F1p:
    wall: float = 2.4
    plate: float = 2.4
    top: float = hw.LID_T
    standoff: float = 3.5
    in_w: float = 31.2
    side_clr: float = 0.3          # board edge to the SW1-side wall
    tail_len: float = 17.0         # sensor length used by the tail (slot + S-bend + FFC). Measure.
    slot_x: float = 50.0
    slot_w: float = 2.5
    end_margin: float = 6.0
    corner_r: float = 3.0

    def __post_init__(self):
        self.out_w = self.in_w + 2 * self.wall
        self.board_z0 = self.plate + self.standoff
        self.board_top = self.board_z0 + hw.BOARD_T
        self.top_under = self.board_top + hw.COMP_CLEAR
        self.out_z = self.top_under + self.top
        self.vis_len = hw.TRILL_SENSOR_L - self.tail_len
        self.ch_x0 = self.slot_x
        self.ch_x1 = self.slot_x + self.slot_w + self.vis_len + 1.0
        self.in_l = self.ch_x1 + self.end_margin
        self.out_l = self.in_l + 2 * self.wall
        self.y_left = self.in_w / 2 - self.side_clr - hw.BOARD_W
        self.base_x0 = 57.0
        self.boss_x = (98.5, self.in_l - 4.5)
        self.boss_y = self.in_w / 2 - 1.5
        self.batt_x0 = 104.0
        self.cap_big_h = self.top_under - hw.CAP_GAP - (self.board_top + hw.TACT_H)
        self.cap_stem_h = hw.CAP_GAP + self.top + hw.CAP_PROUD
        self.led_standoff = self.out_z - hw.LED_H - self.board_top

    # board -> inner coordinates: X from the USB end inner wall face, Y centred
    def X(self, by):
        return hw.USB_SETBACK + by

    def Y(self, bx):
        return self.y_left + bx


@dataclass
class F1w:
    t: float = 3.0           # main plywood
    t2: float = 1.5          # board-pocket layer
    wall: float = 9.0
    in_w: float = 31.2
    side_clr: float = 0.3
    tail_len: float = 20.0
    slot_x: float = 50.0
    slot_w: float = 2.5
    end_margin: float = 6.0
    kerf: float = 0.15
    n_upper: int = 4         # frames L3..L6 above the board-pocket layer

    def __post_init__(self):
        self.out_w = self.in_w + 2 * self.wall
        self.vis_len = hw.TRILL_SENSOR_L - self.tail_len
        self.ch_x0 = self.slot_x
        self.ch_x1 = self.slot_x + self.slot_w + self.vis_len + 1.0
        self.in_l = self.ch_x1 + self.end_margin
        self.out_l = self.in_l + 2 * self.wall
        self.y_left = self.in_w / 2 - self.side_clr - hw.BOARD_W
        # z stack
        self.z = {}
        z = 0.0
        for name, th in [("L0", self.t), ("L1", self.t), ("L2", self.t2)] + \
                [(f"L{3 + i}", self.t) for i in range(self.n_upper)] + [("TOP", self.t)]:
            self.z[name] = (z, z + th)
            z += th
        self.out_z = z
        self.board_z0 = self.z["L1"][1]
        self.board_top = self.board_z0 + hw.BOARD_T
        self.top_under = self.z["TOP"][0]
        self.led_standoff = self.out_z - hw.LED_H - self.board_top
        self.base_x0 = 57.0
        self.batt_x0 = 104.0
        self.bolt_x_out = (4.5, 70.0, 136.0, self.out_l - 4.5)

    def X(self, by):
        return hw.USB_SETBACK + by

    def Y(self, bx):
        return self.y_left + bx
