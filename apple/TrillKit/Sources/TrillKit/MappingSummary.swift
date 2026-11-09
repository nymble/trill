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
        let scale = c[.scale] == 1 ? "pentatonic" : "chromatic"
        switch mode {
        case .touch:
            let pitch = c[.pitchMode] == 1 ? "\(scale) steps" : "gliding pitch (bend ±\(c[.bendRange]))"
            out.append(.init(input: "Touch strip", symbol: "hand.draw", output: "Notes \(range), \(pitch), \(ch(c[.channel]))"))
        case .tiltNotes:
            out.append(.init(input: "Tilt forward + roll", symbol: "level", output: "\(scale.capitalized) notes \(range), \(ch(c[.channel]))"))
        case .theremin:
            out.append(.init(input: "Tilt forward + roll", symbol: "waveform", output: "Gliding pitch from \(NoteName.name(UInt8(c[.baseNote]))), bend ±\(c[.bendRange]), \(ch(c[.channel]))"))
        }
        if mode != .touch, c[.expressionCC] > 0 {
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
        if c[.percussionEnabled] == 1 {
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
