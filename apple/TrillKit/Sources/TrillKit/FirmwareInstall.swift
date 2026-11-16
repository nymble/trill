// SPDX-License-Identifier: GPL-3.0-only
//
// Installing the firmware that ships inside the app. The app bundle carries
// one application-only UF2 built from the same commit as the app
// (Firmware/firmware.json + the image, added by `make apple-firmware`).
// Installing means: the board restarts into its UF2 bootloader (the
// `EnterBootloader` action on firmware 0.6+, or a double-press of RESET),
// the user lets the app use the drive that appears, the app backs up the
// current firmware, then copies the image. The same rules as
// tools/xiao_uf2.py apply: application window only, nRF52840 family,
// SoftDevice S140 7.3.0, never a bootloader image. SHA-256 is an integrity
// check only; images are not signed.

import Foundation

/// A firmware version, `major.minor.patch`.
public struct FirmwareVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "0.6.0" (exactly three numbers).
    public init?(_ text: String) {
        let parts = text.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2], a >= 0, b >= 0, c >= 0 else { return nil }
        self.init(a, b, c)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

extension TrillReply.Hello {
    public var firmwareVersion: FirmwareVersion { FirmwareVersion(firmware.0, firmware.1, firmware.2) }
    /// Firmware 0.6+: action 6 restarts into the UF2 bootloader, no RESET double-press needed.
    public var canEnterBootloader: Bool { capabilities & TrillProtocol.capBoard != 0 }
}

/// How the firmware on a connected Trillium relates to the firmware in the app.
public enum FirmwareStatus: Equatable, Sendable {
    case current
    case updateAvailable(installed: FirmwareVersion, bundled: FirmwareVersion)
    /// The board runs a newer firmware than this app carries: update the app.
    case newerThanApp(installed: FirmwareVersion, bundled: FirmwareVersion)
    /// This build of the app carries no firmware.
    case noBundledFirmware

    public static func compare(installed: FirmwareVersion, bundled: FirmwareVersion?) -> FirmwareStatus {
        guard let b = bundled else { return .noBundledFirmware }
        if installed == b { return .current }
        return installed < b ? .updateAvailable(installed: installed, bundled: b) : .newerThanApp(installed: installed, bundled: b)
    }
}

/// The firmware image carried in the app bundle.
public struct BundledFirmware: Equatable, Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public var version: String
        public var file: String
        public var sha256: String
        public var board: String
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case missing, manifest, version(String), checksum, image(String)
        public var errorDescription: String? {
            switch self {
            case .missing: return "This build of Trillium carries no firmware."
            case .manifest: return "The firmware manifest in the app is unreadable."
            case let .version(v): return "The firmware manifest has an invalid version (\(v))."
            case .checksum: return "The firmware in the app does not match its checksum."
            case let .image(why): return "The firmware in the app is not a safe image: \(why)"
            }
        }
    }

    public static let directory = "Firmware"
    public static let manifestName = "firmware.json"

    public let manifest: Manifest
    public let version: FirmwareVersion
    public let image: Data
    public let summary: UF2.Summary

    /// Validate a manifest and its image (same checks as `xiao_uf2.py inspect`).
    public init(manifest data: Data, image: Data) throws {
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else { throw Failure.manifest }
        guard let v = FirmwareVersion(m.version) else { throw Failure.version(m.version) }
        let s: UF2.Summary
        do { s = try UF2.validate(image) } catch { throw Failure.image(error.localizedDescription) }
        guard s.sha256 == m.sha256.lowercased() else { throw Failure.checksum }
        manifest = m
        version = v
        self.image = image
        summary = s
    }

    /// The firmware in `bundle` (`Firmware/firmware.json` and its image).
    public static func load(from bundle: Bundle = .main) throws -> BundledFirmware {
        guard let dir = bundle.resourceURL?.appendingPathComponent(directory),
              let m = FileManager.default.contents(atPath: dir.appendingPathComponent(manifestName).path)
        else { throw Failure.missing }
        guard let name = (try? JSONDecoder().decode(Manifest.self, from: m))?.file,
              !name.contains("/"), !name.hasPrefix(".")
        else { throw Failure.manifest }
        guard let img = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else { throw Failure.missing }
        return try BundledFirmware(manifest: m, image: img)
    }
}

extension UF2 {
    /// Bytes per block payload in images this project builds.
    public static let pageSize = 256

    /// Rebuild an application-only image from a bootloader read-back
    /// (CURRENT.UF2 also holds the MBR and SoftDevice). Same result as
    /// `xiao_uf2.py backup`'s *-app-only.uf2; erased (all 0xFF) pages are dropped.
    public static func applicationOnly(fromBackup data: Data) throws -> Data {
        let d = [UInt8](data)
        guard !d.isEmpty, d.count % 512 == 0, d.count <= maxFileSize else { throw Failure.size }
        var pages: [UInt32: [UInt8]] = [:]
        for o in stride(from: 0, to: d.count, by: 512) {
            guard u32(d, o) == magic0, u32(d, o + 4) == magic1, u32(d, o + 508) == magicEnd else { throw Failure.magic(offset: o) }
            let flags = u32(d, o + 8), addr = u32(d, o + 12), size = Int(u32(d, o + 16)), family = u32(d, o + 28)
            guard size <= 476 else { throw Failure.payload(block: o / 512) }
            if flags & flagNotMainFlash != 0 { continue }
            if flags & flagFamily != 0, family == familyBootloader { continue }
            for i in 0..<size {
                let a = addr &+ UInt32(i)
                guard a >= appStart, a < appEnd else { continue }
                let base = a - a % UInt32(pageSize)
                pages[base, default: [UInt8](repeating: 0xFF, count: pageSize)][Int(a - base)] = d[o + 32 + i]
            }
        }
        pages = pages.filter { $0.value.contains { $0 != 0xFF } }
        guard !pages.isEmpty else { throw Failure.noMainFlash }
        return build(pages: pages)
    }

    /// UF2 image (nRF52840 family) from 256-byte pages.
    static func build(pages: [UInt32: [UInt8]]) -> Data {
        var out = Data()
        let addrs = pages.keys.sorted()
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        for (n, addr) in addrs.enumerated() {
            put(magic0); put(magic1); put(flagFamily); put(addr); put(UInt32(pageSize))
            put(UInt32(n)); put(UInt32(addrs.count)); put(familyNRF52840)
            out.append(contentsOf: pages[addr]!)
            out.append(contentsOf: [UInt8](repeating: 0, count: 476 - pageSize))
            put(magicEnd)
        }
        return out
    }
}

/// Backing up and writing firmware on a mounted UF2 bootloader drive.
public enum UF2Installer {
    public enum Failure: Error, Equatable, LocalizedError {
        case drive([String]), image(String), noCurrent, write(String)
        public var errorDescription: String? {
            switch self {
            case let .drive(p): return "This drive can't take Trillium firmware: " + p.joined(separator: " ")
            case let .image(why): return "The firmware image is not safe to install: \(why)"
            case .noCurrent: return "The drive has no CURRENT.UF2, so the current firmware can't be backed up."
            case let .write(why): return "Writing the firmware failed: \(why)"
            }
        }
    }

    /// What a backup saved.
    public struct Backup: Equatable, Sendable {
        public let directory: URL
        /// The full read-back (MBR + SoftDevice + application).
        public let current: URL
        /// Application-only image that restores the previous firmware (nil if the board was empty).
        public let applicationOnly: URL?
    }

    /// File name the image is copied to (any name works; the bootloader reads the blocks).
    public static let targetName = "TRILLIUM.UF2"

    /// Check that `drive` is a UF2 bootloader drive this firmware can go on.
    public static func check(drive: URL) throws -> BootloaderInfo {
        let info: BootloaderInfo
        do { info = try BootloaderVolume.inspect(drive) } catch { throw Failure.drive([error.localizedDescription]) }
        guard info.problems.isEmpty else { throw Failure.drive(info.problems) }
        return info
    }

    /// Copy CURRENT.UF2, INFO_UF2.TXT and an application-only restore image
    /// into a new folder under `root`. Never overwrites an existing backup.
    public static func backup(drive: URL, into root: URL, date: Date = Date()) throws -> Backup {
        let info = try check(drive: drive)
        let fm = FileManager.default
        guard let current = fm.contents(atPath: drive.appendingPathComponent("CURRENT.UF2").path) else { throw Failure.noCurrent }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let board = (info.boardID ?? "board").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        var dir = root.appendingPathComponent("\(f.string(from: date))-\(board)")
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(f.string(from: date))-\(board)-\(n)")
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cur = dir.appendingPathComponent("CURRENT.UF2")
        try current.write(to: cur, options: .withoutOverwriting)
        if let infoData = fm.contents(atPath: drive.appendingPathComponent("INFO_UF2.TXT").path) {
            try infoData.write(to: dir.appendingPathComponent("INFO_UF2.TXT"), options: .withoutOverwriting)
        }
        var appOnly: URL?
        if let restore = try? UF2.applicationOnly(fromBackup: current) {
            let u = dir.appendingPathComponent("app-only.uf2")
            try restore.write(to: u, options: .withoutOverwriting)
            appOnly = u
        }
        return Backup(directory: dir, current: cur, applicationOnly: appOnly)
    }

    /// Outcome of a write. The bootloader restarts the board as soon as the
    /// last block arrives, so the drive often disappears before the file is
    /// closed; that is reported, not treated as a failure. The real check is
    /// the version the board reports after it restarts.
    public enum Outcome: Equatable, Sendable {
        case written
        case driveWentAway(String)
    }

    /// Validate `image` and `drive`, then copy the image onto the drive.
    public static func write(_ image: Data, to drive: URL) throws -> Outcome {
        do { _ = try UF2.validate(image) } catch { throw Failure.image(error.localizedDescription) }
        _ = try check(drive: drive)
        let dest = drive.appendingPathComponent(targetName)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw Failure.write("could not create \(targetName) on the drive")
        }
        var started = false
        do {
            let h = try FileHandle(forWritingTo: dest)
            started = true
            try h.write(contentsOf: image)
            try h.synchronize()
            try h.close()
            return .written
        } catch {
            if started { return .driveWentAway(error.localizedDescription) }
            throw Failure.write(error.localizedDescription)
        }
    }
}
