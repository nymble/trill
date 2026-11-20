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

/// Tab chrome without launch-arg side effects, so a dedicated screenshot
/// window can host it for App Store screenshots.
struct AppChromeView: View {
    @EnvironmentObject var model: AppModel
    var showSplash: Bool

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
    }
}

/// Four simple top-level screens; everything detailed lives under Settings.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSplash = !ProcessInfo.processInfo.arguments.contains("--skip-splash")

    var body: some View {
        AppChromeView(showSplash: showSplash)
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
    /// Point size of the offscreen App Store shot (16:10). Rendered at @2x
    /// to produce a 2880×1800 PNG, independent of the CI display.
    fileprivate static let screenshotPointSize = NSSize(width: 1440, height: 900)
    fileprivate static let screenshotPixelSize = (width: 2880, height: 1800)

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

    /// `--screenshot-out=PATH` renders the UI in its own 1440×900 pt window
    /// and writes an opaque RGB PNG after `--screenshot-delay=`
    /// seconds, then quits. The window may be larger than the display (the
    /// GitHub macos-15 display is 1024×684), so a small CI screen cannot clip it.
    /// The PNG comes from the window server at display scale; a view render
    /// at @2x is written next to it as `NAME-view.png` as a fallback.
    private func writeMacScreenshotIfRequested() {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--screenshot-out=") }) else { return }
        let path = String(arg.dropFirst("--screenshot-out=".count))
        let delay = Self.screenshotDelay()
        let points = Self.screenshotPointSize
        let root = AppChromeView(showSplash: false)
            .environmentObject(model)
            .trilliumStage()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(.dark)
        DispatchQueue.main.async {
            // Keep the regular window out of the way.
            for w in NSApp.windows { w.orderOut(nil) }
            let win = ScreenshotWindow(
                contentRect: NSRect(origin: .zero, size: points),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.appearance = NSAppearance(named: .darkAqua)
            win.backgroundColor = NSColor(srgbRed: 0.047, green: 0.047, blue: 0.051, alpha: 1)
            win.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: root)
            // The window sets the size (full 1440x900 frame, content under a
            // transparent title bar); the SwiftUI content must not grow it.
            hosting.sizingOptions = []
            win.contentView = hosting
            win.setFrame(NSRect(origin: .zero, size: points), display: true)
            win.orderFrontRegardless()
            Self.screenshotWindow = win
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.writeWindowScreenshot(win, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor private static var screenshotWindow: NSWindow?

    private static func screenshotDelay() -> TimeInterval {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--screenshot-delay=") }),
              let value = Double(arg.dropFirst("--screenshot-delay=".count)),
              value > 0 else { return 3.0 }
        return value
    }

    private static func launchWindowSize() -> NSSize? {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") }) else { return nil }
        let parts = String(arg.dropFirst("--window-size=".count)).split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return NSSize(width: w, height: h)
    }

    @MainActor
    private static func writeWindowScreenshot(_ win: NSWindow, to url: URL) {
        let points = screenshotPointSize
        let pixels = screenshotPixelSize
        guard let view = win.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // Fallback copy first (so it exists when the caller sees the main
        // PNG): the view hierarchy drawn into an explicit @2x bitmap.
        let alt = URL(fileURLWithPath: url.deletingPathExtension().path + "-view.png")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels.width,
            pixelsHigh: pixels.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            FileHandle.standardError.write(Data("screenshot: could not allocate @2x bitmap\n".utf8))
            return
        }
        rep.size = points
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else {
            FileHandle.standardError.write(Data("screenshot: @2x bitmap had no CGImage\n".utf8))
            return
        }
        writeOpaqueRGB(cg, to: alt, canvasWidth: pixels.width, canvasHeight: pixels.height)
        FileHandle.standardError.write(Data("screenshot: view wrote \(alt.path) \(cg.width)x\(cg.height)\n".utf8))
        // Main copy from the window server: includes the AppKit tab control
        // and title bar that a view render misses. Display scale, so
        // 1440x900 on a 1x CI display and 2880x1800 on Retina.
        if let shot = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]
        ) {
            writeOpaqueRGB(shot, to: url, canvasWidth: shot.width, canvasHeight: shot.height)
            FileHandle.standardError.write(Data("screenshot: window server wrote \(url.path) \(shot.width)x\(shot.height)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("screenshot: window server capture failed; only \(alt.path) written\n".utf8))
        }
    }

    /// Composite `image` onto an opaque Stage-black canvas and write an 8-bit RGB PNG.
    private static func writeOpaqueRGB(_ image: CGImage, to url: URL, canvasWidth: Int, canvasHeight: Int) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            FileHandle.standardError.write(Data("screenshot: no sRGB color space\n".utf8))
            return
        }
        guard let ctx = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            // CoreGraphics has no 24-bit RGB context; skip-last is opaque and
            // ImageIO writes it as a PNG without alpha.
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            FileHandle.standardError.write(Data("screenshot: could not allocate RGB context\n".utf8))
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 0.047, green: 0.047, blue: 0.051, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        ctx.interpolationQuality = .high
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        let scale = min(CGFloat(canvasWidth) / iw, CGFloat(canvasHeight) / ih)
        let dw = iw * scale
        let dh = ih * scale
        let dx = (CGFloat(canvasWidth) - dw) / 2
        let dy = (CGFloat(canvasHeight) - dh) / 2
        ctx.draw(image, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        guard let out = ctx.makeImage() else {
            FileHandle.standardError.write(Data("screenshot: could not snapshot RGB context\n".utf8))
            return
        }
        writePNG(out, to: url)
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
    #endif
}

#if os(macOS)
/// A window that may extend past the display, for fixed-size screenshots.
final class ScreenshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif

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
