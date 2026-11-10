// SPDX-License-Identifier: GPL-3.0-only
//
// Built-in presets, shown together with the user's saved presets. Choosing
// one fills the editor and, when a device is connected, applies it (RAM only
// on the device). Presets that use settings an older firmware lacks are sent
// without those settings, and the app says which update they need.

import Foundation

public struct BuiltInPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    /// SF Symbol name for the preset card.
    public let symbol: String
    public let config: DeviceConfig

    /// Pages holding a value that differs from the firmware default.
    public var usedPages: Set<Int> {
        Set(config.changes(from: .firmwareDefaults).map(\.0.page))
    }
    /// True if any value differs from the firmware default on page 1.
    public var needsConfigPages: Bool { usedPages.contains(1) }
    /// True if the preset uses directional strikes (page 2).
    public var needsStrikes: Bool {
        usedPages.contains(2) || config.changes(from: .firmwareDefaults).contains { $0.0.requiresStrikes($0.1) }
    }
    /// Oldest firmware that plays this preset completely (nil = any).
    public var minimumFirmware: String? {
        needsStrikes ? TrillProtocol.strikesMinimumFirmware
            : needsConfigPages ? TrillProtocol.configPagesMinimumFirmware : nil
    }

    /// The same preset with the user's refined values.
    public func with(config: DeviceConfig) -> BuiltInPreset {
        BuiltInPreset(id: id, name: name, summary: summary, symbol: symbol, config: config)
    }

    static func make(_ id: String, _ name: String, _ symbol: String, _ summary: String,
                     _ values: [TrillParam: Int]) -> BuiltInPreset {
        var c = DeviceConfig.firmwareDefaults
        for (p, v) in values { c[p] = v }
        return BuiltInPreset(id: id, name: name, summary: summary, symbol: symbol, config: c)
    }

    /// Motion-only sounds first (they play without the touch strip), then
    /// the strip presets. The tilt + strike sounds follow the motion-mapping
    /// report: roll selects, a strike plays (selection and excitation
    /// separated), about one octave of 5-8 notes, zones finer near level.
    public static let all: [BuiltInPreset] = [
        make("tilt-melody", "Tilt melody", "music.note",
             "Roll to choose a note from a pentatonic scale, then tap or strike to play it in time. Tilt forward or back for an octave up or down.",
             [.mode: SensorMode.tiltStrike.rawValue, .scale: ScaleKind.pentatonic.rawValue, .baseNote: 60, .rangeSemitones: 12,
              .motionEnabled: 0, .tiltSpanDeg: 45, .gateDeg: 20, .stepHysteresis: 25,
              .tapThresholdCg: 60, .tapCooldownMs: 70, .noteLengthMs: 350,
              .registerTilt: 1, .zoneCurve: 1, .strikeVoicing: 0]),
        make("strum-chords", "Strum chords", "pianokeys",
             "Roll picks the chord root in C major. Strike down for the root, left for the third, right for the fifth, up for the octave: arpeggios and broken chords.",
             [.mode: SensorMode.tiltStrike.rawValue, .scale: ScaleKind.major.rawValue, .baseNote: 60, .rangeSemitones: 12,
              .motionEnabled: 0, .tiltSpanDeg: 45, .gateDeg: 20, .stepHysteresis: 25,
              .tapThresholdCg: 60, .tapCooldownMs: 60, .noteLengthMs: 700,
              .registerTilt: 1, .zoneCurve: 1, .strikeVoicing: 1, .strikeDirections: 4]),
        make("minor-bass", "Minor bass", "speaker.wave.2",
             "A short, punchy bass line in A minor: roll for the note, strike down for it, up for the octave. Keep a steady wrist rhythm.",
             [.mode: SensorMode.tiltStrike.rawValue, .scale: ScaleKind.minor.rawValue, .baseNote: 45, .rangeSemitones: 12,
              .motionEnabled: 0, .tiltSpanDeg: 40, .gateDeg: 25, .stepHysteresis: 25,
              .tapThresholdCg: 55, .tapCooldownMs: 60, .noteLengthMs: 180,
              .registerTilt: 1, .zoneCurve: 1, .strikeVoicing: 1, .strikeDirections: 2]),
        make("drum-strikes", "Drum strikes", "arrow.up.and.down.and.arrow.left.and.right",
             "Strike in different directions to play different drums: down = snare, up = crash, left = kick, right = hi-hat (channel 10).",
             [.percussionEnabled: 1, .percussionChannel: 9, .percussionNote: 39, .tapThresholdCg: 60, .tapCooldownMs: 70,
              .strikeDirections: 4, .strikeNoteDown: 38, .strikeNoteUp: 49, .strikeNoteLeft: 36, .strikeNoteRight: 42,
              .motionEnabled: 0]),
        make("percussion", "Tap drum", "hand.tap",
             "Tap the instrument for a hand clap on the drum channel (10); with the strip attached, play notes on it too.",
             [.percussionEnabled: 1, .percussionChannel: 9, .percussionNote: 39, .tapThresholdCg: 60, .tapCooldownMs: 80]),
        make("tilt-scale", "Tilt scale", "level",
             "Tilt forward to sound a note and hold it; roll left and right to step through one octave of a pentatonic scale.",
             [.mode: SensorMode.tiltNotes.rawValue, .scale: 1, .pitchMode: 1, .baseNote: 60, .rangeSemitones: 12,
              .motionEnabled: 0, .tiltSpanDeg: 45, .gateDeg: 15, .stepHysteresis: 25]),
        make("theremin", "Theremin", "waveform",
             "Tilt forward to sound; roll glides the pitch smoothly. Tilt depth controls volume (CC11). Set your synth's pitch-bend range to ±24.",
             [.mode: SensorMode.theremin.rawValue, .scale: 0, .baseNote: 48, .rangeSemitones: 24, .bendRange: 24,
              .motionEnabled: 1, .ccASource: CCSource.rotation.rawValue, .ccANumber: 74, .ccBSource: CCSource.off.rawValue,
              .expressionCC: 11, .ccSmoothingMs: 30, .gateDeg: 15, .tiltSpanDeg: 45]),
        make("default", "Touch strip", "hand.draw",
             "Slide a finger along the strip to play. Turning the instrument brightens the sound (CC74); tilting it forward adds modulation (CC1).", [:]),
        make("expressive-cc", "Touch + expression", "slider.horizontal.3",
             "Play on the strip; rolling left/right sweeps brightness (CC74) and tilting forward adds modulation (CC1), smoothed.",
             [.ccASource: CCSource.rollCentered.rawValue, .ccANumber: 74, .ccBSource: CCSource.pitchForward.rawValue,
              .ccBNumber: 1, .ccDeadzone: 5, .ccSmoothingMs: 40]),
        make("flick-gestures", "Flick gestures", "wind",
             "Flick your wrist one way or the other for two drum notes, and back-and-forth (a zig-zag) for a third.",
             [.gestureAxis: 3, .gestureThresholdDps: 400, .gestureCooldownMs: 300, .gestureBaseNote: 60]),
    ]
}
