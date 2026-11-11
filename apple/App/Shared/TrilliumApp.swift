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
                PresetsView().tabItem { Label("Presets", systemImage: "square.grid.2x2") }.tag(AppTab.presets)
                SensorsView().tabItem { Label("Sensors", systemImage: "gyroscope") }.tag(AppTab.sensors)
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

/// Three-petal mark drawn in SwiftUI (no image assets).
struct TrilliumMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Ellipse()
                    .fill(LinearGradient(colors: [.purple.opacity(0.85), .pink.opacity(0.75)],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(width: size * 0.42, height: size * 0.62)
                    .offset(y: -size * 0.24)
                    .rotationEffect(.degrees(Double(i) * 120))
            }
            Circle().fill(.yellow.opacity(0.9)).frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                TrilliumMark(size: 110)
                Text("Trillium").font(.largeTitle.weight(.semibold))
                Text("Motion and touch to play any synth or music app").foregroundStyle(.secondary)
            }
        }
    }
}
