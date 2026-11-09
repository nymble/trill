// SPDX-License-Identifier: GPL-3.0-only
//
// Built-in mapping presets shown on the Mapping tab. Applying one only fills
// the editor; "Apply to device" sends it (RAM only on the device). Presets
// that use sensor modes, configurable controllers, tap sensitivity or
// gestures need firmware 0.4.0; on older firmware only their page-0 part is
// sent and the app says so.

import Foundation

public struct BuiltInPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let config: DeviceConfig

    /// True if any value differs from the firmware default on page 1.
    public var needsConfigPages: Bool { !config.changes(from: .firmwareDefaults, pages: [1]).isEmpty }

    static func make(_ id: String, _ name: String, _ summary: String, _ values: [TrillParam: Int]) -> BuiltInPreset {
        var c = DeviceConfig.firmwareDefaults
        for (p, v) in values { c[p] = v }
        return BuiltInPreset(id: id, name: name, summary: summary, config: c)
    }

    public static let all: [BuiltInPreset] = [
        make("default", "Default: touch + motion",
             "Trill strip plays notes (bend), rotation speed → CC74, forward tilt → CC1. Firmware defaults.", [:]),
        make("tilt-scale", "Tilt scale",
             "Tilt forward past the gate to play; roll left/right picks pentatonic notes over two octaves. Trill touch ignored.",
             [.mode: SensorMode.tiltNotes.rawValue, .scale: 1, .pitchMode: 1, .baseNote: 48, .rangeSemitones: 24,
              .motionEnabled: 0, .tiltSpanDeg: 45, .gateDeg: 15, .stepHysteresis: 25]),
        make("theremin", "Theremin",
             "Tilt forward to sound; roll glides pitch continuously (±24 st bend, set the synth's bend range to 24). Forward tilt depth → CC11 expression, rotation → CC74.",
             [.mode: SensorMode.theremin.rawValue, .scale: 0, .baseNote: 48, .rangeSemitones: 24, .bendRange: 24,
              .motionEnabled: 1, .ccASource: CCSource.rotation.rawValue, .ccANumber: 74, .ccBSource: CCSource.off.rawValue,
              .expressionCC: 11, .ccSmoothingMs: 30, .gateDeg: 15, .tiltSpanDeg: 45]),
        make("expressive-cc", "Expressive controllers",
             "Touch strip as default; roll (centred) → CC74 brightness, forward tilt → CC1 mod wheel, small deadzone and 40 ms smoothing.",
             [.ccASource: CCSource.rollCentered.rawValue, .ccANumber: 74, .ccBSource: CCSource.pitchForward.rawValue,
              .ccBNumber: 1, .ccDeadzone: 5, .ccSmoothingMs: 40]),
        make("percussion", "Tap percussion",
             "Default mapping plus tap → note 39 (hand clap) on channel 10, slightly more sensitive.",
             [.percussionEnabled: 1, .percussionChannel: 9, .percussionNote: 39, .tapThresholdCg: 60, .tapCooldownMs: 100]),
        make("flick-gestures", "Flick gestures (experimental)",
             "Default mapping plus flick gestures about the sensor Z axis on channel 10: one way → note 60, the other → 61, quick back-and-forth (zig-zag) → 62.",
             [.gestureAxis: 3, .gestureThresholdDps: 400, .gestureCooldownMs: 300, .gestureBaseNote: 60]),
    ]
}
