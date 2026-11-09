// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import TrillKit

final class FileTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trillkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSHA256KnownAnswers() {
        XCTAssertEqual(SHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex([UInt8](repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // MARK: UF2

    static func block(addr: UInt32, no: Int, total: Int, family: UInt32 = UF2.familyNRF52840,
                      flags: UInt32 = UF2.flagFamily, size: UInt32 = 256, data: [UInt8] = []) -> [UInt8] {
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        var b = le(UF2.magic0) + le(UF2.magic1) + le(flags) + le(addr) + le(size) + le(UInt32(no)) + le(UInt32(total)) + le(family)
        var payload = data + [UInt8](repeating: 0xFF, count: max(0, 476 - data.count))
        payload = Array(payload.prefix(476))
        b += payload + le(UF2.magicEnd)
        return b
    }

    static func image(blocks n: Int = 3, start: UInt32 = UF2.appStart, family: UInt32 = UF2.familyNRF52840,
                      sp: UInt32 = 0x2004_0000, reset: UInt32 = 0x0002_7101) -> Data {
        func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        var d: [UInt8] = []
        for i in 0..<n {
            d += block(addr: start + UInt32(i) * 256, no: i, total: n, family: family, data: i == 0 ? le(sp) + le(reset) : [])
        }
        return Data(d)
    }

    func testValidImage() throws {
        let s = try UF2.validate(Self.image())
        XCTAssertEqual(s.blocks, 3)
        XCTAssertEqual(s.start, 0x27000)
        XCTAssertEqual(s.end, 0x27300)
        XCTAssertEqual(s.sha256.count, 64)
    }

    func testRealFirmwareArtifactIfBuilt() throws {
        // Cross-check with tools/xiao_uf2.py output when dist/ has a UF2.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dist = root.appendingPathComponent("dist")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dist.path))?.filter { $0.hasSuffix(".uf2") } ?? []
        guard let f = files.first else { throw XCTSkip("no dist/*.uf2 built") }
        let s = try UF2.validate(try Data(contentsOf: dist.appendingPathComponent(f)))
        XCTAssertEqual(s.start, UF2.appStart)
        XCTAssertLessThanOrEqual(s.end, UF2.appEnd)
    }

    func testRefusals() {
        XCTAssertThrowsError(try UF2.validate(Data())) { XCTAssertEqual($0 as? UF2.Failure, .size) }
        XCTAssertThrowsError(try UF2.validate(Data([0] + [UInt8](Self.image())))) { XCTAssertEqual($0 as? UF2.Failure, .size) }
        XCTAssertThrowsError(try UF2.validate(Self.image(family: UF2.familyBootloader))) { XCTAssertEqual($0 as? UF2.Failure, .bootloaderImage) }
        XCTAssertThrowsError(try UF2.validate(Self.image(family: 0x1234_5678))) {
            guard case .family? = $0 as? UF2.Failure else { return XCTFail("\($0)") }
        }
        // SoftDevice region (0x1000) and bootloader (0xF4000).
        for start: UInt32 in [0x1000, 0x26F00, 0xEBF00, 0xF4000] {
            XCTAssertThrowsError(try UF2.validate(Self.image(start: start)), String(format: "%X", start))
        }
        XCTAssertThrowsError(try UF2.validate(Self.image(sp: 0x1000))) {
            guard case .badVector? = $0 as? UF2.Failure else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try UF2.validate(Self.image(reset: 0x0002_7100))) // not Thumb
        // Bad magic, numbering, payload, untyped.
        var d = [UInt8](Self.image()); d[0] ^= 1
        XCTAssertThrowsError(try UF2.validate(Data(d))) { XCTAssertEqual($0 as? UF2.Failure, .magic(offset: 0)) }
        let dup = Self.block(addr: 0x27000, no: 0, total: 2) + Self.block(addr: 0x27100, no: 0, total: 2)
        XCTAssertThrowsError(try UF2.validate(Data(dup))) { XCTAssertEqual($0 as? UF2.Failure, .numbering) }
        XCTAssertThrowsError(try UF2.validate(Data(Self.block(addr: 0x27000, no: 0, total: 1, size: 477))))
        XCTAssertThrowsError(try UF2.validate(Data(Self.block(addr: 0x27000, no: 0, total: 1, flags: 0)))) {
            XCTAssertEqual($0 as? UF2.Failure, .untyped(block: 0))
        }
        // Address overflow.
        XCTAssertThrowsError(try UF2.validate(Data(Self.block(addr: 0xFFFF_FF00, no: 0, total: 1))))
        XCTAssertThrowsError(try UF2.validate(Data(count: UF2.maxFileSize + 512))) { XCTAssertEqual($0 as? UF2.Failure, .tooLarge) }
    }

    // MARK: Bootloader drive (temporary directories only)

    func testBootloaderVolumeInspection() throws {
        let vol = tmp.appendingPathComponent("FAKE-DRIVE")
        try FileManager.default.createDirectory(at: vol, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BootloaderVolume.inspect(vol)) { XCTAssertEqual($0 as? BootloaderVolume.Failure, .noInfo) }
        let text = "UF2 Bootloader 0.6.1 lib/nrfx (v2.0.0)\r\nModel: Seeed XIAO nRF52840\r\nBoard-ID: Seeed_XIAO_nRF52840_Sense\r\nSoftDevice: S140 version 7.3.0\r\nDate: Nov 12 2021\r\n"
        try text.write(to: vol.appendingPathComponent("INFO_UF2.TXT"), atomically: true, encoding: .utf8)
        let info = try BootloaderVolume.inspect(vol)
        XCTAssertEqual(info.boardID, "Seeed_XIAO_nRF52840_Sense")
        XCTAssertEqual(info.bootloader, "0.6.1 lib/nrfx (v2.0.0)")
        XCTAssertTrue(info.softDeviceOK)
        XCTAssertEqual(info.problems, [])
        XCTAssertFalse(BootloaderVolume.hasCurrentUF2(vol))

        let wrong = BootloaderInfo(text: "Model: Raspberry Pi RP2\nBoard-ID: RPI-RP2\n")
        XCTAssertEqual(wrong.problems.count, 2)
        XCTAssertFalse(BootloaderInfo(text: "Board-ID: nRF52840\nSoftDevice: S140 6.1.1\n").softDeviceOK)

        let file = tmp.appendingPathComponent("file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BootloaderVolume.inspect(file)) { XCTAssertEqual($0 as? BootloaderVolume.Failure, .notDirectory) }
        // The inspection wrote nothing to the "drive".
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vol.path), ["INFO_UF2.TXT"])
    }

    func testFlashCommandsAreQuotedAndDryRunFirst() {
        let c = FlashCommands(image: "/Users/me/My Firmware/xiao-sense-fw.uf2", drive: "/Volumes/XIAO-SENSE", boardID: "Seeed_XIAO_nRF52840_Sense")
        XCTAssertEqual(c.info, "python3 tools/xiao_uf2.py info /Volumes/XIAO-SENSE")
        XCTAssertEqual(c.backup, "python3 tools/xiao_uf2.py backup /Volumes/XIAO-SENSE -o backups/")
        XCTAssertEqual(c.dryRun, "python3 tools/xiao_uf2.py flash '/Users/me/My Firmware/xiao-sense-fw.uf2' --drive /Volumes/XIAO-SENSE --board-id Seeed_XIAO_nRF52840_Sense")
        XCTAssertFalse(c.dryRun.contains("--write"))
        XCTAssertTrue(c.write.hasSuffix(" --write"))
        XCTAssertEqual(FlashCommands.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(FlashCommands.quote("a;rm -rf"), "'a;rm -rf'")
    }

    // MARK: Presets

    func testPresetRoundTripAndValidation() throws {
        var cfg = DeviceConfig.firmwareDefaults
        cfg[.channel] = 3
        cfg[.rotationFullDps] = 720
        let p = Preset(name: "Lead", config: cfg)
        let data = try p.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\" : \"trill-preset\""))
        XCTAssertTrue(text.contains("\"rotation_full_dps\" : 720"))
        XCTAssertEqual(try Preset.decode(data), p)

        XCTAssertThrowsError(try Preset.decode(Data(#"{"format":"x","version":1,"name":"a","values":{}}"#.utf8))) {
            XCTAssertEqual($0 as? Preset.PresetError, .notAPreset)
        }
        XCTAssertThrowsError(try Preset.decode(Data(#"{"format":"trill-preset","version":2,"name":"a","values":{}}"#.utf8))) {
            XCTAssertEqual($0 as? Preset.PresetError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try Preset.decode(Data(#"{"format":"trill-preset","version":1,"name":"a","values":{"channel":16}}"#.utf8))) {
            XCTAssertEqual($0 as? Preset.PresetError, .outOfRange("channel", 16))
        }
        XCTAssertThrowsError(try Preset.decode(Data(#"{"format":"trill-preset","version":1,"name":"a","values":{"volume":1}}"#.utf8))) {
            XCTAssertEqual($0 as? Preset.PresetError, .unknownParameter("volume"))
        }
        let partial = try Preset.decode(Data(#"{"format":"trill-preset","version":1,"name":"a","values":{"base_note":60}}"#.utf8))
        XCTAssertEqual(partial.config[.baseNote], 60)
        XCTAssertEqual(partial.config[.bendRange], 24)
    }

    func testPresetStorePersists() throws {
        let url = tmp.appendingPathComponent("sub/presets.json")
        let s = PresetStore(fileURL: url)
        XCTAssertTrue(s.presets.isEmpty)
        let p = Preset(name: "A", config: .firmwareDefaults)
        try s.save(p)
        try s.save(Preset(id: p.id, name: "A2", config: .firmwareDefaults))
        XCTAssertEqual(PresetStore(fileURL: url).presets.map(\.name), ["A2"])
        try s.delete(id: p.id)
        XCTAssertTrue(PresetStore(fileURL: url).presets.isEmpty)
    }

    func testDeviceConfigClampsAndDiffs() {
        var c = DeviceConfig()
        c[.channel] = 99
        XCTAssertEqual(c[.channel], 15)
        c[.tiltFullDeg] = 0
        XCTAssertEqual(c[.tiltFullDeg], 5)
        XCTAssertEqual(c.changes(from: .firmwareDefaults).map(\.0), [.channel, .tiltFullDeg])
        for p in TrillParam.allCases {
            XCTAssertTrue(p.range.contains(p.defaultValue))
            XCTAssertEqual(TrillParam.from(key: p.key), p)
        }
    }
}
