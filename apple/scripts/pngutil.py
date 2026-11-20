#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Flatten App Store screenshots to opaque sRGB RGB and reject blank frames."""
from __future__ import annotations

import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Color.Trillium.black (brand/tokens/TrilliumColors.swift): 0.047, 0.047, 0.051.
STAGE_BLACK = (12, 12, 13)
NEAR_BLACK_LUMA = 8.0
BLANK_MEAN = 8.0
BLANK_NEAR_FRAC = 0.99
# Mac shots must fill the 16:10 canvas; a clipped window sits in a short strip.
MAC_MIN_FILL = 0.85


@dataclass
class PngStats:
    width: int
    height: int
    color_type: int  # IHDR: 2 = RGB, 6 = RGBA
    mean: float
    variance: float
    near_black_frac: float
    content_width_frac: float
    content_height_frac: float
    has_alpha: bool

    @property
    def is_blank(self) -> bool:
        return self.mean < BLANK_MEAN or (
            self.near_black_frac > BLANK_NEAR_FRAC and self.mean < 12.0
        )

    @property
    def is_unfilled(self) -> bool:
        return (
            self.content_width_frac < MAC_MIN_FILL
            or self.content_height_frac < MAC_MIN_FILL
        )


def png_ihdr(path: Path) -> tuple[int, int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    if data[12:16] != b"IHDR":
        raise ValueError(f"{path} has no IHDR")
    width, height = struct.unpack(">II", data[16:24])
    color_type = data[25]
    return width, height, color_type


def _try_pil():
    try:
        from PIL import Image  # type: ignore

        return Image
    except ImportError:
        return None


def flatten_to_rgb(path: Path, background: tuple[int, int, int] = STAGE_BLACK) -> None:
    """Rewrite path as an 8-bit RGB PNG with no alpha, composited on Stage-black."""
    Image = _try_pil()
    if Image is not None:
        im = Image.open(path)
        rgba = im.convert("RGBA")
        bg = Image.new("RGB", rgba.size, background)
        bg.paste(rgba, mask=rgba.split()[-1])
        bg.save(path, "PNG")
        return
    _flatten_with_swift(path, background)


def _flatten_with_swift(path: Path, background: tuple[int, int, int]) -> None:
    src = Path(__file__).resolve().parent / "flatten_png.swift"
    if not src.is_file():
        raise RuntimeError(f"no Pillow and no {src} to flatten {path}")
    cmd = [
        "swift",
        str(src),
        str(path),
        str(path),
        f"{background[0]},{background[1]},{background[2]}",
    ]
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def luma_stats(path: Path, background: tuple[int, int, int] = STAGE_BLACK) -> PngStats:
    Image = _try_pil()
    if Image is not None:
        return _stats_pil(Image, path, background)
    return _stats_swift(path)


def _stats_pil(Image, path: Path, background: tuple[int, int, int]) -> PngStats:
    raw = Image.open(path)
    width, height, color_type = png_ihdr(path)
    has_alpha = raw.mode in ("RGBA", "LA", "PA") or color_type in (4, 6)
    rgba = raw.convert("RGBA")
    rgb = Image.new("RGB", rgba.size, background)
    rgb.paste(rgba, mask=rgba.split()[-1])
    # Step by 2: plenty for mean/variance/bbox, keeps CI cheap at 2880x1800.
    step = 2 if min(width, height) >= 800 else 1
    pix = rgb.load()
    n = 0
    sum_y = 0.0
    sum_y2 = 0.0
    near = 0
    minx, miny, maxx, maxy = width, height, -1, -1
    br, bg, bb = background
    for y in range(0, height, step):
        for x in range(0, width, step):
            r, g, b = pix[x, y]
            yv = 0.2126 * r + 0.7152 * g + 0.0722 * b
            n += 1
            sum_y += yv
            sum_y2 += yv * yv
            if yv < NEAR_BLACK_LUMA:
                near += 1
            if abs(r - br) > 6 or abs(g - bg) > 6 or abs(b - bb) > 6:
                if x < minx:
                    minx = x
                if y < miny:
                    miny = y
                if x > maxx:
                    maxx = x
                if y > maxy:
                    maxy = y
    mean = sum_y / n if n else 0.0
    var = (sum_y2 / n) - (mean * mean) if n else 0.0
    if var < 0:
        var = 0.0
    if maxx < 0:
        cw = ch = 0.0
    else:
        cw = (maxx - minx + step) / width
        ch = (maxy - miny + step) / height
    return PngStats(
        width=width,
        height=height,
        color_type=color_type,
        mean=mean,
        variance=var,
        near_black_frac=near / n if n else 1.0,
        content_width_frac=min(cw, 1.0),
        content_height_frac=min(ch, 1.0),
        has_alpha=has_alpha,
    )


def _stats_swift(path: Path) -> PngStats:
    """Parse the one-line report from flatten_png.swift --stats (after flatten)."""
    # After flatten the file is RGB; decode via a tiny Swift stats pass.
    src = Path(__file__).resolve().parent / "flatten_png.swift"
    cmd = ["swift", str(src), "--stats", str(path)]
    print("+", " ".join(cmd), flush=True)
    r = subprocess.run(cmd, check=True, capture_output=True, text=True)
    # STATS w= h= color_type= mean= variance= near_black= content_w= content_h= has_alpha=
    vals: dict[str, str] = {}
    for part in r.stdout.strip().split():
        if "=" in part:
            k, v = part.split("=", 1)
            vals[k] = v
    return PngStats(
        width=int(vals["w"]),
        height=int(vals["h"]),
        color_type=int(vals["color_type"]),
        mean=float(vals["mean"]),
        variance=float(vals["variance"]),
        near_black_frac=float(vals["near_black"]),
        content_width_frac=float(vals["content_w"]),
        content_height_frac=float(vals["content_h"]),
        has_alpha=vals["has_alpha"] in ("1", "true"),
    )


def reject_reason(stats: PngStats, *, mac: bool = False) -> str | None:
    if stats.has_alpha or stats.color_type == 6:
        return f"has alpha (color type {stats.color_type})"
    if stats.is_blank:
        return (
            f"blank frame (mean luma {stats.mean:.2f}, "
            f"near-black {stats.near_black_frac:.3f}, variance {stats.variance:.1f})"
        )
    if mac and stats.is_unfilled:
        return (
            f"content does not fill the canvas "
            f"(bbox {stats.content_width_frac:.2f}x{stats.content_height_frac:.2f}, "
            f"need >= {MAC_MIN_FILL})"
        )
    return None


def format_stats(stats: PngStats) -> str:
    return (
        f"{stats.width}x{stats.height} rgb{'' if not stats.has_alpha else '+alpha'} "
        f"mean={stats.mean:.2f} var={stats.variance:.1f} "
        f"near_black={stats.near_black_frac:.3f} "
        f"fill={stats.content_width_frac:.2f}x{stats.content_height_frac:.2f}"
    )


if __name__ == "__main__":
    paths = [Path(a) for a in sys.argv[1:]]
    if not paths:
        sys.stderr.write("usage: pngutil.py FILE.png...\n")
        raise SystemExit(2)
    failed = 0
    for p in paths:
        flatten_to_rgb(p)
        s = luma_stats(p)
        reason = reject_reason(s, mac="mac" in p.parts or p.parent.name == "mac")
        print(f"{p} {format_stats(s)}" + (f" REJECT {reason}" if reason else " ok"))
        if reason:
            failed = 1
    raise SystemExit(failed)
