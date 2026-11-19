// SPDX-License-Identifier: GPL-3.0-only
//
// Stage theme helpers built on the brand tokens (brand/tokens/TrilliumColors.swift,
// see brand/BRAND.md). No colour values are defined here: every colour comes
// from Color.Trillium.
import SwiftUI

/// Icon states from brand/BRAND.md section 6.
enum TrilliumIconState {
    case rest, hover, active, unavailable

    var color: Color {
        switch self {
        case .rest: return Color.Trillium.ashLight
        case .hover: return Color.Trillium.warmWhite
        case .active: return Color.Trillium.signal
        case .unavailable: return Color.Trillium.unavailable
        }
    }
}

/// A brand in-app icon (brand/ui-icons, imported as a template image).
struct TrilliumIcon: View {
    let name: String
    var state: TrilliumIconState = .rest
    var size: CGFloat = 20

    var body: some View {
        Image("icon-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(state.color)
            .accessibilityHidden(true)
    }
}

/// The Rhodonea mark (brand/icons/svg/rhodonea-glyph.svg) in signal orange.
/// Never rotated or redrawn; one petal points up.
struct TrilliumMark: View {
    var size: CGFloat = 64

    var body: some View {
        Image("rhodonea-glyph")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.Trillium.signal)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Primary button: an orange pill with black text (never white on orange).
/// One per screen.
struct TrilliumPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.Trillium.black : Color.Trillium.ash)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(isEnabled ? Color.Trillium.signal : Color.Trillium.unavailable))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// Secondary button: a graphite pill with warm-white text.
struct TrilliumSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.Trillium.warmWhite : Color.Trillium.ash)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Color.Trillium.graphite))
            .overlay(Capsule().stroke(Color.Trillium.unavailable, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == TrilliumPrimaryButtonStyle {
    static var trilliumPrimary: TrilliumPrimaryButtonStyle { TrilliumPrimaryButtonStyle() }
}

extension ButtonStyle where Self == TrilliumSecondaryButtonStyle {
    static var trilliumSecondary: TrilliumSecondaryButtonStyle { TrilliumSecondaryButtonStyle() }
}

extension View {
    /// Dark-first Stage look for a whole window: black ground, warm-white
    /// text, signal orange for the active state (selected tab, switches on).
    func trilliumStage() -> some View {
        self
            .preferredColorScheme(.dark)
            .tint(Color.Trillium.signal)
            .foregroundStyle(Color.Trillium.warmWhite)
            .background(Color.Trillium.black.ignoresSafeArea())
    }

    /// Black ground behind a Form, List or ScrollView (instead of the system grey).
    func trilliumGround() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.Trillium.black.ignoresSafeArea())
    }
}
