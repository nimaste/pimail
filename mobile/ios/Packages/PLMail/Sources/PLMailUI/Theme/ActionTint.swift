import SwiftUI

/// The colours a swipe reveals.
///
/// Stated here rather than taken from `.green`, `.blue` and friends, which are
/// tuned for the system's white and are the most saturated thing on screen next
/// to cream paper and desaturated avatars — a swipe that lights up like a
/// traffic light undoes the restraint the rest of the list is built on.
///
/// These are the avatar hues walked down in lightness until white text and a
/// white glyph clear 4.5:1 on them. That is the constraint that matters: a
/// swipe button is a coloured block with white content on it, and one that
/// merely looks nice at rest is unreadable mid-gesture with a thumb over half
/// of it. The same value serves both appearances, because the fill is opaque
/// and the surface behind never shows through.
///
/// `destructive` is the exception and is meant to be. It is the one action
/// nothing undoes for you after the toast expires, so it keeps a saturation the
/// others deliberately give up — against these muted blocks a red one is
/// unmistakable, which is the entire job.
/// Two of these were **not** clearing 4.5:1 when the palette was first
/// measured, despite the paragraph above saying they were: `star` sat at
/// 4.36:1 and `spam` at 4.35:1 against white. Both are nudged one step darker
/// here — the smallest change that makes the claim true — which is the whole
/// argument for stating a palette as measurable numbers rather than as prose
/// about numbers. `PaletteContrastTests` now asserts it on every value, so the
/// comment and the colours cannot drift apart again.
enum ActionTint {
    static let archiveSwatch = Swatch(0.29, 0.44, 0.35)
    static let readStateSwatch = Swatch(0.26, 0.40, 0.52)
    static let starSwatch = Swatch(0.58, 0.44, 0.13)
    static let spamSwatch = Swatch(0.64, 0.41, 0.19)
    static let destructiveSwatch = Swatch(0.72, 0.21, 0.17)

    static let archive = archiveSwatch.color
    static let readState = readStateSwatch.color
    static let star = starSwatch.color
    static let spam = spamSwatch.color
    static let destructive = destructiveSwatch.color

    /// Every tint, named, so the contrast suite sweeps the set rather than a
    /// list somebody has to remember to extend.
    static let all: [(name: String, swatch: Swatch)] = [
        ("archive", archiveSwatch), ("readState", readStateSwatch), ("star", starSwatch),
        ("spam", spamSwatch), ("destructive", destructiveSwatch),
    ]
}
