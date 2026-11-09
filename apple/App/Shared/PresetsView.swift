// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TrillKit
import UniformTypeIdentifiers

/// One preset as a JSON file, for export/import through the system file
/// dialogs (the app only touches files the user picks).
struct PresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var preset: Preset

    init(preset: Preset) { self.preset = preset }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count < 64 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        preset = try Preset.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try preset.jsonData())
    }
}

/// Every preset in one place: built-in sounds first, then the user's own.
/// Choosing one applies it straight away when Trillium is connected.
struct PresetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var exporting: PresetDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showSave = false

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusLine
                    Text("Built in").font(.headline)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(BuiltInPreset.all) { p in
                            PresetCard(name: p.name, symbol: p.symbol, summary: p.summary,
                                       note: updateNote(p), isActive: model.activePresetName == p.name) {
                                model.use(p.config)
                            }
                        }
                    }
                    HStack {
                        Text("My presets").font(.headline)
                        Spacer()
                        Button { showSave = true } label: { Label("Save current sound…", systemImage: "plus") }
                        Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    }
                    if model.presets.isEmpty {
                        Text("Sounds you save appear here. They're stored on this \(Self.deviceWord), because Trillium itself forgets changes when unplugged.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.presets) { p in
                            PresetCard(name: p.name, symbol: SensorMode(rawValue: p.config[.mode])?.symbol ?? "slider.horizontal.3",
                                       summary: MappingSummary.lines(p.config).map(\.input).joined(separator: " · "),
                                       note: nil, isActive: model.activePresetName == p.name) {
                                model.use(p.config)
                            }
                            .contextMenu {
                                Button("Export…") { exporting = PresetDocument(preset: p); showExporter = true }
                                Button("Delete", role: .destructive) { model.deletePreset(p) }
                            }
                        }
                    }
                    if !model.presets.isEmpty {
                        Text("Right-click (or touch and hold) a preset to export or delete it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Presets")
            .alert("Save current sound", isPresented: $showSave) {
                TextField("Name", text: $newName)
                Button("Save") { model.savePreset(named: newName); newName = "" }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text("Saves the sound from the editor on this \(Self.deviceWord).")
            }
            .fileExporter(isPresented: $showExporter, document: exporting, contentType: .json,
                          defaultFilename: (exporting?.preset.name ?? "preset") + ".trill.json") { result in
                if case let .failure(e) = result { model.presetError = e.localizedDescription }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case let .success(url): model.importPreset(from: url)
                case let .failure(e): model.presetError = e.localizedDescription
                }
            }
            .alert("Preset", isPresented: Binding(get: { model.presetError != nil }, set: { if !$0 { model.presetError = nil } })) {
                Button("OK") { model.presetError = nil }
            } message: {
                Text(model.presetError ?? "")
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if model.session.isReady {
            Label("Choosing a preset sends it to Trillium right away.", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Label("Not connected: choosing a preset loads it into the editor. Connect on the Home tab to play it.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func updateNote(_ p: BuiltInPreset) -> String? {
        guard model.session.hello != nil, let min = p.minimumFirmware else { return nil }
        let has = p.needsStrikes ? model.session.supportsStrikes : model.session.supportsConfigPages
        return has ? nil : "Needs a firmware update (\(min)) to play fully."
    }

    static var deviceWord: String {
        #if os(macOS)
        return "Mac"
        #else
        return "device"
        #endif
    }
}

struct PresetCard: View {
    let name: String
    let symbol: String
    let summary: String
    let note: String?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
                    Text(name).font(.headline)
                    Spacer()
                    if isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(isActive ? 0.9 : 0.45)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActive ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityHint(isActive ? "Current sound" : "Use this sound")
    }
}
