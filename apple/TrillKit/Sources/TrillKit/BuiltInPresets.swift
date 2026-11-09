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
    public var needsStrikes: Bool { usedPages.contains(2) }
    /// Oldest firmware that plays this preset completely (nil = any).
    public var minimumFirmware: String? {
        needsStrikes ? TrillProtocol.strikesMinimumFirmware
            : needsConfigPages ? TrillProtocol.configPagesMinimumFirmware : nil
    }

    static func make(_ id: String, _ name: String, _ symbol: String, _ summary: String,
                     _ values: [TrillParam: Int]) -> BuiltInPreset {
        var c = DeviceConfig.firmwareDefaults
        for (p, v) in values { c[p] = v }
        return BuiltInPreset(id: id, name: name, summary: summary, symbol: symbol, config: c)
    }

    public static let all: [BuiltInPreset] = [
        make("default", "Touch strip", "hand.draw",
             "Slide a finger along the strip to play. Turning the instrument brightens the sound (CC74); tilting it forward adds modulation (CC1).", [:]),
        make("tilt-scale", "Tilt scale", "level",
             "Tilt forward to play; roll left and right to pick notes from a pentatonic scale over two octaves. No strip needed.",
             [.mode: SensorMode.tiltNotes.rawValue, .scale: 1, .pitchMode: 1, .baseNote: 48, .rangeSemitones: 24,
              .motionEnabled: 0, .tiltSpanDeg: 45, .gateDeg: 15, .stepHysteresis: 25]),
        make("theremin", "Theremin", "waveform",
             "Tilt forward to sound; roll glides the pitch smoothly. Tilt depth controls volume (CC11). Set your synth's pitch-bend range to ±24.",
             [.mode: SensorMode.theremin.rawValue, .scale: 0, .baseNote: 48, .rangeSemitones: 24, .bendRange: 24,
              .motionEnabled: 1, .ccASource: CCSource.rotation.rawValue, .ccANumber: 74, .ccBSource: CCSource.off.rawValue,
              .expressionCC: 11, .ccSmoothingMs: 30, .gateDeg: 15, .tiltSpanDeg: 45]),
        make("expressive-cc", "Touch + expression", "slider.horizontal.3",
             "Play on the strip; rolling left/right sweeps brightness (CC74) and tilting forward adds modulation (CC1), smoothed.",
             [.ccASource: CCSource.rollCentered.rawValue, .ccANumber: 74, .ccBSource: CCSource.pitchForward.rawValue,
              .ccBNumber: 1, .ccDeadzone: 5, .ccSmoothingMs: 40]),
        make("percussion", "Tap drum", "hand.tap",
             "Play on the strip, and tap the instrument for a hand clap on the drum channel (10).",
             [.percussionEnabled: 1, .percussionChannel: 9, .percussionNote: 39, .tapThresholdCg: 60, .tapCooldownMs: 100]),
        make("drum-strikes", "Drum strikes", "arrow.up.and.down.and.arrow.left.and.right",
             "Strike in different directions to play different drums: down = snare, up = crash, left = kick, right = hi-hat (channel 10).",
             [.percussionEnabled: 1, .percussionChannel: 9, .percussionNote: 39, .tapThresholdCg: 70, .tapCooldownMs: 90,
              .strikeDirections: 4, .strikeNoteDown: 38, .strikeNoteUp: 49, .strikeNoteLeft: 36, .strikeNoteRight: 42,
              .motionEnabled: 0]),
        make("flick-gestures", "Flick gestures", "wind",
             "Play on the strip; flick your wrist one way or the other for two drum notes, and back-and-forth (a zig-zag) for a third.",
             [.gestureAxis: 3, .gestureThresholdDps: 400, .gestureCooldownMs: 300, .gestureBaseNote: 60]),
    ]
}
