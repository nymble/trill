// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import TrillKit

struct AboutView: View {
    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trillium \(version)") {
                    Text("Trillium monitors and configures the Trill Flex + XIAO nRF52840 Sense instrument over class-compliant USB MIDI. Configuration protocol v\(TrillProtocol.version).")
                    Text("Trill is the Bela sensor; Trillium is this app. Development build. The SysEx manufacturer ID 0x7D and the USB IDs 1209:0002/1209:0003 are development/test identifiers, not product identifiers.")
                        .foregroundStyle(.secondary)
                }
                Section("Not in this version") {
                    Text("Bluetooth MIDI or any wireless connection (the firmware has no BLE), over-the-air updates, settings saved on the device, and host-side MIDI processing or virtual MIDI ports.")
                }
                Section("License") {
                    Text("GPL-3.0-only. A separate commercial license is available from the copyright holder; see COMMERCIAL-LICENSE.md. Source: github.com/nymble/trill")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("About")
        }
    }
}
