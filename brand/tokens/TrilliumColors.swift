import SwiftUI

/// Trillium brand colors (Stage). Generated from brand/tokens/tokens.json.
extension Color {
    enum Trillium {
        /// Primary ground. ~58% of any layout.
        static let black = Color(red: 0.047, green: 0.047, blue: 0.051)
        /// Panels, cards, icon ground. ~20%.
        static let graphite = Color(red: 0.137, green: 0.137, blue: 0.149)
        /// Secondary text on black (5.4:1).
        static let ash = Color(red: 0.541, green: 0.522, blue: 0.502)
        /// Resting UI icons and captions on black (8.8:1).
        static let ashLight = Color(red: 0.702, green: 0.678, blue: 0.643)
        /// Text on black (17.3:1); light ground. ~13%.
        static let warmWhite = Color(red: 0.957, green: 0.945, blue: 0.918)
        /// The brand orange: mark, active state, primary button. ~6%.
        static let signal = Color(red: 1.000, green: 0.353, blue: 0.122)
        /// Levels, meters, highlights only. ~3%.
        static let amber = Color(red: 1.000, green: 0.690, blue: 0.125)
        /// Mark color on light grounds (not for text).
        static let ember = Color(red: 0.910, green: 0.282, blue: 0.059)
        /// Orange text on light grounds (4.7:1 on warm white).
        static let rust = Color(red: 0.761, green: 0.239, blue: 0.055)
        /// Disabled UI on black (decorative, not for text).
        static let unavailable = Color(red: 0.333, green: 0.322, blue: 0.302)
        /// Connected / OK status dot.
        static let connected = Color(red: 0.435, green: 0.682, blue: 0.604)
        /// Alias of signal for live/record states.
        static let record = Color(red: 1.000, green: 0.353, blue: 0.122)
    }
}
