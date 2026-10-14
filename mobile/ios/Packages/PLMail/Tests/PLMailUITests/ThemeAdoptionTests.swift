import SwiftUI
import Testing

@testable import PLMailUI

/// What the views actually read.
///
/// ``ThemeResolutionTests`` proves the resolver turns a server response into a
/// ``ResolvedTheme``; this suite covers the step after it, which was missing
/// for a whole wave: the app built five palettes, `Appearance/get`, an accent
/// asset and a `Motion` enum, and then drew `Color.accentColor` and
/// `.snappy(duration: 0.2)` anyway. Every test below pins a value that a call
/// site now reads, so the adoption cannot quietly come undone.
@Suite("Theme adoption")
struct ThemeAdoptionTests {

    // MARK: - The default theme must not move

    /// **This is a refactor, not a redesign.** The moment views read
    /// ``ThemePalette/accent`` instead of `Color.accentColor`, the palette's
    /// value becomes what ships — so dark mode's accent has to be the one the
    /// asset catalogue has been drawing, not whatever the contrast walk stops
    /// at first. Derived from ``PanelStyle/defaultAccent`` it lands on a dull
    /// `#9a8c76`, which is legible and visibly not the colour of the app.
    @Test("dark mode's accent is the one the asset catalogue ships, not a derived one")
    func darkAccentIsUnchanged() {
        #expect(PanelStyle.defaultAccentDark == Swatch(hex: "#c2a67e"))
        // Untouched by the derivation: it already clears the floor, and a
        // walked value here would be the change this test exists to catch.
        #expect(ThemePalette.dark.accent == PanelStyle.defaultAccentDark)
    }

    /// The light accent **does** move, by one step, and that is deliberate:
    /// `#7d6b4f` measures 4.11:1 against the palette's worst surface, under
    /// the 4.5:1 every other value in the app is held to. Pinned so the
    /// difference is a decision on the record rather than something noticed on
    /// a screenshot later.
    @Test("the light accent is nudged only as far as its own contrast floor")
    func lightAccentClearsItsFloor() {
        let shipped = PanelStyle.defaultAccent
        let drawn = ThemePalette.light.accent

        #expect(drawn != shipped, "the raw accent already passed, so nothing was owed")
        #expect(shipped.contrastRatio(against: ThemePalette.light.worstSurface(for: shipped)) < 4.5)
        #expect(drawn.contrastRatio(against: ThemePalette.light.worstSurface(for: drawn)) >= 4.5)
        // A few steps of the 2% walk and no more, so the colour is
        // recognisably the one the user chose rather than a substitute. The
        // whole point of walking rather than replacing is that this stays
        // true.
        #expect(drawn.contrastRatio(against: shipped) < 1.15)
    }

    // MARK: - Unread emphasis

    /// `standard` is what the list drew before the knob was wired — semibold
    /// against regular. If this changes, every default install changes.
    @Test("the default unread emphasis is exactly the weight the list already drew")
    func standardEmphasisIsTodaysWeight() {
        #expect(UnreadEmphasis.standard.weight(isUnread: true) == .semibold)
        #expect(UnreadEmphasis.standard.weight(isUnread: false) == .regular)
    }

    /// A read row is read at every setting. The knob says how loudly unread is
    /// announced, never whether it is announced — a level that made the two
    /// identical would be a setting that hides mail.
    @Test("no emphasis level lets an unread row weigh the same as a read one")
    func unreadIsAlwaysHeavier() {
        let order: [Font.Weight] = [.regular, .medium, .semibold, .bold]

        for level in UnreadEmphasis.allCases {
            #expect(level.weight(isUnread: false) == .regular)

            let unread = order.firstIndex(of: level.weight(isUnread: true))
            let read = order.firstIndex(of: level.weight(isUnread: false))

            #expect(unread != nil && read != nil)
            #expect((unread ?? 0) > (read ?? 0), "\(level) draws unread no heavier than read")
        }
    }

    // MARK: - Motion

    /// A view below a root that never called `resolvedMotion(_:reduced:)`
    /// reads these. They have to be the literals the call sites used before
    /// they read the environment, or the refactor is visible as a change in
    /// how fast the app moves.
    @Test("an unpopulated environment animates exactly as the literals did")
    func environmentDefaultsMatchTheOldLiterals() {
        let environment = EnvironmentValues()

        #expect(environment.standardAnimation == .snappy(duration: 0.2))
        #expect(environment.fastAnimation == .snappy(duration: 0.15))
        #expect(environment.slowAnimation == .snappy(duration: 0.25))
    }

    /// **The accessibility defect this wave was asked to close.** Reduce
    /// Motion was consulted nowhere outside `Motion.swift`, so a phone with it
    /// switched on still slid the undo bar, flipped every avatar in a
    /// multi-select sweep and expanded quoted history. All three curves have
    /// to go still, not just the standard one — the 0.15 and 0.25 call sites
    /// are the ones easiest to leave behind.
    @Test("Reduce Motion silences every curve, not only the standard one")
    func reduceMotionSilencesAllThree() {
        for level in MotionLevel.allCases {
            #expect(Motion.standard(level, reduced: true) == nil)
            #expect(Motion.fast(level, reduced: true) == nil)
            #expect(Motion.slow(level, reduced: true) == nil)
        }
    }

    /// The server may ask for less movement; it may not ask for more than the
    /// person using the phone allowed.
    @Test("the server's motion level still applies when Reduce Motion is off")
    func serverLevelStillApplies() {
        #expect(Motion.slow(.full, reduced: false) == .snappy(duration: 0.25))
        #expect(Motion.slow(.minimal, reduced: false) == .linear(duration: 0.1))
        #expect(Motion.slow(.none, reduced: false) == nil)
    }

    // MARK: - Panes

    /// `radius` reaches panes and nothing else, and an unpopulated environment
    /// has to keep the 20pt everybody has been looking at — a pane outside the
    /// injected tree drawing square corners is the visible half of forgetting
    /// to inject the theme at the root.
    @Test("a pane with no theme injected keeps the radius the app already drew")
    func paneRadiusFallsBackToTheShippedValue() {
        #expect(ResolvedTheme.placeholder.paneCornerRadius == PanelStyle.cornerRadius)
        #expect(EnvironmentValues().theme.paneCornerRadius == PanelStyle.cornerRadius)
    }

    /// The other half of the same rule: a theme that never had a server
    /// response applied still resolves a full palette, so a view reading
    /// ``ThemeAccent`` before `Appearance/get` lands draws this app's own
    /// accent rather than nothing or system blue.
    @Test("the placeholder theme resolves the app's own accent in both appearances")
    func placeholderResolvesTheAppsAccent() {
        let theme = ResolvedTheme.placeholder

        #expect(theme.palette(for: .light).accent == ThemePalette.light.accent)
        #expect(theme.palette(for: .dark).accent == PanelStyle.defaultAccentDark)
    }
}
