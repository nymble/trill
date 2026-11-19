// SPDX-License-Identifier: GPL-3.0-only
//
// Handpan scales for the instrument view (docs/instrument-view.md). Each
// scale is stored exactly as published (ding, then tone fields from low to
// high) and can be moved to any ding note; spelling follows the scale's
// letters, so a transposed scale keeps one letter per step.

import Foundation

/// A spelled note: letter, accidental and octave (C4 = MIDI 60).
public struct SpelledNote: Equatable, Hashable, Sendable {
    /// 0 = C … 6 = B.
    public var letter: Int
    /// −2 … +2 semitones (♭♭ … ♯♯).
    public var accidental: Int
    public var octave: Int

    static let letters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]
    static let naturals = [0, 2, 4, 5, 7, 9, 11]

    public init(letter: Int, accidental: Int, octave: Int) {
        self.letter = letter; self.accidental = accidental; self.octave = octave
    }

    /// Parses "D3", "Bb3", "C#4", "F♯3", "E♭4".
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        guard let first = s.first, let l = Self.letters.firstIndex(of: Character(first.uppercased())) else { return nil }
        s = s.dropFirst()
        var acc = 0
        while let c = s.first, "b♭#♯".contains(c) {
            acc += (c == "#" || c == "♯") ? 1 : -1
            s = s.dropFirst()
        }
        guard let o = Int(s) else { return nil }
        self.init(letter: l, accidental: acc, octave: o)
    }

    public var midi: Int { (octave + 1) * 12 + Self.naturals[letter] + accidental }

    /// Diatonic steps from C0 (letter count), used to keep spelling when transposing.
    var steps: Int { octave * 7 + letter }

    /// Display name with ♭ / ♯, e.g. "B♭3".
    public var name: String { pitchName + "\(octave)" }

    /// Display name without the octave, e.g. "B♭".
    public var pitchName: String {
        let a = accidental > 0 ? String(repeating: "♯", count: accidental) : String(repeating: "♭", count: -accidental)
        return "\(Self.letters[letter])\(a)"
    }

    /// The note `d` letters and `semitones` above this one.
    public func transposed(steps d: Int, semitones: Int) -> SpelledNote {
        let total = steps + d
        let l = ((total % 7) + 7) % 7
        let o = Int((Double(total) / 7).rounded(.down))
        let natural = (o + 1) * 12 + Self.naturals[l]
        return SpelledNote(letter: l, accidental: midi + semitones - natural, octave: o)
    }

    /// Conventional spelling for a ding chosen by MIDI number (♭ for E♭, A♭, B♭; ♯ for C♯, F♯).
    public static func ding(midi: Int) -> SpelledNote {
        let table: [(Int, Int)] = [(0, 0), (0, 1), (1, 0), (2, -1), (2, 0), (3, 0), (3, 1), (4, 0), (5, -1), (5, 0), (6, -1), (6, 0)]
        let (l, a) = table[((midi % 12) + 12) % 12]
        return SpelledNote(letter: l, accidental: a, octave: midi / 12 - 1)
    }
}

/// One published handpan scale.
public struct HandpanScale: Identifiable, Hashable, Sendable {
    public let id: String
    /// Name without the root, e.g. "Kurd".
    public let name: String
    /// As published, e.g. "D3 | A3 Bb3 C4 D4 E4 F4 G4 A4".
    public let published: String
    /// Where the note list comes from.
    public let source: String
    public let ding: SpelledNote
    /// Tone fields from low to high, as published.
    public let toneFields: [SpelledNote]

    public init(id: String, name: String, published: String, source: String) {
        self.id = id; self.name = name; self.published = published; self.source = source
        let parts = published.split(separator: "|")
        precondition(parts.count == 2, "scale \(id): expected 'ding | tone fields'")
        ding = SpelledNote(String(parts[0]))!
        toneFields = parts[1].split(separator: " ").map { SpelledNote(String($0))! }
    }

    /// The tone fields moved so the ding is `dingMIDI` (same intervals and letters).
    public func toneFields(dingMIDI: Int) -> [SpelledNote] {
        let newDing = SpelledNote.ding(midi: dingMIDI)
        let dSteps = newDing.steps - ding.steps
        let dSemi = newDing.midi - ding.midi
        return toneFields.map { $0.transposed(steps: dSteps, semitones: dSemi) }
    }

    /// Display title at a ding, e.g. "D Kurd 9".
    public func title(dingMIDI: Int) -> String {
        "\(SpelledNote.ding(midi: dingMIDI).pitchName) \(name) \(toneFields.count + 1)"
    }

    static let handpanTuner = "handpantuner.app, \"The classic handpan scales\" (handpantuner.app/handpan-scales.html)"
    static let beatRise = "BeatRise handpan scales chart (beatrisemusic.com/pages/handpan-scales-chart)"
    static let opsilon = "Opsilon scales database (opsilon.de/en/pages/scales-database)"

    /// Built-in scales at the root they are most commonly sold in.
    public static let all: [HandpanScale] = [
        HandpanScale(id: "kurd", name: "Kurd", published: "D3 | A3 Bb3 C4 D4 E4 F4 G4 A4",
                     source: handpanTuner + "; " + beatRise),
        HandpanScale(id: "celtic-minor", name: "Celtic Minor", published: "D3 | A3 C4 D4 E4 F4 G4 A4 C5",
                     source: handpanTuner + "; " + beatRise + " (D Amara 9)"),
        HandpanScale(id: "integral", name: "Integral", published: "D3 | A3 Bb3 C4 D4 E4 F4 A4 C5",
                     source: handpanTuner),
        HandpanScale(id: "hijaz", name: "Hijaz", published: "A2 | E3 G3 A3 Bb3 C#4 D4 E4 G4",
                     source: handpanTuner + "; " + opsilon + " (A2 Hijaz 9)"),
        HandpanScale(id: "pygmy", name: "Pygmy", published: "F3 | G3 Ab3 C4 Eb4 F4 G4 Ab4 C5",
                     source: beatRise + " (F Pygmy 9)"),
        HandpanScale(id: "amara", name: "Amara", published: "E3 | B3 D4 E4 F#4 G4 A4 B4 D5",
                     source: opsilon + " (E Amara 9); " + beatRise + " (E Amara 9)"),
        HandpanScale(id: "equinox", name: "Equinox", published: "F3 | Ab3 C4 Db4 Eb4 F4 G4 Ab4 C5 Eb5",
                     source: handpanTuner + " (F Equinox 10, C#4 written as Db4)"),
        HandpanScale(id: "la-sirena", name: "La Sirena", published: "E3 | G3 B3 C#4 D4 E4 F#4 G4 B4 C#5",
                     source: opsilon + " (E La Sirena 10); " + beatRise + " (E La Sirena 10)"),
    ]

    public static func named(_ id: String) -> HandpanScale? { all.first { $0.id == id } }

    /// Ding notes offered in the picker: E2 … A3.
    public static let dingRange = 40...57
}

/// How the 8 tone fields of the first ring sit around the compass.
public enum HandpanLayout: String, CaseIterable, Codable, Sendable {
    /// Lowest at N, rising clockwise.
    case clockwise
    /// Like a handpan seen from above with the player at S: lowest at S,
    /// then alternating right and left up to N.
    case alternating

    public var title: String {
        switch self {
        case .clockwise: return "Clockwise from N"
        case .alternating: return "Alternating, low at S"
        }
    }

    /// Sector (0 = N, clockwise) for each of the first 8 tone fields.
    public var sectors: [Int] {
        switch self {
        case .clockwise: return [0, 1, 2, 3, 4, 5, 6, 7]
        case .alternating: return [4, 3, 5, 2, 6, 1, 7, 0]
        }
    }
}

/// Which notes a strike plays.
public enum HandpanRing: Int, Codable, Sendable {
    /// First 8 tone fields.
    case first = 0
    /// Tone fields 9 and up, then the scale continued upward.
    case second = 1
    /// The ding, whatever the direction.
    case ding = 2

    public var title: String {
        switch self {
        case .first: return "Ring 1"
        case .second: return "Ring 2"
        case .ding: return "Ding"
        }
    }
}

/// A scale at a chosen ding, laid out on 8 compass sectors.
public struct HandpanInstrument: Equatable, Sendable {
    public var scale: HandpanScale
    public var dingMIDI: Int
    public var layout: HandpanLayout

    public init(scale: HandpanScale, dingMIDI: Int? = nil, layout: HandpanLayout = .clockwise) {
        self.scale = scale
        self.dingMIDI = dingMIDI ?? scale.ding.midi
        self.layout = layout
    }

    public var ding: SpelledNote { SpelledNote.ding(midi: dingMIDI) }
    public var toneFields: [SpelledNote] { scale.toneFields(dingMIDI: dingMIDI) }

    /// The note a strike in `sector` (0 = N, clockwise) plays on `ring`.
    public func note(sector: Int, ring: HandpanRing) -> SpelledNote {
        let fields = toneFields
        let s = ((sector % 8) + 8) % 8
        let k = layout.sectors.firstIndex(of: s) ?? s
        switch ring {
        case .ding:
            return ding
        case .first:
            if k < fields.count { return fields[k] }
            // Fewer than 8 tone fields: repeat the lower ones an octave up.
            return fields[k % max(fields.count, 1)].transposed(steps: 7, semitones: 12)
        case .second:
            return upperRing[k]
        }
    }

    /// Ring 2, low to high: tone fields 9 and up, then the scale's own notes
    /// continued upward above the top tone field (same letters, octaves up).
    public var upperRing: [SpelledNote] {
        let fields = toneFields
        var out = Array(fields.dropFirst(8))
        guard out.count < 8 else { return Array(out.prefix(8)) }
        let top = fields.map(\.midi).max() ?? dingMIDI
        let pool = [ding] + fields
        var seen = Set(out.map(\.midi))
        var more: [SpelledNote] = []
        for octave in 1...3 {
            for n in pool {
                let t = n.transposed(steps: 7 * octave, semitones: 12 * octave)
                if t.midi > top, t.midi <= 127, !seen.contains(t.midi) { seen.insert(t.midi); more.append(t) }
            }
        }
        out += more.sorted { $0.midi < $1.midi }
        while out.count < 8 { out.append(out.last ?? ding) }
        return Array(out.prefix(8))
    }

    /// All 8 sectors on one ring.
    public func ring(_ ring: HandpanRing) -> [SpelledNote] { (0..<8).map { note(sector: $0, ring: ring) } }
}
