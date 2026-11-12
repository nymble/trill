// SPDX-License-Identifier: GPL-3.0-only
//
// CI helper: launch Trillium on an iPad Simulator, switch tabs with launch
// arguments, rotate, and write named PNGs into the test runner's Documents
// folder. Not a product behaviour test. The Simulator has no USB MIDI
// device, so Home shows the disconnected / plug-in prompt.

import XCTest

final class SimulatorScreenshots: XCTestCase {
    func testCaptureMainScreens() throws {
        let out = try Self.outputDirectory()
        let tabs = ["home", "presets", "sensors", "settings"]
        let device = XCUIDevice.shared

        for tab in tabs {
            let app = XCUIApplication()
            app.launchArguments = ["--skip-splash", "--tab=\(tab)", "-AppleInterfaceStyle", "Light"]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            // Allow the first frame (and any tab change) to settle.
            Thread.sleep(forTimeInterval: 1.0)

            device.orientation = .portrait
            Thread.sleep(forTimeInterval: 1.0)
            try Self.writeScreenshot(name: "\(tab)-portrait", to: out)

            device.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1.0)
            try Self.writeScreenshot(name: "\(tab)-landscape", to: out)

            device.orientation = .portrait
            app.terminate()
        }
    }

    private static func outputDirectory() throws -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ipad-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeScreenshot(name: String, to dir: URL) throws {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertGreaterThan(data.count, 100, "empty screenshot for \(name)")
        try data.write(to: dir.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
