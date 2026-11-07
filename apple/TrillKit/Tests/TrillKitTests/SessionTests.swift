// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

/// A fake device speaking protocol v1 (mirrors the firmware handler for the
/// cases the session uses), so the session is tested end to end.
final class FakeTrill {
    var config = DeviceConfig.firmwareDefaults
    var generation = 0
    var bootID = 100
    var silent = false
    var actions: [TrillAction] = []

    func reply(to m: [UInt8]) -> [UInt8]? {
        guard !silent, TrillCodec.isTrillSysEx(m), m.count >= 8 else { return nil }
        let id = m[6]
        let hdr = { (t: UInt8) in [0xF0, 0x7D, 0x54, 0x52, 0x01, t, id] as [UInt8] }
        switch m[5] {
        case 0x01:
            return hdr(0x41) + [1, 0, 2, 0, 0, 3, 64, 13, 0, 0, 5, UInt8(bootID >> 7), UInt8(bootID & 0x7F), 0xF7]
        case 0x02:
            return configReply(hdr)
        case 0x03:
            var new = config
            for i in stride(from: 7, to: m.count - 1, by: 3) {
                guard let p = TrillParam(rawValue: m[i]) else { return hdr(0x7F) + [4, m[i], 0xF7] }
                let v = Int(m[i + 1]) << 7 | Int(m[i + 2])
                guard p.range.contains(v) else { return hdr(0x7F) + [5, p.rawValue, 0xF7] }
                new[p] = v
            }
            if new != config { generation = (generation + 1) & 0x3FFF; config = new }
            return configReply(hdr)
        case 0x04:
            let a = TrillAction(rawValue: m[7])!
            actions.append(a)
            if a == .restoreDefaults { config = .firmwareDefaults; return configReply(hdr) }
            return hdr(0x44) + [a.rawValue, 0xF7]
        default:
            return hdr(0x7F) + [2, m[5], 0xF7]
        }
    }

    func configReply(_ hdr: (UInt8) -> [UInt8]) -> [UInt8] {
        var r = hdr(0x42) + [UInt8(generation >> 7), UInt8(generation & 0x7F), 0]
        for p in TrillParam.allCases { r += [p.rawValue, UInt8(config[p] >> 7), UInt8(config[p] & 0x7F)] }
        return r + [0xF7]
    }
}

final class SessionTests: XCTestCase {
    var device = FakeTrill()
    var sent: [[UInt8]] = []
    var now: TimeInterval = 0
    var session: ConfigSession!

    override func setUp() {
        device = FakeTrill()
        sent = []
        now = 0
        session = ConfigSession { [unowned self] m in self.sent.append(m); return true }
    }

    /// Deliver every outstanding request to the fake device.
    func pump() {
        var guardCount = 0
        while let m = sent.first, guardCount < 20 {
            sent.removeFirst()
            guardCount += 1
            now += 0.003
            if let r = device.reply(to: m) { session.receive(r, now: now) }
        }
    }

    func testHandshakeThenConfig() {
        session.connect(now: now)
        XCTAssertEqual(session.phase, .handshaking)
        pump()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.hello?.firmwareString, "0.2.0")
        XCTAssertEqual(session.acknowledged, .firmwareDefaults)
        XCTAssertEqual(session.generation, 0)
    }

    func testApplySendsOnlyDifferencesAndTracksAcknowledgement() {
        session.connect(now: now); pump()
        var want = DeviceConfig.firmwareDefaults
        want[.channel] = 4
        want[.scale] = 1
        XCTAssertTrue(session.apply(want, now: now))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].count, 7 + 6 + 1, "two parameters")
        XCTAssertNotEqual(session.acknowledged, want, "not acknowledged until the reply")
        pump()
        XCTAssertEqual(session.acknowledged, want)
        XCTAssertEqual(session.generation, 1)
        XCTAssertFalse(session.apply(want, now: now), "nothing to send")
    }

    func testActionsAndRestoreDefaults() {
        session.connect(now: now); pump()
        var want = DeviceConfig.firmwareDefaults
        want[.baseNote] = 60
        session.apply(want, now: now); pump()
        session.perform(.panic, now: now)
        session.perform(.restoreDefaults, now: now)
        pump()
        XCTAssertEqual(device.actions, [.panic, .restoreDefaults])
        XCTAssertEqual(session.acknowledged, .firmwareDefaults)
    }

    func testTimeoutDuringHandshakeFails() {
        device.silent = true
        session.connect(now: now); pump()
        session.tick(now: 0.5)
        XCTAssertEqual(session.phase, .handshaking)
        session.tick(now: 1.01)
        guard case .failed = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertNil(session.pending)
    }

    func testTimeoutAfterReadyKeepsSessionAndContinuesQueue() {
        session.connect(now: now); pump()
        device.silent = true
        session.perform(.ledSelfTest, now: now)
        session.perform(.recalibrateGyro, now: now)
        XCTAssertEqual(sent.count, 1, "one in flight")
        sent.removeAll()
        session.tick(now: now + 2)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(sent.count, 1, "next request sent after timeout")
        XCTAssertTrue(session.log.contains { $0.isError })
    }

    func testStaleAndMismatchedRepliesIgnored() {
        session.connect(now: now); pump()
        session.perform(.panic, now: now)
        let req = sent.removeFirst()
        var reply = device.reply(to: req)!
        reply[6] = (reply[6] + 1) & 0x7F
        session.receive(reply, now: now)
        XCTAssertNotNil(session.pending, "wrong request id is ignored")
        session.receive(TrillCodec.hello(3), now: now)
        XCTAssertNotNil(session.pending, "a request echoed back is not a reply")
    }

    func testDeviceErrorDoesNotChangeAcknowledged() {
        session.connect(now: now); pump()
        // Bypass app-side validation to provoke a device error.
        device.config[.channel] = 0
        session.receive([0xF0, 0x7D, 0x54, 0x52, 0x01, 0x7F, 0x70, 0x05, 0x01, 0xF7], now: now)
        XCTAssertEqual(session.acknowledged, .firmwareDefaults)
    }

    func testRestartDetectedByBootID() {
        session.connect(now: now); pump()
        XCTAssertFalse(session.deviceRestarted)
        device.bootID = 101
        session.connect(now: now); pump()
        XCTAssertTrue(session.deviceRestarted)
    }

    func testNotReadyRefusesWork() {
        XCTAssertFalse(session.perform(.panic, now: 0))
        XCTAssertFalse(session.apply(.firmwareDefaults, now: 0))
        XCTAssertTrue(sent.isEmpty)
    }

    func testRequestIDsStay7Bit() {
        session.connect(now: now); pump()
        for _ in 0..<300 { session.perform(.panic, now: now); pump() }
        XCTAssertEqual(device.actions.count, 300)
    }
}
