// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TrillKit

struct ParamStepper: View {
    @EnvironmentObject var model: AppModel
    let param: TrillParam
    let label: String
    var step = 1
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        let binding = Binding(get: { model.draft[param] }, set: { model.draft[param] = $0 })
        HStack {
            Stepper(value: binding, in: param.range, step: step) {
                Text("\(label): \(format(model.draft[param]))")
            }
            AckBadge(param: param, format: format)
        }
        .disabled(model.session.unsupported(param))
    }
}

struct AckBadge: View {
    @EnvironmentObject var model: AppModel
    let param: TrillParam
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        if let a = model.session.acknowledged, a[param] != model.draft[param] {
            Text("device: \(format(a[param]))").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct ParamToggle: View {
    @EnvironmentObject var model: AppModel
    let param: TrillParam
    let label: String

    var body: some View {
        HStack {
            Toggle(label, isOn: Binding(get: { model.draft[param] == 1 }, set: { model.draft[param] = $0 ? 1 : 0 }))
            AckBadge(param: param) { $0 == 1 ? "on" : "off" }
        }
        .disabled(model.session.unsupported(param))
    }
}

struct ParamChoice: View {
    @EnvironmentObject var model: AppModel
    let param: TrillParam
    let label: String
    let options: [(Int, String)]

    var body: some View {
        HStack {
            Picker(label, selection: Binding(get: { model.draft[param] }, set: { model.draft[param] = $0 })) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].1).tag(options[i].0) }
            }
            AckBadge(param: param) { v in options.first { $0.0 == v }?.1 ?? "\(v)" }
        }
        .disabled(model.session.unsupported(param))
    }
}

struct MappingView: View {
    @EnvironmentObject var model: AppModel
    static let channels = (0..<16).map { ($0, "\($0 + 1)") }
    static let sources = CCSource.allCases.map { ($0.rawValue, $0.title) }
    static let ccNumbers = (1...119).map { ($0, Self.ccName($0)) }
    static let expression = [(0, "Off")] + Self.ccNumbers

    static func ccName(_ n: Int) -> String {
        switch n {
        case 1: return "CC1 mod wheel"
        case 2: return "CC2 breath"
        case 7: return "CC7 volume"
        case 10: return "CC10 pan"
        case 11: return "CC11 expression"
        case 71: return "CC71 resonance"
        case 74: return "CC74 brightness"
        default: return "CC\(n)"
        }
    }

    private var oldFirmware: Bool { model.session.hello != nil && !model.session.supportsConfigPages }
    private var mode: SensorMode { SensorMode(rawValue: model.draft[.mode]) ?? .touch }

    private var modeFooter: String {
        switch mode {
        case .touch:
            return "Touch: the Trill strip plays the note (as before). Tilt modes ignore the strip: tilting forward past the gate starts a note, roll picks the pitch, tilting back stops it."
        case .tiltNotes:
            return "Tilt notes: roll picks scale notes (Lowest note, Range, Scale below), with hysteresis so a note does not flicker between neighbours. Velocity and pressure follow how far past the gate you tilt."
        case .theremin:
            return "Theremin: roll bends pitch continuously from the note chosen at onset. Set your synth's pitch-bend range to ±\(model.draft[.bendRange]) semitones (also sent as RPN 0) or pitch will be wrong."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Button("Apply to device") { model.applyDraft() }
                            .disabled(!model.session.isReady || !model.hasUnappliedEdits)
                            .keyboardShortcut(.defaultAction)
                        Button("Revert edits") { model.revertDraft() }
                            .disabled(!model.hasUnappliedEdits)
                        Button("Read from device") { model.readFromDevice() }
                            .disabled(!model.session.isReady)
                    }
                    if !model.session.isReady {
                        Text("Not connected: you can edit and save presets; applying needs a connection (Device tab).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.hasUnappliedEdits {
                        Text("Orange values are what the device last acknowledged; your edits are not on the device yet.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if oldFirmware {
                        Text("This device runs firmware \(model.session.hello?.firmwareString ?? "?"). Sensor modes, controller assignment, tap sensitivity and gestures need firmware \(TrillProtocol.configPagesMinimumFirmware); those controls are disabled and never sent to it.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Applying releases sounding notes and returns changed controllers to 0 first. Settings are RAM only: unplugging or resetting the device restores firmware defaults.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(BuiltInPreset.all) { p in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(p.summary).font(.caption).foregroundStyle(.secondary)
                                if p.needsConfigPages && oldFirmware {
                                    Text("Needs firmware \(TrillProtocol.configPagesMinimumFirmware) (only the basic part would be sent).")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button("Load") { model.load(builtIn: p) }
                        }
                    }
                } header: {
                    Text("Presets")
                } footer: {
                    Text("Load fills the editor; press Apply to device to send it.")
                }
                Section {
                    ParamChoice(param: .mode, label: "Mode", options: SensorMode.allCases.map { ($0.rawValue, $0.title) })
                    if mode != .touch {
                        ParamStepper(param: .tiltSpanDeg, label: "Roll to reach each end", step: 5) { "\($0)°" }
                        ParamStepper(param: .gateDeg, label: "Forward tilt to sound", step: 1) { "\($0)° (closes 3° lower)" }
                        if mode == .tiltNotes {
                            ParamStepper(param: .stepHysteresis, label: "Note-change hysteresis", step: 5) { "\($0)% of a step" }
                        }
                        ParamChoice(param: .expressionCC, label: "Tilt depth also as", options: Self.expression)
                    }
                    Button("Set current orientation as level") { model.perform(.zeroOrientation) }
                        .disabled(!model.session.isReady || !model.session.supportsConfigPages)
                } header: {
                    Text("Sensor mode")
                } footer: {
                    Text(modeFooter)
                }
                Section("Notes") {
                    ParamChoice(param: .channel, label: "MIDI channel", options: Self.channels)
                    ParamStepper(param: .baseNote, label: "Lowest note") { "\(NoteName.name(UInt8($0))) (\($0))" }
                    ParamStepper(param: .rangeSemitones, label: "Range") { "\($0) semitones" }
                    ParamChoice(param: .scale, label: "Scale", options: [(0, "Chromatic"), (1, "Pentatonic")])
                    ParamChoice(param: .pitchMode, label: "Pitch (touch mode)", options: [(0, "Continuous bend"), (1, "Stepped notes")])
                    ParamStepper(param: .bendRange, label: "Pitch-bend range") { "±\($0) st" }
                    ParamStepper(param: .velocityMin, label: "Minimum velocity")
                }
                Section {
                    ParamToggle(param: .motionEnabled, label: "Send motion controllers")
                    ParamChoice(param: .ccASource, label: "Controller A from", options: Self.sources)
                    ParamChoice(param: .ccANumber, label: "Controller A sends", options: Self.ccNumbers)
                    ParamChoice(param: .ccBSource, label: "Controller B from", options: Self.sources)
                    ParamChoice(param: .ccBNumber, label: "Controller B sends", options: Self.ccNumbers)
                    ParamStepper(param: .rotationFullDps, label: "Rotation for 127", step: 30) { "\($0) °/s" }
                    ParamStepper(param: .tiltFullDeg, label: "Tilt for 127 (or ±64)", step: 5) { "\($0)°" }
                    ParamStepper(param: .ccDeadzone, label: "Deadzone", step: 1) { "\($0)%" }
                    ParamStepper(param: .ccSmoothingMs, label: "Smoothing", step: 10) { $0 == 0 ? "off" : "\($0) ms" }
                } header: {
                    Text("Motion controllers")
                } footer: {
                    Text("Sources are pitch (tilt forward/back), roll (tilt left/right) and rotation speed, from the board's IMU axes; which way is \"forward\" depends on how it is mounted. There is no compass, so no heading/yaw, and no position. \"Back\" and \"left\" are the inverted directions; centred sources send 64 when level. Smoothing adds about that much lag (63% of a step after one time constant). Channel pressure always follows note pressure.")
                }
                Section {
                    ParamToggle(param: .percussionEnabled, label: "Tap percussion")
                    ParamChoice(param: .percussionChannel, label: "Channel", options: Self.channels)
                    ParamStepper(param: .percussionNote, label: "Note") { "\(NoteName.name(UInt8($0))) (\($0))" }
                    ParamStepper(param: .tapThresholdCg, label: "Tap threshold", step: 10) { String(format: "%.2f g (lower = more sensitive)", Double($0) / 100) }
                    ParamStepper(param: .tapCooldownMs, label: "Minimum time between taps", step: 10) { "\($0) ms" }
                } header: {
                    Text("Tap percussion")
                } footer: {
                    Text("Taps play once the gyro is calibrated (hold still ~1 s after connecting) and only while USB MIDI is connected. The LED flashes white on every detected tap, even with percussion off.")
                }
                Section {
                    ParamChoice(param: .gestureAxis, label: "Flick gestures", options: [(0, "Off"), (1, "Sensor X axis"), (2, "Sensor Y axis"), (3, "Sensor Z axis")])
                    ParamStepper(param: .gestureThresholdDps, label: "Flick speed", step: 50) { "\($0) °/s" }
                    ParamStepper(param: .gestureCooldownMs, label: "Minimum time between flicks", step: 50) { "\($0) ms" }
                    ParamStepper(param: .gestureBaseNote, label: "Notes") { "\($0) / \($0 + 1) / \($0 + 2)" }
                } header: {
                    Text("Gestures (experimental, off by default)")
                } footer: {
                    Text("A quick flick one way plays the first note, the other way the second; flicking back the other way soon after (a zig-zag) also plays the third. Notes go on the percussion channel. Circle and twirl recognition is not implemented yet.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Mapping")
        }
    }
}
