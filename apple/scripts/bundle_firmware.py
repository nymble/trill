#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Put the firmware for this version into apple/Firmware for the app bundle.

    bundle_firmware.py IMAGE.uf2 VERSION [OUT_DIR]

Validates IMAGE with tools/xiao_uf2.py rules, checks VERSION against the app's
MARKETING_VERSION, then writes OUT_DIR/xiao-sense-fw.uf2 and firmware.json.
Standard library only.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main() -> int:
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    image, version = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) == 4 else os.path.join(ROOT, "apple", "Firmware")
    if not os.path.isfile(image):
        raise SystemExit(f"{image} not found: run `make fw-uf2` first")
    with open(os.path.join(ROOT, "apple", "Config", "Base.xcconfig"), encoding="utf-8") as f:
        m = re.search(r"^MARKETING_VERSION = (\S+)", f.read(), re.M)
    if not m or m.group(1) != version:
        raise SystemExit(f"firmware {version} does not match the app's MARKETING_VERSION {m and m.group(1)}")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "xiao_uf2.py"), "inspect", image], check=True)
    with open(image, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    os.makedirs(out, exist_ok=True)
    shutil.copyfile(image, os.path.join(out, "xiao-sense-fw.uf2"))
    manifest = {
        "version": version,
        "file": "xiao-sense-fw.uf2",
        "sha256": digest,
        "board": "Seeed Studio XIAO nRF52840 Sense",
    }
    with open(os.path.join(out, "firmware.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"bundled firmware {version} sha256 {digest} -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
