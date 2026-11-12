// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

final class MonitorTests: XCTestCase {
    func testRealtimeFilteredButCountedRateAndCSV() {
        var m = MonitorModel(historyLimit: 3)
        var events: [MIDIEvent] = []
        for i in 0..<10 {
            let msg: MIDIMessage = i % 2 == 0 ? .realtime(status: 0xF8) : .noteOn(channel: 1, note: 60, velocity: UInt8(i))
            events.append(MIDIEvent(id: UInt64(i), hostTime: 5 + Double(i) * 0.1, message: msg))
        }
        m.apply(events)
        XCTAssertEqual(m.total, 10)
        XCTAssertEqual(m.realtimeCount, 5)
        XCTAssertEqual(m.history.count, 3, "bounded")
        XCTAssertTrue(m.history.allSatisfy { if case .noteOn = $0.message { return true }; return false })
        XCTAssertEqual(m.rate, 10)
        m.idle(now: 7)
        XCTAssertEqual(m.rate, 0)
        let csv = m.csv(port: "Trill \"Port 1\"").split(separator: "\n")
        XCTAssertEqual(csv.count, 4)
        XCTAssertEqual(csv[1], "5.500000,\"Trill 'Port 1'\",2,\"ch2 Note On C4 (60) vel 5\"")
        XCTAssertEqual(MIDIMessage.realtime(status: 0xF8).summary, "Real-time F8 Clock")
        m.hideRealtime = false
        m.apply([MIDIEvent(id: 99, hostTime: 8, message: .realtime(status: 0xFE))])
        XCTAssertEqual(m.history.last?.message, .realtime(status: 0xFE))
    }

    func testTrillSysExHiddenSoTapNotesStayVisible() {
        var m = MonitorModel(historyLimit: 20)
        let frame = MIDIMessage.sysex(bytes: [0xF0, 0x7D, 0x54, 0x52, 0x01, 0x50, 0x00, 0x01, 0xF7], truncated: false)
        var events: [MIDIEvent] = []
        for i in 0..<50 { events.append(MIDIEvent(id: UInt64(i), hostTime: Double(i) * 0.02, message: frame)) }
        events.insert(MIDIEvent(id: 100, hostTime: 0.5, message: .noteOn(channel: 9, note: 39, velocity: 100)), at: 25)
        events.append(MIDIEvent(id: 101, hostTime: 1.1, message: .sysex(bytes: [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], truncated: false)))
        m.apply(events)
        XCTAssertEqual(m.sysexCount, 51)
        XCTAssertEqual(m.trillSysExCount, 50)
        XCTAssertEqual(m.history.count, 2, "tap note and the non-Trill SysEx stay")
        XCTAssertEqual(m.history.first?.message, .noteOn(channel: 9, note: 39, velocity: 100))
        XCTAssertEqual(m.activeChannels, [9])
        m.hideTrillSysEx = false
        m.apply([MIDIEvent(id: 102, hostTime: 1.2, message: frame)])
        XCTAssertEqual(m.history.last?.message, frame)
    }
}

final class BuiltInPresetTests: XCTestCase {
    func testBuiltInsAreValidAndGestureFreeExceptTheGesturePreset() {
        let strip = BuiltInPreset.all.first { $0.id == "default" }!
        XCTAssertEqual(strip.config, .firmwareDefaults)
        XCTAssertFalse(strip.needsConfigPages)
        XCTAssertEqual(Set(BuiltInPreset.all.map(\.id)).count, BuiltInPreset.all.count)
        for p in BuiltInPreset.all {
            for param in TrillParam.allCases { XCTAssertTrue(param.range.contains(p.config[param]), "\(p.id) \(param)") }
            XCTAssertEqual(p.config[.gestureAxis] != 0, p.id == "flick-gestures", p.id)
            // Round-trips through the preset file format.
            let file = try! Preset(name: p.name, config: p.config).jsonData()
            XCTAssertEqual(try! Preset.decode(file).config, p.config)
        }
        let theremin = BuiltInPreset.all.first { $0.id == "theremin" }!
        XCTAssertEqual(theremin.config[.pitchMode], 0)
        XCTAssertTrue(theremin.needsConfigPages)
        XCTAssertEqual(theremin.minimumFirmware, TrillProtocol.configPagesMinimumFirmware)
        let strikes = BuiltInPreset.all.first { $0.id == "drum-strikes" }!
        XCTAssertTrue(strikes.needsStrikes)
        XCTAssertEqual(strikes.config[.strikeDirections], 4)
        XCTAssertEqual(strikes.minimumFirmware, TrillProtocol.strikesMinimumFirmware)
        XCTAssertNil(strip.minimumFirmware)
        // Strikes: the drum preset and the chord-tone voicings.
        for p in BuiltInPreset.all {
            XCTAssertEqual(p.config[.strikeDirections] != 0, ["drum-strikes", "strum-chords", "minor-bass"].contains(p.id), p.id)
        }
        // Tilt + strike presets need 0.5.0 even where only page-1/0 values say so.
        for id in ["tilt-melody", "strum-chords", "minor-bass"] {
            let p = BuiltInPreset.all.first { $0.id == id }!
            XCTAssertEqual(p.config[.mode], SensorMode.tiltStrike.rawValue)
            XCTAssertTrue(p.needsStrikes, id)
            XCTAssertEqual(p.minimumFirmware, TrillProtocol.strikesMinimumFirmware, id)
            // One octave of 5-8 notes (motion-mapping report §6.1).
            XCTAssertTrue((5...8).contains(TiltStrike(p.config).zoneCount), id)
        }
        // Motion-only sounds come first.
        XCTAssertEqual(BuiltInPreset.all.first?.id, "tilt-melody")
    }

    func testStrikeDirectionsStayEven() {
        var c = DeviceConfig.firmwareDefaults
        c[.strikeDirections] = 3
        XCTAssertEqual(c[.strikeDirections], 4)
        XCTAssertFalse(TrillParam.strikeDirections.accepts(5))
        XCTAssertNil(TrillCodec.setConfig(1, [(.strikeDirections, 1)]))
        XCTAssertNotNil(TrillCodec.setConfig(1, [(.strikeDirections, 6)]))
    }

    func testOldPresetFilesLoadWithPageOneDefaults() throws {
        let json = #"{"format":"trill-preset","version":1,"name":"old","values":{"channel":2,"base_note":50}}"#
        let p = try Preset.decode(Data(json.utf8))
        XCTAssertEqual(p.config[.channel], 2)
        XCTAssertEqual(p.config[.mode], 0)
        XCTAssertEqual(p.config[.gestureAxis], 0)
    }
}

final class TiltStrikeTests: XCTestCase {
    /// Same expectations as instrument-events/tests/modes.rs (C major, one octave).
    func testMatchesFirmwareSelection() {
        var c = DeviceConfig.firmwareDefaults
        c[.mode] = SensorMode.tiltStrike.rawValue
        c[.scale] = ScaleKind.major.rawValue
        c[.baseNote] = 60
        c[.rangeSemitones] = 12
        let t = TiltStrike(c)
        XCTAssertEqual(t.zoneCount, 8)
        XCTAssertEqual(t.note(zone: t.zone(roll: -45)), 60)
        XCTAssertEqual(t.note(zone: t.zone(roll: 45)), 72)
        XCTAssertEqual(t.note(zone: t.zone(roll: 0)), 67)
        XCTAssertEqual(t.zone(roll: 5), 5, "quadratic: finer near level")
        XCTAssertEqual(t.note(zone: 0, octave: t.octave(pitch: 20)), 72)
        XCTAssertEqual(t.note(zone: 0, octave: t.octave(pitch: -20)), 48)
        XCTAssertEqual(t.note(zone: 0, direction: .left, voicing: true), 64)
        XCTAssertEqual(t.note(zone: 0, direction: .right, voicing: true), 67)
        XCTAssertEqual(t.note(zone: 0, direction: .up, voicing: true), 72)
        XCTAssertEqual(t.note(zone: 0, direction: .right, voicing: false), 60)
        // Zone edges are symmetric and squeeze towards level.
        XCTAssertEqual(t.edge(0), -45)
        XCTAssertEqual(t.edge(8), 45)
        XCTAssertEqual(t.edge(4), 0)
        XCTAssertLessThan(abs(t.edge(5) - t.edge(4)), abs(t.edge(8) - t.edge(7)))
        var lin = c
        lin[.zoneCurve] = 0
        XCTAssertEqual(TiltStrike(lin).zone(roll: 5), 4)
    }

    func testScales() {
        XCTAssertEqual(ScaleKind.major.offset(7), 12)
        XCTAssertEqual(ScaleKind.major.offset(-1), -1)
        XCTAssertEqual(ScaleKind.minor.offset(2), 3)
        XCTAssertEqual(ScaleKind.pentatonic.steps(for: 7), 3)
        XCTAssertEqual(ScaleKind.chromatic.steps(for: 4), 4)
    }

    func testSummaryDescribesSelectionAndStrikes() {
        let c = BuiltInPreset.all.first { $0.id == "strum-chords" }!.config
        let l = MappingSummary.lines(c)
        XCTAssertEqual(l.map(\.input), ["Roll", "Tilt forward / back", "Strike or tap", "Strike direction"])
        XCTAssertTrue(l[0].output.contains("1 of 8 major notes"), l[0].output)
        XCTAssertEqual(l[3].output, "up = octave, left = third, right = fifth")
    }
}

final class MappingSummaryTests: XCTestCase {
    func testStrikeDirectionFromNote() {
        let c = BuiltInPreset.all.first { $0.id == "drum-strikes" }!.config
        XCTAssertEqual(StrikeDirection.matching(channel: 9, note: 36, config: c), .left)
        XCTAssertEqual(StrikeDirection.matching(channel: 9, note: 38, config: c), .down)
        XCTAssertNil(StrikeDirection.matching(channel: 9, note: 39, config: c), "unclear note")
        XCTAssertNil(StrikeDirection.matching(channel: 0, note: 36, config: c), "other channel")
        var shared = c
        shared[.strikeNoteUp] = 38
        XCTAssertNil(StrikeDirection.matching(channel: 9, note: 38, config: shared), "two directions share it")
        var off = c
        off[.strikeDirections] = 0
        XCTAssertNil(StrikeDirection.matching(channel: 9, note: 36, config: off))
    }

    func testBuiltInWithConfigKeepsIdentity() {
        let p = BuiltInPreset.all[1]
        var c = p.config
        c[.baseNote] = 50
        let e = p.with(config: c)
        XCTAssertEqual(e.id, p.id)
        XCTAssertEqual(e.name, p.name)
        XCTAssertEqual(e.config[.baseNote], 50)
    }

    func testDefaultsDescribeStripAndControllers() {
        let l = MappingSummary.lines(.firmwareDefaults)
        XCTAssertEqual(l.map(\.input), ["Touch strip", "Rotation speed (any axis)", "Pitch forward"])
        XCTAssertTrue(l[0].output.contains("C3–C5"))
        XCTAssertEqual(l[1].output, "CC74 brightness")
    }

    func testStrikesAndOldFirmware() {
        let strikes = BuiltInPreset.all.first { $0.id == "drum-strikes" }!.config
        let l = MappingSummary.lines(strikes)
        XCTAssertTrue(l.contains { $0.input == "Strike in 4 directions" && $0.output.contains("down 38") }, "\(l)")
        // A 0.4 device has no page 2: taps play the single note.
        let old = MappingSummary.lines(strikes, pages: [0, 1])
        XCTAssertTrue(old.contains { $0.input == "Tap" })
        let theremin = BuiltInPreset.all.first { $0.id == "theremin" }!.config
        XCTAssertEqual(MappingSummary.lines(theremin).first?.input, "Tilt forward + roll")
        XCTAssertEqual(MappingSummary.lines(theremin, pages: [0]).first?.input, "Touch strip")
    }
}
