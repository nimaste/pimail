import SwiftUI

/// The colour a correspondent is drawn in.
///
/// Derived from the address, never stored: the same person is the same colour
/// on every device and after every reinstall, with nothing to sync and nothing
/// to migrate. A hash rather than an allocation counter for the same reason —
/// an counter would renumber everyone the moment one contact disappeared.
///
/// The hues are fixed rather than generated because a generated hue lands in
/// the yellow-green band often enough to matter, and white-on-yellow fails
/// contrast. Each of these carries white text at 4.5:1 or better, and each is
/// mid-toned rather than pale or near-black, so one set works on both a white
/// and a black background — the avatar is a solid fill, so the surface behind
/// it never shows through.
///
/// They are also deliberately desaturated. A dozen fully-saturated circles
/// down the left of a list is the loudest thing on screen, and the avatar is
/// meant to be scanned past, not read: it answers "same person as three rows
/// up?" and nothing else. Muting them lets the sender and subject carry the
/// row, which is the order the eye should take it in.
enum AvatarPalette {
    /// Tuned by hand, not sampled from a wheel: evenly spaced hues would put
    /// two adjacent entries a few degrees apart in the blues, where the eye
    /// discriminates worst.
    ///
    /// Earthy rather than primary — terracotta, clay, mustard, sage, dusty
    /// blue, periwinkle, heather. Saturation is held low so nothing vibrates
    /// against the warm off-white in light mode, then each is walked down in
    /// lightness only as far as white text needs to clear 4.5:1, which is what
    /// keeps them muted without going pale.
    ///
    /// The order is unchanged and must stay unchanged: a sender's colour is
    /// their hash modulo this count, so reordering or resizing the array
    /// renumbers everybody.
    /// Stated as ``Swatch`` rather than `Color` so `PaletteContrastTests` can
    /// measure them. Every rendered value is byte-identical to what shipped,
    /// with one exception noted on its own line.
    static let swatches: [(name: String, swatch: Swatch)] = [
        ("terracotta", Swatch(0.67, 0.39, 0.33)),
        ("clay", Swatch(0.61, 0.42, 0.27)),
        ("mustard", Swatch(0.54, 0.45, 0.25)),
        ("sage", Swatch(0.40, 0.49, 0.34)),
        // Green nudged one hundredth darker: it measured 4.49:1 against white,
        // the only entry that missed the 4.5:1 this comment has always claimed
        // for all twelve. Its slot and its hue are unchanged, so nobody is
        // renumbered — which is the constraint, and it is not the same
        // constraint as never touching a value.
        ("eucalyptus", Swatch(0.32, 0.49, 0.46)),
        ("dusty blue", Swatch(0.35, 0.48, 0.58)),
        ("periwinkle", Swatch(0.43, 0.45, 0.65)),
        ("heather", Swatch(0.52, 0.43, 0.60)),
        ("mauve", Swatch(0.60, 0.40, 0.53)),
        ("dusty rose", Swatch(0.64, 0.39, 0.41)),
        ("stone", Swatch(0.45, 0.46, 0.49)),
        ("taupe", Swatch(0.55, 0.44, 0.37)),
    ]

    private static let colors: [Color] = swatches.map(\.swatch.color)

    static func color(for seed: String) -> Color {
        colors[index(for: seed)]
    }

    /// The measurable form of ``color(for:)``, for the contrast suite and for
    /// anything that has to decide what to draw *on* an avatar.
    static func swatch(for seed: String) -> Swatch {
        swatches[index(for: seed)].swatch
    }

    /// FNV-1a, written out rather than using `hashValue`.
    ///
    /// Swift seeds `Hashable` per process, so `hashValue` would give the same
    /// person a different colour on every launch — the one thing this must not
    /// do.
    static func index(for seed: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325

        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }

        return Int(hash % UInt64(colors.count))
    }

    static var count: Int { colors.count }

    /// One or two letters, in the order a reader expects them.
    ///
    /// A display name gives initials; a bare address gives the first letter of
    /// the local part, because the domain is the part people share. Anything
    /// that yields nothing printable — an address that is all punctuation, a
    /// name that is only emoji — falls back to a symbol rather than an empty
    /// circle, which reads as a loading failure.
    static func initials(name: String?, address: String?) -> String {
        if let name, name.isEmpty == false, name.contains("@") == false {
            let words =
                name
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { $0.first(where: \.isLetter) }

            if words.isEmpty == false {
                return String(words.prefix(2)).uppercased()
            }
        }

        let local = address?.split(separator: "@").first ?? ""

        if let first = local.first(where: \.isLetter) {
            return String(first).uppercased()
        }

        return ""
    }
}
