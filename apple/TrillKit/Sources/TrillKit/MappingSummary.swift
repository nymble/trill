// SPDX-License-Identifier: GPL-3.0-only
//
// Plain-language description of a parameter set: what each input does and
// which MIDI it sends. Shown on the home screen and at the top of the mapping
// editor so the configuration reads as "input → processing → MIDI".

import Foundation

/// Direction of a strike, in `TrillParam.strikeNotes` order.
public enum StrikeDirection: Int, CaseIterable, Sendable {
    case down = 0, up, left, right, forward, back
    public var name: String {
        switch self {
        case .down: return "Down"
        case .up: return "Up"
        case .left: return "Left"
        case .right: return "Right"
        case .forward: return "Forward"
        case .back: return "Back"
        }
    }
    public var symbol: String {
        switch self {
        case .down: return "arrow.down"
        case .up: return "arrow.up"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .forward: return "arrow.up.forward"
        case .back: return "arrow.down.backward"
        }
    }
    public var param: TrillParam { TrillParam.strikeNotes[rawValue] }
    /// Tilt-strike mode: chord tone this direction adds.
    public var chordTone: String {
        switch self {
        case .down: return "the note"
        case .up: return "octave"
        case .left: return "third"
        case .right: return "fifth"
        case .forward: return "second"
        case .back: return "octave below"
        }
    }
    /// The direction a percussion note-on came from, if the configuration
    /// gives that note to exactly one active direction. `nil` for the
    /// "unclear" note, plain taps, other channels or shared notes.
    public static func matching(channel: Int, note: Int, config c: DeviceConfig) -> StrikeDirection? {
        guard c[.percussionEnabled] == 1, channel == c[.percussionChannel] else { return nil }
        let hits = active(c[.strikeDirections]).filter { c[$0.param] == note }
        return hits.count == 1 ? hits[0] : nil
    }
    /// Directions active for a `strikeDirections` value (0, 2, 4 or 6).
    public static func active(_ count: Int) -> [StrikeDirection] { Array(allCases.prefix(max(0, min(count, 6)))) }
}

public struct RoutingLine: Hashable, Sendable {
    /// What the player does.
    public let input: String
    /// SF Symbol for the input.
    public let symbol: String
    /// What it sends.
    public let output: String
}

public enum MappingSummary {
    static func ch(_ c: Int) -> String { "ch \(c + 1)" }
    static func note(_ n: Int) -> String { "\(NoteName.name(UInt8(n))) (\(n))" }
    static func cc(_ n: Int) -> String {
        switch n {
        case 1: return "CC1 modulation"
        case 7: return "CC7 volume"
        case 11: return "CC11 expression"
        case 74: return "CC74 brightness"
        default: return "CC\(n)"
        }
    }

    /// One line per active input. `pages` limits the description to what
    /// the device has (nil = everything).
    public static func lines(_ c: DeviceConfig, pages: Set<Int>? = nil) -> [RoutingLine] {
        let has = { (p: Int) in pages?.contains(p) ?? true }
        var out: [RoutingLine] = []
        let mode = has(1) ? SensorMode(rawValue: c[.mode]) ?? .touch : .touch
        let top = min(127, c[.baseNote] + c[.rangeSemitones])
        let range = "\(NoteName.name(UInt8(c[.baseNote])))–\(NoteName.name(UInt8(top)))"
        let scale = ScaleKind(rawValue: c[.scale])?.name.lowercased() ?? "chromatic"
        switch mode {
        case .touch:
            let pitch = c[.pitchMode] == 1 ? "\(scale) steps" : "gliding pitch (bend ±\(c[.bendRange]))"
            out.append(.init(input: "Touch strip", symbol: "hand.draw", output: "Notes \(range), \(pitch), \(ch(c[.channel]))"))
        case .tiltNotes:
            out.append(.init(input: "Tilt forward + roll", symbol: "level", output: "\(scale.capitalized) notes \(range), \(ch(c[.channel]))"))
        case .theremin:
            out.append(.init(input: "Tilt forward + roll", symbol: "waveform", output: "Gliding pitch from \(NoteName.name(UInt8(c[.baseNote]))), bend ±\(c[.bendRange]), \(ch(c[.channel]))"))
        case .tiltStrike:
            let t = TiltStrike(c)
            out.append(.init(input: "Roll", symbol: "arrow.left.and.right",
                             output: "Chooses 1 of \(t.zoneCount) \(scale) notes \(range)\(c[.zoneCurve] == 1 ? ", finer near level" : "")"))
            if c[.registerTilt] == 1 {
                out.append(.init(input: "Tilt forward / back", symbol: "arrow.up.and.down", output: "Octave up / down (past \(c[.gateDeg])°)"))
            }
            out.append(.init(input: "Strike or tap", symbol: "hand.tap", output: "Plays the chosen note, \(ch(c[.channel])), \(c[.noteLengthMs]) ms"))
            if c[.strikeVoicing] == 1, has(2) {
                let dirs = StrikeDirection.active(c[.strikeDirections]).filter { $0 != .down }
                if !dirs.isEmpty {
                    out.append(.init(input: "Strike direction", symbol: "arrow.up.and.down.and.arrow.left.and.right",
                                     output: dirs.map { "\($0.name.lowercased()) = \($0.chordTone)" }.joined(separator: ", ")))
                }
            }
        }
        if mode != .touch, mode != .tiltStrike, c[.expressionCC] > 0 {
            out.append(.init(input: "Tilt depth", symbol: "arrow.down.forward", output: cc(c[.expressionCC])))
        }
        if c[.motionEnabled] == 1 {
            let sources: [(TrillParam, TrillParam)] = has(1) ? [(.ccASource, .ccANumber), (.ccBSource, .ccBNumber)] : []
            if sources.isEmpty {
                out.append(.init(input: "Rotation speed", symbol: "rotate.3d", output: cc(74)))
                out.append(.init(input: "Pitch forward", symbol: "arrow.down.forward", output: cc(1)))
            }
            for (s, n) in sources {
                guard let src = CCSource(rawValue: c[s]), src != .off else { continue }
                out.append(.init(input: src.title, symbol: src == .rotation ? "rotate.3d" : "arrow.triangle.2.circlepath", output: cc(c[n])))
            }
        }
        if c[.percussionEnabled] == 1, mode != .tiltStrike {
            let dirs = has(2) ? StrikeDirection.active(c[.strikeDirections]) : []
            if dirs.isEmpty {
                out.append(.init(input: "Tap", symbol: "hand.tap", output: "\(note(c[.percussionNote])), \(ch(c[.percussionChannel]))"))
            } else {
                let notes = dirs.map { "\($0.name.lowercased()) \(c[$0.param])" }.joined(separator: ", ")
                out.append(.init(input: "Strike in \(dirs.count) directions", symbol: "arrow.up.and.down.and.arrow.left.and.right",
                                 output: "Notes \(notes), \(ch(c[.percussionChannel]))"))
            }
        }
        if has(1), c[.gestureAxis] > 0 {
            let b = c[.gestureBaseNote]
            out.append(.init(input: "Flick / zig-zag", symbol: "wind", output: "Notes \(b), \(b + 1), \(b + 2), \(ch(c[.percussionChannel]))"))
        }
        return out
    }
}

/// Values of `TrillParam.scale`.
public enum ScaleKind: Int, CaseIterable, Sendable {
    case chromatic = 0, pentatonic, major, minor
    public var name: String {
        switch self {
        case .chromatic: return "Chromatic"
        case .pentatonic: return "Pentatonic"
        case .major: return "Major"
        case .minor: return "Minor"
        }
    }
    /// Needs firmware 0.5.0.
    public var needsStrikes: Bool { rawValue >= 2 }
    public var degrees: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .pentatonic: return [0, 2, 4, 7, 9]
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        }
    }
    /// Semitones of scale step `i` (any integer).
    public func offset(_ i: Int) -> Int {
        let n = degrees.count
        let q = Int((Double(i) / Double(n)).rounded(.down))
        return q * 12 + degrees[i - q * n]
    }
    /// Scale steps nearest to `semitones` (third = 2 steps in major).
    public func steps(for semitones: Int) -> Int {
        let n = degrees.count
        return (semitones * n * 2 + 12 * semitones.signum()) / 24
    }
}

/// The firmware's tilt-strike note choice (instrument_events
/// `Mode::TiltStrike`), without hysteresis, for the app's displays.
public struct TiltStrike: Sendable {
    public let scale: ScaleKind
    public let base: Int
    public let zoneCount: Int
    public let span: Double
    public let quadratic: Bool
    public let gate: Double
    public let register: Bool

    public init(_ c: DeviceConfig) {
        scale = ScaleKind(rawValue: c[.scale]) ?? .chromatic
        base = c[.baseNote]
        span = Double(c[.tiltSpanDeg])
        quadratic = c[.zoneCurve] == 1
        gate = Double(c[.gateDeg])
        register = c[.registerTilt] == 1
        var n = 0
        while n < 128, scale.offset(n) <= c[.rangeSemitones] { n += 1 }
        zoneCount = max(n, 1)
    }

    /// Zone position 0...zoneCount for a roll angle.
    public func position(roll: Double) -> Double {
        let x = max(-1, min(1, roll / span))
        let y = quadratic ? (x < 0 ? -1 : 1) * abs(x).squareRoot() : x
        return (y + 1) / 2 * Double(zoneCount)
    }

    public func zone(roll: Double) -> Int { min(zoneCount - 1, max(0, Int(position(roll: roll)))) }

    /// Roll angle of the edge between zone `k - 1` and `k` (0...zoneCount).
    public func edge(_ k: Int) -> Double {
        let y = Double(k) / Double(zoneCount) * 2 - 1
        let x = quadratic ? (y < 0 ? -1 : 1) * y * y : y
        return x * span
    }

    public func octave(pitch: Double) -> Int {
        guard register else { return 0 }
        return pitch >= gate ? 1 : pitch <= -gate ? -1 : 0
    }

    public func note(zone: Int, octave: Int = 0, direction: StrikeDirection? = nil, voicing: Bool = false) -> Int {
        let n = scale.degrees.count
        let extra: Int
        switch voicing ? direction : nil {
        case nil, .down?: extra = 0
        case .up?: extra = n
        case .left?: extra = scale.steps(for: 4)
        case .right?: extra = scale.steps(for: 7)
        case .forward?: extra = scale.steps(for: 2)
        case .back?: extra = -n
        }
        return max(0, min(127, base + scale.offset(zone + extra) + 12 * octave))
    }
}
