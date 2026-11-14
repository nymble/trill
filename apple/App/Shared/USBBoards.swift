// SPDX-License-Identifier: GPL-3.0-only
//
// Spot an nRF52840 board on USB that is not running Trillium firmware: a
// new XIAO nRF52840 Sense (Seeed's demo firmware), one running other
// firmware (Zephyr, Adafruit), or one in its bootloader. Reads USB
// descriptors from the I/O Registry only; never opens the device. macOS
// only: iOS offers no way to list USB devices.

import Foundation
#if os(macOS)
import IOKit
#endif

struct USBBoardInfo: Hashable, Identifiable, Sendable {
    let vendorID: Int
    let productID: Int
    let name: String

    var id: String { String(format: "%04x:%04x %@", vendorID, productID, name) }

    /// Vendor IDs seen on XIAO nRF52840 boards with other firmware.
    static let vendors: [Int: String] = [
        0x2886: "Seeed Studio",
        0x2FE3: "Zephyr",
        0x239A: "Adafruit",
    ]

    /// Plain-language description, e.g. "XIAO nRF52840 Sense (Seeed Studio firmware)".
    var summary: String {
        let maker = Self.vendors[vendorID] ?? String(format: "vendor %04x", vendorID)
        return "\(name.isEmpty ? "USB device" : name) (\(maker) firmware)"
    }

    #if os(macOS)
    /// Current matching devices, sorted by name.
    static func scan() -> [USBBoardInfo] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(it) }
        var out: Set<USBBoardInfo> = []
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            func prop(_ k: String) -> Any? {
                IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let vid = prop("idVendor") as? Int, vendors[vid] != nil else { continue }
            let pid = prop("idProduct") as? Int ?? 0
            let name = (prop("USB Product Name") as? String) ?? (prop("kUSBProductString") as? String) ?? ""
            out.insert(USBBoardInfo(vendorID: vid, productID: pid, name: name))
        }
        return out.sorted { $0.name < $1.name }
    }
    #endif
}
