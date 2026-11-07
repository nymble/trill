#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nymble (https://github.com/nymble)
"""Safe UF2 tooling for the Seeed XIAO nRF52840 (Sense) UF2 bootloader.

Application-only by construction: every image is checked to stay inside
0x27000..0xEC000 (after MBR + SoftDevice S140 v7, before the storage
partition and the bootloader). The Adafruit-derived bootloader treats
everything above the MBR (0x1000) as writable "application space",
SoftDevice included, so this check is the only thing standing between a
bad image and a board without a SoftDevice. Bootloader-family images
(0xD663823C) are always refused.

Nothing here runs automatically and nothing scans for devices. Writing
requires an explicit drive path, the Board-ID read back from that drive,
and --write. Without --write, `flash` is a dry run.

  convert ELF -o OUT.uf2          ELF -> application-only UF2
  inspect FILE.uf2                validate an existing UF2 (exit 1 if unsafe)
  info DRIVE                      print the bootloader's INFO_UF2.TXT
  backup DRIVE -o DIR             copy CURRENT.UF2 (+ app-only split) off the board
  flash FILE.uf2 --drive DRIVE --board-id ID [--write]

Standard library only. Tested with tools/test_xiao_uf2.py.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import os
import struct
import sys
from dataclasses import dataclass

UF2_MAGIC0 = 0x0A324655
UF2_MAGIC1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FLAG_NOT_MAIN_FLASH = 0x00000001
UF2_FLAG_FAMILY = 0x00002000
FAMILY_NRF52840 = 0xADA52840
FAMILY_BOOTLOADER = 0xD663823C
PAYLOAD = 256

APP_START = 0x00027000  # after MBR + S140 v7 (Zephyr nrf52840_partition_uf2_sdv7.dtsi)
APP_END = 0x000EC000  # start of the storage partition; bootloader at 0xF4000
RAM_START = 0x20000000
RAM_END = 0x20040000
EXPECTED_SOFTDEVICE = "S140 7.3.0"


class Unsafe(Exception):
    """Image or target failed a safety check."""


# ---------------------------------------------------------------- ELF ----

@dataclass
class Segment:
    addr: int
    data: bytes


def elf_load_segments(blob: bytes) -> list[Segment]:
    """PT_LOAD segments with file data, at their load (physical) address."""
    if blob[:4] != b"\x7fELF":
        raise Unsafe("not an ELF file")
    if blob[4] != 1 or blob[5] != 1:
        raise Unsafe("expected 32-bit little-endian ELF")
    (e_type, e_machine) = struct.unpack_from("<HH", blob, 16)
    if e_machine != 40:
        raise Unsafe(f"ELF machine {e_machine} is not ARM (40)")
    e_phoff, = struct.unpack_from("<I", blob, 28)
    e_phentsize, e_phnum = struct.unpack_from("<HH", blob, 42)
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_offset, _vaddr, p_paddr, p_filesz, _memsz, _flags, _align = struct.unpack_from(
            "<IIIIIIII", blob, off
        )
        if p_type == 1 and p_filesz > 0:
            segs.append(Segment(p_paddr, blob[p_offset : p_offset + p_filesz]))
    if not segs:
        raise Unsafe("ELF has no loadable data")
    return sorted(segs, key=lambda s: s.addr)


def check_app_range(addr: int, length: int) -> None:
    if addr < APP_START or addr + length > APP_END:
        raise Unsafe(
            f"data at 0x{addr:08X}..0x{addr + length:08X} is outside the application "
            f"window 0x{APP_START:08X}..0x{APP_END:08X} (would touch SoftDevice/MBR, "
            "storage or bootloader)"
        )


def check_vector_table(word0: int, word1: int) -> None:
    if not (RAM_START < word0 <= RAM_END):
        raise Unsafe(f"initial stack pointer 0x{word0:08X} is not in RAM")
    if word1 & 1 == 0 or not (APP_START <= (word1 & ~1) < APP_END):
        raise Unsafe(f"reset vector 0x{word1:08X} is not a Thumb address in the application")


def segments_to_pages(segs: list[Segment]) -> dict[int, bytearray]:
    pages: dict[int, bytearray] = {}
    for s in segs:
        check_app_range(s.addr, len(s.data))
        for i, b in enumerate(s.data):
            a = s.addr + i
            base = a - (a % PAYLOAD)
            page = pages.setdefault(base, bytearray(b"\xff" * PAYLOAD))
            page[a - base] = b
    return pages


def build_uf2(pages: dict[int, bytearray], family: int = FAMILY_NRF52840) -> bytes:
    out = bytearray()
    addrs = sorted(pages)
    for n, addr in enumerate(addrs):
        data = bytes(pages[addr]) + b"\x00" * (476 - PAYLOAD)
        out += struct.pack(
            "<IIIIIIII", UF2_MAGIC0, UF2_MAGIC1, UF2_FLAG_FAMILY, addr, PAYLOAD, n, len(addrs), family
        )
        out += data
        out += struct.pack("<I", UF2_MAGIC_END)
    return bytes(out)


def elf_to_uf2(blob: bytes) -> bytes:
    segs = elf_load_segments(blob)
    pages = segments_to_pages(segs)
    first = pages.get(APP_START)
    if first is None:
        raise Unsafe(f"no vector table at 0x{APP_START:08X}; was the image linked with firmware/xiao-sense/memory.x?")
    sp, reset = struct.unpack_from("<II", first, 0)
    check_vector_table(sp, reset)
    return build_uf2(pages)


# ---------------------------------------------------------------- UF2 ----

@dataclass
class Block:
    flags: int
    addr: int
    size: int
    no: int
    total: int
    family: int
    data: bytes


def parse_uf2(blob: bytes) -> list[Block]:
    if len(blob) == 0 or len(blob) % 512:
        raise Unsafe("UF2 size is not a non-zero multiple of 512")
    blocks = []
    for off in range(0, len(blob), 512):
        m0, m1, flags, addr, size, no, total, fam = struct.unpack_from("<IIIIIIII", blob, off)
        (mend,) = struct.unpack_from("<I", blob, off + 508)
        if m0 != UF2_MAGIC0 or m1 != UF2_MAGIC1 or mend != UF2_MAGIC_END:
            raise Unsafe(f"bad UF2 magic in block at offset {off}")
        if size > 476:
            raise Unsafe(f"block {no}: payload {size} > 476")
        blocks.append(Block(flags, addr, size, no, total, fam, blob[off + 32 : off + 32 + size]))
    return blocks


def validate_blocks(blocks: list[Block], *, require_vectors: bool = True) -> dict:
    """Raise Unsafe unless this is an application-only nRF52840 image."""
    totals = {b.total for b in blocks}
    if len(totals) != 1 or totals.pop() != len(blocks):
        raise Unsafe("numBlocks inconsistent with block count")
    if sorted(b.no for b in blocks) != list(range(len(blocks))):
        raise Unsafe("block numbers are not 0..n-1")
    lo, hi = None, 0
    for b in blocks:
        if b.flags & UF2_FLAG_NOT_MAIN_FLASH:
            continue
        if not b.flags & UF2_FLAG_FAMILY:
            raise Unsafe(f"block {b.no}: no family ID (refusing untyped image)")
        if b.family == FAMILY_BOOTLOADER:
            raise Unsafe("this is a BOOTLOADER update image; refusing")
        if b.family != FAMILY_NRF52840:
            raise Unsafe(f"block {b.no}: family 0x{b.family:08X} is not nRF52840 (0x{FAMILY_NRF52840:08X})")
        check_app_range(b.addr, b.size)
        lo = b.addr if lo is None else min(lo, b.addr)
        hi = max(hi, b.addr + b.size)
    if lo is None:
        raise Unsafe("no main-flash blocks")
    if require_vectors:
        first = next((b for b in blocks if b.addr == APP_START and b.size >= 8), None)
        if first is None:
            raise Unsafe(f"no vector table block at 0x{APP_START:08X}")
        check_vector_table(*struct.unpack_from("<II", first.data, 0))
    return {"blocks": len(blocks), "start": lo, "end": hi, "bytes": sum(b.size for b in blocks)}


def app_only(blocks: list[Block]) -> bytes:
    """Rebuild a UF2 with only application-window pages (used for backups,
    whose CURRENT.UF2 also contains the SoftDevice region)."""
    pages: dict[int, bytearray] = {}
    for b in blocks:
        if b.flags & UF2_FLAG_NOT_MAIN_FLASH or b.family == FAMILY_BOOTLOADER:
            continue
        for i, byte in enumerate(b.data):
            a = b.addr + i
            if APP_START <= a < APP_END:
                base = a - (a % PAYLOAD)
                pages.setdefault(base, bytearray(b"\xff" * PAYLOAD))[a - base] = byte
    pages = {a: p for a, p in pages.items() if any(x != 0xFF for x in p)}
    if not pages:
        raise Unsafe("backup has no application data")
    return build_uf2(pages)


# --------------------------------------------------------------- drive ---

def parse_info(text: str) -> dict:
    info = {}
    for line in text.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            info[k.strip()] = v.strip()
        elif line.startswith("UF2 Bootloader"):
            info["Bootloader"] = line[len("UF2 Bootloader") :].strip()
    return info


def softdevice_ok(value: str) -> bool:
    # Adafruit bootloader prints e.g. "S140 7.3.0"; tolerate "S140 version 7.3.0".
    return value.replace("version", "").split() == EXPECTED_SOFTDEVICE.split()


def check_drive(path: str) -> dict:
    if any(c in path for c in "*?[]"):
        raise Unsafe("drive path must be literal (no wildcards)")
    real = os.path.realpath(path)
    if real in ("/", os.path.expanduser("~")) or not os.path.isdir(real):
        raise Unsafe(f"{path} is not a mounted UF2 drive directory")
    info_path = os.path.join(real, "INFO_UF2.TXT")
    if not os.path.isfile(info_path):
        raise Unsafe(f"{path} has no INFO_UF2.TXT: not a UF2 bootloader drive")
    with open(info_path, encoding="ascii", errors="replace") as f:
        info = parse_info(f.read())
    info["_path"] = real
    return info


def require_target(info: dict, board_id: str) -> None:
    bid = info.get("Board-ID", "")
    if "nrf52840" not in (bid + " " + info.get("Model", "")).lower():
        raise Unsafe(f"Board-ID/Model {bid!r} / {info.get('Model')!r} do not identify an nRF52840 board")
    if not softdevice_ok(info.get("SoftDevice", "")):
        raise Unsafe(
            f"SoftDevice is {info.get('SoftDevice')!r}, expected {EXPECTED_SOFTDEVICE}; the 0x27000 "
            "application address is only valid for S140 v7"
        )
    if board_id != bid:
        raise Unsafe(f"--board-id {board_id!r} does not match the drive's Board-ID {bid!r}")


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


# ----------------------------------------------------------------- CLI ---

def cmd_convert(a) -> int:
    with open(a.elf, "rb") as f:
        uf2 = elf_to_uf2(f.read())
    summary = validate_blocks(parse_uf2(uf2))
    with open(a.output, "wb") as f:
        f.write(uf2)
    print(f"{a.output}: {summary['blocks']} blocks, 0x{summary['start']:08X}..0x{summary['end']:08X}, sha256 {sha256(uf2)}")
    return 0


def cmd_inspect(a) -> int:
    with open(a.uf2, "rb") as f:
        blob = f.read()
    blocks = parse_uf2(blob)
    fams = sorted({b.family for b in blocks})
    print(f"{a.uf2}: {len(blocks)} blocks, families {[hex(x) for x in fams]}, sha256 {sha256(blob)}")
    s = validate_blocks(blocks)
    print(f"OK application-only: 0x{s['start']:08X}..0x{s['end']:08X} ({s['bytes']} bytes)")
    return 0


def cmd_info(a) -> int:
    info = check_drive(a.drive)
    for k, v in info.items():
        if not k.startswith("_"):
            print(f"{k}: {v}")
    print("SoftDevice check:", "OK" if softdevice_ok(info.get("SoftDevice", "")) else "MISMATCH")
    return 0


def cmd_backup(a) -> int:
    info = check_drive(a.drive)
    src = os.path.join(info["_path"], "CURRENT.UF2")
    if not os.path.isfile(src):
        raise Unsafe("drive has no CURRENT.UF2 (bootloader does not expose a read-back)")
    with open(src, "rb") as f:
        blob = f.read()
    blocks = parse_uf2(blob)
    os.makedirs(a.output, exist_ok=True)
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    full = os.path.join(a.output, f"backup-{stamp}-CURRENT.uf2")
    app = os.path.join(a.output, f"backup-{stamp}-app-only.uf2")
    infof = os.path.join(a.output, f"backup-{stamp}-INFO_UF2.TXT")
    app_blob = app_only(blocks)
    validate_blocks(parse_uf2(app_blob))
    for path, data in ((full, blob), (app, app_blob)):
        with open(path, "wb") as f:
            f.write(data)
        print(f"{path}: sha256 {sha256(data)}")
    with open(os.path.join(info["_path"], "INFO_UF2.TXT"), "rb") as f, open(infof, "wb") as g:
        g.write(f.read())
    print(f"{infof}")
    print("Restore later with: flash <app-only.uf2> --drive ... --board-id ... --write")
    return 0


def cmd_flash(a) -> int:
    with open(a.uf2, "rb") as f:
        blob = f.read()
    s = validate_blocks(parse_uf2(blob))
    info = check_drive(a.drive)
    require_target(info, a.board_id)
    dest = os.path.join(info["_path"], "TRILL.UF2")
    print(f"image  : {a.uf2} 0x{s['start']:08X}..0x{s['end']:08X} sha256 {sha256(blob)}")
    print(f"target : {info['_path']} Board-ID {info.get('Board-ID')} SoftDevice {info.get('SoftDevice')} bootloader {info.get('Bootloader')}")
    if not a.write:
        print("dry run: nothing written (add --write to copy the image to the drive)")
        return 0
    try:
        with open(dest, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
    except OSError as e:
        # The bootloader resets as soon as the last block lands; the volume
        # can vanish before close().
        print(f"drive went away during/after write ({e}); this is normal once all blocks are received")
    print("written; the board reboots into the new application")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("elf")
    c.add_argument("-o", "--output", required=True)
    c.set_defaults(fn=cmd_convert)
    i = sub.add_parser("inspect")
    i.add_argument("uf2")
    i.set_defaults(fn=cmd_inspect)
    n = sub.add_parser("info")
    n.add_argument("drive")
    n.set_defaults(fn=cmd_info)
    b = sub.add_parser("backup")
    b.add_argument("drive")
    b.add_argument("-o", "--output", required=True)
    b.set_defaults(fn=cmd_backup)
    w = sub.add_parser("flash")
    w.add_argument("uf2")
    w.add_argument("--drive", required=True, help="literal mount path, e.g. /Volumes/XIAO-SENSE")
    w.add_argument("--board-id", required=True, help="must equal Board-ID in the drive's INFO_UF2.TXT")
    w.add_argument("--write", action="store_true", help="actually copy the image (default: dry run)")
    w.set_defaults(fn=cmd_flash)
    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except Unsafe as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
