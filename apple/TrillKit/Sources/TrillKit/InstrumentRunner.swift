// SPDX-License-Identifier: GPL-3.0-only
//
// Runs the impulse engine on telemetry frames and turns strikes into MIDI
// note bytes for the app's own MIDI source (app-generated MIDI, see
// docs/instrument-view.md). Thread-safe: frames arrive on the CoreMIDI
// thread, the UI reads snapshots on the main thread.

import Foundation

public final class InstrumentRunner: @unchecked Sendable {
    /// What the UI draws.
    public struct Snapshot: Equatable, Sendable {
        public var readout = ImpulseReadout()
        public var lastStrike: InstrumentStrike?
        /// Note of `lastStrike`.
        public var lastNote: SpelledNote?
        /// Host time of `lastStrike`, seconds.
        public var lastStrikeHostTime: Double = -.infinity
        /// Strength (× threshold) over the last few seconds, oldest first, with host times.
        public var history: [Double] = []
        public var historyTimes: [Double] = []
        public var strikeTimes: [Double] = []
        public var strikes = 0
        public var framesSeen = 0
        public init() {}
    }

    public static let historySeconds = 3.0

    private let lock = NSLock()
    private var engine: ImpulseEngine
    private var instrumentStore: HandpanInstrument
    private var clock = DeviceClock()
    private var snap = Snapshot()
    private var sounding: [Int: Int] = [:]   // note → generation
    private var generation = 0
    private var channelStore = 0
    private var gateStore = 0.4
    private var sendStore: (([UInt8]) -> Void)?
    private let noteOffQueue = DispatchQueue(label: "trillium.instrument.noteoff")

    public init(settings: ImpulseSettings = ImpulseSettings(), instrument: HandpanInstrument) {
        engine = ImpulseEngine(settings: settings)
        instrumentStore = instrument
    }

    /// Receives complete MIDI 1.0 messages (3 bytes); nil = do not play.
    public var send: (([UInt8]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sendStore }
        set {
            lock.lock(); let old = sendStore; sendStore = newValue
            let held = old != nil && newValue == nil ? Array(sounding.keys) : []
            if !held.isEmpty { sounding.removeAll() }
            let ch = channelStore
            lock.unlock()
            for n in held { old?([0x80 | UInt8(ch), UInt8(n), 0]) }
        }
    }

    public var settings: ImpulseSettings {
        get { lock.lock(); defer { lock.unlock() }; return engine.settings }
        set { lock.lock(); engine.settings = newValue; lock.unlock() }
    }

    public var instrument: HandpanInstrument {
        get { lock.lock(); defer { lock.unlock() }; return instrumentStore }
        set { lock.lock(); instrumentStore = newValue; lock.unlock() }
    }

    /// MIDI channel 0…15.
    public var channel: Int {
        get { lock.lock(); defer { lock.unlock() }; return channelStore }
        set { lock.lock(); channelStore = max(0, min(15, newValue)); lock.unlock() }
    }

    /// Note length before the note-off, seconds.
    public var gate: Double {
        get { lock.lock(); defer { lock.unlock() }; return gateStore }
        set { lock.lock(); gateStore = max(0.02, min(4, newValue)); lock.unlock() }
    }

    public func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    public func resetRoll() { lock.lock(); engine.resetRoll(); snap.readout = engine.readout; lock.unlock() }

    public func currentPoseAsUp() -> UpAxis? { lock.lock(); defer { lock.unlock() }; return engine.currentPoseAsUp() }

    /// A telemetry frame (any thread). Frames without a new IMU sample are skipped.
    public func handle(_ f: TelemetryFrame, hostTime: Double) {
        guard f.imuValid, f.flags & TelemetryFrame.flagIMUNew != 0 else { return }
        lock.lock()
        let t = clock.seconds(f.timeMs)
        lock.unlock()
        process(time: t, accel: Vec3(f.accel), gyro: Vec3(f.gyro), taps: f.taps, hostTime: hostTime)
    }

    /// One IMU sample (any thread); also used by the screenshot demo and tests.
    public func process(time: Double, accel: Vec3, gyro: Vec3, taps: Int?, hostTime: Double) {
        lock.lock()
        let strike = engine.process(time: time, accel: accel, gyro: gyro, taps: taps)
        snap.readout = engine.readout
        snap.framesSeen += 1
        snap.history.append(engine.readout.strength)
        snap.historyTimes.append(hostTime)
        let cut = hostTime - Self.historySeconds
        if let i = snap.historyTimes.firstIndex(where: { $0 >= cut }), i > 0 {
            snap.history.removeFirst(i); snap.historyTimes.removeFirst(i)
        }
        snap.strikeTimes.removeAll { $0 < cut }
        var messages: [[UInt8]] = []
        var offAfter: (note: Int, gen: Int, delay: Double)?
        if let s = strike {
            let note = instrumentStore.note(sector: s.sector ?? 0, ring: s.sector == nil ? .ding : s.ring)
            snap.lastStrike = s
            snap.lastNote = note
            snap.lastStrikeHostTime = hostTime
            snap.strikes += 1
            snap.strikeTimes.append(hostTime)
            if sendStore != nil, (0...127).contains(note.midi) {
                let ch = UInt8(channelStore)
                if sounding[note.midi] != nil { messages.append([0x80 | ch, UInt8(note.midi), 0]) }
                messages.append([0x90 | ch, UInt8(note.midi), UInt8(max(1, min(127, s.velocity)))])
                generation += 1
                sounding[note.midi] = generation
                offAfter = (note.midi, generation, gateStore)
            }
        }
        let out = sendStore
        lock.unlock()
        for m in messages { out?(m) }
        if let o = offAfter {
            noteOffQueue.asyncAfter(deadline: .now() + o.delay) { [weak self] in self?.noteOff(o.note, generation: o.gen) }
        }
    }

    private func noteOff(_ note: Int, generation g: Int) {
        lock.lock()
        guard sounding[note] == g else { lock.unlock(); return }
        sounding[note] = nil
        let out = sendStore, ch = UInt8(channelStore)
        lock.unlock()
        out?([0x80 | ch, UInt8(note), 0])
    }
}
