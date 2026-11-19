// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import TrillKit

final class HardwareSummaryTests: XCTestCase {
    static let caps: UInt8 = TrillProtocol.capSetConfig | TrillProtocol.capActions | TrillProtocol.capTelemetry
        | TrillProtocol.capConfigPages | TrillProtocol.capStrikes | TrillProtocol.capBoard

    static func hello(variant: UInt8 = TrillProtocol.variantIMU | TrillProtocol.variantMic | TrillProtocol.variantMultiTouch,
                      bootID: Int = 7) -> TrillReply.Hello {
        TrillReply.Hello(protocolVersion: 1, firmware: (0, 7, 0), variant: variant, capabilities: caps,
                         maxMessageLength: 64, paramCount: 38, uptimeSeconds: 5, bootID: bootID)
    }

    static func frame(imu: SensorState = .running, linear: SensorState) -> TelemetryFrame {
        TelemetryFrame(seq: 1, timeMs: 0, flags: TelemetryFrame.flagIMUValid | TelemetryFrame.flagCalibrated,
                       imuStateCode: imu.rawValue, trillStateCode: linear.rawValue,
                       accelMg: [0, 0, 1000], gyroDdps: [0, 0, 0], pitchCdeg: 0, rollCdeg: 0, touchPos: 0, touchSize: 0,
                       imuSamples: 0, taps: 0, calibrations: 0, skipped: 0, trillFrames: 0)
    }

    static let usb = HardwareSummary.USBInfo(vendorID: 0x1209, productID: 0x0003, name: "Trill XIAO MIDI_PCM", ports: [
        .init(path: "/dev/cu.usbmodem21105", interface: 5),
        .init(path: "/dev/cu.usbmodem21101", interface: 1),
    ])

    func testSenseWithLinearSensor() {
        let h = HardwareSummary(hello: Self.hello(), telemetry: Self.frame(linear: .running), usb: Self.usb)
        XCTAssertEqual(h.model, .t0)
        XCTAssertEqual(h.modelTitle, "T0 Trillium Zero + linear sensor")
        XCTAssertEqual(h.capabilities, ["USB MIDI", "motion sensor", "linear sensor (5 touches)", "microphone (test)"])
        XCTAssertEqual(h.sensorPanels, [.motion, .linearSensor, .microphone])
        XCTAssertTrue(h.missingSensors.isEmpty)
        let rows = Dictionary(uniqueKeysWithValues: h.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["USB ID"], "1209:0003 · Trill XIAO MIDI_PCM")
        XCTAssertEqual(rows["Linear sensor"], "attached · 30 channels · up to 5 touches")
        XCTAssertEqual(rows["Motion sensor (IMU)"], "running")
        XCTAssertEqual(rows["Microphone"], "test capture available, off")
        XCTAssertEqual(rows["Battery"], "not reported by this firmware")
        XCTAssertEqual(rows["BLE"], "not in this firmware")
        XCTAssertEqual(rows["Serial ports"], "diagnostics /dev/cu.usbmodem21101 · PCM (microphone) /dev/cu.usbmodem21105")
        XCTAssertTrue(rows["Firmware"]!.hasPrefix("0.7.0 · protocol v1 · standard build"))
        XCTAssertEqual(Self.usb.pcmPort?.path, "/dev/cu.usbmodem21105")
    }

    /// The firmware reports a missing linear sensor as "retrying": the
    /// Sensors view must drop the chart, not keep tracking.
    func testNoLinearSensorHidesItsPanel() {
        let h = HardwareSummary(hello: Self.hello(), telemetry: Self.frame(linear: .retrying))
        XCTAssertEqual(h.linearSensor, .absent)
        XCTAssertEqual(h.modelTitle, "T0 Trillium Zero")
        XCTAssertEqual(h.sensorPanels, [.motion, .microphone])
        XCTAssertEqual(h.missingSensors, ["Linear sensor: not attached."])
        XCTAssertFalse(h.capabilities.contains { $0.hasPrefix("linear") })
    }

    func testBoardWithoutMotionSensorOrMicrophone() {
        let h = HardwareSummary(hello: Self.hello(variant: 0), telemetry: Self.frame(imu: .absent, linear: .running))
        XCTAssertEqual(h.motionSensor, .absent)
        XCTAssertEqual(h.sensorPanels, [.linearSensor])
        XCTAssertEqual(h.missingSensors.count, 2)
    }

    func testBeforeTelemetryPanelsStayAndPresenceIsUnknown() {
        let h = HardwareSummary(hello: Self.hello(), telemetry: nil)
        XCTAssertEqual(h.linearSensor, .unknown)
        XCTAssertEqual(h.sensorPanels, [.motion, .linearSensor, .microphone])
        XCTAssertEqual(HardwareSummary(hello: nil, telemetry: nil).rows.first?.value, "not connected")
    }

    func testLayoutFollowsHotSwap() {
        let withSensor = HardwareSummary(hello: Self.hello(), telemetry: Self.frame(linear: .running))
        let swapped = HardwareSummary(hello: Self.hello(bootID: 8), telemetry: Self.frame(linear: .retrying))
        XCTAssertTrue(withSensor.sensorPanels.contains(.linearSensor))
        XCTAssertFalse(swapped.sensorPanels.contains(.linearSensor))
        XCTAssertNotEqual(withSensor, swapped)
    }

    func testLineup() {
        func model(_ e: HardwareSummary.Extras, linear: SensorState = .retrying) -> HardwareSummary {
            HardwareSummary(hello: Self.hello(), telemetry: Self.frame(linear: linear), extras: e)
        }
        XCTAssertEqual(model(.init(battery: true, ble: true)).model, .t1)
        XCTAssertEqual(model(.init(battery: true, ble: true, ledAndButtons: true)).model, .t2)
        let f1 = model(.init(battery: true, ble: true, ledAndButtons: true), linear: .running)
        XCTAssertEqual(f1.model, .f1)
        XCTAssertEqual(f1.modelTitle, "F1")
        XCTAssertEqual(model(.init(battery: true)).model, .t0)
    }

    func testPortRoles() {
        XCTAssertEqual(HardwareSummary.Port.role(interface: 1), .diagnostics)
        XCTAssertEqual(HardwareSummary.Port.role(interface: 5), .microphonePCM)
        XCTAssertEqual(HardwareSummary.Port.role(interface: 3), .other)
    }

    func testDeviceChangeDetector() {
        var d = DeviceChangeDetector()
        XCTAssertFalse(d.usbChanged([10]), "first sighting is only recorded")
        XCTAssertFalse(d.usbChanged([10]))
        XCTAssertTrue(d.usbChanged([]), "unplugged")
        XCTAssertTrue(d.usbChanged([11]), "another board enumerated")
        XCTAssertFalse(d.helloChanged(bootID: 7))
        XCTAssertFalse(d.helloChanged(bootID: 7))
        XCTAssertTrue(d.helloChanged(bootID: 8), "different board or restart")
        d.forgetBoot()
        XCTAssertFalse(d.helloChanged(bootID: 9))
    }
}
