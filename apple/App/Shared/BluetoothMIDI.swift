// SPDX-License-Identifier: GPL-3.0-only
//
// Bluetooth MIDI pairing through the system panels. The app never scans
// or connects by itself: CoreAudioKit's panel connects the BLE-MIDI
// device to CoreMIDI, and its source then appears next to the USB ports
// (the MIDI monitor uses it when no USB instrument source is present).
// iOS and iPadOS: CABTMIDICentralViewController. macOS:
// CABTLEMIDIWindowController, or Audio MIDI Setup › MIDI Studio.

import CoreAudioKit
import SwiftUI
import TrillKit

#if os(iOS)
import UIKit

/// The system Bluetooth MIDI device list, inside a navigation controller.
struct BluetoothMIDIPanel: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let central = CABTMIDICentralViewController()
        central.title = "Bluetooth MIDI"
        return UINavigationController(rootViewController: central)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
#else
import AppKit

enum BluetoothMIDIWindow {
    /// Kept alive while the window is open.
    private static var controller: CABTLEMIDIWindowController?

    static func show() {
        let c = controller ?? CABTLEMIDIWindowController()
        controller = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    static func openAudioMIDISetup() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
#endif

/// "Bluetooth MIDI…" button plus a one-line hint. USB stays the setup
/// path: settings and sensor data never use Bluetooth.
struct BluetoothMIDIButton: View {
    #if os(iOS)
    @State private var showPanel = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                #if os(iOS)
                Button {
                    showPanel = true
                } label: {
                    Label { Text("Bluetooth MIDI…") } icon: { TrilliumIcon(name: "wireless") }
                }
                #else
                Button {
                    BluetoothMIDIWindow.show()
                } label: {
                    Label { Text("Bluetooth MIDI…") } icon: { TrilliumIcon(name: "wireless") }
                }
                Button("Audio MIDI Setup") { BluetoothMIDIWindow.openAudioMIDISetup() }
                #endif
            }
            Text("Connect a battery-powered Trillium wirelessly. It is listed as \u{201C}Trillium\u{201D} plus a 4-character ID. Bluetooth carries the instrument only; use USB for settings and firmware.")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if os(iOS)
        .sheet(isPresented: $showPanel) { BluetoothMIDIPanel() }
        #endif
    }
}
