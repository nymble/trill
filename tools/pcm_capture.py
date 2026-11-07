#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nymble (https://github.com/nymble)
"""Capture the firmware's framed PCM test stream (second USB CDC port) to WAV.

  pcm_capture.py /dev/ttyACM1 -o take.wav --seconds 10     # Linux
  pcm_capture.py /dev/cu.usbmodemXXXX3 -o take.wav          # macOS

The port is given explicitly; nothing is auto-detected. Opening the port
asserts DTR, which tells the firmware to start streaming. Frame format:
crates/motion-synth/src/stream.rs. Reports CRC errors, sequence gaps,
device-side drops and the sample rate measured against the host clock.
Standard library only (termios), POSIX hosts.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time
import wave

MAGIC = b"TRPC"
HEADER = 16


def crc16(data: bytes) -> int:
    """CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF)."""
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


class Parser:
    """Incremental frame parser with resynchronisation on the magic."""

    MAX_SAMPLES = 4096

    def __init__(self) -> None:
        self.buf = bytearray()
        self.frames = 0
        self.crc_errors = 0
        self.resync_bytes = 0
        self.seq_gaps = 0
        self.dropped_flags = 0
        self.last_seq: int | None = None
        self.sample_rate: int | None = None

    def feed(self, data: bytes) -> list[list[int]]:
        self.buf += data
        out = []
        while True:
            i = self.buf.find(MAGIC)
            if i < 0:
                keep = len(MAGIC) - 1
                self.resync_bytes += max(0, len(self.buf) - keep)
                del self.buf[: max(0, len(self.buf) - keep)]
                return out
            if i:
                self.resync_bytes += i
                del self.buf[:i]
            if len(self.buf) < HEADER:
                return out
            version, flags, n, seq, rate = struct.unpack_from("<BBHII", self.buf, 4)
            if version != 1 or n > self.MAX_SAMPLES:
                self.resync_bytes += 1
                del self.buf[:1]
                continue
            total = HEADER + 2 * n + 2
            if len(self.buf) < total:
                return out
            frame = bytes(self.buf[:total])
            (crc,) = struct.unpack_from("<H", frame, total - 2)
            if crc16(frame[:-2]) != crc:
                self.crc_errors += 1
                self.resync_bytes += 1
                del self.buf[:1]
                continue
            del self.buf[:total]
            self.frames += 1
            if flags & 1:
                self.dropped_flags += 1
            if self.last_seq is not None and seq != (self.last_seq + 1) & 0xFFFFFFFF:
                self.seq_gaps += 1
            self.last_seq = seq
            self.sample_rate = rate
            out.append(list(struct.unpack_from(f"<{n}h", frame, HEADER)))


def open_raw(path: str) -> int:
    import termios

    fd = os.open(path, os.O_RDONLY | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0  # iflag
    attrs[1] = 0  # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL | termios.HUPCL
    attrs[3] = 0  # lflag: raw
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 2
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="PCM CDC port (the second one the board exposes)")
    ap.add_argument("-o", "--output", required=True, help="WAV file to write")
    ap.add_argument("--seconds", type=float, default=10.0)
    a = ap.parse_args(argv)
    if any(c in a.port for c in "*?[]"):
        print("port must be a literal path", file=sys.stderr)
        return 2

    fd = open_raw(a.port)
    p = Parser()
    samples: list[int] = []
    t0 = None
    deadline = time.monotonic() + a.seconds + 2.0
    try:
        while time.monotonic() < deadline:
            data = os.read(fd, 4096)
            for block in p.feed(data):
                if t0 is None:
                    t0 = time.monotonic()
                    deadline = t0 + a.seconds
                samples.extend(block)
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)
    elapsed = (time.monotonic() - t0) if t0 else 0.0
    rate = p.sample_rate or 32000
    with wave.open(a.output, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    measured = len(samples) / elapsed if elapsed > 0 else 0.0
    print(
        f"{a.output}: {len(samples)} samples, {p.frames} frames, nominal {rate} Hz, "
        f"measured {measured:.0f} Hz over {elapsed:.2f} s, crc_errors {p.crc_errors}, "
        f"seq_gaps {p.seq_gaps}, device_drops {p.dropped_flags}, resync_bytes {p.resync_bytes}"
    )
    return 0 if p.frames else 1


if __name__ == "__main__":
    sys.exit(main())
