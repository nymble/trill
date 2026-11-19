// SPDX-License-Identifier: GPL-3.0-only
//
// Spot an nRF52840 board on USB that is not running Trillium firmware: a
// new XIAO nRF52840 Sense (Seeed's demo firmware), one running other
// firmware (Zephyr, Adafruit), or one in its bootloader. Reads USB
// descriptors from the I/O Registry only; never opens the device. macOS
// only: iOS offers no way to list USB devices.

import Foundation
import TrillKit
#if os(macOS)
import IOKit
import IOKit.serial
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

/// The Trillium board itself on USB (pid.codes test VID 1209, PID 0002 or
/// 0003): identity, serial ports and a signature that changes whenever a
/// board is unplugged, swapped or re-enumerated. Registry reads only.
enum TrilliumUSB {
    static let vendorID = 0x1209
    static let productIDs: Set<Int> = [0x0002, 0x0003]

    struct Scan: Equatable {
        var info: HardwareSummary.USBInfo?
        /// Sorted registry entry IDs of matching devices.
        var signature: [UInt64]
    }

    #if os(macOS)
    private static func prop(_ s: io_object_t, _ k: String) -> Any? {
        IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func scan() -> Scan {
        var out = Scan(info: nil, signature: [])
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else {
            return out
        }
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            guard prop(s, "idVendor") as? Int == vendorID, let pid = prop(s, "idProduct") as? Int, productIDs.contains(pid) else { continue }
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entry)
            out.signature.append(entry)
            if out.info == nil {
                let name = (prop(s, "USB Product Name") as? String) ?? (prop(s, "kUSBProductString") as? String) ?? ""
                out.info = HardwareSummary.USBInfo(vendorID: vendorID, productID: pid, name: name)
            }
        }
        IOObjectRelease(it)
        out.signature.sort()
        if out.info != nil { out.info?.ports = serialPorts() }
        return out
    }

    /// Callout devices of the board's CDC ACM functions with their data
    /// interface numbers.
    static func serialPorts() -> [HardwareSummary.Port] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(it) }
        var ports: [HardwareSummary.Port] = []
        while true {
            let service = IOIteratorNext(it)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let path = (prop(service, kIOCalloutDeviceKey) as? String) ?? (prop(service, "IOCalloutDevice") as? String) else { continue }
            var current = service
            var vid = 0, pid = 0, iface = -1
            // Walk up to the USB device, noting the first interface number seen.
            var parent: io_object_t = 0
            while IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
                if current != service { IOObjectRelease(current) }
                current = parent
                if iface < 0, let n = prop(current, "bInterfaceNumber") as? Int { iface = n }
                if let v = prop(current, "idVendor") as? Int { vid = v }
                if let p = prop(current, "idProduct") as? Int { pid = p }
                if vid != 0 && pid != 0 { break }
            }
            if current != service { IOObjectRelease(current) }
            guard vid == vendorID, productIDs.contains(pid), iface >= 0 else { continue }
            ports.append(HardwareSummary.Port(path: path, interface: iface))
        }
        return ports.sorted { $0.interface < $1.interface }
    }
    #else
    static func scan() -> Scan { Scan(info: nil, signature: []) }
    #endif
}
