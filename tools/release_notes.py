#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Release notes for vX.Y.Z: the CHANGELOG section plus a downloads guide.

    release_notes.py 0.5.0 [CHANGELOG.md] > notes.md

Fails (exit 1) when CHANGELOG.md has no "## [X.Y.Z]" heading, so a tag
cannot be released without written notes. Standard library only.
"""

import re
import sys

# Brand release header (brand/visuals/png/release-header-light-1600x546.png),
# linked at the tag so the image matches the released tree.
HEADER = (
    "![Trillium {v}](https://raw.githubusercontent.com/nymble/trillium/v{v}/"
    "brand/visuals/png/release-header-light-1600x546.png)"
)

DOWNLOADS = """\
## Downloads

| File | What it is |
|---|---|
| `Trillium-macOS-{v}.dmg` | Trillium app for macOS 13+ (Apple Silicon and Intel). Drag Trillium to Applications. |
| `Trillium-macOS-unsigned-dev-{v}.zip` | The same macOS app as a zip (Apple Silicon and Intel) |
| `Trillium-iOS-Simulator-{v}.zip` | Trillium app for the iPhone and iPad Simulator (iOS/iPadOS 16+). It cannot be installed on a physical device. The Simulator has no USB MIDI device, so Home shows the plug-in prompt. |
| `xiao-sense-fw-{v}.uf2` | Instrument firmware for the Seeed XIAO nRF52840 Sense (application only; bootloader and SoftDevice untouched) |
| `xiao_uf2.py` | Checks the firmware file and copies it to the board only when asked |
| `Trillium-{v}-<commit>.zip` | Everything above from one commit, with docs and a manifest |
| `trill-{v}-<target>.tar.gz` | `trill` command-line tool for Raspberry Pi and Linux |
| `SHA256SUMS` | Checksums: `shasum -a 256 -c SHA256SUMS --ignore-missing` |

**Opening the app.** Open the DMG and drag Trillium to Applications (or unzip the zip). The app is not notarized or signed with a Developer ID, so macOS blocks it the first time. On macOS 15 or newer, try to open it once, then go to System Settings > Privacy & Security > *Open Anyway*. On macOS 13 or 14, right-click Trillium.app and choose *Open*.

**Updating the firmware.** The Trillium app carries this firmware and installs it for you: connect Trillium and choose *Update firmware* on Home (or Settings > Firmware), or plug in a new Seeed Studio XIAO nRF52840 Sense and double-press RESET. The app backs up the board's firmware first. To do it by hand instead, double-press RESET so the `XIAO-SENSE` drive appears, keep a backup, and use the Board-ID that `info` prints:

```sh
python3 xiao_uf2.py info /Volumes/XIAO-SENSE
python3 xiao_uf2.py backup /Volumes/XIAO-SENSE -o backups/
python3 xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id <Board-ID> xiao-sense-fw-{v}.uf2          # dry run
python3 xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id <Board-ID> xiao-sense-fw-{v}.uf2 --write  # copy
```

Development builds: the USB IDs (1209:0003) and SysEx ID (0x7D) are test identifiers. Licence: GPL-3.0-only; commercial terms in `COMMERCIAL-LICENSE.md`.
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
    print(f"{HEADER.format(v=version)}\n\n{body}\n\n{DOWNLOADS.format(v=version)}")


if __name__ == "__main__":
    main()
