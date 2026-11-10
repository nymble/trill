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
        XCTAssertEqual(BuiltInPreset.all.first?.config, .firmwareDefaults)
        XCTAssertFalse(BuiltInPreset.all[0].needsConfigPages)
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
        XCTAssertNil(BuiltInPreset.all[0].minimumFirmware)
        // Only the strikes preset turns strikes on.
        for p in BuiltInPreset.all { XCTAssertEqual(p.config[.strikeDirections] != 0, p.id == "drum-strikes", p.id) }
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
