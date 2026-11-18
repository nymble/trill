// SPDX-License-Identifier: GPL-3.0-only
//
// Settings › Firmware: the firmware carried in the app, the connected
// board, installs (FirmwareCard) and backups. The older read-only assistant
// (validate any UF2, read a drive, show tools/xiao_uf2.py commands) stays
// under Advanced for developers.

import SwiftUI
import TrillKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct FirmwareView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                FirmwareCard(alwaysShow: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("Firmware in this app") {
                if let fw = model.bundledFirmware {
                    LabeledContent("Version", value: fw.version.description)
                    LabeledContent("Board", value: fw.manifest.board)
                    Text("SHA-256 \(fw.summary.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Every Trillium app carries the firmware of its own version, so updating the app brings firmware updates with it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.bundledFirmwareError ?? "None").foregroundStyle(.secondary)
                }
            }
            if let h = model.session.hello {
                Section("Connected board") {
                    LabeledContent("Board", value: model.connectedBoardName ?? "?")
                    LabeledContent("Firmware", value: h.firmwareString)
                    LabeledContent("Motion sensor", value: h.hasMotionSensor ? "yes" : "no")
                    LabeledContent("Microphone", value: h.hasMicrophone ? "test capture available" : "not used by this firmware")
                    LabeledContent("Restart for updates", value: h.canEnterBootloader ? "from the app" : "double-press RESET (firmware before 0.6.0)")
                }
            }
            Section {
                #if os(macOS)
                Button("Show firmware backups in Finder") { model.showBackupsInFinder() }
                #endif
                Text("Before each install Trillium saves the board's firmware (CURRENT.UF2 and an app-only restore image) in \(model.firmwareBackupFolder.path).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } header: {
                Text("Backups")
            }
            #if os(macOS)
            Section {
                NavigationLink("Check a UF2 file and drive with the command-line tools…") {
                    FirmwareAssistant().navigationTitle("Command-line tools")
                }
            } header: {
                Text("Advanced")
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Firmware")
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
                Label("Loading this firmware replaces the Omi (or any other) application on the board. Back up first. Bluetooth is not available in this firmware. The onboard microphone is a testing-only capture path in Trillium, not part of any instrument.", systemImage: "exclamationmark.triangle")
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
