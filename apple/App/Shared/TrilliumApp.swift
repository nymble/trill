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
                SplashView(skip: { withAnimation(.easeOut(duration: 0.15)) { showSplash = false } })
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear { applyLaunchOverrides() }
        .task {
            // Intro: 0.95 s on screen plus a 0.25 s fade = 1.2 s; a tap skips it.
            guard showSplash else { return }
            try? await Task.sleep(nanoseconds: 950_000_000)
            withAnimation(.easeOut(duration: 0.25)) { showSplash = false }
        }
    }

    /// Simulator and screenshot helpers (`--skip-splash`, `--tab=home|presets|sensors|settings|instrument`,
    /// `--instrument-demo` for synthetic motion in the instrument view).
    /// Ignored in normal launches; the iOS Simulator has no USB MIDI device.
    private func applyLaunchOverrides() {
        let args = ProcessInfo.processInfo.arguments
        if let arg = args.first(where: { $0.hasPrefix("--tab=") }) {
            switch String(arg.dropFirst("--tab=".count)) {
            case "home": model.tab = .home
            case "presets": model.tab = .presets
            case "sensors": model.tab = .sensors
            case "settings": model.tab = .settings
            case "instrument":
                model.tab = .presets
                model.showInstrument = true
            default: break
            }
        }
        if args.contains("--instrument-demo") { model.startInstrumentDemo() }
    }
}

/// Startup intro (≤ 1.2 s, tap to skip): the Light trails key visual draws
/// itself as rose curves r = cos 3θ, then the approved lockup appears below
/// it. The Rhodonea mark is never animated, redrawn or recoloured (brand/BRAND.md
/// section 2); the lockup image is shown as is. With Reduce Motion the trails
/// appear without drawing.
struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var lockupShown = false
    var skip: () -> Void

    init(skip: @escaping () -> Void = {}) { self.skip = skip }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.Trillium.black).ignoresSafeArea()
            VStack(spacing: 24) {
                LightTrails(progress: drawn)
                    .frame(width: 220, height: 220)
                    .accessibilityHidden(true)
                VStack(spacing: 14) {
                    // Approved lockup (brand/wordmark/lockup-primary-transparent.svg): signal mark, warm-white word.
                    Image("lockup-primary")
                        .resizable().scaledToFit().frame(width: 260)
                        .accessibilityLabel("Trillium")
                    Text("Motion and touch to play any synth or music app").foregroundStyle(Color.Trillium.ash)
                }
                .opacity(lockupShown ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the intro")
        .onAppear {
            if reduceMotion {
                drawn = 1; lockupShown = true
            } else {
                withAnimation(.easeOut(duration: 0.65)) { drawn = 1 }
                withAnimation(.easeOut(duration: 0.3).delay(0.35)) { lockupShown = true }
            }
        }
    }
}

/// The Light trails visual (brand/visuals): layered rose curves r = cos 3θ,
/// one petal up, signal-to-amber, drawn by `progress` (0…1). Layers follow
/// the kit's SVG: a soft glow, the main line, a fainter outer echo and a
/// slightly turned inner echo.
struct LightTrails: View {
    var progress: CGFloat

    var body: some View {
        let gradient = LinearGradient(colors: [Color.Trillium.signal, Color.Trillium.amber],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            RoseCurve(scale: 1).trim(from: 0, to: progress)
                .stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .blur(radius: 6).opacity(0.6)
            RoseCurve(scale: 1.133).trim(from: 0, to: progress)
                .stroke(gradient, style: StrokeStyle(lineWidth: 0.8, lineCap: .round)).opacity(0.4)
            RoseCurve(scale: 0.907, turn: -3).trim(from: 0, to: progress)
                .stroke(gradient, style: StrokeStyle(lineWidth: 1.2, lineCap: .round)).opacity(0.65)
            RoseCurve(scale: 1).trim(from: 0, to: progress)
                .stroke(gradient, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            Circle().fill(Color.Trillium.warmWhite).frame(width: 5, height: 5).opacity(Double(progress))
        }
    }
}

/// Rose curve r = cos 3θ (three petals, one pointing up) in one stroke.
struct RoseCurve: Shape {
    var scale: CGFloat = 1
    /// Extra turn in degrees (the kit's inner echo is turned slightly).
    var turn: Double = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Fit the largest echo (1.133 × the main curve) inside the frame.
        let R = min(rect.width, rect.height) / 2 / 1.133 * scale
        var p = Path()
        let steps = 240
        for i in 0...steps {
            let th = Double(i) / Double(steps) * .pi
            let r = R * CGFloat(cos(3 * th))
            let a = th + turn * .pi / 180
            let pt = CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
