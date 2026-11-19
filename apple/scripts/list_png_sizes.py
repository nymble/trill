#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Print WIDTH x HEIGHT for every PNG under a directory, and write SIZES.txt."""
from __future__ import annotations

import struct
import sys
from pathlib import Path


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG")
    return struct.unpack(">II", data[16:24])


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    rows = []
    for p in sorted(root.rglob("*.png")):
        w, h = png_size(p)
        line = f"{p.relative_to(root)} {w}x{h} {p.stat().st_size}"
        print(line)
        rows.append(line)
    (root / "SIZES.txt").write_text("\n".join(rows) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
