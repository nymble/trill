#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Release notes for vX.Y.Z: the CHANGELOG section plus a downloads guide.

    release_notes.py 0.5.0 [CHANGELOG.md] > notes.md

Fails (exit 1) when CHANGELOG.md has no "## [X.Y.Z]" heading, so a tag
cannot be released without written notes. Standard library only.
"""

import re
import sys

DOWNLOADS = """\
## Downloads

| File | What it is |
|---|---|
| `Trillium-macOS-unsigned-dev-{v}.zip` | Trillium app for macOS 13+ (Apple Silicon and Intel) |
| `xiao-sense-fw-{v}.uf2` | Instrument firmware for the Seeed XIAO nRF52840 Sense (application only; bootloader and SoftDevice untouched) |
| `xiao_uf2.py` | Checks the firmware file and copies it to the board only when asked |
| `Trillium-{v}-<commit>.zip` | Everything above from one commit, with docs and a manifest |
| `trill-{v}-<target>.tar.gz` | `trill` command-line tool for Raspberry Pi and Linux |
| `SHA256SUMS` | Checksums: `shasum -a 256 -c SHA256SUMS --ignore-missing` |

**Opening the app.** It is not notarized or signed with a Developer ID, so macOS blocks it the first time. On macOS 15 or newer, try to open it once, then go to System Settings > Privacy & Security > *Open Anyway*. On macOS 13 or 14, right-click Trillium.app and choose *Open*.

**Updating the firmware.** Keep a backup of your current firmware first. Then double-press RESET on the XIAO so the `XIAO-SENSE` drive appears, and run:

```sh
python3 xiao_uf2.py info /Volumes/XIAO-SENSE
python3 xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id Seeed_XIAO_nRF52840_Sense xiao-sense-fw-{v}.uf2          # dry run
python3 xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id Seeed_XIAO_nRF52840_Sense xiao-sense-fw-{v}.uf2 --write  # copy
```

Development builds: the USB IDs (1209:0002) and SysEx ID (0x7D) are test identifiers. Licence: GPL-3.0-only; commercial terms in `COMMERCIAL-LICENSE.md`.
"""


def section(text: str, version: str) -> str:
    m = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M)
    if not m or not m.group(1).strip():
        raise SystemExit(f"CHANGELOG has no '## [{version}]' section; add one before tagging v{version}")
    return m.group(1).strip()


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    version = sys.argv[1].removeprefix("v")
    path = sys.argv[2] if len(sys.argv) == 3 else "CHANGELOG.md"
    with open(path, encoding="utf-8") as f:
        body = section(f.read(), version)
    print(f"{body}\n\n{DOWNLOADS.format(v=version)}")


if __name__ == "__main__":
    main()
