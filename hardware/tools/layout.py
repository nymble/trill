"""Perfboard placement + underside wiring drawing and wiring list, from hw_model."""

from __future__ import annotations

import hw_model as hw
from svgkit import Svg, INK, GREY, LIGHT, ACCENT, BLUE

COLS = "ABCDEFGHIJK"
NET_COLORS = {
    "GND": "#222222", "+3V3": "#c0392b", "VBAT": "#e67e22", "VBAT_SW": "#d35400",
    "SDA": "#2471a3", "SCL": "#7d3c98", "TRILL_EVT": "#117a65", "AUX_C": "#16a085",
    "BTN_A": "#1e8449", "BTN_B": "#27ae60", "BTN_D": "#52be80",
    "LED_R_DRV": "#a93226", "LED_G_DRV": "#229954", "LED_B_DRV": "#2e86c1",
    "LED_R": "#cd6155", "LED_G": "#58d68d", "LED_B": "#5dade2",
}


def hole_name(h) -> str:
    c, r = h
    return f"{COLS[c]}{r + 1}"


def board_points(model: str):
    """net -> list of (ref.pin, hole) for pins that land in board holes."""
    pts: dict[str, list] = {}
    for p in hw.parts_for(model):
        for pin, net in p.pins.items():
            h = p.holes.get(pin)
            if h is None or net.startswith("NC") or net.startswith("TP"):
                continue
            pts.setdefault(net, []).append((f"{p.ref}.{pin}", h))
    return pts


def wiring(model: str):
    """Minimum spanning tree per net (Manhattan), in a stable order."""
    rows = []
    for net, pts in board_points(model).items():
        if len(pts) < 2:
            continue
        done = [pts[0]]
        todo = pts[1:]
        while todo:
            best = None
            for a in done:
                for b in todo:
                    d = abs(a[1][0] - b[1][0]) + abs(a[1][1] - b[1][1])
                    if best is None or d < best[0]:
                        best = (d, a, b)
            _, a, b = best
            rows.append((net, a, b))
            done.append(b)
            todo.remove(b)
    # off-board / flying connections
    rows.append(("VBAT_SW", ("U1.BAT+", "pad"), ("SW1.2", (9, 10))))
    return rows


def draw(model: str) -> Svg:
    s = Svg(297, 210)
    s.frame()
    s.text(12, 15.5, f"Trillium {model}: perfboard layout and wiring", 4.6, weight="bold")
    s.text(12, 20.5, "2.54 mm perfboard, 11 x 18 holes (27.94 x 45.72 mm), scale 3:1. Holes named column letter + row number "
           "(A1 = top-left, component side, USB-C at top).", 2.1, fill=GREY)
    k = 3.0
    fitted = {p.ref for p in hw.parts_for(model)}

    def view(ox, oy, mirror, title):
        s.text(ox, oy - 10, title, 2.6, weight="bold")
        W, L = hw.BOARD_W * k, hw.BOARD_L * k

        def X(x):
            return ox + ((hw.BOARD_W - x) if mirror else x) * k

        def Y(y):
            return oy + y * k

        s.rect(ox, oy, W, L, stroke=INK, sw=0.4, fill="#f6f1e4")
        # corner zones
        for c, r0, r1 in hw.CORNER_ZONES:
            x0 = c * hw.PITCH
            xa, xb = sorted((X(x0), X(x0 + hw.PITCH)))
            s.rect(xa, Y(r0 * hw.PITCH), xb - xa, (r1 - r0 + 1) * hw.PITCH * k, stroke="none", fill="#e3d9bf")
        for c in range(hw.BOARD_COLS):
            s.text(X(hw.hole_xy(c, 0)[0]), oy - 1.2, COLS[c], 1.6, "middle", fill=GREY)
        for r in range(hw.BOARD_ROWS):
            s.text(ox - 1.4 if not mirror else ox - 1.4, Y(hw.hole_xy(0, r)[1]) + 0.6, str(r + 1), 1.5, "end", fill=GREY)
        for c in range(hw.BOARD_COLS):
            for r in range(hw.BOARD_ROWS):
                x, y = hw.hole_xy(c, r)
                s.circle(X(x), Y(y), 0.55, stroke="#b8a77a", sw=0.15, fill="white")
        return X, Y

    # ---------------- component side ----------------
    ox, oy = 18, 42
    X, Y = view(ox, oy, False, "A. Component side (top view)")
    for item in hw.body_outlines(model):
        kind, ref = item[0], item[1]
        base = ref.replace("cap", "").replace("act", "")
        if base in ("USB",):
            base = "U1"
        col = INK if base in fitted or base == "U1" else GREY
        if kind == "rect":
            _, _, x, y, w, h = item
            fill = "none"
            dash = None
            if ref == "U1":
                fill = "rgba(60,60,60,0.06)"
            if ref == "USB":
                fill = "rgba(60,60,60,0.25)"
            if ref == "SW1act":
                fill = "rgba(60,60,60,0.35)"
            s.rect(X(x), Y(y), w * k, h * k, stroke=col, sw=0.3, fill=fill, dash=dash)
        elif kind == "circle":
            _, _, x, y, r = item
            s.circle(X(x), Y(y), r * k, stroke=col, sw=0.3)
        elif kind == "resistor":
            _, _, x, y, span = item
            col = INK if ref in fitted else GREY
            dash = None if ref in fitted else "0.8,0.6"
            s.line(X(x - span / 2), Y(y), X(x + span / 2), Y(y), col, 0.3)
            s.rect(X(x - 1.7), Y(y - 0.9), 3.4 * k, 1.8 * k, stroke=col, sw=0.3, fill="white", rx=1, dash=dash)
            s.text(X(x), Y(y) + 0.7, ref, 1.8, "middle", "bold", fill=col)
    # labels and pin dots
    for p in hw.PARTS:
        col = INK if p.ref in fitted else GREY
        for pin, h in list(p.holes.items()) + [("m", h) for h in p.mech_holes]:
            if not h:
                continue
            x, y = hw.hole_xy(*h)
            s.circle(X(x), Y(y), 0.75, stroke="none", fill=col if p.ref in fitted else "#c8c8c8")
    labels = {
        "U1": (hw.XIAO_CX, 9.0, "U1 XIAO nRF52840 Sense"),
        "D1": (hw.hole_xy(4.5, 11)[0], hw.hole_xy(0, 12)[1] + 1.5, "D1"),
        "SW2": (hw.hole_xy(1.5, 0)[0], hw.hole_xy(0, 14)[1] + 0.3, "SW2 A"),
        "SW3": (hw.hole_xy(8.5, 0)[0], hw.hole_xy(0, 14)[1] + 0.3, "SW3 B"),
        "SW1": (hw.hole_xy(8.2, 0)[0], hw.hole_xy(0, 12.4)[1], "SW1"),
        "J1": (hw.hole_xy(1.5, 0)[0], hw.hole_xy(0, 17)[1] + 0.7, "J1 + -"),
        "J2": (hw.hole_xy(5, 0)[0], hw.hole_xy(0, 17)[1] + 2.3, "J2  1 . . . 5"),
        "J3": (hw.hole_xy(5, 0)[0], hw.hole_xy(0, 14)[1] - 1.6, "J3"),
        "JP1": (hw.hole_xy(6.5, 0)[0], hw.hole_xy(0, 16)[1] - 1.5, "JP1"),
    }
    for ref, (x, y, t) in labels.items():
        col = INK if ref in fitted or ref == "U1" else GREY
        s.text(X(x), Y(y), t, 2.0, "middle", "bold", fill=col)
    s.text(X(hw.XIAO_CX), Y(-3.4), "USB-C", 1.8, "middle", fill=GREY)
    s.text(X(hw.BOARD_W) + 1.5, Y(hw.hole_xy(0, 10)[1]) + 0.6, "actuator", 1.6, fill=GREY)
    # XIAO pin names
    for pin in hw.PIN_MAP:
        x, y = hw.hole_xy(pin.col, pin.row)
        dx = 2.4 if pin.col == hw.XIAO_LEFT_COL else -2.4
        s.text(X(x) + dx, Y(y) + 0.6, pin.name, 1.5, "start" if dx > 0 else "end", fill=BLUE)
    s.text(ox, oy + hw.BOARD_L * k + 5, "Shaded corners: keep free (enclosure supports and clamps).", 1.8, fill=GREY)
    s.text(ox, oy + hw.BOARD_L * k + 8, "Grey: F1-only parts (not fitted on T1)." if model == "T1"
           else "JP1 and J3 are optional; see schematic.", 1.8, fill=GREY)

    # ---------------- underside ----------------
    ox2 = 118
    X2, Y2 = view(ox2, oy, True, "B. Wiring side (underside, mirrored)")
    rows = wiring(model)
    for net, a, b in rows:
        if a[1] == "pad":
            continue
        col = NET_COLORS.get(net, INK)
        (c1, r1), (c2, r2) = a[1], b[1]
        x1, y1 = hw.hole_xy(c1, r1)
        x2, y2 = hw.hole_xy(c2, r2)
        # route: vertical first along the source column, then horizontal
        s.line(X2(x1), Y2(y1), X2(x2), Y2(y2), col, 0.6)
    for p in hw.parts_for(model):
        for pin, h in list(p.holes.items()) + [("m", h) for h in p.mech_holes]:
            if not h:
                continue
            x, y = hw.hole_xy(*h)
            s.circle(X2(x), Y2(y), 0.8, stroke=INK, sw=0.2, fill="#c9c9c9")
    # flying lead
    bx, by = hw.hole_xy(9, 10)
    s.circle(X2(hw.XIAO_CX), Y2(9.0), 1.2, stroke=ACCENT, sw=0.3, dash="0.6,0.4")
    s.path(f"M {X2(bx):.2f} {Y2(by):.2f} C {X2(bx):.2f} {Y2(by)-12:.2f} {X2(hw.XIAO_CX)+6:.2f} {Y2(9.0)+10:.2f} "
           f"{X2(hw.XIAO_CX):.2f} {Y2(9.0)+1.2:.2f}", stroke=NET_COLORS["VBAT_SW"], sw=0.55)
    s.text(X2(hw.XIAO_CX), Y2(9.0) - 2.0, "to U1 BAT+ pad (flying lead,", 1.6, "middle", fill=ACCENT)
    s.text(X2(hw.XIAO_CX), Y2(9.0) + 4.4 - 6.4 + 7.8, "fit before U1)", 1.6, "middle", fill=ACCENT)
    s.text(ox2, oy + hw.BOARD_L * k + 5, "Use 28-30 AWG insulated solid wire. Trim leads to <= 1 mm under the board", 1.8, fill=GREY)
    s.text(ox2, oy + hw.BOARD_L * k + 8, "(T1: the cell sits below). Straight lines = point-to-point insulated wires.", 1.8, fill=GREY)

    # ---------------- wiring list ----------------
    tx, ty = 212, 30
    s.text(tx, ty, "C. Wiring list", 2.6, weight="bold")
    s.text(tx + 3, ty + 3.6, "Net", 1.8, fill=GREY)
    s.text(tx + 19, ty + 3.6, "From", 1.8, fill=GREY)
    s.text(tx + 44, ty + 3.6, "To", 1.8, fill=GREY)
    yy = ty + 7.4
    for i, (net, a, b) in enumerate(rows):
        fa = a[0] + (f" {hole_name(a[1])}" if a[1] != "pad" else " (pad)")
        fb = b[0] + f" {hole_name(b[1])}"
        s.rect(tx, yy - 2.2, 2.0, 2.0, stroke="none", fill=NET_COLORS.get(net, INK))
        s.text(tx + 3, yy - 0.4, net, 1.7)
        s.text(tx + 19, yy - 0.4, fa, 1.7)
        s.text(tx + 44, yy - 0.4, fb, 1.7)
        yy += 3.15
    yy += 2
    extra = [
        "Off-board: BT1 cell plugs into J1 (red = J1.1 '+').",
        "U1.BAT- is common with GND inside U1: no wire.",
        "SW2/SW3 extra pins: solder for strength only.",
    ]
    if model == "F1":
        extra.append("J2: cut Qwiic cable; black 1, red 2, blue 3, yellow 4.")
    for t in extra:
        s.text(tx, yy, t, 1.7, fill=GREY)
        yy += 2.9
    return s


def wiring_table_md(model: str) -> str:
    out = ["| # | Net | From | To |", "|---|---|---|---|"]
    for i, (net, a, b) in enumerate(wiring(model), 1):
        fa = f"{a[0]} ({hole_name(a[1])})" if a[1] != "pad" else f"{a[0]} (underside pad)"
        out.append(f"| {i} | `{net}` | {fa} | {b[0]} ({hole_name(b[1])}) |")
    return "\n".join(out)


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    for m in ("T1", "F1"):
        draw(m).save(f"{out}/{m.lower()}-layout.svg")
    print(wiring_table_md("F1"))
