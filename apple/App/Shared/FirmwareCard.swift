// SPDX-License-Identifier: GPL-3.0-only
//
// Firmware status and installs, shown on Home (only when there is
// something to do) and in Settings › Firmware (always).

import SwiftUI
import TrillKit

struct FirmwareCard: View {
    @EnvironmentObject var model: AppModel
    /// Settings shows the card even when everything is up to date.
    var alwaysShow = false
    #if os(iOS)
    @State private var pickDrive = false
    #endif

    var body: some View {
        if let content = content {
            Card { content }
            #if os(iOS)
                .fileImporter(isPresented: $pickDrive, allowedContentTypes: [.folder]) { r in
                    if case let .success(url) = r { model.installFirmware(onDrive: url) }
                }
            #endif
        }
    }

    private var bundled: String { model.bundledFirmware?.version.description ?? "?" }

    private var content: AnyView? {
        switch model.install {
        case .idle:
            return idleContent
        case .restarting:
            return AnyView(progress("Restarting Trillium for the update…",
                                    "The board's drive appears in a moment. If nothing happens, double-press RESET on the board."))
        case .waitingForDrive:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Double-press RESET on the board", systemImage: "hand.tap").font(.headline)
                Text("Press the tiny RESET button next to the USB socket twice, quickly. The LED pulses and a drive called XIAO-SENSE appears; Trillium then installs the firmware by itself.")
                    .font(.callout).foregroundStyle(.secondary)
                #if os(iOS)
                Text("On iPhone and iPad, then choose the XIAO-SENSE drive once to allow access.").font(.caption).foregroundStyle(.secondary)
                Button("Allow access to XIAO-SENSE…") { pickDrive = true }.buttonStyle(.borderedProminent)
                #endif
                Button("Cancel", role: .cancel) { model.cancelFirmwareInstall() }.controlSize(.small)
            })
        case let .needsDriveAccess(url):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Allow Trillium to use the board's drive", systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text("The system needs your permission for Trillium to use the \(url.lastPathComponent) drive. You don't choose a file: firmware \(bundled) is inside Trillium. The firmware on the board is backed up first.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    #if os(macOS)
                    Button("Allow…") { model.requestDriveAccess(suggested: url) }.buttonStyle(.borderedProminent)
                    #else
                    Button("Allow…") { pickDrive = true }.buttonStyle(.borderedProminent)
                    #endif
                    Button("Cancel", role: .cancel) { model.cancelFirmwareInstall() }
                }
            })
        case let .working(what):
            return AnyView(progress(what, "Keep the board plugged in.", cancellable: false))
        case .waitingForBoard:
            return AnyView(progress("Waiting for Trillium to restart…", "The board restarts with the new firmware and reconnects."))
        case let .done(v, backup):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Firmware \(v.description) installed", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                Text(backup == nil ? "Trillium is connected and reports the new version."
                     : "Trillium is connected and reports the new version. The previous firmware was backed up.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("OK") { model.dismissFirmwareResult() }
                    #if os(macOS)
                    if backup != nil { Button("Show backup") { model.showBackupsInFinder() } }
                    #endif
                }
            })
        case let .failed(why):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Firmware not installed", systemImage: "xmark.octagon").font(.headline).foregroundStyle(.red)
                Text(why).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Try again") { model.startFirmwareInstall() }.buttonStyle(.borderedProminent)
                    Button("Dismiss") { model.dismissFirmwareResult() }
                }
            })
        }
    }

    private var idleContent: AnyView? {
        if model.bundledFirmware == nil {
            guard alwaysShow else { return nil }
            return AnyView(Label(model.bundledFirmwareError ?? "This build carries no firmware.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange))
        }
        if let h = model.session.hello, model.session.isReady, !h.hasMotionSensor {
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Label("This board isn't supported", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                Text("It is a XIAO nRF52840 without the motion sensor. Trillium needs the Seeed Studio XIAO nRF52840 Sense (the model with the microphone and motion sensor).")
                    .font(.callout).foregroundStyle(.secondary)
            })
        }
        switch model.firmwareStatus {
        case let .updateAvailable(installed, b)?:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Firmware update: \(installed.description) → \(b.description)", systemImage: "arrow.down.circle").font(.headline)
                Text("This version of the app comes with firmware \(b.description). Installing takes under a minute; the firmware on the board is backed up first.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Update firmware") { model.startFirmwareInstall() }.buttonStyle(.borderedProminent)
            })
        case let .newerThanApp(installed, b)?:
            return AnyView(Label("Trillium runs firmware \(installed.description), newer than the \(b.description) in this app. Update the Trillium app.",
                                 systemImage: "info.circle").font(.callout))
        case .current?:
            guard alwaysShow else { return nil }
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Firmware \(bundled) is up to date", systemImage: "checkmark.seal").foregroundStyle(.green)
                Button("Reinstall firmware \(bundled)") { model.startFirmwareInstall() }.controlSize(.small)
            })
        default:
            break
        }
        if !model.trillDetected, let drive = model.bootloaderDrives.first {
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("Board waiting for firmware", systemImage: "externaldrive").font(.headline)
                Text("A board is in bootloader mode (\(drive.lastPathComponent)). Install Trillium firmware \(bundled) to use it.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Install firmware \(bundled)") { model.startFirmwareInstall() }.buttonStyle(.borderedProminent)
            })
        }
        if !model.trillDetected, let other = model.otherBoards.first {
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Label("New board found", systemImage: "cpu").font(.headline)
                Text("\(other.summary) is connected but isn't running Trillium firmware yet. Install firmware \(bundled) to turn a Seeed Studio XIAO nRF52840 Sense into a Trillium.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Install firmware \(bundled)…") { model.startFirmwareInstall() }.buttonStyle(.borderedProminent)
            })
        }
        guard alwaysShow else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            Label("Firmware \(bundled) in this app", systemImage: "shippingbox").font(.headline)
            Text("Connect Trillium to check its firmware. To set up a new Seeed Studio XIAO nRF52840 Sense, plug it in and install the firmware.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Install firmware \(bundled) on a new board…") { model.startFirmwareInstall() }
        })
    }

    private func progress(_ title: String, _ detail: String, cancellable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.headline)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            if cancellable {
                Button("Cancel", role: .cancel) { model.cancelFirmwareInstall() }.controlSize(.small)
            }
        }
    }
}
