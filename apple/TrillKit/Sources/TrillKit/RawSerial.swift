// SPDX-License-Identifier: GPL-3.0-only
//
// Open a USB CDC ACM port (/dev/cu.usbmodem…) for reading binary data.
//
// A tty opened with plain open() keeps the line discipline's defaults:
// canonical (line-buffered) input, echo, CR-to-NL translation and the
// control characters (erase, kill, EOF, start/stop, …). Binary PCM frames
// are mangled by that and never pass their CRC, so the port must be put in
// raw mode first. The line speed is left as it is: CDC ACM ignores it, and
// 1200 baud must never be set (it resets many boards into their bootloader).

import Foundation
#if os(macOS)
import Darwin

public enum RawSerial {
    public struct OpenError: Error, CustomStringConvertible {
        public let call: String
        public let code: Int32
        public var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
    }

    /// Open `path` read-only, non-blocking, without making it the
    /// controlling terminal, in raw mode, with DTR raised (the firmware only
    /// streams while the host holds DTR). The caller owns the descriptor.
    public static func openForReading(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw OpenError(call: "open", code: errno) }
        do {
            try makeRaw(fd)
        } catch {
            close(fd)
            throw error
        }
        // TIOCSDTR = _IO('t', 121). Not imported into Swift (function-like
        // macro). Ignored where it does not apply (e.g. a pseudo-terminal).
        _ = ioctl(fd, UInt(0x2000_7479))
        tcflush(fd, TCIFLUSH)
        return fd
    }

    /// Raw mode: no line buffering, echo, translation or signal characters;
    /// 8 data bits; modem control lines ignored. Speed unchanged.
    public static func makeRaw(_ fd: Int32) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw OpenError(call: "tcgetattr", code: errno) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw OpenError(call: "tcsetattr", code: errno) }
    }

    /// True when the descriptor's line discipline passes bytes unchanged.
    public static func isRaw(_ fd: Int32) -> Bool {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        let lflags = tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        let iflags = tcflag_t(ICRNL | INLCR | IGNCR | IXON | ISTRIP)
        return t.c_lflag & lflags == 0 && t.c_iflag & iflags == 0
    }

    /// Read everything available without blocking.
    public static func readAvailable(_ fd: Int32, max: Int = 1 << 16) -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < max {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}
#endif
