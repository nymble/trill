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
    var telemetry = false
    var telemetryRate = 0
    /// Firmware 0.4.0 behaviour: paged configuration, params 14...30, action 5.
    var pages = false

    func known(_ p: TrillParam) -> Bool { pages || p.page == 0 }

    func reply(to m: [UInt8]) -> [UInt8]? {
        guard !silent, TrillCodec.isTrillSysEx(m), m.count >= 8 else { return nil }
        let id = m[6]
        let hdr = { (t: UInt8) in [0xF0, 0x7D, 0x54, 0x52, 0x01, t, id] as [UInt8] }
        switch m[5] {
        case 0x01:
            let minor: UInt8 = pages ? 4 : telemetry ? 3 : 2
            let caps: UInt8 = (telemetry ? 0x0B : 3) | (pages ? 0x10 : 0)
            return hdr(0x41) + [1, 0, minor, 0, 0, caps, 64, pages ? 30 : 13, 0, 0, 5, UInt8(bootID >> 7), UInt8(bootID & 0x7F), 0xF7]
        case 0x02:
            let payload = Array(m[7..<(m.count - 1)])
            if payload.isEmpty { return configReply(hdr, page: 0) }
            guard pages else { return hdr(0x7F) + [3, UInt8(payload.count), 0xF7] }
            guard payload.count == 1, payload[0] < 2 else { return hdr(0x7F) + [5, payload[0], 0xF7] }
            return configReply(hdr, page: Int(payload[0]))
        case 0x03:
            var new = config
            for i in stride(from: 7, to: m.count - 1, by: 3) {
                guard let p = TrillParam(rawValue: m[i]), known(p) else { return hdr(0x7F) + [4, m[i], 0xF7] }
                let v = Int(m[i + 1]) << 7 | Int(m[i + 2])
                guard p.range.contains(v) else { return hdr(0x7F) + [5, p.rawValue, 0xF7] }
                new[p] = v
            }
            if new != config { generation = (generation + 1) & 0x3FFF; config = new }
            return configReply(hdr, page: TrillParam(rawValue: m[7])!.page)
        case 0x04:
            guard let a = TrillAction(rawValue: m[7]), !a.needsConfigPages || pages else { return hdr(0x7F) + [7, m[7], 0xF7] }
            actions.append(a)
            if a == .restoreDefaults { config = .firmwareDefaults; return configReply(hdr, page: 0) }
            return hdr(0x44) + [a.rawValue, 0xF7]
        case 0x05 where telemetry:
            guard (1...100).contains(Int(m[7])) else { return hdr(0x7F) + [5, m[7], 0xF7] }
            telemetryRate = Int(m[7])
            return hdr(0x45) + [m[7], 5, 54, 1, 0xF7]
        case 0x06 where telemetry:
            telemetryRate = 0
            return hdr(0x45) + [0, 5, 54, 1, 0xF7]
        default:
            return hdr(0x7F) + [2, m[5], 0xF7]
        }
    }

    func configReply(_ hdr: (UInt8) -> [UInt8], page: Int) -> [UInt8] {
        var r = hdr(0x42) + [UInt8(generation >> 7), UInt8(generation & 0x7F), 0]
        for p in TrillParam.params(page: page) { r += [p.rawValue, UInt8(config[p] >> 7), UInt8(config[p] & 0x7F)] }
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

    // MARK: Firmware 0.4.0 paged configuration

    func testPagedHandshakeReadsBothPages() {
        device.telemetry = true
        device.pages = true
        device.config[.mode] = 2
        session.connect(now: now); pump()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.supportsConfigPages)
        XCTAssertEqual(session.receivedPages, [0, 1])
        XCTAssertEqual(session.acknowledged?[.mode], 2)
        XCTAssertEqual(session.acknowledged, device.config)
    }

    func testPresetTouchingBothPagesIsSplitPerPageAndAcknowledged() {
        device.pages = true
        session.connect(now: now); pump()
        var want = DeviceConfig.firmwareDefaults
        want[.channel] = 3
        want[.mode] = 1
        want[.gestureAxis] = 3
        XCTAssertTrue(session.apply(want, now: now))
        pump()
        XCTAssertEqual(session.acknowledged, want)
        XCTAssertEqual(device.config, want)
        XCTAssertTrue(session.unappliedChanges(want).isEmpty)
        // All 17 page-1 parameters at once: more than one request holds.
        var all = want
        for p in TrillParam.params(page: 1) { all[p] = p.range.upperBound }
        XCTAssertTrue(session.apply(all, now: now))
        pump()
        XCTAssertEqual(device.config, all)
        XCTAssertEqual(session.acknowledged, all)
    }

    func testOldFirmwareNeverGetsPageOneParametersOrActions() {
        device.telemetry = true // 0.3.0
        session.connect(now: now); pump()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertFalse(session.supportsConfigPages)
        XCTAssertTrue(session.unsupported(.mode))
        XCTAssertFalse(session.unsupported(.channel))
        var want = DeviceConfig.firmwareDefaults
        want[.mode] = 2
        want[.tapThresholdCg] = 50
        XCTAssertFalse(session.apply(want, now: now), "only unsupported edits: nothing sent")
        XCTAssertTrue(session.unappliedChanges(want).isEmpty)
        want[.baseNote] = 60
        XCTAssertTrue(session.apply(want, now: now))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].count, 7 + 3 + 1, "page-0 change only")
        pump()
        XCTAssertEqual(device.config[.baseNote], 60)
        XCTAssertEqual(device.config[.mode], 0)
        XCTAssertFalse(session.perform(.zeroOrientation, now: now))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(session.log.contains { $0.isError })
    }

    func testRestoreDefaultsRereadsPageOne() {
        device.pages = true
        session.connect(now: now); pump()
        var want = DeviceConfig.firmwareDefaults
        want[.mode] = 2
        session.apply(want, now: now); pump()
        XCTAssertEqual(session.acknowledged?[.mode], 2)
        session.perform(.restoreDefaults, now: now); pump()
        XCTAssertEqual(session.acknowledged, .firmwareDefaults)
        XCTAssertTrue(session.perform(.zeroOrientation, now: now)); pump()
        XCTAssertEqual(device.actions, [.restoreDefaults, .zeroOrientation])
    }
}
