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
                    Toggle("Hide Trill sensor SysEx", isOn: Binding(get: { model.monitor.hideTrillSysEx }, set: { model.setHideTrillSysEx($0) }))
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
                Text(channelLine).font(.caption).foregroundStyle(.secondary)
                ChannelPanel(state: model.monitor.channels[model.monitorChannel],
                             bendRange: model.session.acknowledged?[.bendRange] ?? model.draft[.bendRange])
                Text("Values are the standard MIDI messages the instrument sends on Port 1 (notes, channel pressure, pitch bend and the controllers chosen on the Mapping tab). Port 2 carries only configuration and the sensor stream; Trill sensor SysEx is counted but hidden from the log unless you untick the option. Raw sensor values are on the Sensors tab. Times are CoreMIDI timestamps; SysEx is summarized to its first 24 bytes. Nothing is routed elsewhere.")
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

extension MonitorView {
    /// Display channel versus what the device sends (1-based, as DAWs show).
    var channelLine: String {
        let cfg = model.session.acknowledged ?? model.draft
        var parts = ["Showing channel \(model.monitorChannel + 1)",
                     "device sends notes on ch \(cfg[.channel] + 1)",
                     "taps\(cfg[.gestureAxis] != 0 ? " and flicks" : "") on ch \(cfg[.percussionChannel] + 1)"]
        let active = model.monitor.activeChannels.map { "\($0 + 1)" }
        parts.append(active.isEmpty ? "no channel activity yet" : "activity on ch " + active.joined(separator: ", "))
        return parts.joined(separator: " · ") + "\(model.monitor.trillSysExCount > 0 ? " · \(model.monitor.trillSysExCount) Trill SysEx (is this Port 2? pick Port 1 for the instrument)" : "")"
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
            ForEach(state.controllers.keys.filter { $0 < 120 }.sorted(), id: \.self) { cc in
                Meter(label: "CC\(cc)", value: Double(state.controllers[cc] ?? 0) / 127, text: "\(state.controllers[cc] ?? 0)")
            }
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
