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
    }
}

struct MappingView: View {
    @EnvironmentObject var model: AppModel
    static let channels = (0..<16).map { ($0, "\($0 + 1)") }

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
                    Text("Applying releases a sounding note first; lift your finger before playing again. Settings are RAM only on the device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Touch voice") {
                    ParamChoice(param: .channel, label: "MIDI channel", options: Self.channels)
                    ParamStepper(param: .baseNote, label: "Lowest note") { "\(NoteName.name(UInt8($0))) (\($0))" }
                    ParamStepper(param: .rangeSemitones, label: "Range") { "\($0) semitones" }
                    ParamChoice(param: .scale, label: "Scale", options: [(0, "Chromatic"), (1, "Pentatonic")])
                    ParamChoice(param: .pitchMode, label: "Pitch", options: [(0, "Continuous bend"), (1, "Stepped notes")])
                    ParamStepper(param: .bendRange, label: "Pitch-bend range") { "±\($0) st" }
                    ParamStepper(param: .velocityMin, label: "Minimum velocity")
                }
                Section {
                    ParamToggle(param: .motionEnabled, label: "Send motion controllers")
                    ParamStepper(param: .rotationFullDps, label: "Rotation for CC74 = 127", step: 30) { "\($0) °/s" }
                    ParamStepper(param: .tiltFullDeg, label: "Tilt for CC1 = 127", step: 5) { "\($0)°" }
                } header: {
                    Text("Motion")
                } footer: {
                    Text("Controller numbers are fixed in firmware 0.2.0: CC74 = rotation rate, CC1 = forward tilt, channel pressure = touch size (contact area, not force).")
                }
                Section("Tap percussion") {
                    ParamToggle(param: .percussionEnabled, label: "Tap percussion")
                    ParamChoice(param: .percussionChannel, label: "Channel", options: Self.channels)
                    ParamStepper(param: .percussionNote, label: "Note") { "\(NoteName.name(UInt8($0))) (\($0))" }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Mapping")
        }
    }
}
