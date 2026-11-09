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
        case telemetryStart = 0x05
        case telemetryStop = 0x06
        case helloReply = 0x41
        case config = 0x42
        case actionAck = 0x44
        case telemetryAck = 0x45
        case telemetry = 0x50
        case error = 0x7F
    }

    public static let variantPCMSynth: UInt8 = 0x01
    public static let capSetConfig: UInt8 = 0x01
    public static let capActions: UInt8 = 0x02
    public static let capPersistent: UInt8 = 0x04
    /// Sensor telemetry (firmware 0.3.0 and newer).
    public static let capTelemetry: UInt8 = 0x08
    /// Oldest firmware that streams sensor telemetry.
    public static let telemetryMinimumFirmware = "0.3.0"
    /// Paged configuration: parameters 14...30 and action 5 (firmware 0.4.0+).
    public static let capConfigPages: UInt8 = 0x10
    /// Oldest firmware with paged configuration (sensor modes, gestures).
    public static let configPagesMinimumFirmware = "0.4.0"
    /// Directional strikes: page 2, parameters 31...37 (firmware 0.5.0+).
    public static let capStrikes: UInt8 = 0x20
    /// Oldest firmware with directional strikes.
    public static let strikesMinimumFirmware = "0.5.0"
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
    /// Take the current pitch and roll as level (firmware 0.4.0+, RAM only).
    case zeroOrientation

    public var title: String {
        switch self {
        case .panic: return "MIDI panic"
        case .recalibrateGyro: return "Recalibrate gyro"
        case .ledSelfTest: return "LED self-test"
        case .restoreDefaults: return "Restore firmware defaults"
        case .zeroOrientation: return "Set current orientation as level"
        }
    }

    /// Needs `TrillProtocol.capConfigPages`.
    public var needsConfigPages: Bool { self == .zeroOrientation }
}

/// Values of `TrillParam.mode`.
public enum SensorMode: Int, CaseIterable, Sendable {
    case touch = 0, tiltNotes, theremin
    public var title: String {
        switch self {
        case .touch: return "Touch strip + motion controllers"
        case .tiltNotes: return "Tilt notes (scale steps)"
        case .theremin: return "Theremin (continuous tilt pitch)"
        }
    }
    /// Short name for the home screen and pickers.
    public var name: String {
        switch self {
        case .touch: return "Touch strip"
        case .tiltNotes: return "Tilt notes"
        case .theremin: return "Theremin"
        }
    }
    /// One sentence on how this mode plays.
    public var howItPlays: String {
        switch self {
        case .touch: return "Slide a finger along the strip to play notes; press harder for more pressure."
        case .tiltNotes: return "Tilt forward to start a note, roll left/right to step through a scale, tilt back to stop."
        case .theremin: return "Tilt forward to start a note, roll left/right to glide the pitch smoothly, tilt back to stop."
        }
    }
    public var symbol: String {
        switch self {
        case .touch: return "hand.draw"
        case .tiltNotes: return "level"
        case .theremin: return "waveform"
        }
    }
}

/// Values of `TrillParam.ccASource` / `.ccBSource`.
public enum CCSource: Int, CaseIterable, Sendable {
    case off = 0, rotation, pitchForward, pitchBack, rollRight, rollLeft, pitchCentered, rollCentered
    public var title: String {
        switch self {
        case .off: return "Off"
        case .rotation: return "Rotation speed (any axis)"
        case .pitchForward: return "Pitch forward"
        case .pitchBack: return "Pitch back (inverted)"
        case .rollRight: return "Roll right"
        case .rollLeft: return "Roll left (inverted)"
        case .pitchCentered: return "Pitch, centred (64 = level)"
        case .rollCentered: return "Roll, centred (64 = level)"
        }
    }
}

/// Configurable parameters. IDs 1...13 (page 0) exist since firmware 0.2.0;
/// IDs 14...30 (page 1) need firmware 0.4.0 (`capConfigPages`); IDs 31...37
/// (page 2, directional strikes) need firmware 0.5.0 (`capStrikes`).
public enum TrillParam: UInt8, CaseIterable, Codable, Sendable {
    case channel = 1, baseNote, rangeSemitones, scale, pitchMode, bendRange, velocityMin,
         motionEnabled, rotationFullDps, tiltFullDeg, percussionEnabled, percussionChannel, percussionNote
    case mode = 14, ccASource, ccANumber, ccBSource, ccBNumber, ccDeadzone, ccSmoothingMs,
         tiltSpanDeg, gateDeg, stepHysteresis, expressionCC, tapThresholdCg, tapCooldownMs,
         gestureAxis, gestureThresholdDps, gestureCooldownMs, gestureBaseNote
    case strikeDirections = 31, strikeNoteDown, strikeNoteUp, strikeNoteLeft, strikeNoteRight,
         strikeNoteForward, strikeNoteBack

    /// Configuration page (a `CONFIG` reply carries one page).
    public var page: Int { rawValue <= 13 ? 0 : rawValue <= 30 ? 1 : 2 }
    public static let pageCount = 3
    /// The strike note parameters, in direction order.
    public static let strikeNotes: [TrillParam] = [.strikeNoteDown, .strikeNoteUp, .strikeNoteLeft,
                                                   .strikeNoteRight, .strikeNoteForward, .strikeNoteBack]

    /// True if the device accepts `v` (range, plus even-only strike counts).
    public func accepts(_ v: Int) -> Bool {
        range.contains(v) && (self != .strikeDirections || v % 2 == 0)
    }
    public static func params(page: Int) -> [TrillParam] { allCases.filter { $0.page == page } }

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
        case .mode: return 0...2
        case .ccASource, .ccBSource: return 0...7
        case .ccANumber, .ccBNumber: return 1...119
        case .ccDeadzone: return 0...50
        case .ccSmoothingMs: return 0...500
        case .tiltSpanDeg: return 10...90
        case .gateDeg: return 5...60
        case .stepHysteresis: return 0...49
        case .expressionCC: return 0...119
        case .tapThresholdCg: return 30...400
        case .tapCooldownMs: return 50...1000
        case .gestureAxis: return 0...3
        case .gestureThresholdDps: return 100...2000
        case .gestureCooldownMs: return 100...2000
        case .gestureBaseNote: return 0...125
        case .strikeDirections: return 0...6
        case .strikeNoteDown, .strikeNoteUp, .strikeNoteLeft, .strikeNoteRight, .strikeNoteForward,
             .strikeNoteBack: return 0...127
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
        case .mode: return 0
        case .ccASource: return 1
        case .ccANumber: return 74
        case .ccBSource: return 2
        case .ccBNumber: return 1
        case .ccDeadzone: return 0
        case .ccSmoothingMs: return 0
        case .tiltSpanDeg: return 45
        case .gateDeg: return 15
        case .stepHysteresis: return 20
        case .expressionCC: return 0
        case .tapThresholdCg: return 80
        case .tapCooldownMs: return 120
        case .gestureAxis: return 0
        case .gestureThresholdDps: return 400
        case .gestureCooldownMs: return 300
        case .gestureBaseNote: return 60
        case .strikeDirections: return 0
        case .strikeNoteDown: return 38
        case .strikeNoteUp: return 49
        case .strikeNoteLeft: return 36
        case .strikeNoteRight: return 42
        case .strikeNoteForward: return 45
        case .strikeNoteBack: return 51
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
        case .mode: return "mode"
        case .ccASource: return "cc_a_source"
        case .ccANumber: return "cc_a_number"
        case .ccBSource: return "cc_b_source"
        case .ccBNumber: return "cc_b_number"
        case .ccDeadzone: return "cc_deadzone_percent"
        case .ccSmoothingMs: return "cc_smoothing_ms"
        case .tiltSpanDeg: return "tilt_span_deg"
        case .gateDeg: return "gate_deg"
        case .stepHysteresis: return "step_hysteresis_percent"
        case .expressionCC: return "expression_cc"
        case .tapThresholdCg: return "tap_threshold_cg"
        case .tapCooldownMs: return "tap_cooldown_ms"
        case .gestureAxis: return "gesture_axis"
        case .gestureThresholdDps: return "gesture_threshold_dps"
        case .gestureCooldownMs: return "gesture_cooldown_ms"
        case .gestureBaseNote: return "gesture_base_note"
        case .strikeDirections: return "strike_directions"
        case .strikeNoteDown: return "strike_note_down"
        case .strikeNoteUp: return "strike_note_up"
        case .strikeNoteLeft: return "strike_note_left"
        case .strikeNoteRight: return "strike_note_right"
        case .strikeNoteForward: return "strike_note_forward"
        case .strikeNoteBack: return "strike_note_back"
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
        set {
            var v = min(max(newValue, p.range.lowerBound), p.range.upperBound)
            if p == .strikeDirections, v % 2 == 1 { v += 1 }
            values[p] = v
        }
    }

    /// Parameters whose values differ from `other`, in ID order, limited to
    /// `pages` (all pages by default).
    public func changes(from other: DeviceConfig, pages: Set<Int>? = nil) -> [(TrillParam, Int)] {
        TrillParam.allCases.compactMap { p in
            guard pages.map({ $0.contains(p.page) }) ?? true else { return nil }
            return self[p] != other[p] ? (p, self[p]) : nil
        }
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
        public var supportsTelemetry: Bool { capabilities & TrillProtocol.capTelemetry != 0 }
        /// Parameters 14...30 and action 5 (firmware 0.4.0+).
        public var supportsConfigPages: Bool { capabilities & TrillProtocol.capConfigPages != 0 }
        /// Parameters 31...37, directional strikes (firmware 0.5.0+).
        public var supportsStrikes: Bool { supportsConfigPages && capabilities & TrillProtocol.capStrikes != 0 }
        /// Configuration pages this firmware has.
        public var pages: Set<Int> { supportsStrikes ? [0, 1, 2] : supportsConfigPages ? [0, 1] : [0] }
        public static func == (a: Hello, b: Hello) -> Bool {
            a.protocolVersion == b.protocolVersion && a.firmware == b.firmware && a.variant == b.variant
                && a.capabilities == b.capabilities && a.maxMessageLength == b.maxMessageLength
                && a.paramCount == b.paramCount && a.uptimeSeconds == b.uptimeSeconds && a.bootID == b.bootID
        }
    }

    case hello(requestID: UInt8, Hello)
    /// One page of parameters. Only that page's values in the `DeviceConfig`
    /// come from the device; the others are firmware defaults.
    case config(requestID: UInt8, generation: Int, persistent: Bool, page: Int, DeviceConfig)
    case actionAck(requestID: UInt8, TrillAction)
    /// Telemetry subscription state: rate (0 = stopped), lease, frame length, format.
    case telemetryAck(requestID: UInt8, rateHz: Int, leaseSeconds: Int, frameLength: Int, format: Int)
    case error(requestID: UInt8, code: UInt8, detail: UInt8)

    public var requestID: UInt8 {
        switch self {
        case let .hello(id, _), let .config(id, _, _, _, _), let .actionAck(id, _), let .error(id, _, _),
             let .telemetryAck(id, _, _, _, _): return id
        }
    }
}

public enum TrillCodec {
    static func header(_ type: TrillProtocol.MessageType, _ requestID: UInt8) -> [UInt8] {
        [0xF0, TrillProtocol.manufacturerID] + TrillProtocol.signature
            + [TrillProtocol.version, type.rawValue, requestID & 0x7F]
    }

    public static func hello(_ id: UInt8) -> [UInt8] { header(.hello, id) + [TrillProtocol.version, 0xF7] }
    /// Page 0 (every firmware).
    public static func getConfig(_ id: UInt8) -> [UInt8] { header(.getConfig, id) + [0xF7] }
    /// One page (pages other than 0 need `capConfigPages`).
    public static func getConfig(_ id: UInt8, page: Int) -> [UInt8] { header(.getConfig, id) + [UInt8(page & 0x7F), 0xF7] }
    public static func action(_ id: UInt8, _ a: TrillAction) -> [UInt8] { header(.action, id) + [a.rawValue, 0xF7] }
    /// `nil` if the rate is outside 1...100 Hz.
    public static func telemetryStart(_ id: UInt8, rateHz: Int) -> [UInt8]? {
        guard TelemetryFrame.rateRange.contains(rateHz) else { return nil }
        return header(.telemetryStart, id) + [UInt8(rateHz), 0xF7]
    }
    public static func telemetryStop(_ id: UInt8) -> [UInt8] { header(.telemetryStop, id) + [0xF7] }

    /// `nil` if empty, too many values, or a value is out of range (the app
    /// never sends a request the device would reject for range).
    public static func setConfig(_ id: UInt8, _ values: [(TrillParam, Int)]) -> [UInt8]? {
        guard !values.isEmpty, values.count <= TrillProtocol.maxSetParams else { return nil }
        guard Set(values.map(\.0)).count == values.count else { return nil }
        var m = header(.setConfig, id)
        for (p, v) in values {
            guard p.accepts(v) else { return nil }
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
                guard param.accepts(v), !seen.contains(param) else { return nil }
                seen.insert(param)
                cfg[param] = v
            }
            // Exactly one complete page.
            guard let page = seen.first?.page, Set(TrillParam.params(page: page)) == seen else { return nil }
            return .config(requestID: id, generation: u14(p[0], p[1]), persistent: p[2] != 0, page: page, cfg)
        case .actionAck:
            guard p.count == 1, let a = TrillAction(rawValue: p[0]) else { return nil }
            return .actionAck(requestID: id, a)
        case .telemetryAck:
            guard p.count == 4 else { return nil }
            return .telemetryAck(requestID: id, rateHz: Int(p[0]), leaseSeconds: Int(p[1]), frameLength: Int(p[2]), format: Int(p[3]))
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
