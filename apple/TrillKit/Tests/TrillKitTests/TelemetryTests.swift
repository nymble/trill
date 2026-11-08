// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

final class TelemetryTests: XCTestCase {
    struct Fixture { let fields: [String: [Int]]; let bytes: [UInt8] }

    static func fixtures() throws -> [String: Fixture] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("protocol/telemetry-v1-frames.txt"), encoding: .utf8)
        var out: [String: Fixture] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.components(separatedBy: " | ")
            guard f.count == 3 else { continue }
            var fields: [String: [Int]] = [:]
            for kv in f[1].split(separator: " ") {
                let p = kv.split(separator: "=")
                fields[String(p[0])] = p[1].split(separator: ",").map { Int($0)! }
            }
            out[f[0]] = Fixture(fields: fields, bytes: f[2].split(separator: " ").map { UInt8($0, radix: 16)! })
        }
        return out
    }

    func testFixturesDecodeExactlyLikeRust() throws {
        let fx = try Self.fixtures()
        XCTAssertEqual(fx.count, 5)
        for (name, x) in fx {
            guard let f = TelemetryFrame.decode(x.bytes) else { XCTFail(name); continue }
            let v = x.fields
            XCTAssertEqual(x.bytes.count, TelemetryFrame.length, name)
            XCTAssertEqual(f.seq, v["seq"]![0], name)
            XCTAssertEqual(f.timeMs, v["t_ms"]![0], name)
            XCTAssertEqual(Int(f.flags), v["flags"]![0], name)
            XCTAssertEqual(f.imuStateCode, v["imu_state"]![0], name)
            XCTAssertEqual(f.trillStateCode, v["trill_state"]![0], name)
            XCTAssertEqual(f.accelMg, v["accel_mg"]!, name)
            XCTAssertEqual(f.gyroDdps, v["gyro_ddps"]!, name)
            XCTAssertEqual(f.pitchCdeg, v["pitch_cdeg"]![0], name)
            XCTAssertEqual(f.rollCdeg, v["roll_cdeg"]![0], name)
            XCTAssertEqual(f.touchPos, v["touch_pos"]![0], name)
            XCTAssertEqual(f.touchSize, v["touch_size"]![0], name)
            XCTAssertEqual(f.imuSamples, v["imu_samples"]![0], name)
            XCTAssertEqual(f.taps, v["taps"]![0], name)
            XCTAssertEqual(f.calibrations, v["calibrations"]![0], name)
            XCTAssertEqual(f.skipped, v["skipped"]![0], name)
            XCTAssertEqual(f.trillFrames, v["trill_frames"]![0], name)
            XCTAssertTrue(TelemetryFrame.isTelemetry(x.bytes))
            XCTAssertNil(TrillCodec.decodeReply(x.bytes), "telemetry is not a request reply")
        }
        let rest = TelemetryFrame.decode(fx["rest_no_trill"]!.bytes)!
        XCTAssertEqual(rest.accel[1], -0.977, accuracy: 1e-9)
        XCTAssertEqual(rest.roll, -77.3, accuracy: 1e-9)
        XCTAssertNil(rest.touchPosition, "no touch is not position 0")
        XCTAssertEqual(rest.trillState, .retrying)
        let invalid = TelemetryFrame.decode(fx["invalid_imu"]!.bytes)!
        XCTAssertFalse(invalid.imuValid)
        XCTAssertTrue(invalid.safeMode)
        let touch = TelemetryFrame.decode(fx["touch_and_motion"]!.bytes)!
        XCTAssertEqual(touch.touchPosition!, 8192.0 / 16383, accuracy: 1e-9)
    }

    func testMalformedFramesRejected() throws {
        let good = try Self.fixtures()["rest_no_trill"]!.bytes
        XCTAssertNotNil(TelemetryFrame.decode(good))
        XCTAssertNil(TelemetryFrame.decode(Array(good.dropLast())))
        var b = good; b[7] = 2; XCTAssertNil(TelemetryFrame.decode(b), "unknown format")
        b = good; b[20] = 0x90; XCTAssertNil(TelemetryFrame.decode(b), "status byte")
        b = good; b[5] = 0x42; XCTAssertNil(TelemetryFrame.decode(b))
    }

    func testRequestsMatchRustEncoder() throws {
        let v = try VectorTests.loadVectors()
        XCTAssertEqual(TrillCodec.telemetryStart(16, rateHz: 50), v["telemetry_start_50"]!.request)
        XCTAssertEqual(TrillCodec.telemetryStart(17, rateHz: 100), v["telemetry_start_100"]!.request)
        XCTAssertNil(TrillCodec.telemetryStart(18, rateHz: 0))
        XCTAssertNil(TrillCodec.telemetryStart(19, rateHz: 101))
        XCTAssertEqual(TrillCodec.telemetryStop(21), v["telemetry_stop"]!.request)
        guard case let .telemetryAck(id, rate, lease, len, fmt)? = TrillCodec.decodeReply(v["telemetry_start_50"]!.reply!) else { return XCTFail() }
        XCTAssertEqual([Int(id), rate, lease, len, fmt], [16, 50, 5, TelemetryFrame.length, TelemetryFrame.format])
        guard case let .error(_, code, detail)? = TrillCodec.decodeReply(v["telemetry_start_101"]!.reply!) else { return XCTFail() }
        XCTAssertEqual([code, detail], [5, 101])
    }

    func frame(seq: Int, t: Int, taps: Int = 0, cal: Int = 0, imu: Int = 0) -> TelemetryFrame {
        TelemetryFrame(seq: seq, timeMs: t, flags: 1, imuStateCode: 2, trillStateCode: 3, accelMg: [0, 0, 1000],
                       gyroDdps: [0, 0, 0], pitchCdeg: 0, rollCdeg: 0, touchPos: 0, touchSize: 0, imuSamples: imu,
                       taps: taps, calibrations: cal, skipped: 0, trillFrames: 0)
    }

    func testGapsWrapEventsAndStaleness() {
        var m = TelemetryModel(window: 10)
        m.apply([(frame(seq: 0x3FFE, t: 0x1F_FFF0, imu: 16380), 100.00),
                 (frame(seq: 0x3FFF, t: 0x1F_FFFF, imu: 16384 - 1), 100.02),
                 (frame(seq: 1, t: 30, taps: 2, imu: 15), 100.06)]) // seq 0 lost; time and counters wrapped
        XCTAssertEqual(m.framesReceived, 3)
        XCTAssertEqual(m.framesMissing, 1)
        XCTAssertTrue(m.points[2].gapBefore)
        XCTAssertFalse(m.points[1].gapBefore)
        XCTAssertEqual(m.points[2].deviceTime, (Double(0x20_0000) + 30 - Double(0x1F_FFF0)) / 1000, accuracy: 1e-9)
        XCTAssertEqual(m.tapsTotal, 2)
        XCTAssertEqual(m.events.map(\.kind), [.tap])
        XCTAssertEqual(m.imuRate, 0, "needs more than 0.2 s of device time")
        // Duplicate frames are ignored.
        m.apply([(frame(seq: 1, t: 30, taps: 2), 100.07)])
        XCTAssertEqual(m.framesReceived, 3)
        XCTAssertFalse(m.isStale(now: 100.1, rateHz: 50))
        XCTAssertTrue(m.isStale(now: 101, rateHz: 50))
        XCTAssertTrue(TelemetryModel().isStale(now: 0, rateHz: 50), "nothing received yet")
    }

    func testDeviceRestartStartsNewTraceAndWindowIsBounded() {
        var m = TelemetryModel(window: 1)
        for i in 0..<200 { m.apply([(frame(seq: 500 + i, t: 10 * i, cal: i / 100, imu: (4 * i) & 0x3FFF), 10 + Double(i) * 0.01)]) }
        XCTAssertLessThanOrEqual(m.points.count, 101)
        XCTAssertEqual(m.imuRate, 400, accuracy: 0.001, "device counter / device time")
        XCTAssertEqual(m.frameRate, 100, accuracy: 0.5)
        XCTAssertEqual(m.calibrationsTotal, 1)
        m.apply([(frame(seq: 0, t: 5), 13)]) // seq jumped backwards: device restarted
        XCTAssertEqual(m.points.count, 1)
        XCTAssertTrue(m.points[0].gapBefore)
        XCTAssertTrue(m.csv().hasPrefix("device_time_s,"))
        XCTAssertEqual(m.csv().split(separator: "\n").count, 2)
    }

    func testBufferIsBounded() {
        let b = TelemetryBuffer(capacity: 4)
        for i in 0..<10 { b.append(frame(seq: i, t: i), hostTime: Double(i)) }
        let (f, d) = b.drain()
        XCTAssertEqual(f.map(\.0.seq), [6, 7, 8, 9])
        XCTAssertEqual(d, 6)
        XCTAssertTrue(b.drain().frames.isEmpty)
    }
}

final class TelemetrySessionTests: XCTestCase {
    func run(telemetry: Bool) -> (ConfigSession, FakeTrill, () -> Void, (TimeInterval) -> Void) {
        let device = FakeTrill()
        device.telemetry = telemetry
        var sent: [[UInt8]] = []
        var now: TimeInterval = 0
        let s = ConfigSession { m in sent.append(m); return true }
        let pump = {
            while !sent.isEmpty { let m = sent.removeFirst(); now += 0.002; if let r = device.reply(to: m) { s.receive(r, now: now) } }
        }
        let advance = { (dt: TimeInterval) in now += dt; s.maintainTelemetry(desiredRate: 50, now: now); pump() }
        s.connect(now: now); pump()
        return (s, device, pump, advance)
    }

    func testOldFirmwareNeverGetsTelemetryRequests() {
        let (s, device, _, advance) = run(telemetry: false)
        XCTAssertTrue(s.isReady)
        XCTAssertFalse(s.supportsTelemetry)
        advance(0.1)
        XCTAssertNil(s.telemetryRate)
        XCTAssertEqual(device.telemetryRate, 0)
    }

    func testSubscribeRenewAndStop() {
        let (s, device, pump, advance) = run(telemetry: true)
        XCTAssertTrue(s.supportsTelemetry)
        advance(0.1)
        XCTAssertEqual(s.telemetryRate, 50)
        XCTAssertEqual(device.telemetryRate, 50)
        let firstAck = s.telemetryAckAt!
        advance(1.0)
        XCTAssertEqual(s.telemetryAckAt, firstAck, "no renewal before half the lease")
        advance(2.0)
        XCTAssertGreaterThan(s.telemetryAckAt!, firstAck, "renewed before the 5 s lease ends")
        s.maintainTelemetry(desiredRate: nil, now: 10); pump()
        XCTAssertEqual(s.telemetryRate, 0)
        XCTAssertEqual(device.telemetryRate, 0)
    }
}
