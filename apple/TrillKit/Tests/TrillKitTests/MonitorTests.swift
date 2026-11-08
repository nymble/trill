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
}
