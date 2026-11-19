// SPDX-License-Identifier: GPL-3.0-only
//
// Eight-direction strike detection from IMU telemetry for the instrument
// view (docs/instrument-view.md). Pure Swift, no platform frameworks, so it
// runs in unit tests on synthetic traces.
//
// Frames: the device frame is the IMU's own X, Y, Z. "Up" is a device axis
// (or a pose the user sets); "N" is a second device axis at right angles to
// it, the forward mark. Directions are worked out in a horizontal plane
// built from measured gravity, not from the device axes, so a strike to the
// east still reads E when the device is upside down.

import Foundation

/// Minimal 3-vector.
public struct Vec3: Equatable, Sendable, Codable {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public init(_ a: [Double]) { self.init(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0) }
    public static let zero = Vec3(0, 0, 0)
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, k: Double) -> Vec3 { Vec3(a.x * k, a.y * k, a.z * k) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { sqrt(dot(self)) }
    public var normalized: Vec3 { let l = length; return l > 1e-9 ? self * (1 / l) : self }
}

/// Which device direction counts as up.
public enum UpAxis: Equatable, Sendable, Codable, Hashable {
    case plusX, minusX, plusY, minusY, plusZ, minusZ
    /// A pose captured with "Set current pose as up" (unit vector, device frame).
    case custom(Vec3)

    public static let axes: [UpAxis] = [.plusZ, .minusZ, .plusX, .minusX, .plusY, .minusY]

    public var title: String {
        switch self {
        case .plusX: return "+X"
        case .minusX: return "−X"
        case .plusY: return "+Y"
        case .minusY: return "−Y"
        case .plusZ: return "+Z"
        case .minusZ: return "−Z"
        case .custom: return "Set pose"
        }
    }

    public var vector: Vec3 {
        switch self {
        case .plusX: return Vec3(1, 0, 0)
        case .minusX: return Vec3(-1, 0, 0)
        case .plusY: return Vec3(0, 1, 0)
        case .minusY: return Vec3(0, -1, 0)
        case .plusZ: return Vec3(0, 0, 1)
        case .minusZ: return Vec3(0, 0, -1)
        case let .custom(v): return v.normalized
        }
    }

    /// The forward mark (N) for this up: the next axis round (X→Y→Z→X),
    /// or for a custom pose the device axis most at right angles to it.
    public var forward: Vec3 {
        let u = vector
        let candidates = [Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 0)]
        let pick: Vec3
        switch self {
        case .plusX, .minusX: pick = Vec3(0, 1, 0)
        case .plusY, .minusY: pick = Vec3(0, 0, 1)
        case .plusZ, .minusZ: pick = Vec3(1, 0, 0)
        case .custom: pick = candidates.min { abs($0.dot(u)) < abs($1.dot(u)) }!
        }
        return (pick - u * pick.dot(u)).normalized
    }
}

/// How the sensor is mounted; sets how a swing is turned into a direction.
public enum Mounting: String, CaseIterable, Codable, Sendable {
    /// On top of a stick or rod held or fixed at the bottom (pivot below).
    case stick
    /// Hanging from a string (pivot above).
    case hanging
    /// Held or free: accelerometer only.
    case free

    public var title: String {
        switch self {
        case .stick: return "On a stick"
        case .hanging: return "Hanging"
        case .free: return "Free"
        }
    }
}

/// Tunables. Defaults are starting points, not tuned on hardware.
public struct ImpulseSettings: Equatable, Codable, Sendable {
    /// Horizontal acceleration transient that counts as a strike, g.
    public var accelThreshold: Double = 0.6
    /// Sudden change of rotation rate (stick or string only) that counts as a strike, °/s.
    public var swingThreshold: Double = 120
    /// Strike strength (multiple of threshold) that gives velocity 127. Lower = more sensitive.
    public var fullVelocityRatio: Double = 4
    /// Softest velocity sent.
    public var minVelocity: Int = 24
    /// Debounce: crossings within this window after the first count as one strike; the peak sets direction and velocity, s.
    public var debounce: Double = 0.02
    /// Refractory period after a strike, s.
    public var refractory: Double = 0.15
    /// Re-arm only after the signal falls below this fraction of the threshold.
    public var rearmRatio: Double = 0.5
    /// Ignore transients whose vertical part exceeds this multiple of the horizontal part (taps along the up axis).
    public var verticalRejection: Double = 2.0
    /// Gravity follows the accelerometer with this time constant (and the gyro in between), s.
    public var gravityTimeConstant: Double = 0.4
    /// Tilt from vertical where ring 2 starts, degrees.
    public var ring2Tilt: Double = 30
    /// Tilt from vertical where every strike plays the ding, degrees (≥ 90: off).
    public var dingTilt: Double = 60
    /// Gyro rates below this are treated as zero for the multi-turn roll, °/s (limits drift).
    public var rollDeadband: Double = 1.5
    /// When the board's own tap counter goes up but no threshold was crossed
    /// (a short transient between telemetry samples), play anyway.
    public var tapAssist: Bool = true
    public var mounting: Mounting = .stick
    public var up: UpAxis = .plusZ
    /// Rotates the sector labels: 0…7 eighths of a turn clockwise.
    public var northOffset: Int = 0

    public init() {}
}

/// One detected strike.
public struct InstrumentStrike: Equatable, Sendable {
    public var time: Double
    /// 0 = N, then clockwise to 7 = NW, after `northOffset`; nil = no clear direction (ding).
    public var sector: Int?
    /// Direction of the push, degrees clockwise from N.
    public var angle: Double
    public var ring: HandpanRing
    /// Peak strength as a multiple of threshold (≥ 1).
    public var strength: Double
    public var velocity: Int
    /// Tilt from vertical at the strike, degrees (0…90, upside down folded).
    public var tilt: Double
    public var upsideDown: Bool
    /// Set when only the board's tap counter saw it.
    public var fromTapCounter: Bool
}

/// Live state for display.
public struct ImpulseReadout: Equatable, Sendable {
    /// Horizontal push now, as (E, N) in multiples of threshold.
    public var push: (east: Double, north: Double) = (0, 0)
    /// Strength now as a multiple of threshold.
    public var strength: Double = 0
    /// Angle between the up axis and vertical, 0…180°.
    public var tiltFromUp: Double = 0
    /// Tilt folded to 0…90° (what selects the ring).
    public var tilt: Double = 0
    /// Which way the up axis leans, degrees clockwise from N.
    public var tiltHeading: Double = 0
    public var upsideDown = false
    /// Rotation about the up axis since reset, degrees, not wrapped.
    public var roll: Double = 0
    public var ring: HandpanRing = .first
    public var armed = true
    public var gravityValid = false

    public static func == (a: ImpulseReadout, b: ImpulseReadout) -> Bool {
        a.push.east == b.push.east && a.push.north == b.push.north && a.strength == b.strength && a.tilt == b.tilt
            && a.tiltFromUp == b.tiltFromUp && a.tiltHeading == b.tiltHeading && a.upsideDown == b.upsideDown
            && a.roll == b.roll && a.ring == b.ring && a.armed == b.armed && a.gravityValid == b.gravityValid
    }

    /// Whole turns and remainder, e.g. roll 495° → (1, 135).
    public var rollTurns: (turns: Int, degrees: Double) {
        let t = Int((roll / 360).rounded(.towardZero))
        return (t, roll - Double(t) * 360)
    }
}

/// Eight compass sectors, 45° each, centred on N, NE, E …
public enum CompassSector {
    public static let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    /// Sector for an angle in degrees clockwise from N.
    public static func index(angle: Double) -> Int {
        let a = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int(((a + 22.5) / 45).rounded(.down)) % 8
    }
}

/// The detector. Feed it one IMU sample per telemetry frame, in order.
public struct ImpulseEngine: Sendable {
    public var settings: ImpulseSettings {
        didSet { if settings.up != oldValue.up { resetRoll() } }
    }
    public private(set) var readout = ImpulseReadout()

    private var gravity: Vec3?
    private var lastTime: Double?
    private var lastGyro: Vec3?
    private var lastTaps: Int?
    private var armed = true
    private var refractoryUntil = -Double.infinity
    private var lastStrikeTime = -Double.infinity
    /// Open debounce window: start time and best candidate so far.
    private var window: (start: Double, best: Candidate)?
    /// Recent horizontal candidates (for tap assist).
    private var recent: [Candidate] = []
    private var upsideDown = false

    struct Candidate {
        var time: Double
        var east: Double
        var north: Double
        var strength: Double
        var tilt: Double
        var upsideDown: Bool
    }

    public init(settings: ImpulseSettings = ImpulseSettings()) { self.settings = settings }

    public mutating func resetRoll() { readout.roll = 0 }

    /// Current gravity direction in the device frame (unit, pointing up), if known.
    public var upDirection: Vec3? { gravity?.normalized }

    /// "Set current pose as up": the device direction now pointing up.
    public func currentPoseAsUp() -> UpAxis? { upDirection.map { .custom($0) } }

    /// Process one sample. `accel` in g (specific force: reads +1 g along
    /// up at rest), `gyro` in °/s, `time` in seconds (device clock),
    /// `taps` the board's tap counter if known. Returns a strike, if any.
    public mutating func process(time: Double, accel: Vec3, gyro: Vec3, taps: Int? = nil) -> InstrumentStrike? {
        let s = settings
        let dt: Double
        if let t0 = lastTime, time > t0 { dt = min(time - t0, 0.25) } else { dt = 0 }
        let gapReset = lastTime.map { time - $0 > 0.25 || time < $0 } ?? true
        lastTime = time

        // 1. Gravity: rotate the estimate with the gyro, then pull it toward
        //    the accelerometer while the reading is close to 1 g.
        let wRad = gyro * (Double.pi / 180)
        if var g = gravity {
            if dt > 0 { g = g - wRad.cross(g) * dt }
            let mag = accel.length
            if window == nil, abs(mag - 1) < 0.2, dt > 0 {
                let k = min(1, dt / max(s.gravityTimeConstant, 1e-3))
                g = g + (accel - g) * k
            }
            gravity = g.normalized
        } else if abs(accel.length - 1) < 0.3 {
            gravity = accel.normalized
        }
        guard let gHat = gravity else {
            readout.gravityValid = false
            lastGyro = gyro; lastTaps = taps
            return nil
        }
        readout.gravityValid = true

        // 2. Tilt and upside down (with hysteresis).
        let u = s.up.vector
        let cosT = max(-1, min(1, gHat.dot(u)))
        let tiltFromUp = acos(cosT) * 180 / .pi
        if upsideDown { if tiltFromUp < 80 { upsideDown = false } } else if tiltFromUp > 100 { upsideDown = true }
        let tilt = upsideDown ? 180 - tiltFromUp : tiltFromUp

        // 3. Horizontal frame from gravity: n = forward mark projected, e = n × up.
        var n = s.up.forward - gHat * s.up.forward.dot(gHat)
        if n.length < 0.2 {
            // Forward mark close to vertical: use the up axis itself (tipped over).
            n = (u * (upsideDown ? 1 : -1)) - gHat * u.dot(gHat)
        }
        n = n.normalized
        let e = n.cross(gHat).normalized
        // Rotate labels by the north offset (eighths, clockwise).
        let off = Double(((s.northOffset % 8) + 8) % 8) * .pi / 4
        let nRot = n * cos(off) + e * sin(off)
        let eRot = nRot.cross(gHat).normalized

        // Lean direction of the up axis (which way it tips), for display.
        let leanVec = u * (upsideDown ? -1 : 1)
        let lean = leanVec - gHat * leanVec.dot(gHat)
        let tiltHeading = lean.length > 1e-6 ? atan2(lean.dot(eRot), lean.dot(nRot)) * 180 / .pi : 0

        // 4. Multi-turn roll about the up axis (gyro integration, never wrapped).
        let rate = gyro.dot(u)
        if dt > 0, abs(rate) > s.rollDeadband { readout.roll += rate * dt }

        // 5. Push signals: accelerometer transient and (stick/string) swing change.
        let dyn = accel - gHat
        let aE = dyn.dot(eRot), aN = dyn.dot(nRot), aV = dyn.dot(gHat)
        let aH = (aE * aE + aN * aN).squareRoot()
        var accStrength = aH / max(s.accelThreshold, 1e-3)
        if aH > 0, abs(aV) > s.verticalRejection * aH { accStrength = 0 }
        var swE = 0.0, swN = 0.0, swStrength = 0.0
        if s.mounting != .free, let g0 = lastGyro, !gapReset {
            // Change of velocity of the sensor end: Δω × r, r = up (stick) or down (hanging).
            let r = s.mounting == .stick ? gHat : -gHat
            let dv = (gyro - g0).cross(r)
            swE = dv.dot(eRot); swN = dv.dot(nRot)
            swStrength = (swE * swE + swN * swN).squareRoot() / max(s.swingThreshold, 1e-3)
        }
        lastGyro = gyro

        let cand: Candidate
        if accStrength >= swStrength {
            cand = Candidate(time: time, east: aE / max(aH, 1e-9) * accStrength, north: aN / max(aH, 1e-9) * accStrength,
                             strength: accStrength, tilt: tilt, upsideDown: upsideDown)
        } else {
            let m = (swE * swE + swN * swN).squareRoot()
            cand = Candidate(time: time, east: swE / max(m, 1e-9) * swStrength, north: swN / max(m, 1e-9) * swStrength,
                             strength: swStrength, tilt: tilt, upsideDown: upsideDown)
        }
        recent.append(cand)
        if recent.count > 4 { recent.removeFirst(recent.count - 4) }

        readout.push = (cand.east, cand.north)
        readout.strength = cand.strength
        readout.tiltFromUp = tiltFromUp
        readout.tilt = tilt
        readout.tiltHeading = tiltHeading
        readout.upsideDown = upsideDown
        readout.ring = ring(tilt: tilt)

        // 6. Strike state machine: armed → debounce window → fire → refractory → re-arm.
        var strike: InstrumentStrike?
        if var w = window {
            if cand.strength > w.best.strength { w.best = cand }
            window = w
            if time - w.start >= s.debounce - 1e-6 {
                strike = fire(w.best, at: time, fromTap: false)
            }
        } else if armed, time >= refractoryUntil, cand.strength >= 1 {
            if s.debounce <= 0 {
                strike = fire(cand, at: time, fromTap: false)
            } else {
                window = (time, cand)
            }
        } else if !armed, time >= refractoryUntil, cand.strength < s.rearmRatio {
            armed = true
        }

        // 7. Tap assist: the board saw a tap between our samples.
        if let t = taps, let t0 = lastTaps, s.tapAssist, strike == nil, window == nil {
            let d = (t - t0 + 0x4000) % 0x4000
            if d > 0, d < 64, time >= refractoryUntil, time - lastStrikeTime > s.refractory {
                let best = recent.max { $0.strength < $1.strength } ?? cand
                var c = best
                c.time = time
                c.strength = max(1, best.strength)
                strike = fire(c, at: time, fromTap: true, direction: best.strength >= 0.35)
            }
        }
        lastTaps = taps
        readout.armed = armed && window == nil && time >= refractoryUntil
        return strike
    }

    private func ring(tilt: Double) -> HandpanRing {
        if settings.dingTilt < 90, tilt >= settings.dingTilt { return .ding }
        if tilt >= settings.ring2Tilt { return .second }
        return .first
    }

    public func velocity(strength: Double) -> Int {
        let s = settings
        let x = max(0, min(1, (strength - 1) / max(s.fullVelocityRatio - 1, 1e-3)))
        let lo = Double(max(1, min(127, s.minVelocity)))
        return Int((lo + (127 - lo) * pow(x, 0.7)).rounded())
    }

    private mutating func fire(_ c: Candidate, at time: Double, fromTap: Bool, direction: Bool = true) -> InstrumentStrike {
        window = nil
        armed = false
        refractoryUntil = time + settings.refractory
        lastStrikeTime = time
        let angle = (atan2(c.east, c.north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let r = ring(tilt: c.tilt)
        return InstrumentStrike(time: c.time, sector: direction && r != .ding ? CompassSector.index(angle: angle) : nil,
                                angle: angle, ring: direction ? r : .ding, strength: c.strength,
                                velocity: velocity(strength: c.strength), tilt: c.tilt,
                                upsideDown: c.upsideDown, fromTapCounter: fromTap)
    }
}

/// Unwraps a 21-bit millisecond device clock (telemetry `timeMs`) into seconds.
public struct DeviceClock: Sendable {
    private var last: Int?
    private var base = 0.0
    public init() {}
    public mutating func seconds(_ ms: Int) -> Double {
        if let l = last, ms < l, l - ms > 0x10_0000 { base += Double(0x20_0000) / 1000 }
        last = ms
        return base + Double(ms) / 1000
    }
}
