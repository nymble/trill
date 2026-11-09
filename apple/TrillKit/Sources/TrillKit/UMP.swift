// SPDX-License-Identifier: GPL-3.0-only
//
// Universal MIDI Packet (UMP) handling for MIDI 1.0 protocol event lists as
// delivered by CoreMIDI's MIDIInputPortCreateWithProtocol(._1_0). CoreMIDI
// already resolves running status and splits SysEx into 64-bit SysEx7
// packets; this file turns UMP words into `MIDIEvent`s and reassembles
// SysEx with a hard size bound.

import Foundation

public enum UMP {
    /// Words in a UMP whose first word is `w` (UMP spec message-type sizes).
    public static func wordCount(_ w: UInt32) -> Int {
        switch w >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    /// Encode a complete SysEx message (`F0 ... F7`) as MIDI 1.0 UMP SysEx7
    /// packets (two words each) on `group`.
    public static func sysex7Words(_ message: [UInt8], group: UInt8 = 0) -> [UInt32] {
        var body = message
        if body.first == 0xF0 { body.removeFirst() }
        if body.last == 0xF7 { body.removeLast() }
        let chunks = stride(from: 0, to: max(body.count, 1), by: 6).map {
            Array(body[$0..<min($0 + 6, body.count)])
        }
        var words: [UInt32] = []
        for (i, c) in chunks.enumerated() {
            let status: UInt32
            if chunks.count == 1 { status = 0 } else if i == 0 { status = 1 } else if i == chunks.count - 1 { status = 3 } else { status = 2 }
            var b = c + [UInt8](repeating: 0, count: 6 - c.count)
            b = b.map { $0 & 0x7F }
            let w0 = 0x3000_0000 | UInt32(group & 0xF) << 24 | status << 20 | UInt32(c.count) << 16
                | UInt32(b[0]) << 8 | UInt32(b[1])
            let w1 = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
            words += [w0, w1]
        }
        return words
    }
}

/// One decoded MIDI message.
public enum MIDIMessage: Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case polyPressure(channel: UInt8, note: UInt8, value: UInt8)
    case controlChange(channel: UInt8, control: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case channelPressure(channel: UInt8, value: UInt8)
    /// 14-bit, 8192 = centre.
    case pitchBend(channel: UInt8, value: UInt16)
    case sysex(bytes: [UInt8], truncated: Bool)
    case realtime(status: UInt8)
    case systemCommon(status: UInt8, data1: UInt8, data2: UInt8)
    /// UMP types this monitor does not decode (MIDI 2.0, utility, ...).
    case other(firstWord: UInt32)

    public var channel: UInt8? {
        switch self {
        case let .noteOn(c, _, _), let .noteOff(c, _, _), let .polyPressure(c, _, _),
             let .controlChange(c, _, _), let .programChange(c, _), let .channelPressure(c, _), let .pitchBend(c, _):
            return c
        default: return nil
        }
    }

    public var summary: String {
        func n(_ note: UInt8) -> String { NoteName.name(note) }
        switch self {
        case let .noteOn(c, k, v): return "ch\(c + 1) Note On \(n(k)) (\(k)) vel \(v)"
        case let .noteOff(c, k, v): return "ch\(c + 1) Note Off \(n(k)) (\(k)) vel \(v)"
        case let .polyPressure(c, k, v): return "ch\(c + 1) Poly Pressure \(n(k)) \(v)"
        case let .controlChange(c, cc, v): return "ch\(c + 1) CC\(cc) = \(v)"
        case let .programChange(c, p): return "ch\(c + 1) Program \(p)"
        case let .channelPressure(c, v): return "ch\(c + 1) Channel Pressure \(v)"
        case let .pitchBend(c, v): return "ch\(c + 1) Pitch Bend \(Int(v) - 8192)"
        case let .sysex(b, t):
            let hex = b.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "SysEx \(b.count) bytes\(t ? " (truncated)" : ""): \(hex)\(b.count > 24 ? " …" : "")"
        case let .realtime(s):
            let names: [UInt8: String] = [0xF8: "Clock", 0xFA: "Start", 0xFB: "Continue", 0xFC: "Stop", 0xFE: "Active Sensing", 0xFF: "Reset"]
            return String(format: "Real-time %02X", s) + (names[s].map { " \($0)" } ?? "")
        case let .systemCommon(s, a, b): return String(format: "System %02X %02X %02X", s, a, b)
        case let .other(w): return String(format: "UMP %08X", w)
        }
    }
}

public enum NoteName {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    /// Middle C (60) = C4.
    public static func name(_ note: UInt8) -> String { "\(names[Int(note) % 12])\(Int(note) / 12 - 1)" }
}

/// Converts UMP words to messages, reassembling SysEx7 per group with a
/// hard byte limit. Not thread-safe: use one per receive callback/port.
public struct UMPDecoder {
    public let maxSysexBytes: Int
    private var sysex: [[UInt8]] = Array(repeating: [], count: 16)
    private var active = [Bool](repeating: false, count: 16)
    private var truncated = [Bool](repeating: false, count: 16)
    /// SysEx messages abandoned (missing end, or a new start).
    public private(set) var abandonedSysex = 0

    public init(maxSysexBytes: Int = 256) {
        self.maxSysexBytes = max(maxSysexBytes, 2)
    }

    /// Decode a run of UMP words (one MIDIEventPacket). Incomplete trailing
    /// packets are ignored.
    public mutating func decode(_ words: [UInt32]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let n = UMP.wordCount(w)
            guard i + n <= words.count else { break }
            let group = Int((w >> 24) & 0xF)
            switch w >> 28 {
            case 0x1:
                let s = UInt8((w >> 16) & 0xFF)
                if s >= 0xF8 { out.append(.realtime(status: s)) } else {
                    out.append(.systemCommon(status: s, data1: UInt8((w >> 8) & 0x7F), data2: UInt8(w & 0x7F)))
                }
            case 0x2:
                if let m = Self.channelVoice(w) { out.append(m) }
            case 0x3:
                if let m = sysex7(group: group, w0: w, w1: words[i + 1]) { out.append(m) }
            default:
                out.append(.other(firstWord: w))
            }
            i += n
        }
        return out
    }

    static func channelVoice(_ w: UInt32) -> MIDIMessage? {
        let status = UInt8((w >> 16) & 0xF0)
        let ch = UInt8((w >> 16) & 0x0F)
        let d1 = UInt8((w >> 8) & 0x7F)
        let d2 = UInt8(w & 0x7F)
        switch status {
        case 0x80: return .noteOff(channel: ch, note: d1, velocity: d2)
        // Note on with velocity 0 is a note off (MIDI 1.0).
        case 0x90: return d2 == 0 ? .noteOff(channel: ch, note: d1, velocity: 0) : .noteOn(channel: ch, note: d1, velocity: d2)
        case 0xA0: return .polyPressure(channel: ch, note: d1, value: d2)
        case 0xB0: return .controlChange(channel: ch, control: d1, value: d2)
        case 0xC0: return .programChange(channel: ch, program: d1)
        case 0xD0: return .channelPressure(channel: ch, value: d1)
        case 0xE0: return .pitchBend(channel: ch, value: UInt16(d2) << 7 | UInt16(d1))
        default: return nil
        }
    }

    mutating func sysex7(group g: Int, w0: UInt32, w1: UInt32) -> MIDIMessage? {
        let status = (w0 >> 20) & 0xF
        let count = min(Int((w0 >> 16) & 0xF), 6)
        let all: [UInt8] = [UInt8((w0 >> 8) & 0x7F), UInt8(w0 & 0x7F),
                            UInt8((w1 >> 24) & 0x7F), UInt8((w1 >> 16) & 0x7F),
                            UInt8((w1 >> 8) & 0x7F), UInt8(w1 & 0x7F)]
        let bytes = Array(all.prefix(count))
        func append() {
            for b in bytes {
                // Keep room for F7.
                if sysex[g].count < maxSysexBytes - 1 { sysex[g].append(b) } else { truncated[g] = true }
            }
        }
        switch status {
        case 0: // complete in one packet
            if active[g] { abandonedSysex += 1 }
            active[g] = false
            sysex[g] = [0xF0]; truncated[g] = false
            append()
            return finish(g)
        case 1: // start
            if active[g] { abandonedSysex += 1 }
            active[g] = true
            sysex[g] = [0xF0]; truncated[g] = false
            append()
            return nil
        case 2: // continue
            guard active[g] else { return nil }
            append()
            return nil
        case 3: // end
            guard active[g] else { return nil }
            active[g] = false
            append()
            return finish(g)
        default:
            return nil
        }
    }

    mutating func finish(_ g: Int) -> MIDIMessage {
        var b = sysex[g]
        b.append(0xF7)
        sysex[g] = []
        return .sysex(bytes: b, truncated: truncated[g])
    }
}
