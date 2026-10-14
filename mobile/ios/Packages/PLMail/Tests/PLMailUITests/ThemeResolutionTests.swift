import JMAPKit
import SwiftUI
import Testing

@testable import PLMailUI

/// What the resolver does with what the server sends — including the values it
/// has never heard of, which is most of them.
@Suite("Theme resolution")
struct ThemeResolutionTests {

    // MARK: - The vocabulary

    /// The mapping Android already ships, so the two clients agree about which
    /// of the server's themes each of them can draw.
    @Test("the six themes this client draws map onto the server's vocabulary")
    func sixThemes() {
        #expect(ThemeChoice.from(wire: "system") == .system)
        #expect(ThemeChoice.from(wire: "light") == .light)
        #expect(ThemeChoice.from(wire: "dark") == .dark)
        #expect(ThemeChoice.from(wire: "nord") == .nord)
        #expect(ThemeChoice.from(wire: "dusk") == .dusk)
        #expect(ThemeChoice.from(wire: "solar") == .solar)
    }

    /// The server's *default* theme, which this client draws as light. Named
    /// rather than inlined precisely so a write cannot flatten it.
    @Test("the server's default `paper` is drawn as light")
    func paper() {
        #expect(ThemeChoice.from(wire: ThemeChoice.paperWireValue) == .light)
        #expect(ThemeChoice.from(wire: "paper") == .light)
    }

    /// **The load-bearing fallback.** The server ships 39 themes and will ship
    /// more; a client that switched exhaustively over its own enum would break
    /// on the next server release, and one that threw would stop being able to
    /// read its own settings.
    @Test("a theme this build has never heard of falls back to system, never to an error")
    func unknownTheme() {
        for unknown in ["ocean", "midnight-gold", "petrol-copper", "", "🙂"] {
            #expect(ThemeChoice.from(wire: unknown) == .system)
        }

        #expect(ThemeChoice.from(wire: nil) == .system)
    }

    /// The other half of the same rule: a phone that read `ocean`, drew it as
    /// system and then wrote `system` back would destroy the user's choice in
    /// the browser. Keeping the raw value is what makes that impossible.
    @Test("a flattened theme keeps its wire value, so it can never be written back over")
    func flattenedThemeIsRemembered() {
        var appearance = Appearance()
        appearance.theme = "ocean"

        let resolved = ResolvedTheme(appearance: appearance)

        #expect(resolved.choice == .system)
        #expect(resolved.themeWireValue == "ocean")
    }

    @Test("unknown motion and emphasis values fall back rather than freezing the app")
    func otherVocabularies() {
        #expect(MotionLevel.from(wire: "full") == .full)
        #expect(MotionLevel.from(wire: "none") == .none)
        // Not `.none`: a server that grows a fourth level must not silently
        // freeze an older client's animations, which reads as a hang.
        #expect(MotionLevel.from(wire: "glacial") == .full)
        #expect(MotionLevel.from(wire: nil) == .full)

        #expect(UnreadEmphasis.from(wire: "strong") == .strong)
        #expect(UnreadEmphasis.from(wire: "shouty") == .standard)
    }

    // MARK: - The knobs

    @Test("an appearance resolves every knob this client honours")
    func fullResolution() {
        var appearance = Appearance()
        appearance.theme = "nord"
        appearance.accent = "#88c0d0"
        appearance.motion = "minimal"
        appearance.previewLines = 2
        appearance.listAvatars = false
        appearance.unreadEmphasis = "strong"
        appearance.paneAlpha = 0.7
        appearance.radius = 1.5

        let resolved = ResolvedTheme(appearance: appearance)

        #expect(resolved.choice == .nord)
        #expect(resolved.colorScheme == .dark)
        #expect(resolved.motion == .minimal)
        #expect(resolved.previewLines == 2)
        #expect(resolved.showsAvatars == false)
        #expect(resolved.unreadEmphasis == .strong)
        #expect(resolved.paneOpacity == 0.7)
        #expect(resolved.accent == Swatch(hex: "#88c0d0"))
    }

    /// The server clamps, so an out-of-range value should never arrive — but a
    /// client that trusts that and is wrong renders a list with nine preview
    /// lines and a pane with negative opacity. Belt and braces, and neither is
    /// an error to show anyone.
    @Test("out-of-range knobs clamp rather than being refused or shown as errors")
    func clampsRatherThanRefusing() {
        var appearance = Appearance()
        appearance.previewLines = 9
        appearance.paneAlpha = 1.4

        let high = ResolvedTheme(appearance: appearance)

        #expect(high.previewLines == 2)
        #expect(high.paneOpacity == 1.0)

        appearance.previewLines = -4
        appearance.paneAlpha = 0.0

        let low = ResolvedTheme(appearance: appearance)

        #expect(low.previewLines == 0)
        #expect(low.paneOpacity == 0.15)
    }

    /// `radius` reaches panes and nothing else, and the server's default maps
    /// onto the radius this app already draws — otherwise every fresh account
    /// would silently shrink every pane in the app.
    @Test("the default radius is this app's own, and the knob is capped at both ends")
    func paneRadius() {
        #expect(ResolvedTheme.paneRadius(fromRem: 0.75) == PanelStyle.cornerRadius)
        #expect(ResolvedTheme.paneRadius(fromRem: 0) == 0)
        #expect(ResolvedTheme.paneRadius(fromRem: 2) == 32)
        // Clamped, not extrapolated: 2.0 is the server's own ceiling.
        #expect(ResolvedTheme.paneRadius(fromRem: 40) == 32)
        #expect(ResolvedTheme.paneRadius(fromRem: -1) == 0)
    }

    /// `Appearance/get` honours a `properties` argument, so a partial object is
    /// a legitimate response. Every field has to have a default that is not a
    /// crash and not a blank screen.
    @Test("an empty appearance resolves to the local default rather than to nothing")
    func emptyAppearance() {
        let resolved = ResolvedTheme(appearance: Appearance())

        #expect(resolved.choice == .system)
        #expect(resolved.previewLines == 1)
        #expect(resolved.showsAvatars)
        #expect(resolved.paneOpacity == 1)
        #expect(resolved.paneCornerRadius == PanelStyle.cornerRadius)
        #expect(resolved == ResolvedTheme.placeholder)
    }

    // MARK: - The Session hint

    @Test("the compact hint paints a first frame without waiting for a request")
    func hint() {
        let hint = Session.CompactAppearance(
            theme: "dusk", layout: "flat", accent: "#a78bfa", density: "cosy")
        let resolved = ResolvedTheme(hint: hint)

        #expect(resolved.choice == .dusk)
        #expect(resolved.colorScheme == .dark)
        #expect(resolved.accent == Swatch(hex: "#a78bfa"))
    }

    /// **A server without the extension is a supported instance.** The hint is
    /// absent, and the app keeps its own palette rather than reporting
    /// anything.
    @Test("no hint at all resolves to the local default, not to a failure")
    func absentHint() {
        #expect(ResolvedTheme(hint: nil) == .placeholder)
    }

    @Test("a malformed accent is ignored rather than substituted")
    func malformedAccent() {
        var appearance = Appearance()
        appearance.accent = "rebeccapurple"

        // Nil, so the palette's own accent stands. Substituting a default here
        // would put a colour on screen the user never chose and give them no
        // way to tell it apart from one they did.
        #expect(ResolvedTheme(appearance: appearance).accent == nil)
    }

    // MARK: - Applying it

    /// A user accent has to be legible on whichever palette it lands on, in
    /// both appearances, or a legal theme from the server renders as
    /// unreadable text with nothing in the app able to say why.
    @Test("a user accent is made legible on every shipped palette in both appearances")
    func accentIsMadeLegible() {
        var appearance = Appearance()
        // Deliberately awful: pale yellow, unreadable on any light surface.
        appearance.accent = "#ffe066"

        let resolved = ResolvedTheme(appearance: appearance)

        for scheme in [ColorScheme.light, .dark] {
            let palette = resolved.palette(for: scheme)

            for surface in palette.surfaces {
                #expect(palette.accent.contrastRatio(against: surface) >= 4.5)
            }

            #expect(palette.accentInk.contrastRatio(against: palette.accent) >= 4.5)
        }
    }

    @Test("system follows the appearance, and a named theme overrides it")
    func schemeResolution() {
        var systemTheme = ResolvedTheme()
        systemTheme.choice = .system

        #expect(systemTheme.colorScheme == nil)
        #expect(systemTheme.palette(for: .light) == .light)
        #expect(systemTheme.palette(for: .dark) == .dark)

        var solar = ResolvedTheme()
        solar.choice = .solar

        // Ignores the appearance entirely — a user who picked solar wants
        // solar at midnight too.
        #expect(solar.palette(for: .dark) == .solar)
        #expect(solar.colorScheme == .light)
    }

    // MARK: - Motion

    /// Reduce Motion wins over the server. Somebody who set it did so because
    /// movement makes them ill, and a theme is not entitled to override an
    /// accessibility setting.
    @Test("Reduce Motion beats the server's motion preference")
    func reduceMotionWins() {
        #expect(Motion.standard(.full, reduced: true) == nil)
        #expect(Motion.fast(.full, reduced: true) == nil)
        #expect(Motion.slow(.minimal, reduced: true) == nil)
        #expect(Motion.standard(.none, reduced: false) == nil)
        #expect(Motion.standard(.full, reduced: false) != nil)
        #expect(Motion.standard(.minimal, reduced: false) != nil)
    }
}
