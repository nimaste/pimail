#if os(iOS)

import JMAPKit
import PLMailCore
import SwiftUI

/// The sidebar, reduced to icons, for the layout that docks the calendar.
///
/// **Why a second view rather than a narrow `MailboxSidebarView`.** The full
/// sidebar's job is to name places — labels, accounts, counts — and at 56pt
/// none of those words fit. Squeezing it produces a column of truncated
/// nothing; the design instead drops to the handful of destinations that are
/// legible as marks alone and lets the mail and the calendar have the width.
/// Labels are still reachable, through the tag icon, as the sheet the phone
/// already uses.
struct SidebarRail: View {
    let sync: MailSyncService
    let compose: () -> Void
    let openLabels: () -> Void
    let openSettings: () -> Void
    @Binding var selection: FeedID?

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    /// The design's width. Stated here because the rail is the only thing that
    /// has to fit inside it.
    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            Button(action: compose) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(palette.accentInk.color)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ThemeAccent()))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.ui("New message")))
            .padding(.bottom, 6)

            ForEach(MailboxSidebarView.unifiedRoles(in: sync.mailboxes), id: \.self) { role in
                railButton(role)
            }

            Spacer(minLength: 0)

            Button(action: openLabels) {
                railIcon("tag", isChosen: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.ui("Edit labels")))

            Button(action: openSettings) {
                railIcon("gearshape", isChosen: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.ui("Settings")))
        }
        .frame(width: Self.width)
    }

    private func railButton(_ role: MailboxRole) -> some View {
        let feed = FeedID.unified(role)
        let isChosen = selection == feed
        let unread = sync.mailboxes.filter { $0.role == role }.reduce(0) { $0 + $1.unreadThreads }

        return Button {
            selection = feed
        } label: {
            railIcon(role.symbolName, isChosen: isChosen)
                .overlay(alignment: .topTrailing) {
                    // Only where a number is the reason to look. A badge on
                    // every mailbox is a badge on none of them.
                    if unread > 0 {
                        Text(verbatim: unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.accentInk.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(ThemeAccent()))
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: role.displayName))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private func railIcon(_ symbol: String, isChosen: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .frame(width: 40, height: 40)
            .foregroundStyle(
                isChosen ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(palette.inkSoft.color)
            )
            .background(
                Circle().fill(isChosen ? palette.accentSoft.color : .clear))
    }
}

#endif
