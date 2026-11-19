// SPDX-License-Identifier: GPL-3.0-only
//
// What the app has detected about the connected board: model in the
// T0/T1/T2/F1 lineup plus a capability list, firmware, USB identity and
// ports, and which sensors are present. Built only from the HELLO reply,
// the latest (fresh) telemetry frame and, on macOS, the I/O Registry.
// The Sensors layout and the Settings summary both follow this value.

import Foundation

public struct HardwareSummary: Equatable, Sendable {
    /// Lineup: T0 = XIAO nRF52840 Sense on USB-MIDI; T1 = T0 + battery and
    /// BLE; T2 = T1 + LED and buttons; F1 = T2 + linear sensor.
    public enum Model: String, Sendable {
        case t0 = "T0", t1 = "T1", t2 = "T2", f1 = "F1"
        public var title: String {
            switch self {
            case .t0: return "T0 Trillium Zero"
            case .t1: return "T1"
            case .t2: return "T2"
            case .f1: return "F1"
            }
        }
    }

    public enum Presence: Equatable, Sendable {
        /// Not connected, or no fresh telemetry yet.
        case unknown
        case starting
        case present
        /// Fitted but not answering (the firmware keeps retrying).
        case faulty
        case absent
    }

    /// One USB serial port of the board.
    public struct Port: Equatable, Sendable {
        public enum Role: String, Sendable { case diagnostics, microphonePCM, other }
        public var path: String
        public var interface: Int
        public var role: Role { Self.role(interface: interface) }
        public init(path: String, interface: Int) {
            self.path = path
            self.interface = interface
        }
        /// Data interfaces of the CDC ACM functions (layout in `trill-usb`):
        /// 1 = diagnostics, 5 = PCM (microphone test).
        public static func role(interface: Int) -> Role {
            switch interface {
            case 1: return .diagnostics
            case 5: return .microphonePCM
            default: return .other
            }
        }
    }

    public struct USBInfo: Equatable, Sendable {
        public var vendorID: Int
        public var productID: Int
        public var name: String
        public var ports: [Port]
        public init(vendorID: Int, productID: Int, name: String, ports: [Port] = []) {
            self.vendorID = vendorID
            self.productID = productID
            self.name = name
            self.ports = ports
        }
        public var idString: String { String(format: "%04x:%04x", vendorID, productID) }
        public var pcmPort: Port? { ports.first { $0.role == .microphonePCM } }
    }

    /// Features the firmware does not report yet. `nil` = not reported.
    public struct Extras: Equatable, Sendable {
        public var battery: Bool?
        public var ble: Bool?
        public var ledAndButtons: Bool?
        public init(battery: Bool? = nil, ble: Bool? = nil, ledAndButtons: Bool? = nil) {
            self.battery = battery
            self.ble = ble
            self.ledAndButtons = ledAndButtons
        }
    }

    public static let linearSensorChannels = 30
    public static let maxTouches = 5

    public var connected: Bool
    public var firmware: String?
    public var protocolVersion: Int?
    public var bootID: Int?
    public var debugSynthBuild: Bool
    public var motionSensor: Presence
    public var motionCalibrated: Bool?
    public var linearSensor: Presence
    public var multiTouch: Bool
    /// The firmware reports BLE-MIDI running (HELLO variant bit 4).
    public var bleMIDI: Bool
    public var microphone: Bool
    public var microphoneOn: Bool
    public var usb: USBInfo?
    public var transport: String
    public var extras: Extras

    /// `telemetry` should be the latest frame only while it is fresh.
    public init(hello: TrillReply.Hello?, telemetry: TelemetryFrame?, usb: USBInfo? = nil,
                transport: String = "USB", microphoneOn: Bool = false, extras: Extras = Extras()) {
        connected = hello != nil
        firmware = hello?.firmwareString
        protocolVersion = hello?.protocolVersion
        bootID = hello?.bootID
        debugSynthBuild = hello?.isPCMSynthBuild ?? false
        multiTouch = hello?.supportsMultiTouch ?? false
        bleMIDI = hello?.hasBLEMIDI ?? false
        microphone = hello?.hasMicrophone ?? false
        self.microphoneOn = microphone && microphoneOn
        self.usb = usb
        self.transport = transport
        self.extras = extras
        if let h = hello, !h.hasMotionSensor {
            motionSensor = .absent
        } else if let f = telemetry {
            motionSensor = Self.presence(f.imuState)
        } else {
            motionSensor = hello == nil ? .unknown : .present
        }
        motionCalibrated = telemetry.map { $0.calibrated }
        // The firmware cannot tell a missing linear sensor from one that
        // stopped answering: both read as "retrying", so treat it as absent.
        linearSensor = hello == nil ? .unknown : telemetry.map { f in
            f.trillState == .retrying ? .absent : Self.presence(f.trillState)
        } ?? .unknown
    }

    static func presence(_ s: SensorState) -> Presence {
        switch s {
        case .running: return .present
        case .initializing: return .starting
        case .retrying: return .faulty
        case .absent, .off, .disabled: return .absent
        }
    }

    // MARK: Model and capabilities

    public var hasLinearSensor: Bool { linearSensor == .present || linearSensor == .starting }

    /// BLE confirmed: by the firmware (BLE-MIDI running) or another report.
    public var hasBLE: Bool { bleMIDI || extras.ble == true }

    /// Highest lineup tier whose features are all confirmed.
    public var model: Model {
        let t1 = extras.battery == true && hasBLE
        let t2 = t1 && extras.ledAndButtons == true
        if t2 && hasLinearSensor { return .f1 }
        if t2 { return .t2 }
        if t1 { return .t1 }
        return .t0
    }

    /// Detected features beyond the model, e.g. a T0 with a linear sensor.
    public var additions: [String] {
        hasLinearSensor && model != .f1 ? ["linear sensor"] : []
    }

    public var capabilities: [String] {
        guard connected else { return [] }
        var c = ["USB MIDI"]
        if motionSensor != .absent { c.append("motion sensor") }
        if hasLinearSensor { c.append(multiTouch ? "linear sensor (\(Self.maxTouches) touches)" : "linear sensor") }
        if microphone { c.append("microphone (test)") }
        if extras.battery == true { c.append("battery") }
        if bleMIDI { c.append("BLE MIDI") } else if extras.ble == true { c.append("BLE") }
        if extras.ledAndButtons == true { c.append("LED and buttons") }
        return c
    }

    /// e.g. "T0 Trillium Zero + linear sensor".
    public var modelTitle: String {
        ([model.title] + additions.map { "+ \($0)" }).joined(separator: " ")
    }

    // MARK: Sensors layout

    public enum SensorPanel: String, CaseIterable, Sendable {
        case motion, linearSensor, microphone
    }

    /// Panels the Sensors view shows. Before telemetry arrives a panel is
    /// shown unless HELLO already rules it out.
    public var sensorPanels: [SensorPanel] {
        var p: [SensorPanel] = []
        if motionSensor != .absent { p.append(.motion) }
        if linearSensor != .absent { p.append(.linearSensor) }
        if microphone { p.append(.microphone) }
        return p
    }

    /// Sensors that are not on this board, for a one-line note each.
    public var missingSensors: [String] {
        guard connected else { return [] }
        var m: [String] = []
        if motionSensor == .absent { m.append("Motion sensor: not fitted on this board.") }
        if linearSensor == .absent { m.append("Linear sensor: not attached.") }
        if !microphone { m.append("Microphone: this firmware does not offer the testing-only capture path.") }
        return m
    }

    // MARK: Settings rows

    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    public var rows: [Row] {
        guard connected else { return [Row(label: "Board", value: "not connected")] }
        var r: [Row] = []
        r.append(Row(label: "Model", value: modelTitle))
        r.append(Row(label: "Capabilities", value: capabilities.joined(separator: ", ")))
        var fw = "\(firmware ?? "?") · protocol v\(protocolVersion ?? 0)"
        fw += debugSynthBuild ? " · debug synth build" : " · standard build"
        if let b = bootID { fw += " · boot ID \(b)" }
        r.append(Row(label: "Firmware", value: fw))
        if let u = usb {
            r.append(Row(label: "USB ID", value: "\(u.idString)\(u.name.isEmpty ? "" : " · \(u.name)")"))
        }
        r.append(Row(label: "Motion sensor (IMU)", value: motionText))
        r.append(Row(label: "Linear sensor", value: linearText))
        r.append(Row(label: "Microphone", value: microphone ? (microphoneOn ? "test capture on" : "test capture available, off") : "not offered by this firmware"))
        r.append(Row(label: "Battery", value: extras.battery.map { $0 ? "fitted" : "none" } ?? "not reported by this firmware"))
        r.append(Row(label: "BLE", value: bleText))
        r.append(Row(label: "Transport", value: "\(transport) · MIDI port 1 instrument, port 2 configuration"
                     + (bleMIDI ? " · BLE MIDI instrument only" : "")))
        if let u = usb, !u.ports.isEmpty {
            let ports = u.ports.sorted { $0.interface < $1.interface }.map { p -> String in
                let name: String
                switch p.role {
                case .diagnostics: name = "diagnostics"
                case .microphonePCM: name = "PCM (microphone)"
                case .other: name = "interface \(p.interface)"
                }
                return "\(name) \(p.path)"
            }
            r.append(Row(label: "Serial ports", value: ports.joined(separator: " · ")))
        }
        return r
    }

    private var bleText: String {
        if bleMIDI { return "BLE MIDI on · advertises as \u{201C}Trillium\u{201D} plus a 4-character ID · pair in Bluetooth MIDI" }
        return extras.ble.map { $0 ? "available" : "none" } ?? "not in this firmware"
    }

    private var motionText: String {
        switch motionSensor {
        case .unknown: return "–"
        case .starting: return "starting"
        case .present: return motionCalibrated == false ? "running, calibrating" : "running"
        case .faulty: return "fitted, not responding"
        case .absent: return "not fitted"
        }
    }

    private var linearText: String {
        let touches = multiTouch ? "up to \(Self.maxTouches) touches" : "1 touch"
        switch linearSensor {
        case .unknown: return "– (shown once sensor data arrives)"
        case .starting: return "starting"
        case .present: return "attached · \(Self.linearSensorChannels) channels · \(touches)"
        case .faulty, .absent: return "not attached"
        }
    }
}

/// Notices a different board: a new USB enumeration (registry entry or
/// location changed) or a HELLO with a different boot ID. The first
/// observation is only recorded.
public struct DeviceChangeDetector: Sendable {
    private var usbSignature: [UInt64]?
    private var bootID: Int?

    public init() {}

    /// `signature`: sorted registry IDs of matching USB devices.
    public mutating func usbChanged(_ signature: [UInt64]) -> Bool {
        defer { usbSignature = signature }
        guard let old = usbSignature else { return false }
        return old != signature
    }

    public mutating func helloChanged(bootID new: Int) -> Bool {
        defer { bootID = new }
        guard let old = bootID else { return false }
        return old != new
    }

    public mutating func forgetBoot() { bootID = nil }
}
