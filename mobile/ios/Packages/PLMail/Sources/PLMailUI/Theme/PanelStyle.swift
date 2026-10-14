import SwiftUI

/// How the app's surfaces are separated.
///
/// On a phone there is one pane at a time and the system's own chrome does all
/// the separating. On a tablet three panes sit side by side, and a single
/// hairline between them reads as one wide document rather than three regions
/// with different jobs — so on regular width each pane becomes its own inset,
/// rounded surface with real space around it.
///
/// Kept here rather than spelled out per view so the radius and the inset
/// cannot drift between the list and the reader, which is exactly the kind of
/// difference that is invisible in isolation and obvious side by side.
enum PanelStyle {
    /// The redesign's pane radius (was 20). 12 is what the mock draws on every
    /// pane, and it is deliberately *not* the control radius — panes are
    /// panes. Kept here so the list, the reader and `messageCard()` cannot
    /// disagree, and so `ResolvedTheme.paneRadius(fromRem:)` keeps anchoring
    /// the server's default rem to whatever this app actually draws.
    static let cornerRadius: CGFloat = 12

    /// Space between panes, and between a pane and the window edge (was 10).
    /// The mock uses 12 for both the window padding and the inter-pane gap.
    /// ``PaneColumn`` derives *both* the content insets and the card's own
    /// margins from this one number — change it anywhere else and the row
    /// content runs past the card edge.
    static let inset: CGFloat = 12

    /// The margin every column keeps against the *window*, as one number.
    ///
    /// The gaps *between* panes were already one value — ``PaneColumn`` splits
    /// ``inset`` in half and the facing halves sum back to it. The outer edges
    /// were not: the sidebar is flat and was read as flush to the screen, the
    /// list showed a card at 12, and the reader's own edge was hidden behind a
    /// navigation bar the system lays out in the column's *full* bounds rather
    /// than inside the pane's padding. Three different numbers on the three
    /// edges that face the user's screen is what stopped the columns reading as
    /// one app.
    ///
    /// Named separately from ``inset`` even though it is the same value,
    /// because the two answer different questions — "how far apart are two
    /// panes" and "how far in from the screen does the app start" — and the
    /// day one of them moves, the other must not follow silently. Read by
    /// ``PaneColumn`` for the window-facing edge of every column, including the
    /// de-carded sidebar's.
    static let outerMargin: CGFloat = inset

    /// The pane itself, and the window behind it.
    ///
    /// Drawn rather than taken from `systemGroupedBackground`, because the
    /// system's light grouped pair is a cool neutral grey and mail read on it
    /// all day looks like a spreadsheet. Paper is warm; these are the same two
    /// steps of the grouped idea — card lighter than window — moved a few
    /// points towards yellow so the list reads as a page rather than a table.
    ///
    /// Dark keeps the near-black the system uses. Warming a dark background
    /// does not read as paper, it reads as a colour cast, and it eats the
    /// contrast the muted avatars need.
    /// The light pane, stated as a ``Swatch`` rather than a `Color` so the
    /// contrast suite can measure it.
    ///
    /// Now the server's own paper pair — surface `#f7f5ef`, window `#f2efe7` —
    /// per the redesign spec, which asked for the mock's hexes verbatim. The
    /// old values were within three points of these; stating the server's
    /// exactly is what stops the phone and the browser disagreeing about what
    /// paper looks like. The two are close: `PaneSurfaceTests` asserts the
    /// pair still separates (≥ 1.05:1), so a further nudge of either one must
    /// keep that gap or the iPad layout loses its columns.
    ///
    /// **Dark is untouched.** The mock draws light only; repainting dark from
    /// an undrawn design would be inventing values (coordinator's decision,
    /// spec Q7).
    static let surfaceLight = Swatch(247 / 255, 245 / 255, 239 / 255)
    static let surfaceDark = Swatch(0.086, 0.086, 0.090)
    static let windowLight = Swatch(242 / 255, 239 / 255, 231 / 255)
    static let windowDark = Swatch(0, 0, 0)

    /// plMail's own accent, `#7d6b4f`.
    ///
    /// **The server's default, not a colour invented here.** It is what
    /// `Appearance::DEFAULT_ACCENT` seeds and what the web draws before a user
    /// picks anything, so a phone that chose its own would disagree with the
    /// browser on every fresh account. It is also what `App/Assets.xcassets`
    /// carries as `AccentColor`, which is what stops `Color.accentColor`
    /// resolving to system blue — a warm cream app with iOS blue checkmarks in
    /// it looks like an app that forgot to finish.
    static let defaultAccent = Swatch(hex: "#7d6b4f") ?? Swatch(0.49, 0.42, 0.31)

    /// The same accent for a near-black surface, `#c2a67e`.
    ///
    /// **Stated rather than derived, because deriving it repaints dark mode.**
    /// `AccentColor.colorset` has always carried this as its dark variant, so
    /// it is what every `Color.accentColor` in the app has been drawing since
    /// the asset landed. Walking ``defaultAccent`` up to the palette's 4.5:1
    /// floor instead stops at the first passing step — a dull `#9a8c76` — which
    /// is legible and visibly not the colour that ships. Naming it here is what
    /// lets views start reading ``ThemePalette/accent`` without anyone noticing
    /// a change in the default theme, which is the whole point of this pass.
    static let defaultAccentDark = Swatch(hex: "#c2a67e") ?? Swatch(0.76, 0.65, 0.49)

    static let surface = Color(light: surfaceLight.color, dark: surfaceDark.color)
    static let window = Color(light: windowLight.color, dark: windowDark.color)

    /// The rule between rows, and anywhere else one surface abuts another.
    ///
    /// Low enough to be felt rather than read: its job is to stop two rows
    /// merging, not to draw a grid. `.separator` is too dark on cream and too
    /// light on near-black, so both ends are stated.
    ///
    /// Light is now **ink at 9%** — the mock's `rgba(35,34,32,.09)` — rather
    /// than the old near-brown at 10%. The hue is the point, not the point of
    /// opacity: a rule mixed from a browner ink than the text it separates
    /// reads warm beside a hairline drawn from ``ThemePalette/line``, and the
    /// two sit within a few pixels of each other in every list. **Dark is
    /// untouched** (see ``surfaceLight``).
    static let hairline = Color(
        light: inkLight.color.opacity(0.09),
        dark: Color.white.opacity(0.08)
    )

    /// The light theme's ink, `#232220`, as the mock states it.
    ///
    /// Stated here as well as in ``ThemePalette/light`` because the hairline
    /// and the pane border are tints *of the ink* and are drawn by views that
    /// have no palette in hand. Same number, one place to change it.
    static let inkLight = Swatch(35 / 255, 34 / 255, 32 / 255)

    /// The 1px edge around a pane, ink at 10% (`rgba(35,34,32,.10)`).
    ///
    /// **New in the redesign, and it is doing the job the shadow used to do
    /// alone.** The old pane was a surface three per cent lighter than the
    /// window with a fairly heavy black shadow under it; softening that shadow
    /// to the mock's two faint ink-tinted ones (see ``MailPane``) leaves the
    /// card's edge undefined on a bright screen, which is how a pane stops
    /// reading as an object. The border restores the edge without drawing the
    /// vertical rule between columns that this layout exists to avoid — it is
    /// a closed outline, not a divider.
    ///
    /// Dark takes the value dark already draws for ``hairline`` rather than a
    /// new one: the mock draws light only, and a pane in dark mode needs the
    /// same edge for the same reason, so borrowing the appearance's existing
    /// rule is the change that invents nothing (spec Q7).
    static let paneBorder = Color(
        light: inkLight.color.opacity(0.10),
        dark: Color.white.opacity(0.08)
    )

    /// The pane's shadow, as the mock's two layers.
    ///
    /// Was one `.black.opacity(0.10) radius 8 y2`. Black under a warm cream
    /// window greys the gutter; the mock tints both layers with the ink
    /// (`rgba(35,34,32,.05)`) and splits them into a wide, low one and a tight
    /// contact one, which is what makes a 12pt card look laid on the paper
    /// rather than floating over it. CSS blur radius is roughly twice
    /// SwiftUI's, so `12px`/`4px` become 6 and 2 here.
    ///
    /// Dark stays black at the same 5%. Warming a shadow on a near-black
    /// window is the colour cast the surfaces already refuse, and 5% twice is
    /// within a point of the single 10% dark used to draw — so dark keeps the
    /// weight it had while both appearances keep one shadow recipe.
    static let paneShadow = Color(light: inkLight.color.opacity(0.05), dark: .black.opacity(0.05))
}

extension Color {
    /// One token, both appearances.
    ///
    /// SwiftUI has no literal for this — `Color(light:dark:)` does not exist —
    /// and an asset catalogue entry for four colours would put the values
    /// somewhere nobody reading this file would look for them.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(
            uiColor: UIColor { traits in
                UIColor(traits.userInterfaceStyle == .dark ? dark : light)
            })
        #else
        self = light
        #endif
    }
}

#if os(iOS)

extension View {
    /// Drops a label's text, conditionally.
    ///
    /// `.labelStyle(flag ? .iconOnly : .automatic)` does not compile — the two
    /// styles are different types and the ternary has nowhere to land. This is
    /// the branch-on-the-view form, which does.
    @ViewBuilder
    func iconOnly(when condition: Bool) -> some View {
        if condition {
            labelStyle(.iconOnly)
        } else {
            self
        }
    }

    /// One message in a conversation, as its own card.
    ///
    /// A thread used to be one continuous column with hairlines between
    /// messages, which made a five-message conversation read as one very long
    /// message with odd rules through it. Cards say "these are separate things"
    /// without a single divider, and give the collapsed rows an obvious edge to
    /// be tappable within.
    ///
    /// The radius is the pane radius, not the control one: a message is a
    /// surface, and matching the panes it sits inside is what keeps the reader
    /// from looking like a list of buttons.
    ///
    /// A modifier rather than a `@ViewBuilder` function because the fill is now
    /// the theme's ``ThemePalette/surface``, and a free function on `View` has
    /// no environment to read it from.
    func messageCard() -> some View {
        modifier(MessageCard())
    }

    /// Makes this pane a distinct surface on a wide layout, and leaves it
    /// alone on a narrow one.
    ///
    /// The compact case is not an oversight: insetting a full-screen pane on a
    /// phone would waste the only width there is and leave a rounded rectangle
    /// floating on a background nobody can see around it.
    ///
    /// A modifier rather than a `@ViewBuilder` function because the radius is
    /// now the theme's: the server's `radius` reaches panes and only panes, and
    /// a free function on `View` has no environment to read it from.
    func mailPane(isSeparated: Bool, column: PaneColumn = .middle) -> some View {
        modifier(MailPane(isSeparated: isSeparated, column: column))
    }
}

/// One message card, filled from the theme rather than from a fixed cream.
///
/// **The radius stays ``PanelStyle/cornerRadius`` and is deliberately not the
/// theme's.** The server's `radius` is documented as reaching panes and only
/// panes; a message is a card *inside* a pane, and letting a 2.0rem radius
/// through here would round a collapsed row into a lozenge.
///
/// An unpopulated ``EnvironmentValues/theme`` is ``ResolvedTheme/placeholder``,
/// whose light and dark surfaces are ``PanelStyle/surfaceLight`` and
/// ``PanelStyle/surfaceDark`` verbatim — so a card in a preview, or under a
/// root that never injected a theme, draws the cream it always did rather than
/// nothing.
private struct MessageCard: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let surface = theme.palette(for: colorScheme).surface.color

        return
            content
            .clipShape(.rect(cornerRadius: PanelStyle.cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                    .fill(surface)
            }
    }
}

/// The pane treatment, with the theme's corner radius and surfaces applied.
///
/// Split out of ``SwiftUI/View/mailPane(isSeparated:)`` so it can hold an
/// `@Environment` — an unpopulated one is ``ResolvedTheme/placeholder``, whose
/// `paneCornerRadius` is ``PanelStyle/cornerRadius`` and whose surfaces are
/// ``PanelStyle``'s own, so a pane outside the injected tree keeps the 20pt and
/// the cream everybody has been looking at.
///
/// The appearance is read from the environment rather than baked in with
/// `Color(light:dark:)`: a themed palette has one surface, not a pair, and
/// `ThemeChoice` already forces the appearance a theme is drawn in — so
/// resolving here is what keeps nord's slate from being handed to a
/// light-appearance trait collection and coming out as cream.
/// Which of the split view's columns a pane is, so its margins can differ.
///
/// **The outer edges are not gutters.** The gap *between* two panes is the sum
/// of their facing margins, so each contributes half; but the gap between the
/// first pane and the window is that pane's margin alone, and halving it there
/// pulls the sidebar towards the screen edge and makes the border look wrong.
public enum PaneColumn: Sendable {
    case leading
    case middle
    case trailing

    /// Full margin against the window, half against another pane.
    ///
    /// The window-facing case reads ``PanelStyle/outerMargin`` rather than
    /// ``PanelStyle/inset`` so the three outer edges are one stated number —
    /// see there.
    var leadingInset: CGFloat {
        self == .leading ? PanelStyle.outerMargin : PanelStyle.inset / 2
    }

    var trailingInset: CGFloat {
        self == .trailing ? PanelStyle.outerMargin : PanelStyle.inset / 2
    }
}

private struct MailPane: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let isSeparated: Bool
    let column: PaneColumn

    @ViewBuilder
    func body(content: Content) -> some View {
        let palette = theme.palette(for: colorScheme)

        if isSeparated {
            content
                // Inset to match the card behind it. The card is drawn as a
                // *background* with its own padding, so without this the
                // content — a sidebar row and its selection highlight most
                // visibly — runs past the card's edge and the pane stops
                // looking like one. The vertical inset is deliberately not
                // applied: the bar has to reach the top of the card.
                .padding(.leading, column.leadingInset)
                .padding(.trailing, column.trailingInset)
                // The navigation bar is part of the pane, not something
                // sitting above it. Left opaque, it draws its own surface
                // across the top and the card appears to start below the
                // title — which reads as a layout bug rather than a card.
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .background {
                    ZStack {
                        // Painted per column, edge to edge. A background set on
                        // the split view itself never shows: each column draws
                        // its own opaque fill over it, so the gutter comes out
                        // the colour of the panes and the split view's 1px
                        // column separator is the only thing visible in it —
                        // which is the vertical rule this layout is trying not
                        // to have. Filling the column's own bounds puts the
                        // window colour where that rule was.
                        palette.window.color

                        // The shape is inset and *then* told to ignore the safe
                        // area, so the card reaches up behind the bar and out
                        // to the window edge while keeping its margin. Padding
                        // the content instead would leave the bar stranded
                        // outside.
                        RoundedRectangle(
                            cornerRadius: theme.paneCornerRadius, style: .continuous
                        )
                        // The surface reads about three per cent lighter than
                        // the window, which on a device is not enough to say
                        // "these are separate objects" — the columns looked
                        // like one sheet with gaps cut in it.
                        //
                        // Three things now say it, and each covers where the
                        // others fail: a 1px ink border, which is the only one
                        // that survives a bright screen; a wide, low shadow
                        // that puts the card above the paper; and a tight
                        // contact shadow that stops the wide one reading as a
                        // blur. The border is a closed outline around a pane,
                        // never a divider between two — the vertical rule this
                        // layout exists to avoid is still nobody's.
                        .fill(palette.surface.color)
                        .stroke(PanelStyle.paneBorder, lineWidth: 1)
                        .shadow(color: PanelStyle.paneShadow, radius: 6, y: 3)
                        .shadow(color: PanelStyle.paneShadow, radius: 2, y: 1)
                        .padding(.vertical, PanelStyle.inset)
                        // Asymmetric by column: full against the window, half
                        // against another pane. See ``PaneColumn``.
                        .padding(.leading, column.leadingInset)
                        .padding(.trailing, column.trailingInset)
                    }
                    .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}

extension View {
    /// The card the design draws every pane on: the surface colour, the
    /// twelve-point radius, a hairline border and the two-step shadow.
    ///
    /// One modifier rather than the same six lines in three places — the mail
    /// card, the docked calendar and the calendar screen are the *same* object
    /// in the design, and three copies is three chances for one of them to
    /// grow a different radius.
    /// The theme, on a `Form` or a `List` inside a sheet.
    ///
    /// A `Form` paints itself out of the system's own materials, so a sheet
    /// presented over a Paper mailbox came up grey-and-white — which is exactly
    /// what "it feels like opening a different app" was about. Injecting the
    /// theme into the sheet is not enough on its own; the scroll background has
    /// to go and the tokens have to take its place.
    ///
    /// **The row background belongs on the sections, not here.** A
    /// `listRowBackground` set on the container does not reach the rows, and
    /// half-themed reads worse than not themed at all — so each screen applies
    /// it to its own content and this modifier only does the parts that work
    /// from outside.
    func themedFormSurface(_ palette: ThemePalette) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(palette.window.color)
            .toolbarBackground(palette.surface.color, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }

    func paneSurface(_ palette: ThemePalette) -> some View {
        self
            .background(palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                    .strokeBorder(PanelStyle.paneBorder, lineWidth: 1)
            }
            .shadow(color: PanelStyle.paneShadow, radius: 6, y: 3)
            .shadow(color: PanelStyle.paneShadow, radius: 2, y: 1)
    }
}

#endif
