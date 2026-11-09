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
        Form {
            Section {
                HStack(spacing: 14) {
                    TrilliumMark(size: 48)
                    VStack(alignment: .leading) {
                        Text("Trillium").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                }
                Text("Trillium is a small instrument that turns touch and movement into MIDI. Slide along its touch strip, tilt, turn, tap or strike it, and it plays any synth or music app over a USB cable.")
                Text("This app chooses Trillium's sound, shows its sensors live and lets you fine-tune every mapping.")
                    .foregroundStyle(.secondary)
            }
            Section("Hardware") {
                Text("A Bela Trill Flex touch sensor and a Seeed XIAO nRF52840 Sense board with a motion sensor (accelerometer and gyroscope), connected as a standard USB MIDI device.")
                Text("Development build: the SysEx ID 0x7D and USB IDs 1209:0002/1209:0003 are test identifiers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("License") {
                Text("GPL-3.0-only. A separate commercial license is available from the copyright holder; see COMMERCIAL-LICENSE.md. Source: github.com/nymble/trill")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
