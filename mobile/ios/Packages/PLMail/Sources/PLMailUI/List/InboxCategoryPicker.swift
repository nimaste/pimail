#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Which slice of the inbox is on screen, and how to change it.
///
/// **Deliberately not Android's tab strip.** `CategoryBundleRow.kt` puts sunken
/// tiles inside the list because Compose's sidebar is a drawer behind a
/// hamburger — the bundles are solving a navigation problem iOS does not have.
/// Nor is this a second navigation axis: a category is the inbox with a
/// condition on it, so it belongs where the other things that narrow a list
/// already live, not as a sibling of Inbox and Sent.
///
/// **One presentation now, on both idioms.** The strip is drawn wherever the
/// list is — the redesign puts it on the phone too, because a category is the
/// first thing people reach for on a screen that shows five rows, and the
/// version that hid it behind the overflow menu made the tabs invisible to
/// anyone who had not already found them. It is a strip of underline tabs
/// rather than capsules: an underline is the lightest mark that can say "this
/// one", which is what lets a permanent control sit above the rows without
/// competing with them for the eye.
///
/// ``menu(selection:)`` remains for anywhere the choices have to appear as
/// menu items, and drives the same binding, so the two cannot come to disagree
/// about what is showing.
struct InboxCategoryPicker: View {
    /// Nil is **All**, not Primary.
    ///
    /// A conversation the classifier never saw belongs to no tab, exactly as
    /// the web UI's own inbox query has it. If nil meant Primary, the unnarrowed
    /// inbox would be unreachable and mail predating the classifier would
    /// vanish from the phone while still sitting in the browser's inbox.
    @Binding var selection: MessageCategory?

    /// Drawn as a strip when true and left to ``menu`` when false.
    let isStrip: Bool
    /// How many unread conversations sit under each tab. Empty until the first
    /// count lands, and a category missing from it has none — a tab that said
    /// "0" would be a tab claiming to have been counted when it has not.
    var unreadCounts: [MessageCategory: Int] = [:]

    /// The tab strip's own ground and its underline both come from the
    /// palette, so the strip separates from the rows below it on every theme
    /// rather than only on paper.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    var body: some View {
        if isStrip { strip }
    }

    /// The tabs.
    ///
    /// Horizontally scrolling rather than a `Picker(.segmented)`: five segments
    /// in a 396pt column are 79pt each, and German's "Werbung" and "Soziales"
    /// truncate inside them at the default text size, never mind an
    /// accessibility one. Tabs size to their words instead, so a longer
    /// language costs a scroll rather than a truncation — which is what makes
    /// the same strip usable on a 390pt phone.
    /// The tabs the design draws: four, filling the width, never scrolling.
    ///
    /// **No "All mail" tab and no Forums.** Forums is always empty on this
    /// server, and an always-empty tab teaches people to distrust the others.
    /// "All mail" is not a category — the unnarrowed inbox is what the Inbox row
    /// already means, so it is reached by tapping the chosen tab again rather
    /// than by spending a sixth of the strip on it. That also keeps mail the
    /// classifier has not labelled reachable, which a strip of categories alone
    /// would hide.
    ///
    /// Fixed widths rather than a scroll view: four tabs fit 404pt, and a strip
    /// that can be dragged is a strip that moves when somebody meant to scroll
    /// the list under it.
    static let shownCategories: [MessageCategory] = [.primary, .social, .promotions, .updates]

    /// One rendering of the whole row, so every tab gives the same things up.
    ///
    /// **The choice belongs to the row, not to the tab.** Asking each tab
    /// separately whether it fits produced a strip where Updates kept its icon
    /// and its three neighbours had dropped theirs — every tab was right and
    /// the row looked broken.
    private func tabsRow(size: CGFloat, showsIcon: Bool, allowsScaling: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.shownCategories, id: \.self) { category in
                tab(for: category, size: size, showsIcon: showsIcon, allowsScaling: allowsScaling)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var strip: some View {
        // **A tab may not truncate.** "Prim… 41" names nothing and "Pro… 1…"
        // is worse — it truncates the number, which is the half people are
        // actually reading. Four tabs across a 335pt list give each of them 84
        // points, and "Promotions 1,204" has never fitted in 84 points at any
        // size worth reading.
        //
        // So the row gives things up in order and `ViewThatFits` takes the
        // first that survives the width it was handed: the icon first, because
        // the word beside it says the same thing, then the size, down to
        // eleven points. The last candidate is allowed to shrink its text
        // because it is the one that gets used when nothing fits, and a tab
        // squeezed to 90% still reads where an ellipsis does not.
        ViewThatFits(in: .horizontal) {
            tabsRow(size: 13, showsIcon: true, allowsScaling: false)
            tabsRow(size: 13, showsIcon: false, allowsScaling: false)
            tabsRow(size: 12, showsIcon: false, allowsScaling: false)
            tabsRow(size: 11, showsIcon: false, allowsScaling: true)
        }
        // The strip's own ground, a shade under the pane, with a hairline
        // closing it off — the mock's `ink @ 4%` on a rule, which is
        // ``ThemePalette/sunken`` and ``PanelStyle/hairline``.
        .background(palette.sunken.color)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PanelStyle.hairline)
                .frame(height: 1)
        }
        // `.contain`, never `.combine`: combining folds the tabs into one
        // sentence and leaves VoiceOver with no way to press any of them.
        .accessibilityElement(children: .contain)
    }

    /// One rendering of a tab's contents, at a given size and with or without
    /// its icon. Sized to its own content so ``ViewThatFits`` can ask whether
    /// it survives — a label that compressed itself would always "fit" and the
    /// first candidate would always win.
    private func label(
        _ category: MessageCategory?, isChosen: Bool, size: CGFloat, showsIcon: Bool,
        allowsScaling: Bool
    ) -> some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: category?.symbolName ?? "tray.2")
                    .font(.system(size: size - 2))
            }

            Text(Self.title(of: category))
                .font(.system(size: size, weight: isChosen ? .semibold : .regular))

            if let category, let count = unreadCounts[category] {
                // Bolder than the name beside it, always — the number is the
                // thing that changed since you last looked, and the word never
                // is. Compact above a thousand: "1.2K" is three characters of
                // width for the one fact a four-digit count carries.
                Text(verbatim: count.formatted(.number.notation(.compactName)))
                    .font(.system(size: size, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(allowsScaling ? 0.75 : 1)
        // Natural width, so the row's ideal size is the sum of its tabs' — and
        // `ViewThatFits` is comparing something real against the width it has.
        // A tab that compressed itself would always "fit" and the first
        // candidate would always win.
        .fixedSize(horizontal: allowsScaling == false, vertical: false)
        .padding(.horizontal, 4)
    }

    /// A scroll id for a choice, with nil given a name of its own.
    ///
    /// `Optional` is `Hashable`, but `scrollTo` matches on an existential and a
    /// nil id silently matches nothing — the strip would simply never scroll,
    /// with no error anywhere to say why.
    private static func id(of category: MessageCategory?) -> String {
        category?.rawValue ?? "all"
    }

    /// One tab: icon, name, and a 2pt accent rule under the chosen one.
    ///
    /// The underline is drawn on every tab and merely goes clear when the tab
    /// is not chosen, so choosing one moves nothing — a rule that appears only
    /// when active would make the whole strip jump by two points on every tap,
    /// and the tab under the finger would be the one that moved.
    ///
    /// The chosen tab is also accent-coloured and medium-weight. Colour alone
    /// would fail anyone who cannot pick the accent out of the ink; the
    /// underline is the mark that does not depend on seeing a hue.
    private func tab(
        for category: MessageCategory?, size: CGFloat, showsIcon: Bool, allowsScaling: Bool
    ) -> some View {
        let isChosen = selection == category

        return Button {
            // Tapping the chosen tab again clears the narrowing. With no
            // "All mail" tab this is the only route back to the whole inbox,
            // and to mail the classifier gave no category at all.
            selection = isChosen ? nil : category
        } label: {
            VStack(spacing: 6) {
                label(
                    category, isChosen: isChosen, size: size, showsIcon: showsIcon,
                    allowsScaling: allowsScaling
                )
                .padding(.top, 9)

                Rectangle()
                    .fill(isChosen ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(.clear))
                    .frame(height: 2)
            }
            .foregroundStyle(
                isChosen ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(palette.inkMuted.color)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(Self.id(of: category))
        .hoverEffect(.highlight)
        // Said as a sentence rather than left as "Promotions, 3" — a bare
        // number after a tab name is as likely to be read as a position in the
        // strip as a count of anything.
        .accessibilityLabel(
            {
                guard let category, let count = unreadCounts[category] else {
                    return Text(Self.title(of: category))
                }

                return Text(Self.title(of: category)) + Text(verbatim: ", ")
                    + Text(.ui("\(count) unread"))
            }()
        )
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// The same six choices as menu items, for the phone.
    ///
    /// A `Picker` rather than six `Button`s so the checkmark and the
    /// single-choice semantics come from the system — a hand-rolled tick beside
    /// a menu row is a second answer to a question `Picker` already answers,
    /// and VoiceOver announces the real one.
    @ViewBuilder
    static func menu(selection: Binding<MessageCategory?>) -> some View {
        Picker(selection: selection) {
            Label(.ui("All mail"), systemImage: "tray.2").tag(MessageCategory?.none)

            ForEach(MessageCategory.allCases, id: \.self) { category in
                Label(category.displayName, systemImage: category.symbolName)
                    .tag(MessageCategory?.some(category))
            }
        } label: {
            Label(.ui("Categories"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .pickerStyle(.inline)
    }

    /// What a choice is called, with nil spelled out rather than left blank.
    ///
    /// The five names come from `PLMailCore` — they are list titles as well as
    /// capsule captions, and one word translated in two catalogues drifts. Only
    /// the sixth choice, which exists solely as a control, is this module's.
    static func title(of category: MessageCategory?) -> String {
        category?.displayName ?? String(localized: "All mail", bundle: .module)
    }
}

#endif
