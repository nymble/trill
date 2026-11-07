// SPDX-License-Identifier: GPL-3.0-only
//
// Trill configuration protocol v1 (docs/config-protocol.md). This is a
// Swift implementation of the same wire format as the Rust `trill-config`
// crate; both are checked against protocol/config-v1-vectors.txt.

import Foundation

public enum TrillProtocol {
    /// MIDI non-commercial / educational manufacturer ID. Development only.
    public static let manufacturerID: UInt8 = 0x7D
    public static let signature: [UInt8] = [0x54, 0x52]
    public static let version: UInt8 = 1
    public static let maxMessageLength = 64
    public static let headerLength = 7
    public static let maxSetParams = 16
    /// Default reply timeout used by `ConfigSession`.
    public static let replyTimeout: TimeInterval = 1.0

    public enum MessageType: UInt8 {
        case hello = 0x01
        case getConfig = 0x02
        case setConfig = 0x03
        case action = 0x04
        case helloReply = 0x41
        case config = 0x42
        case actionAck = 0x44
        case error = 0x7F
    }

    public static let variantPCMSynth: UInt8 = 0x01
    public static let capSetConfig: UInt8 = 0x01
    public static let capActions: UInt8 = 0x02
    public static let capPersistent: UInt8 = 0x04
}

/// Device-side error codes.
public enum TrillErrorCode: UInt8, CaseIterable, Sendable {
    case badVersion = 1, unknownType, badLength, unknownParam, outOfRange, tooLong, unknownAction, duplicateParam

    public var summary: String {
        switch self {
        case .badVersion: return "unsupported protocol version"
        case .unknownType: return "unknown request type"
        case .badLength: return "malformed request length"
        case .unknownParam: return "unknown parameter"
        case .outOfRange: return "value out of range"
        case .tooLong: return "request longer than 64 bytes"
        case .unknownAction: return "unknown action"
        case .duplicateParam: return "parameter repeated in one request"
        }
    }
}

/// Actions the firmware implements.
public enum TrillAction: UInt8, CaseIterable, Sendable {
    case panic = 1, recalibrateGyro, ledSelfTest, restoreDefaults

    public var title: String {
        switch self {
        case .panic: return "MIDI panic"
        case .recalibrateGyro: return "Recalibrate gyro"
        case .ledSelfTest: return "LED self-test"
        case .restoreDefaults: return "Restore firmware defaults"
        }
    }
}

/// Configurable parameters (IDs, ranges and defaults as in firmware 0.2.0).
public enum TrillParam: UInt8, CaseIterable, Codable, Sendable {
    case channel = 1, baseNote, rangeSemitones, scale, pitchMode, bendRange, velocityMin,
         motionEnabled, rotationFullDps, tiltFullDeg, percussionEnabled, percussionChannel, percussionNote

    public var range: ClosedRange<Int> {
        switch self {
        case .channel, .percussionChannel: return 0...15
        case .baseNote, .percussionNote: return 0...127
        case .rangeSemitones: return 1...96
        case .scale, .pitchMode, .motionEnabled, .percussionEnabled: return 0...1
        case .bendRange: return 1...24
        case .velocityMin: return 1...127
        case .rotationFullDps: return 30...2000
        case .tiltFullDeg: return 5...90
        }
    }

    /// Firmware default (instrument_events::Config::default()).
    public var defaultValue: Int {
        switch self {
        case .channel: return 0
        case .baseNote: return 48
        case .rangeSemitones: return 24
        case .scale: return 0
        case .pitchMode: return 0
        case .bendRange: return 24
        case .velocityMin: return 30
        case .motionEnabled: return 1
        case .rotationFullDps: return 360
        case .tiltFullDeg: return 60
        case .percussionEnabled: return 0
        case .percussionChannel: return 9
        case .percussionNote: return 39
        }
    }

    /// Stable key for preset files.
    public var key: String {
        switch self {
        case .channel: return "channel"
        case .baseNote: return "base_note"
        case .rangeSemitones: return "range_semitones"
        case .scale: return "scale"
        case .pitchMode: return "pitch_mode"
        case .bendRange: return "bend_range_semitones"
        case .velocityMin: return "velocity_min"
        case .motionEnabled: return "motion_enabled"
        case .rotationFullDps: return "rotation_full_dps"
        case .tiltFullDeg: return "tilt_full_deg"
        case .percussionEnabled: return "percussion_enabled"
        case .percussionChannel: return "percussion_channel"
        case .percussionNote: return "percussion_note"
        }
    }

    public static func from(key: String) -> TrillParam? { allCases.first { $0.key == key } }
}

/// A complete parameter set. Values are always within each parameter's range.
public struct DeviceConfig: Equatable, Hashable, Sendable {
    public private(set) var values: [TrillParam: Int]

    public init() {
        values = Dictionary(uniqueKeysWithValues: TrillParam.allCases.map { ($0, $0.defaultValue) })
    }

    public static let firmwareDefaults = DeviceConfig()

    public subscript(p: TrillParam) -> Int {
        get { values[p] ?? p.defaultValue }
        set { values[p] = min(max(newValue, p.range.lowerBound), p.range.upperBound) }
    }

    /// Parameters whose values differ from `other`, in ID order.
    public func changes(from other: DeviceConfig) -> [(TrillParam, Int)] {
        TrillParam.allCases.compactMap { self[$0] != other[$0] ? ($0, self[$0]) : nil }
    }
}

/// A decoded device reply.
public enum TrillReply: Equatable, Sendable {
    public struct Hello: Equatable, Sendable {
        public var protocolVersion: Int
        public var firmware: (Int, Int, Int)
        public var variant: UInt8
        public var capabilities: UInt8
        public var maxMessageLength: Int
        public var paramCount: Int
        public var uptimeSeconds: Int
        public var bootID: Int
        public var firmwareString: String { "\(firmware.0).\(firmware.1).\(firmware.2)" }
        public var isPCMSynthBuild: Bool { variant & TrillProtocol.variantPCMSynth != 0 }
        public var persistent: Bool { capabilities & TrillProtocol.capPersistent != 0 }
        public static func == (a: Hello, b: Hello) -> Bool {
            a.protocolVersion == b.protocolVersion && a.firmware == b.firmware && a.variant == b.variant
                && a.capabilities == b.capabilities && a.maxMessageLength == b.maxMessageLength
                && a.paramCount == b.paramCount && a.uptimeSeconds == b.uptimeSeconds && a.bootID == b.bootID
        }
    }

    case hello(requestID: UInt8, Hello)
    case config(requestID: UInt8, generation: Int, persistent: Bool, DeviceConfig)
    case actionAck(requestID: UInt8, TrillAction)
    case error(requestID: UInt8, code: UInt8, detail: UInt8)

    public var requestID: UInt8 {
        switch self {
        case let .hello(id, _), let .config(id, _, _, _), let .actionAck(id, _), let .error(id, _, _): return id
        }
    }
}

public enum TrillCodec {
    static func header(_ type: TrillProtocol.MessageType, _ requestID: UInt8) -> [UInt8] {
        [0xF0, TrillProtocol.manufacturerID] + TrillProtocol.signature
            + [TrillProtocol.version, type.rawValue, requestID & 0x7F]
    }

    public static func hello(_ id: UInt8) -> [UInt8] { header(.hello, id) + [TrillProtocol.version, 0xF7] }
    public static func getConfig(_ id: UInt8) -> [UInt8] { header(.getConfig, id) + [0xF7] }
    public static func action(_ id: UInt8, _ a: TrillAction) -> [UInt8] { header(.action, id) + [a.rawValue, 0xF7] }

    /// `nil` if empty, too many values, or a value is out of range (the app
    /// never sends a request the device would reject for range).
    public static func setConfig(_ id: UInt8, _ values: [(TrillParam, Int)]) -> [UInt8]? {
        guard !values.isEmpty, values.count <= TrillProtocol.maxSetParams else { return nil }
        guard Set(values.map(\.0)).count == values.count else { return nil }
        var m = header(.setConfig, id)
        for (p, v) in values {
            guard p.range.contains(v) else { return nil }
            m += [p.rawValue, UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
        }
        return m + [0xF7]
    }

    /// Decode a complete SysEx message. Returns `nil` for anything that is
    /// not a well-formed v1 reply from a Trill (including requests).
    public static func decodeReply(_ m: [UInt8]) -> TrillReply? {
        guard m.count >= TrillProtocol.headerLength + 1, m.count <= TrillProtocol.maxMessageLength,
              m.first == 0xF0, m.last == 0xF7, m[1] == TrillProtocol.manufacturerID,
              Array(m[2...3]) == TrillProtocol.signature, m[4] == TrillProtocol.version,
              m[1..<(m.count - 1)].allSatisfy({ $0 < 0x80 })
        else { return nil }
        let id = m[6]
        let p = Array(m[TrillProtocol.headerLength..<(m.count - 1)])
        let u14 = { (hi: UInt8, lo: UInt8) in Int(hi) << 7 | Int(lo) }
        switch TrillProtocol.MessageType(rawValue: m[5]) {
        case .helloReply:
            guard p.count == 13 else { return nil }
            return .hello(requestID: id, .init(
                protocolVersion: Int(p[0]), firmware: (Int(p[1]), Int(p[2]), Int(p[3])),
                variant: p[4], capabilities: p[5], maxMessageLength: Int(p[6]), paramCount: Int(p[7]),
                uptimeSeconds: Int(p[8]) << 14 | Int(p[9]) << 7 | Int(p[10]), bootID: u14(p[11], p[12])))
        case .config:
            guard p.count >= 3, (p.count - 3) % 3 == 0 else { return nil }
            var cfg = DeviceConfig()
            var seen = Set<TrillParam>()
            for i in stride(from: 3, to: p.count, by: 3) {
                // Unknown IDs (newer firmware) are skipped, not fatal.
                guard let param = TrillParam(rawValue: p[i]) else { continue }
                let v = u14(p[i + 1], p[i + 2])
                guard param.range.contains(v), !seen.contains(param) else { return nil }
                seen.insert(param)
                cfg[param] = v
            }
            guard seen.count == TrillParam.allCases.count else { return nil }
            return .config(requestID: id, generation: u14(p[0], p[1]), persistent: p[2] != 0, cfg)
        case .actionAck:
            guard p.count == 1, let a = TrillAction(rawValue: p[0]) else { return nil }
            return .actionAck(requestID: id, a)
        case .error:
            guard p.count == 2 else { return nil }
            return .error(requestID: id, code: p[0], detail: p[1])
        default:
            return nil
        }
    }

    /// True if `m` looks like a Trill protocol message (request or reply).
    public static func isTrillSysEx(_ m: [UInt8]) -> Bool {
        m.count >= 4 && m[0] == 0xF0 && m[1] == TrillProtocol.manufacturerID && Array(m[2...3]) == TrillProtocol.signature
    }
}
