import SwiftUI
import Testing

@testable import PLMailUI

/// The pane surfaces, now that `.mailPane` and `messageCard()` fill from
/// ``ThemePalette`` rather than from ``PanelStyle``.
///
/// The change is invisible in the default theme by construction and visible in
/// every other one, which is exactly the pair of claims a compiler cannot check
/// and a screenshot proves only for the build it was taken from. Both halves
/// are pinned here: the default must not move a point, and a themed palette
/// must actually move.
@Suite("Pane surfaces")
struct PaneSurfaceTests {

    // MARK: - The default theme must not move

    /// **This is a refactor, not a redesign.** A pane that used to fill with
    /// `PanelStyle.surface` now fills with `theme.palette(for:).surface`, and
    /// the only thing making that a no-op for everybody who never set a theme
    /// is that the two are the same numbers. Stated as a test rather than left
    /// to the doc comment, because the doc comment cannot fail.
    @Test("the default palettes fill panes with exactly the colours PanelStyle shipped")
    func defaultPaletteMatchesPanelStyle() {
        #expect(ThemePalette.light.surface == PanelStyle.surfaceLight)
        #expect(ThemePalette.light.window == PanelStyle.windowLight)
        #expect(ThemePalette.dark.surface == PanelStyle.surfaceDark)
        #expect(ThemePalette.dark.window == PanelStyle.windowDark)
    }

    /// The value a pane outside the injected tree draws.
    ///
    /// A preview, a test host, or a subtree under a root that forgot the
    /// injection all resolve ``ResolvedTheme/placeholder`` — so the placeholder
    /// resolving to anything but the shipped cream would make "nothing looks
    /// broken" false in precisely the places nobody looks.
    @Test("an uninjected environment still paints the shipped cream and near-black")
    func placeholderPaintsTheShippedSurfaces() {
        let theme = EnvironmentValues().theme

        #expect(theme.palette(for: .light).surface == PanelStyle.surfaceLight)
        #expect(theme.palette(for: .light).window == PanelStyle.windowLight)
        #expect(theme.palette(for: .dark).surface == PanelStyle.surfaceDark)
        #expect(theme.palette(for: .dark).window == PanelStyle.windowDark)
    }

    // MARK: - A themed palette must move

    /// The other half, and the one the whole adoption exists for: before this
    /// pass a non-default theme moved the accent, the density and the corner
    /// radius and left every pane cream. A theme whose surface equalled
    /// ``PanelStyle``'s would be that bug again, and it would look like nothing
    /// at all.
    @Test("every shipped theme other than the default draws a pane surface of its own")
    func themedPalettesLeaveTheDefaultSurface() {
        for (name, palette) in ThemePalette.allShipped where name != "light" && name != "dark" {
            #expect(
                palette.surface != PanelStyle.surfaceLight,
                "\(name) draws the default light pane")
            #expect(
                palette.surface != PanelStyle.surfaceDark,
                "\(name) draws the default dark pane")
            // The gutter has to move with the pane. A themed surface on the
            // shipped window is the reading that looks like a rendering fault
            // rather than a theme.
            #expect(palette.window != palette.surface, "\(name) has no gutter to read")
        }
    }

    /// A pane is only a pane if you can see where it ends.
    ///
    /// The `mailPane` treatment now draws a 1px ``PanelStyle/paneBorder`` as
    /// well, but the border is a hairline at ten per cent and cannot carry the
    /// edge alone — the surface reading differently from the window is still
    /// what makes a column a column, so a palette whose two were within
    /// rounding would produce an iPad layout with no visible columns and
    /// nothing in the code saying why.
    @Test("a pane is distinguishable from the window it sits on, in every palette")
    func paneReadsAgainstItsWindow() {
        for (name, palette) in ThemePalette.allShipped {
            let separation = palette.surface.contrastRatio(against: palette.window)

            #expect(separation >= 1.05, "\(name)'s pane and window are the same colour")
        }
    }

    // MARK: - The redesign's geometry

    /// The two numbers the pane treatment is built from, pinned because they
    /// are read from three places that cannot see each other.
    ///
    /// ``PaneColumn`` splits ``PanelStyle/inset`` in half against a
    /// neighbouring pane and keeps it whole against the window, so the gap
    /// between two panes is one inset and the margin at the edge is one inset
    /// too. The card is drawn as a *background* with the same insets the
    /// content is padded by; when those two drifted apart, rows ran past the
    /// card's edge — which looks like a clipping bug rather than a spacing
    /// one, and is why it is asserted rather than described.
    @Test("the pane geometry the redesign specifies, and the two halves that must agree")
    func paneGeometry() {
        #expect(PanelStyle.cornerRadius == 12)
        #expect(PanelStyle.inset == 12)

        // `PaneColumn` lives behind `#if os(iOS)` with the pane treatment it
        // serves; on the macOS test host there is no split view to inset.
        #if os(iOS)
        #expect(PaneColumn.leading.leadingInset == PanelStyle.inset)
        #expect(PaneColumn.trailing.trailingInset == PanelStyle.inset)

        // Facing margins sum to one full gutter, whichever pair faces.
        #expect(
            PaneColumn.leading.trailingInset + PaneColumn.middle.leadingInset == PanelStyle.inset)
        #expect(
            PaneColumn.middle.trailingInset + PaneColumn.trailing.leadingInset == PanelStyle.inset)
        #endif
    }

    /// One outer margin, for all three columns.
    ///
    /// The gaps *between* panes were consistent long before the outer edges
    /// were: the sidebar is flat and read as flush to the screen, the list
    /// showed its card at twelve points, and the reader's edge was hidden
    /// behind chrome. ``PanelStyle/outerMargin`` is the single number the three
    /// window-facing edges now read, and this is what stops the next person
    /// tuning one of them on its own — the sidebar's margin is
    /// ``PaneColumn/leading``'s, taken rather than restated, so a change here
    /// moves all three or fails.
    @Test("the three columns keep one margin against the window")
    func outerMarginIsOneNumber() {
        #if os(iOS)
        // The sidebar's leading edge, and the reader's trailing one: the two
        // edges that actually touch the screen.
        #expect(PaneColumn.leading.leadingInset == PanelStyle.outerMargin)
        #expect(PaneColumn.trailing.trailingInset == PanelStyle.outerMargin)

        // And nothing else claims it: an inner edge is half a gutter, never a
        // margin, or the columns drift apart by the difference.
        #expect(PaneColumn.middle.leadingInset != PanelStyle.outerMargin)
        #expect(PaneColumn.middle.trailingInset != PanelStyle.outerMargin)
        #endif
    }

    // MARK: - The new tokens

    /// The star has to be visible before it can mean anything.
    ///
    /// The mock's `#fbbf24` measures 1.36:1 on the paper surface, so the
    /// palette walks it to the 3:1 non-text floor. This asserts the floor, not
    /// the resulting hex: the walk is allowed to land wherever a theme's
    /// surface puts it, and pinning the value would make adding a sixth theme
    /// a test edit.
    @Test("the star clears the non-text floor on every surface of every theme")
    func starIsVisible() {
        for (name, palette) in ThemePalette.allShipped {
            for surface in palette.surfaces {
                let ratio = palette.star.contrastRatio(against: surface)

                #expect(ratio >= 3, "\(name): the star is \(ratio) on a surface, under 3")
            }
        }
    }

    /// An unread row is a fill now, not just a weight — and a fill that reads
    /// as a different surface has to hold the text drawn on it.
    ///
    /// Both new fills are checked against ``ThemePalette/ink`` at the text
    /// floor rather than the body floor: they are backgrounds under rows and
    /// under matched substrings, and the ink ladder's own 7:1 is asserted
    /// against the pane, which these deliberately are not.
    @Test("ink stays readable on the unread tint and on a search highlight")
    func newFillsHoldTheirText() {
        for (name, palette) in ThemePalette.allShipped {
            #expect(
                palette.ink.contrastRatio(against: palette.unreadTint) >= 4.5,
                "\(name): ink is unreadable on an unread row")
            #expect(
                palette.ink.contrastRatio(against: palette.searchHighlight) >= 4.5,
                "\(name): ink is unreadable on a search match")

            // A tint nobody can see is a tint that does not mark anything.
            #expect(
                palette.unreadTint != palette.surface,
                "\(name): an unread row is the same colour as a read one")
            #expect(
                palette.searchHighlight != palette.surface,
                "\(name): a search match is the same colour as the pane")
        }
    }

    /// The light ladder is the mock's, and only the light one.
    ///
    /// Both halves matter. The drawn values landing verbatim is what says the
    /// override actually reached the palette rather than being faded past by
    /// the derivation; every other theme still differing from them is what
    /// says a light-only decision stayed light-only. A dark palette that
    /// happened to match these would mean the override had leaked into
    /// `derived` for everybody — the exact regression the doc comment on
    /// ``ThemePalette/light`` asks the next reader not to introduce.
    @Test("the light ink ladder is the drawn one, and no other theme takes it")
    func lightLadderIsDrawn() {
        #expect(ThemePalette.light.inkSoft == Swatch(hex: "#524e48"))
        #expect(ThemePalette.light.inkMuted == Swatch(hex: "#5f5b54"))
        #expect(ThemePalette.light.inkFaint == Swatch(hex: "#746f67"))

        for (name, palette) in ThemePalette.allShipped where name != "light" {
            #expect(palette.inkSoft != ThemePalette.light.inkSoft, "\(name) took light's ladder")
            #expect(palette.inkFaint != ThemePalette.light.inkFaint, "\(name) took light's ladder")
        }
    }

    // MARK: - The ink ladder against a themed surface

    /// Where contrast quietly breaks.
    ///
    /// ``PaletteContrastTests`` sweeps this too; it is repeated here because
    /// this suite is the one somebody reads when they add a sixth theme, and
    /// the failure — text that is legible on the default cream and not on the
    /// surface a theme actually paints — is the one a pane refactor invites.
    @Test("the ink ladder clears its floors against the surface each palette paints")
    func inkClearsItsFloorsOnEveryPaneSurface() {
        for (name, palette) in ThemePalette.allShipped {
            #expect(
                palette.ink.contrastRatio(against: palette.surface) >= 7,
                "\(name)'s ink is under 7:1 on its own pane")
            #expect(
                palette.inkSoft.contrastRatio(against: palette.surface) >= 4.5,
                "\(name)'s soft ink is under 4.5:1 on its own pane")
            #expect(
                palette.inkMuted.contrastRatio(against: palette.surface) >= 4.5,
                "\(name)'s muted ink is under 4.5:1 on its own pane")
            #expect(
                palette.inkFaint.contrastRatio(against: palette.surface) >= 3,
                "\(name)'s faint ink is under 3:1 on its own pane")
        }
    }
}
