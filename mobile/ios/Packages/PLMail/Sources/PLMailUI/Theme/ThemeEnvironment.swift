public import JMAPKit
public import PLMailCore

import SwiftUI

/// The resolved theme injected through the environment.
///
/// plMail separates Theme (the palette) from Layout (the treatment), with
/// user-set knobs on top, and a client that hardcodes its palette is
/// explicitly wrong. Views read the theme from here so that swapping the
/// *source* of those values touches nothing but the resolver — which is
/// exactly what happened: this was a nineteen-line placeholder waiting for the
/// server to expose `Appearance` over JMAP, and now it resolves a real
/// ``JMAPKit/Appearance``.
///
/// **Three things this type refuses to do**, each of which is a bug that has
/// shipped in a themable client somewhere:
///
/// 1. It never fails on an unknown value. The server has 39 themes and will
///    have more; an unrecognised `theme`, `layout`, `density` or `motion`
///    resolves to the default rather than throwing, because a client that
///    errors on a new one is a client that breaks on a server upgrade.
/// 2. It never writes back what it flattened. ``ResolvedTheme`` remembers the
///    ``themeWireValue`` it was given, so a phone that read `ocean`, drew it
///    as system dark and then saved its own idea of the theme cannot destroy
///    the user's choice in the browser.
/// 3. It applies `radius` to **panes only**. A `radius` of 2.0rem is a legal
///    value that must never reach a button; `PanelStyle` already drew that
///    line and this keeps it.
public struct ResolvedTheme: Equatable, Sendable {
    /// The local default: the app's own light and dark palettes, plMail's
    /// accent, and no server involved. What an instance without the appearance
    /// extension gets, and what the first frame draws before `Appearance/get`
    /// lands.
    public static let placeholder = ResolvedTheme()

    /// Which of the shipped palettes this theme resolves to, before the
    /// system's light/dark preference is applied.
    public var choice: ThemeChoice = .system

    /// The raw `theme` string the server sent, kept verbatim.
    ///
    /// **The load-bearing part of never flattening a theme.** `ocean` renders
    /// as system here, but this still says `ocean`, so a settings screen can
    /// tell "the user is on a theme I cannot draw" from "the user chose
    /// system" — and a writer knows not to send `system` for the first case.
    public var themeWireValue: String?

    /// The user's accent, already walked to legibility against each palette.
    /// Nil means the palette's own accent stands.
    public var accent: Swatch?

    /// Pane corner radius in points, from the server's `radius` (which is in
    /// rem). Panes only.
    public var paneCornerRadius: CGFloat = PanelStyle.cornerRadius

    /// Pane opacity, 0.15…1.0. 1.0 is the default layout's value, and the one
    /// case where nothing has to be composited.
    public var paneOpacity: Double = 1

    /// How much motion the user asked for, before `Reduce Motion` is
    /// consulted. Consult ``Motion`` rather than this.
    public var motion: MotionLevel = .full

    /// Rows of preview text, 0…2. iOS honours it; the value is clamped
    /// server-side so it never arrives out of range.
    public var previewLines: Int = 1

    /// Whether the list draws sender avatars at all.
    public var showsAvatars = true

    /// How hard an unread row is pushed forward.
    public var unreadEmphasis: UnreadEmphasis = .standard

    public init() {}

    // MARK: - Palettes

    /// The palette for a given appearance.
    ///
    /// Taking the `ColorScheme` as an argument rather than reading it inside is
    /// what lets one `ResolvedTheme` serve both — a value type that captured
    /// the appearance would be stale the moment the user pulled the shade down
    /// and switched the phone to dark.
    public func palette(for scheme: ColorScheme) -> ThemePalette {
        var palette = choice.palette(for: scheme)

        if let accent {
            palette.accent = accent.adjusted(
                toContrast: 4.5, against: palette.worstSurface(for: accent))
            palette.accentInk =
                palette.accent.contrastRatio(against: .white)
                    >= palette.accent.contrastRatio(against: .black) ? .white : .black
            palette.accentSoft = palette.surface.mixed(
                with: palette.accent, amount: palette.isDark ? 0.22 : 0.14)
        }

        return palette
    }

    /// Whether this theme forces an appearance, or lets the system decide.
    ///
    /// Nil is what `preferredColorScheme` wants for "do not override" — it
    /// means exactly that, not "pick one for me".
    public var colorScheme: ColorScheme? { choice.colorScheme }
}

// MARK: - The vocabulary this client can draw

/// The themes iOS ships, which is Android's six mapped onto the server's
/// thirty-nine.
///
/// Ships a subset deliberately. What matters is the *shape*: the resolver
/// exists, so adding `ocean` is a two-line data entry in ``ThemePalette``, and
/// until somebody does it `ocean` renders as system rather than as an error.
public enum ThemeChoice: String, CaseIterable, Sendable {
    case system
    case light
    case dark
    case nord
    case dusk
    case solar

    /// The server value this choice writes.
    ///
    /// `light` writes `light`, not `paper` — see ``from(wire:)`` for why the
    /// asymmetry is deliberate rather than an oversight.
    public var wireValue: String { rawValue }

    /// The server's default theme, which this client draws as light.
    ///
    /// Named rather than inlined so a write cannot flatten it: `paper` reads
    /// as `light`, but a user sitting on `paper` who never touches the theme
    /// picker must not have `light` written under them by some unrelated save.
    public static let paperWireValue = "paper"

    /// Maps a server theme onto something this client can draw.
    ///
    /// **Anything unrecognised becomes `system`**, exactly as Android does.
    /// That fallback is the load-bearing part: the server ships 39 themes and
    /// will ship more, so a client that switched exhaustively over its own
    /// enum would break on the next server release.
    public static func from(wire value: String?) -> ThemeChoice {
        guard let value else { return .system }

        if value == paperWireValue { return .light }

        return ThemeChoice(rawValue: value) ?? .system
    }

    /// Nil for `system`.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .solar: .light
        case .dark, .nord, .dusk: .dark
        }
    }

    func palette(for scheme: ColorScheme) -> ThemePalette {
        switch self {
        case .system: scheme == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        case .nord: .nord
        case .dusk: .dusk
        case .solar: .solar
        }
    }
}

/// How much the app moves. The server's `motion` property.
public enum MotionLevel: String, CaseIterable, Sendable {
    case full
    case minimal
    case none

    /// Unknown becomes `full` rather than `none`: a server that grows a fourth
    /// level should not silently freeze an older client's animations, which
    /// reads as the app having hung.
    public static func from(wire value: String?) -> MotionLevel {
        MotionLevel(rawValue: value ?? "") ?? .full
    }
}

/// How hard an unread row is pushed forward. The server's `unreadEmphasis`.
public enum UnreadEmphasis: String, CaseIterable, Sendable {
    case subtle
    case standard
    case strong

    public static func from(wire value: String?) -> UnreadEmphasis {
        UnreadEmphasis(rawValue: value ?? "") ?? .standard
    }

    /// The weight a sender and a subject are drawn at.
    ///
    /// **Weight only, and never colour.** The row already says "unread" three
    /// other ways — a green dot, a primary rather than secondary sender, and
    /// the position in the list — so this knob is allowed to change how loud
    /// that is and not whether it is said at all. `subtle` still leaves an
    /// unread row heavier than a read one, because a setting that made the two
    /// identical would be a setting that hides mail.
    ///
    /// `standard` is `.semibold` against `.regular`, which is verbatim what the
    /// list drew before the knob was wired: the default theme has to render
    /// unchanged, or this is a redesign rather than a refactor.
    public func weight(isUnread: Bool) -> Font.Weight {
        guard isUnread else { return .regular }

        switch self {
        case .subtle: return .medium
        case .standard: return .semibold
        case .strong: return .bold
        }
    }
}

// MARK: - Resolving one from the wire

extension ResolvedTheme {
    /// Resolves the Session's compact hint — `{theme, layout, accent,
    /// density}` — into something paintable.
    ///
    /// **For the first frame only.** The Session's `state` is a hash of the
    /// user's account ids and does not move when a theme changes, so a cached
    /// Session holds a stale hint until `Appearance/get` corrects it. It is a
    /// splash-screen colour, not truth, and nothing committed outside the app
    /// may be driven from it.
    public init(hint: Session.CompactAppearance?) {
        self.init()

        guard let hint else { return }

        choice = ThemeChoice.from(wire: hint.theme)
        themeWireValue = hint.theme
        accent = hint.accent.flatMap(Swatch.init(hex:))
    }

    /// Resolves the authoritative read.
    ///
    /// Every property is optional on the way in and every one has a default
    /// here, because `Appearance/get` honours a `properties` argument and a
    /// partial object is a legitimate response rather than a broken one.
    public init(appearance: Appearance) {
        self.init()

        choice = ThemeChoice.from(wire: appearance.theme)
        themeWireValue = appearance.theme
        accent = appearance.accent.flatMap(Swatch.init(hex:))
        motion = MotionLevel.from(wire: appearance.motion)
        unreadEmphasis = UnreadEmphasis.from(wire: appearance.unreadEmphasis)

        if let lines = appearance.previewLines {
            previewLines = min(2, max(0, lines))
        }

        showsAvatars = appearance.listAvatars ?? true

        if let alpha = appearance.paneAlpha {
            paneOpacity = min(1, max(0.15, alpha))
        }

        if let radius = appearance.radius {
            paneCornerRadius = Self.paneRadius(fromRem: radius)
        }
    }

    /// The server's `radius` is in **rem** on a 16px root, clamped 0.0…2.0 —
    /// so 0…32pt, against this app's own pane radius of
    /// ``PanelStyle/cornerRadius``.
    ///
    /// Anchored rather than taken literally, and the anchoring still earns its
    /// keep now that the redesign has moved the pane radius to 12: the *ratio*
    /// is what is server-driven, so a fresh account's default 0.75rem is
    /// whatever this app draws, and a user who moved the knob keeps the same
    /// proportion of it. Capped at 32 — past which a phone-sized pane is a
    /// lozenge and the list inside it loses its corners. (At 12pt the default
    /// happens to coincide with a literal 16px-per-rem reading; that is a
    /// coincidence, not the rule, and hard-coding 16 here would desynchronise
    /// the moment the pane radius moves again.)
    static func paneRadius(fromRem rem: Double) -> CGFloat {
        let clamped = min(2, max(0, rem))

        return min(32, CGFloat(clamped / 0.75) * PanelStyle.cornerRadius)
    }
}

#if os(iOS)

extension View {
    /// Everything a sheet needs to look like the rest of the app.
    ///
    /// A sheet is presented in its own hosting context, so **none** of the
    /// three reaches it from the root: the theme, the resolved motion, and —
    /// the one that was still missing — the forced appearance. Without the
    /// last, a themed sheet asked its palette for the *system's* scheme rather
    /// than the theme's, and Settings came up with near-white rows on a
    /// near-black ground the first time somebody chose Dark.
    ///
    /// One modifier so the next sheet cannot get two of the three.
    public func themedSheet(_ theme: ResolvedTheme, reduceMotion: Bool) -> some View {
        self
            .environment(\.theme, theme)
            .resolvedMotion(theme.motion, reduced: reduceMotion)
            .preferredColorScheme(theme.colorScheme)
    }
}

#endif

extension EnvironmentValues {
    @Entry public var theme: ResolvedTheme = .placeholder

    /// The one ``AppearanceSettings`` the app owns, handed down from the
    /// composition root.
    ///
    /// **Injected rather than constructed where it is used.** The screen that
    /// writes the appearance sits behind a sheet several levels below the root
    /// that reads it, and the view presenting that sheet is not this module's
    /// to change — so passing it as an initialiser parameter would mean editing
    /// a file the shell owns. The environment crosses a sheet presentation,
    /// which is exactly the boundary in the way.
    ///
    /// Nil is a supported value, not a missing one: a preview, a test host, or
    /// any tree without a composition root above it gets nil and the picker
    /// falls back to a device-local choice — which is also what an instance
    /// without the appearance extension does.
    @Entry public var appearanceSettings: AppearanceSettings?
}
