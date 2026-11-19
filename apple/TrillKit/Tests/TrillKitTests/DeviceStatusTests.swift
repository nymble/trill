// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

/// Battery and Bluetooth status (`GET_STATUS`, actions 10...13).
final class DeviceStatusTests: XCTestCase {
    func testStatusVectorsMatchRust() throws {
        let v = try VectorTests.loadVectors()
        XCTAssertEqual(TrillCodec.getStatus(40), v["get_status"]!.request)
        XCTAssertEqual(TrillCodec.action(42, .bluetoothDiscoverableOff), v["action_discoverable_off"]!.request)
        XCTAssertEqual(TrillCodec.action(43, .bluetoothDiscoverableOn), v["action_discoverable_on"]!.request)
        XCTAssertEqual(TrillCodec.action(44, .bluetoothMIDIOff), v["action_ble_midi_off"]!.request)
        XCTAssertEqual(TrillCodec.action(45, .bluetoothMIDIOn), v["action_ble_midi_on"]!.request)

        guard case let .hello(_, h)? = TrillCodec.decodeReply(v["hello"]!.reply!) else { return XCTFail("hello") }
        XCTAssertTrue(h.hasBLEMIDI)
        XCTAssertTrue(h.supportsStatus)

        guard case let .status(id, s)? = TrillCodec.decodeReply(v["get_status"]!.reply!) else { return XCTFail("status") }
        XCTAssertEqual(id, 40)
        XCTAssertEqual(s, DeviceStatus(battery: .present, charging: true, usbPower: true, batteryMillivolts: 3987,
                                       batteryPercent: 76, discoverable: true, bluetoothMIDI: true, settingsStored: true,
                                       link: .streaming, offReason: .running))
        XCTAssertEqual(s.payload, Array(v["get_status"]!.reply!.dropFirst(7).dropLast()))
        XCTAssertEqual(s.batteryText, "present · 76 % · 3.99 V · charging")
        XCTAssertEqual(s.bluetoothMIDIText, "Bluetooth MIDI: connected")
        XCTAssertNil(s.offExplanation)

        let expected: [(String, Bool, Bool)] = [
            ("action_discoverable_off", false, true), ("action_discoverable_on", true, true),
            ("action_ble_midi_off", true, false), ("action_ble_midi_on", true, true),
        ]
        for (name, discoverable, midi) in expected {
            guard case let .status(_, st)? = TrillCodec.decodeReply(v[name]!.reply!) else { return XCTFail(name) }
            XCTAssertEqual(st.discoverable, discoverable, name)
            XCTAssertEqual(st.bluetoothMIDI, midi, name)
        }
        guard case let .error(_, code, detail)? = TrillCodec.decodeReply(v["get_status_bad_length"]!.reply!) else { return XCTFail("bad") }
        XCTAssertEqual(code, TrillErrorCode.badLength.rawValue)
        XCTAssertEqual(detail, 1)
    }

    func testActionCodesAndVariantBits() {
        XCTAssertEqual(TrillAction.stopMic.rawValue, 8)
        XCTAssertNil(TrillAction(rawValue: 9), "code 9 stays unassigned")
        XCTAssertEqual(TrillAction.bluetoothDiscoverableOn.rawValue, 10)
        XCTAssertEqual(TrillAction.bluetoothDiscoverableOff.rawValue, 11)
        XCTAssertEqual(TrillAction.bluetoothMIDIOn.rawValue, 12)
        XCTAssertEqual(TrillAction.bluetoothMIDIOff.rawValue, 13)
        XCTAssertEqual(TrillProtocol.variantStatus, 0x20)
        XCTAssertTrue(TrillProtocol.variantStatus < 0x80, "7-bit MIDI data")
        XCTAssertEqual(TrillProtocol.MessageType.getStatus.rawValue, 0x07)
        XCTAssertEqual(TrillProtocol.MessageType.status.rawValue, 0x47)
    }

    func testMalformedStatusIsRejected() {
        let good = DeviceStatus(battery: .absent, usbPower: true, batteryMillivolts: 4310, offReason: .noBattery).payload
        XCTAssertNotNil(DeviceStatus(payload: good))
        XCTAssertNil(DeviceStatus(payload: Array(good.dropLast())))
        var bad = good; bad[0] = 2
        XCTAssertNil(DeviceStatus(payload: bad), "format")
        bad = good; bad[3] = 0x80
        XCTAssertNil(DeviceStatus(payload: bad), "bit 7")
        let s = DeviceStatus(payload: good)!
        XCTAssertEqual(s.offExplanation, "Bluetooth needs a battery. Fit a battery to use Bluetooth; USB keeps working.")
        XCTAssertEqual(s.batteryText, "none detected (USB power)")
        XCTAssertFalse(s.bluetoothPowered)
    }

    func testSessionPollsStatusAndTogglesBluetooth() {
        let device = FakeTrill()
        device.board = true
        device.strikes = true
        device.telemetry = true
        device.bluetooth = true
        var sent: [[UInt8]] = []
        var now: TimeInterval = 0
        let session = ConfigSession { sent.append($0); return true }
        func pump() {
            var n = 0
            while !sent.isEmpty, n < 30 {
                let m = sent.removeFirst()
                n += 1
                now += 0.003
                if let r = device.reply(to: m) { session.receive(r, now: now) }
            }
        }
        session.connect(now: now); pump()
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.supportsStatus)
        XCTAssertNil(session.status)
        session.maintainStatus(now: now); pump()
        XCTAssertEqual(session.status?.discoverable, true)
        XCTAssertEqual(session.status?.link, .advertising)
        // Not again until the interval has passed.
        session.maintainStatus(now: now + 0.5)
        XCTAssertTrue(sent.isEmpty)
        session.maintainStatus(now: now + session.statusInterval)
        XCTAssertEqual(sent.count, 1)
        pump()

        XCTAssertTrue(session.setDiscoverable(false, now: now)); pump()
        XCTAssertEqual(session.status?.discoverable, false, "the action reply already shows the new setting")
        XCTAssertTrue(session.setBluetoothMIDI(false, now: now)); pump()
        XCTAssertEqual(session.status?.bluetoothMIDI, false)
        XCTAssertEqual(device.actions, [.bluetoothDiscoverableOff, .bluetoothMIDIOff])
        XCTAssertTrue(session.setBluetoothMIDI(true, now: now)); pump()
        XCTAssertEqual(session.status?.bluetoothMIDI, true)
    }

    func testBluetoothTogglesNeedTheBluetoothFirmware() {
        let device = FakeTrill()
        device.board = true
        var sent: [[UInt8]] = []
        let session = ConfigSession { sent.append($0); return true }
        session.connect(now: 0)
        while !sent.isEmpty { if let r = device.reply(to: sent.removeFirst()) { session.receive(r, now: 0.01) } }
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.supportsStatus)
        XCTAssertFalse(session.setDiscoverable(true, now: 0.02))
        XCTAssertFalse(session.setBluetoothMIDI(true, now: 0.02))
        session.maintainStatus(now: 0.02)
        XCTAssertTrue(sent.isEmpty, "no status request to firmware without it")
    }

    func testHardwareSummaryShowsBatteryAndT1() {
        let hello = HardwareSummaryTests.hello(variant: TrillProtocol.variantIMU | TrillProtocol.variantBLEMIDI | TrillProtocol.variantStatus)
        var st = DeviceStatus(battery: .present, charging: false, usbPower: true, batteryMillivolts: 4120,
                              batteryPercent: 89, discoverable: true, bluetoothMIDI: true, settingsStored: true,
                              link: .streaming, offReason: .running)
        var h = HardwareSummary(hello: hello, telemetry: nil, status: st)
        XCTAssertEqual(h.model, .t1)
        XCTAssertTrue(h.capabilities.contains("battery"))
        var rows = Dictionary(uniqueKeysWithValues: h.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Battery"], "present · 89 % · 4.12 V · on USB power")
        XCTAssertEqual(rows["BLE"], "Discoverable: on · Bluetooth MIDI: connected")
        XCTAssertEqual(st.batterySymbol, "battery.100")

        st = DeviceStatus(battery: .absent, usbPower: true, batteryMillivolts: 4300, discoverable: true,
                          bluetoothMIDI: true, settingsStored: true, link: .off, offReason: .noBattery)
        h = HardwareSummary(hello: hello, telemetry: nil, status: st)
        XCTAssertEqual(h.model, .t0, "no battery: not a T1")
        rows = Dictionary(uniqueKeysWithValues: h.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Battery"], "none detected (USB power)")
        XCTAssertEqual(rows["BLE"], "Discoverable: on · Bluetooth MIDI: on · Bluetooth needs a battery")

        // Still checking: battery not confirmed either way.
        st.battery = .unknown
        st.offReason = .checkingBattery
        h = HardwareSummary(hello: hello, telemetry: nil, status: st)
        XCTAssertNil(h.batteryFitted)
        XCTAssertEqual(h.model, .t0)
    }
}
