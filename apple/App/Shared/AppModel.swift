// SPDX-License-Identifier: GPL-3.0-only
//
// Main-actor state for the SwiftUI views. MIDI input is buffered off the
// main thread (EventBuffer) and drained at a fixed UI rate, so a busy
// stream never floods the main thread and never delays CoreMIDI.

import Foundation
import CoreMIDI
import SwiftUI
import TrillKit

@MainActor
final class AppModel: ObservableObject {
    // Endpoints
    @Published private(set) var sources: [MIDIEndpointInfo] = []
    @Published private(set) var destinations: [MIDIEndpointInfo] = []
    @Published var monitorSourceID: MIDIUniqueID? { didSet { applyMonitorSource() } }
    @Published var configSourceID: MIDIUniqueID? { didSet { if oldValue != configSourceID { disconnectConfig() } } }
    @Published var configDestinationID: MIDIUniqueID? { didSet { if oldValue != configDestinationID { disconnectConfig() } } }
    @Published private(set) var midiError: String?

    // Monitor
    @Published private(set) var monitor = MonitorModel(historyLimit: 2000)
    @Published var monitorPaused = false
    @Published var monitorChannel = 0

    // Sensors (telemetry on the configuration port, firmware 0.3.0+)
    /// The Sensors view is on screen; telemetry is only requested then.
    @Published var sensorsVisible = false
    @Published var sensorsLive = true
    @Published var sensorsPaused = false { didSet { if !sensorsPaused { telemetry = liveTelemetry } else { framesAtPause = liveTelemetry.framesReceived } } }
    @Published var telemetryRateHz = TelemetryFrame.defaultRateHz
    /// What the charts show (frozen while paused).
    @Published private(set) var telemetry = TelemetryModel(window: 10)
    /// Always-updating model; differs from `telemetry` only while paused.
    private(set) var liveTelemetry = TelemetryModel(window: 10)
    private(set) var framesAtPause = 0
    @Published private(set) var clock: TimeInterval = 0

    // Configuration
    @Published private(set) var sessionRevision = 0
    @Published var draft = DeviceConfig.firmwareDefaults

    // Presets
    @Published private(set) var presets: [Preset] = []
    @Published var presetError: String?

    let events = EventBuffer(capacity: 4096)
    let telemetryBuffer = TelemetryBuffer(capacity: 512)
    private(set) var client: MIDIClient?
    private(set) var session: ConfigSession!
    private var timer: Timer?
    private let presetStore: PresetStore

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        presetStore = PresetStore(fileURL: dir.appendingPathComponent("Trill/presets.json"))
        presets = presetStore.presets
        session = ConfigSession { [weak self] bytes in
            guard let self, let c = self.client, let d = self.configDestinationID else { return false }
            return c.send(sysex: bytes, to: d)
        }
        do {
            let c = try MIDIClient(name: "Trillium", events: events, telemetry: telemetryBuffer)
            c.onSetupChanged = { [weak self] in self?.refreshEndpoints() }
            c.onConfigMessage = { [weak self] bytes, _ in self?.configMessage(bytes) }
            client = c
        } catch {
            midiError = error.localizedDescription
        }
        refreshEndpoints()
        // 30 Hz UI drain + 10 Hz-or-better timeout checks.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Endpoints

    func refreshEndpoints() {
        guard let c = client else { return }
        sources = c.sources()
        destinations = c.destinations()
        // Suggest the Trill ports once, without sending anything: port 1 =
        // instrument output, port 2 = configuration. The user still has to
        // press Connect before the app sends a byte.
        if monitorSourceID == nil, let s = sources.first(where: { $0.isTrill && $0.portIndex == 0 }) {
            monitorSourceID = s.id
        }
        if configSourceID == nil, let s = sources.first(where: { $0.isTrill && $0.portIndex == 1 }) {
            configSourceID = s.id
        }
        if configDestinationID == nil, let d = destinations.first(where: { $0.isTrill && $0.portIndex == 1 }) {
            configDestinationID = d.id
        }
        // Hot-plug: an endpoint that vanished ends the session; listening
        // resumes automatically when the same endpoint (unique ID) returns.
        if let id = configDestinationID, !destinations.contains(where: { $0.id == id && !$0.isOffline }), session.phase != .disconnected {
            session.disconnect(now: now)
            sessionRevision += 1
        }
        applyMonitorSource()
        if let id = configSourceID { _ = c.setConfigSource(sources.contains { $0.id == id } ? id : nil) }
    }

    private func applyMonitorSource() {
        guard let c = client else { return }
        let id = monitorSourceID.flatMap { id in sources.contains { $0.id == id } ? id : nil }
        if !c.setMonitorSource(id), id != nil { midiError = "Could not listen to the selected source." }
    }

    func source(_ id: MIDIUniqueID?) -> MIDIEndpointInfo? { sources.first { $0.id == id } }
    func destination(_ id: MIDIUniqueID?) -> MIDIEndpointInfo? { destinations.first { $0.id == id } }

    var destinationLooksLikeTrill: Bool { destination(configDestinationID)?.isTrill ?? false }

    // MARK: Session

    func connectConfig() {
        guard let c = client, let s = configSourceID, configDestinationID != nil else { return }
        _ = c.setConfigSource(s)
        session.connect(now: now)
        sessionRevision += 1
    }

    func disconnectConfig() {
        guard session.phase != .disconnected else { return }
        // Best effort; the device also drops the stream when its 5 s lease ends.
        session.maintainTelemetry(desiredRate: nil, now: now)
        session.disconnect(now: now)
        sessionRevision += 1
    }

    private func configMessage(_ bytes: [UInt8]) {
        let wasReady = session.isReady
        let before = session.acknowledged
        session.receive(bytes, now: now)
        if let ack = session.acknowledged, ack != before, !wasReady || draft == (before ?? ack) {
            // Follow the device while the user has no unapplied edits.
            draft = ack
        }
        sessionRevision += 1
    }

    func applyDraft() {
        if session.apply(draft, now: now) { sessionRevision += 1 }
    }

    func revertDraft() {
        if let a = session.acknowledged { draft = a }
    }

    func readFromDevice() {
        session.refresh(now: now)
        sessionRevision += 1
    }

    func perform(_ a: TrillAction) {
        if session.perform(a, now: now) { sessionRevision += 1 }
    }

    /// Edits the connected firmware could take (page-1 edits on firmware
    /// 0.3.0 are not counted: they are never sent there).
    var hasUnappliedEdits: Bool { !session.unappliedChanges(draft).isEmpty }

    /// Fill the editor with a built-in preset (nothing is sent until Apply).
    func load(builtIn p: BuiltInPreset) { draft = p.config }

    func setHideTrillSysEx(_ on: Bool) { monitor.hideTrillSysEx = on }

    // MARK: Timer

    private func tick() {
        let (newEvents, dropped) = events.drain()
        if !monitorPaused, !newEvents.isEmpty || dropped > 0 {
            monitor.apply(newEvents, dropped: dropped)
        }
        monitor.idle(now: now)
        let (frames, lost) = telemetryBuffer.drain()
        if !frames.isEmpty || lost > 0 {
            liveTelemetry.apply(frames, dropped: lost)
            if !sensorsPaused { telemetry = liveTelemetry }
        }
        if sensorsVisible { clock = MIDIClient.now() }
        let pending = session.pending
        session.tick(now: now)
        session.maintainTelemetry(desiredRate: sensorsVisible && sensorsLive ? telemetryRateHz : nil, now: now)
        if pending != session.pending { sessionRevision += 1 }
    }

    func clearMonitor() { monitor.clear() }

    func setHideRealtime(_ on: Bool) { monitor.hideRealtime = on }

    func resetSensors() {
        liveTelemetry.reset()
        telemetry = liveTelemetry
        framesAtPause = 0
    }

    func retryTelemetry() {
        session.retryTelemetry()
        sessionRevision += 1
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try presetStore.save(Preset(name: trimmed, config: draft))
            presets = presetStore.presets
        } catch { presetError = error.localizedDescription }
    }

    func deletePreset(_ p: Preset) {
        do {
            try presetStore.delete(id: p.id)
            presets = presetStore.presets
        } catch { presetError = error.localizedDescription }
    }

    func load(_ p: Preset) { draft = p.config }

    func importPreset(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 64 * 1024 else { throw Preset.PresetError.notAPreset }
            var p = try Preset.decode(data)
            p.id = UUID()
            try presetStore.save(p)
            presets = presetStore.presets
        } catch { presetError = error.localizedDescription }
    }
}
