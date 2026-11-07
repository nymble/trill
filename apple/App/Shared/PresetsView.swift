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

struct PresetsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var exporting: PresetDocument?
    @State private var showExporter = false
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Preset name", text: $newName)
                        Button("Save editor as preset") {
                            model.savePreset(named: newName)
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Import preset file…") { showImporter = true }
                } footer: {
                    Text("Presets are stored on this \(Self.deviceWord) and hold every mapping setting. Loading one fills the Mapping editor; press Apply there to send it. The Trill itself keeps settings only until it restarts.")
                }
                Section("Saved presets") {
                    if model.presets.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                    ForEach(model.presets) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Button("Load") { model.load(p) }
                            Button("Export…") {
                                exporting = PresetDocument(preset: p)
                                showExporter = true
                            }
                            Button(role: .destructive) { model.deletePreset(p) } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Presets")
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

    static var deviceWord: String {
        #if os(macOS)
        return "Mac"
        #else
        return "device"
        #endif
    }
}
