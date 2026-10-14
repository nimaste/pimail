#if os(iOS)

public import PLMailCore

import SwiftUI

/// The six-week month grid.
///
/// **Always 42 days**, never five-or-six, so paging through the year does not
/// change the grid's height under the reader's finger. The leading and trailing
/// part-weeks are real days with real events rather than padding, and they are
/// dimmed rather than blanked.
///
/// **Cells draw titled chips, not dots.** Android degrades to coloured dots
/// because a 411 dp phone cell fits about four characters; that is a phone
/// compromise and it is not inherited here. `MonthCellPlan` decides from the
/// **measured** cell — so a 13-inch iPad cell carries three or four chips, a
/// compact phone cell falls back to dots, and Slide Over or an accessibility
/// text size gets the same answer for the same reason rather than by idiom.
struct MonthGridView: View {
    let window: CalendarWindow
    let anchor: CalendarDay
    let clusters: [EventCluster]
    /// On a compact width the grid is half the screen and the selected day
    /// expands into a list below it — which is what iOS Calendar does, and what
    /// the web calls `month-agenda`.
    let isCompact: Bool
    @Binding var selection: CalendarDay?
    let onOpen: (EventCluster) -> Void
    /// Nil where no calendar on this server accepts a new event, which takes
    /// the hover affordance and the custom action away together — an affordance
    /// that appears and then refuses is worse than one that never appeared.
    var onCreate: ((CalendarDay) -> Void)?

    /// Which cell the pointer is over, for the hover highlight. Nil on a touch
    /// device, where nothing ever sets it.
    @State private var hovered: CalendarDay?

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var typeSize

    /// One chip's height at the current text size. Passed to `MonthCellPlan`
    /// rather than assumed, because a chip at `.accessibility3` is twice the
    /// height of one at `.medium` and a fixed row count would clip it.
    @ScaledMetric(relativeTo: .caption2) private var chipHeight: CGFloat = 16

    private var days: [CalendarDay] { window.days }

    private func contents(_ day: CalendarDay) -> [EventCluster] {
        let grid = DayGridLayout.place(clusters, on: day)

        return grid.allDay + grid.timed.map(\.cluster)
    }

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader

            GeometryReader { geometry in
                let cell = CGSize(
                    width: geometry.size.width / 7,
                    height: geometry.size.height / 6
                )

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7),
                    spacing: 1
                ) {
                    ForEach(days, id: \.self) { day in
                        cellView(day, size: cell)
                    }
                }
            }

            if isCompact, let selection {
                Divider()
                selectedDayList(selection)
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 1) {
            ForEach(days.prefix(7), id: \.self) { day in
                Text(CalendarHeading.day(day, template: "EEE", locale: locale, timeZone: timeZone))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
        // The column headings repeat the day name every chip already carries in
        // its own label; read aloud they are seven words before any content.
        .accessibilityHidden(true)
    }

    private func cellView(_ day: CalendarDay, size: CGSize) -> some View {
        let events = contents(day)
        let plan = MonthCellPlan(
            count: events.count,
            height: size.height - chipHeight - 6,
            width: size.width - 4,
            rowHeight: chipHeight
        )
        let isOutside = day.month != anchor.month

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(CalendarHeading.day(day, template: "d", locale: locale, timeZone: timeZone))
                    .font(.caption2)
                    .foregroundStyle(isOutside ? .tertiary : .primary)

                Spacer(minLength: 0)

                // **The pointer's create affordance**, and only the pointer's:
                // it appears under the cursor over an empty part of a cell and
                // is invisible on a touch device, where the toolbar's + on the
                // selected day is the same action. Hidden from VoiceOver
                // because the cell already carries "New event" as a custom
                // action — an icon that only exists while a mouse is over it is
                // not a control a reader can find.
                if hovered == day, onCreate != nil {
                    Image(systemName: "plus")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            if plan.chips > 0 {
                ForEach(events.prefix(plan.chips)) { cluster in
                    // A titled chip is a control. On the canvas that can afford
                    // chips, tapping one has to open that event rather than
                    // merely select its day — otherwise the large layout is two
                    // taps away from what the compact one does in one, which is
                    // the wrong way round.
                    Button {
                        onOpen(cluster)
                    } label: {
                        EventChipView(
                            cluster: cluster, density: .chip, showsTime: plan.showsStartTime)
                    }
                    .buttonStyle(.plain)
                }
            } else if plan.dots > 0 {
                HStack(spacing: 2) {
                    ForEach(Array(events.prefix(plan.dots).enumerated()), id: \.offset) { item in
                        Circle()
                            .fill(CalendarTheme.edge(item.element.representative.colourHex))
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityHidden(true)
            }

            if plan.overflow > 0 {
                Text(.ui("+\(plan.overflow) more"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: size.height, alignment: .topLeading)
        .padding(2)
        .background(
            ThemeAccent().opacity(cellTint(day)),
            in: .rect(cornerRadius: 6)
        )
        .contentShape(.rect)
        .onTapGesture { selection = day }
        .onHover { isInside in
            // Cleared by comparing rather than by writing nil unconditionally:
            // SwiftUI delivers the new cell's `true` before the old cell's
            // `false` often enough that the naive version leaves no cell
            // highlighted at all while the pointer moves.
            if isInside {
                hovered = day
            } else if hovered == day {
                hovered = nil
            }
        }
        // **One element per day**, with its events as children — not three
        // sibling elements a reader has to swipe past to reach the sixth.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            CalendarHeading.day(day, template: "EEEEdMMM", locale: locale, timeZone: timeZone)
                + ", " + String(localized: .ui("\(events.count) events"))
        )
        .accessibilityAddTraits(selection == day ? [.isButton, .isSelected] : .isButton)
        // The hover affordance's equal, for a reader who has no pointer.
        .createAction(onCreate, on: day)
    }

    /// How strongly a cell is tinted: selected, then hovered, then not at all.
    ///
    /// One function rather than two overlapping backgrounds, so a selected cell
    /// the pointer is also over does not stack two washes and read as a third
    /// state that means nothing.
    private func cellTint(_ day: CalendarDay) -> Double {
        if selection == day { return 0.12 }
        if hovered == day { return 0.06 }

        return 0
    }

    /// The compact month's lower half: a grid to scan above, a list to read
    /// below.
    private func selectedDayList(_ day: CalendarDay) -> some View {
        let events = contents(day)

        return Group {
            if events.isEmpty {
                ContentUnavailableView(
                    .ui("Nothing on this day"),
                    systemImage: "calendar"
                )
            } else {
                List(events) { cluster in
                    Button {
                        onOpen(cluster)
                    } label: {
                        EventChipView(cluster: cluster, density: .row)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxHeight: 260)
    }
}

extension View {
    /// "New event" on a day cell, **only where a calendar would accept one**.
    ///
    /// An unconditional custom action whose closure is nil is an action the
    /// rotor offers, the reader chooses, and nothing happens — which reads as
    /// the app having failed rather than as a right it does not have.
    @ViewBuilder
    fileprivate func createAction(
        _ action: ((CalendarDay) -> Void)?, on day: CalendarDay
    ) -> some View {
        if let action {
            accessibilityAction(named: Text(.ui("New event"))) { action(day) }
        } else {
            self
        }
    }
}

#endif
