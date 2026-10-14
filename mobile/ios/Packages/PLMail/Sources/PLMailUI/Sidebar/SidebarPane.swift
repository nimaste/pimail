#if os(iOS)

import SwiftUI

extension View {
    /// The sidebar's own pane treatment: flat on the window, never a card.
    ///
    /// The list and the reader are cards; the sidebar deliberately is not.
    /// Three cards side by side gave the mailboxes the same weight as the mail
    /// itself, and the redesign's aside sits directly on the window colour with
    /// nothing but its margins separating it — which is also what lets a
    /// selected row's pill reach the leading edge instead of stopping at a
    /// card's rounded corner.
    ///
    /// It still does the two things ``SwiftUI/View/mailPane(isSeparated:column:)``
    /// does that are not about the card:
    ///
    /// - **Paints the window colour per column, edge to edge.** A background
    ///   set on the split view itself never shows — each column draws its own
    ///   opaque fill over it — so without this the sidebar comes out in the
    ///   system's grouped grey beside two cream panes.
    /// - **Hides the navigation bar's background**, so the search field and the
    ///   title sit on the same flat window colour as the rows below them rather
    ///   than under an opaque band across the top.
    ///
    /// - Parameter isResident: Whether the sidebar is a column of its own. In
    ///   the dual layout the system presents it as a floating overlay with its
    ///   own panel material, and painting a window colour and margins inside
    ///   that fights the panel it is drawn on — so there, as on a phone, this
    ///   does nothing at all.
    /// - Returns: The sidebar on the window colour, with the pane margins —
    ///   or exactly what it was handed, where the sidebar is not a column.
    func sidebarPane(isResident: Bool) -> some View {
        modifier(SidebarPane(isResident: isResident))
    }
}

/// Split out of ``SwiftUI/View/sidebarPane(isResident:)`` so it can hold an
/// `@Environment` — an unpopulated one is ``ResolvedTheme/placeholder``, whose
/// window colours are ``PanelStyle``'s own, so a sidebar outside the injected
/// tree keeps the paper everybody has been looking at.
private struct SidebarPane: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let isResident: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isResident {
            content
                // The same asymmetric margins the cards use — full against the
                // window, half against the next pane — taken from
                // ``PaneColumn`` rather than restated, so the sidebar's gutter
                // and the list card's stay the one number.
                .padding(.leading, PaneColumn.leading.leadingInset)
                .padding(.trailing, PaneColumn.leading.trailingInset)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .background {
                    theme.palette(for: colorScheme).window.color
                        .ignoresSafeArea()
                }
        } else {
            content
        }
    }
}

#endif
