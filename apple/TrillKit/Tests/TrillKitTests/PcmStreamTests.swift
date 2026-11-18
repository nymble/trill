// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import TrillKit

final class PcmStreamTests: XCTestCase {
    /// Golden frame shared with `motion-synth` `stream` tests and
    /// `tools/test_pcm_capture.py`: seq 0x01020304, 32 kHz, FLAG_DROPPED,
    /// samples [1, -1], CRC 0x5E73.
    private let golden: [UInt8] = [
        0x54, 0x52, 0x50, 0x43, 1, 1, 2, 0,
        4, 3, 2, 1, 0x00, 0x7D, 0, 0,
        1, 0, 0xFF, 0xFF, 0x73, 0x5E,
    ]

    func testGoldenFrame() {
        let (f, n) = PcmStream.decode(golden[...]) ?? { XCTFail("decode"); return (PcmStream.Frame(flags: 0, seq: 0, sampleRate: 0, samples: []), 0) }()
        XCTAssertEqual(n, 22)
        XCTAssertEqual(f.flags, PcmStream.flagDropped)
        XCTAssertTrue(f.dropped)
        XCTAssertEqual(f.seq, 0x0102_0304)
        XCTAssertEqual(f.sampleRate, 32_000)
        XCTAssertEqual(f.samples, [1, -1])
        XCTAssertEqual(PcmStream.crc16(golden[..<(golden.count - 2)]), 0x5E73)
    }

    func testParserResyncsAfterJunk() {
        var p = PcmStream.Parser()
        var junk: [UInt8] = [0x00, 0x11, 0x22]
        junk.append(contentsOf: golden)
        junk.append(contentsOf: [0x99])
        junk.append(contentsOf: golden)
        let frames = p.push(junk)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].seq, 0x0102_0304)
        XCTAssertEqual(frames[1].samples, [1, -1])
    }

    func testParserWaitsForCompleteFrame() {
        var p = PcmStream.Parser()
        XCTAssertTrue(p.push(Array(golden.prefix(10))).isEmpty)
        let frames = p.push(Array(golden.dropFirst(10)))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].sampleRate, 32_000)
    }

    func testRejectsBadCRC() {
        var bad = golden
        bad[bad.count - 1] ^= 1
        XCTAssertNil(PcmStream.decode(bad[...]))
    }
}
