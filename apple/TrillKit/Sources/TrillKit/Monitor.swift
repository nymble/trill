// SPDX-License-Identifier: GPL-3.0-only
//
// Monitor model: a bounded, lock-protected event buffer filled from the
// CoreMIDI receive thread and drained by the UI at a fixed rate, plus
// per-channel state derived from standard MIDI messages.

import Foundation

/// A received message with its host timestamp in seconds (CoreMIDI host
/// time converted with mach_timebase_info; monotonic, not wall clock).
public struct MIDIEvent: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let hostTime: Double
    public let message: MIDIMessage
    public init(id: UInt64, hostTime: Double, message: MIDIMessage) {
        self.id = id
        self.hostTime = hostTime
        self.message = message
    }
}

/// Thread-safe bounded FIFO. `append` never blocks for long and never grows
/// beyond `capacity` (oldest events are dropped and counted).
public final class EventBuffer: @unchecked Sendable {
    public let capacity: Int
    private var items: [MIDIEvent] = []
    private var head = 0
    private var nextID: UInt64 = 0
    private var dropped = 0
    private let lock = NSLock()

    public init(capacity: Int = 2048) {
        self.capacity = max(capacity, 1)
        items.reserveCapacity(self.capacity)
    }

    public func append(_ messages: [MIDIMessage], hostTime: Double) {
        lock.lock(); defer { lock.unlock() }
        for m in messages {
            let e = MIDIEvent(id: nextID, hostTime: hostTime, message: m)
            nextID &+= 1
            if items.count - head >= capacity {
                head += 1
                dropped += 1
            }
            items.append(e)
        }
        if head > capacity { items.removeFirst(head); head = 0 }
    }

    /// Take everything queued since the last drain, and the number of
    /// events dropped because the buffer was full.
    public func drain() -> (events: [MIDIEvent], dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        let out = Array(items[head...])
        items.removeAll(keepingCapacity: true)
        head = 0
        let d = dropped
        dropped = 0
        return (out, d)
    }
}

/// What the monitor shows for one MIDI channel.
public struct ChannelState: Equatable, Sendable {
    public var notes: [UInt8: UInt8] = [:] // note -> velocity
    public var pitchBend: UInt16 = 8192
    public var pressure: UInt8 = 0
    public var controllers: [UInt8: UInt8] = [:]
    public var lastActivity: Double = 0

    public init() {}

    /// Bend in semitones for a given bend range.
    public func bendSemitones(range: Int) -> Double {
        (Double(pitchBend) - 8192) / 8192 * Double(range)
    }
}

/// Bounded history plus per-channel state.
public struct MonitorModel: Sendable {
    public let historyLimit: Int
    public private(set) var history: [MIDIEvent] = []
    public private(set) var channels = [ChannelState](repeating: ChannelState(), count: 16)
    public private(set) var dropped = 0
    public private(set) var total = 0

    public init(historyLimit: Int = 500) { self.historyLimit = max(historyLimit, 1) }

    public mutating func apply(_ events: [MIDIEvent], dropped d: Int = 0) {
        dropped += d
        total += events.count
        for e in events { update(e) }
        history.append(contentsOf: events.suffix(historyLimit))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    public mutating func clear() {
        history.removeAll()
        channels = [ChannelState](repeating: ChannelState(), count: 16)
        dropped = 0
        total = 0
    }

    mutating func update(_ e: MIDIEvent) {
        guard let ch = e.message.channel.map(Int.init) else { return }
        var s = channels[ch]
        s.lastActivity = e.hostTime
        switch e.message {
        case let .noteOn(_, n, v): s.notes[n] = v
        case let .noteOff(_, n, _): s.notes[n] = nil
        case let .controlChange(_, cc, v):
            s.controllers[cc] = v
            // All Sound Off / Reset All Controllers / All Notes Off.
            if cc == 120 || cc == 123 { s.notes.removeAll() }
            if cc == 121 { s.pitchBend = 8192; s.pressure = 0 }
        case let .channelPressure(_, v): s.pressure = v
        case let .pitchBend(_, v): s.pitchBend = v
        default: break
        }
        channels[ch] = s
    }
}
