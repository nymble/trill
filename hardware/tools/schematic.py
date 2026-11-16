"""Draw the T1 and F1 schematics from hw_model (net-label style, A4 landscape)."""

from __future__ import annotations

import hw_model as hw
from svgkit import Svg, INK, GREY, LIGHT, ACCENT, BLUE

DATE = "2026-11-11"
REV = "A (prototype)"


class Sch:
    def __init__(self, model: str):
        self.m = model
        self.s = Svg(297, 210)
        self.fitted = {p.ref for p in hw.parts_for(model)}

    # -- symbols ------------------------------------------------------
    def col(self, ref):
        return INK if (ref is None or ref in self.fitted) else GREY

    def label(self, x, y, name, side="left", color=INK):
        """Net label flag; (x, y) is the connection point."""
        s = self.s
        w = len(name) * 1.35 + 2.6
        h = 3.0
        if side == "left":     # flag extends to the left of the point
            pts = [(x, y), (x - 1.4, y - h / 2), (x - w, y - h / 2), (x - w, y + h / 2), (x - 1.4, y + h / 2)]
            s.poly(pts, stroke=color, sw=0.2, close=True)
            s.text(x - w / 2 - 0.7, y + 0.75, name, 2.0, "middle", fill=color)
        else:
            pts = [(x, y), (x + 1.4, y - h / 2), (x + w, y - h / 2), (x + w, y + h / 2), (x + 1.4, y + h / 2)]
            s.poly(pts, stroke=color, sw=0.2, close=True)
            s.text(x + w / 2 + 0.7, y + 0.75, name, 2.0, "middle", fill=color)

    def gnd(self, x, y, color=INK):
        s = self.s
        s.line(x, y, x, y + 1.6, color)
        for i, half in enumerate((1.8, 1.2, 0.6)):
            yy = y + 1.6 + i * 0.7
            s.line(x - half, yy, x + half, yy, color, 0.3)

    def vcc(self, x, y, name="+3V3", color=INK):
        s = self.s
        s.line(x, y, x, y - 1.8, color)
        s.line(x - 1.6, y - 1.8, x + 1.6, y - 1.8, color, 0.35)
        s.text(x, y - 2.6, name, 2.0, "middle", fill=color)

    def resistor(self, x1, y1, x2, y2, ref, value, color=INK, label_side=1):
        s = self.s
        if y1 == y2:   # horizontal
            mx = (x1 + x2) / 2
            s.line(x1, y1, mx - 3, y1, color)
            s.line(mx + 3, y1, x2, y1, color)
            s.rect(mx - 3, y1 - 1, 6, 2, stroke=color)
            s.text(mx, y1 - 1.8, ref, 1.9, "middle", "bold", fill=color)
            s.text(mx, y1 + 3.6, value, 1.9, "middle", fill=color)
        else:
            my = (y1 + y2) / 2
            s.line(x1, y1, x1, my - 3, color)
            s.line(x1, my + 3, x1, y2, color)
            s.rect(x1 - 1, my - 3, 2, 6, stroke=color)
            s.text(x1 + 1.8 * label_side, my - 0.3, ref, 1.9, "start" if label_side > 0 else "end", "bold", fill=color)
            s.text(x1 + 1.8 * label_side, my + 2.3, value, 1.9, "start" if label_side > 0 else "end", fill=color)

    def diode_down(self, x, y, color=INK):
        """LED, anode at y, cathode at y+7."""
        s = self.s
        s.line(x, y, x, y + 2, color)
        s.poly([(x - 1.5, y + 2), (x + 1.5, y + 2), (x, y + 4.4)], stroke=color, close=True)
        s.line(x - 1.5, y + 4.4, x + 1.5, y + 4.4, color, 0.3)
        s.line(x, y + 4.4, x, y + 7, color)
        for d in (0, 1.2):
            s.arrow(x + 1.9, y + 2.3 + d, x + 3.6, y + 1.3 + d, color, 0.15, 0.6)

    def tact(self, x, y, ref, value, color=INK):
        """Vertical push button, terminals at (x, y) and (x, y+8)."""
        s = self.s
        s.line(x, y, x, y + 2, color)
        s.circle(x, y + 2.4, 0.4, stroke=color)
        s.circle(x, y + 5.6, 0.4, stroke=color)
        s.line(x, y + 6, x, y + 8, color)
        s.line(x - 2.2, y + 1.6, x - 2.2, y + 6.4, color, 0.3)
        s.line(x - 2.2, y + 4, x - 4.2, y + 4, color)
        s.line(x - 4.2, y + 3.2, x - 4.2, y + 4.8, color)
        s.text(x + 1.6, y + 3.6, ref, 1.9, weight="bold", fill=color)
        s.text(x + 1.6, y + 6.0, value, 1.8, fill=color)

    def connector(self, x, y, n, ref, value, pitch=6, names=None, color=INK, side="left"):
        """Vertical connector body; pins exit on `side`. Returns pin points."""
        s = self.s
        h = n * pitch
        s.rect(x, y, 6, h, stroke=color, sw=0.3)
        s.text(x + 3, y - 1.6, ref, 1.9, "middle", "bold", fill=color)
        s.text(x + 3, y + h + 3.2, value, 1.8, "middle", fill=color)
        pts = []
        for i in range(n):
            yy = y + pitch / 2 + i * pitch
            if side == "left":
                s.line(x - 3, yy, x, yy, color)
                pts.append((x - 3, yy))
                s.text(x + 1, yy + 0.7, str(i + 1), 1.7, fill=color)
            else:
                s.line(x + 6, yy, x + 9, yy, color)
                pts.append((x + 9, yy))
                s.text(x + 5, yy + 0.7, str(i + 1), 1.7, "end", fill=color)
            if names:
                s.text(x - 3.6 if side == "left" else x + 9.6, yy - 0.8, names[i], 1.5,
                       "end" if side == "left" else "start", fill=GREY)
        return pts

    def box(self, x, y, w, h, title):
        self.s.rect(x, y, w, h, stroke=LIGHT, sw=0.3, rx=1.2)
        self.s.text(x + 2, y + 4, title, 2.3, weight="bold", fill=GREY)

    # -- sheet ----------------------------------------------------------
    def draw(self) -> Svg:
        s = self.s
        s.frame()
        name = {"T1": "Trillium T1: core board (XIAO nRF52840 Sense)",
                "F1": "Trillium F1: core board + Trill Flex"}[self.m]
        s.text(12, 15.5, name, 4.6, weight="bold")
        s.text(12, 20.5, "Prototype schematic. All parts through-hole or modules on 2.54 mm headers; "
               "hand-built on 2.54 mm perfboard (see layout drawing).", 2.2, fill=GREY)
        self.power()
        self.mcu()
        self.led()
        self.buttons()
        self.i2c()
        self.notes()
        rows = [("Project", "Trillium hardware (nymble/trill)"),
                ("Model", {"T1": "T1  (Tiny, nRF52840)", "F1": "F1  (Flex, nRF52840)"}[self.m]),
                ("Board", "Core board 11 x 18 holes (27.9 x 45.7 mm)"),
                ("Revision", REV), ("Date", DATE),
                ("Status", "Design, not yet built or measured")]
        s.title_block(200, 157, 85, 45, rows, f"{self.m} schematic")
        return s

    def power(self):
        s = self.s
        self.box(12, 25, 88, 99, "POWER AND CHARGING")
        # battery symbol (vertical, + at top)
        bx, by = 22, 44
        s.line(bx, 38, bx, by, INK)
        for i in range(2):
            yy = by + i * 3
            s.line(bx - 3.2, yy, bx + 3.2, yy, INK, 0.35)
            s.line(bx - 1.8, yy + 1.4, bx + 1.8, yy + 1.4, INK, 0.6)
        s.line(bx, by + 4.4, bx, 58, INK)
        s.text(bx - 4, by + 0.6, "+", 2.6, "end", "bold", fill=ACCENT)
        s.text(16, 63, "BT1  LiPo 1S 3.7 V, with PCM", 1.9, weight="bold")
        cell = "502030 ~250 mAh" if self.m == "T1" else "503035 ~500 mAh"
        s.text(16, 65.8, cell + " (off-board)", 1.8, fill=GREY)
        # J1 (2 pins, pitch 8): pin1 at y=42, pin2 at y=50
        j = self.connector(34, 38, 2, "J1", "JST-PH 2", pitch=8, side="left")
        s.line(bx, 38, bx, 36, INK); s.line(bx, 36, 29, 36, INK); s.line(29, 36, 29, j[0][1], INK)
        s.line(29, j[0][1], j[0][0], j[0][1], INK)
        s.line(bx, 58, 29, 58, INK); s.line(29, 58, 29, j[1][1], INK); s.line(29, j[1][1], j[1][0], j[1][1], INK)
        # board side of J1
        y1, y2 = j[0][1], j[1][1]
        s.line(40, y2, 46, y2, INK)
        self.gnd(46, y2)
        s.line(40, y1, 62, y1, INK)
        s.text(51, y1 - 1.2, "VBAT", 1.8, "middle", fill=BLUE)
        # SW1
        s.dot(62, y1, 0.4, INK)                 # contact 1 (ON)
        s.circle(62, y1 + 6, 0.45)              # contact 3 (OFF, NC)
        s.line(62, y1 + 6, 59, y1 + 6, INK)
        s.text(58.4, y1 + 6.7, "NC", 1.7, "end", fill=GREY)
        px, py = 72, y1 + 3
        s.dot(px, py, 0.45)
        s.line(px, py, 62.6, y1 + 0.4, INK, 0.3)
        s.text(62, y1 - 1.6, "1 ON", 1.6, "middle", fill=GREY)
        s.text(62, y1 + 9.4, "3 OFF", 1.6, "middle", fill=GREY)
        s.text(px + 1, py - 4.6, "SW1", 1.9, "middle", "bold")
        s.text(px + 1, py + 6.6, "SPDT slide", 1.8, "middle")
        s.text(px + 0.8, py + 2.4, "2", 1.6, fill=GREY)
        s.line(px, py, 82, py, INK)
        self.label(82, py, "VBAT_SW", "right")
        lines = [
            "U1 contains the charger (TI BQ25101, 4.20 V) and the",
            "USB/battery switch-over (P-MOSFET + Schottky). Nothing",
            "else is needed on the board to charge the cell.",
            "",
            "SW1 ON + USB: runs from USB, charges BT1 (~50 mA;",
            "  ~100 mA if firmware drives P0.13 low).",
            "SW1 ON, no USB: runs from BT1.",
            "SW1 OFF: BT1 isolated (no drain, safe to ship). The",
            "  instrument still runs from USB but does not charge.",
            "",
            "Cell must have its own protection circuit (PCM).",
            "Check JST-PH polarity of every cell before plugging in:",
            "vendors differ. Red = +.",
        ]
        for i, t in enumerate(lines):
            s.text(16, 74 + i * 3.6, t, 1.95, fill=ACCENT if ("polarity" in t or "PCM" in t) else INK)

    def mcu(self):
        s = self.s
        self.box(104, 25, 92, 99, "MCU MODULE")
        x, y, w, h = 132, 34, 36, 76
        s.rect(x, y, w, h, sw=0.4, fill="#fafafa")
        s.text(x + w / 2, y + 5, "U1", 2.4, "middle", "bold")
        s.text(x + w / 2, y + 8.2, "Seeed XIAO", 1.9, "middle")
        s.text(x + w / 2, y + 10.8, "nRF52840 Sense", 1.9, "middle")
        s.text(x + w / 2, y - 2.0, "USB-C (top edge)", 1.7, "middle", fill=GREY)
        s.rect(x + w / 2 - 4.5, y - 1.4, 9, 1.4, stroke=GREY, sw=0.2)
        left = [p for p in hw.PIN_MAP if p.col == hw.XIAO_LEFT_COL]
        right = sorted([p for p in hw.PIN_MAP if p.col == hw.XIAO_RIGHT_COL], key=lambda p: p.row)
        step = 8
        for i, p in enumerate(left):
            yy = y + 18 + i * step
            s.line(x - 6, yy, x, yy)
            s.text(x - 0.8, yy - 0.8, str(p.num), 1.6, "end", fill=GREY)
            s.text(x + 1.2, yy + 0.7, f"{p.name}", 2.0)
            s.text(x + 1.2, yy + 3.0, p.port, 1.5, fill=GREY)
            self.mcu_net(x - 6, yy, p.net, "left")
        for i, p in enumerate(right):
            yy = y + 18 + i * step
            s.line(x + w, yy, x + w + 6, yy)
            s.text(x + w + 0.8, yy - 0.8, str(p.num), 1.6, fill=GREY)
            s.text(x + w - 1.2, yy + 0.7, p.name, 2.0, "end")
            if p.port != "-":
                s.text(x + w - 1.2, yy + 3.0, p.port, 1.5, "end", fill=GREY)
            self.mcu_net(x + w + 6, yy, p.net, "right")
        # underside pads
        for i, (pad, net, _) in enumerate(hw.XIAO_PADS):
            px = x + 11 + i * 14
            s.line(px, y + h, px, y + h + 6)
            s.text(px, y + h - 1.4, pad, 1.8, "middle")
            if net == "GND":
                self.gnd(px, y + h + 6)
                s.text(px + 3, y + h + 9.6, "internal", 1.5, fill=GREY)
            else:
                s.line(px, y + h + 6, px - 4, y + h + 6)
                self.label(px - 4, y + h + 6, net, "left")
        s.text(x + w / 2, y + h - 4.6, "underside pads", 1.6, "middle", fill=GREY)

    def mcu_net(self, x, y, net, side):
        s = self.s
        if net == "GND":
            s.line(x, y, x + 4, y)
            self.gnd(x + 4, y)
        elif net == "+3V3":
            s.line(x, y, x + 11, y)
            self.vcc(x + 11, y)
        elif net.startswith("NC"):
            s.line(x - 0.9, y - 0.9, x + 0.9, y + 0.9, ACCENT, 0.3)
            s.line(x - 0.9, y + 0.9, x + 0.9, y - 0.9, ACCENT, 0.3)
            s.text(x + 1.8, y + 0.7, "NC (VBUS)", 1.7, fill=GREY)
        elif net.startswith("TP"):
            s.circle(x - 0.7, y, 0.7)
            s.text(x - 2.2, y + 0.7, "reserved (debug)", 1.7, "end", fill=GREY)
        else:
            if net in ("SDA", "SCL") and self.m == "T1":
                self.label(x, y, net, side, GREY)
            else:
                self.label(x, y, net, side)

    def led(self):
        s = self.s
        self.box(200, 25, 90, 57, "STATUS LED (external, visible through case)")
        xs = (252, 262, 272)
        names = ("R", "G", "B")
        self.vcc(262, 34)
        s.line(252, 34, 272, 34)
        rows = (54, 62, 70)
        refs = (("R3", "680 Ω"), ("R4", "150 Ω"), ("R5", "150 Ω"))
        nets = ("LED_R_DRV", "LED_G_DRV", "LED_B_DRV")
        for xx, nm, yy, (ref, val), net in zip(xs, names, rows, refs, nets):
            s.dot(xx, 34) if xx == 262 else None
            self.diode_down(xx, 34)
            s.text(xx - 2.0, 44.5, nm, 1.8, "end", "bold")
            s.line(xx, 41, xx, yy)
            s.line(xx, yy, 238, yy)
            self.resistor(238, yy, 224, yy, ref, val)
            s.line(224, yy, 222, yy)
            self.label(222, yy, net, "left")
        s.text(276, 38, "D1", 1.9, weight="bold")
        s.text(276, 40.6, "RGB 5 mm", 1.7)
        s.text(276, 43.0, "common", 1.7)
        s.text(276, 45.4, "anode", 1.7)
        s.text(204, 77.2, "Active low: pin low = on. Firmware should set P1.13-15 to high drive (H0H1).", 1.7, fill=GREY)
        s.text(204, 79.6, "G/B values assume Vf ≈ 2.8 V at 2-4 mA; tune 82-220 Ω for even brightness.", 1.7, fill=GREY)

    def buttons(self):
        s = self.s
        self.box(200, 85, 90, 69, "BUTTONS (at least 2)")
        for x, ref, net in ((218, "SW2", "BTN_A"), (240, "SW3", "BTN_B")):
            s.line(x, 100, x, 104)
            self.label(x, 100, net, "left") if False else None
            s.line(x, 100, x - 2, 100)
            self.label(x - 2, 100, net, "left")
            self.tact(x, 104, ref, "A" if ref == "SW2" else "B")
            self.gnd(x, 112)
        s.text(206, 121.5, "Tactile 6 x 6 mm (B3F-1000), to GND.", 1.8)
        s.text(206, 124.1, "Firmware: internal pull-up (~13 kΩ), debounce.", 1.8)
        # J3
        color = INK
        pts = self.connector(270, 96, 3, "J3", "AUX (opt.)", pitch=6, side="left",
                             names=None, color=color)
        for (px, py), net in zip(pts, ("AUX_C", "BTN_D", "GND")):
            if net == "GND":
                s.line(px, py, px - 3, py)
                self.gnd(px - 3, py)
            else:
                self.label(px, py, net, "left")
        s.text(206, 131, "J3: external buttons C (D6) and D (D7), each to GND,", 1.8)
        s.text(206, 133.6, "e.g. panel-mount buttons on a case wall.", 1.8)
        if self.m == "F1":
            s.text(206, 137.4, "F1: if JP1 is fitted, D6 carries Trill EVT and", 1.8, fill=ACCENT)
            s.text(206, 140.0, "button C must not be connected.", 1.8, fill=ACCENT)
        s.text(206, 145, "D6, D7 are P1.xx pins: Nordic recommends low-frequency", 1.7, fill=GREY)
        s.text(206, 147.4, "use only, which suits buttons and LEDs.", 1.7, fill=GREY)

    def i2c(self):
        s = self.s
        f1 = self.m == "F1"
        c = INK if f1 else GREY
        self.box(12, 127, 184, 41, "I2C: TRILL FLEX" if f1 else "I2C EXPANSION (not fitted on T1)")
        # pull-ups
        self.vcc(44, 136, color=c)
        s.line(44, 136, 54, 136, c)
        s.dot(44, 136, 0.4, c)
        self.resistor(44, 136, 44, 147, "R1", "4.7 kΩ", c, -1)
        self.resistor(54, 136, 54, 152, "R2", "4.7 kΩ", c, 1)
        s.line(28, 147, 82, 147, c); s.dot(44, 147, 0.4, c)
        s.line(28, 152, 82, 152, c); s.dot(54, 152, 0.4, c)
        self.label(28, 147, "SDA", "left", c)
        self.label(28, 152, "SCL", "left", c)
        pts = self.connector(85, 135, 5, "J2", "TRILL 5", pitch=5, side="left", color=c)
        # pin1 GND, pin2 3V3, pin3 SDA, pin4 SCL, pin5 EVT
        s.line(pts[0][0], pts[0][1], 72, pts[0][1], c); self.gnd(72, pts[0][1], c)
        s.line(pts[1][0], pts[1][1], 78, pts[1][1], c); self.vcc(78, pts[1][1], color=c)
        s.line(82, 147, 82, pts[2][1], c); s.line(82, pts[2][1], pts[2][0], pts[2][1], c)
        s.line(82, 152, 82, 153, c)
        s.line(82, 152, pts[3][0] - 0, pts[3][1], c) if False else None
        s.line(82, 152, 82, pts[3][1], c); s.line(82, pts[3][1], pts[3][0], pts[3][1], c)
        # pin 5 EVT -> JP1 -> AUX_C
        s.line(pts[4][0], pts[4][1], 70, pts[4][1], c)
        s.circle(69.3, pts[4][1], 0.7, stroke=c)
        s.circle(65.7, pts[4][1], 0.7, stroke=c)
        s.path(f"M 69.3 {pts[4][1]-0.9} Q 67.5 {pts[4][1]-2.6} 65.7 {pts[4][1]-0.9}", stroke=c, sw=0.2)
        s.text(67.5, pts[4][1] + 3.0, "JP1 (opt.)", 1.6, "middle", fill=c)
        s.line(65, pts[4][1], 62, pts[4][1], c)
        self.label(62, pts[4][1], "AUX_C", "left", c)
        s.text(78, pts[4][1] - 1.0, "EVT", 1.6, "middle", fill=GREY)
        for i, nm in enumerate(("GND", "3V3", "SDA", "SCL", "EVT")):
            s.text(92.6, pts[i][1] + 0.7, nm, 1.6, fill=c)
        if not f1:
            s.text(104, 140, "T1 leaves R1, R2, J2 and JP1 unfitted: holes stay free so a", 2.0, fill=GREY)
            s.text(104, 143.4, "T1 board can be upgraded to F1, or take any Qwiic/I2C module", 2.0, fill=GREY)
            s.text(104, 146.8, "(3.3 V only, address must not clash). D4/D5 are not 5 V tolerant.", 2.0, fill=GREY)
            return
        # cable + Trill Flex
        s.line(100, 137.5, 112, 137.5, INK, 0.25, dash="1.2,0.8")
        s.text(106, 135.6, "W1 Qwiic cable", 1.6, "middle", fill=GREY)
        tx, ty = 114, 133
        s.rect(tx, ty, 32, 28, sw=0.4, fill="#fafafa")
        s.text(tx + 16, ty + 4.5, "U2  Bela Trill Flex", 2.0, "middle", "bold")
        s.text(tx + 16, ty + 7.3, "base, I2C addr 0x48", 1.7, "middle")
        for i, nm in enumerate(("1 GND", "2 VCC", "3 SDA", "4 SCL")):
            s.text(tx + 1.2, ty + 11.5 + i * 2.6, nm, 1.6)
        s.text(tx + 1.2, ty + 23.0, "Qwiic (JST-SH)", 1.5, fill=GREY)
        s.text(tx + 1.2, ty + 25.4, "EVT/RST: unpopulated pads", 1.5, fill=GREY)
        s.text(tx + 31, ty + 15, "FFC 32p", 1.5, "end", fill=GREY)
        s.text(tx + 31, ty + 17.4, "0.5 mm", 1.5, "end", fill=GREY)
        s.rect(tx + 32, ty + 12, 2, 8, stroke=INK, sw=0.25)
        # flex sensor
        s.poly([(tx + 34, ty + 14), (tx + 40, ty + 14), (tx + 42, ty + 10), (tx + 80, ty + 10),
                (tx + 80, ty + 24), (tx + 42, ty + 24), (tx + 40, ty + 18), (tx + 34, ty + 18)],
               stroke=INK, sw=0.3, close=True)
        for k in range(12):
            xx = tx + 44 + k * 3
            s.line(xx, ty + 11.5, xx, ty + 22.5, LIGHT, 0.6)
        s.text(tx + 61, ty + 7.5, "S1  Trill Flex sensor (flex PCB)", 1.8, "middle", weight="bold")
        s.text(tx + 61, ty + 27.2, "stock 1-axis strip: Mode::Centroid", 1.6, "middle", fill=GREY)

    def notes(self):
        s = self.s
        notes = [
            "1. Pin allocation is identical on T1 and F1 so that one firmware image serves both (see hardware/README.md).",
            "2. D0/D1 are reserved for the firmware's timing-gpio feature (logic analyser). Leave unconnected.",
            "3. U1 is soldered on male headers (2.5 mm spacer). Solder the BAT+ flying lead to the underside pad BEFORE fitting U1.",
            "4. 3V3 comes from U1's SGM2040 LDO (250 mA). Budget: Trill ~4 mA, LED <= 10 mA, buttons negligible.",
            "5. Never connect the cell, VBAT or 5V to 3V3, to D-pins or to the Trill. All I/O is 3.3 V, not 5 V tolerant.",
            "6. The on-board RGB LED and red charge LED of U1 remain; D1 duplicates status where U1 cannot be seen.",
        ]
        if self.m == "T1":
            notes[5] = "6. On-board RGB and charge LEDs of U1 remain; D1 shows status through the case. R1/R2/J2/JP1: F1 only."
        for i, t in enumerate(notes):
            s.text(12, 174 + i * 4.6, t, 2.0)
        s.text(12, 203, "Values for parts marked 'tune' are starting points for bring-up, not measured results.", 1.8, fill=GREY)


def draw(model: str) -> Svg:
    return Sch(model).draw()


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    for m in ("T1", "F1"):
        draw(m).save(f"{out}/{m.lower()}-schematic.svg")
