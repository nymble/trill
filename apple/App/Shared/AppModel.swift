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
    @Published var draft = DeviceConfig.firmwareDefaults { didSet { if draft != oldValue { draftChangedAt = now } } }
    private var draftChangedAt: TimeInterval = 0

    /// What the editor is working on.
    enum EditTarget: Equatable {
        /// Whatever Trillium is playing; not tied to a preset.
        case current
        /// A new preset, not saved yet.
        case new
        case saved(UUID)
        case builtIn(String)
    }
    @Published var editing: EditTarget = .current

    /// Send editor changes to Trillium as they are made (short debounce).
    var liveApply: Bool {
        get { UserDefaults.standard.object(forKey: "liveApply") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveApply"); objectWillChange.send() }
    }

    // Strikes and taps seen on port 1 (for the Motion overview).
    struct Hit: Equatable {
        let direction: StrikeDirection?
        let note: Int
        let velocity: Int
        let time: TimeInterval
    }
    @Published private(set) var lastHit: Hit?

    // Navigation
    @Published var tab: AppTab = .home
    @Published var settingsPath: [SettingsPage] = []

    /// Jump to the full mapping editor (Settings › Sound & mapping).
    func openMapping() {
        settingsPath = [.mapping]
        tab = .settings
    }

    // Presets
    @Published private(set) var presets: [Preset] = []
    /// The user's refinements of built-in presets, by built-in id.
    @Published private(set) var builtInEdits: [String: DeviceConfig] = [:]
    @Published var presetError: String?

    let events = EventBuffer(capacity: 4096)
    let telemetryBuffer = TelemetryBuffer(capacity: 512)
    private(set) var client: MIDIClient?
    private(set) var session: ConfigSession!
    private var timer: Timer?
    private let presetStore: PresetStore
    private let builtInStore: PresetStore

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        presetStore = PresetStore(fileURL: dir.appendingPathComponent("Trill/presets.json"))
        presets = presetStore.presets
        // Refined built-ins: one Preset per built-in, its name is the built-in id.
        builtInStore = PresetStore(fileURL: dir.appendingPathComponent("Trill/builtin-edits.json"))
        builtInEdits = Dictionary(builtInStore.presets.map { ($0.name, $0.config) }, uniquingKeysWith: { a, _ in a })
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
        if autoConnect, trillDetected, session.phase == .disconnected { connectToDetected() }
    }

    private func applyMonitorSource() {
        guard let c = client else { return }
        let id = monitorSourceID.flatMap { id in sources.contains { $0.id == id } ? id : nil }
        if !c.setMonitorSource(id), id != nil { midiError = "Could not listen to the selected source." }
    }

    func source(_ id: MIDIUniqueID?) -> MIDIEndpointInfo? { sources.first { $0.id == id } }
    func destination(_ id: MIDIUniqueID?) -> MIDIEndpointInfo? { destinations.first { $0.id == id } }

    var destinationLooksLikeTrill: Bool { destination(configDestinationID)?.isTrill ?? false }

    /// A Trillium (online) is on the MIDI bus: both configuration endpoints
    /// (port 2) are present.
    var trillDetected: Bool {
        sources.contains { $0.isTrill && $0.portIndex == 1 && !$0.isOffline }
            && destinations.contains { $0.isTrill && $0.portIndex == 1 && !$0.isOffline }
    }

    /// Connect automatically when a Trillium appears (Settings › Connection).
    var autoConnect: Bool {
        get { UserDefaults.standard.bool(forKey: "autoConnect") }
        set { UserDefaults.standard.set(newValue, forKey: "autoConnect"); objectWillChange.send() }
    }

    /// Select the detected Trillium's ports and start the handshake.
    func connectToDetected() {
        if let s = sources.first(where: { $0.isTrill && $0.portIndex == 1 && !$0.isOffline }) { configSourceID = s.id }
        if let d = destinations.first(where: { $0.isTrill && $0.portIndex == 1 && !$0.isOffline }) { configDestinationID = d.id }
        if let s = sources.first(where: { $0.isTrill && $0.portIndex == 0 && !$0.isOffline }) { monitorSourceID = s.id }
        connectConfig()
    }

    /// Name of the built-in or saved preset matching what the device runs
    /// (or the editor, when not connected).
    var activePresetName: String? {
        let cfg = session.acknowledged ?? draft
        let pages = session.supportedPages
        let same = { (c: DeviceConfig) in c.changes(from: cfg, pages: pages).isEmpty }
        return builtIns.first { same($0.config) }?.name ?? presets.first { same($0.config) }?.name
    }

    /// Built-in presets with the user's refinements applied.
    var builtIns: [BuiltInPreset] {
        BuiltInPreset.all.map { p in builtInEdits[p.id].map { p.with(config: $0) } ?? p }
    }

    /// Load a preset into the editor and, if connected, send it.
    func use(_ config: DeviceConfig) {
        draft = config
        editing = .current
        if session.isReady { applyDraft() }
    }

    // MARK: Editing presets

    /// Open a preset in the editor; it plays on Trillium while you edit.
    func edit(builtIn p: BuiltInPreset) {
        draft = p.config
        editing = .builtIn(p.id)
        if session.isReady { applyDraft() }
    }

    func edit(saved p: Preset) {
        draft = p.config
        editing = .saved(p.id)
        if session.isReady { applyDraft() }
    }

    /// Start a new preset from the current sound.
    func newPreset() {
        if let a = session.acknowledged, !hasUnappliedEdits { draft = a }
        editing = .new
    }

    var editingName: String? {
        switch editing {
        case .current: return nil
        case .new: return "New preset"
        case let .saved(id): return presets.first { $0.id == id }?.name
        case let .builtIn(id): return BuiltInPreset.all.first { $0.id == id }?.name
        }
    }

    /// The saved version of what is being edited, to show unsaved changes.
    var editingSavedConfig: DeviceConfig? {
        switch editing {
        case .current, .new: return nil
        case let .saved(id): return presets.first { $0.id == id }?.config
        case let .builtIn(id): return builtIns.first { $0.id == id }?.config
        }
    }

    var hasUnsavedPresetEdits: Bool {
        guard let c = editingSavedConfig else { return editing == .new }
        return c != draft
    }

    /// Save over the preset being edited (built-ins keep their original,
    /// restorable with `restoreBuiltIn`).
    func saveEdits() {
        do {
            switch editing {
            case .current, .new:
                return
            case let .saved(id):
                guard var p = presets.first(where: { $0.id == id }) else { return }
                p.config = draft
                try presetStore.save(p)
                presets = presetStore.presets
            case let .builtIn(id):
                let existing = builtInStore.presets.first { $0.name == id }
                try builtInStore.save(Preset(id: existing?.id ?? UUID(), name: id, config: draft))
                reloadBuiltInEdits()
            }
        } catch { presetError = error.localizedDescription }
    }

    /// Save the editor as a new preset and keep editing that one.
    func saveAsNew(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let p = Preset(name: trimmed, config: draft)
        do {
            try presetStore.save(p)
            presets = presetStore.presets
            editing = .saved(p.id)
        } catch { presetError = error.localizedDescription }
    }

    /// Save a copy without touching the editor or the device.
    func duplicate(_ config: DeviceConfig, named name: String) {
        do {
            try presetStore.save(Preset(name: name, config: config))
            presets = presetStore.presets
        } catch { presetError = error.localizedDescription }
    }

    func isEdited(builtIn id: String) -> Bool { builtInEdits[id] != nil }

    /// Throw away the user's refinement of a built-in preset.
    func restoreBuiltIn(_ id: String) {
        do {
            for p in builtInStore.presets where p.name == id { try builtInStore.delete(id: p.id) }
            reloadBuiltInEdits()
            if editing == .builtIn(id), let p = builtIns.first(where: { $0.id == id }) { draft = p.config }
        } catch { presetError = error.localizedDescription }
    }

    /// A refined built-in (or any config) as a preset file, e.g. to send back
    /// for inclusion in the app.
    func presetForExport(builtIn p: BuiltInPreset) -> Preset { Preset(name: p.name, config: p.config) }

    private func reloadBuiltInEdits() {
        builtInEdits = Dictionary(builtInStore.presets.map { ($0.name, $0.config) }, uniquingKeysWith: { a, _ in a })
    }

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
        noteHits(newEvents)
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
        // Live editing: send edits once the user pauses for a moment and the
        // previous request has been answered.
        if liveApply, editing != .current || settingsPath.contains(.mapping), session.isReady, session.pending == nil,
           now - draftChangedAt > 0.12, hasUnappliedEdits {
            applyDraft()
        }
    }

    /// Percussion note-ons on port 1, matched to strike directions.
    private func noteHits(_ events: [MIDIEvent]) {
        let cfg = session.acknowledged ?? draft
        for e in events {
            guard case let .noteOn(ch, note, vel) = e.message, vel > 0, cfg[.percussionEnabled] == 1,
                  Int(ch) == cfg[.percussionChannel] else { continue }
            lastHit = Hit(direction: StrikeDirection.matching(channel: Int(ch), note: Int(note), config: cfg),
                          note: Int(note), velocity: Int(vel), time: e.hostTime)
        }
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
