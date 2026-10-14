import SwiftUI

/// One colour, as three sRGB components, plus the arithmetic a palette needs.
///
/// Deliberately **not** a `SwiftUI.Color`. `Color` is opaque: there is no
/// supported way to read the components back out on every platform this
/// package builds for, so a palette stated as `Color` cannot be contrast-tested
/// at all — and an untested palette is exactly how the app ended up with two
/// swipe tints whose doc comment claimed 4.5:1 while they measured 4.35:1.
/// Stating the numbers here and converting to `Color` at the edge is what lets
/// `PaletteContrastTests` run on the macOS test host with no simulator.
///
/// Components are sRGB in 0…1 — the same numbers `Color(red:green:blue:)`
/// takes — so a value moved from one to the other renders identically.
public struct Swatch: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red.clamped()
        self.green = green.clamped()
        self.blue = blue.clamped()
    }

    /// A six-digit hex colour as the server spells it, e.g. `#7d6b4f`.
    ///
    /// Failable rather than falling back to a default, because the server's
    /// own `Appearance/set` refuses a malformed colour for exactly that
    /// reason: substituting a colour nobody asked for is worse than declining
    /// to use it. Callers pick the fallback themselves, where they can say why.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("#") { text.removeFirst() }

        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }

        self.init(
            Double((value >> 16) & 0xff) / 255,
            Double((value >> 8) & 0xff) / 255,
            Double(value & 0xff) / 255
        )
    }

    public static let white = Swatch(1, 1, 1)
    public static let black = Swatch(0, 0, 0)

    /// The SwiftUI colour. sRGB is named explicitly: the default for
    /// `Color(red:green:blue:)` is sRGB, but relying on a default that a
    /// future release could reinterpret would silently shift every token.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance.
    ///
    /// The gamma expansion is the part people leave out, and leaving it out
    /// overstates the contrast of mid-tones by enough to pass a palette that
    /// fails on a phone in daylight.
    public var relativeLuminance: Double {
        func expand(_ component: Double) -> Double {
            component <= 0.040_45
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * expand(red) + 0.7152 * expand(green) + 0.0722 * expand(blue)
    }

    /// WCAG 2.1 contrast ratio, 1…21. Symmetric, so the argument order carries
    /// no meaning and a caller cannot get it backwards.
    public func contrastRatio(against other: Swatch) -> Double {
        let one = relativeLuminance
        let two = other.relativeLuminance

        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    // MARK: - Derivation

    /// A linear blend, `amount` of `other` over this.
    ///
    /// Blending in sRGB rather than a perceptual space on purpose: every
    /// palette below is derived from a surface and an ink that are already
    /// close together, where the two agree, and a perceptual blend would need
    /// a colour-space library this package does not have and does not want.
    public func mixed(with other: Swatch, amount: Double) -> Swatch {
        let t = amount.clamped()

        return Swatch(
            red + (other.red - red) * t,
            green + (other.green - green) * t,
            blue + (other.blue - blue) * t
        )
    }

    /// This colour walked toward `ink` until it clears `ratio` against
    /// `background`, or as far as `ink` if it never does.
    ///
    /// **This is what makes a server-driven palette safe.** The accent arrives
    /// as one hex value chosen against the web's surface; the same value on
    /// this app's near-black would be either invisible or the only thing
    /// glowing on screen. Rather than refuse it or ignore it, it is moved the
    /// smallest distance that makes it legible, which keeps the user's choice
    /// recognisable. Without this, a legal theme from the server renders as
    /// unreadable text and nothing in the app can say why.
    ///
    /// Steps of 2% because 50 iterations is cheap and the alternative — a
    /// closed-form solve — is only closed-form in a space this does not use.
    public func adjusted(
        toContrast ratio: Double, against background: Swatch, towards ink: Swatch
    ) -> Swatch {
        guard contrastRatio(against: background) < ratio else { return self }

        for step in 1...50 {
            let candidate = mixed(with: ink, amount: Double(step) * 0.02)

            if candidate.contrastRatio(against: background) >= ratio { return candidate }
        }

        return ink
    }

    /// The same walk, choosing the direction automatically: toward black on a
    /// light background and toward white on a dark one.
    ///
    /// The direction has to be decided from the background rather than from
    /// the colour itself — a mid grey on a mid grey has no contrast in either
    /// direction, and guessing from the colour picks the shorter walk, which
    /// is the one that ends up inverting a theme's intent.
    public func adjusted(toContrast ratio: Double, against background: Swatch) -> Swatch {
        let ink: Swatch = background.relativeLuminance > 0.5 ? .black : .white

        return adjusted(toContrast: ratio, against: background, towards: ink)
    }
}

extension Double {
    /// Kept private to the palette: a component outside 0…1 is a derivation
    /// bug, and letting it through produces a colour that renders differently
    /// on each platform's clamping rather than failing anywhere visible.
    fileprivate func clamped() -> Double { Swift.min(1, Swift.max(0, self)) }
}
