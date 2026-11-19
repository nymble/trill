// SPDX-License-Identifier: GPL-3.0-only
//
// The microphone PCM port must be read in raw mode. Checked on a
// pseudo-terminal, which has the same line discipline as a USB CDC port.

#if os(macOS)
import Darwin
import XCTest
@testable import TrillKit

final class RawSerialTests: XCTestCase {
    /// A TRPC frame whose payload holds the bytes a default tty rewrites or
    /// swallows: CR, NL, EOF, erase, kill, start/stop, … (signal
    /// characters are left out so the test never raises one)
    static func frame() -> (bytes: [UInt8], samples: [Int16]) {
        let tricky: [UInt8] = [0x0D, 0x0A, 0x04, 0x7F, 0x15, 0x11, 0x13, 0x17, 0x12, 0x16, 0x0F, 0x08]
        var samples: [Int16] = []
        for i in stride(from: 0, to: tricky.count, by: 2) {
            samples.append(Int16(bitPattern: UInt16(tricky[i]) | UInt16(tricky[i + 1]) << 8))
        }
        samples += (0..<62).map { Int16(bitPattern: UInt16(0x40 + $0) | UInt16(0x30 + $0) << 8) }
        var b: [UInt8] = PcmStream.magic + [PcmStream.version, 0]
        b += [UInt8(samples.count & 0xFF), UInt8(samples.count >> 8)]
        b += [0x0D, 0x0A, 0x05, 0x00]          // seq
        b += [0x80, 0x3E, 0x00, 0x00]          // 16 000 Hz
        for s in samples { let u = UInt16(bitPattern: s); b += [UInt8(u & 0xFF), UInt8(u >> 8)] }
        let crc = PcmStream.crc16(b[...])
        b += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return (b, samples)
    }

    private func pty() throws -> (master: Int32, slave: Int32) {
        var m: Int32 = -1, s: Int32 = -1
        guard openpty(&m, &s, nil, nil, nil) == 0 else { throw XCTSkip("no pseudo-terminal") }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        return (m, s)
    }

    private func send(_ bytes: [UInt8], to fd: Int32) {
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        usleep(100_000)
    }

    func testRawModePassesFramesUnchanged() throws {
        let (m, s) = try pty()
        defer { close(m); close(s) }
        XCTAssertFalse(RawSerial.isRaw(s), "a new tty starts in canonical mode")
        try RawSerial.makeRaw(s)
        XCTAssertTrue(RawSerial.isRaw(s))
        let (bytes, samples) = Self.frame()
        XCTAssertNotNil(PcmStream.decode(bytes[...]))
        send(bytes + bytes, to: m)
        var parser = PcmStream.Parser()
        let frames = parser.push(RawSerial.readAvailable(s))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.samples, samples)
        XCTAssertEqual(frames.first?.sampleRate, 16_000)
    }

    /// The 0.7.0 app read the port with the default line discipline: no
    /// frame survived, so the chart stayed empty and nothing played.
    func testDefaultLineDisciplineBreaksFrames() throws {
        let (m, s) = try pty()
        defer { close(m); close(s) }
        let (bytes, _) = Self.frame()
        send(bytes + bytes, to: m)
        var parser = PcmStream.Parser()
        XCTAssertEqual(parser.push(RawSerial.readAvailable(s)).count, 0)
    }
}
#endif
