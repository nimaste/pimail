import Foundation

/// A calendar's own colour, and the **one** non-token colour in this app.
///
/// It arrives from the server as a literal `#rrggbb` the user picked in a
/// browser, so there is no design token that could stand in for it — and it is
/// deliberately not the Tailwind token a mailbox carries, which resolves per
/// theme. The two are different vocabularies and translating one into the other
/// invents a colour nobody chose.
///
/// Validation is strict on purpose. CSS shorthand (`#abc`), an alpha channel
/// (`#rrggbbaa`), a named colour and a missing `#` are all refused, and the
/// answer is **nil rather than an invented grey**: a calendar drawn in a colour
/// the user did not pick, beside one drawn in a colour they did, is worse than
/// one drawn with no colour at all. Colour is never the only carrier of meaning
/// here, so nil is always drawable.
public struct CalendarColour: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// The spelling the server sent, normalised to lower case, for round trips
    /// and for diagnostics.
    public let hex: String

    /// Exactly `#` and six hexadecimal digits. Anything else is nil.
    public init?(hex text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var characters = Array(trimmed)

        guard characters.first == "#" else { return nil }

        characters.removeFirst()

        guard characters.count == 6 else { return nil }
        guard characters.allSatisfy(\.isHexDigit) else { return nil }

        let digits = String(characters).lowercased()

        guard let value = Int(digits, radix: 16) else { return nil }

        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
        hex = "#" + digits
    }

    /// Relative luminance, WCAG 2.1 §1.4.3's own formula.
    ///
    /// What decides whether a label on this colour is drawn in black or white,
    /// the way `ActionTint` already walks a colour down until white text clears
    /// 4.5:1. A calendar colour was chosen against a white web background, so
    /// painting it raw behind text on a dark surface is how a chip becomes
    /// unreadable in exactly one appearance and nobody notices.
    public var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Whether black text clears 4.5:1 on this colour. False means white.
    public var prefersDarkLabel: Bool {
        let contrastWithBlack = (luminance + 0.05) / 0.05
        let contrastWithWhite = 1.05 / (luminance + 0.05)

        return contrastWithBlack >= contrastWithWhite
    }
}
