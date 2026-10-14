import JMAPKit
import SwiftUI

/// The colour a label is drawn in.
///
/// plMail stores a label's colour as one of nine Tailwind *tokens*, never a hex
/// value, precisely so each end can resolve it for its own appearance: `#3b82f6`
/// is a fixed light-mode blue and stays that exact blue on a black background,
/// where "blue" resolves to whatever blue means there. This is the iOS half of
/// that resolution.
///
/// **Nil is a third state.** A label with no colour chosen falls back to the
/// hashed ``AvatarPalette`` tint, which is what iOS did for every label before
/// colour was on the wire; a label deliberately coloured grey resolves to
/// ``LabelColor/gray`` and stays there. Collapsing the two would repaint every
/// label somebody chose grey on purpose, and would make "clear the colour" a
/// change with no visible effect.
enum LabelTint {
    /// The nine tokens, resolved for both appearances.
    ///
    /// Muted the same way ``AvatarPalette`` is, and for the same reason: a
    /// column of chips is meant to be scanned past, not read, and a dozen
    /// fully-saturated pills is the loudest thing on screen. Each light value
    /// carries white text at 4.5:1 or better so a filled chip is legible, and
    /// each dark value is lifted rather than darkened so it does not vanish
    /// into near-black.
    ///
    /// These sit beside the hashed palette rather than being drawn from it: the
    /// two vocabularies mean different things — one is a colour the user picked,
    /// the other is a stand-in for not having picked — and indexing one into the
    /// other would make "red" whatever the eleventh avatar colour happens to be.
    static func color(for color: LabelColor) -> Color {
        switch color {
        case .gray:
            Color(
                light: Color(red: 0.42, green: 0.44, blue: 0.47),
                dark: Color(red: 0.62, green: 0.64, blue: 0.67))
        case .red:
            Color(
                light: Color(red: 0.72, green: 0.31, blue: 0.29),
                dark: Color(red: 0.87, green: 0.48, blue: 0.45))
        case .orange:
            Color(
                light: Color(red: 0.70, green: 0.40, blue: 0.22),
                dark: Color(red: 0.88, green: 0.57, blue: 0.34))
        case .amber:
            Color(
                light: Color(red: 0.61, green: 0.46, blue: 0.16),
                dark: Color(red: 0.85, green: 0.68, blue: 0.30))
        case .green:
            Color(
                light: Color(red: 0.32, green: 0.51, blue: 0.33),
                dark: Color(red: 0.50, green: 0.72, blue: 0.51))
        case .teal:
            Color(
                light: Color(red: 0.20, green: 0.49, blue: 0.48),
                dark: Color(red: 0.38, green: 0.72, blue: 0.70))
        case .blue:
            Color(
                light: Color(red: 0.25, green: 0.44, blue: 0.68),
                dark: Color(red: 0.47, green: 0.65, blue: 0.88))
        case .violet:
            Color(
                light: Color(red: 0.45, green: 0.36, blue: 0.68),
                dark: Color(red: 0.66, green: 0.58, blue: 0.88))
        case .pink:
            Color(
                light: Color(red: 0.70, green: 0.34, blue: 0.51),
                dark: Color(red: 0.88, green: 0.53, blue: 0.69))
        }
    }

    /// The colour to draw a label in, falling back for one with none chosen.
    ///
    /// `seed` is what the fallback hashes — the user-scoped label id where there
    /// is one, so the same label is the same colour in every account it reaches,
    /// and the name only when there is not. A binding id would give one label
    /// three different fallback colours across three accounts, which is the
    /// unified sidebar disagreeing with itself.
    static func color(for color: LabelColor?, seed: String) -> Color {
        guard let color else { return AvatarPalette.color(for: seed) }

        return Self.color(for: color)
    }
}
