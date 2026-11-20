// SPDX-License-Identifier: GPL-3.0-only
//
// The app's own MIDI source for app-generated MIDI (instrument view). A
// separate CoreMIDI client so MIDIClient keeps its rule of never creating
// virtual endpoints. Music apps see it as "Trillium Instrument". The app
// never connects its own inputs to it (AppModel filters it out of the
// source lists), so it cannot form a loop.

#if canImport(CoreMIDI)
import CoreMIDI
import Foundation

public final class AppMIDISource: @unchecked Sendable {
    public static let defaultName = "Trillium Instrument"

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    public let name: String

    public init(name: String = AppMIDISource.defaultName) throws {
        self.name = name
        var status = MIDIClientCreateWithBlock("\(name) Client" as CFString, &client) { _ in }
        guard status == noErr else { throw MIDIClient.Failure(call: "MIDIClientCreateWithBlock", status: status) }
        status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard status == noErr else {
            MIDIClientDispose(client)
            throw MIDIClient.Failure(call: "MIDISourceCreateWithProtocol", status: status)
        }
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    }

    /// CoreMIDI unique ID of the source (to keep it out of the app's own inputs).
    public var uniqueID: MIDIUniqueID {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
        return id
    }

    /// Send one MIDI 1.0 channel voice message (2 or 3 bytes) now.
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] & 0x80 != 0, bytes[0] < 0xF0 else { return false }
        let word: UInt32 = 0x2000_0000 | UInt32(bytes[0]) << 16 | UInt32(bytes[1] & 0x7F) << 8
            | UInt32(bytes.count > 2 ? bytes[2] & 0x7F : 0)
        let size = 256
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        let packet = MIDIEventListInit(list, ._1_0)
        var w = word
        guard MIDIEventListAdd(list, size, packet, 0, 1, &w) != nil else { return false }
        return MIDIReceivedEventList(source, list) == noErr
    }
}
#endif
