// SPDX-License-Identifier: GPL-3.0-only
//
// Runs on macOS/iOS only: exercises the real CoreMIDI send/receive path of
// MIDIClient against virtual endpoints created by the test itself, with
// FakeTrill answering on the "device" side. No hardware involved.

#if canImport(CoreMIDI)
import CoreMIDI
import XCTest
@testable import TrillKit

final class CoreMIDILoopbackTests: XCTestCase {
    var deviceClient = MIDIClientRef()
    var virtualDest = MIDIEndpointRef()
    var virtualSource = MIDIEndpointRef()
    let fake = FakeTrill()

    override func tearDown() {
        if virtualDest != 0 { MIDIEndpointDispose(virtualDest) }
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource) }
        if deviceClient != 0 { MIDIClientDispose(deviceClient) }
    }

    func uniqueID(_ ep: MIDIEndpointRef) -> MIDIUniqueID {
        var v: Int32 = 0
        MIDIObjectGetIntegerProperty(ep, kMIDIPropertyUniqueID, &v)
        return v
    }

    /// Emit `bytes` from the virtual source as UMP SysEx7.
    func emit(_ bytes: [UInt8]) {
        let words = UMP.sysex7Words(bytes)
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var pkt = MIDIEventListInit(list, ._1_0)
        words.withUnsafeBufferPointer { wp in
            for i in stride(from: 0, to: words.count, by: 2) {
                let next: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListAdd(list, size, pkt, 0, 2, wp.baseAddress! + i)
                pkt = next!
            }
        }
        MIDIReceivedEventList(virtualSource, list)
    }

    func testSessionOverCoreMIDIWithFakeDevice() throws {
        guard MIDIClientCreateWithBlock("TrillKitTests Device" as CFString, &deviceClient, nil) == noErr else {
            throw XCTSkip("CoreMIDI server unavailable on this host")
        }
        var received: [[UInt8]] = []
        var decoder = UMPDecoder(maxSysexBytes: 64)
        let lock = NSLock()
        let gotRequest = expectation(description: "device received HELLO")
        gotRequest.assertForOverFulfill = false
        var status = MIDIDestinationCreateWithProtocol(deviceClient, "Fake Trill In" as CFString, ._1_0, &virtualDest) { [weak self] list, _ in
            MIDIClient.forEachPacket(list) { _, words in
                lock.lock()
                let msgs = decoder.decode(words)
                lock.unlock()
                for case let .sysex(b, _) in msgs {
                    lock.lock(); received.append(b); lock.unlock()
                    gotRequest.fulfill()
                    if let r = self?.fake.reply(to: b) { DispatchQueue.main.async { self?.emit(r) } }
                }
            }
        }
        // iOS only allows virtual endpoints for apps with the audio
        // background mode; the test host may not have it.
        guard status == noErr else { throw XCTSkip("virtual destination not permitted here (OSStatus \(status))") }
        status = MIDISourceCreateWithProtocol(deviceClient, "Fake Trill Out" as CFString, ._1_0, &virtualSource)
        guard status == noErr else { throw XCTSkip("virtual source not permitted here (OSStatus \(status))") }

        let client = try MIDIClient(name: "TrillKitTests", events: EventBuffer())
        let destID = uniqueID(virtualDest)
        let srcID = uniqueID(virtualSource)
        // Endpoint enumeration sees the virtual endpoints (no device, so no port index).
        XCTAssertTrue(client.destinations().contains { $0.id == destID && $0.portIndex == nil })
        XCTAssertTrue(client.sources().contains { $0.id == srcID })
        XCTAssertTrue(client.setConfigSource(srcID))

        let session = ConfigSession { client.send(sysex: $0, to: destID) }
        let ready = expectation(description: "session ready")
        client.onConfigMessage = { bytes, _ in
            session.receive(bytes, now: ProcessInfo.processInfo.systemUptime)
            if session.isReady { ready.fulfill() }
        }
        session.connect(now: ProcessInfo.processInfo.systemUptime)
        wait(for: [gotRequest, ready], timeout: 5)
        XCTAssertEqual(session.acknowledged, .firmwareDefaults)
        lock.lock()
        XCTAssertEqual(received.first, TrillCodec.hello(1))
        lock.unlock()

        // Sending to a destination that does not exist fails cleanly.
        XCTAssertFalse(client.send(sysex: TrillCodec.hello(2), to: 0x7FFF_FFF0))
        // Over-long or non-SysEx payloads are refused before CoreMIDI.
        XCTAssertFalse(client.send(sysex: [0x90, 60, 100], to: destID))
        XCTAssertFalse(client.send(sysex: [0xF0] + [UInt8](repeating: 1, count: 70) + [0xF7], to: destID))
        XCTAssertTrue(client.setConfigSource(nil))
    }

    func testMonitorReceivesChannelVoiceFromVirtualSource() throws {
        guard MIDIClientCreateWithBlock("TrillKitTests Device" as CFString, &deviceClient, nil) == noErr else {
            throw XCTSkip("CoreMIDI server unavailable on this host")
        }
        let status = MIDISourceCreateWithProtocol(deviceClient, "Fake Trill Notes" as CFString, ._1_0, &virtualSource)
        guard status == noErr else { throw XCTSkip("virtual source not permitted here (OSStatus \(status))") }
        let buffer = EventBuffer(capacity: 64)
        let client = try MIDIClient(name: "TrillKitTests", events: buffer)
        XCTAssertTrue(client.setMonitorSource(uniqueID(virtualSource)))
        // Note on ch1 C4, pitch bend, pressure, in one packet.
        let words: [UInt32] = [0x2090_3C64, 0x20E0_0050, 0x20D0_2A00]
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        let pkt = MIDIEventListInit(list, ._1_0)
        _ = words.withUnsafeBufferPointer { MIDIEventListAdd(list, 512, pkt, 0, words.count, $0.baseAddress!) }
        let before = MIDIClient.now()
        MIDIReceivedEventList(virtualSource, list)
        var events: [MIDIEvent] = []
        let deadline = Date().addingTimeInterval(3)
        while events.count < 3, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            events += buffer.drain().events
        }
        XCTAssertEqual(events.map(\.message), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .pitchBend(channel: 0, value: 0x50 << 7),
            .channelPressure(channel: 0, value: 0x2A),
        ])
        // Timestamp 0 ("now") is converted to host time at receipt.
        XCTAssertGreaterThanOrEqual(events.first?.hostTime ?? 0, before)
    }
}
#endif
