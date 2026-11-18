// SPDX-License-Identifier: GPL-3.0-only
//
// Framed PCM test stream (`TRPC`), the same layout as crates/motion-synth
// `stream`. Used for the microphone test path and the optional debug synth.

import Foundation

public enum PcmStream {
    public static let magic: [UInt8] = [0x54, 0x52, 0x50, 0x43] // "TRPC"
    public static let version: UInt8 = 1
    public static let headerLength = 16
    public static let flagDropped: UInt8 = 1

    public static func frameLength(samples n: Int) -> Int { headerLength + 2 * n + 2 }

    /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection).
    public static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    public struct Frame: Equatable, Sendable {
        public var flags: UInt8
        public var seq: UInt32
        public var sampleRate: UInt32
        public var samples: [Int16]
        public var dropped: Bool { flags & PcmStream.flagDropped != 0 }
    }

    /// Decode one frame at the start of `data`. Returns the frame and the
    /// number of bytes consumed, or nil if the prefix is not a complete
    /// valid frame (need more bytes, bad magic after a sync, or bad CRC).
    public static func decode(_ data: ArraySlice<UInt8>) -> (Frame, Int)? {
        if data.count < headerLength + 2 { return nil }
        if Array(data.prefix(4)) != magic { return nil }
        if data[data.startIndex + 4] != version { return nil }
        let flags = data[data.startIndex + 5]
        func u16(_ i: Int) -> UInt16 {
            let o = data.startIndex + i
            return UInt16(data[o]) | UInt16(data[o + 1]) << 8
        }
        func u32(_ i: Int) -> UInt32 {
            let o = data.startIndex + i
            return UInt32(data[o]) | UInt32(data[o + 1]) << 8
                | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        let n = Int(u16(6))
        let len = frameLength(samples: n)
        if data.count < len { return nil }
        let body = data.prefix(len - 2)
        let expect = u16(len - 2)
        if crc16(body) != expect { return nil }
        var samples: [Int16] = []
        samples.reserveCapacity(n)
        let payload = data.startIndex + headerLength
        for i in 0..<n {
            let lo = data[payload + 2 * i]
            let hi = data[payload + 2 * i + 1]
            samples.append(Int16(bitPattern: UInt16(lo) | UInt16(hi) << 8))
        }
        let frame = Frame(flags: flags, seq: u32(8), sampleRate: u32(12), samples: samples)
        return (frame, len)
    }

    /// Reassembly of a byte stream into frames. Bytes that cannot start a
    /// frame (wrong magic) are skipped one at a time so a lost packet can
    /// resynchronise on the next `TRPC` marker.
    public struct Parser: Sendable {
        private var buf: [UInt8] = []
        public init() {}

        public mutating func push(_ bytes: [UInt8]) -> [Frame] {
            buf.append(contentsOf: bytes)
            var out: [Frame] = []
            var i = 0
            while i + headerLength + 2 <= buf.count {
                if buf[i] != magic[0] || buf[i + 1] != magic[1]
                    || buf[i + 2] != magic[2] || buf[i + 3] != magic[3] {
                    i += 1
                    continue
                }
                guard let (frame, n) = decode(buf[i...]) else {
                    // Looks like a header but the rest has not arrived yet.
                    if i + frameLength(samples: Int(UInt16(buf[i + 6]) | UInt16(buf[i + 7]) << 8)) > buf.count {
                        break
                    }
                    // Complete but invalid: skip the magic and hunt again.
                    i += 1
                    continue
                }
                out.append(frame)
                i += n
            }
            if i > 0 { buf.removeFirst(i) }
            return out
        }
    }
}
