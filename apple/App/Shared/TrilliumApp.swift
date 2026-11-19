// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
#if os(macOS)
import AppKit
#endif

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
        .onAppear {
            applyLaunchOverrides()
            #if os(macOS)
            applyMacWindowSize()
            #endif
        }
        .task {
            guard showSplash else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        }
    }

    /// Simulator and screenshot helpers (`--skip-splash`, `--tab=...`,
    /// `--settings=mapping`, `--sensors-page=overview|charts|linear`,
    /// `--window-size=WxH` on macOS). Ignored in normal launches.
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
        if let arg = args.first(where: { $0.hasPrefix("--settings=") }) {
            switch String(arg.dropFirst("--settings=".count)) {
            case "mapping":
                model.tab = .settings
                model.settingsPath = [.mapping]
            case "connection":
                model.tab = .settings
                model.settingsPath = [.connection]
            default: break
            }
        }
        if let arg = args.first(where: { $0.hasPrefix("--sensors-page=") }) {
            let page = String(arg.dropFirst("--sensors-page=".count))
            if ["overview", "charts", "linear"].contains(page) {
                model.tab = .sensors
                model.sensorsPageOverride = page
            }
        }
    }

    #if os(macOS)
    /// `--window-size=WIDTHxHEIGHT` in points (the whole window, including the title bar).
    private func applyMacWindowSize() {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") }) else { return }
        let parts = String(arg.dropFirst("--window-size=".count)).split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return }
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else { return }
            if let screen = win.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                let x = visible.midX - w / 2
                let y = visible.midY - h / 2
                win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            } else {
                win.setFrame(NSRect(x: 80, y: 80, width: w, height: h), display: true)
            }
        }
    }
    #endif
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
