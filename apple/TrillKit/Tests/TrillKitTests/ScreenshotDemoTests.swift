// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import TrillKit

final class ScreenshotDemoTests: XCTestCase {
    func testSessionLooksLikeT1WithLinearSensor() {
        let session = ConfigSession { _ in false }
        session.applyScreenshotDemo(now: 10)
        XCTAssertTrue(session.isScreenshotDemo)
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.supportsTelemetry)
        XCTAssertTrue(session.hello?.hasBLEMIDI ?? false)
        XCTAssertEqual(session.hello?.firmwareString, "0.8.0")
        XCTAssertEqual(session.status?.battery, .present)
        XCTAssertEqual(session.status?.batteryPercent, 76)
        XCTAssertTrue(session.status?.charging ?? false)
        XCTAssertTrue(session.status?.discoverable ?? false)
        XCTAssertTrue(session.status?.bluetoothMIDI ?? false)
        XCTAssertEqual(session.status?.link, .advertising)

        let frame = TelemetryFrame.screenshotDemo(seq: 10, timeMs: 200)
        let summary = HardwareSummary(
            hello: session.hello,
            telemetry: frame,
            usb: HardwareSummary.USBInfo(vendorID: 0x1209, productID: 0x0003, name: "Trillium", ports: [
                .init(path: "/dev/cu.usbmodem101", interface: 1),
                .init(path: "/dev/cu.usbmodem105", interface: 5),
            ]),
            status: session.status
        )
        XCTAssertEqual(summary.model, .t1)
        XCTAssertEqual(summary.modelTitle, "T1 + linear sensor")
        XCTAssertTrue(summary.hasLinearSensor)
        XCTAssertTrue(summary.hasBLE)
        XCTAssertEqual(summary.batteryFitted, true)
        XCTAssertTrue(summary.rows.contains { $0.label == "USB ID" && $0.value.contains("1209:0003") && $0.value.contains("Trillium") })
        XCTAssertFalse(summary.rows.contains { $0.value.localizedCaseInsensitiveContains("Trill XIAO") })
        XCTAssertTrue(frame.displayTouches.count >= 1)
        XCTAssertTrue(frame.imuValid)

        session.disconnect(now: 11)
        XCTAssertTrue(session.isReady, "screenshot demo must ignore disconnect")
        session.connect(now: 12)
        XCTAssertTrue(session.isReady)
    }

    func testDemoFramesAreRepeatable() {
        let a = TelemetryFrame.screenshotDemo(seq: 42, timeMs: 840)
        let b = TelemetryFrame.screenshotDemo(seq: 42, timeMs: 840)
        XCTAssertEqual(a.accelMg, b.accelMg)
        XCTAssertEqual(a.pitchCdeg, b.pitchCdeg)
        XCTAssertEqual(a.touchPos, b.touchPos)
    }
}
