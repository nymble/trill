// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main
struct TrilliumApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if os(iOS)
        // Icon states (brand/BRAND.md): resting tabs in ash light; the selected tab takes the signal tint.
        UITabBar.appearance().unselectedItemTintColor = UIColor(Color.Trillium.ashLight)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .trilliumStage()
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 720)
        #endif
    }
}

enum AppTab: Hashable {
    case home, presets, sensors, settings
}

/// Four simple top-level screens; everything detailed lives under Settings.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("--skip-splash")

    var body: some View {
        ZStack {
            TabView(selection: $model.tab) {
                HomeView().tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
                PresetsView().tabItem { Label("Presets", image: "icon-presets") }.tag(AppTab.presets)
                SensorsView().tabItem { Label("Sensors", image: "icon-live-monitor") }.tag(AppTab.sensors)
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
            }
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear { applyLaunchOverrides() }
        .task {
            guard showSplash else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        }
    }

    /// Simulator and screenshot helpers (`--skip-splash`, `--tab=home|presets|sensors|settings`).
    /// Ignored in normal launches; the iOS Simulator has no USB MIDI device.
    private func applyLaunchOverrides() {
        let args = ProcessInfo.processInfo.arguments
        if let arg = args.first(where: { $0.hasPrefix("--tab=") }) {
            switch String(arg.dropFirst("--tab=".count)) {
            case "home": model.tab = .home
            case "presets": model.tab = .presets
            case "sensors": model.tab = .sensors
            case "settings": model.tab = .settings
            default: break
            }
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.Trillium.black).ignoresSafeArea()
            VStack(spacing: 20) {
                // Approved lockup (brand/wordmark/lockup-primary-transparent.svg): signal mark, warm-white word.
                Image("lockup-primary")
                    .resizable().scaledToFit().frame(width: 300)
                    .accessibilityLabel("Trillium")
                Text("Motion and touch to play any synth or music app").foregroundStyle(Color.Trillium.ash)
            }
        }
    }
}
