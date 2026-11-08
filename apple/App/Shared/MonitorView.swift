// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TrillKit

struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    @State private var exporting: CSVDocument?
    @State private var showExporter = false

    private var portName: String { model.source(model.monitorSourceID)?.name ?? "none" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) { HStack {
                    Picker("Channel", selection: $model.monitorChannel) {
                        ForEach(0..<16, id: \.self) { Text("Ch \($0 + 1)").tag($0) }
                    }
                    .frame(maxWidth: 160)
                    Toggle("Pause", isOn: $model.monitorPaused)
                    Toggle("Hide clock / real-time", isOn: Binding(get: { model.monitor.hideRealtime }, set: { model.setHideRealtime($0) }))
                    Button("Clear") { model.clearMonitor() }
                    Button("Export…") {
                        exporting = CSVDocument(text: model.monitor.csv(port: portName))
                        showExporter = true
                    }
                    .disabled(model.monitor.history.isEmpty)
                } }
                Text("Port: \(portName) · \(String(format: "%.0f", model.monitor.rate)) events/s · \(model.monitor.total) total · \(model.monitor.realtimeCount) real-time · \(model.monitor.sysexCount) SysEx\(model.monitor.dropped > 0 ? " · \(model.monitor.dropped) dropped (UI buffer full)" : "") · log keeps the last \(model.monitor.historyLimit)\(model.monitorPaused ? " · PAUSED (not recording)" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if model.monitorSourceID == nil {
                    Text("Select a source on the Device tab.").foregroundStyle(.secondary)
                }
                ChannelPanel(state: model.monitor.channels[model.monitorChannel],
                             bendRange: model.session.acknowledged?[.bendRange] ?? model.draft[.bendRange])
                Text("Values are the standard MIDI messages the instrument sends (touch size arrives as channel pressure; rotation and tilt as CC74 / CC1). Raw sensor values are on the Sensors tab. Times are CoreMIDI timestamps; SysEx is summarized to its first 24 bytes. Nothing is routed elsewhere.")
                    .font(.caption).foregroundStyle(.secondary)
                EventList(events: model.monitor.history)
            }
            .padding()
            .navigationTitle("MIDI Monitor")
            .fileExporter(isPresented: $showExporter, document: exporting, contentType: .commaSeparatedText,
                          defaultFilename: "trill-midi-log.csv") { _ in exporting = nil }
        }
    }
}

struct Meter: View {
    let label: String
    let value: Double // 0...1
    let text: String

    var body: some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            ProgressView(value: min(max(value, 0), 1))
            Text(text).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
        }
    }
}

struct ChannelPanel: View {
    let state: ChannelState
    let bendRange: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").frame(width: 120, alignment: .leading)
                if state.notes.isEmpty { Text("–").foregroundStyle(.secondary) }
                ForEach(state.notes.keys.sorted(), id: \.self) { n in
                    Text("\(NoteName.name(n)) v\(state.notes[n] ?? 0)")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
            let semis = state.bendSemitones(range: bendRange)
            Meter(label: "Pitch bend", value: (Double(state.pitchBend) / 16383), text: String(format: "%+.2f st", semis))
            Meter(label: "Pressure", value: Double(state.pressure) / 127, text: "\(state.pressure)")
            Meter(label: "CC74 (rotation)", value: Double(state.controllers[74] ?? 0) / 127, text: "\(state.controllers[74] ?? 0)")
            Meter(label: "CC1 (tilt)", value: Double(state.controllers[1] ?? 0) / 127, text: "\(state.controllers[1] ?? 0)")
        }
    }
}

struct EventList: View {
    let events: [MIDIEvent]

    var body: some View {
        let first = events.first?.hostTime ?? 0
        List(Array(events.reversed())) { e in
            HStack {
                Text(String(format: "%10.4f s", e.hostTime - first)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(e.message.summary).font(.caption.monospaced())
            }
        }
        .listStyle(.plain)
    }
}
