#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Unit tests for tools/xiao_uf2.py and tools/pcm_capture.py (stdlib unittest).

  python3 -m unittest discover -s tools -p 'test_*.py'
"""

import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import pcm_capture  # noqa: E402
import xiao_uf2 as u  # noqa: E402


def make_elf(segments):
    """Minimal ARM ELF32 with PT_LOAD segments [(paddr, bytes)]."""
    ehsize, phentsize = 52, 32
    phoff = ehsize
    data_off = phoff + phentsize * len(segments)
    ph = b""
    body = b""
    for paddr, data in segments:
        ph += struct.pack("<IIIIIIII", 1, data_off + len(body), paddr, paddr, len(data), len(data), 5, 4)
        body += data
    ident = b"\x7fELF" + bytes([1, 1, 1]) + b"\x00" * 9
    eh = ident + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0x27101, phoff, 0, 0x5000400, ehsize, phentsize, len(segments), 40, 0, 0)
    return eh + ph + body


def vectors(sp=0x20040000, reset=0x27101):
    return struct.pack("<II", sp, reset) + b"\x00" * 248


class Uf2Tests(unittest.TestCase):
    def test_convert_roundtrip(self):
        elf = make_elf([(0x27000, vectors() + b"\xaa" * 100), (0x28000, b"\x55" * 10)])
        uf2 = u.elf_to_uf2(elf)
        blocks = u.parse_uf2(uf2)
        s = u.validate_blocks(blocks)
        self.assertEqual(s["start"], 0x27000)
        self.assertEqual(len(blocks), 3)  # 0x27000, 0x27100, 0x28000
        self.assertTrue(all(b.family == u.FAMILY_NRF52840 for b in blocks))
        self.assertEqual(blocks[1].data[:100], b"\xaa" * 100)
        self.assertEqual(blocks[1].data[100:], b"\xff" * 156)

    def test_refuses_softdevice_region(self):
        elf = make_elf([(0x26F00, b"\x00" * 512)])
        with self.assertRaises(u.Unsafe):
            u.elf_to_uf2(elf)

    def test_refuses_storage_and_bootloader_region(self):
        for addr in (0xEC000, 0xF4000):
            elf = make_elf([(0x27000, vectors()), (addr, b"\x00" * 4)])
            with self.assertRaises(u.Unsafe, msg=hex(addr)):
                u.elf_to_uf2(elf)

    def test_refuses_bad_vectors(self):
        with self.assertRaises(u.Unsafe):
            u.elf_to_uf2(make_elf([(0x27000, vectors(sp=0x1000))]))
        with self.assertRaises(u.Unsafe):
            u.elf_to_uf2(make_elf([(0x27000, vectors(reset=0x27100))]))  # not Thumb

    def test_refuses_bootloader_family_and_untyped(self):
        pages = {0x27000: bytearray(vectors())}
        boot = u.build_uf2(pages, family=u.FAMILY_BOOTLOADER)
        with self.assertRaises(u.Unsafe):
            u.validate_blocks(u.parse_uf2(boot))
        untyped = bytearray(u.build_uf2(pages))
        struct.pack_into("<I", untyped, 8, 0)  # clear flags
        with self.assertRaises(u.Unsafe):
            u.validate_blocks(u.parse_uf2(bytes(untyped)))

    def test_app_only_strips_softdevice_from_backup(self):
        pages = {0x1000: bytearray(b"\x11" * 256), 0x27000: bytearray(vectors()), 0xEC000: bytearray(b"\x22" * 256)}
        full = u.build_uf2(pages)
        with self.assertRaises(u.Unsafe):
            u.validate_blocks(u.parse_uf2(full))
        app = u.parse_uf2(u.app_only(u.parse_uf2(full)))
        self.assertEqual([b.addr for b in app], [0x27000])
        u.validate_blocks(app)

    def _drive(self, d, board="Seeed_XIAO_nRF52840_Sense", sd="S140 7.3.0"):
        with open(os.path.join(d, "INFO_UF2.TXT"), "w") as f:
            f.write(f"UF2 Bootloader 0.6.1\r\nModel: Seeed XIAO nRF52840\r\nBoard-ID: {board}\r\nSoftDevice: {sd}\r\nDate: x\r\n")

    def test_drive_checks_and_dry_run(self):
        with tempfile.TemporaryDirectory() as d:
            self._drive(d)
            img = os.path.join(d, "..", os.path.basename(d) + ".uf2")
            with open(img, "wb") as f:
                f.write(u.elf_to_uf2(make_elf([(0x27000, vectors())])))
            try:
                info = u.check_drive(d)
                u.require_target(info, "Seeed_XIAO_nRF52840_Sense")
                with self.assertRaises(u.Unsafe):
                    u.require_target(info, "Other")
                # dry run writes nothing
                with contextlib.redirect_stdout(io.StringIO()):
                    rc = u.main(["flash", img, "--drive", d, "--board-id", "Seeed_XIAO_nRF52840_Sense"])
                self.assertEqual(rc, 0)
                self.assertFalse(os.path.exists(os.path.join(d, "TRILL.UF2")))
                # explicit write (to the temp dir standing in for the drive)
                with contextlib.redirect_stdout(io.StringIO()):
                    rc = u.main(["flash", img, "--drive", d, "--board-id", "Seeed_XIAO_nRF52840_Sense", "--write"])
                self.assertEqual(rc, 0)
                self.assertTrue(os.path.exists(os.path.join(d, "TRILL.UF2")))
            finally:
                os.remove(img)

    def test_wrong_softdevice_refused(self):
        with tempfile.TemporaryDirectory() as d:
            self._drive(d, sd="S140 6.1.1")
            with self.assertRaises(u.Unsafe):
                u.require_target(u.check_drive(d), "Seeed_XIAO_nRF52840_Sense")
        self.assertTrue(u.softdevice_ok("S140 version 7.3.0"))

    def test_wildcards_and_non_drive_refused(self):
        with self.assertRaises(u.Unsafe):
            u.check_drive("/Volumes/XIAO*")
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(u.Unsafe):
                u.check_drive(d)  # no INFO_UF2.TXT


class PcmTests(unittest.TestCase):
    # Same golden frame as crates/motion-synth/src/stream.rs::golden_frame
    GOLDEN = bytes([0x54, 0x52, 0x50, 0x43, 1, 1, 2, 0, 4, 3, 2, 1, 0x00, 0x7D, 0, 0, 1, 0, 0xFF, 0xFF, 0x73, 0x5E])

    def test_crc_check_value(self):
        self.assertEqual(pcm_capture.crc16(b"123456789"), 0x29B1)

    def test_golden_frame(self):
        p = pcm_capture.Parser()
        self.assertEqual(p.feed(self.GOLDEN), [[1, -1]])
        self.assertEqual((p.frames, p.dropped_flags, p.sample_rate, p.last_seq), (1, 1, 32000, 0x01020304))

    def _frame(self, seq, samples):
        hdr = b"TRPC" + struct.pack("<BBHII", 1, 0, len(samples), seq, 32000) + struct.pack(f"<{len(samples)}h", *samples)
        return hdr + struct.pack("<H", pcm_capture.crc16(hdr))

    def test_resync_crc_and_gaps(self):
        p = pcm_capture.Parser()
        bad = bytearray(self._frame(1, [5, 6]))
        bad[17] ^= 0xFF
        stream = b"junkTR" + self._frame(0, [1, 2]) + bytes(bad) + self._frame(2, [3]) + self._frame(5, [4])
        out = []
        for i in range(0, len(stream), 7):  # arbitrary chunking
            out += p.feed(stream[i : i + 7])
        self.assertEqual(out, [[1, 2], [3], [4]])
        self.assertEqual(p.crc_errors, 1)
        self.assertEqual(p.seq_gaps, 2)  # 0->2 and 2->5


if __name__ == "__main__":
    unittest.main()
