// SPDX-License-Identifier: GPL-3.0-only
//
// Sensors › Overview: the motion data as a player thinks about it: how the
// instrument is held, how much it is moving, what the current sound does
// with that, and which way the last strike went. Built from the telemetry
// stream (port 2) and the notes Trillium sends (port 1).

import SwiftUI
import TrillKit

struct MotionOverview: View {
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)]

    var body: some View {
        let f = model.telemetry.latest
        let cfg = model.session.acknowledged ?? model.draft
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            Card {
                Text("How it's held").font(.headline)
                if let f, f.imuValid {
                    BoardPose(pitch: f.pitch, roll: f.roll, touch: f.touchPosition)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                    HStack {
                        Label(String(format: "Tilt %+.0f°", f.pitch), systemImage: "arrow.up.and.down")
                        Spacer()
                        Label(String(format: "Roll %+.0f°", f.roll), systemImage: "arrow.left.and.right")
                    }
                    .font(.callout.monospacedDigit())
                    Text(pose(f)).font(.caption).foregroundStyle(.secondary)
                } else {
                    noMotion(f)
                }
            }
            Card {
                Text("Level").font(.headline)
                if let f, f.imuValid {
                    let mode = SensorMode(rawValue: cfg[.mode]) ?? .touch
                    BubbleLevel(pitch: f.pitch, roll: f.roll,
                                gate: mode == .touch || mode == .tiltStrike ? nil : Double(cfg[.gateDeg]),
                                span: Double(cfg[.tiltSpanDeg]),
                                octaveLines: mode == .tiltStrike && cfg[.registerTilt] == 1 ? Double(cfg[.gateDeg]) : nil)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                    Text("The dot moves like a bubble: right when rolled right, up when tilted forward. In tilt modes the band is where notes sound and the side marks are the ends of the range.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    noMotion(f)
                }
            }
            Card {
                Text("Movement").font(.headline)
                if let f, f.imuValid {
                    let rot = sqrt(f.gyro.reduce(0) { $0 + $1 * $1 })
                    let shake = abs(sqrt(f.accel.reduce(0) { $0 + $1 * $1 }) - 1)
                    MotionMeter(title: "Turning", value: rot, full: Double(cfg[.rotationFullDps]), text: String(format: "%.0f °/s", rot))
                    MotionMeter(title: "Shake / impact", value: shake, full: Double(cfg[.tapThresholdCg]) / 100,
                          text: String(format: "%.2f g", shake), mark: 1)
                    HStack(spacing: 6) {
                        Image(systemName: rot < 4 && shake < 0.05 ? "pause.circle" : "figure.wave")
                        Text(rot < 4 && shake < 0.05 ? "Still" : "Moving")
                        Spacer()
                        Image(systemName: f.calibrated ? "checkmark.seal" : "hourglass")
                        Text(f.calibrated ? "Gyro calibrated" : "Calibrating: hold still")
                    }
                    .font(.callout)
                    Text("Turning's full scale is the sound's rotation setting; the impact mark is the tap strength needed to play a note.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    noMotion(f)
                }
            }
            Card {
                Text("What it plays").font(.headline)
                PlayingNow(frame: f, config: cfg)
            }
            Card {
                Text("Taps and strikes").font(.headline)
                StrikeCompass(config: cfg, hit: model.lastHit, now: model.clock)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                strikeText(cfg)
            }
        }
    }

    private func pose(_ f: TelemetryFrame) -> String {
        let flat = abs(f.pitch) < 10 && abs(f.roll) < 10
        if flat { return "Lying flat (level)." }
        var parts: [String] = []
        if abs(f.pitch) >= 10 { parts.append(f.pitch > 0 ? "tilted forward" : "tilted back") }
        if abs(f.roll) >= 10 { parts.append(f.roll > 0 ? "rolled right" : "rolled left") }
        if abs(f.roll) > 120 { return "Upside down." }
        return parts.joined(separator: ", ").capitalizedFirst + ". No heading: the board has no compass."
    }

    @ViewBuilder private func noMotion(_ f: TelemetryFrame?) -> some View {
        Text(f == nil ? "No sensor data yet." : "Motion sensor not ready.").foregroundStyle(.secondary)
    }

    @ViewBuilder private func strikeText(_ c: DeviceConfig) -> some View {
        if SensorMode(rawValue: c[.mode]) == .tiltStrike {
            Text(c[.strikeVoicing] == 1 && c[.strikeDirections] > 0
                 ? "Strikes play the note chosen by roll; the direction adds a chord tone: up = octave, left = third, right = fifth."
                 : "Every strike plays the note chosen by roll.")
                .font(.caption).foregroundStyle(.secondary)
        } else if c[.percussionEnabled] == 0 {
            Text("Taps are off in this sound. Choose Tap drum or Drum strikes, or turn on taps in the editor (section 4).")
                .font(.caption).foregroundStyle(.secondary)
        } else if c[.strikeDirections] == 0 {
            Text("Every tap plays \(NoteName.name(UInt8(c[.percussionNote]))). Turn on strike directions (editor section 4) to give each direction its own note.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.session.unsupported(.strikeDirections) {
            Text("Strike directions need firmware \(TrillProtocol.strikesMinimumFirmware).").font(.caption).foregroundStyle(.orange)
        } else {
            Text("The arrow shows the direction of the last strike, read from the note Trillium sent. A strike that wasn't clearly one way plays the \"unclear\" note and lights the centre.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The board drawn in perspective, tilted and rolled like the real one.
struct BoardPose: View {
    let pitch: Double
    let roll: Double
    let touch: Double?

    var body: some View {
        ZStack {
            Ellipse().fill(.black.opacity(0.12)).frame(width: 190, height: 26).offset(y: 70).blur(radius: 4)
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 6).fill(.purple.opacity(0.55))
                    .frame(width: 150, height: 18)
                if let touch {
                    Circle().fill(.yellow).frame(width: 16, height: 16).offset(x: CGFloat(touch - 0.5) * 150)
                }
                Image(systemName: "arrow.up").font(.caption.bold()).foregroundStyle(.white.opacity(0.7)).offset(y: -34)
            }
            .frame(width: 190, height: 96)
            .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(roll), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        }
        .animation(.linear(duration: 0.05), value: pitch)
        .accessibilityLabel(String(format: "Tilt %.0f degrees, roll %.0f degrees", pitch, roll))
    }
}

/// Bubble level: x = roll, y = forward tilt, ±90° to the edge.
struct BubbleLevel: View {
    let pitch: Double
    let roll: Double
    /// Forward tilt that starts a note (tilt modes only).
    let gate: Double?
    /// Roll to each end of the note range (tilt modes only).
    let span: Double
    /// Tilt + strike: forward/back tilt that changes the octave.
    var octaveLines: Double?

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2 - 6
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let s = r / 90
            ZStack {
                Circle().fill(.quaternary.opacity(0.5)).frame(width: 2 * r, height: 2 * r).position(c)
                ForEach([30.0, 60.0], id: \.self) { d in
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 1).frame(width: 2 * d * s, height: 2 * d * s).position(c)
                }
                Path { p in p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r)) }
                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
                if let gate {
                    // Notes sound above the gate line (forward tilt ≥ gate), between ±span roll.
                    Rectangle().fill(.green.opacity(0.18))
                        .frame(width: 2 * span * s, height: max(0, (90 - gate) * s))
                        .position(x: c.x, y: c.y - (gate + (90 - gate) / 2) * s)
                        .clipShape(Circle().size(width: 2 * r, height: 2 * r).offset(x: c.x - r, y: c.y - r))
                    Path { p in p.move(to: CGPoint(x: c.x - span * s, y: c.y - gate * s)); p.addLine(to: CGPoint(x: c.x + span * s, y: c.y - gate * s)) }
                        .stroke(.green, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                if let o = octaveLines {
                    ForEach([o, -o], id: \.self) { d in
                        Path { p in p.move(to: CGPoint(x: c.x - r, y: c.y - d * s)); p.addLine(to: CGPoint(x: c.x + r, y: c.y - d * s)) }
                            .stroke(.blue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        Text(d > 0 ? "octave up" : "octave down").font(.caption2).foregroundStyle(.blue)
                            .position(x: c.x, y: c.y - d * s + (d > 0 ? -8 : 8))
                    }
                }
                let x = max(-90, min(90, roll)) * s
                let y = max(-90, min(90, pitch)) * s
                Circle().fill(Color.accentColor).frame(width: 22, height: 22)
                    .shadow(radius: 2)
                    .position(x: c.x + x, y: c.y - y)
            }
        }
        .accessibilityLabel(String(format: "Level: roll %.0f, tilt %.0f", roll, pitch))
    }
}

struct MotionMeter: View {
    let title: String
    let value: Double
    let full: Double
    let text: String
    /// Optional marker as a fraction of `full` (e.g. the tap threshold).
    var mark: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(text).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
            GeometryReader { g in
                // The bar spans 0…1.5× full so the marker at full is visible.
                let scale = full > 0 ? g.size.width / (full * 1.5) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(value >= full ? Color.orange : Color.accentColor)
                        .frame(width: min(g.size.width, max(4, value * scale)))
                    if let mark {
                        Rectangle().fill(.primary).frame(width: 2).offset(x: mark * full * scale)
                    }
                }
            }
            .frame(height: 10)
        }
    }
}

/// What the current sound is doing with the latest frame.
struct PlayingNow: View {
    let frame: TelemetryFrame?
    let config: DeviceConfig

    var body: some View {
        let mode = SensorMode(rawValue: config[.mode]) ?? .touch
        VStack(alignment: .leading, spacing: 8) {
            Label(mode.name, systemImage: mode.symbol).font(.callout.weight(.medium))
            let low = config[.baseNote]
            let high = min(127, low + config[.rangeSemitones])
            if mode == .tiltStrike, let f = frame, f.imuValid {
                let t = TiltStrike(config)
                let oct = t.octave(pitch: f.pitch)
                ZoneStrip(config: config, roll: f.roll, octave: oct)
                HStack(spacing: 6) {
                    Image(systemName: oct > 0 ? "arrow.up.circle.fill" : oct < 0 ? "arrow.down.circle.fill" : "circle")
                    Text(oct > 0 ? "Octave up (tilted forward)" : oct < 0 ? "Octave down (tilted back)" : "Middle octave")
                    Spacer()
                    Text("Strike to play \(NoteName.name(UInt8(t.note(zone: t.zone(roll: f.roll), octave: oct))))").bold()
                }
                .font(.callout)
                Text("Roll chooses, a strike plays: the note doesn't sound until you hit. Approximate: ignores a level set with \"Set current position as level\".")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let f = frame, f.imuValid || mode == .touch {
                let pos: Double? = mode == .touch
                    ? f.touchPosition
                    : max(0, min(1, (f.roll + Double(config[.tiltSpanDeg])) / (2 * Double(config[.tiltSpanDeg]))))
                let sounding = mode == .touch ? f.touchPosition != nil : f.pitch >= Double(config[.gateDeg])
                NoteRuler(position: pos, sounding: sounding, low: low, high: high, steps: mode == .theremin ? 0 : config[.scale] == 1 ? 5 : 12)
                    .frame(height: 34)
                Group {
                    if mode == .touch {
                        Text(f.trillState == .running ? (sounding ? "Finger on the strip: playing." : "Touch the strip to play.")
                             : "Touch strip not detected, so touch mode is silent. Try a tilt preset.")
                    } else if sounding {
                        Text("Tilted past \(config[.gateDeg])°: playing. Roll to move along the range.")
                    } else {
                        Text(String(format: "Tilt forward to %d° to play (now %.0f°).", config[.gateDeg], f.pitch))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if mode != .touch {
                    Text("Approximate: assumes the level position hasn't been reset with \"Set current position as level\".")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("No sensor data yet.").foregroundStyle(.secondary)
            }
        }
    }
}

struct NoteRuler: View {
    let position: Double?
    let sounding: Bool
    let low: Int
    let high: Int
    /// Tick spacing hint: 12 = chromatic, 5 = pentatonic, 0 = continuous.
    let steps: Int

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8).offset(y: 0)
                    if steps > 0 {
                        let octaves = max(1, Double(high - low) / 12)
                        let n = Int(Double(steps) * octaves)
                        ForEach(0...max(n, 1), id: \.self) { i in
                            Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 8)
                                .offset(x: g.size.width * Double(i) / Double(max(n, 1)))
                        }
                    }
                    if let p = position {
                        Circle().fill(sounding ? Color.green : Color.secondary)
                            .frame(width: 16, height: 16)
                            .offset(x: g.size.width * p - 8)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            HStack {
                Text(NoteName.name(UInt8(low)))
                Spacer()
                Text(NoteName.name(UInt8(high)))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Six directions around the board; the last strike's direction glows.
struct StrikeCompass: View {
    let config: DeviceConfig
    let hit: AppModel.Hit?
    let now: TimeInterval

    var body: some View {
        let active = Set(StrikeDirection.active(config[.strikeDirections]))
        let age = hit.map { now - $0.time } ?? .infinity
        let fresh = age < 1.5
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let r = min(g.size.width, g.size.height) / 2 - 22
            ZStack {
                Circle().fill(fresh && hit?.direction == nil ? Color.orange.opacity(max(0, 1 - age / 1.5)) : Color.secondary.opacity(0.15))
                    .frame(width: 44, height: 44).position(c)
                Text(hit.map { NoteName.name(UInt8($0.note)) } ?? "–").font(.caption.monospacedDigit()).position(c)
                ForEach(StrikeDirection.allCases, id: \.self) { d in
                    let on = active.contains(d)
                    let lit = fresh && hit?.direction == d
                    let p = offset(d, r)
                    VStack(spacing: 1) {
                        Image(systemName: d.symbol).font(.title3.weight(lit ? .bold : .regular))
                        Text(on ? "\(d.name) \(SensorMode(rawValue: config[.mode]) == .tiltStrike ? d.chordTone : NoteName.name(UInt8(config[d.param])))" : d.name)
                            .font(.caption2)
                    }
                    .foregroundStyle(lit ? Color.orange : on ? Color.primary : Color.secondary.opacity(0.4))
                    .scaleEffect(lit ? 1.25 : 1)
                    .position(x: c.x + p.x, y: c.y + p.y)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hit)
    }

    /// Screen placement: up/down vertical, left/right horizontal,
    /// forward/back on the diagonal (as if seen in perspective).
    private func offset(_ d: StrikeDirection, _ r: CGFloat) -> CGPoint {
        switch d {
        case .up: return CGPoint(x: 0, y: -r)
        case .down: return CGPoint(x: 0, y: r)
        case .left: return CGPoint(x: -r, y: 0)
        case .right: return CGPoint(x: r, y: 0)
        case .forward: return CGPoint(x: r * 0.72, y: -r * 0.72)
        case .back: return CGPoint(x: -r * 0.72, y: r * 0.72)
        }
    }
}

/// Tilt + strike note zones across the roll range, with the current roll
/// (if known) and the zone it selects.
struct ZoneStrip: View {
    let config: DeviceConfig
    var roll: Double?
    var octave = 0

    var body: some View {
        let t = TiltStrike(config)
        let sel = roll.map { t.zone(roll: $0) }
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                let w = g.size.width
                let x = { (deg: Double) in CGFloat((deg + t.span) / (2 * t.span)) * w }
                ZStack(alignment: .topLeading) {
                    ForEach(0..<t.zoneCount, id: \.self) { k in
                        let x0 = x(t.edge(k)), x1 = x(t.edge(k + 1))
                        let on = sel == k
                        RoundedRectangle(cornerRadius: 4)
                            .fill(on ? Color.green.opacity(0.75) : (k % 2 == 0 ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.10)))
                            .frame(width: max(1, x1 - x0 - 2), height: 30)
                            .offset(x: x0 + 1)
                        Text(NoteName.name(UInt8(t.note(zone: k, octave: octave))))
                            .font(.system(size: 10, weight: on ? .bold : .regular).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: max(1, x1 - x0 - 2), height: 30)
                            .offset(x: x0 + 1)
                    }
                    if let r = roll {
                        Rectangle().fill(.primary).frame(width: 2, height: 38).offset(x: x(max(-t.span, min(t.span, r))) - 1, y: -4)
                    }
                }
            }
            .frame(height: 30)
            HStack {
                Text(String(format: "← roll left %.0f°", t.span))
                Spacer()
                Text("level")
                Spacer()
                Text(String(format: "roll right %.0f° →", t.span))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(t.zoneCount) note zones" + (sel.map { ", selected \(NoteName.name(UInt8(t.note(zone: $0, octave: octave))))" } ?? ""))
    }
}
