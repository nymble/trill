// SPDX-License-Identifier: GPL-3.0-only
//
// Battery and Bluetooth status from `STATUS` (message 0x47, firmware with
// variant bit 5). Layout in crates/trill-config/src/status.rs.

import Foundation

public struct DeviceStatus: Equatable, Sendable {
    public enum Battery: UInt8, Sendable { case unknown = 0, absent, present }
    public enum Link: UInt8, Sendable { case off = 0, advertising, connected, streaming }
    /// Why Bluetooth is not advertising or connected.
    public enum BluetoothOff: UInt8, Sendable {
        case running = 0, notBuilt, noBattery, turnedOff, unavailable, checkingBattery
    }

    public static let format: UInt8 = 1
    public static let payloadLength = 7

    public var battery: Battery
    public var charging: Bool
    public var usbPower: Bool
    /// Battery voltage in mV, nil when not measured.
    public var batteryMillivolts: Int?
    /// Approximate charge (0...100), nil when unknown.
    public var batteryPercent: Int?
    public var discoverable: Bool
    public var bluetoothMIDI: Bool
    /// The Bluetooth settings are stored on the board.
    public var settingsStored: Bool
    public var link: Link
    public var offReason: BluetoothOff

    public init(battery: Battery = .unknown, charging: Bool = false, usbPower: Bool = false,
                batteryMillivolts: Int? = nil, batteryPercent: Int? = nil, discoverable: Bool = false,
                bluetoothMIDI: Bool = false, settingsStored: Bool = false, link: Link = .off,
                offReason: BluetoothOff = .notBuilt) {
        self.battery = battery
        self.charging = charging
        self.usbPower = usbPower
        self.batteryMillivolts = batteryMillivolts
        self.batteryPercent = batteryPercent
        self.discoverable = discoverable
        self.bluetoothMIDI = bluetoothMIDI
        self.settingsStored = settingsStored
        self.link = link
        self.offReason = offReason
    }

    /// Decode the 7-byte payload; nil for a wrong length, format or a byte with bit 7 set.
    public init?(payload p: [UInt8]) {
        guard p.count == Self.payloadLength, p[0] == Self.format, p.allSatisfy({ $0 < 0x80 }) else { return nil }
        battery = Battery(rawValue: p[1] & 0x03) ?? .unknown
        charging = p[1] & 0x04 != 0
        usbPower = p[1] & 0x08 != 0
        let mv = Int(p[2]) << 7 | Int(p[3])
        batteryMillivolts = mv == 0 ? nil : mv
        batteryPercent = p[4] <= 100 ? Int(p[4]) : nil
        discoverable = p[5] & 0x01 != 0
        bluetoothMIDI = p[5] & 0x02 != 0
        settingsStored = p[5] & 0x04 != 0
        link = Link(rawValue: p[6] & 0x07) ?? .off
        offReason = BluetoothOff(rawValue: (p[6] >> 3) & 0x07) ?? .unavailable
    }

    /// The 7-byte payload (inverse of `init(payload:)`; used by tests and tools).
    public var payload: [UInt8] {
        let mv = min(batteryMillivolts ?? 0, 0x3FFF)
        return [Self.format,
                battery.rawValue | (charging ? 0x04 : 0) | (usbPower ? 0x08 : 0),
                UInt8((mv >> 7) & 0x7F), UInt8(mv & 0x7F),
                UInt8(min(max(batteryPercent ?? 127, 0), 127)),
                (discoverable ? 0x01 : 0) | (bluetoothMIDI ? 0x02 : 0) | (settingsStored ? 0x04 : 0),
                link.rawValue | (offReason.rawValue << 3)]
    }

    /// Bluetooth can run on this board right now (a battery is detected).
    public var bluetoothPowered: Bool { battery == .present }

    /// e.g. "Present · 76 % · 3.99 V · charging".
    public var batteryText: String {
        switch battery {
        case .unknown:
            return usbPower ? "checking…" : "not measured"
        case .absent:
            return "none detected" + (usbPower ? " (USB power)" : "")
        case .present:
            var parts = ["present"]
            if let p = batteryPercent { parts.append("\(p) %") }
            if let mv = batteryMillivolts { parts.append(String(format: "%.2f V", Double(mv) / 1000)) }
            if charging { parts.append("charging") } else if usbPower { parts.append("on USB power") }
            return parts.joined(separator: " · ")
        }
    }

    /// "Discoverable: on/off".
    public var discoverableText: String { "Discoverable: \(discoverable ? "on" : "off")" }

    /// "Bluetooth MIDI: on/off/connected".
    public var bluetoothMIDIText: String {
        guard bluetoothMIDI else { return "Bluetooth MIDI: off" }
        switch link {
        case .streaming: return "Bluetooth MIDI: connected"
        case .connected: return "Bluetooth MIDI: on · host connected, MIDI not opened"
        case .advertising: return "Bluetooth MIDI: on · waiting for a host"
        case .off: return "Bluetooth MIDI: on"
        }
    }

    /// Why Bluetooth is off, in plain words; nil while it runs.
    public var offExplanation: String? {
        switch offReason {
        case .running: return nil
        case .notBuilt: return "This firmware has no Bluetooth. Install the Bluetooth firmware to use it."
        case .noBattery: return "Bluetooth needs a battery. Fit a battery to use Bluetooth; USB keeps working."
        case .turnedOff: return "Bluetooth is off: turn Discoverable on so a host can find Trillium."
        case .unavailable: return "Bluetooth is not available on this board right now. USB keeps working."
        case .checkingBattery: return "Checking for a battery… Bluetooth starts once one is detected."
        }
    }

    /// SF Symbol for a small battery indicator.
    public var batterySymbol: String {
        guard battery == .present else { return "battery.0" }
        if charging { return "battery.100.bolt" }
        switch batteryPercent ?? 0 {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}
