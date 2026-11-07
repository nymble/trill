// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

final class UMPTests: XCTestCase {
    func testChannelVoiceDecoding() {
        var d = UMPDecoder()
        let m = d.decode([0x2093_3C64, 0x2093_3C00, 0x2083_3C40, 0x20B3_4A7F, 0x20D3_5000, 0x20E3_0040, 0x20C3_0500, 0x10F8_0000, 0x10F2_0102])
        XCTAssertEqual(m, [
            .noteOn(channel: 3, note: 60, velocity: 100),
            .noteOff(channel: 3, note: 60, velocity: 0),
            .noteOff(channel: 3, note: 60, velocity: 64),
            .controlChange(channel: 3, control: 74, value: 127),
            .channelPressure(channel: 3, value: 80),
            .pitchBend(channel: 3, value: 8192),
            .programChange(channel: 3, program: 5),
            .realtime(status: 0xF8),
            .systemCommon(status: 0xF2, data1: 1, data2: 2),
        ])
    }

    func testSysexRoundTripAllLengths() {
        for len in 0...70 {
            let msg: [UInt8] = [0xF0] + (0..<len).map { UInt8($0 % 128) } + [0xF7]
            var d = UMPDecoder(maxSysexBytes: 128)
            let words = UMP.sysex7Words(msg)
            XCTAssertEqual(words.count, 2 * max(1, (len + 5) / 6))
            XCTAssertEqual(d.decode(words), [.sysex(bytes: msg, truncated: false)], "len \(len)")
        }
    }

    func testSysexInterleavedWithRealtimeAndOtherGroups() {
        let msg = TrillCodec.setConfig(5, [(.channel, 1), (.baseNote, 60)])!
        XCTAssertEqual(UMP.sysex7Words(msg).count, 4)
        let w = UMP.sysex7Words(msg)
        var d = UMPDecoder()
        // Clock between the SysEx7 packets, plus a note on group 1.
        let words = [w[0], w[1], 0x10F8_0000, 0x2190_3C64] + w[2...]
        let out = d.decode(Array(words))
        XCTAssertEqual(out, [.realtime(status: 0xF8), .noteOn(channel: 0, note: 60, velocity: 100), .sysex(bytes: msg, truncated: false)])
    }

    func testSysexIsBoundedAndRecoversFromMissingEnd() {
        var d = UMPDecoder(maxSysexBytes: 64)
        let long: [UInt8] = [0xF0] + [UInt8](repeating: 1, count: 300) + [0xF7]
        guard case let .sysex(b, truncated)? = d.decode(UMP.sysex7Words(long)).first else { return XCTFail() }
        XCTAssertTrue(truncated)
        XCTAssertEqual(b.count, 64)
        XCTAssertEqual(b.last, 0xF7)
        // A start without end, then a fresh complete message.
        let w = UMP.sysex7Words(long)
        XCTAssertTrue(d.decode(Array(w.prefix(4))).isEmpty)
        let ok = TrillCodec.hello(1)
        XCTAssertEqual(d.decode(UMP.sysex7Words(ok)), [.sysex(bytes: ok, truncated: false)])
        XCTAssertEqual(d.abandonedSysex, 1)
        // Continue/end without start are ignored; truncated trailing packet ignored.
        XCTAssertTrue(d.decode([0x3020_0101, 0, 0x3030_0101, 0]).isEmpty)
        XCTAssertTrue(d.decode([0x3000_0000]).isEmpty)
    }

    func testWordCounts() {
        XCTAssertEqual(UMP.wordCount(0x2000_0000), 1)
        XCTAssertEqual(UMP.wordCount(0x3000_0000), 2)
        XCTAssertEqual(UMP.wordCount(0x4000_0000), 2)
        XCTAssertEqual(UMP.wordCount(0x5000_0000), 4)
        XCTAssertEqual(UMP.wordCount(0xB000_0000), 3)
        var d = UMPDecoder()
        XCTAssertEqual(d.decode([0x4090_3C00, 0xFFFF_0000]), [.other(firstWord: 0x4090_3C00)], "MIDI 2.0 note shown as other")
    }

    func testMonitorBuffersAreBounded() {
        let b = EventBuffer(capacity: 10)
        b.append((0..<25).map { .noteOn(channel: 0, note: UInt8($0), velocity: 1) }, hostTime: 1)
        let (events, dropped) = b.drain()
        XCTAssertEqual(events.count, 10)
        XCTAssertEqual(dropped, 15)
        XCTAssertEqual(events.first?.message, .noteOn(channel: 0, note: 15, velocity: 1))
        XCTAssertTrue(b.drain().events.isEmpty)

        var m = MonitorModel(historyLimit: 5)
        m.apply(events)
        XCTAssertEqual(m.history.count, 5)
        XCTAssertEqual(m.channels[0].notes.count, 10)
        m.apply([MIDIEvent(id: 99, hostTime: 2, message: .controlChange(channel: 0, control: 123, value: 0)),
                 MIDIEvent(id: 100, hostTime: 2, message: .pitchBend(channel: 0, value: 16383))])
        XCTAssertTrue(m.channels[0].notes.isEmpty)
        XCTAssertEqual(m.channels[0].bendSemitones(range: 24), 24 * 8191.0 / 8192, accuracy: 1e-9)
    }

    func testConcurrentAppendDrain() {
        let b = EventBuffer(capacity: 100)
        let g = DispatchGroup()
        var drained = 0
        DispatchQueue.global().async(group: g) {
            for i in 0..<10_000 { b.append([.realtime(status: 0xF8)], hostTime: Double(i)) }
        }
        for _ in 0..<1000 { drained += b.drain().events.count }
        g.wait()
        drained += b.drain().events.count
        XCTAssertLessThanOrEqual(drained, 10_000)
        XCTAssertGreaterThan(drained, 0)
    }

    func testNoteNames() {
        XCTAssertEqual(NoteName.name(60), "C4")
        XCTAssertEqual(NoteName.name(0), "C-1")
        XCTAssertEqual(NoteName.name(69), "A4")
    }
}
