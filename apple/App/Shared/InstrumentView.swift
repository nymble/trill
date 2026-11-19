// SPDX-License-Identifier: GPL-3.0-only
//
// Instrument view (prototype): one screen with feedback and adjustment for
// the handpan instrument. Strikes are detected in the app from telemetry
// (TrillKit ImpulseEngine) and played through the app's own MIDI source.
// Reached from Presets; optional, and nothing else changes when it is
// closed. Design: black ground, hairlines, labels in place of legends;
// orange only for the live strike and the switch that is on, amber for the
// last hit and levels. See docs/instrument-view.md.

import SwiftUI
import TrillKit

struct InstrumentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { g in
            ScrollView {
                Group {
                    if g.size.width > 760 {
                        HStack(alignment: .top, spacing: 20) {
                            feedback.frame(maxWidth: .infinity)
                            InstrumentControls().frame(width: 330)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            feedback
                            InstrumentControls()
                        }
                    }
                }
                .padding()
            }
        }
        .trilliumGround()
        .navigationTitle("Instrument")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { model.instrumentVisible = true }
        .onDisappear { model.instrumentVisible = false }
    }

    private var feedback: some View {
        let snap = model.instrumentSnapshot
        let prefs = model.instrumentPrefs
        return VStack(alignment: .leading, spacing: 14) {
            InstrumentStatusLine(snapshot: snap, prefs: prefs, live: model.session.isReady || model.instrumentDemo != nil,
                                 midiOn: model.instrumentMIDIOn)
            InstrumentRing(snapshot: snap, prefs: prefs)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            TiltStrip(readout: snap.readout, settings: prefs.settings)
            HStack(alignment: .top, spacing: 24) {
                RollReadout(readout: snap.readout, up: prefs.settings.up) { model.resetInstrumentRoll() }
                StrengthTrace(snapshot: snap, settings: prefs.settings)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Status line

private struct InstrumentStatusLine: View {
    let snapshot: InstrumentRunner.Snapshot
    let prefs: InstrumentPrefs
    let live: Bool
    let midiOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(prefs.scale.title(dingMIDI: prefs.dingMIDI)).font(.title2.weight(.semibold))
                Text(snapshot.readout.ring.title)
                    .font(.callout.monospaced())
                    .foregroundStyle(Color.Trillium.ashLight)
                if snapshot.readout.upsideDown {
                    Text("INVERTED").font(.caption.monospaced().weight(.semibold)).foregroundStyle(Color.Trillium.amber)
                        .accessibilityLabel("Upside down")
                }
                Spacer()
                if let s = snapshot.lastStrike, let n = snapshot.lastNote {
                    Text("\(n.name)  \(s.sector.map { CompassSector.names[$0] } ?? "ding")  v\(s.velocity)")
                        .font(.body.monospaced())
                        .foregroundStyle(Color.Trillium.amber)
                        .accessibilityLabel("Last strike \(n.name), velocity \(s.velocity)")
                }
            }
            Text(statusText).font(.caption).foregroundStyle(Color.Trillium.ash)
        }
    }

    private var statusText: String {
        var parts: [String] = []
        parts.append(live ? (snapshot.readout.gravityValid ? "Motion live" : "Waiting for motion data") : "Not connected: connect on Home to see live motion")
        parts.append(midiOn ? "Playing to \(AppMIDISource.defaultName), channel \(prefs.channel + 1)" : "App-generated MIDI off")
        return parts.joined(separator: " · ")
    }
}

// MARK: Compass ring

/// Eight sectors labelled with their notes; the live push as a radial line
/// against threshold circles; the last hit outlined; recent strikes as dots.
struct InstrumentRing: View {
    let snapshot: InstrumentRunner.Snapshot
    let prefs: InstrumentPrefs

    var body: some View {
        Canvas { ctx, size in
            draw(&ctx, size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let hp = prefs.handpan
        let notes = (0..<8).map { "\(CompassSector.names[$0]) \(hp.note(sector: $0, ring: snapshot.readout.ring == .second ? .second : .first).name)" }
        return "Strike directions: " + notes.joined(separator: ", ")
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ deg: Double) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }

    private func wedge(_ c: CGPoint, r0: CGFloat, r1: CGFloat, sector: Int) -> Path {
        let a0 = Double(sector) * 45 - 22.5, a1 = a0 + 45
        var p = Path()
        // SwiftUI angles: 0 = +x, clockwise on screen; compass 0 = up.
        p.addArc(center: c, radius: r1, startAngle: .degrees(a0 - 90), endAngle: .degrees(a1 - 90), clockwise: false)
        p.addArc(center: c, radius: r0, startAngle: .degrees(a1 - 90), endAngle: .degrees(a0 - 90), clockwise: true)
        p.closeSubpath()
        return p
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let s = prefs.settings
        let rd = snapshot.readout
        let hp = prefs.handpan
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 - 2
        let band0 = R * 0.72          // inner edge of the label band
        let rP = R * 0.68             // push scale: full velocity
        let full = max(s.fullVelocityRatio, 1.01)
        func radius(_ strength: Double) -> CGFloat { rP * CGFloat(sqrt(max(0, min(strength, full)) / full)) }
        let hair = StrokeStyle(lineWidth: 1)
        let now = snapshot.historyTimes.last ?? 0
        let active = rd.strength >= 1 && rd.gravityValid
        let pushAngle = atan2(rd.push.east, rd.push.north) * 180 / .pi
        let activeSector = active ? CompassSector.index(angle: pushAngle) : nil

        // Active sector (live strike): the one orange area.
        if let a = activeSector, rd.ring != .ding {
            ctx.fill(wedge(c, r0: band0, r1: R, sector: a), with: .color(Color.Trillium.signal.opacity(0.35)))
        }
        // Last hit: amber outline, brighter while fresh.
        if let last = snapshot.lastStrike, let sec = last.sector {
            let fresh = now - snapshot.lastStrikeHostTime < 1.5
            ctx.stroke(wedge(c, r0: band0, r1: R, sector: sec),
                       with: .color(Color.Trillium.amber.opacity(fresh ? 1 : 0.45)), style: StrokeStyle(lineWidth: fresh ? 2 : 1))
        }

        // Band edges and sector boundaries (hairlines).
        ctx.stroke(circle(c, R), with: .color(Color.Trillium.unavailable), style: hair)
        ctx.stroke(circle(c, band0), with: .color(Color.Trillium.unavailable), style: hair)
        for k in 0..<8 {
            var p = Path()
            p.move(to: point(c, band0, Double(k) * 45 + 22.5))
            p.addLine(to: point(c, R, Double(k) * 45 + 22.5))
            ctx.stroke(p, with: .color(Color.Trillium.unavailable), style: hair)
        }

        // Labels: compass point, ring 1 note, ring 2 note (current ring bright).
        let ringOneOn = rd.ring == .first, ringTwoOn = rd.ring == .second
        let labelSize = max(11, min(20, R * 0.085))
        for k in 0..<8 {
            let a = Double(k) * 45
            ctx.draw(Text(CompassSector.names[k]).font(.system(size: max(8, labelSize * 0.5), weight: .medium).monospaced())
                        .foregroundColor(Color.Trillium.ash),
                     at: point(c, R * 0.945, a))
            ctx.draw(Text(hp.note(sector: k, ring: .first).name)
                        .font(.system(size: labelSize, weight: ringOneOn ? .semibold : .regular).monospaced())
                        .foregroundColor(ringOneOn ? Color.Trillium.warmWhite : Color.Trillium.ash),
                     at: point(c, R * 0.855, a))
            ctx.draw(Text(hp.note(sector: k, ring: .second).name)
                        .font(.system(size: labelSize * 0.62, weight: ringTwoOn ? .semibold : .regular).monospaced())
                        .foregroundColor(ringTwoOn ? Color.Trillium.warmWhite : Color.Trillium.ash),
                     at: point(c, R * 0.765, a))
        }

        // Push scale: re-arm (dotted), threshold (dashed, labelled), full velocity (hairline).
        ctx.stroke(circle(c, rP), with: .color(Color.Trillium.unavailable), style: hair)
        ctx.stroke(circle(c, radius(s.rearmRatio)), with: .color(Color.Trillium.unavailable), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        ctx.stroke(circle(c, radius(1)), with: .color(Color.Trillium.ashLight), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        let small = Font.system(size: max(8, labelSize * 0.5)).monospaced()
        ctx.draw(Text(String(format: "%.2f g", s.accelThreshold)).font(small).foregroundColor(Color.Trillium.ashLight),
                 at: CGPoint(x: c.x + radius(1) * 0.72 + 4, y: c.y + radius(1) * 0.72 + 4), anchor: .topLeading)
        ctx.draw(Text("v127").font(small).foregroundColor(Color.Trillium.ash),
                 at: CGPoint(x: c.x + rP * 0.72 + 2, y: c.y + rP * 0.72 + 2), anchor: .topLeading)

        // Recent strikes as dots at their direction and strength.
        let recent = snapshot.recentStrikes.filter { $0.sector != nil }
        for (i, st) in recent.enumerated() {
            let p = point(c, radius(st.strength), st.angle)
            let op = 0.25 + 0.6 * Double(i + 1) / Double(max(recent.count, 1))
            ctx.fill(circle(p, 2.5), with: .color(Color.Trillium.ashLight.opacity(op)))
        }

        // Lean of the up axis: a notch on the inner band edge.
        if rd.gravityValid, rd.tilt > 3 {
            var p = Path()
            p.move(to: point(c, band0 - 2, rd.tiltHeading - 4))
            p.addLine(to: point(c, band0 - 10, rd.tiltHeading))
            p.addLine(to: point(c, band0 - 2, rd.tiltHeading + 4))
            ctx.stroke(p, with: .color(Color.Trillium.warmWhite), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }

        // Ding in the centre.
        let rDing = R * 0.11
        let dingOn = rd.ring == .ding
        if dingOn, active { ctx.fill(circle(c, rDing), with: .color(Color.Trillium.signal.opacity(0.35))) }
        if let last = snapshot.lastStrike, last.sector == nil {
            ctx.stroke(circle(c, rDing), with: .color(Color.Trillium.amber), style: StrokeStyle(lineWidth: 2))
        } else {
            ctx.stroke(circle(c, rDing), with: .color(Color.Trillium.unavailable), style: hair)
        }
        ctx.draw(Text(hp.ding.name).font(.system(size: labelSize * 0.8, weight: dingOn ? .semibold : .regular).monospaced())
                    .foregroundColor(dingOn ? Color.Trillium.warmWhite : Color.Trillium.ash), at: c)

        // Live push: radial line, amber below threshold, orange above.
        if rd.gravityValid, rd.strength > 0.05 {
            let tip = point(c, radius(rd.strength), pushAngle)
            var p = Path()
            p.move(to: point(c, rDing, pushAngle))
            p.addLine(to: tip)
            let col = active ? Color.Trillium.signal : Color.Trillium.amber
            ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.fill(circle(tip, 3.5), with: .color(col))
        }
    }
}

// MARK: Tilt zones

/// Tilt from vertical (0–90°, upside down folded) with the ring zones as areas.
struct TiltStrip: View {
    let readout: ImpulseReadout
    let settings: ImpulseSettings

    var body: some View {
        let r2 = max(0, min(90, settings.ring2Tilt))
        let dg = max(r2, min(90, settings.dingTilt))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tilt").font(.caption.weight(.semibold)).foregroundStyle(Color.Trillium.ashLight)
                Spacer()
                Text(readout.gravityValid ? "\(Int(readout.tilt.rounded()))° from \(readout.upsideDown ? "down" : "up")" : "–")
                    .font(.caption.monospaced()).foregroundStyle(Color.Trillium.warmWhite)
            }
            Canvas { ctx, size in
                let w = size.width, h = size.height
                func x(_ deg: Double) -> CGFloat { CGFloat(deg / 90) * w }
                let zones: [(Double, Double, HandpanRing)] = [(0, r2, .first), (r2, dg, .second), (dg, 90, .ding)]
                for (a, b, ring) in zones where b > a {
                    let rect = CGRect(x: x(a), y: 0, width: max(0, x(b) - x(a) - 1), height: h - 14)
                    let on = readout.ring == ring && readout.gravityValid
                    ctx.fill(Path(rect), with: .color(on ? Color.Trillium.warmWhite.opacity(0.16) : Color.Trillium.graphite))
                    ctx.draw(Text(ring.title).font(.system(size: 10).monospaced())
                                .foregroundColor(on ? Color.Trillium.warmWhite : Color.Trillium.ash),
                             at: CGPoint(x: x(a) + 6, y: (h - 14) / 2), anchor: .leading)
                }
                for deg in [0, r2, dg, 90] {
                    ctx.draw(Text("\(Int(deg))°").font(.system(size: 9).monospaced()).foregroundColor(Color.Trillium.ash),
                             at: CGPoint(x: min(max(x(deg), 8), w - 10), y: h - 6))
                }
                if readout.gravityValid {
                    var p = Path()
                    let tx = x(min(90, readout.tilt))
                    p.move(to: CGPoint(x: tx, y: -1))
                    p.addLine(to: CGPoint(x: tx, y: h - 13))
                    ctx.stroke(p, with: .color(Color.Trillium.warmWhite), style: StrokeStyle(lineWidth: 2))
                }
            }
            .frame(height: 36)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tilt \(Int(readout.tilt.rounded())) degrees, \(readout.ring.title)")
    }
}

// MARK: Roll

/// Multi-turn roll about the up axis: whole turns plus degrees, not wrapped.
struct RollReadout: View {
    let readout: ImpulseReadout
    let up: UpAxis
    let reset: () -> Void

    var body: some View {
        let t = readout.rollTurns
        VStack(alignment: .leading, spacing: 4) {
            Text("Roll about up").font(.caption.weight(.semibold)).foregroundStyle(Color.Trillium.ashLight)
            HStack(spacing: 10) {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 2
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(Color.Trillium.unavailable), style: StrokeStyle(lineWidth: 1))
                    let a = t.degrees * .pi / 180
                    var p = Path()
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a))))
                    ctx.stroke(p, with: .color(Color.Trillium.warmWhite), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%+.0f°", readout.roll)).font(.title3.monospaced())
                    Text("\(t.turns >= 0 ? "+" : "")\(t.turns) turn\(abs(t.turns) == 1 ? "" : "s") \(String(format: "%+.0f°", t.degrees))")
                        .font(.caption.monospaced()).foregroundStyle(Color.Trillium.ash)
                }
            }
            HStack(spacing: 8) {
                Text("Up \(up.title)").font(.caption.monospaced()).foregroundStyle(Color.Trillium.ash)
                Button("Reset", action: reset).font(.caption).buttonStyle(.trilliumSecondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Strength over time

/// Push strength over the last 3 s against the threshold, with strike ticks.
struct StrengthTrace: View {
    let snapshot: InstrumentRunner.Snapshot
    let settings: ImpulseSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Push, last 3 s").font(.caption.weight(.semibold)).foregroundStyle(Color.Trillium.ashLight)
                Spacer()
                Text("\(snapshot.strikes) strikes").font(.caption.monospaced()).foregroundStyle(Color.Trillium.ash)
            }
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let end = snapshot.historyTimes.last ?? 0
                let span = InstrumentRunner.historySeconds
                let full = max(settings.fullVelocityRatio, 1.01)
                func x(_ t: Double) -> CGFloat { CGFloat((t - (end - span)) / span) * w }
                func y(_ s: Double) -> CGFloat { h - CGFloat(min(s, full) / full) * (h - 2) - 1 }
                var th = Path()
                th.move(to: CGPoint(x: 0, y: y(1)))
                th.addLine(to: CGPoint(x: w, y: y(1)))
                ctx.stroke(th, with: .color(Color.Trillium.ashLight), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                for t in snapshot.strikeTimes {
                    var p = Path()
                    p.move(to: CGPoint(x: x(t), y: 0))
                    p.addLine(to: CGPoint(x: x(t), y: h))
                    ctx.stroke(p, with: .color(Color.Trillium.amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1))
                }
                var line = Path()
                for (i, (t, s)) in zip(snapshot.historyTimes, snapshot.history).enumerated() {
                    let pt = CGPoint(x: x(t), y: y(s))
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                ctx.stroke(line, with: .color(Color.Trillium.warmWhite), style: StrokeStyle(lineWidth: 1))
            }
            .frame(height: 52)
            .background(Rectangle().stroke(Color.Trillium.unavailable, lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Push strength over the last 3 seconds, \(snapshot.strikes) strikes")
    }
}

// MARK: Controls

/// Compact controls: instrument, detection, tilt, up, output.
struct InstrumentControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Instrument") {
                row("Scale") {
                    Picker("Scale", selection: $model.instrumentPrefs.scaleID) {
                        ForEach(HandpanScale.all) { s in Text(s.name).tag(s.id) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .onChange(of: model.instrumentPrefs.scaleID) { id in
                        if let s = HandpanScale.named(id) { model.instrumentPrefs.dingMIDI = s.ding.midi }
                    }
                }
                row("Ding") {
                    Picker("Ding", selection: $model.instrumentPrefs.dingMIDI) {
                        ForEach(Array(HandpanScale.dingRange), id: \.self) { m in Text(SpelledNote.ding(midi: m).name).tag(m) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                Picker("Layout", selection: $model.instrumentPrefs.layout) {
                    Text("Clockwise").tag(HandpanLayout.clockwise)
                    Text("Alternating").tag(HandpanLayout.alternating)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(model.instrumentPrefs.handpan.toneFields.map(\.name).joined(separator: " "))
                    .font(.caption.monospaced()).foregroundStyle(Color.Trillium.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section("Detection") {
                Picker("Mounting", selection: $model.instrumentPrefs.settings.mounting) {
                    ForEach(Mounting.allCases, id: \.self) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden()
                slider("Threshold", $model.instrumentPrefs.settings.accelThreshold, 0.2...2.0, step: 0.05) { String(format: "%.2f g", $0) }
                slider("Swing", $model.instrumentPrefs.settings.swingThreshold, 40...400, step: 10) { String(format: "%.0f °/s", $0) }
                    .disabled(model.instrumentPrefs.settings.mounting == .free)
                slider("Sensitivity", $model.instrumentPrefs.settings.fullVelocityRatio, 1.5...8, step: 0.5) { String(format: "127 at %.1f×", $0) }
                slider("Debounce", $model.instrumentPrefs.settings.debounce, 0...0.06, step: 0.01) { String(format: "%.0f ms", $0 * 1000) }
                slider("Refractory", $model.instrumentPrefs.settings.refractory, 0.05...0.5, step: 0.01) { String(format: "%.0f ms", $0 * 1000) }
                Toggle("Use the board's tap count", isOn: $model.instrumentPrefs.settings.tapAssist).font(.callout)
            }
            section("Tilt") {
                slider("Ring 2 from", $model.instrumentPrefs.settings.ring2Tilt, 10...80, step: 5) { String(format: "%.0f°", $0) }
                slider("Ding from", $model.instrumentPrefs.settings.dingTilt, 20...90, step: 5) { $0 >= 90 ? "off" : String(format: "%.0f°", $0) }
            }
            section("Up and N") {
                row("Up axis") {
                    Picker("Up axis", selection: $model.instrumentPrefs.settings.up) {
                        ForEach(UpAxis.axes, id: \.self) { a in Text(a.title).tag(a) }
                        if case .custom = model.instrumentPrefs.settings.up {
                            Text("Set pose").tag(model.instrumentPrefs.settings.up)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                HStack {
                    Button("Set current pose as up") { model.setCurrentPoseAsUp() }
                        .disabled(!model.instrumentSnapshot.readout.gravityValid)
                    Button("Make last strike N") { model.makeLastStrikeNorth() }
                        .disabled(model.instrumentSnapshot.lastStrike?.sector == nil)
                }
                .buttonStyle(.trilliumSecondary).font(.callout)
                Text("N is where the board's \(axisName(model.instrumentPrefs.settings.up)) points, turned \(model.instrumentPrefs.settings.northOffset * 45)°.")
                    .font(.caption).foregroundStyle(Color.Trillium.ash)
            }
            section("Output") {
                Toggle("App-generated MIDI", isOn: Binding(get: { model.instrumentMIDIOn }, set: { model.setInstrumentMIDI($0) }))
                if let e = model.instrumentMIDIError {
                    Text(e).font(.caption).foregroundStyle(Color.Trillium.amber)
                }
                Stepper(value: $model.instrumentPrefs.channel, in: 0...15) {
                    Text("Channel \(model.instrumentPrefs.channel + 1)").font(.callout.monospaced())
                }
                slider("Note length", $model.instrumentPrefs.gate, 0.05...2, step: 0.05) { String(format: "%.2f s", $0) }
                Text("Music apps see a source named \u{201C}\(AppMIDISource.defaultName)\u{201D}. Notes come from motion data sent over USB at \(InstrumentPrefs.telemetryRateHz) Hz, so they arrive about 10–40 ms after the strike. Pick a preset without strikes, or ignore Trillium's own port, to avoid doubled notes.")
                    .font(.caption).foregroundStyle(Color.Trillium.ash)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func axisName(_ up: UpAxis) -> String {
        let f = up.forward
        let axes = [(f.x, "X"), (f.y, "Y"), (f.z, "Z")]
        guard let m = axes.max(by: { abs($0.0) < abs($1.0) }), abs(m.0) > 0.9 else { return "forward mark" }
        return (m.0 > 0 ? "+" : "−") + m.1 + " axis"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Color.Trillium.ash).tracking(0.8)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.Trillium.graphite))
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            content()
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        _ format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value.wrappedValue)).font(.callout.monospaced()).foregroundStyle(Color.Trillium.ashLight)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

/// Entry on the Presets screen.
struct InstrumentEntryCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Handpan instrument (prototype)").font(.headline)
                Text("Strike the sensor on a stick or a string in 8 directions to play a handpan scale; tilt for more notes. Feedback and settings on one screen.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open instrument view") { model.showInstrument = true }
                .buttonStyle(.trilliumSecondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.Trillium.graphite))
    }
}
