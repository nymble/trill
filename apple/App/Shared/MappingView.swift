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
    static let voicingCounts = [(0, "Off: every strike plays the chosen note"), (2, "2: down = note, up = octave"),
                                (4, "4: + left = third, right = fifth"), (6, "6: + forward = second, back = octave below")]
    static let scales = ScaleKind.allCases.map { ($0.rawValue, $0.name) }
    static let strikeCounts = [(0, "Off: one note for every tap"), (2, "2: down, up"),
                               (4, "4: down, up, left, right"), (6, "6: + forward, back")]

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

    private var mode: SensorMode { SensorMode(rawValue: model.draft[.mode]) ?? .touch }
    private var connected: Bool { model.session.hello != nil }

    /// "Update the firmware" note for a feature the device lacks.
    @ViewBuilder private func needsUpdate(_ unsupported: Bool, _ version: String) -> some View {
        if connected && unsupported {
            Label("Update Trillium's firmware to \(version) to use these settings.", systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @State private var showSaveAs = false
    @State private var saveAsName = ""
    @State private var showJSON = false
    @State private var showAll = false

    private var liveBinding: Binding<Bool> { Binding(get: { model.liveApply }, set: { model.liveApply = $0 }) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.editingName.map { "Editing: \($0)" } ?? "Current sound").font(.headline)
                        if model.editing != .new, model.editing != .current, model.hasUnsavedPresetEdits {
                            Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    switch model.editing {
                    case .saved, .builtIn:
                        Button("Save") { model.saveEdits() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.hasUnsavedPresetEdits)
                            .keyboardShortcut("s", modifiers: .command)
                    case .current, .new:
                        EmptyView()
                    }
                    Button(model.editing == .new ? "Save preset…" : "Save as new…") {
                        saveAsName = model.editing == .new ? "" : (model.editingName.map { $0 + " copy" } ?? "")
                        showSaveAs = true
                    }
                    .buttonStyle(.bordered)
                }
                if case let .builtIn(id) = model.editing, model.isEdited(builtIn: id) {
                    Button("Restore the original \(model.editingName ?? "preset")", role: .destructive) { model.restoreBuiltIn(id) }
                        .font(.callout)
                }
                Toggle("Play changes on Trillium as you edit", isOn: liveBinding)
                    .disabled(!model.session.isReady)
                if !model.liveApply || !model.session.isReady {
                    HStack {
                        Button("Apply to Trillium") { model.applyDraft() }
                            .disabled(!model.session.isReady || !model.hasUnappliedEdits)
                        Button("Revert") { model.revertDraft() }
                            .disabled(!model.hasUnappliedEdits)
                        Spacer()
                        Button("Read from Trillium") { model.readFromDevice() }
                            .disabled(!model.session.isReady)
                    }
                }
                if !model.session.isReady {
                    Text("Not connected: you can edit and save presets; hearing them needs a connection.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !model.liveApply, model.hasUnappliedEdits {
                    Text("Orange values show what Trillium is using now; press Apply to send your edits.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Built-in presets can be refined and saved in place (Restore brings back the original). Trillium keeps settings until it is unplugged; presets keep them on this \(PresetsView.deviceWord).")
            }

            Section("What this sound does") {
                RoutingList(lines: MappingSummary.lines(model.draft, pages: connected ? model.session.supportedPages : nil))
            }

            Section {
                Picker("Mode", selection: Binding(get: { model.draft[.mode] }, set: { model.draft[.mode] = $0 })) {
                    ForEach(SensorMode.allCases, id: \.rawValue) { m in Text(m.name).tag(m.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(model.session.unsupported(.mode))
                Text(mode.howItPlays).font(.callout).foregroundStyle(.secondary)
                if mode == .tiltStrike {
                    ZoneStrip(config: model.draft).padding(.vertical, 4)
                    ParamStepper(param: .tiltSpanDeg, label: "Roll to reach each end", step: 5) { "\($0)°" }
                    ParamToggle(param: .zoneCurve, label: "Smaller zones near level (finer control where the wrist is steadiest)")
                    ParamStepper(param: .stepHysteresis, label: "Zone edge stickiness", step: 5) { "\($0)% of a zone" }
                    ParamToggle(param: .registerTilt, label: "Tilt forward / back for octave up / down")
                    if model.draft[.registerTilt] == 1 {
                        ParamStepper(param: .gateDeg, label: "Tilt for an octave change", step: 1) { "\($0)°" }
                    }
                    ParamStepper(param: .noteLengthMs, label: "Note length", step: 50) { "\($0) ms" }
                    ParamToggle(param: .strikeVoicing, label: "Strike direction adds chord tones")
                    if model.draft[.strikeVoicing] == 1 {
                        ParamChoice(param: .strikeDirections, label: "Directions", options: Self.voicingCounts)
                    }
                    Button("Set current position as level") { model.perform(.zeroOrientation) }
                        .disabled(!model.session.isReady || !model.session.supportsConfigPages)
                    needsUpdate(model.session.hello != nil && !model.session.supportsStrikes, TrillProtocol.strikesMinimumFirmware)
                } else if mode != .touch {
                    ParamStepper(param: .tiltSpanDeg, label: "Roll to reach each end", step: 5) { "\($0)°" }
                    ParamStepper(param: .gateDeg, label: "Forward tilt to sound", step: 1) { "\($0)° (stops 3° lower)" }
                    if mode == .tiltNotes {
                        ParamStepper(param: .stepHysteresis, label: "Note-change hysteresis", step: 5) { "\($0)% of a step" }
                    }
                    ParamChoice(param: .expressionCC, label: "Tilt depth also sends", options: Self.expression)
                    Button("Set current position as level") { model.perform(.zeroOrientation) }
                        .disabled(!model.session.isReady || !model.session.supportsConfigPages)
                }
                needsUpdate(model.session.unsupported(.mode), TrillProtocol.configPagesMinimumFirmware)
            } header: {
                Text("1 · What plays the notes")
            } footer: {
                if mode == .theremin {
                    Text("Set your synth's pitch-bend range to ±\(model.draft[.bendRange]) semitones (also sent as RPN 0), or the pitch will be wrong.")
                }
            }

            Section {
                ParamChoice(param: .channel, label: "MIDI channel", options: Self.channels)
                ParamStepper(param: .baseNote, label: "Lowest note") { "\(NoteName.name(UInt8($0))) (\($0))" }
                ParamStepper(param: .rangeSemitones, label: "Range") { "\($0) semitones" }
                ParamChoice(param: .scale, label: "Scale", options: Self.scales)
                if ScaleKind(rawValue: model.draft[.scale])?.needsStrikes == true {
                    needsUpdate(model.session.hello != nil && !model.session.supportsStrikes, TrillProtocol.strikesMinimumFirmware)
                }
                if mode == .touch {
                    ParamChoice(param: .pitchMode, label: "Pitch", options: [(0, "Glide (pitch bend)"), (1, "Steps (separate notes)")])
                }
                ParamStepper(param: .bendRange, label: "Pitch-bend range") { "±\($0) semitones" }
                ParamStepper(param: .velocityMin, label: "Softest velocity")
            } header: {
                Text("2 · Notes")
            }

            Section {
                ParamToggle(param: .motionEnabled, label: "Send motion controllers")
                if model.draft[.motionEnabled] == 1 {
                    ParamChoice(param: .ccASource, label: "Controller A from", options: Self.sources)
                    ParamChoice(param: .ccANumber, label: "Controller A sends", options: Self.ccNumbers)
                    ParamChoice(param: .ccBSource, label: "Controller B from", options: Self.sources)
                    ParamChoice(param: .ccBNumber, label: "Controller B sends", options: Self.ccNumbers)
                    ParamStepper(param: .rotationFullDps, label: "Rotation for full value", step: 30) { "\($0) °/s" }
                    ParamStepper(param: .tiltFullDeg, label: "Tilt for full value", step: 5) { "\($0)°" }
                    ParamStepper(param: .ccDeadzone, label: "Dead zone", step: 1) { "\($0)%" }
                    ParamStepper(param: .ccSmoothingMs, label: "Smoothing", step: 10) { $0 == 0 ? "off" : "\($0) ms" }
                }
                needsUpdate(model.session.unsupported(.ccASource), TrillProtocol.configPagesMinimumFirmware)
            } header: {
                Text("3 · Motion controllers")
            } footer: {
                Text("Tilt and roll are measured against gravity; rotation is how fast Trillium turns. Which way is \"forward\" depends on how the board is mounted. Smoothing adds about that much lag. Channel pressure always follows note pressure.")
            }

            Section {
                if mode == .tiltStrike {
                    Label("In Tilt + strike, every tap or strike plays the note chosen by roll (section 1).", systemImage: "music.note")
                        .font(.callout)
                    ParamStepper(param: .tapThresholdCg, label: "Strike strength needed", step: 5) { String(format: "%.2f g (lower = more sensitive)", Double($0) / 100) }
                    ParamStepper(param: .tapCooldownMs, label: "Fastest repeat", step: 10) { "\($0) ms (sixteenths up to \(60_000 / max($0, 1) / 4) BPM)" }
                } else {
                ParamToggle(param: .percussionEnabled, label: "Play notes on taps")
                if model.draft[.percussionEnabled] == 1 {
                    ParamChoice(param: .percussionChannel, label: "Channel", options: Self.channels)
                    ParamStepper(param: .tapThresholdCg, label: "Tap strength needed", step: 10) { String(format: "%.2f g (lower = more sensitive)", Double($0) / 100) }
                    ParamStepper(param: .tapCooldownMs, label: "Minimum time between taps", step: 10) { "\($0) ms" }
                    ParamChoice(param: .strikeDirections, label: "Strike directions", options: Self.strikeCounts)
                    let dirs = model.session.unsupported(.strikeDirections) ? [] : StrikeDirection.active(model.draft[.strikeDirections])
                    if dirs.isEmpty {
                        ParamStepper(param: .percussionNote, label: "Note") { "\(NoteName.name(UInt8($0))) (\($0))" }
                    } else {
                        ForEach(dirs, id: \.self) { d in
                            ParamStepper(param: d.param, label: d.name) { "\(NoteName.name(UInt8($0))) (\($0))" }
                        }
                        ParamStepper(param: .percussionNote, label: "Unclear direction") { "\(NoteName.name(UInt8($0))) (\($0))" }
                    }
                    needsUpdate(model.session.unsupported(.strikeDirections), TrillProtocol.strikesMinimumFirmware)
                }
                }
            } header: {
                Text("4 · Taps and strikes")
            } footer: {
                Text("With strike directions on, the direction Trillium was moving when it hit something (or stopped sharply) picks the note; down and up follow gravity, left/right and forward/back follow the board. A strike that isn't clearly in one direction plays the \"unclear\" note. Taps work once Trillium has been still for a second after connecting.")
            }

            Section {
                ParamChoice(param: .gestureAxis, label: "Flick gestures", options: [(0, "Off"), (1, "Around sensor X"), (2, "Around sensor Y"), (3, "Around sensor Z")])
                if model.draft[.gestureAxis] != 0 {
                    ParamStepper(param: .gestureThresholdDps, label: "Flick speed", step: 50) { "\($0) °/s" }
                    ParamStepper(param: .gestureCooldownMs, label: "Minimum time between flicks", step: 50) { "\($0) ms" }
                    ParamStepper(param: .gestureBaseNote, label: "Notes") { "\($0) / \($0 + 1) / \($0 + 2)" }
                }
                needsUpdate(model.session.unsupported(.gestureAxis), TrillProtocol.configPagesMinimumFirmware)
            } header: {
                Text("5 · Flick gestures")
            } footer: {
                Text("A quick wrist flick one way plays the first note, the other way the second; flicking back soon after (a zig-zag) also plays the third. Notes use the tap channel.")
            }

            Section {
                DisclosureGroup("Every parameter (\(TrillParam.allCases.count))", isExpanded: $showAll) {
                    ForEach(TrillParam.allCases, id: \.rawValue) { p in RawParamRow(param: p) }
                }
                Button("Edit as text (JSON)…") { showJSON = true }
            } header: {
                Text("6 · Configuration data")
            } footer: {
                Text("Every value Trillium stores, by parameter number, with its allowed range. The JSON text is the same format as exported preset files.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.editingName ?? "Sound & mapping")
        .alert(model.editing == .new ? "Save preset" : "Save as new preset", isPresented: $showSaveAs) {
            TextField("Name", text: $saveAsName)
            Button("Save") { model.saveAsNew(named: saveAsName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved on this \(PresetsView.deviceWord) under My presets.")
        }
        .sheet(isPresented: $showJSON) { ConfigJSONEditor() }
    }
}

/// One parameter by number: exact value entry plus a stepper.
struct RawParamRow: View {
    @EnvironmentObject var model: AppModel
    let param: TrillParam

    var body: some View {
        let binding = Binding(get: { model.draft[param] }, set: { v in
            let c = min(max(v, param.range.lowerBound), param.range.upperBound)
            if param.accepts(c) { model.draft[param] = c } else { model.draft[param] = c + 1 }
        })
        HStack {
            Text("\(param.rawValue)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(param.key).font(.callout.monospaced())
                Text("\(param.range.lowerBound)…\(param.range.upperBound) · default \(param.defaultValue)\(model.session.unsupported(param) ? " · needs newer firmware" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("", value: binding, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Stepper("", value: binding, in: param.range).labelsHidden()
            AckBadge(param: param)
        }
        .disabled(model.session.unsupported(param))
    }
}

/// The editor's configuration as preset JSON, editable as text.
struct ConfigJSONEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .border(.quaternary)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                Text("Change any value and press Use. Missing keys take firmware defaults; unknown keys and out-of-range values are refused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Configuration data")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        do {
                            model.draft = try Preset.decode(Data(text.utf8)).config
                            dismiss()
                        } catch let e as LocalizedError {
                            error = e.errorDescription ?? "\(e)"
                        } catch {
                            self.error = "Not valid JSON: \(error.localizedDescription)"
                        }
                    }
                }
            }
            .onAppear {
                let p = Preset(name: model.editingName ?? "Current sound", config: model.draft)
                text = (try? p.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}
