// SPDX-License-Identifier: GPL-3.0-only
//
// Board identification and firmware installs. The app carries the firmware
// of its own version (BundledFirmware). Install flow:
//   1. Restart into the UF2 bootloader: the EnterBootloader action on
//      firmware 0.6+, otherwise the user double-presses RESET.
//   2. A drive appears (XIAO-SENSE) and the app installs right away: the
//      Mac app is entitled to /Volumes/XIAO-SENSE/. Only if the system
//      refuses access (another drive name, iOS) does the user grant it
//      with a drive picker; no file is ever chosen.
//   3. Back up CURRENT.UF2 (plus an app-only restore image) into
//      Application Support, then copy the image (UF2Installer).
//   4. Wait for Trillium to come back, reconnect and check that it reports
//      the bundled version.

import Foundation
import SwiftUI
import TrillKit
#if os(macOS)
import AppKit
#endif

enum FirmwareInstallState: Equatable {
    case idle
    /// Asked the board to restart into its bootloader (firmware 0.6+).
    case restarting(since: TimeInterval)
    /// Waiting for the user to double-press RESET.
    case waitingForDrive
    /// A bootloader drive is mounted; the app needs permission to use it.
    case needsDriveAccess(URL)
    case working(String)
    /// Firmware copied; waiting for Trillium to restart and answer.
    case waitingForBoard(since: TimeInterval, backup: URL?)
    case done(FirmwareVersion, backup: URL?)
    case failed(String)

    /// An install is under way (buttons that start another are disabled).
    var active: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    /// Reconnect to Trillium even with automatic connection off.
    var reconnects: Bool {
        if case .waitingForBoard = self { return true }
        return false
    }
}

extension AppModel {
    /// What is connected, in plain words (nil when not connected).
    var connectedBoardName: String? {
        guard let h = session.hello else { return nil }
        return h.hasMotionSensor ? "Seeed Studio XIAO nRF52840 Sense" : "XIAO nRF52840 without motion sensor"
    }

    /// Installed firmware compared with the firmware this app carries.
    var firmwareStatus: FirmwareStatus? {
        guard session.isReady, let h = session.hello else { return nil }
        return FirmwareStatus.compare(installed: h.firmwareVersion, bundled: bundledFirmware?.version)
    }

    /// Where installs keep the firmware they replaced.
    var firmwareBackupFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Trill/firmware-backups", isDirectory: true)
    }

    // MARK: Starting

    /// Install the bundled firmware: restart the connected Trillium into its
    /// bootloader if it can, otherwise ask for a double-press of RESET.
    func startFirmwareInstall() {
        guard bundledFirmware != nil else {
            install = .failed(bundledFirmwareError ?? "This build of Trillium carries no firmware.")
            return
        }
        if session.isReady, session.hello?.canEnterBootloader == true, session.perform(.enterBootloader, now: now) {
            install = .restarting(since: now)
            sessionRevision += 1
        } else {
            install = .waitingForDrive
            offerDriveIfWaiting()
        }
    }

    func cancelFirmwareInstall() {
        if install.active { install = .idle }
    }

    func dismissFirmwareResult() {
        if !install.active { install = .idle }
    }

    // MARK: Drives

    func startDriveWatch() {
        #if os(macOS)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            driveObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scanDrives() }
            })
        }
        scanDrives()
        #endif
    }

    func scanDrives() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        bootloaderDrives = vols.filter(Self.looksLikeBootloaderDrive)
        offerDriveIfWaiting()
    }

    /// INFO_UF2.TXT when readable; otherwise the volume name (a sandboxed
    /// app cannot read a drive before the user grants access).
    nonisolated static func looksLikeBootloaderDrive(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("INFO_UF2.TXT").path) { return true }
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
        return name.uppercased().hasPrefix("XIAO")
    }

    /// While an install waits for the bootloader, move on as soon as a drive appears.
    func offerDriveIfWaiting() {
        switch install {
        case .restarting, .waitingForDrive: break
        default: return
        }
        guard let d = bootloaderDrives.first else { return }
        // The firmware is inside the app and the drive is readable (the Mac
        // app may use /Volumes/XIAO-SENSE): install straight away.
        if FileManager.default.isReadableFile(atPath: d.appendingPathComponent("INFO_UF2.TXT").path) {
            installFirmware(onDrive: d)
            return
        }
        // Only if the system refuses access (another drive name, or iOS):
        // the user has to allow Trillium to use the drive.
        install = .needsDriveAccess(d)
        #if os(macOS)
        requestDriveAccess(suggested: d)
        #endif
    }

    #if os(macOS)
    /// Ask the user to confirm the drive (this grants the sandboxed app access).
    func requestDriveAccess(suggested: URL?) {
        let p = NSOpenPanel()
        p.message = "macOS needs your permission for Trillium to use the board's drive (\(suggested?.lastPathComponent ?? "XIAO-SENSE")). "
            + "Click Allow. You don't need to choose a file: the firmware (\(bundledFirmware?.version.description ?? "?")) is inside Trillium."
        p.prompt = "Allow"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.directoryURL = suggested
        p.begin { [weak self] r in
            let url = p.url
            Task { @MainActor in
                guard let self, case .needsDriveAccess = self.install else { return }
                if r == .OK, let url { self.installFirmware(onDrive: url) }
            }
        }
    }
    #endif

    // MARK: Installing

    /// Back up, then install the bundled firmware on `drive` (a URL the user picked).
    func installFirmware(onDrive drive: URL) {
        guard let fw = bundledFirmware else {
            install = .failed(bundledFirmwareError ?? "This build of Trillium carries no firmware.")
            return
        }
        let backups = firmwareBackupFolder
        install = .working("Backing up the firmware on the board…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = drive.startAccessingSecurityScopedResource()
            defer { if scoped { drive.stopAccessingSecurityScopedResource() } }
            do {
                _ = try UF2Installer.check(drive: drive)
                var backup: URL?
                do {
                    backup = try UF2Installer.backup(drive: drive, into: backups).directory
                } catch UF2Installer.Failure.noCurrent {
                    backup = nil  // Nothing to read back; install anyway.
                }
                await self?.setInstall(.working("Installing firmware \(fw.version)…"))
                _ = try UF2Installer.write(fw.image, to: drive)
                await self?.firmwareWritten(backup: backup)
            } catch {
                await self?.setInstall(.failed(error.localizedDescription))
            }
        }
    }

    private func setInstall(_ s: FirmwareInstallState) { install = s }

    private func firmwareWritten(backup: URL?) {
        // The board restarts now; drop any old session so the version check
        // only trusts a fresh handshake.
        session.disconnect(now: now)
        sessionRevision += 1
        install = .waitingForBoard(since: now, backup: backup)
    }

    /// Called from the UI timer.
    func firmwareTick() {
        switch install {
        case let .restarting(since) where now - since > 15:
            // The board did not show its drive: fall back to RESET.
            install = .waitingForDrive
        case let .waitingForBoard(since, backup):
            if session.isReady, let h = session.hello {
                if let fw = bundledFirmware, h.firmwareVersion == fw.version {
                    install = .done(fw.version, backup: backup)
                } else {
                    install = .failed("Trillium restarted with firmware \(h.firmwareString), not \(bundledFirmware?.version.description ?? "?").")
                }
            } else if now - since > 45 {
                install = .failed("Trillium hasn't come back after the update. Unplug it and plug it in again. If it still isn't found, double-press RESET and install again.")
            }
        default:
            break
        }
        #if os(macOS)
        if now - lastBoardScan > 2 {
            lastBoardScan = now
            let found = trillDetected || install.active ? [] : USBBoardInfo.scan()
            if found != otherBoards { otherBoards = found }
        }
        #endif
    }

    #if os(macOS)
    func showBackupsInFinder() {
        try? FileManager.default.createDirectory(at: firmwareBackupFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([firmwareBackupFolder])
    }
    #endif
}
