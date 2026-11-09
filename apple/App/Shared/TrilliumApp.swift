// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main
struct TrilliumApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 720)
        #endif
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            DeviceView().tabItem { Label("Device", systemImage: "cable.connector") }
            SensorsView().tabItem { Label("Sensors", systemImage: "gyroscope") }
            MonitorView().tabItem { Label("MIDI", systemImage: "waveform.path.ecg") }
            MappingView().tabItem { Label("Mapping", systemImage: "slider.horizontal.3") }
            PresetsView().tabItem { Label("Presets", systemImage: "square.stack") }
            FirmwareView().tabItem { Label("Firmware", systemImage: "cpu") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}
