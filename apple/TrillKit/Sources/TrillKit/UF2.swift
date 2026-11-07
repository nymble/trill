// SPDX-License-Identifier: GPL-3.0-only
//
// Read-only firmware checks for the guided update assistant, ported from
// tools/xiao_uf2.py (same constants and rules). Nothing here writes to a
// disk: the app shows the validated result and the exact
// tools/xiao_uf2.py commands for the user to run. SHA-256 is an integrity
// checksum only; images are not signed and nothing here authenticates them.

import Foundation

public enum UF2 {
    public static let magic0: UInt32 = 0x0A32_4655
    public static let magic1: UInt32 = 0x9E5D_5157
    public static let magicEnd: UInt32 = 0x0AB1_6F30
    public static let flagNotMainFlash: UInt32 = 0x0000_0001
    public static let flagFamily: UInt32 = 0x0000_2000
    public static let familyNRF52840: UInt32 = 0xADA5_2840
    public static let familyBootloader: UInt32 = 0xD663_823C
    /// After MBR + SoftDevice S140 v7.
    public static let appStart: UInt32 = 0x0002_7000
    /// Start of the storage partition; the bootloader is at 0xF4000.
    public static let appEnd: UInt32 = 0x000E_C000
    public static let ramStart: UInt32 = 0x2000_0000
    public static let ramEnd: UInt32 = 0x2004_0000
    public static let expectedSoftDevice = "S140 7.3.0"
    /// Refuse to read anything bigger than the whole 1 MB flash as UF2.
    public static let maxFileSize = 2 * 1024 * 1024

    public struct Summary: Equatable, Sendable {
        public let blocks: Int
        public let start: UInt32
        public let end: UInt32
        public let payloadBytes: Int
        public let sha256: String
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case size, magic(offset: Int), payload(block: Int), numbering, untyped(block: Int), bootloaderImage,
             family(block: Int, UInt32), outsideApp(UInt32, UInt32), noMainFlash, noVectorTable, badVector(String), tooLarge

        public var errorDescription: String? {
            switch self {
            case .size: return "File size is not a non-zero multiple of 512 bytes: not a UF2 image."
            case let .magic(o): return "Bad UF2 magic in the block at offset \(o)."
            case let .payload(b): return "Block \(b) has a payload larger than 476 bytes."
            case .numbering: return "Block numbers or block count are inconsistent."
            case let .untyped(b): return "Block \(b) has no family ID; untyped images are refused."
            case .bootloaderImage: return "This is a BOOTLOADER update image. It is always refused."
            case let .family(b, f): return String(format: "Block %d has family 0x%08X, not nRF52840 (0xADA52840).", b, f)
            case let .outsideApp(a, e):
                return String(format: "Data at 0x%08X..0x%08X is outside the application window 0x00027000..0x000EC000 (it would touch the SoftDevice, storage or bootloader).", a, e)
            case .noMainFlash: return "The image contains no flash data."
            case .noVectorTable: return "No vector table at 0x00027000: not linked for the Trill/Omi application address."
            case let .badVector(s): return s
            case .tooLarge: return "File is larger than any nRF52840 application image."
            }
        }
    }

    static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    /// Validate an application-only nRF52840 image (same rules as
    /// `tools/xiao_uf2.py inspect`).
    public static func validate(_ data: Data) throws -> Summary {
        guard data.count <= maxFileSize else { throw Failure.tooLarge }
        let d = [UInt8](data)
        guard !d.isEmpty, d.count % 512 == 0 else { throw Failure.size }
        let n = d.count / 512
        var numbers: [Int] = []
        var lo: UInt32?
        var hi: UInt32 = 0
        var payload = 0
        var vectors: (UInt32, UInt32)?
        for i in 0..<n {
            let o = i * 512
            guard u32(d, o) == magic0, u32(d, o + 4) == magic1, u32(d, o + 508) == magicEnd else { throw Failure.magic(offset: o) }
            let flags = u32(d, o + 8), addr = u32(d, o + 12), size = u32(d, o + 16)
            let no = u32(d, o + 20), total = u32(d, o + 24), family = u32(d, o + 28)
            guard size <= 476 else { throw Failure.payload(block: Int(no)) }
            guard total == UInt32(n) else { throw Failure.numbering }
            numbers.append(Int(no))
            payload += Int(size)
            if flags & flagNotMainFlash != 0 { continue }
            guard flags & flagFamily != 0 else { throw Failure.untyped(block: Int(no)) }
            if family == familyBootloader { throw Failure.bootloaderImage }
            guard family == familyNRF52840 else { throw Failure.family(block: Int(no), family) }
            let (end, overflow) = addr.addingReportingOverflow(size)
            guard !overflow, addr >= appStart, end <= appEnd else { throw Failure.outsideApp(addr, overflow ? .max : end) }
            lo = min(lo ?? addr, addr)
            hi = max(hi, end)
            if addr == appStart, size >= 8 { vectors = (u32(d, o + 32), u32(d, o + 36)) }
        }
        guard numbers.sorted() == Array(0..<n) else { throw Failure.numbering }
        guard let start = lo else { throw Failure.noMainFlash }
        guard let (sp, reset) = vectors else { throw Failure.noVectorTable }
        guard sp > ramStart, sp <= ramEnd else {
            throw Failure.badVector(String(format: "Initial stack pointer 0x%08X is not in RAM.", sp))
        }
        guard reset & 1 == 1, (reset & ~1) >= appStart, (reset & ~1) < appEnd else {
            throw Failure.badVector(String(format: "Reset vector 0x%08X is not a Thumb address in the application.", reset))
        }
        return Summary(blocks: n, start: start, end: hi, payloadBytes: payload, sha256: SHA256.hex(d))
    }
}

/// Parsed INFO_UF2.TXT of a mounted UF2 bootloader drive.
public struct BootloaderInfo: Equatable, Sendable {
    public var fields: [String: String]
    public var bootloader: String? { fields["Bootloader"] }
    public var boardID: String? { fields["Board-ID"] }
    public var model: String? { fields["Model"] }
    public var softDevice: String? { fields["SoftDevice"] }

    public init(text: String) {
        var f: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if let i = line.firstIndex(of: ":") {
                f[line[..<i].trimmingCharacters(in: .whitespaces)] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("UF2 Bootloader") {
                f["Bootloader"] = line.dropFirst("UF2 Bootloader".count).trimmingCharacters(in: .whitespaces)
            }
        }
        fields = f
    }

    public var isNRF52840: Bool { ((boardID ?? "") + " " + (model ?? "")).lowercased().contains("nrf52840") }

    /// Same rule as tools/xiao_uf2.py (tolerates "S140 version 7.3.0").
    public var softDeviceOK: Bool {
        (softDevice ?? "").replacingOccurrences(of: "version", with: "").split(separator: " ").map(String.init)
            == UF2.expectedSoftDevice.split(separator: " ").map(String.init)
    }

    /// Problems that make this drive unsuitable; empty = suitable.
    public var problems: [String] {
        var p: [String] = []
        if !isNRF52840 { p.append("Board-ID/Model do not identify an nRF52840 board.") }
        if !softDeviceOK { p.append("SoftDevice is \(softDevice ?? "missing"), expected \(UF2.expectedSoftDevice): the 0x27000 application address is only valid for S140 v7.") }
        if boardID == nil { p.append("INFO_UF2.TXT has no Board-ID.") }
        return p
    }
}

public enum BootloaderVolume {
    public enum Failure: Error, Equatable, LocalizedError {
        case notDirectory, noInfo
        public var errorDescription: String? {
            switch self {
            case .notDirectory: return "The selected item is not a folder or mounted drive."
            case .noInfo: return "No INFO_UF2.TXT: this is not a UF2 bootloader drive. Double-press RESET on the board and select the drive that appears."
            }
        }
    }

    /// Read (only) INFO_UF2.TXT from a user-selected drive.
    public static func inspect(_ url: URL) throws -> BootloaderInfo {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw Failure.notDirectory }
        let info = url.appendingPathComponent("INFO_UF2.TXT")
        guard let data = FileManager.default.contents(atPath: info.path), data.count < 64 * 1024 else { throw Failure.noInfo }
        return BootloaderInfo(text: String(decoding: data, as: UTF8.self))
    }

    /// True if the drive exposes a CURRENT.UF2 read-back (needed for backup).
    public static func hasCurrentUF2(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("CURRENT.UF2").path)
    }
}

/// The exact tools/xiao_uf2.py commands for a validated image and drive.
public struct FlashCommands: Equatable, Sendable {
    public let info: String
    public let backup: String
    public let inspect: String
    public let dryRun: String
    public let write: String

    public init(repo: String = ".", image: String, drive: String, boardID: String, backupDir: String = "backups/") {
        let tool = Self.quote(repo == "." ? "tools/xiao_uf2.py" : repo + "/tools/xiao_uf2.py")
        let d = Self.quote(drive), i = Self.quote(image), b = Self.quote(boardID)
        info = "python3 \(tool) info \(d)"
        backup = "python3 \(tool) backup \(d) -o \(Self.quote(backupDir))"
        inspect = "python3 \(tool) inspect \(i)"
        dryRun = "python3 \(tool) flash \(i) --drive \(d) --board-id \(b)"
        write = dryRun + " --write"
    }

    /// POSIX shell single-quoting.
    public static func quote(_ s: String) -> String {
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+:=@,".contains($0) }
        return safe && !s.isEmpty ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
