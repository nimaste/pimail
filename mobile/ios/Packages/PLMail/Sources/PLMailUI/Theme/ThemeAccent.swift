import SwiftUI

/// The resolved theme's accent, as a `ShapeStyle`.
///
/// **A style rather than a `Color` because a `Color` cannot be read from the
/// environment at the point it is used.** The accent depends on two
/// environment values at once — the ``ResolvedTheme`` and the current
/// `ColorScheme`, since one theme serves both appearances — so every call site
/// that wanted it as a colour would have to declare two `@Environment`
/// properties and thread them into whatever draws. Twenty call sites doing
/// that is twenty chances to forget one, and a forgotten one silently falls
/// back to `Color.accentColor`, which is the exact bug this pass exists to
/// remove: it looks right in the default theme and ignores the server
/// entirely.
///
/// Resolving inside `resolve(in:)` means the style is written `.themeAccent`
/// wherever `.accentColor` used to appear and picks both inputs up by itself.
/// It also keeps working where there is no environment to read — an
/// unpopulated ``EnvironmentValues/theme`` is ``ResolvedTheme/placeholder``,
/// whose palette is this app's own, so a preview or a view outside the
/// injected tree draws the shipped accent rather than nothing.
public struct ThemeAccent: ShapeStyle, Sendable {
    public init() {}

    public func resolve(in environment: EnvironmentValues) -> Color {
        environment.theme.palette(for: environment.colorScheme).accent.color
    }
}

extension ShapeStyle where Self == ThemeAccent {
    /// The user's accent, already walked to legibility against this theme's
    /// surfaces. Replaces `Color.accentColor` everywhere the accent is meant
    /// to be the user's rather than the asset catalogue's.
    public static var themeAccent: ThemeAccent { ThemeAccent() }
}

extension ResolvedTheme {
    /// The accent as a plain `Color`, for the handful of places that cannot
    /// take a `ShapeStyle`.
    ///
    /// `.tint(_:)`, a `Color?` returned from a role-to-colour function, and a
    /// ternary whose other branch is a `Color` all need a concrete type. Those
    /// call sites read ``EnvironmentValues/colorScheme`` themselves and pass it
    /// in, rather than this capturing an appearance — a value type that stored
    /// the appearance would be stale the moment the shade is pulled down and
    /// the phone switches to dark.
    public func accentColor(in scheme: ColorScheme) -> Color {
        palette(for: scheme).accent.color
    }
}
