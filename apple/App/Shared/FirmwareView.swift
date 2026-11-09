// SPDX-License-Identifier: GPL-3.0-only
//
// Guided, read-only firmware update assistant. The app validates a UF2 the
// user picks and reads INFO_UF2.TXT from the bootloader drive the user
// picks, then shows the exact tools/xiao_uf2.py commands. It never writes
// to the drive: copying an image is a step the user runs explicitly.

import SwiftUI
import TrillKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct FirmwareView: View {
    var body: some View {
        NavigationStack {
            #if os(macOS)
            FirmwareAssistant()
                .navigationTitle("Firmware")
            #else
            Form {
                Section("Firmware updates need a Mac or PC") {
                    Text("The XIAO nRF52840 Sense is updated through its UF2 bootloader drive over USB, using tools/xiao_uf2.py on a computer. There is no Bluetooth or over-the-air update path in this firmware, so this iPhone/iPad app cannot update it.")
                    Text("See docs/firmware-xiao-sense.md in the repository.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Firmware")
            #endif
        }
    }
}

#if os(macOS)
struct FirmwareAssistant: View {
    enum Pick { case image, drive }
    @State private var imageURL: URL?
    @State private var summary: UF2.Summary?
    @State private var imageError: String?
    @State private var driveURL: URL?
    @State private var info: BootloaderInfo?
    @State private var driveError: String?
    @State private var hasCurrent = false
    @State private var repoPath = "."
    // One importer for both picks (several .fileImporter modifiers on one
    // view do not all work on every macOS version).
    @State private var pick: Pick?

    var body: some View {
        Form {
            Section {
                Label("Loading this firmware replaces the Omi (or any other) application on the board. Back up first. Bluetooth and the microphone are not available in this firmware.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("This assistant only reads files. It never writes to the board; you run the commands below yourself, dry run first.")
                    .foregroundStyle(.secondary)
            }
            Section("1 · Firmware image") {
                Button("Choose UF2 file…") { pick = .image }
                if let u = imageURL { Text(u.path).font(.caption.monospaced()).textSelection(.enabled) }
                if let s = summary {
                    Label(String(format: "Application-only nRF52840 image: %d blocks, 0x%08X–0x%08X", s.blocks, s.start, s.end), systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                    Text("SHA-256 \(s.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Compare with SHA256SUMS from the same CI artifact. This is an integrity check only; images are not signed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let e = imageError { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
            Section {
                Button("Choose bootloader drive…") { pick = .drive }
                if let u = driveURL { Text(u.path).font(.caption.monospaced()) }
                if let i = info {
                    ForEach(i.fields.keys.sorted(), id: \.self) { k in
                        Text("\(k): \(i.fields[k] ?? "")").font(.caption.monospaced())
                    }
                    if i.problems.isEmpty {
                        Label("nRF52840 with SoftDevice \(UF2.expectedSoftDevice)", systemImage: "checkmark.seal").foregroundStyle(.green)
                    }
                    ForEach(i.problems, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
                    Text(hasCurrent ? "CURRENT.UF2 is present: the backup command can read the current application." : "No CURRENT.UF2 on this drive: a backup is not possible this way.")
                        .font(.caption).foregroundStyle(hasCurrent ? Color.secondary : Color.orange)
                }
                if let e = driveError { Label(e, systemImage: "xmark.octagon").foregroundStyle(.red) }
            } header: {
                Text("2 · Bootloader drive")
            } footer: {
                Text("Double-press RESET on the board; a drive appears in Finder. Its name varies by board and bootloader.")
            }
            if let s = summary, let i = info, i.problems.isEmpty, let board = i.boardID, let img = imageURL, let drive = driveURL {
                let c = FlashCommands(repo: repoPath, image: img.path, drive: drive.path, boardID: board)
                Section {
                    TextField("Path to your trill checkout", text: $repoPath)
                    CommandRow(title: "Check the drive (read-only)", command: c.info)
                    CommandRow(title: "Back up the current application (read-only)", command: c.backup)
                    CommandRow(title: "Validate the image", command: c.inspect)
                    CommandRow(title: "Dry run (writes nothing)", command: c.dryRun)
                    CommandRow(title: "Write — only after the backup and dry run", command: c.write)
                    Text("Expected image SHA-256: \(s.sha256)").font(.caption.monospaced())
                } header: {
                    Text("3 · Commands to run in Terminal")
                } footer: {
                    Text("Restore later by flashing the *-app-only.uf2 from the backup (or Omi's release UF2) the same way. Never copy a bootloader*.uf2 or a full CURRENT.UF2 to the drive; the tool refuses both. Full Omi recovery is not guaranteed.")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: Binding(get: { pick != nil }, set: { if !$0 { pick = nil } }),
                      allowedContentTypes: pick == .drive ? [.folder, .volume] : [UTType(filenameExtension: "uf2") ?? .data, .data]) { r in
            let mode = pick
            pick = nil
            guard case let .success(url) = r else { return }
            if mode == .drive { loadDrive(url) } else { loadImage(url) }
        }
    }

    private func loadImage(_ url: URL) {
        imageURL = url
        summary = nil
        imageError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? Int ?? 0) <= UF2.maxFileSize else { throw UF2.Failure.tooLarge }
            summary = try UF2.validate(try Data(contentsOf: url))
        } catch { imageError = error.localizedDescription }
    }

    private func loadDrive(_ url: URL) {
        driveURL = url
        info = nil
        driveError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            info = try BootloaderVolume.inspect(url)
            hasCurrent = BootloaderVolume.hasCurrentUF2(url)
        } catch { driveError = error.localizedDescription }
    }
}

struct CommandRow: View {
    let title: String
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            HStack {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
    }
}
#endif
