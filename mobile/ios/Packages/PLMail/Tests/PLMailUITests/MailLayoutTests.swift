import Testing

@testable import PLMailUI

/// The breakpoints, checked without a simulator.
///
/// The layout decision was a pile of inline `sizeClass != .compact` tests
/// spread over four call sites, which meant the only way to find out what a
/// 700pt Stage Manager window did was to make one and look. It is a pure
/// function of two inputs now, and this is that function pinned down.
@Suite("Mail layout")
struct MailLayoutTests {
    @Test("a compact size class is one pane whatever the width says")
    func compactWins() {
        for width in [320.0, 700.0, 1366.0] {
            let layout = MailLayout.resolve(width: width, isCompactSizeClass: true)

            #expect(layout.mode == .single)
        }
    }

    @Test("a Slide Over panel gets one pane")
    func slideOver() {
        #expect(MailLayout.resolve(width: 320, isCompactSizeClass: false).mode == .single)
    }

    @Test("a Stage Manager window too narrow for three columns gets two")
    func stageManager() {
        // The case the old single boolean got wrong: 700pt is a regular size
        // class, so it took the full three-column treatment and left the
        // reader roughly nothing after a 220pt sidebar and a 396pt list.
        let layout = MailLayout.resolve(width: 700, isCompactSizeClass: false)

        #expect(layout.mode == .dual)
        #expect(layout.preferredColumnVisibility == .doubleColumn)
    }

    @Test("an 11-inch iPad in portrait gets two panes, not three")
    func portrait() {
        #expect(MailLayout.resolve(width: 834, isCompactSizeClass: false).mode == .dual)
    }

    @Test("a 13-inch iPad in landscape gets three panes")
    func landscape() {
        let layout = MailLayout.resolve(width: 1366, isCompactSizeClass: false)

        #expect(layout.mode == .triple)
        #expect(layout.preferredColumnVisibility == .all)
    }

    @Test("the thresholds are inclusive at the bottom")
    func boundaries() {
        #expect(
            MailLayout.resolve(width: MailLayout.dualThreshold, isCompactSizeClass: false).mode
                == .dual)
        #expect(
            MailLayout.resolve(width: MailLayout.dualThreshold - 1, isCompactSizeClass: false)
                .mode == .single)
        #expect(
            MailLayout.resolve(width: MailLayout.tripleThreshold, isCompactSizeClass: false).mode
                == .triple)
        #expect(
            MailLayout.resolve(width: MailLayout.tripleThreshold - 1, isCompactSizeClass: false)
                .mode == .dual)
    }

    @Test("an unmeasured width falls back to the size class rather than to one pane")
    func unmeasured() {
        // Zero is the first frame, before any geometry has been reported.
        // Guessing `.single` there would flash a collapsed layout on an iPad
        // every cold launch.
        #expect(MailLayout.resolve(width: 0, isCompactSizeClass: false).mode == .triple)
        #expect(MailLayout.resolve(width: 0, isCompactSizeClass: true).mode == .single)
    }

    @Test("panes are only separated where more than one is on screen")
    func separation() {
        #expect(MailLayout.resolve(width: 320, isCompactSizeClass: true).isSeparated == false)
        #expect(MailLayout.resolve(width: 700, isCompactSizeClass: false).isSeparated)
        #expect(MailLayout.resolve(width: 1366, isCompactSizeClass: false).isSeparated)
    }

    @Test("search results replace the sidebar only when there is no second column")
    func searchPlacement() {
        #expect(
            MailLayout.resolve(width: 390, isCompactSizeClass: true).placesSearchResultsInSidebar)
        #expect(
            MailLayout.resolve(width: 700, isCompactSizeClass: false)
                .placesSearchResultsInSidebar == false)
    }

    @Test("the floating compose button survives on a phone and stands down on iPad")
    func composePlacement() {
        // A phone: floating, thumb-reachable, and where it has always been.
        #expect(MailLayout.resolve(width: 393, isCompactSizeClass: true).usesFloatingCompose)
        // An iPhone SE, which is exactly as wide as a Slide Over panel. It
        // keeps the button, because taking it away from every small phone to
        // tidy up a Slide Over is the wrong trade.
        #expect(MailLayout.resolve(width: 320, isCompactSizeClass: true).usesFloatingCompose)
        // Two panes and up: it belongs in the list column's toolbar.
        #expect(
            MailLayout.resolve(width: 700, isCompactSizeClass: false).usesFloatingCompose
                == false)
        #expect(
            MailLayout.resolve(width: 1366, isCompactSizeClass: false).usesFloatingCompose
                == false)
    }

    @Test("the sidebar becomes a rail where a reader would be squeezed out")
    func sidebarRail() {
        // An 11-inch iPad upright. 224 for a named sidebar plus 404 for the
        // list leaves the reader 169 points, which is not a reader — so the
        // sidebar goes down to its 56pt rail and the list gives back 84.
        let narrow = MailLayout.resolve(width: 834, isCompactSizeClass: false)
        #expect(narrow.usesSidebarRail)
        #expect(narrow.listWidth == 320)
        // 834 - 56 - 320 - four gutters, which leaves the reader over 400.
        #expect(834 - 56 - narrow.listWidth - 48 > 400)

        // A 13-inch iPad upright has room for the names.
        let wide = MailLayout.resolve(width: 1032, isCompactSizeClass: false)
        #expect(wide.usesSidebarRail == false)
        #expect(wide.listWidth == 404)

        // A phone has one pane at a time and no sidebar beside it to shrink.
        #expect(MailLayout.resolve(width: 393, isCompactSizeClass: true).usesSidebarRail == false)
    }

    @Test("a view tree with no MailView above it assumes one pane")
    func standalone() {
        #expect(MailLayout.standalone.isSeparated == false)
        #expect(MailLayout.standalone.usesFloatingCompose)
    }
}
