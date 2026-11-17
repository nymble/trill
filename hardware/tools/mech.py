"""Enclosure drawings (T1, F1p, F1w) and F1w laser-cut sheets."""

from __future__ import annotations

import math

from matplotlib.font_manager import FontProperties
from matplotlib.path import Path as MPath
from matplotlib.textpath import TextPath

import hw_model as hw
import mech_params as mp
from svgkit import Svg, INK, GREY, LIGHT, ACCENT, BLUE

DATE = "2026-11-11"
REV = "A (prototype)"
HIDDEN = "1.2,0.8"


# ======================================================================
# Rectilinear region boolean + outline tracing (for laser layers)
# ======================================================================
class Region:
    """Ordered rectilinear boolean: ops applied in sequence; rects = (x0, y0, x1, y1)."""

    def __init__(self):
        self.ops: list[tuple[str, tuple]] = []

    @property
    def add(self):
        return _OpList(self, "add")

    @property
    def sub(self):
        return _OpList(self, "sub")

    def rects(self):
        return [r for _, r in self.ops]

    def inside(self, x, y):
        state = False
        for op, r in self.ops:
            if r[0] <= x <= r[2] and r[1] <= y <= r[3]:
                state = op == "add"
        return state

    def loops(self):
        xs = sorted({v for r in self.rects() for v in (r[0], r[2])})
        ys = sorted({v for r in self.rects() for v in (r[1], r[3])})
        nx, ny = len(xs) - 1, len(ys) - 1
        cell = [[self.inside((xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2) for j in range(ny)] for i in range(nx)]

        def C(i, j):
            return 0 <= i < nx and 0 <= j < ny and cell[i][j]

        edges = {}
        for i in range(nx):
            for j in range(ny):
                if not cell[i][j]:
                    continue
                # counter-clockwise around filled cells (y up)
                if not C(i, j - 1):
                    edges.setdefault((i, j), []).append((i + 1, j))
                if not C(i + 1, j):
                    edges.setdefault((i + 1, j), []).append((i + 1, j + 1))
                if not C(i, j + 1):
                    edges.setdefault((i + 1, j + 1), []).append((i, j + 1))
                if not C(i - 1, j):
                    edges.setdefault((i, j + 1), []).append((i, j))
        loops = []
        while edges:
            start = next(iter(edges))
            loop = [start]
            cur = start
            while True:
                nxts = edges[cur]
                nxt = nxts.pop()
                if not nxts:
                    del edges[cur]
                if nxt == start:
                    break
                loop.append(nxt)
                cur = nxt
            # drop collinear points
            pts = [(xs[i], ys[j]) for i, j in loop]
            clean = []
            n = len(pts)
            for k in range(n):
                a, b, c = pts[k - 1], pts[k], pts[(k + 1) % n]
                if (a[0] == b[0] == c[0]) or (a[1] == b[1] == c[1]):
                    continue
                clean.append(b)
            loops.append(clean)
        return loops


class _OpList:
    def __init__(self, reg, op):
        self.reg, self.op = reg, op

    def append(self, r):
        self.reg.ops.append((self.op, r))

    def extend(self, rs):
        for r in rs:
            self.append(r)


def text_path_d(s, x, y, size, anchor="start", weight="bold"):
    """Text as filled SVG path data (for laser engraving), baseline at y, y down."""
    tp = TextPath((0, 0), s, size=size, prop=FontProperties(family="DejaVu Sans", weight=weight))
    ext = tp.get_extents()
    dx = {"start": 0, "middle": -ext.width / 2 - ext.x0, "end": -ext.width - ext.x0}[anchor]
    d = []
    for verts, code in tp.iter_segments(curves=True, simplify=False):
        pts = [(x + dx + verts[k], y - verts[k + 1]) for k in range(0, len(verts), 2)]
        if code == MPath.MOVETO:
            d.append("M %.3f %.3f" % pts[0])
        elif code == MPath.LINETO:
            d.append("L %.3f %.3f" % pts[0])
        elif code == MPath.CURVE3:
            d.append("Q %.3f %.3f %.3f %.3f" % (*pts[0], *pts[1]))
        elif code == MPath.CURVE4:
            d.append("C %.3f %.3f %.3f %.3f %.3f %.3f" % (*pts[0], *pts[1], *pts[2]))
        elif code == MPath.CLOSEPOLY:
            d.append("Z")
    return " ".join(d)


# ======================================================================
# F1w layers
# ======================================================================
def f1w_layers(w: mp.F1w | None = None, kerf: float | None = None):
    """Return {layer: dict(region, circles, hexes, engrave_rects, texts)} in OUTER coords, y up."""
    w = w or mp.F1w()
    k = w.kerf if kerf is None else kerf
    h = k / 2
    ox, oy = w.wall, w.out_w / 2          # inner (X, Y) -> outer (X + ox, Y + oy)

    def R(x0, y0, x1, y1, grow=0.0):
        return (x0 + ox - grow, y0 + oy - grow, x1 + ox + grow, y1 + oy + grow)

    inner = (0, -w.in_w / 2, w.in_l, w.in_w / 2)
    outer = (-h, -h, w.out_l + h, w.out_w + h)

    def zone_rect(z, g=-0.2):
        x0, y0, x1, y1 = z
        return (w.X(y0) - g * -1 if False else w.X(y0) - g, w.Y(x0) - g, w.X(y1) + g, w.Y(x1) + g)

    tabs = []
    for (c, r0, r1), z in zip(hw.CORNER_ZONES, mp.ZONES_B):
        X0, Y0, X1, Y1 = w.X(z[1]) + 0.2, w.Y(z[0]) + 0.2, w.X(z[3]) - 0.2, w.Y(z[2]) - 0.2
        if c == 0:
            Y0 = -w.in_w / 2 - 0.01
        else:
            Y1 = w.in_w / 2 + 0.01
        if r0 == 0:
            X0 = -0.01
        tabs.append((X0, Y0, X1, Y1))

    usb_y = w.Y(hw.XIAO_CX)
    usb = (-w.wall - 1, usb_y - mp.USB_OPEN_W / 2, 0.01, usb_y + mp.USB_OPEN_W / 2)
    sx = w.X(mp.SW1_B_Y)
    sw1_bulge = (sx - 5, w.in_w / 2 - 0.01, sx + 5, w.in_w / 2 + w.wall - 2.0)
    sw1_slot = (sx - mp.SW1_SLOT_L / 2, w.in_w / 2, sx + mp.SW1_SLOT_L / 2, w.in_w / 2 + w.wall + 1)

    bolts = [(bx, by) for bx in w.bolt_x_out for by in (w.wall / 2, w.out_w - w.wall / 2)]

    def cav(r):        # cavity rect (inner coords) shrunk by kerf/2 for the material region
        return R(r[0], r[1], r[2], r[3], -h)

    layers = {}

    def new(name):
        reg = Region()
        reg.add.append(outer)
        d = dict(region=reg, circles=[], hexes=[], engrave_rects=[], texts=[])
        layers[name] = d
        return d

    def sub_minus_tabs(reg, base_rect, tab_list):
        """cavity = base_rect minus tabs: subtract the cavity, then add the tabs back (kerf-grown)."""
        reg.sub.append(cav(base_rect))
        for t_ in tab_list:
            reg.add.append(R(t_[0], t_[1], t_[2], t_[3], +h))

    # L0: bottom plate
    d = new("L0")
    d["circles"] += [(bx, by, 1.7 - h) for bx, by in bolts]
    # L1: nut traps + board support tabs
    d = new("L1")
    sub_minus_tabs(d["region"], inner, tabs)
    d["hexes"] += [(bx, by, 5.6 - k) for bx, by in bolts]
    # L2: board pocket (1.5 mm)
    d = new("L2")
    pocket = (w.X(0) - 0.15, w.Y(0) - 0.15, w.X(hw.BOARD_L) + 0.15, w.Y(hw.BOARD_W) + 0.15)
    d["region"].sub.append(cav(pocket))
    d["region"].sub.append(cav((pocket[2] - 0.01, -w.in_w / 2, w.in_l, w.in_w / 2)))
    d["circles"] += [(bx, by, 1.7 - h) for bx, by in bolts]
    # L3: retainer tabs, SW1 slot, USB opening
    d = new("L3")
    sub_minus_tabs(d["region"], inner, tabs)
    for r in (sw1_bulge, sw1_slot, usb):
        d["region"].sub.append(cav(r))
    d["circles"] += [(bx, by, 1.7 - h) for bx, by in bolts]
    for name in [f"L{3 + i}" for i in range(1, w.n_upper)]:
        d = new(name)
        d["region"].sub.append(cav(inner))
        if name in ("L4", "L5"):
            d["region"].sub.append(cav(usb))
        d["circles"] += [(bx, by, 1.7 - h) for bx, by in bolts]
    # TOP
    d = new("TOP")
    d["circles"] += [(bx, by, 1.7 - h) for bx, by in bolts]
    lx, ly = w.X(mp.LED_B[1]) + ox, w.Y(mp.LED_B[0]) + oy
    d["circles"].append((lx, ly, mp.LED_HOLE_D / 2 - h))
    for b in (mp.SW2_B, mp.SW3_B):
        d["circles"].append((w.X(b[1]) + ox, w.Y(b[0]) + oy, mp.BTN_HOLE_D / 2 - h))
    d["region"].sub.append(cav((w.slot_x, -11.5, w.slot_x + w.slot_w, 11.5)))
    d["engrave_rects"].append(R(w.ch_x0 + w.slot_w, -(hw.TRILL_SENSOR_W + 0.8) / 2, w.ch_x1, (hw.TRILL_SENSOR_W + 0.8) / 2))
    d["texts"] += [("TRILLIUM", 13.0 + ox, usb_y + oy + 3.2, 3.6, "middle"), ("F1w", 13.0 + ox, usb_y + oy - 3.6, 3.0, "middle"),
                   ("A", w.X(mp.SW2_B[1]) + ox + 5.8, w.Y(mp.SW2_B[0]) + oy, 2.8, "middle"),
                   ("B", w.X(mp.SW3_B[1]) + ox + 5.8, w.Y(mp.SW3_B[0]) + oy, 2.8, "middle")]
    # hidden layer IDs on wall faces (orientation: near the USB end, -Y wall)
    for name, dd in layers.items():
        if name != "TOP":
            dd["texts"].append((name, 16.0, w.wall / 2, 2.6, "start-id"))
    return layers, w


def plunger_discs(w: mp.F1w):
    """(sheet, diameter) list for two laminated button plungers."""
    k = w.kerf
    big, stem = mp.CAP_BIG_D, mp.CAP_STEM_D
    discs = []
    for _ in range(2):
        discs += [("3", big), ("3", big), ("1.5", big), ("3", stem), ("1.5", stem)]
    return discs


def _emit_layer(s: Svg, d, x0, y0, out_w, cut="#ff0000", engrave="#000000", sw=0.1, preview=False):
    """Draw one layer with its own outer coords (y up) at sheet position (x0, y0 = top-left)."""
    def T(x, y):
        return x0 + x, y0 + (out_w - y)
    for loop in d["region"].loops():
        pts = [T(*p) for p in loop]
        s.poly(pts, stroke=cut, sw=sw, close=True, fill="none")
    for cx, cy, r in d["circles"]:
        X, Y = T(cx, cy)
        s.circle(X, Y, r, stroke=cut, sw=sw)
    for cx, cy, af in d["hexes"]:
        X, Y = T(cx, cy)
        rr = af / math.sqrt(3)
        pts = [(X + rr * math.cos(math.radians(30 + 60 * i)), Y + rr * math.sin(math.radians(30 + 60 * i))) for i in range(6)]
        s.poly(pts, stroke=cut, sw=sw, close=True)
    for r in d["engrave_rects"]:
        X0, Y0 = T(r[0], r[3])
        s.rect(X0, Y0, r[2] - r[0], r[3] - r[1], stroke="none", fill=engrave if not preview else "#e8dcc0")
    for t, x, y, size, anchor in d["texts"]:
        X, Y = T(x, y)
        if anchor == "start-id":
            s.path(text_path_d(t, X, Y + size / 2.6, size, "start"), stroke="none", fill=engrave if not preview else GREY)
        else:
            s.path(text_path_d(t, X, Y + size / 2.6, size, anchor), stroke="none", fill=engrave if not preview else INK)


def f1w_sheets(outdir):
    layers, w = f1w_layers()
    gap = 4.0
    # 3 mm sheet: 2 columns x 4 rows
    names3 = ["TOP", "L0", "L1", "L3", "L4", "L5", "L6"]
    cols, rows = 2, 4
    sw_ = cols * w.out_l + (cols + 1) * gap
    sh_ = rows * w.out_w + (rows + 1) * gap
    s = Svg(round(sw_ + 0.5, 1), round(sh_ + 0.5, 1))
    s.bg = False
    for i, n in enumerate(names3):
        c, r = i % cols, i // cols
        _emit_layer(s, layers[n], gap + c * (w.out_l + gap), gap + r * (w.out_w + gap), w.out_w)
    # plunger discs in the last cell
    cx0, cy0 = gap + 1 * (w.out_l + gap), gap + 3 * (w.out_w + gap)
    x = cx0 + 6
    for sheet, dia in plunger_discs(w):
        if sheet != "3":
            continue
        s.circle(x, cy0 + 8, dia / 2 + w.kerf / 2, stroke="#ff0000", sw=0.1)
        x += dia + 3
    s.save(f"{outdir}/f1w-sheet-3mm.svg")
    sheet3 = (s.w, s.h)
    # 1.5 mm sheet
    s2 = Svg(round(w.out_l + 2 * gap + 0.5, 1), round(w.out_w + 2 * gap + 16, 1))
    s2.bg = False
    _emit_layer(s2, layers["L2"], gap, gap, w.out_w)
    x = gap + 6
    for sheet, dia in plunger_discs(w):
        if sheet != "1.5":
            continue
        s2.circle(x, w.out_w + 2 * gap + 7, dia / 2 + w.kerf / 2, stroke="#ff0000", sw=0.1)
        x += dia + 3
    s2.save(f"{outdir}/f1w-sheet-1.5mm.svg")
    return sheet3, (s2.w, s2.h)


# ======================================================================
# Drawings
# ======================================================================
def title(s: Svg, x, y, w, h, name, scale, extra=()):
    rows = [("Project", "Trillium hardware (nymble/trill)"), ("Part", name), ("Scale", scale),
            ("Revision", REV), ("Date", DATE), ("Units", "mm; general tolerance ±0.2 (print), ±0.1 (laser)")] + list(extra)
    s.title_block(x, y, w, h, rows, name)


def notes_block(s: Svg, x, y, lines, size=1.9, step=3.3):
    for i, t in enumerate(lines):
        s.text(x, y + i * step, t, size, fill=ACCENT if t.startswith("!") else INK)


def t1_drawing(path):
    t = mp.T1()
    s = Svg(297, 210)
    s.frame()
    s.text(12, 15.5, "Trillium T1 enclosure (3D printed): base, lid, button caps", 4.6, weight="bold")
    s.text(12, 20.5, "Source: t1/t1-enclosure.scad (parametric). Outside "
           f"{t.out_x:.1f} x {t.out_y:.1f} x {t.out_z:.1f} mm.", 2.2, fill=GREY)
    k = 2.0
    # ---- top view (lid on, internals hidden) ----
    ox, oy = 22, 36
    s.text(ox, oy - 4, "TOP VIEW (lid fitted, internals dashed)  2:1", 2.3, weight="bold")

    def TX(x):
        return ox + x * k

    def TY(y):
        return oy + (t.out_y - y) * k
    r = t.corner_r * k
    s.rect(TX(0), TY(t.out_y), t.out_x * k, t.out_y * k, sw=0.45, rx=r)
    s.rect(TX(t.wall), TY(t.wall + t.in_y), t.in_x * k, t.in_y * k, stroke=GREY, sw=0.2, dash=HIDDEN)
    # board + xiao + cell hidden
    s.rect(TX(t.X(0)), TY(t.Y(0)), hw.BOARD_W * k, hw.BOARD_L * k, stroke=GREY, sw=0.2, dash=HIDDEN)
    s.rect(TX(t.X(hw.XIAO_CX - hw.XIAO_W / 2)), TY(t.Y(hw.XIAO_TOP_Y)), hw.XIAO_W * k, hw.XIAO_L * k, stroke=GREY, sw=0.2, dash=HIDDEN)
    c = hw.CELL_T1
    s.rect(TX(t.out_x / 2 - c[1] / 2), TY(t.Y(hw.BOARD_L / 2) + c[2] / 2), c[1] * k, c[2] * k, stroke=BLUE, sw=0.2, dash=HIDDEN)
    for z in mp.ZONES_B:
        s.rect(TX(t.X(z[0]) + 0.2), TY(t.Y(z[1]) - 0.2), (z[2] - z[0] - 0.4) * k, (z[3] - z[1] - 0.4) * k, stroke=GREY, sw=0.2, fill="#eeeeee")
    led = (t.X(mp.LED_B[0]), t.Y(mp.LED_B[1]))
    s.circle(TX(led[0]), TY(led[1]), mp.LED_HOLE_D / 2 * k, sw=0.35)
    btns = [(t.X(b[0]), t.Y(b[1])) for b in (mp.SW2_B, mp.SW3_B)]
    for (bx, by), nm in zip(btns, "AB"):
        s.circle(TX(bx), TY(by), mp.BTN_HOLE_D / 2 * k, sw=0.35)
        s.circle(TX(bx), TY(by), mp.CAP_STEM_D / 2 * k, stroke=GREY, sw=0.2)
        s.text(TX(bx), TY(by - 5.6) + 1, nm, 2.6, "middle", "bold", fill=GREY)
    s.text(TX(t.out_x / 2), TY(t.Y(9)) + 1, "TRILLIUM", 3.0, "middle", "bold", fill=GREY)
    s.text(TX(t.out_x / 2), TY(t.Y(16)) + 1, "T1", 2.6, "middle", fill=GREY)
    # USB and SW1 positions
    ux = t.X(hw.XIAO_CX)
    s.line(TX(ux - mp.USB_OPEN_W / 2), TY(t.out_y) - 0.1, TX(ux + mp.USB_OPEN_W / 2), TY(t.out_y) - 0.1, ACCENT, 0.8)
    s.text(TX(ux), TY(t.out_y) - 2.0, "USB-C", 1.9, "middle", fill=ACCENT)
    sy = t.Y(mp.SW1_B_Y)
    s.line(TX(t.out_x) + 0.1, TY(sy + mp.SW1_SLOT_L / 2), TX(t.out_x) + 0.1, TY(sy - mp.SW1_SLOT_L / 2), ACCENT, 0.8)
    s.text(TX(t.out_x) + 1.5, TY(sy) + 0.7, "SW1", 1.9, fill=ACCENT)
    # dims
    s.dim(TX(0), TY(0), TX(t.out_x), TY(0), f"{t.out_x:.2f}", off=5)
    s.dim(TX(0), TY(0), TX(0), TY(t.out_y), f"{t.out_y:.2f}", off=-6)
    s.dim(TX(0), TY(0), TX(led[0]), TY(0), f"{led[0]:.2f}", off=10)
    s.dim(TX(0), TY(0), TX(btns[0][0]), TY(0), f"{btns[0][0]:.2f}", off=14)
    s.dim(TX(0), TY(0), TX(btns[1][0]), TY(0), f"{btns[1][0]:.2f}", off=18)
    s.dim(TX(t.out_x), TY(0), TX(t.out_x), TY(led[1]), f"{led[1]:.2f}", off=8)
    s.dim(TX(t.out_x), TY(0), TX(t.out_x), TY(btns[0][1]), f"{btns[0][1]:.2f}", off=15)
    s.text(TX(led[0]) + 5.5, TY(led[1]) + 0.7, f"Ø{mp.LED_HOLE_D} LED", 1.8)
    s.text(TX(btns[1][0]) + 4.0, TY(btns[1][1]) - 4.5, f"Ø{mp.BTN_HOLE_D} x2", 1.8)

    # ---- section (Y-Z) through X = LED ----
    sx0, sy0 = 150, 40
    s.text(sx0, sy0 - 8, "SECTION A-A (side, through the LED)  2:1", 2.3, weight="bold")

    def SX(y):    # horizontal = Y (USB at right)
        return sx0 + y * k

    def SZ(z):
        return sy0 + (t.out_z - z) * k + 6
    # base walls and floor
    s.rect(SX(0), SZ(t.lid_under), t.wall * k, t.lid_under * k, fill="#dcdcdc", sw=0.3)
    s.rect(SX(t.out_y - t.wall), SZ(t.lid_under), t.wall * k, t.lid_under * k, fill="#dcdcdc", sw=0.3)
    s.rect(SX(0), SZ(t.floor), t.out_y * k, t.floor * k, fill="#dcdcdc", sw=0.3)
    # USB opening cut in +Y wall
    uz = t.board_top + hw.USB_Z_ABOVE_BOARD
    s.rect(SX(t.out_y - t.wall), SZ(t.lid_under), t.wall * k, (t.lid_under - (uz - mp.USB_OPEN_H / 2)) * k, fill="white", stroke=INK, sw=0.2)
    # lid
    s.rect(SX(0), SZ(t.out_z), t.out_y * k, t.lid * k, fill="#c9d6e8", sw=0.3)
    ledy = led[1]
    s.rect(SX(ledy - mp.LED_HOLE_D / 2), SZ(t.out_z), mp.LED_HOLE_D * k, t.lid * k, fill="white", stroke="none")
    # cell, board, xiao, led
    s.rect(SX(t.Y(hw.BOARD_L / 2) - c[2] / 2), SZ(t.floor + c[0]), c[2] * k, c[0] * k, fill="#f0e6c8", sw=0.25)
    s.text(SX(t.Y(hw.BOARD_L / 2)), SZ(t.floor + c[0] / 2) + 0.8, "cell 502030", 1.8, "middle")
    s.rect(SX(t.Y(hw.BOARD_L)), SZ(t.board_top), hw.BOARD_L * k, hw.BOARD_T * k, fill="#9fc79f", sw=0.25)
    xz0 = t.board_top + hw.XIAO_HEADER_SPACER
    s.rect(SX(t.Y(hw.XIAO_TOP_Y + hw.XIAO_L)), SZ(xz0 + hw.XIAO_PCB_T), hw.XIAO_L * k, hw.XIAO_PCB_T * k, fill="#3d3d3d", sw=0.2)
    s.rect(SX(t.Y(hw.USB_FACE_Y) - 7.4), SZ(xz0 + hw.XIAO_PCB_T + hw.USB_C_H), 7.4 * k, hw.USB_C_H * k, fill="#b5b5b5", sw=0.2)
    s.text(SX(t.Y(10)), SZ(xz0 + 3.5), "XIAO on 2.5 mm header", 1.7, "middle")
    s.rect(SX(ledy - 2.5), SZ(t.out_z), 5 * k, (hw.LED_H - 2.5) * k, fill="#f3d7d7", sw=0.25)
    s.circle(SX(ledy), SZ(t.out_z - 2.5), 2.5 * k, fill="#f3d7d7", sw=0.25)
    s.rect(SX(ledy - 2.9), SZ(t.board_top + t.led_standoff), 5.8 * k, 1.0 * k, fill="#f3d7d7", sw=0.25)
    s.rect(SX(ledy - 1.6), SZ(t.board_top + t.led_standoff), 3.2 * k, t.led_standoff * k, fill="#eeeeee", sw=0.2, dash="0.6,0.4")
    # z dims
    for zz, lab, off in ((t.board_z0, f"{t.board_z0:.1f} board underside", 0), (t.board_top, f"{t.board_top:.1f} board top", 0),
                         (t.lid_under, f"{t.lid_under:.1f} lid underside / wall top", 0), (t.out_z, f"{t.out_z:.1f} overall", 0)):
        s.line(SX(t.out_y) + 1, SZ(zz), SX(t.out_y) + 4, SZ(zz), GREY, 0.15)
        s.text(SX(t.out_y) + 5, SZ(zz) + 0.7, lab, 1.8)
    s.text(SX(ledy), SZ(t.out_z) - 2.0, f"LED dome flush; {t.led_standoff:.1f} mm standoff", 1.7, "middle")
    s.text(SX(t.out_y - 1), SZ(uz) + 0.7, "USB-C", 1.7, "end", fill=ACCENT)

    # ---- right-side elevation (+X wall) ----
    ex0, ey0 = 150, 122
    k = 1.5
    s.text(ex0, ey0 - 4, "SIDE ELEVATION (+X wall, power switch)  1.5:1", 2.3, weight="bold")

    def EX(y):
        return ex0 + y * k

    def EZ(z):
        return ey0 + (t.out_z - z) * k
    s.rect(EX(0), EZ(t.out_z), t.out_y * k, t.out_z * k, sw=0.45, rx=0.6)
    s.line(EX(0), EZ(t.lid_under), EX(t.out_y), EZ(t.lid_under), sw=0.25)
    sz = t.board_top + hw.SW1_ACT_Z
    s.rect(EX(sy - mp.SW1_SLOT_L / 2), EZ(sz + mp.SW1_SLOT_H / 2), mp.SW1_SLOT_L * k, mp.SW1_SLOT_H * k, sw=0.35)
    s.text(EX(sy), EZ(sz + 3.2) - 0.8, "PWR", 2.0, "middle", "bold", fill=GREY)
    s.dim(EX(0), EZ(0), EX(sy), EZ(0), f"{sy:.2f}", off=5)
    s.dim(EX(t.out_y), EZ(0), EX(t.out_y), EZ(sz), f"{sz:.2f}", off=4)
    s.dim(EX(0), EZ(0), EX(0), EZ(t.out_z), f"{t.out_z:.2f}", off=-4)
    s.text(EX(sy), EZ(sz) + 6.5, f"slot {mp.SW1_SLOT_L} x {mp.SW1_SLOT_H}", 1.8, "middle")

    # ---- end elevation (+Y, USB) ----
    gx0, gy0 = 240, 122
    s.text(gx0 - 6, gy0 - 4, "END (+Y, USB-C)  1.5:1", 2.3, weight="bold")

    def GX(x):
        return gx0 + (t.out_x - x) * k

    def GZ(z):
        return gy0 + (t.out_z - z) * k
    s.rect(GX(t.out_x), GZ(t.out_z), t.out_x * k, t.out_z * k, sw=0.45, rx=0.6)
    s.line(GX(t.out_x), GZ(t.lid_under), GX(0), GZ(t.lid_under), sw=0.25)
    s.rect(GX(ux + mp.USB_OPEN_W / 2), GZ(t.lid_under), mp.USB_OPEN_W * k, (t.lid_under - (uz - mp.USB_OPEN_H / 2)) * k, sw=0.35)
    s.dim(GX(t.out_x), GZ(0), GX(0), GZ(0), f"{t.out_x:.2f}", off=5)
    s.dim(GX(0), GZ(0), GX(0), GZ(uz - mp.USB_OPEN_H / 2), f"{uz - mp.USB_OPEN_H / 2:.2f}", off=4)
    s.text(GX(ux), GZ(uz) + 0.8, f"{mp.USB_OPEN_W} wide, U-notch", 1.8, "middle")

    # ---- cap detail ----
    cx0, cy0 = 26, 178
    s.text(cx0 - 4, cy0 - 4, "BUTTON CAP (print 2)  3:1", 2.3, weight="bold")
    kk = 3.0
    bh, sh = t.cap_big_h, t.cap_stem_h
    s.rect(cx0, cy0 + sh * kk, mp.CAP_BIG_D * kk, bh * kk, fill="#f2e6b8", sw=0.3)
    s.rect(cx0 + (mp.CAP_BIG_D - mp.CAP_STEM_D) / 2 * kk, cy0, mp.CAP_STEM_D * kk, sh * kk, fill="#f2e6b8", sw=0.3)
    s.text(cx0 + mp.CAP_BIG_D * kk + 2, cy0 + sh * kk / 2, f"Ø{mp.CAP_STEM_D} x {sh:.1f}", 1.9)
    s.text(cx0 + mp.CAP_BIG_D * kk + 2, cy0 + sh * kk + bh * kk / 2, f"Ø{mp.CAP_BIG_D} x {bh:.1f}", 1.9)

    notes_block(s, 70, 160, [
        "Print: PLA or PETG, 0.2 mm layers, 3 perimeters, 20 % infill, no supports.",
        "Base: open side up. Lid: plate on the bed (lip and posts up). Caps: wide end down.",
        f"Lid is a press fit (lip clearance 0.15 mm); tune `lip_clr` for your printer.",
        "Board rests on four corner supports and is clamped by four lid posts (corner zones).",
        "Cell (502030) sits under the board on foam tape between two ribs.",
        f"Fit D1 with its flange {t.led_standoff:.1f} mm above the board so the dome is flush.",
        "Mark ON/OFF beside PWR after checking SW1 with a meter (direction is part-specific).",
        "! Check the USB-C opening against your cable's overmould before printing a batch.",
    ])
    title(s, 200, 168, 85, 34, "T1 enclosure", "2:1 (elevations 1.5:1, cap 3:1)")
    s.save(path)


def f1p_drawing(path):
    f = mp.F1p()
    s = Svg(297, 210)
    s.frame()
    s.text(12, 15.5, "Trillium F1p body (3D printed): shell, bottom plate, button caps", 4.6, weight="bold")
    s.text(12, 20.5, f"Source: f1/f1p-body.scad (parametric). Outside {f.out_l:.1f} x {f.out_w:.1f} x {f.out_z:.1f} mm. "
           f"Visible sensor length {f.vis_len:.1f} mm (tail allowance {f.tail_len} mm: measure).", 2.2, fill=GREY)
    k = 1.0
    ox, oy = 22, 50
    s.text(ox, 30, "TOP VIEW (internals dashed)  1:1", 2.3, weight="bold")

    def TX(x):          # inner X -> sheet
        return ox + (x + f.wall) * k

    def TY(y):          # inner Y (centred, +Y up) -> sheet
        return oy + (f.out_w / 2 - y) * k
    s.rect(TX(-f.wall), TY(f.out_w / 2), f.out_l * k, f.out_w * k, sw=0.45, rx=f.corner_r * k)
    s.rect(TX(0), TY(f.in_w / 2), f.in_l * k, f.in_w * k, stroke=GREY, sw=0.2, dash=HIDDEN)
    # channel + slot
    cw = hw.TRILL_SENSOR_W + 0.8
    s.rect(TX(f.ch_x0), TY(cw / 2), (f.ch_x1 - f.ch_x0) * k, cw * k, fill="#f6ecd0", stroke=INK, sw=0.25)
    s.rect(TX(f.slot_x), TY(11.5), f.slot_w * k, 23 * k, fill="#555555", stroke=INK, sw=0.2)
    s.text(TX((f.ch_x0 + f.ch_x1) / 2), TY(0) + 0.8, f"sensor channel {f.ch_x1 - f.ch_x0:.1f} x {cw:.1f}, 0.4 deep", 2.0, "middle")
    # internals
    s.rect(TX(f.X(0)), TY(f.Y(hw.BOARD_W)), hw.BOARD_L * k, hw.BOARD_W * k, stroke=GREY, sw=0.2, dash=HIDDEN)
    s.rect(TX(f.base_x0), TY(hw.TRILL_BASE[1] / 2), hw.TRILL_BASE[0] * k, hw.TRILL_BASE[1] * k, stroke=BLUE, sw=0.2, dash=HIDDEN)
    s.text(TX(f.base_x0 + 18), TY(-hw.TRILL_BASE[1] / 2) + 3.0, "Trill base", 1.7, "middle", fill=BLUE)
    c = hw.CELL_F1
    s.rect(TX(f.batt_x0), TY(c[1] / 2), c[2] * k, c[1] * k, stroke=BLUE, sw=0.2, dash=HIDDEN)
    s.text(TX(f.batt_x0 + c[2] / 2), TY(-c[1] / 2) + 3.0, "cell 503035", 1.7, "middle", fill=BLUE)
    for bx in f.boss_x:
        for sgn in (-1, 1):
            s.circle(TX(bx), TY(sgn * f.boss_y), 3.5 * k, stroke=GREY, sw=0.2, dash=HIDDEN)
    led = (f.X(mp.LED_B[1]), f.Y(mp.LED_B[0]))
    s.circle(TX(led[0]), TY(led[1]), mp.LED_HOLE_D / 2 * k, sw=0.35)
    btns = [(f.X(b[1]), f.Y(b[0])) for b in (mp.SW2_B, mp.SW3_B)]
    for (bx, by), nm in zip(btns, "AB"):
        s.circle(TX(bx), TY(by), mp.BTN_HOLE_D / 2 * k, sw=0.35)
        s.text(TX(bx + 5.6), TY(by) + 0.9, nm, 2.4, "middle", "bold", fill=GREY)
    s.text(TX(11.5), TY(f.Y(hw.XIAO_CX)) + 1.0, "TRILLIUM", 3.0, "middle", "bold", fill=GREY)
    uy = f.Y(hw.XIAO_CX)
    s.line(TX(-f.wall) - 0.1, TY(uy + mp.USB_OPEN_W / 2), TX(-f.wall) - 0.1, TY(uy - mp.USB_OPEN_W / 2), ACCENT, 0.8)
    s.text(TX(-f.wall) - 1.2, TY(uy) + 0.7, "USB-C", 1.8, "end", fill=ACCENT)
    sx = f.X(mp.SW1_B_Y)
    s.line(TX(sx - 3), TY(f.out_w / 2) - 0.1, TX(sx + 3), TY(f.out_w / 2) - 0.1, ACCENT, 0.8)
    s.text(TX(sx), TY(f.out_w / 2) - 1.4, "SW1", 1.8, "middle", fill=ACCENT)
    s.dim(TX(-f.wall), TY(-f.out_w / 2), TX(f.in_l + f.wall), TY(-f.out_w / 2), f"{f.out_l:.1f}", off=5)
    s.dim(TX(f.in_l + f.wall), TY(-f.out_w / 2), TX(f.in_l + f.wall), TY(f.out_w / 2), f"{f.out_w:.1f}", off=5)
    s.dim(TX(-f.wall), TY(f.out_w / 2), TX(led[0]), TY(f.out_w / 2), f"{led[0] + f.wall:.1f} LED", off=-4.5)
    s.dim(TX(-f.wall), TY(f.out_w / 2), TX(btns[0][0]), TY(f.out_w / 2), f"{btns[0][0] + f.wall:.1f} buttons", off=-8.5)
    s.dim(TX(-f.wall), TY(f.out_w / 2), TX(f.slot_x), TY(f.out_w / 2), f"{f.slot_x + f.wall:.1f} tail slot", off=-12.5)

    # ---- longitudinal section ----
    sx0, sy0 = 22, 104
    s.text(sx0, sy0 - 6, "SECTION B-B (along the centre line)  1:1, heights 2.5:1", 2.3, weight="bold")
    kz = 2.5

    def SX(x):
        return sx0 + (x + f.wall) * k

    def SZ(z):
        return sy0 + (f.out_z - z) * kz
    s.rect(SX(-f.wall), SZ(f.out_z), f.out_l * k, f.top * kz, fill="#c9d6e8", sw=0.3)
    s.rect(SX(-f.wall), SZ(f.out_z), f.wall * k, f.out_z * kz, fill="#c9d6e8", sw=0.3)
    s.rect(SX(f.in_l), SZ(f.out_z), f.wall * k, f.out_z * kz, fill="#c9d6e8", sw=0.3)
    s.rect(SX(0.2), SZ(f.plate), (f.in_l - 0.4) * k, f.plate * kz, fill="#dcdcdc", sw=0.3)
    s.rect(SX(f.slot_x), SZ(f.out_z), f.slot_w * k, f.top * kz, fill="white", stroke="none")
    s.rect(SX(f.X(0)), SZ(f.board_top), hw.BOARD_L * k, hw.BOARD_T * kz, fill="#9fc79f", sw=0.25)
    s.text(SX(f.X(hw.BOARD_L / 2)), SZ(f.board_top) - 1.0, "core board", 1.7, "middle")
    s.rect(SX(f.base_x0), SZ(f.plate + 1 + 1.6), hw.TRILL_BASE[0] * k, 1.6 * kz, fill="#5d8f6a", sw=0.25)
    s.text(SX(f.base_x0 + 18), SZ(f.plate + 4.5), "Trill base (foam tape)", 1.7, "middle")
    s.rect(SX(f.batt_x0), SZ(f.plate + c[0]), c[2] * k, c[0] * kz, fill="#f0e6c8", sw=0.25)
    s.text(SX(f.batt_x0 + c[2] / 2), SZ(f.plate + c[0] / 2) + 0.8, "cell", 1.7, "middle")
    # sensor strip on top + tail S-bend
    s.line(SX(f.slot_x + f.slot_w), SZ(f.out_z - 0.2), SX(f.ch_x1 - 1.0), SZ(f.out_z - 0.2), "#d4880f", 0.9)
    tz = f.plate + 1 + 1.6 + 0.8
    s.path(f"M {SX(f.slot_x + 1.25):.2f} {SZ(f.out_z):.2f} L {SX(f.slot_x + 1.25):.2f} {SZ(tz + 2.5):.2f} "
           f"Q {SX(f.slot_x + 1.25):.2f} {SZ(tz):.2f} {SX(f.slot_x + 4):.2f} {SZ(tz):.2f} L {SX(f.base_x0 + 2):.2f} {SZ(tz):.2f}",
           stroke="#d4880f", sw=0.9)
    s.text(SX(f.slot_x + 9), SZ(f.out_z) - 1.2, "sensor tail through slot to FFC", 1.7, fill="#a0640a")
    for zz, lab in ((f.plate, f"{f.plate}"), (f.board_top, f"{f.board_top:.1f}"), (f.top_under, f"{f.top_under:.1f}"), (f.out_z, f"{f.out_z:.1f}")):
        s.line(SX(f.in_l + f.wall) + 1, SZ(zz), SX(f.in_l + f.wall) + 4, SZ(zz), GREY, 0.15)
        s.text(SX(f.in_l + f.wall) + 5, SZ(zz) + 0.7, lab, 1.8)

    # ---- end view (USB) ----
    ex0, ey0 = 234, 104
    kk = 1.5
    s.text(ex0, ey0 - 6, "END (USB-C)  1.5:1", 2.3, weight="bold")

    def EX(y):      # viewed from -X: right = -Y
        return ex0 + (f.out_w / 2 - y) * kk

    def EZ(z):
        return ey0 + (f.out_z - z) * kk
    s.rect(EX(f.out_w / 2), EZ(f.out_z), f.out_w * kk, f.out_z * kk, sw=0.45, rx=0.8)
    uz = f.board_top + hw.USB_Z_ABOVE_BOARD
    s.rect(EX(uy + mp.USB_OPEN_W / 2), EZ(uz + mp.USB_OPEN_H / 2), mp.USB_OPEN_W * kk, mp.USB_OPEN_H * kk, sw=0.35, rx=1)
    s.dim(EX(f.out_w / 2), EZ(0), EX(-f.out_w / 2), EZ(0), f"{f.out_w:.1f}", off=5)
    s.dim(EX(-f.out_w / 2), EZ(0), EX(-f.out_w / 2), EZ(f.out_z), f"{f.out_z:.1f}", off=4)
    s.dim(EX(f.out_w / 2), EZ(0), EX(f.out_w / 2), EZ(uz), f"{uz:.1f}", off=-4)

    notes_block(s, 14, 160, [
        "Shell prints top-surface down (no supports: the USB opening bridges 12.5 mm). Plate prints flat.",
        "PLA or PETG, 0.2 mm layers, 3-4 perimeters, 20-25 % infill. Caps: as T1 (same part).",
        "Fit four M3 heat-set inserts in the bosses (pilot Ø4.0 x 5.5). Plate: tongue into the USB-end wall slot first,",
        "then four M3 x 6 countersunk screws from below.",
        "Board: on four plate posts, located by lips; clamped by four shell posts. Same corner zones as T1.",
        f"Sensor: dry-fit the tail through the slot into the Trill FFC, then set `tail_len` so the strip ends",
        f"{f.end_margin} mm short of the far wall. Stick the strip into the 0.4 mm channel with its own adhesive or thin tape.",
        "Trill base and cell: double-sided foam tape inside the printed locators.",
        "! Cable W1 (Qwiic) runs along the -Y side, past the Trill base, to J2 at the board's inner edge.",
        "! Capacitive sensing is affected by fingers near the tail and FFC: keep the slot end free of metal.",
    ], size=1.9, step=3.3)
    title(s, 200, 160, 85, 42, "F1p body", "1:1 (end view 1.5:1)")
    s.save(path)


def f1w_drawing(path):
    layers, w = f1w_layers(kerf=0.0)
    s = Svg(420, 297)
    s.frame(8)
    s.text(16, 20, "Trillium F1w body (laser-cut birch plywood, layered and bolted)", 5.4, weight="bold")
    s.text(16, 26, f"Source: f1/f1w-sheet-3mm.svg + f1w-sheet-1.5mm.svg (generated, kerf {w.kerf} mm). Outside "
           f"{w.out_l:.1f} x {w.out_w:.1f} x {w.out_z:.1f} mm. Visible sensor length {w.vis_len:.1f} mm.", 2.4, fill=GREY)
    # layer plans, 2 columns
    k = 0.8
    order = ["TOP", "L6", "L5", "L4", "L3", "L2", "L1", "L0"]
    info = {
        "TOP": "3 mm. Engraved sensor pocket + labels; LED, button, tail-slot holes",
        "L6": "3 mm frame", "L5": "3 mm frame, USB opening", "L4": "3 mm frame, USB opening",
        "L3": "3 mm. Board retainer tabs, SW1 slot (wall thinned to 2 mm), USB opening",
        "L2": "1.5 mm. Board pocket (locates the board)",
        "L1": "3 mm. Board support tabs, M3 nut traps",
        "L0": "3 mm bottom plate",
    }
    for i, n in enumerate(order):
        col, row = i // 4, i % 4
        x0 = 16 + col * 200
        y0 = 34 + row * 47
        sub = Svg(1, 1)
        _emit_layer(sub, layers[n], 0, 0, w.out_w, cut=INK, engrave="#cbb88a", sw=0.18, preview=True)
        s.raw(f'<g transform="translate({x0},{y0 + 6}) scale({k})">' + "\n".join(sub.items) + "</g>")
        z0, z1 = w.z[n]
        s.text(x0, y0 + 3.5, f"{n}   z {z0:.1f}-{z1:.1f}", 2.6, weight="bold")
        s.text(x0 + 38, y0 + 3.5, info[n], 2.0, fill=GREY)
    # section
    sx0, sy0 = 16, 281
    kz = 2.0
    kx = 0.8
    s.text(sx0, sy0 - 52, "SECTION C-C (centre line, Y = 0)  0.8:1, heights 2:1", 2.6, weight="bold")
    ycut = 0.0 + w.out_w / 2
    xs = [i * 0.25 for i in range(int(w.out_l / 0.25) + 1)]
    for n in order:
        reg = layers[n]["region"]
        z0, z1 = w.z[n]
        run = None
        for x in xs + [None]:
            solid = x is not None and reg.inside(x, ycut)
            if n == "TOP" and x is not None and w.wall + w.slot_x < x < w.wall + w.slot_x + w.slot_w:
                solid = False
            if solid and run is None:
                run = x
            if not solid and run is not None:
                end = x if x is not None else w.out_l
                s.rect(sx0 + run * kx, sy0 - z1 * kz, (end - run) * kx, (z1 - z0) * kz,
                       fill="#e8d6ad" if n != "L2" else "#d9c493", stroke=INK, sw=0.15)
                run = None
        s.text(sx0 + w.out_l * kx + 3, sy0 - (z0 + z1) / 2 * kz + 0.8, f"{n}", 1.9)
    bt = w.board_top
    s.rect(sx0 + (w.wall + w.X(0)) * kx, sy0 - bt * kz, hw.BOARD_L * kx, hw.BOARD_T * kz, fill="#9fc79f", stroke=INK, sw=0.2)
    c = hw.CELL_F1
    s.rect(sx0 + (w.wall + w.batt_x0) * kx, sy0 - (w.t + c[0]) * kz, c[2] * kx, c[0] * kz, fill="#f0e6c8", stroke=INK, sw=0.2)
    s.rect(sx0 + (w.wall + w.base_x0) * kx, sy0 - (w.t + 2.6) * kz, hw.TRILL_BASE[0] * kx, 1.6 * kz, fill="#5d8f6a", stroke=INK, sw=0.2)
    s.line(sx0 + (w.wall + w.slot_x + w.slot_w) * kx, sy0 - w.out_z * kz - 0.4, sx0 + (w.wall + w.ch_x1 - 1) * kx,
           sy0 - w.out_z * kz - 0.4, "#d4880f", 0.8)
    for zz in (w.board_top, w.top_under, w.out_z):
        s.text(sx0 - 1.5, sy0 - zz * kz + 0.7, f"{zz:.1f}", 1.7, "end", fill=GREY)
    # right column notes
    notes_block(s, 222, 226, [
        "Cut: red hairlines. Engrave: black fill (sensor pocket ~0.3-0.5 mm deep, labels, hidden layer IDs).",
        "Layer IDs are engraved on the -Y wall face near the USB end: stack all IDs on the same corner.",
        "Assembly (bottom up): L0, L1 + 8 M3 nuts, board onto L1 tabs, L2 around it, L3 ... L6, TOP.",
        "8 x M3 x 20 button-head screws from the top into the nuts. No glue in the stack (serviceable).",
        f"LED flange {w.led_standoff:.1f} mm above the board. Buttons: laminated plungers (glue discs:",
        "2 x Ø7 3 mm + 1 x Ø7 1.5 mm, then Ø4.6 3 mm + Ø4.6 1.5 mm), or the printed T1 cap.",
        "! Seal or oil the wood away from the sensor pocket; moisture shifts capacitive baselines.",
        "! Test-cut a nut trap and the board pocket first; adjust `kerf` in mech_params.py.",
    ], size=2.0, step=3.2)
    title(s, 222, 254, 110, 32, "F1w body", "0.8:1 (section heights 2:1)")
    s.save(path)


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    t1_drawing(f"{out}/t1-enclosure-drawing.svg")
    f1p_drawing(f"{out}/f1p-body-drawing.svg")
    f1w_drawing(f"{out}/f1w-body-drawing.svg")
    print(f1w_sheets(out))
