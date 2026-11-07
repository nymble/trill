// SPDX-License-Identifier: GPL-3.0-only
//
// CoreMIDI adapter (macOS and iOS). Uses only documented CoreMIDI APIs:
// MIDIClientCreateWithBlock for setup/hot-plug notifications,
// MIDIInputPortCreateWithProtocol(._1_0) for input as UMP event lists,
// MIDIOutputPortCreate + MIDISendEventList for output.
//
// Sources (device -> app) and destinations (app -> device) are separate
// endpoints. This class connects only the sources the caller selects and
// sends only to the destination the caller passes; it never broadcasts and
// never creates virtual endpoints, so it cannot form a MIDI loop.

#if canImport(CoreMIDI)
import CoreMIDI
import Foundation

public struct MIDIEndpointInfo: Identifiable, Hashable, Sendable {
    public let id: MIDIUniqueID
    public let name: String
    public let deviceName: String?
    /// 0-based index of this endpoint among its device's sources (or
    /// destinations). For the Trill firmware: 0 = instrument, 1 = config.
    public let portIndex: Int?
    public let isOffline: Bool

    public var isTrill: Bool { (deviceName ?? name).localizedCaseInsensitiveContains("Trill") }
    public var title: String {
        guard let d = deviceName, d != name, !name.hasPrefix(d) else { return name }
        return "\(d) – \(name)"
    }
}

public final class MIDIClient {
    public struct Failure: Error, LocalizedError {
        public let call: String
        public let status: OSStatus
        public var errorDescription: String? { "CoreMIDI \(call) failed (OSStatus \(status))" }
    }

    /// Instrument messages from the monitor source.
    public let events: EventBuffer
    /// Called on the main queue after CoreMIDI reports a setup change
    /// (device plugged/unplugged, endpoint renamed or taken offline).
    public var onSetupChanged: (() -> Void)?
    /// Called on the main queue for each complete Trill SysEx message from
    /// the configuration source, with its host time in seconds.
    public var onConfigMessage: (([UInt8], Double) -> Void)?

    private var client = MIDIClientRef()
    private var monitorPort = MIDIPortRef()
    private var configPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var monitorSource: MIDIEndpointRef = 0
    private var configSource: MIDIEndpointRef = 0
    private let lock = NSLock()
    private var monitorDecoder = UMPDecoder(maxSysexBytes: 256)
    private var configDecoder = UMPDecoder(maxSysexBytes: TrillProtocol.maxMessageLength)
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    public init(name: String = "Trill", events: EventBuffer) throws {
        self.events = events
        var status = MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] note in
            switch note.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                DispatchQueue.main.async { self?.onSetupChanged?() }
            default:
                break
            }
        }
        guard status == noErr else { throw Failure(call: "MIDIClientCreateWithBlock", status: status) }
        status = MIDIInputPortCreateWithProtocol(client, "\(name) Monitor" as CFString, ._1_0, &monitorPort) { [weak self] list, _ in
            self?.receive(list, config: false)
        }
        guard status == noErr else { throw Failure(call: "MIDIInputPortCreateWithProtocol", status: status) }
        status = MIDIInputPortCreateWithProtocol(client, "\(name) Config In" as CFString, ._1_0, &configPort) { [weak self] list, _ in
            self?.receive(list, config: true)
        }
        guard status == noErr else { throw Failure(call: "MIDIInputPortCreateWithProtocol", status: status) }
        status = MIDIOutputPortCreate(client, "\(name) Config Out" as CFString, &outPort)
        guard status == noErr else { throw Failure(call: "MIDIOutputPortCreate", status: status) }
    }

    deinit {
        MIDIPortDispose(monitorPort)
        MIDIPortDispose(configPort)
        MIDIPortDispose(outPort)
        MIDIClientDispose(client)
    }

    /// Convert a CoreMIDI host timestamp to seconds (0 = "now").
    public static func seconds(_ t: MIDITimeStamp) -> Double {
        Double(t == 0 ? mach_absolute_time() : t) * timebase
    }

    public static func now() -> Double { seconds(0) }

    // MARK: Endpoints

    public func sources() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfSources()).map { Self.info(MIDIGetSource($0), source: true) }
    }

    public func destinations() -> [MIDIEndpointInfo] {
        (0..<MIDIGetNumberOfDestinations()).map { Self.info(MIDIGetDestination($0), source: false) }
    }

    static func string(_ obj: MIDIObjectRef, _ key: CFString) -> String? {
        var s: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, key, &s) == noErr, let v = s?.takeRetainedValue() else { return nil }
        return v as String
    }

    static func integer(_ obj: MIDIObjectRef, _ key: CFString) -> Int32? {
        var v: Int32 = 0
        return MIDIObjectGetIntegerProperty(obj, key, &v) == noErr ? v : nil
    }

    static func info(_ ep: MIDIEndpointRef, source: Bool) -> MIDIEndpointInfo {
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        var deviceName: String?
        var portIndex: Int?
        if MIDIEndpointGetEntity(ep, &entity) == noErr, entity != 0,
           MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
            deviceName = string(device, kMIDIPropertyName)
            var index = 0
            outer: for e in 0..<MIDIDeviceGetNumberOfEntities(device) {
                let ent = MIDIDeviceGetEntity(device, e)
                let n = source ? MIDIEntityGetNumberOfSources(ent) : MIDIEntityGetNumberOfDestinations(ent)
                for i in 0..<n {
                    let other = source ? MIDIEntityGetSource(ent, i) : MIDIEntityGetDestination(ent, i)
                    if other == ep { portIndex = index; break outer }
                    index += 1
                }
            }
        }
        return MIDIEndpointInfo(
            id: integer(ep, kMIDIPropertyUniqueID) ?? 0,
            name: string(ep, kMIDIPropertyDisplayName) ?? string(ep, kMIDIPropertyName) ?? "Unnamed",
            deviceName: deviceName,
            portIndex: portIndex,
            isOffline: (integer(ep, kMIDIPropertyOffline) ?? 0) != 0)
    }

    static func endpoint(_ id: MIDIUniqueID) -> MIDIEndpointRef? {
        var obj = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(id, &obj, &type) == noErr, obj != 0 else { return nil }
        return MIDIEndpointRef(obj)
    }

    // MARK: Connections

    /// Listen to one source for the monitor (nil = none).
    @discardableResult
    public func setMonitorSource(_ id: MIDIUniqueID?) -> Bool {
        connect(port: monitorPort, current: &monitorSource, to: id)
    }

    /// Listen to one source for configuration replies (nil = none).
    @discardableResult
    public func setConfigSource(_ id: MIDIUniqueID?) -> Bool {
        connect(port: configPort, current: &configSource, to: id)
    }

    private func connect(port: MIDIPortRef, current: inout MIDIEndpointRef, to id: MIDIUniqueID?) -> Bool {
        if current != 0 {
            MIDIPortDisconnectSource(port, current)
            current = 0
        }
        guard let id, let ep = Self.endpoint(id) else { return id == nil }
        guard MIDIPortConnectSource(port, ep, nil) == noErr else { return false }
        current = ep
        return true
    }

    /// Send one complete SysEx message to exactly one destination.
    public func send(sysex: [UInt8], to id: MIDIUniqueID) -> Bool {
        guard sysex.first == 0xF0, sysex.last == 0xF7, sysex.count <= TrillProtocol.maxMessageLength,
              let dest = Self.endpoint(id) else { return false }
        let words = UMP.sysex7Words(sysex)
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        let ok: Bool = words.withUnsafeBufferPointer { wp in
            guard let base = wp.baseAddress else { return false }
            for i in stride(from: 0, to: words.count, by: 2) {
                let next: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListAdd(list, size, packet, 0, 2, base + i)
                guard let n = next else { return false }
                packet = n
            }
            return true
        }
        return ok && MIDISendEventList(outPort, dest, list) == noErr
    }

    // MARK: Receive (CoreMIDI's high-priority thread)

    /// Walk an event list without copying fixed-size packet structs (a
    /// packet holds only `wordCount` words, so reading the full struct
    /// could read past the list).
    static func forEachPacket(_ list: UnsafePointer<MIDIEventList>, _ body: (MIDITimeStamp, [UInt32]) -> Void) {
        let base = UnsafeRawPointer(list)
        guard let numOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.numPackets),
              let firstOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet),
              let tsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.timeStamp),
              let wcOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.wordCount),
              let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) else { return }
        let count = Int(base.loadUnaligned(fromByteOffset: numOffset, as: UInt32.self))
        var p = base + firstOffset
        for _ in 0..<min(count, 1024) {
            let ts = p.loadUnaligned(fromByteOffset: tsOffset, as: MIDITimeStamp.self)
            let n = min(Int(p.loadUnaligned(fromByteOffset: wcOffset, as: UInt32.self)), 64)
            let words = (0..<n).map { p.loadUnaligned(fromByteOffset: wordsOffset + 4 * $0, as: UInt32.self) }
            body(ts, words)
            p += wordsOffset + 4 * n
        }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, config: Bool) {
        Self.forEachPacket(list) { ts, words in
            let t = Self.seconds(ts)
            lock.lock()
            let messages = config ? configDecoder.decode(words) : monitorDecoder.decode(words)
            lock.unlock()
            if config {
                for case let .sysex(bytes, truncated) in messages where !truncated && TrillCodec.isTrillSysEx(bytes) {
                    DispatchQueue.main.async { [weak self] in self?.onConfigMessage?(bytes, t) }
                }
            } else if !messages.isEmpty {
                events.append(messages, hostTime: t)
            }
        }
    }
}
#endif
