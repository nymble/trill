// SPDX-License-Identifier: GPL-3.0-only
//
// Live sensor dashboard. Data comes only from the device's telemetry
// stream (config port, firmware 0.3.0+). Charts are redrawn by the 30 Hz UI
// timer, never per frame; lines break at sequence gaps, invalid IMU frames
// and late frames, and are never extended past the last real sample.

import SwiftUI
import UniformTypeIdentifiers
import TrillKit

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// One plotted line. Colour is never the only cue: each series also has a
/// text label and its own dash pattern, repeated in the legend.
struct ChartSeries: Identifiable {
    let id: String
    let color: Color
    let dash: [CGFloat]
    let value: (TelemetryFrame) -> Double?

    static let x = (Color.red, [CGFloat]())
    static let y = (Color.green, [CGFloat(6), 3])
    static let z = (Color.blue, [CGFloat(2), 3])
}

struct LineChart: View {
    let title: String
    let unit: String
    let points: [TelemetryPoint]
    let series: [ChartSeries]
    let end: Double          // right edge, host time
    let window: Double
    let breakAfter: Double   // seconds between frames that counts as a gap
    var minSpan: Double = 0.2
    var fixed: ClosedRange<Double>? = nil

    private var range: ClosedRange<Double> {
        if let fixed { return fixed }
        var lo = Double.infinity, hi = -Double.infinity
        for p in points where p.hostTime >= end - window {
            for s in series { if let v = s.value(p.frame) { lo = min(lo, v); hi = max(hi, v) } }
        }
        guard lo.isFinite, hi.isFinite else { return -minSpan...minSpan }
        let mid = (lo + hi) / 2, half = max((hi - lo) / 2 * 1.15, minSpan / 2)
        return (mid - half)...(mid + half)
    }

    var body: some View {
        let r = range
        let latest = points.last?.frame
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text("(\(unit))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("last \(Int(window)) s").font(.caption2).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size, r) }
                VStack(alignment: .leading) {
                    Text(fmt(r.upperBound)); Spacer(); Text(fmt(r.lowerBound))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).padding(2)
            }
            .frame(minHeight: 110, idealHeight: 140)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 14) {
                ForEach(series) { s in
                    HStack(spacing: 4) {
                        DashSwatch(color: s.color, dash: s.dash)
                        Text(s.id).font(.caption.bold())
                        Text(latest.flatMap(s.value).map(fmt) ?? "–").font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) chart, \(unit)")
        .accessibilityValue(series.map { s in "\(s.id) \(latest.flatMap(s.value).map(fmt) ?? "no value")" }.joined(separator: ", "))
    }

    private func fmt(_ v: Double) -> String { String(format: abs(v) >= 100 ? "%.0f" : abs(v) >= 10 ? "%.1f" : "%.2f", v) }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ r: ClosedRange<Double>) {
        let start = end - window
        func x(_ t: Double) -> CGFloat { CGFloat((t - start) / window) * size.width }
        func y(_ v: Double) -> CGFloat {
            let c = min(max(v, r.lowerBound), r.upperBound)
            return size.height - CGFloat((c - r.lowerBound) / (r.upperBound - r.lowerBound)) * size.height
        }
        if r.contains(0) {
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
        }
        for s in series {
            var path = Path()
            var prevT: Double?
            var open = false
            for p in points where p.hostTime >= start - 0.5 {
                guard let v = s.value(p.frame) else { open = false; prevT = p.hostTime; continue }
                let pt = CGPoint(x: x(p.hostTime), y: y(v))
                let gap = p.gapBefore || prevT.map { p.hostTime - $0 > breakAfter } ?? true
                if !open || gap {
                    // Start a new segment; a dot keeps an isolated sample visible.
                    path.move(to: pt)
                    path.addEllipse(in: CGRect(x: pt.x - 0.75, y: pt.y - 0.75, width: 1.5, height: 1.5))
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
                open = true
                prevT = p.hostTime
            }
            ctx.stroke(path, with: .color(s.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: s.dash))
        }
    }
}

struct DashSwatch: View {
    let color: Color
    let dash: [CGFloat]
    var body: some View {
        Canvas { ctx, size in
            var p = Path(); p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
        }
        .frame(width: 22, height: 8)
        .accessibilityHidden(true)
    }
}

struct SensorsView: View {
    @EnvironmentObject var model: AppModel
    @State private var exporting: CSVDocument?
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    StatusBanner()
                    if model.session.isReady && model.session.supportsTelemetry { dashboard }
                    UnavailableNotes()
                }
                .padding()
            }
            .navigationTitle("Sensors")
            .onAppear { model.sensorsVisible = true }
            .onDisappear { model.sensorsVisible = false }
            .fileExporter(isPresented: $showExporter, document: exporting, contentType: .commaSeparatedText,
                          defaultFilename: "trill-sensors.csv") { _ in exporting = nil }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controlItems }
            VStack(alignment: .leading, spacing: 8) { controlItems }
        }
    }

    @ViewBuilder private var controlItems: some View {
        Toggle("Stream", isOn: $model.sensorsLive)
            .help("Ask the device for telemetry while this view is open")
        Picker("Rate", selection: $model.telemetryRateHz) {
            ForEach([10, 25, 50, 100], id: \.self) { Text("\($0) Hz").tag($0) }
        }
        .frame(maxWidth: 140)
        Button(model.sensorsPaused ? "Resume display" : "Pause display") { model.sensorsPaused.toggle() }
        Button("Reset") { model.resetSensors() }
        Button("Export CSV…") {
            exporting = CSVDocument(text: model.telemetry.csv())
            showExporter = true
        }
        .disabled(model.telemetry.points.isEmpty)
    }

    private var dashboard: some View {
        let t = model.telemetry
        let end = model.sensorsPaused ? (t.lastHostTime ?? model.clock) : model.clock
        let rate = Double(model.session.telemetryRate ?? model.telemetryRateHz)
        let brk = max(0.25, 4 / max(rate, 1))
        let imu: (Int) -> (TelemetryFrame) -> Double? = { i in { $0.imuValid ? $0.accel[i] : nil } }
        let gyro: (Int) -> (TelemetryFrame) -> Double? = { i in { $0.imuValid ? $0.gyro[i] : nil } }
        return VStack(alignment: .leading, spacing: 16) {
            LineChart(title: "Acceleration", unit: "g", points: t.points, series: [
                ChartSeries(id: "X", color: ChartSeries.x.0, dash: ChartSeries.x.1, value: imu(0)),
                ChartSeries(id: "Y", color: ChartSeries.y.0, dash: ChartSeries.y.1, value: imu(1)),
                ChartSeries(id: "Z", color: ChartSeries.z.0, dash: ChartSeries.z.1, value: imu(2)),
                ChartSeries(id: "|a|", color: .primary, dash: [8, 3, 2, 3], value: { f in
                    f.imuValid ? sqrt(f.accel.reduce(0) { $0 + $1 * $1 }) : nil }),
            ], end: end, window: t.window, breakAfter: brk, minSpan: 0.5)
            LineChart(title: "Rotation rate (gyro)", unit: "°/s", points: t.points, series: [
                ChartSeries(id: "X", color: ChartSeries.x.0, dash: ChartSeries.x.1, value: gyro(0)),
                ChartSeries(id: "Y", color: ChartSeries.y.0, dash: ChartSeries.y.1, value: gyro(1)),
                ChartSeries(id: "Z", color: ChartSeries.z.0, dash: ChartSeries.z.1, value: gyro(2)),
            ], end: end, window: t.window, breakAfter: brk, minSpan: 20)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { orientation(t, end, brk); TouchPanel(frame: t.latest).frame(maxWidth: 360) }
                VStack(alignment: .leading, spacing: 16) { orientation(t, end, brk); TouchPanel(frame: t.latest) }
            }
            HealthPanel()
            EventsPanel()
        }
    }

    private func orientation(_ t: TelemetryModel, _ end: Double, _ brk: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LineChart(title: "Orientation", unit: "°", points: t.points, series: [
                ChartSeries(id: "Pitch", color: .orange, dash: [], value: { $0.imuValid ? $0.pitch : nil }),
                ChartSeries(id: "Roll", color: .purple, dash: [6, 3], value: { $0.imuValid ? $0.roll : nil }),
            ], end: end, window: t.window, breakAfter: brk, fixed: -180...180)
            Text("Pitch = atan2(−ax, √(ay²+az²)), range ±90°; roll = atan2(ay, az), range ±180°; in the IMU's own axes, gyro-smoothed (complementary filter). No yaw/heading: the board has no magnetometer. Axis directions relative to the case are not yet verified.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Explains every state in which there is nothing to plot, instead of empty charts.
struct StatusBanner: View {
    @EnvironmentObject var model: AppModel

    private struct Info {
        let title: String
        let detail: String
        let icon: String
        let color: Color
    }

    var body: some View {
        let info = current()
        let failed = model.session.isReady && model.session.supportsTelemetry && model.session.telemetryError != nil
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).font(.headline)
                    Text(info.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: info.icon).foregroundStyle(info.color)
            }
            if failed {
                Button("Try again") { model.retryTelemetry() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(info.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func current() -> Info {
        let s: ConfigSession = model.session
        let t: TelemetryModel = model.telemetry
        let requested: Int = s.telemetryRate ?? model.telemetryRateHz
        if !s.isReady {
            return Info(title: "Not connected",
                        detail: "Connect to the Trill on the Device tab. Sensor data comes from the device's configuration port.",
                        icon: "cable.connector", color: .secondary)
        }
        if !s.supportsTelemetry {
            let fw: String = s.hello?.firmwareString ?? "?"
            return Info(title: "Sensors unsupported until the firmware is updated",
                        detail: "This device reports firmware \(fw); live sensor data needs \(TrillProtocol.telemetryMinimumFirmware) or newer. Install the matching UF2 (double-press RESET to show the XIAO-SENSE drive; see the Firmware tab). MIDI keeps working on the current firmware.",
                        icon: "exclamationmark.triangle", color: .orange)
        }
        if let e = s.telemetryError {
            return Info(title: "The device refused the sensor stream", detail: e, icon: "xmark.octagon", color: .red)
        }
        if model.sensorsPaused {
            let n: Int = model.liveTelemetry.framesReceived - model.framesAtPause
            return Info(title: "Display paused",
                        detail: "The device is still streaming: \(n) frames received since pausing. Resume to see them.",
                        icon: "pause.circle", color: .blue)
        }
        if !model.sensorsLive {
            return Info(title: "Stream off", detail: "Turn on Stream to request sensor data.", icon: "stop.circle", color: .secondary)
        }
        if t.isStale(now: model.clock, rateHz: requested) {
            if let age = t.age(now: model.clock) {
                return Info(title: "Sensor data is stale",
                            detail: String(format: "No frame for %.1f s. Values shown are the last ones received.", age),
                            icon: "hourglass", color: .orange)
            }
            return Info(title: "Waiting for sensor data…", detail: "Requested \(requested) Hz.", icon: "hourglass", color: .orange)
        }
        let detail: String = String(format: "%ld Hz requested, %.0f frames/s arriving. Telemetry is a sampled snapshot of the %.0f Hz IMU, not every sample.",
                                    requested, t.frameRate, t.imuRate)
        return Info(title: "Live", detail: detail, icon: "dot.radiowaves.left.and.right", color: .green)
    }
}

struct TouchPanel: View {
    let frame: TelemetryFrame?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trill touch").font(.headline)
            if let f = frame {
                if f.trillState != .running {
                    Label("Trill sensor not detected (\(f.trillState.title))", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                    Text("This is different from “no touch”: the firmware cannot talk to the Trill over I²C.").font(.caption).foregroundStyle(.secondary)
                } else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                            if let p = f.touchPosition {
                                let size = f.touchContact ?? 0
                                Circle().fill(Color.accentColor)
                                    .frame(width: 10 + 30 * size, height: 10 + 30 * size)
                                    .position(x: CGFloat(p) * g.size.width, y: g.size.height / 2)
                            }
                        }
                    }
                    .frame(height: 44)
                    .accessibilityHidden(true)
                    if let p = f.touchPosition {
                        Text(String(format: "Touch at %.3f, contact size %.3f", p, f.touchContact ?? 0)).font(.callout.monospacedDigit())
                    } else {
                        Text("No touch").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No data yet").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct HealthPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let t = model.telemetry
        let f = t.latest
        let rows: [(String, String)] = [
            ("IMU", f.map { $0.imuValid ? $0.imuState.title : "\($0.imuState.title) (no valid data)" } ?? "–"),
            ("Calibration", f.map { $0.calibrated ? "Gyro bias calibrated" : "Calibrating – keep still" } ?? "–"),
            ("IMU sample rate (device clock)", t.imuRate > 0 ? String(format: "%.0f Hz", t.imuRate) : "–"),
            ("Frames arriving (host clock)", String(format: "%.1f /s", t.frameRate)),
            ("Last frame", t.age(now: model.clock).map { String(format: "%.2f s ago", $0) } ?? "never"),
            ("Device time", t.points.last.map { String(format: "%.3f s (seq %d)", $0.deviceTime, $0.frame.seq) } ?? "–"),
            ("Frames received / missing", "\(t.framesReceived) / \(t.framesMissing)"),
            ("Skipped by device / dropped in app", "\(t.deviceSkipped) / \(t.bufferDropped)"),
            ("Safe mode", f.map { $0.safeMode ? "YES – see Firmware tab" : "no" } ?? "–"),
        ]
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream health").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0).foregroundStyle(.secondary)
                        Text(rows[i].1).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct EventsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let t = model.telemetry
        VStack(alignment: .leading, spacing: 4) {
            Text("Events").font(.headline)
            Text("Taps: \(t.tapsTotal) · Gyro calibrations: \(t.calibrationsTotal) (counted by the firmware since this view started)")
                .font(.callout)
            ForEach(Array(t.events.suffix(6).reversed().enumerated()), id: \.offset) { _, e in
                Text(String(format: "%@ ×%d, %.1f s ago", e.kind == .tap ? "Tap" : "Calibration", e.count, model.clock - e.hostTime))
                    .font(.caption.monospacedDigit())
            }
        }
    }
}

struct UnavailableNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not available").font(.headline)
            Text("Microphone: not streamed – the firmware does not read the board's PDM microphone.")
            Text("Battery: not measured – this firmware has no battery-voltage reading.")
            Text("Heading (yaw): no magnetometer on the XIAO nRF52840 Sense.")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
