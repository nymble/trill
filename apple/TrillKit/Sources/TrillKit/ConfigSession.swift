// SPDX-License-Identifier: GPL-3.0-only
//
// Host side of the configuration protocol: handshake, one request in
// flight, request IDs, timeouts, and the distinction between what the user
// requested and what the device acknowledged. Transport-independent and
// clock-injected so it is unit tested without CoreMIDI.

import Foundation

public final class ConfigSession {
    public enum Phase: Equatable {
        case disconnected
        case handshaking
        case ready
        case failed(String)
    }

    public enum Request: Equatable {
        case hello
        case getConfig
        /// Read one page (page 1 needs firmware 0.4.0).
        case getConfigPage(Int)
        case setConfig([TrillParam: Int])
        case action(TrillAction)
        case telemetryStart(Int)
        case telemetryStop

        var title: String {
            switch self {
            case .hello: return "handshake"
            case .getConfig: return "read settings"
            case let .getConfigPage(p): return "read settings page \(p)"
            case .setConfig: return "apply settings"
            case let .action(a): return a.title
            case let .telemetryStart(r): return "sensor stream \(r) Hz"
            case .telemetryStop: return "stop sensor stream"
            }
        }
    }

    public struct Pending: Equatable {
        public let id: UInt8
        public let request: Request
        public let sentAt: TimeInterval
    }

    public struct LogEntry: Equatable {
        public let time: TimeInterval
        public let text: String
        public let isError: Bool
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var hello: TrillReply.Hello?
    /// Last parameter set the device reported. On firmware without
    /// `capConfigPages` the page-1 values are app defaults the device does
    /// not have; see `supportedPages`.
    public private(set) var acknowledged: DeviceConfig?
    /// Pages received since the handshake.
    public private(set) var receivedPages: Set<Int> = []
    public private(set) var generation: Int?
    public private(set) var pending: Pending?
    public private(set) var queue: [Request] = []
    public private(set) var log: [LogEntry] = []
    /// Set when the device's boot ID changed between handshakes: it restarted
    /// and its RAM-only settings went back to firmware defaults.
    public private(set) var deviceRestarted = false
    /// Telemetry rate the device acknowledged (0 = off, nil = unknown).
    public private(set) var telemetryRate: Int?
    public private(set) var telemetryLease: TimeInterval = 5
    public private(set) var telemetryAckAt: TimeInterval?
    public private(set) var telemetryError: String?

    public let timeout: TimeInterval
    public let maxQueue = 8
    public let maxLog = 100
    private let send: ([UInt8]) -> Bool
    private var nextID: UInt8 = 1
    private var lastBootID: Int?

    /// `send` transmits one complete SysEx message; it returns false if the
    /// transport refused it.
    public init(timeout: TimeInterval = TrillProtocol.replyTimeout, send: @escaping ([UInt8]) -> Bool) {
        self.timeout = timeout
        self.send = send
    }

    public var isReady: Bool { phase == .ready }
    public var isBusy: Bool { pending != nil || !queue.isEmpty }

    /// Start (or restart) the handshake on a newly selected endpoint pair.
    public func connect(now: TimeInterval) {
        pending = nil
        queue = []
        acknowledged = nil
        receivedPages = []
        generation = nil
        hello = nil
        deviceRestarted = false
        telemetryRate = nil
        telemetryAckAt = nil
        telemetryError = nil
        phase = .handshaking
        note(now, "handshake: HELLO sent")
        transmit(.hello, now: now)
    }

    public func disconnect(now: TimeInterval) {
        pending = nil
        queue = []
        telemetryRate = nil
        telemetryAckAt = nil
        phase = .disconnected
        note(now, "disconnected")
    }

    public func refresh(now: TimeInterval) {
        enqueue(.getConfig, now: now)
        for page in supportedPages.sorted() where page > 0 { enqueue(.getConfigPage(page), now: now) }
    }

    /// Pages this device has: page 0 always, page 1 with firmware 0.4.0+,
    /// page 2 with 0.5.0+.
    public var supportedPages: Set<Int> { hello?.pages ?? [0] }
    public var supportsConfigPages: Bool { hello?.supportsConfigPages ?? false }
    public var supportsStrikes: Bool { hello?.supportsStrikes ?? false }

    /// Parameters the connected device does not have (empty when not connected).
    public func unsupported(_ p: TrillParam) -> Bool { hello != nil && !supportedPages.contains(p.page) }

    /// Edits in `desired` that would be sent to this device.
    public func unappliedChanges(_ desired: DeviceConfig) -> [(TrillParam, Int)] {
        guard let ack = acknowledged else { return [] }
        return sendable(desired.changes(from: ack, pages: supportedPages))
    }

    /// Drops values this firmware would reject as out of range (tilt-strike
    /// mode and major/minor scales before 0.5.0).
    private func sendable(_ diff: [(TrillParam, Int)]) -> [(TrillParam, Int)] {
        supportsStrikes ? diff : diff.filter { !$0.0.requiresStrikes($0.1) }
    }

    /// Request a parameter set. Only differences from the acknowledged set
    /// are sent. Returns false if not ready or nothing changed.
    @discardableResult
    public func apply(_ desired: DeviceConfig, now: TimeInterval) -> Bool {
        guard isReady, let ack = acknowledged else { return false }
        // Parameters the firmware does not have are never sent (0.3.0 would
        // reject the whole request as unknownParam).
        let diff = sendable(desired.changes(from: ack, pages: supportedPages))
        guard !diff.isEmpty else { return false }
        // Replace already queued (not yet sent) sets with the newer ones.
        queue.removeAll { if case .setConfig = $0 { return true } else { return false } }
        // One request per page (the CONFIG reply covers the first parameter's
        // page), at most maxSetParams each. Each request is atomic on the
        // device; a preset touching both pages is applied as two or three.
        for page in 0..<TrillParam.pageCount {
            let part = diff.filter { $0.0.page == page }
            var i = 0
            while i < part.count {
                let chunk = part[i..<min(i + TrillProtocol.maxSetParams, part.count)]
                enqueue(.setConfig(Dictionary(uniqueKeysWithValues: Array(chunk))), now: now)
                i += TrillProtocol.maxSetParams
            }
        }
        return true
    }

    @discardableResult
    public func perform(_ action: TrillAction, now: TimeInterval) -> Bool {
        guard isReady, !action.needsConfigPages || supportsConfigPages else { return false }
        enqueue(.action(action), now: now)
        return true
    }

    /// The device streams sensor telemetry (HELLO capability, firmware 0.3.0+).
    public var supportsTelemetry: Bool { hello?.supportsTelemetry ?? false }

    /// Keep the telemetry subscription in the wanted state: start it, renew
    /// the lease before it expires (half the lease), or stop it. Call from
    /// the UI timer. `desiredRate` nil = off. Does nothing on firmware
    /// without telemetry.
    public func maintainTelemetry(desiredRate: Int?, now: TimeInterval) {
        guard isReady, supportsTelemetry, telemetryError == nil else { return }
        let inFlight = (pending.map { Self.isTelemetry($0.request) } ?? false) || queue.contains(where: Self.isTelemetry)
        guard !inFlight else { return }
        if let rate = desiredRate {
            let due = telemetryRate != rate || (telemetryAckAt.map { now - $0 >= telemetryLease / 2 } ?? true)
            if due { enqueue(.telemetryStart(rate), now: now) }
        } else if (telemetryRate ?? 0) != 0 {
            enqueue(.telemetryStop, now: now)
        }
    }

    /// Clear a telemetry error so `maintainTelemetry` tries again.
    public func retryTelemetry() { telemetryError = nil }

    static func isTelemetry(_ r: Request) -> Bool {
        switch r {
        case .telemetryStart, .telemetryStop: return true
        default: return false
        }
    }

    /// Feed every complete SysEx message received from the config source.
    public func receive(_ message: [UInt8], now: TimeInterval) {
        guard let reply = TrillCodec.decodeReply(message) else { return }
        guard let p = pending, p.id == reply.requestID else {
            note(now, "ignored stale or unsolicited reply (id \(reply.requestID))")
            return
        }
        pending = nil
        let ms = Int(((now - p.sentAt) * 1000).rounded())
        switch reply {
        case let .hello(_, h):
            guard h.protocolVersion == Int(TrillProtocol.version) else {
                fail(now, "device speaks protocol v\(h.protocolVersion), app speaks v\(TrillProtocol.version)")
                return
            }
            if let last = lastBootID, last != h.bootID { deviceRestarted = true }
            lastBootID = h.bootID
            hello = h
            note(now, "handshake: firmware \(h.firmwareString)\(h.isPCMSynthBuild ? " (pcm-synth)" : ""), protocol v\(h.protocolVersion), \(ms) ms")
            queue.insert(contentsOf: [.getConfig] + h.pages.sorted().dropFirst().map { .getConfigPage($0) }, at: 0)
        case let .config(_, gen, _, page, cfg):
            var merged = acknowledged ?? DeviceConfig()
            for param in TrillParam.params(page: page) { merged[param] = cfg[param] }
            acknowledged = merged
            receivedPages.insert(page)
            generation = gen
            if phase == .handshaking, receivedPages.isSuperset(of: supportedPages) { phase = .ready }
            // Restoring defaults replies with page 0 only: read the others too.
            if p.request == .action(.restoreDefaults) {
                queue.insert(contentsOf: supportedPages.sorted().dropFirst().map { .getConfigPage($0) }, at: 0)
            }
            note(now, "\(p.request.title): acknowledged, generation \(gen), \(ms) ms")
        case let .actionAck(_, a):
            note(now, "\(a.title): acknowledged, \(ms) ms")
        case let .telemetryAck(_, rate, lease, _, _):
            if telemetryRate != rate { note(now, rate == 0 ? "sensor stream stopped" : "sensor stream on at \(rate) Hz (lease \(lease) s), \(ms) ms") }
            telemetryRate = rate
            telemetryLease = TimeInterval(max(lease, 1))
            telemetryAckAt = now
        case let .error(_, code, detail):
            let c = TrillErrorCode(rawValue: code)
            var text = "\(p.request.title): device error \(code) (\(c?.summary ?? "unknown"))"
            if c == .outOfRange || c == .unknownParam || c == .duplicateParam {
                text += ", parameter \(TrillParam(rawValue: detail).map { $0.key } ?? String(detail))"
            }
            note(now, text, error: true)
            if Self.isTelemetry(p.request) { telemetryError = text }
            if phase == .handshaking { fail(now, text); return }
        }
        sendNext(now: now)
    }

    /// Call periodically (e.g. 10 Hz) to detect timeouts.
    public func tick(now: TimeInterval) {
        guard let p = pending, now - p.sentAt >= timeout else { return }
        pending = nil
        let text = "\(p.request.title): no reply within \(Int(timeout * 1000)) ms"
        if phase == .handshaking {
            fail(now, text + " (is this the Trill configuration port, firmware 0.2.0 or newer?)")
            return
        }
        note(now, text, error: true)
        if Self.isTelemetry(p.request) { telemetryError = text }
        sendNext(now: now)
    }

    // MARK: - Internals

    private func enqueue(_ r: Request, now: TimeInterval) {
        if queue.count >= maxQueue { queue.removeFirst() }
        queue.append(r)
        if pending == nil { sendNext(now: now) }
    }

    private func sendNext(now: TimeInterval) {
        guard pending == nil, !queue.isEmpty else { return }
        transmit(queue.removeFirst(), now: now)
    }

    private func transmit(_ r: Request, now: TimeInterval) {
        let id = nextID
        nextID = nextID >= 0x7F ? 1 : nextID + 1
        let bytes: [UInt8]?
        switch r {
        case .hello: bytes = TrillCodec.hello(id)
        case .getConfig: bytes = TrillCodec.getConfig(id)
        case let .getConfigPage(page): bytes = TrillCodec.getConfig(id, page: page)
        case let .setConfig(v): bytes = TrillCodec.setConfig(id, v.sorted { $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value) })
        case let .action(a): bytes = TrillCodec.action(id, a)
        case let .telemetryStart(rate): bytes = TrillCodec.telemetryStart(id, rateHz: rate)
        case .telemetryStop: bytes = TrillCodec.telemetryStop(id)
        }
        guard let b = bytes, send(b) else {
            note(now, "\(r.title): could not send", error: true)
            if phase == .handshaking { fail(now, "could not send to the selected destination") }
            return
        }
        pending = Pending(id: id, request: r, sentAt: now)
    }

    private func fail(_ now: TimeInterval, _ why: String) {
        phase = .failed(why)
        queue = []
        pending = nil
        note(now, why, error: true)
    }

    private func note(_ now: TimeInterval, _ text: String, error: Bool = false) {
        log.append(LogEntry(time: now, text: text, isError: error))
        if log.count > maxLog { log.removeFirst(log.count - maxLog) }
    }
}
