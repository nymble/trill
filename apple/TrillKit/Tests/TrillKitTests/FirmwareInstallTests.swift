// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

final class FirmwareInstallTests: XCTestCase {
    /// A small valid application image: vector table at 0x27000 plus one more page.
    static func appImage(extraPage: UInt32 = 0x0002_7100) -> Data {
        var vt = [UInt8](repeating: 0xFF, count: 256)
        let sp: UInt32 = 0x2004_0000, reset: UInt32 = 0x0002_7101
        for i in 0..<4 { vt[i] = UInt8(sp >> (8 * i) & 0xFF); vt[4 + i] = UInt8(reset >> (8 * i) & 0xFF) }
        return UF2.build(pages: [0x0002_7000: vt, extraPage: [UInt8](repeating: 0x42, count: 256)])
    }

    static func manifest(_ img: Data, version: String = "0.6.0", sha: String? = nil) -> Data {
        let s = sha ?? (try! UF2.validate(img)).sha256
        return Data(#"{"version":"\#(version)","file":"xiao-sense-fw.uf2","sha256":"\#(s)","board":"Seeed Studio XIAO nRF52840 Sense"}"#.utf8)
    }

    static let goodInfo = """
    UF2 Bootloader 0.9.0 lib/nrfx (v2.0.0)
    Model: Seeed XIAO nRF52840
    Board-ID: nRF52840-SeeedXiaoSense-v1
    SoftDevice: S140 7.3.0
    """

    func makeDrive(info: String = goodInfo, current: Data? = nil) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(info.utf8).write(to: d.appendingPathComponent("INFO_UF2.TXT"))
        if let c = current { try c.write(to: d.appendingPathComponent("CURRENT.UF2")) }
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testVersionsParseAndOrder() {
        XCTAssertEqual(FirmwareVersion("0.6.0"), FirmwareVersion(0, 6, 0))
        XCTAssertNil(FirmwareVersion("0.6"))
        XCTAssertNil(FirmwareVersion("0.6.x"))
        XCTAssertLessThan(FirmwareVersion(0, 5, 9), FirmwareVersion(0, 6, 0))
        XCTAssertLessThan(FirmwareVersion(0, 9, 0), FirmwareVersion(0, 10, 0))
        let b = FirmwareVersion(0, 6, 0)
        XCTAssertEqual(FirmwareStatus.compare(installed: b, bundled: b), .current)
        XCTAssertEqual(FirmwareStatus.compare(installed: FirmwareVersion(0, 5, 0), bundled: b),
                       .updateAvailable(installed: FirmwareVersion(0, 5, 0), bundled: b))
        XCTAssertEqual(FirmwareStatus.compare(installed: FirmwareVersion(0, 7, 0), bundled: b),
                       .newerThanApp(installed: FirmwareVersion(0, 7, 0), bundled: b))
        XCTAssertEqual(FirmwareStatus.compare(installed: b, bundled: nil), .noBundledFirmware)
    }

    func testBootloaderActionNeedsFirmware06() {
        func hello(_ caps: UInt8) -> TrillReply.Hello {
            TrillReply.Hello(protocolVersion: 1, firmware: (0, 6, 0), variant: 2, capabilities: caps,
                             maxMessageLength: 64, paramCount: 41, uptimeSeconds: 1, bootID: 1)
        }
        XCTAssertFalse(hello(0x3B).canEnterBootloader)
        XCTAssertTrue(hello(0x3B | TrillProtocol.capBoard).canEnterBootloader)
        XCTAssertEqual(TrillAction.enterBootloader.rawValue, 6)
        XCTAssertTrue(TrillAction.enterBootloader.needsBoard)
        XCTAssertEqual(TrillCodec.action(37, .enterBootloader), [0xF0, 0x7D, 0x54, 0x52, 0x01, 0x04, 0x25, 0x06, 0xF7])
    }

    func testBundledFirmwareIsValidatedAgainstItsManifest() throws {
        let img = Self.appImage()
        let fw = try BundledFirmware(manifest: Self.manifest(img), image: img)
        XCTAssertEqual(fw.version, FirmwareVersion(0, 6, 0))
        XCTAssertEqual(fw.summary.start, UF2.appStart)
        XCTAssertThrowsError(try BundledFirmware(manifest: Self.manifest(img, sha: String(repeating: "0", count: 64)), image: img)) {
            XCTAssertEqual($0 as? BundledFirmware.Failure, .checksum)
        }
        XCTAssertThrowsError(try BundledFirmware(manifest: Self.manifest(img, version: "six"), image: img))
        XCTAssertThrowsError(try BundledFirmware(manifest: Data("{}".utf8), image: img))
        // An image that would touch the SoftDevice is never accepted, whatever the manifest says.
        let bad = UF2.build(pages: [0x0002_6F00: [UInt8](repeating: 0, count: 256)])
        XCTAssertThrowsError(try BundledFirmware(manifest: Self.manifest(Self.appImage(), sha: SHA256.hex([UInt8](bad))), image: bad))
        XCTAssertThrowsError(try BundledFirmware.load(from: Bundle(for: Self.self))) {
            XCTAssertEqual($0 as? BundledFirmware.Failure, .missing)
        }
    }

    func testApplicationOnlyKeepsOnlyTheApplicationWindow() throws {
        // A read-back: MBR/SoftDevice page, two app pages, an erased app page.
        var pages = [UInt32: [UInt8]]()
        pages[0x0000_1000] = [UInt8](repeating: 0x11, count: 256)
        let app = [UInt8](Self.appImage())
        pages[0x0002_7000] = Array(app[32..<288])
        pages[0x0002_7100] = [UInt8](repeating: 0x42, count: 256)
        pages[0x0002_8000] = [UInt8](repeating: 0xFF, count: 256)
        pages[0x000F_4000] = [UInt8](repeating: 0x22, count: 256)
        let restored = try UF2.applicationOnly(fromBackup: UF2.build(pages: pages))
        let s = try UF2.validate(restored)
        XCTAssertEqual(s.blocks, 2)
        XCTAssertEqual(s.start, 0x0002_7000)
        XCTAssertEqual(s.end, 0x0002_7200)
        XCTAssertEqual(restored, Self.appImage())
        XCTAssertThrowsError(try UF2.applicationOnly(fromBackup: UF2.build(pages: [0x1000: [UInt8](repeating: 1, count: 256)])))
    }

    func testBackupThenWrite() throws {
        let old = Self.appImage(extraPage: 0x0003_0000)
        var readBack = [UInt32: [UInt8]]()
        readBack[0x0000_1000] = [UInt8](repeating: 0x11, count: 256)
        let oldBytes = [UInt8](old)
        for o in stride(from: 0, to: oldBytes.count, by: 512) {
            readBack[UF2.u32(oldBytes, o + 12)] = Array(oldBytes[(o + 32)..<(o + 288)])
        }
        let drive = try makeDrive(current: UF2.build(pages: readBack))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let b1 = try UF2Installer.backup(drive: drive, into: root, date: date)
        XCTAssertTrue(b1.directory.lastPathComponent.hasSuffix("-nRF52840-SeeedXiaoSense-v1"))
        XCTAssertEqual(try Data(contentsOf: b1.applicationOnly!), old, "restore image = the previous application")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b1.directory.appendingPathComponent("INFO_UF2.TXT").path))
        let b2 = try UF2Installer.backup(drive: drive, into: root, date: date)
        XCTAssertNotEqual(b1.directory, b2.directory, "a second backup never overwrites the first")

        let new = Self.appImage()
        XCTAssertEqual(try UF2Installer.write(new, to: drive), .written)
        XCTAssertEqual(try Data(contentsOf: drive.appendingPathComponent(UF2Installer.targetName)), new)
    }

    func testWriteRefusesUnsafeDrivesAndImages() throws {
        let img = Self.appImage()
        let oldSD = try makeDrive(info: Self.goodInfo.replacingOccurrences(of: "S140 7.3.0", with: "S140 6.1.1"))
        XCTAssertThrowsError(try UF2Installer.write(img, to: oldSD))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSD.appendingPathComponent(UF2Installer.targetName).path))
        let notNordic = try makeDrive(info: "UF2 Bootloader 3.0\nModel: Raspberry Pi RP2\nBoard-ID: RPI-RP2\n")
        XCTAssertThrowsError(try UF2Installer.write(img, to: notNordic))
        let good = try makeDrive()
        let bootloader = UF2.build(pages: [0x0002_7000: [UInt8](repeating: 0, count: 256)])
        XCTAssertThrowsError(try UF2Installer.write(bootloader, to: good), "no vector table: refused")
        XCTAssertThrowsError(try UF2Installer.backup(drive: good, into: FileManager.default.temporaryDirectory)) {
            XCTAssertEqual($0 as? UF2Installer.Failure, .noCurrent)
        }
    }
}
