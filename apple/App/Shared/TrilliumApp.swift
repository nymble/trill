// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
            writeMacScreenshotIfRequested()
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
    /// Origin is (0, 0) so a size larger than the display is not centred and
    /// then clamped to the visible frame (GitHub macos-15 is 1024x684 @1x).
    private func applyMacWindowSize() {
        guard let size = Self.launchWindowSize() else { return }
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else { return }
            win.setFrame(NSRect(x: 0, y: 0, width: size.width, height: size.height), display: true)
        }
    }

    /// `--screenshot-out=PATH` writes a PNG of the window at `--window-size=`
    /// (falling back to a view bitmap if the display clips the window) and quits.
    private func writeMacScreenshotIfRequested() {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--screenshot-out=") }) else { return }
        let path = String(arg.dropFirst("--screenshot-out=".count))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            Self.writeMacScreenshot(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    private static func launchWindowSize() -> NSSize? {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") }) else { return nil }
        let parts = String(arg.dropFirst("--window-size=".count)).split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return NSSize(width: w, height: h)
    }

    private static func writeMacScreenshot(to url: URL) {
        guard let win = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else {
            FileHandle.standardError.write(Data("screenshot: no window\n".utf8))
            return
        }
        let target = launchWindowSize() ?? win.frame.size
        win.setFrame(NSRect(x: 0, y: 0, width: target.width, height: target.height), display: true)
        win.contentView?.layoutSubtreeIfNeeded()

        let scale = win.backingScaleFactor
        let pixel = NSSize(width: target.width * scale, height: target.height * scale)

        if let cg = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            CGWindowID(UInt32(win.windowNumber)),
            [.boundsIgnoreFraming, .bestResolution]
        ), cg.width == Int(pixel.width.rounded()), cg.height == Int(pixel.height.rounded()) {
            writePNG(cg, to: url)
            return
        }

        // Display clipped the window; render the frame view at the requested size.
        let frameView = win.contentView?.superview ?? win.contentView
        guard let view = frameView else {
            FileHandle.standardError.write(Data("screenshot: no content view\n".utf8))
            return
        }
        let bounds = NSRect(origin: .zero, size: target)
        view.setFrameSize(target)
        view.layoutSubtreeIfNeeded()
        win.contentView?.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            FileHandle.standardError.write(Data("screenshot: could not allocate bitmap\n".utf8))
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
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
