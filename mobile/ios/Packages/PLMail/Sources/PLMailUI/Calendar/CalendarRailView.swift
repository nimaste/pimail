#if os(iOS)

public import PLMailCore

import SwiftUI

/// The calendar's own sidebar, on a canvas wide enough for three panes.
///
/// It exists to take two things out of a menu and put them on the screen: which
/// calendars are drawn, and where "today" is. Both are state a person changes
/// repeatedly while reading a month, and both were behind a `Menu` because a
/// phone has nowhere else to put them.
///
/// **Only ever one of the two.** Where this rail is on screen the toolbar menu
/// stops offering the same toggles, because two controls for one piece of state
/// is how they drift apart — the same argument that took the duplicate Calendar
/// button out of `MailView`'s toolbar.
struct CalendarRailView: View {
    let service: CalendarService
    @Binding var mode: CalendarViewMode
    let onToday: () -> Void

    var body: some View {
        List {
            Section {
                Button(action: onToday) {
                    Label(.ui("Today"), systemImage: "calendar.badge.clock")
                }
                .buttonStyle(.plain)
            }

            Section {
                ForEach(CalendarViewMode.allCases, id: \.self) { choice in
                    Button {
                        mode = choice
                    } label: {
                        Label {
                            Text(CalendarModeName.text(choice))
                        } icon: {
                            Image(systemName: symbol(of: choice))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        mode == choice
                            ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(.primary)
                    )
                    .accessibilityAddTraits(
                        mode == choice ? [.isButton, .isSelected] : .isButton)
                }
            } header: {
                Text(.ui("View"))
            }

            if service.calendars.isEmpty == false {
                Section {
                    ForEach(service.calendars) { calendar in
                        row(calendar)
                    }
                } header: {
                    Text(.ui("Calendars"))
                } footer: {
                    // The one place the local/server distinction can be stated
                    // without a paragraph in a menu. `isVisible` is a *server*
                    // preference and this toggle is not it: filtering the query
                    // by it would hide from a phone what its user chose to hide
                    // in a browser, which the server's own docblock forbids.
                    Text(.ui("Hiding a calendar here changes nothing on the server."))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ calendar: CalendarSnapshot) -> some View {
        let isShown = service.isShown(calendar)

        return Button {
            Task { await service.setHidden(isShown, calendar: calendar.calendarID) }
        } label: {
            HStack(spacing: 8) {
                // The swatch is decoration. The tick is what says whether the
                // calendar is drawn, because a calendar with no `color` would
                // otherwise have no visible state at all — colour is never the
                // only carrier of meaning here.
                RoundedRectangle(cornerRadius: 3)
                    .fill(CalendarTheme.edge(calendar.colorHex))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)

                Text(calendar.name)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isShown {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(calendar.name)
        // Tri-state read aloud, because a tick is invisible and "shown" is the
        // whole meaning of the row.
        .accessibilityValue(isShown ? Text(.ui("Shown")) : Text(.ui("Hidden")))
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
    }

    private func symbol(of mode: CalendarViewMode) -> String {
        switch mode {
        case .agenda: "list.bullet"
        case .day: "calendar.day.timeline.left"
        case .week: "calendar"
        case .month: "square.grid.3x3"
        case .year: "square.grid.4x3.fill"
        }
    }
}

/// What each mode is called, in one place.
///
/// The rail, the segmented control and the menu all name the same five modes,
/// and three copies of the same switch is three chances for one of them to say
/// something the keyboard shortcut does not.
enum CalendarModeName {
    static func text(_ mode: CalendarViewMode) -> LocalizedStringResource {
        switch mode {
        case .agenda: .ui("Agenda")
        case .day: .ui("Day")
        case .week: .ui("Week")
        case .month: .ui("Month")
        case .year: .ui("Year")
        }
    }
}

#endif
