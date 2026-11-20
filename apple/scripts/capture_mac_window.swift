// SPDX-License-Identifier: GPL-3.0-only
// Capture one on-screen window to a PNG at its full window bounds
// (including parts that sit off the display). Used by appstore_shots.py
// because `screencapture -l` only records the visible slice, and GitHub
// macos-15 runners have a 1024x684 point display.
//
// Usage: swift capture_mac_window.swift WINDOW_ID OUT.png [WIDTHxHEIGHT]
// If WIDTHxHEIGHT is given, the window is resized to that size in points
// before capture (allowed to extend past the display).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs(message + "\n", stderr)
    exit(code)
}

func parseSize(_ raw: String) -> NSSize? {
    let parts = raw.lowercased().split(separator: "x")
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else {
        return nil
    }
    return NSSize(width: w, height: h)
}

func windowByID(_ id: CGWindowID) -> NSWindow? {
    NSApp.windows.first { $0.windowNumber == Int(id) }
}

func ownerPID(for id: CGWindowID) -> pid_t? {
    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
    return info.first.flatMap { $0[kCGWindowOwnerPID as String] as? pid_t }
}

func resizeWindow(_ id: CGWindowID, size: NSSize) {
    // Prefer Scripting/CG, then AX, then a tiny Swift/AppKit hop in-process
    // is not possible (this tool is a separate process). Use Core Graphics
    // + AppleScript System Events / CGWindow, and finally a CGS-free AX path.
    let src = """
    tell application "System Events"
        set matches to every window of (every process whose unix id is \(ownerPID(for: id) ?? 0))
        repeat with w in matches
            try
                set size of w to {\(Int(size.width)), \(Int(size.height))}
                set position of w to {0, 0}
            end try
        end repeat
    end tell
    """
    let script = NSAppleScript(source: src)
    var err: NSDictionary?
    script?.executeAndReturnError(&err)
    if let err {
        fputs("resize warning: \(err)\n", stderr)
    }
}

guard CommandLine.arguments.count >= 3, let wid = UInt32(CommandLine.arguments[1]) else {
    fail("usage: capture_mac_window.swift WINDOW_ID OUT.png [WIDTHxHEIGHT]", code: 2)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
if CommandLine.arguments.count >= 4, let size = parseSize(CommandLine.arguments[3]) {
    resizeWindow(CGWindowID(wid), size: size)
    // Let the backing store catch up.
    Thread.sleep(forTimeInterval: 0.35)
}

guard let image = CGWindowListCreateImage(
    .null,
    [.optionIncludingWindow],
    CGWindowID(wid),
    [.boundsIgnoreFraming, .bestResolution]
) else {
    fail("could not capture window \(CommandLine.arguments[1])")
}

let width = image.width
let height = image.height
print("\(width)x\(height)")

guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("could not write \(outURL.path)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    fail("could not finalize \(outURL.path)")
}
