"""Minimal SVG drawing helpers (millimetre units) for Trillium drawings."""

from __future__ import annotations

import math
from xml.sax.saxutils import escape

FONT = "Helvetica, Arial, sans-serif"
INK = "#1a1a1a"
GREY = "#8a8a8a"
LIGHT = "#d9d9d9"
ACCENT = "#b0362b"     # used sparingly: polarity, warnings
BLUE = "#2a5d9f"


class Svg:
    def __init__(self, w: float, h: float):
        self.w, self.h = w, h
        self.items: list[str] = []
        self.bg = True

    # primitives -------------------------------------------------------
    def line(self, x1, y1, x2, y2, stroke=INK, sw=0.25, dash=None, cap="round"):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.items.append(
            f'<line x1="{x1:.3f}" y1="{y1:.3f}" x2="{x2:.3f}" y2="{y2:.3f}" '
            f'stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}"{d}/>')

    def poly(self, pts, stroke=INK, sw=0.25, fill="none", close=False, dash=None):
        p = " ".join(f"{x:.3f},{y:.3f}" for x, y in pts)
        tag = "polygon" if close else "polyline"
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.items.append(f'<{tag} points="{p}" stroke="{stroke}" stroke-width="{sw}" '
                          f'fill="{fill}" stroke-linejoin="round"{d}/>')

    def rect(self, x, y, w, h, stroke=INK, sw=0.25, fill="none", rx=0, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.items.append(f'<rect x="{x:.3f}" y="{y:.3f}" width="{w:.3f}" height="{h:.3f}" rx="{rx}" '
                          f'stroke="{stroke}" stroke-width="{sw}" fill="{fill}"{d}/>')

    def circle(self, cx, cy, r, stroke=INK, sw=0.25, fill="none", dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.items.append(f'<circle cx="{cx:.3f}" cy="{cy:.3f}" r="{r:.3f}" stroke="{stroke}" '
                          f'stroke-width="{sw}" fill="{fill}"{d}/>')

    def path(self, d, stroke=INK, sw=0.25, fill="none"):
        self.items.append(f'<path d="{d}" stroke="{stroke}" stroke-width="{sw}" fill="{fill}"/>')

    def text(self, x, y, s, size=2.2, anchor="start", weight="normal", fill=INK, rot=0,
             style="normal", baseline="auto"):
        t = f' transform="rotate({rot} {x:.3f} {y:.3f})"' if rot else ""
        self.items.append(
            f'<text x="{x:.3f}" y="{y:.3f}" font-family="{FONT}" font-size="{size}" '
            f'text-anchor="{anchor}" font-weight="{weight}" font-style="{style}" fill="{fill}" '
            f'dominant-baseline="{baseline}"{t}>{escape(str(s))}</text>')

    def dot(self, x, y, r=0.45, fill=INK):
        self.circle(x, y, r, stroke="none", fill=fill)

    def raw(self, s):
        self.items.append(s)

    # composite --------------------------------------------------------
    def arrow(self, x1, y1, x2, y2, stroke=INK, sw=0.2, head=1.2):
        self.line(x1, y1, x2, y2, stroke, sw)
        a = math.atan2(y2 - y1, x2 - x1)
        for s in (+1, -1):
            self.line(x2, y2, x2 - head * math.cos(a + s * 0.4), y2 - head * math.sin(a + s * 0.4), stroke, sw)

    def dim(self, x1, y1, x2, y2, label, off=4.0, size=2.0, stroke=GREY, ext=True):
        """Aligned dimension between two points, offset perpendicular by `off`."""
        a = math.atan2(y2 - y1, x2 - x1)
        nx, ny = -math.sin(a), math.cos(a)
        p1 = (x1 + nx * off, y1 + ny * off)
        p2 = (x2 + nx * off, y2 + ny * off)
        if ext:
            self.line(x1 + nx * 0.6 * math.copysign(1, off), y1 + ny * 0.6 * math.copysign(1, off),
                      p1[0] + nx * 0.8 * math.copysign(1, off), p1[1] + ny * 0.8 * math.copysign(1, off), stroke, 0.15)
            self.line(x2 + nx * 0.6 * math.copysign(1, off), y2 + ny * 0.6 * math.copysign(1, off),
                      p2[0] + nx * 0.8 * math.copysign(1, off), p2[1] + ny * 0.8 * math.copysign(1, off), stroke, 0.15)
        self.arrow((p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2, *p1, stroke, 0.18, 1.0)
        self.arrow((p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2, *p2, stroke, 0.18, 1.0)
        mx, my = (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2
        deg = math.degrees(a)
        if deg > 90 or deg <= -90:
            deg += 180
        tx, ty = mx + nx * 0.9 * math.copysign(1, off), my + ny * 0.9 * math.copysign(1, off)
        self.text(tx, ty, label, size, "middle", rot=deg, fill=INK, baseline="middle")

    def title_block(self, x, y, w, h, rows: list[tuple[str, str]], title: str):
        self.rect(x, y, w, h, sw=0.35)
        self.text(x + 2, y + 5.2, title, 3.6, weight="bold")
        rh = (h - 8) / len(rows)
        for i, (k, v) in enumerate(rows):
            yy = y + 8 + i * rh
            self.line(x, yy, x + w, yy, sw=0.2)
            self.text(x + 2, yy + rh * 0.68, k, 1.8, fill=GREY)
            self.text(x + 22, yy + rh * 0.68, v, 2.1)

    def frame(self, margin=6):
        self.rect(margin, margin, self.w - 2 * margin, self.h - 2 * margin, sw=0.4)

    def to_string(self) -> str:
        body = "\n".join(self.items)
        return (f'<?xml version="1.0" encoding="UTF-8"?>\n'
                f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}mm" height="{self.h}mm" '
                f'viewBox="0 0 {self.w} {self.h}">\n'
                + (f'<rect width="{self.w}" height="{self.h}" fill="white"/>\n' if self.bg else "")
                + f'{body}\n</svg>\n')

    def save(self, path):
        with open(path, "w") as f:
            f.write(self.to_string())
