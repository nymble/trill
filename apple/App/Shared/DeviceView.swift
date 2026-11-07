// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TrillKit

struct EndpointPicker: View {
    let title: String
    let endpoints: [MIDIEndpointInfo]
    @Binding var selection: MIDIUniqueID?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(MIDIUniqueID?.none)
            ForEach(endpoints) { e in
                Text(e.title + (e.isOffline ? " (offline)" : "") + (e.portIndex.map { " · port \($0 + 1)" } ?? ""))
                    .tag(MIDIUniqueID?.some(e.id))
            }
        }
    }
}

struct DeviceView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRestore = false

    var body: some View {
        NavigationStack {
            Form {
                if let e = model.midiError {
                    Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    EndpointPicker(title: "Source", endpoints: model.sources, selection: $model.monitorSourceID)
                } header: {
                    Text("Instrument output (monitor)")
                } footer: {
                    Text("The Trill plays straight into your DAW or synth over USB MIDI; this app is not needed while playing. Listening here does not take the port away from other apps.")
                }

                Section {
                    EndpointPicker(title: "Replies from (source)", endpoints: model.sources, selection: $model.configSourceID)
                    EndpointPicker(title: "Requests to (destination)", endpoints: model.destinations, selection: $model.configDestinationID)
                    if model.configDestinationID != nil, !model.destinationLooksLikeTrill {
                        Label("The selected destination does not look like a Trill. Requests are SysEx with the development ID 0x7D; other devices normally ignore them.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Connect") { model.connectConfig() }
                            .disabled(model.configSourceID == nil || model.configDestinationID == nil || model.client == nil)
                        Button("Disconnect") { model.disconnectConfig() }
                            .disabled(model.session.phase == .disconnected)
                    }
                    StatusRow()
                } header: {
                    Text("Configuration port")
                } footer: {
                    Text("Firmware 0.2.0 or newer exposes two MIDI ports: port 1 carries the instrument, port 2 only the configuration protocol, so configuration replies never reach the port your DAW records. Nothing is sent until you press Connect.")
                }

                Section("Device actions") {
                    Button(TrillAction.panic.title) { model.perform(.panic) }
                    Button(TrillAction.recalibrateGyro.title) { model.perform(.recalibrateGyro) }
                        .help("Keep the board still for about one second.")
                    Button(TrillAction.ledSelfTest.title) { model.perform(.ledSelfTest) }
                    Button(TrillAction.restoreDefaults.title, role: .destructive) { confirmRestore = true }
                }
                .disabled(!model.session.isReady)

                Section("Activity") {
                    let log = model.session.log.suffix(15).reversed()
                    if log.isEmpty { Text("No requests yet.").foregroundStyle(.secondary) }
                    ForEach(Array(log.enumerated()), id: \.offset) { _, e in
                        Text(e.text).font(.caption.monospaced()).foregroundStyle(e.isError ? .red : .primary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Device")
            .confirmationDialog("Restore firmware defaults on the device?", isPresented: $confirmRestore) {
                Button("Restore defaults", role: .destructive) { model.perform(.restoreDefaults) }
            } message: {
                Text("Replaces the current mapping on the device (RAM only). Saved presets in this app are not affected.")
            }
        }
    }
}

struct StatusRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.session!
        VStack(alignment: .leading, spacing: 4) {
            switch s.phase {
            case .disconnected: Label("Not connected", systemImage: "circle").foregroundStyle(.secondary)
            case .handshaking: Label("Waiting for handshake reply…", systemImage: "hourglass")
            case .ready: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let .failed(why): Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let h = s.hello {
                Text("Firmware \(h.firmwareString)\(h.isPCMSynthBuild ? " (pcm-synth debug build)" : "") · protocol v\(h.protocolVersion) · up \(h.uptimeSeconds) s at handshake · boot ID \(h.bootID)")
                    .font(.caption)
                Text(h.persistent ? "Settings persist on the device." : "Settings are kept in device RAM only: a reset or power cycle restores firmware defaults. Use presets to keep them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if s.deviceRestarted {
                Text("The device restarted since the last connection; its settings went back to defaults.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let g = s.generation { Text("Settings generation \(g)").font(.caption).foregroundStyle(.secondary) }
            if let p = s.pending { Text("Waiting for reply to request \(p.id)…").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
