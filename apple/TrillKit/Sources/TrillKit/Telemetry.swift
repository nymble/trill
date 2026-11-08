// SPDX-License-Identifier: GPL-3.0-only
//
// Sensor telemetry (docs/config-protocol.md, "Telemetry"): frame decoding,
// a bounded thread-safe buffer filled on the CoreMIDI thread, and a rolling
// window with derived health (rates, gaps, staleness, tap and calibration
// events). Same wire format as trill-config's `telemetry` module; both are
// checked against protocol/telemetry-v1-frames.txt.

import Foundation

/// Sensor state codes reported by the firmware.
public enum SensorState: Int, Sendable {
    case off = 0, initializing, running, retrying, disabled
    public var title: String {
        switch self {
        case .off: return "off"
        case .initializing: return "starting"
        case .running: return "running"
        case .retrying: return "not detected / retrying"
        case .disabled: return "disabled (safe mode)"
        }
    }
}

/// One decoded telemetry frame, wire units plus physical accessors.
public struct TelemetryFrame: Equatable, Sendable {
    public static let format = 1
    public static let length = 54
    public static let rateRange = 1...100
    public static let defaultRateHz = 50
    public static let flagIMUValid: UInt8 = 0x01
    public static let flagCalibrated: UInt8 = 0x02
    public static let flagTouch: UInt8 = 0x04
    public static let flagIMUNew: UInt8 = 0x08
    public static let flagSafeMode: UInt8 = 0x10

    public var seq: Int
    public var timeMs: Int          // 21-bit, wraps
    public var flags: UInt8
    public var imuStateCode: Int
    public var trillStateCode: Int
    public var accelMg: [Int]       // x, y, z
    public var gyroDdps: [Int]      // 0.1 deg/s
    public var pitchCdeg: Int
    public var rollCdeg: Int
    public var touchPos: Int        // 0...16383
    public var touchSize: Int       // 0...16383
    public var imuSamples: Int      // 14-bit counter
    public var taps: Int            // 14-bit counter
    public var calibrations: Int    // 7-bit counter
    public var skipped: Int         // 14-bit counter
    public var trillFrames: Int     // 14-bit counter

    public var imuValid: Bool { flags & Self.flagIMUValid != 0 }
    public var calibrated: Bool { flags & Self.flagCalibrated != 0 }
    public var touching: Bool { flags & Self.flagTouch != 0 }
    public var safeMode: Bool { flags & Self.flagSafeMode != 0 }
    public var imuState: SensorState { SensorState(rawValue: imuStateCode) ?? .off }
    public var trillState: SensorState { SensorState(rawValue: trillStateCode) ?? .off }
    /// g
    public var accel: [Double] { accelMg.map { Double($0) / 1000 } }
    /// deg/s
    public var gyro: [Double] { gyroDdps.map { Double($0) / 10 } }
    public var pitch: Double { Double(pitchCdeg) / 100 }
    public var roll: Double { Double(rollCdeg) / 100 }
    /// 0...1 along the strip, nil without a touch.
    public var touchPosition: Double? { touching ? Double(touchPos) / 16383 : nil }
    public var touchContact: Double? { touching ? Double(touchSize) / 16383 : nil }

    public static func decode(_ m: [UInt8]) -> TelemetryFrame? {
        guard m.count == length, m.first == 0xF0, m.last == 0xF7, m[1] == TrillProtocol.manufacturerID,
              Array(m[2...3]) == TrillProtocol.signature, m[4] == TrillProtocol.version,
              m[5] == TrillProtocol.MessageType.telemetry.rawValue,
              m[1..<(m.count - 1)].allSatisfy({ $0 < 0x80 }) else { return nil }
        let p = Array(m[TrillProtocol.headerLength..<(m.count - 1)])
        guard Int(p[0]) == format else { return nil }
        func u14(_ i: Int) -> Int { Int(p[i]) << 7 | Int(p[i + 1]) }
        func i16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(p[i]) << 14 | UInt16(p[i + 1]) << 7 | UInt16(p[i + 2]))) }
        return TelemetryFrame(
            seq: u14(1), timeMs: Int(p[3]) << 14 | Int(p[4]) << 7 | Int(p[5]), flags: p[6],
            imuStateCode: Int(p[7]), trillStateCode: Int(p[8]),
            accelMg: [i16(9), i16(12), i16(15)], gyroDdps: [i16(18), i16(21), i16(24)],
            pitchCdeg: i16(27), rollCdeg: i16(30), touchPos: u14(33), touchSize: u14(35),
            imuSamples: u14(37), taps: u14(39), calibrations: Int(p[41]), skipped: u14(42), trillFrames: u14(44))
    }

    public static func isTelemetry(_ m: [UInt8]) -> Bool {
        m.count > 5 && TrillCodec.isTrillSysEx(m) && m[5] == TrillProtocol.MessageType.telemetry.rawValue
    }
}

/// Bounded FIFO between the CoreMIDI thread and the UI (oldest dropped).
public final class TelemetryBuffer: @unchecked Sendable {
    public let capacity: Int
    private var items: [(TelemetryFrame, Double)] = []
    private var dropped = 0
    private let lock = NSLock()

    public init(capacity: Int = 512) { self.capacity = max(capacity, 1) }

    public func append(_ f: TelemetryFrame, hostTime: Double) {
        lock.lock(); defer { lock.unlock() }
        if items.count >= capacity { items.removeFirst(); dropped += 1 }
        items.append((f, hostTime))
    }

    public func drain() -> (frames: [(TelemetryFrame, Double)], dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        let out = items; let d = dropped
        items.removeAll(keepingCapacity: true); dropped = 0
        return (out, d)
    }
}

/// A frame placed on a continuous device time axis.
public struct TelemetryPoint: Equatable, Sendable {
    /// Device time of the IMU sample, seconds since the first frame of this
    /// stream (21-bit ms clock unwrapped). Does not advance while the IMU is
    /// not producing samples.
    public let deviceTime: Double
    /// Host arrival time (CoreMIDI timestamp, seconds, monotonic).
    public let hostTime: Double
    /// True if one or more frames are missing right before this one.
    public let gapBefore: Bool
    public let frame: TelemetryFrame
}

/// A discrete event derived from counters (never synthesised).
public struct TelemetryEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case tap, calibration }
    public let kind: Kind
    /// Host arrival time of the frame that reported the counter change.
    public let hostTime: Double
    public let count: Int
}

/// Rolling window of telemetry with derived health. Pure value type, fed by
/// the UI at its own rate; time is injected for tests.
public struct TelemetryModel: Sendable {
    public let window: Double
    public let maxPoints: Int
    public private(set) var points: [TelemetryPoint] = []
    public private(set) var events: [TelemetryEvent] = []
    public private(set) var framesReceived = 0
    public private(set) var framesMissing = 0     // sequence gaps seen by the host
    public private(set) var bufferDropped = 0     // dropped in the app before the UI
    public private(set) var deviceSkipped = 0     // reported by the device
    public private(set) var lastHostTime: Double?
    /// Frame rate measured over the window (host arrival times), Hz.
    public private(set) var frameRate: Double = 0
    /// IMU sample rate measured from the device counter and device time, Hz.
    public private(set) var imuRate: Double = 0
    public private(set) var tapsTotal = 0
    public private(set) var calibrationsTotal = 0

    private var lastSeq: Int?
    private var lastTimeMs: Int?
    private var timeBase: Double = 0   // seconds added for 21-bit wraps
    private var firstTimeMs: Int?
    private var lastTaps: Int?
    private var lastCalibrations: Int?

    public init(window: Double = 10, maxPoints: Int = 1200) {
        self.window = window
        self.maxPoints = maxPoints
    }

    public var latest: TelemetryFrame? { points.last?.frame }

    /// Seconds since the last frame arrived (nil: never).
    public func age(now: Double) -> Double? { lastHostTime.map { now - $0 } }

    /// No frame for 3 expected periods (or 0.5 s), given the subscribed rate.
    public func isStale(now: Double, rateHz: Int) -> Bool {
        guard let a = age(now: now) else { return true }
        return a > max(0.5, 3.0 / Double(max(rateHz, 1)))
    }

    public mutating func reset() {
        self = TelemetryModel(window: window, maxPoints: maxPoints)
    }

    public mutating func apply(_ frames: [(TelemetryFrame, Double)], dropped: Int = 0) {
        bufferDropped += dropped
        for (f, host) in frames { add(f, host: host) }
        if let end = points.last?.hostTime {
            let cut = end - window
            if let i = points.firstIndex(where: { $0.hostTime >= cut }), i > 0 { points.removeFirst(i) }
            events.removeAll { $0.hostTime < cut }
        }
        if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
        updateRates()
    }

    private mutating func add(_ f: TelemetryFrame, host: Double) {
        framesReceived += 1
        var gap = false
        if let s = lastSeq {
            let d = (f.seq - s) & 0x3FFF
            if d == 0 { framesReceived -= 1; return } // duplicate
            if d > 0x2000 {
                // Duplicate or a restarted stream: start a new trace.
                restartAxis()
                gap = true
            } else if d > 1 {
                framesMissing += d - 1
                gap = true
            }
        }
        lastSeq = f.seq
        // Unwrap the 21-bit millisecond clock.
        if let t = lastTimeMs, f.timeMs < t, t - f.timeMs > 0x10_0000 { timeBase += Double(0x20_0000) / 1000 }
        if firstTimeMs == nil { firstTimeMs = f.timeMs }
        lastTimeMs = f.timeMs
        let dt = timeBase + Double(f.timeMs - (firstTimeMs ?? 0)) / 1000
        // Counters: events are counted only from increments we observed.
        if let t = lastTaps {
            let d = (f.taps - t) & 0x3FFF
            if d > 0 && d < 0x2000 { tapsTotal += d; events.append(.init(kind: .tap, hostTime: host, count: d)) }
        }
        lastTaps = f.taps
        if let c = lastCalibrations {
            let d = (f.calibrations - c) & 0x7F
            if d > 0 && d < 0x40 { calibrationsTotal += d; events.append(.init(kind: .calibration, hostTime: host, count: d)) }
        }
        lastCalibrations = f.calibrations
        deviceSkipped = f.skipped
        points.append(TelemetryPoint(deviceTime: dt, hostTime: host, gapBefore: gap, frame: f))
        lastHostTime = host
    }

    private mutating func restartAxis() {
        points.removeAll()
        events.removeAll()
        timeBase = 0
        firstTimeMs = nil
        lastTimeMs = nil
        lastTaps = nil
        lastCalibrations = nil
    }

    private mutating func updateRates() {
        guard points.count >= 2, let a = points.first, let b = points.last else { frameRate = 0; imuRate = 0; return }
        let host = b.hostTime - a.hostTime
        frameRate = host > 0 ? Double(points.count - 1) / host : 0
        // IMU rate from the device's own clock and sample counter (the
        // counter wraps at 16384, i.e. ~39 s at 416 Hz, longer than the window).
        let dev = b.deviceTime - a.deviceTime
        let n = (b.frame.imuSamples - a.frame.imuSamples) & 0x3FFF
        imuRate = dev > 0.2 && b.hostTime - a.hostTime < 30 ? Double(n) / dev : 0
    }

    /// CSV of the current window (physical units).
    public func csv() -> String {
        var s = "device_time_s,host_time_s,seq,gap_before,imu_valid,calibrated,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps,pitch_deg,roll_deg,touch,touch_pos,touch_size,imu_state,trill_state,imu_samples,taps,calibrations,device_skipped\n"
        for p in points {
            let f = p.frame
            let a = f.accel, g = f.gyro
            s += String(format: "%.3f,%.4f,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.2f,%.2f,%d,",
                        p.deviceTime, p.hostTime, f.seq, p.gapBefore ? 1 : 0, f.imuValid ? 1 : 0, f.calibrated ? 1 : 0,
                        a[0], a[1], a[2], g[0], g[1], g[2], f.pitch, f.roll, f.touching ? 1 : 0)
            s += f.touching ? String(format: "%.4f,%.4f,", f.touchPosition ?? 0, f.touchContact ?? 0) : ",,"
            s += "\(f.imuStateCode),\(f.trillStateCode),\(f.imuSamples),\(f.taps),\(f.calibrations),\(f.skipped)\n"
        }
        return s
    }
}
