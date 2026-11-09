// SPDX-License-Identifier: GPL-3.0-only
//
// Everything beyond picking a sound: the full mapping editor, MIDI ports,
// the MIDI monitor, device tools, firmware and About.

import CoreMIDI
import SwiftUI
import TrillKit

enum SettingsPage: Hashable {
    case mapping, connection, monitor, device, firmware, about
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack(path: $model.settingsPath) {
            List {
                Section {
                    row(.mapping, "Sound & mapping", "slider.horizontal.3",
                        "What plays the notes, controllers, taps, strikes and gestures")
                }
                Section("Connection and tools") {
                    row(.connection, "Connection", "cable.connector", "MIDI ports and automatic connection")
                    row(.monitor, "MIDI monitor", "waveform.path.ecg", "See every message Trillium sends")
                    row(.device, "Device", "cpu", "Recalibrate, LED test, restore defaults, activity log")
                    row(.firmware, "Firmware", "arrow.down.circle", "Check and install firmware updates")
                }
                Section {
                    row(.about, "About Trillium", "info.circle", nil)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .mapping: MappingView()
                case .connection: ConnectionView()
                case .monitor: MonitorView()
                case .device: DeviceToolsView()
                case .firmware: FirmwareView()
                case .about: AboutView()
                }
            }
        }
    }

    private func row(_ page: SettingsPage, _ title: String, _ symbol: String, _ detail: String?) -> some View {
        NavigationLink(value: page) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            } icon: { Image(systemName: symbol) }
        }
    }
}

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

/// MIDI ports. Trillium's ports are chosen automatically; this page is for
/// checking or overriding them.
struct ConnectionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Connect automatically when Trillium is plugged in",
                       isOn: Binding(get: { model.autoConnect }, set: { model.autoConnect = $0 }))
                StatusRow()
                HStack {
                    Button("Connect") { model.connectConfig() }
                        .disabled(model.configSourceID == nil || model.configDestinationID == nil || model.client == nil)
                    Button("Disconnect") { model.disconnectConfig() }
                        .disabled(model.session.phase == .disconnected)
                }
            }
            Section {
                EndpointPicker(title: "Instrument (monitor)", endpoints: model.sources, selection: $model.monitorSourceID)
            } header: {
                Text("Port 1: instrument")
            } footer: {
                Text("The notes and controllers your music app receives. The app only listens here, for the MIDI monitor; other apps keep full use of the port.")
            }
            Section {
                EndpointPicker(title: "Replies from", endpoints: model.sources, selection: $model.configSourceID)
                EndpointPicker(title: "Requests to", endpoints: model.destinations, selection: $model.configDestinationID)
                if model.configDestinationID != nil, !model.destinationLooksLikeTrill {
                    Label("This destination doesn't look like Trillium. Settings messages use a development SysEx ID that other devices normally ignore.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Port 2: settings")
            } footer: {
                Text("Settings and the sensor stream use Trillium's second MIDI port, so they never reach the port your music app records. Nothing is sent until you connect.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
    }
}

struct StatusRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.session!
        VStack(alignment: .leading, spacing: 4) {
            switch s.phase {
            case .disconnected: Label("Not connected", systemImage: "circle").foregroundStyle(.secondary)
            case .handshaking: Label("Connecting…", systemImage: "hourglass")
            case .ready: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case let .failed(why): Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let h = s.hello {
                Text("Firmware \(h.firmwareString)\(h.isPCMSynthBuild ? " (debug synth build)" : "") · protocol v\(h.protocolVersion) · boot ID \(h.bootID)")
                    .font(.caption).foregroundStyle(.secondary)
                if !h.persistent {
                    Text("Trillium keeps settings until it's unplugged or reset; save sounds as presets to keep them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if s.deviceRestarted {
                Text("Trillium restarted since the last connection, so its settings went back to defaults.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let p = s.pending { Text("Waiting for reply to request \(p.id)…").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct DeviceToolsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRestore = false

    var body: some View {
        Form {
            Section { StatusRow() }
            Section {
                Button(TrillAction.panic.title) { model.perform(.panic) }
                Button(TrillAction.recalibrateGyro.title) { model.perform(.recalibrateGyro) }
                    .help("Keep Trillium still for about one second.")
                Button(TrillAction.ledSelfTest.title) { model.perform(.ledSelfTest) }
                Button(TrillAction.restoreDefaults.title, role: .destructive) { confirmRestore = true }
            } header: {
                Text("Actions")
            } footer: {
                Text("MIDI panic sends All Notes Off and resets controllers. Recalibrate re-measures the gyro: hold Trillium still for a second.")
            }
            .disabled(!model.session.isReady)
            Section("Activity") {
                let log = model.session.log.suffix(20).reversed()
                if log.isEmpty { Text("No requests yet.").foregroundStyle(.secondary) }
                ForEach(Array(log.enumerated()), id: \.offset) { _, e in
                    Text(e.text).font(.caption.monospaced()).foregroundStyle(e.isError ? .red : .primary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Device")
        .confirmationDialog("Restore firmware defaults on Trillium?", isPresented: $confirmRestore) {
            Button("Restore defaults", role: .destructive) { model.perform(.restoreDefaults) }
        } message: {
            Text("Replaces the current sound on the instrument. Your saved presets are not affected.")
        }
    }
}
