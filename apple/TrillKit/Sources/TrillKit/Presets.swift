// SPDX-License-Identifier: GPL-3.0-only
//
// Host-side named presets. A preset is a complete parameter set stored as
// JSON on the Mac/iPhone; loading one only fills the editor, and the device
// keeps it only until it restarts (firmware settings are RAM only).

import Foundation

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public static let format = "trill-preset"
    public static let formatVersion = 1

    public var id: UUID
    public var name: String
    public var config: DeviceConfig

    public init(id: UUID = UUID(), name: String, config: DeviceConfig) {
        self.id = id
        self.name = name
        self.config = config
    }

    enum CodingKeys: String, CodingKey { case format, version, protocolVersion = "protocol_version", id, name, values }

    public enum PresetError: Error, Equatable, LocalizedError {
        case notAPreset, unsupportedVersion(Int), outOfRange(String, Int), unknownParameter(String)
        public var errorDescription: String? {
            switch self {
            case .notAPreset: return "Not a Trill preset file."
            case let .unsupportedVersion(v): return "Unsupported preset version \(v)."
            case let .outOfRange(k, v): return "Value \(v) for \(k) is out of range."
            case let .unknownParameter(k): return "Unknown parameter \(k)."
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? c.decode(String.self, forKey: .format)) == Self.format else { throw PresetError.notAPreset }
        let v = try c.decode(Int.self, forKey: .version)
        guard v == Self.formatVersion else { throw PresetError.unsupportedVersion(v) }
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let values = try c.decode([String: Int].self, forKey: .values)
        var cfg = DeviceConfig()
        for (k, value) in values {
            guard let p = TrillParam.from(key: k) else { throw PresetError.unknownParameter(k) }
            guard p.range.contains(value) else { throw PresetError.outOfRange(k, value) }
            cfg[p] = value
        }
        // Missing keys keep firmware defaults.
        config = cfg
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(Int(TrillProtocol.version), forKey: .protocolVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(Dictionary(uniqueKeysWithValues: TrillParam.allCases.map { ($0.key, config[$0]) }), forKey: .values)
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> Preset {
        try JSONDecoder().decode(Preset.self, from: data)
    }
}

/// Presets kept in one JSON file (in the app's own container).
public final class PresetStore {
    public let fileURL: URL
    public private(set) var presets: [Preset] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let d = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([Preset].self, from: d) {
            presets = list
        }
    }

    public func save(_ p: Preset) throws {
        if let i = presets.firstIndex(where: { $0.id == p.id }) { presets[i] = p } else { presets.append(p) }
        try persist()
    }

    public func delete(id: UUID) throws {
        presets.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(presets).write(to: fileURL, options: .atomic)
    }
}
