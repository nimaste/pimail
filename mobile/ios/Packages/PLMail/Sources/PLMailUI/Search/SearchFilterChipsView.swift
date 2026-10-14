#if os(iOS)

import PLMailCore
import SwiftUI

/// Quick narrowings offered over the results.
///
/// Each chip writes its operator into the query text rather than filtering
/// behind it, so tapping "Unread" makes an `is:unread` token appear in the bar
/// below and the words `is:unread` appear in the field. That is the point: this
/// search field's one real virtue is showing people how their query was read,
/// and a chip that narrowed invisibly would undo it.
///
/// The chips sit above ``SearchTokensView`` and are the same shape as its
/// tokens on purpose — one is what you can add, the other is what was
/// understood, and they are meant to read as one row of the same material.
struct SearchFilterChipsView: View {
    let query: ParsedSearchQuery

    /// Called with the rewritten query. The caller owns the field's text.
    let onChange: (String) -> Void

    /// The current field contents, which the edits are applied to.
    let raw: String

    /// `.tint(_:)` takes a concrete style, so the accent is read here rather
    /// than resolved at the call site the way ``ThemeAccent`` does elsewhere.
    @Environment(\.theme) private var theme
    /// Passed to ``ResolvedTheme/accentColor(in:)`` per draw. One resolved
    /// theme serves both appearances, so the scheme cannot be baked into it.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(SearchFilterChip.allCases) { chip in
                    let isOn = SearchQueryEditor.isActive(chip, in: query)

                    Button {
                        onChange(SearchQueryEditor.toggling(chip, in: raw))
                    } label: {
                        Label(chip.title, systemImage: chip.symbolName)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    // Tinted only when on. A row of chips that are all
                    // prominent gives no signal about which are doing anything.
                    .tint(isOn ? theme.accentColor(in: colorScheme) : .secondary)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }

                dateMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    /// The date range, which needs a value and so is a menu rather than a
    /// toggle.
    private var dateMenu: some View {
        let active = SearchQueryEditor.activePreset(in: query)

        return Menu {
            ForEach(SearchDatePreset.allCases) { preset in
                Button {
                    onChange(SearchQueryEditor.settingAfter(preset.date(), in: raw))
                } label: {
                    // A tick rather than a separate "selected" style, so the
                    // menu says which one is on when it is opened again.
                    Label(
                        preset.title,
                        systemImage: active == preset ? "checkmark" : "calendar")
                }
            }

            // Only offered when there is something to clear. "Any time" on a
            // query with no date bound is a button that does nothing.
            if query.after != nil {
                Divider()

                Button(.ui("Any time"), systemImage: "xmark") {
                    onChange(SearchQueryEditor.settingAfter(nil, in: raw))
                }
            }
        } label: {
            Label(active?.title ?? String(localized: .ui("Any time")), systemImage: "calendar")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(active == nil ? .secondary : theme.accentColor(in: colorScheme))
    }
}

#endif
