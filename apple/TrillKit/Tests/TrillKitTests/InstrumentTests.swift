// SPDX-License-Identifier: GPL-3.0-only
//
// Instrument view engine on synthetic IMU traces: 8 directions upright and
// upside down, tilt rings, multi-turn roll, debounce and refractory, swing
// on a stick or a string, tap assist, plus the handpan scale tables.

import XCTest
@testable import TrillKit

/// Rotation matrix, device → world (columns are the device axes in world coordinates).
private struct Rot {
    var m: [[Double]]
    static let identity = Rot(m: [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
    /// Rotation by `deg` about a world axis (right-hand rule).
    static func axis(_ a: Vec3, _ deg: Double) -> Rot {
        let u = a.normalized, t = deg * .pi / 180, c = cos(t), s = sin(t), C = 1 - c
        return Rot(m: [
            [c + u.x * u.x * C, u.x * u.y * C - u.z * s, u.x * u.z * C + u.y * s],
            [u.y * u.x * C + u.z * s, c + u.y * u.y * C, u.y * u.z * C - u.x * s],
            [u.z * u.x * C - u.y * s, u.z * u.y * C + u.x * s, c + u.z * u.z * C],
        ])
    }
    func apply(_ v: Vec3) -> Vec3 {
        Vec3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
             m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
             m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z)
    }
    /// World → device.
    func inverse(_ v: Vec3) -> Vec3 {
        Vec3(m[0][0] * v.x + m[1][0] * v.y + m[2][0] * v.z,
             m[0][1] * v.x + m[1][1] * v.y + m[2][1] * v.z,
             m[0][2] * v.x + m[1][2] * v.y + m[2][2] * v.z)
    }
}

/// World axes used by the traces. With the device at identity and up = +Z,
/// the forward mark (+X) points N, so E = N × up = −Y.
private let worldUp = Vec3(0, 0, 1)
private let worldN = Vec3(1, 0, 0)
private let worldE = Vec3(0, -1, 0)

private func horizontal(_ angle: Double) -> Vec3 {
    let t = angle * .pi / 180
    return worldN * cos(t) + worldE * sin(t)
}

/// Builds a 50 Hz trace for a device held still in `pose`, with optional pushes.
private struct Trace {
    var pose: Rot = .identity
    var rate = 50.0
    var samples: [(t: Double, a: Vec3, g: Vec3, taps: Int)] = []
    var taps = 0
    var t = 0.0

    mutating func rest(_ seconds: Double, gyroWorld: Vec3 = .zero) {
        let n = Int((seconds * rate).rounded())
        for _ in 0..<n { sample(extra: .zero, gyroWorld: gyroWorld) }
    }

    /// A push in world direction `angle` (clockwise from N) of `g` for `frames` samples.
    mutating func push(_ angle: Double, g: Double = 1.5, frames: Int = 2, vertical: Double = 0) {
        for _ in 0..<frames { sample(extra: horizontal(angle) * g + worldUp * vertical, gyroWorld: .zero) }
    }

    mutating func sample(extra: Vec3, gyroWorld: Vec3) {
        samples.append((t, pose.inverse(worldUp + extra), pose.inverse(gyroWorld), taps))
        t += 1 / rate
    }

    func run(_ engine: inout ImpulseEngine) -> [InstrumentStrike] {
        samples.compactMap { engine.process(time: $0.t, accel: $0.a, gyro: $0.g, taps: $0.taps) }
    }
}

private func freeSettings() -> ImpulseSettings {
    var s = ImpulseSettings()
    s.mounting = .free
    return s
}

final class ImpulseEngineTests: XCTestCase {
    func testSectorIndex() {
        XCTAssertEqual(CompassSector.index(angle: 0), 0)
        XCTAssertEqual(CompassSector.index(angle: 22.4), 0)
        XCTAssertEqual(CompassSector.index(angle: 22.6), 1)
        XCTAssertEqual(CompassSector.index(angle: 359), 0)
        XCTAssertEqual(CompassSector.index(angle: -45), 7)
        XCTAssertEqual(CompassSector.index(angle: 180), 4)
    }

    func testAllEightDirectionsUpright() {
        for k in 0..<8 {
            var tr = Trace()
            tr.rest(1)
            tr.push(Double(k) * 45 + 10)
            tr.rest(0.5)
            var e = ImpulseEngine(settings: freeSettings())
            let hits = tr.run(&e)
            XCTAssertEqual(hits.count, 1, "direction \(k)")
            XCTAssertEqual(hits.first?.sector, k, "direction \(k)")
            XCTAssertEqual(hits.first?.ring, .first)
            XCTAssertEqual(hits.first?.upsideDown, false)
            XCTAssertEqual(hits.first.map { abs($0.angle - (Double(k) * 45 + 10)) < 1 }, true, "angle \(k)")
        }
    }

    func testAllEightDirectionsUpsideDown() {
        // Flipped over the forward mark: device +Z points down, +X still N.
        // A device-axis mapping would swap E and W here; the gravity frame does not.
        for k in 0..<8 {
            var tr = Trace(pose: .axis(worldN, 180))
            tr.rest(1)
            tr.push(Double(k) * 45)
            tr.rest(0.5)
            var e = ImpulseEngine(settings: freeSettings())
            let hits = tr.run(&e)
            XCTAssertEqual(hits.count, 1, "direction \(k)")
            XCTAssertEqual(hits.first?.sector, k, "direction \(k)")
            XCTAssertEqual(hits.first?.upsideDown, true)
            XCTAssertEqual(hits.first?.ring, .first, "upside down and vertical is tilt 0")
            XCTAssertTrue(e.readout.upsideDown)
            XCTAssertEqual(e.readout.tiltFromUp, 180, accuracy: 1)
            XCTAssertEqual(e.readout.tilt, 0, accuracy: 1)
        }
    }

    func testUpsideDownFlippedOverEastAxisFollowsForwardMark() {
        // Flipped over E: the forward mark now points S, so N is behind; a push S reads N.
        var tr = Trace(pose: .axis(worldE, 180))
        tr.rest(1)
        tr.push(180)
        tr.rest(0.5)
        var e = ImpulseEngine(settings: freeSettings())
        let hits = tr.run(&e)
        XCTAssertEqual(hits.map(\.sector), [0])
        XCTAssertEqual(hits.first?.upsideDown, true)
    }

    func testTiltSelectsRing() {
        for (deg, ring) in [(0.0, HandpanRing.first), (20, .first), (40, .second), (55, .second), (70, .ding)] {
            var tr = Trace(pose: .axis(worldN, deg))
            tr.rest(1.5)
            tr.push(90)
            tr.rest(0.5)
            var e = ImpulseEngine(settings: freeSettings())
            let hits = tr.run(&e)
            XCTAssertEqual(hits.count, 1, "tilt \(deg)")
            XCTAssertEqual(hits.first?.ring, ring, "tilt \(deg)")
            XCTAssertEqual(hits.first?.tilt ?? -1, deg, accuracy: 2, "tilt \(deg)")
            if ring == .ding { XCTAssertNil(hits.first?.sector) } else { XCTAssertEqual(hits.first?.sector, 2, "E at tilt \(deg)") }
        }
    }

    func testTiltUpsideDownFoldsToNearestVertical() {
        var tr = Trace(pose: .axis(worldN, 180 - 40))
        tr.rest(1.5)
        tr.push(0)
        tr.rest(0.5)
        var e = ImpulseEngine(settings: freeSettings())
        let hits = tr.run(&e)
        XCTAssertEqual(hits.first?.ring, .second)
        XCTAssertEqual(hits.first?.upsideDown, true)
        XCTAssertEqual(hits.first?.sector, 0)
    }

    func testMultiTurnRollDoesNotWrap() {
        var tr = Trace()
        tr.rest(0.5)
        tr.rest(2.5, gyroWorld: worldUp * 360) // 2.5 turns counter-clockwise about up
        var e = ImpulseEngine(settings: freeSettings())
        _ = tr.run(&e)
        XCTAssertEqual(e.readout.roll, 900, accuracy: 10)
        XCTAssertEqual(e.readout.rollTurns.turns, 2)
        XCTAssertEqual(e.readout.rollTurns.degrees, 180, accuracy: 10)

        var back = Trace()
        back.rest(4, gyroWorld: worldUp * -300) // 3 1/3 turns the other way
        var e2 = ImpulseEngine(settings: freeSettings())
        _ = back.run(&e2)
        XCTAssertEqual(e2.readout.roll, -1200, accuracy: 10)
        XCTAssertEqual(e2.readout.rollTurns.turns, -3)
        e2.resetRoll()
        XCTAssertEqual(e2.readout.roll, 0)
    }

    func testRollUpsideDownIsAboutTheUpAxis() {
        // Device upside down, spinning about world up: about its own up axis that is the opposite sense.
        var tr = Trace(pose: .axis(worldN, 180))
        tr.rest(2, gyroWorld: worldUp * 180)
        var e = ImpulseEngine(settings: freeSettings())
        _ = tr.run(&e)
        XCTAssertEqual(e.readout.roll, -360, accuracy: 10)
        XCTAssertTrue(e.readout.upsideDown)
    }

    func testRollDuringSpinKeepsGravityAndDirections() {
        var tr = Trace()
        tr.rest(1)
        tr.push(90)
        tr.rest(0.5)
        var e = ImpulseEngine(settings: freeSettings())
        _ = tr.run(&e)
        XCTAssertEqual(e.readout.tilt, 0, accuracy: 1)
    }

    func testDebounceMergesAndRefractoryBlocks() {
        var tr = Trace()
        tr.rest(1)
        tr.push(0, g: 1.0, frames: 1)
        tr.push(0, g: 2.5, frames: 1)   // same strike, bigger peak: one hit, peak velocity
        tr.rest(0.06)
        tr.push(180, g: 2.0, frames: 1) // rebound inside the refractory period: ignored
        tr.rest(0.5)
        tr.push(90, g: 1.5, frames: 1)  // a new strike
        tr.rest(0.5)
        var e = ImpulseEngine(settings: freeSettings())
        let hits = tr.run(&e)
        XCTAssertEqual(hits.map(\.sector), [0, 2])
        XCTAssertEqual(hits[0].strength, 2.5 / 0.6, accuracy: 0.01)
    }

    func testBelowThresholdAndVerticalTapsIgnored() {
        var tr = Trace()
        tr.rest(1)
        tr.push(45, g: 0.4)                  // under 0.6 g
        tr.rest(0.5)
        tr.push(45, g: 0.7, vertical: 2.0)   // mostly along up
        tr.rest(0.5)
        var e = ImpulseEngine(settings: freeSettings())
        XCTAssertEqual(tr.run(&e).count, 0)
    }

    func testVelocityFromStrength() {
        let e = ImpulseEngine()
        XCTAssertEqual(e.velocity(strength: 1), 24)
        XCTAssertEqual(e.velocity(strength: 4), 127)
        XCTAssertEqual(e.velocity(strength: 10), 127)
        XCTAssertLessThan(e.velocity(strength: 1.5), e.velocity(strength: 2.5))
    }

    /// A sudden swing: rotation rate steps to `dps` about `axis` (world) and stays.
    private func swingTrace(_ axis: Vec3, dps: Double) -> Trace {
        var tr = Trace()
        tr.rest(1)
        tr.rest(0.1, gyroWorld: axis * dps)
        tr.rest(0.5)
        return tr
    }

    func testSwingOnStickAndString() {
        // Top of a stick moving N: ω = up × N.
        let w = worldUp.cross(worldN)
        var stick = ImpulseEngine()
        stick.settings.mounting = .stick
        XCTAssertEqual(swingTrace(w, dps: 300).run(&stick).compactMap(\.sector).first, 0)
        // Same rotation on a string (pivot above): the sensor moves S.
        var string = ImpulseEngine()
        string.settings.mounting = .hanging
        XCTAssertEqual(swingTrace(w, dps: 300).run(&string).compactMap(\.sector).first, 4)
        // Free: gyro ignored.
        var free = ImpulseEngine(settings: freeSettings())
        XCTAssertEqual(swingTrace(w, dps: 300).run(&free).count, 0)
    }

    func testTapAssistPlaysWhenTransientWasMissed() {
        var tr = Trace()
        tr.rest(1)
        tr.taps += 1
        tr.rest(0.3)
        var e = ImpulseEngine(settings: freeSettings())
        let hits = tr.run(&e)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.fromTapCounter, true)
        XCTAssertEqual(hits.first?.ring, .ding)
        XCTAssertNil(hits.first?.sector)

        var off = ImpulseEngine(settings: freeSettings())
        off.settings.tapAssist = false
        XCTAssertEqual(tr.run(&off).count, 0)
    }

    func testCurrentPoseAsUp() {
        let pose = Rot.axis(Vec3(1, 1, 0), 63)
        var tr = Trace(pose: pose)
        tr.rest(1.5)
        var e = ImpulseEngine(settings: freeSettings())
        _ = tr.run(&e)
        XCTAssertGreaterThan(e.readout.tilt, 50)
        guard let up = e.currentPoseAsUp() else { return XCTFail("no gravity") }
        e.settings.up = up
        var more = Trace(pose: pose)
        more.t = tr.t
        more.rest(0.2)
        more.push(0)
        more.rest(0.3)
        let hits = more.run(&e)
        XCTAssertEqual(e.readout.tilt, 0, accuracy: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.ring, .first)
    }

    func testEveryUpAxisReadsUprightWhenThatAxisPointsUp() {
        for axis in UpAxis.axes {
            // Rotate the device so `axis` points to world up.
            let v = axis.vector
            let pose: Rot
            if v.dot(worldUp) > 0.99 { pose = .identity }
            else if v.dot(worldUp) < -0.99 { pose = .axis(worldN, 180) }
            else { pose = .axis(v.cross(worldUp), acos(v.dot(worldUp)) * 180 / .pi) }
            var tr = Trace(pose: pose)
            tr.rest(1)
            var s = freeSettings(); s.up = axis
            var e = ImpulseEngine(settings: s)
            _ = tr.run(&e)
            XCTAssertEqual(e.readout.tilt, 0, accuracy: 1, axis.title)
            XCTAssertFalse(e.readout.upsideDown, axis.title)
        }
    }

    func testNorthOffsetRotatesLabels() {
        var tr = Trace()
        tr.rest(1)
        tr.push(45)
        tr.rest(0.5)
        var s = freeSettings(); s.northOffset = 1
        var e = ImpulseEngine(settings: s)
        XCTAssertEqual(tr.run(&e).map(\.sector), [0])
    }

    func testDeviceClockUnwraps() {
        var c = DeviceClock()
        XCTAssertEqual(c.seconds(0x1F_FFF0), Double(0x1F_FFF0) / 1000, accuracy: 1e-9)
        XCTAssertEqual(c.seconds(0x10), (Double(0x20_0000) + 16) / 1000, accuracy: 1e-9)
    }
}

final class HandpanTests: XCTestCase {
    func testSpelledNotes() {
        XCTAssertEqual(SpelledNote("D3")?.midi, 50)
        XCTAssertEqual(SpelledNote("Bb3")?.midi, 58)
        XCTAssertEqual(SpelledNote("C#4")?.midi, 61)
        XCTAssertEqual(SpelledNote("F♯4")?.name, "F♯4")
        XCTAssertEqual(SpelledNote("Bb3")?.name, "B♭3")
        XCTAssertNil(SpelledNote("H3"))
    }

    func testDKurdMatchesPublishedNotes() {
        let kurd = HandpanScale.named("kurd")!
        XCTAssertEqual(kurd.ding.midi, 50)
        XCTAssertEqual(kurd.toneFields.map(\.midi), [57, 58, 60, 62, 64, 65, 67, 69])
        XCTAssertEqual(kurd.title(dingMIDI: 50), "D Kurd 9")
    }

    func testEveryScaleIsAscendingWithEightOrMoreToneFields() {
        XCTAssertEqual(HandpanScale.all.map(\.name),
                       ["Kurd", "Celtic Minor", "Integral", "Hijaz", "Pygmy", "Amara", "Equinox", "La Sirena"])
        for s in HandpanScale.all {
            let m = s.toneFields.map(\.midi)
            XCTAssertGreaterThanOrEqual(m.count, 8, s.name)
            XCTAssertEqual(m, m.sorted(), s.name)
            XCTAssertEqual(Set(m).count, m.count, s.name)
            XCTAssertGreaterThan(m[0], s.ding.midi, s.name)
            XCTAssertFalse(s.source.isEmpty)
            XCTAssertTrue(HandpanScale.dingRange.contains(s.ding.midi), s.name)
        }
    }

    func testTranspositionKeepsLettersAndIntervals() {
        let kurd = HandpanScale.named("kurd")!
        let e = kurd.toneFields(dingMIDI: 52)
        XCTAssertEqual(e.map(\.name), ["B3", "C4", "D4", "E4", "F♯4", "G4", "A4", "B4"])
        let c = kurd.toneFields(dingMIDI: 48)
        XCTAssertEqual(c.map(\.name), ["G3", "A♭3", "B♭3", "C4", "D4", "E♭4", "F4", "G4"])
        let hijaz = HandpanScale.named("hijaz")!
        XCTAssertEqual(hijaz.toneFields.map(\.name), ["E3", "G3", "A3", "B♭3", "C♯4", "D4", "E4", "G4"])
        XCTAssertEqual(hijaz.toneFields(dingMIDI: 50).map(\.name), ["A3", "C4", "D4", "E♭4", "F♯4", "G4", "A4", "C5"])
    }

    func testRingsAndLayouts() {
        let kurd = HandpanInstrument(scale: HandpanScale.named("kurd")!)
        XCTAssertEqual(kurd.ring(.first).map(\.name), ["A3", "B♭3", "C4", "D4", "E4", "F4", "G4", "A4"])
        XCTAssertEqual(kurd.upperRing.map(\.name), ["B♭4", "C5", "D5", "E5", "F5", "G5", "A5", "B♭5"])
        XCTAssertEqual(kurd.note(sector: 3, ring: .ding).name, "D3")

        var alt = kurd
        alt.layout = .alternating
        XCTAssertEqual(alt.note(sector: 4, ring: .first).name, "A3", "lowest at S")
        XCTAssertEqual(alt.note(sector: 0, ring: .first).name, "A4", "highest at N")
        XCTAssertEqual(Set(alt.ring(.first).map(\.midi)), Set(kurd.ring(.first).map(\.midi)))

        let equinox = HandpanInstrument(scale: HandpanScale.named("equinox")!)
        XCTAssertEqual(equinox.upperRing.first?.name, "E♭5", "9th tone field leads ring 2")
        XCTAssertEqual(equinox.upperRing.count, 8)
        XCTAssertEqual(equinox.upperRing.map(\.midi), equinox.upperRing.map(\.midi).sorted())
    }
}
