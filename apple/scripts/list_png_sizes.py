#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Print WIDTH x HEIGHT, luma stats, and color type for every PNG under a directory.

Writes SIZES.txt. Exits non-zero if any shot is blank, has alpha, or (for Mac)
does not fill the canvas.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pngutil


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    rows = []
    failures = []
    for p in sorted(root.rglob("*.png")):
        stats = pngutil.luma_stats(p)
        line = (
            f"{p.relative_to(root)} {stats.width}x{stats.height} {p.stat().st_size} "
            f"{pngutil.format_stats(stats)}"
        )
        print(line)
        rows.append(line)
        mac = "mac" in p.parts or p.parent.name == "mac"
        reason = pngutil.reject_reason(stats, mac=mac)
        if reason:
            failures.append(f"{p.relative_to(root)}: {reason}")
            print(f"  REJECT {reason}", file=sys.stderr)
    (root / "SIZES.txt").write_text("\n".join(rows) + "\n")
    if failures:
        print("unusable screenshots:\n" + "\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
