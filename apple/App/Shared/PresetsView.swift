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
/// Choosing one applies it straight away when Trillium is connected; Edit
/// opens it in the full editor, where changes play live.
struct PresetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var exporting: PresetDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showEditor = false
    @State private var confirmRestore: BuiltInPreset?

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusLine
                    Text("Built in").font(.headline)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.builtIns) { p in
                            let edited = model.isEdited(builtIn: p.id)
                            PresetCard(name: p.name, symbol: p.symbol, summary: p.summary,
                                       note: updateNote(p), badge: edited ? "Edited" : nil,
                                       isActive: model.activePresetName == p.name,
                                       action: { model.use(p.config) },
                                       edit: { model.edit(builtIn: p); showEditor = true })
                            .contextMenu {
                                Button("Edit…") { model.edit(builtIn: p); showEditor = true }
                                Button("Duplicate as my preset") { model.duplicate(p.config, named: p.name + " copy") }
                                Button("Export…") { exporting = PresetDocument(preset: model.presetForExport(builtIn: p)); showExporter = true }
                                if edited { Button("Restore original…", role: .destructive) { confirmRestore = p } }
                            }
                        }
                    }
                    HStack {
                        Text("My presets").font(.headline)
                        Spacer()
                        Button { model.newPreset(); showEditor = true } label: { Label("New preset", systemImage: "plus") }
                        Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    }
                    if model.presets.isEmpty {
                        Text("Make your own: press New preset to start from the current sound, or Edit on any preset above and choose Save as new. Presets are stored on this \(Self.deviceWord), because Trillium itself forgets changes when unplugged.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.presets) { p in
                            PresetCard(name: p.name, symbol: SensorMode(rawValue: p.config[.mode])?.symbol ?? "slider.horizontal.3",
                                       summary: MappingSummary.lines(p.config).map(\.input).joined(separator: " · "),
                                       note: nil, badge: nil, isActive: model.activePresetName == p.name,
                                       action: { model.use(p.config) },
                                       edit: { model.edit(saved: p); showEditor = true })
                            .contextMenu {
                                Button("Edit…") { model.edit(saved: p); showEditor = true }
                                Button("Duplicate") { model.duplicate(p.config, named: p.name + " copy") }
                                Button("Export…") { exporting = PresetDocument(preset: p); showExporter = true }
                                Button("Delete", role: .destructive) { model.deletePreset(p) }
                            }
                        }
                    }
                    Text("Right-click (or touch and hold) a preset for more: duplicate, export, delete or restore the original. Edited built-ins can be exported and sent in to improve the ones that ship with the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Presets")
            .navigationDestination(isPresented: $showEditor) { MappingView() }
            .confirmationDialog("Restore the original \(confirmRestore?.name ?? "")?", isPresented: Binding(
                get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
                Button("Restore original", role: .destructive) {
                    if let p = confirmRestore { model.restoreBuiltIn(p.id) }
                    confirmRestore = nil
                }
            } message: {
                Text("Your changes to this built-in preset are discarded.")
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
    let badge: String?
    let isActive: Bool
    let action: () -> Void
    let edit: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
                        Text(name).font(.headline)
                        if let badge {
                            Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.orange.opacity(0.2))).foregroundStyle(.orange)
                        }
                        Spacer()
                        if isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    Text(summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    if let note { Text(note).font(.caption).foregroundStyle(.orange) }
                    Spacer(minLength: 18)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(isActive ? 0.9 : 0.45)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActive ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint(isActive ? "Current sound" : "Use this sound")
            Button(action: edit) { Label("Edit", systemImage: "pencil") }
                .controlSize(.small)
                .padding(8)
                .help("Open in the editor; changes play live")
        }
    }
}
