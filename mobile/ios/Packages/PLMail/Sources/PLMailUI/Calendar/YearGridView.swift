#if os(iOS)

public import PLMailCore

import SwiftUI

/// Twelve month grids at once.
///
/// **The one mode a large canvas is the entire point of**, and it degrades
/// rather than being withdrawn. The tiles are an *adaptive* grid, so a 13-inch
/// iPad gets four or five columns and a narrow container gets two — every tile
/// stays a hit target either way. Withdrawing the mode below a width threshold
/// was worse than it looked: a saved Year preference then opened on Month and
/// rewrote itself on the way past, destroying the setting to tidy up a layout.
///
/// It is a **navigation surface**, not a reading one. Nothing here names an
/// event: a year cell is a few points across, so the only honest thing it can
/// carry is "something / a bit / a lot", and the events are named the moment a
/// month is tapped. Every cell states its count in its accessibility label, so
/// shading is never the only carrier of the meaning — a reader who cannot
/// resolve the tint gets the number instead.
///
/// **What it costs.** A year is one window like any other, but an expanded
/// query counts *occurrences*, so a year containing a daily standup is
/// hundreds of ids paged a hundred at a time. That is paid once, when somebody
/// deliberately opens Year, while they are looking at it — never on a timer and
/// never in the background. It is the most expensive screen in this feature and
/// it is worth knowing that before adding an automatic refresh anywhere near
/// it.
struct YearGridView: View {
    let anchor: CalendarDay
    let clusters: [EventCluster]
    /// Tapping a month is the whole gesture: it is a picker for the month view.
    let onOpenMonth: (CalendarDay) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    /// The narrowest a month tile may be drawn.
    ///
    /// Below this its seven columns are three-point cells, which is a texture
    /// rather than a calendar. The grid answers by giving fewer columns, never
    /// by shrinking a tile past this.
    static let minimumTileWidth: CGFloat = 150

    /// One shading scale for the whole year, so December's busiest week and
    /// February's are drawn at the same weight.
    private var density: YearDensity { YearDensity(clusters: clusters) }

    var body: some View {
        let density = density

        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.minimumTileWidth), spacing: 16)],
                spacing: 16
            ) {
                ForEach(months, id: \.self) { month in
                    monthTile(month, density: density)
                }
            }
            .padding(PanelStyle.inset)
        }
    }

    /// The first of each of the anchor year's twelve months.
    private var months: [CalendarDay] {
        (0..<12).map { anchor.startOfYear.adding(months: $0) }
    }

    @ViewBuilder
    private func monthTile(_ first: CalendarDay, density: YearDensity) -> some View {
        let days = weeks(of: first)
        let total = days.flatMap { $0 }.reduce(0) { $0 + density.count(on: $1) }

        VStack(alignment: .leading, spacing: 4) {
            Text(CalendarHeading.day(first, template: "MMMM", locale: locale, timeZone: timeZone))
                .font(.subheadline.weight(.semibold))
                // The month name is already in the tile's own label; read on its
                // own it is twelve extra stops before any content.
                .accessibilityHidden(true)

            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                ForEach(Array(days.enumerated()), id: \.offset) { week in
                    GridRow {
                        ForEach(week.element, id: \.self) { day in
                            cell(day, month: first, density: density)
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(PanelStyle.surface, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onTapGesture { onOpenMonth(first) }
        // **One element per month**, with the day tints as decoration inside
        // it. Forty-two sibling elements per tile is five hundred stops for a
        // screen whose only gesture is "take me to August".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            CalendarHeading.day(first, template: "MMMMy", locale: locale, timeZone: timeZone)
                + ", " + String(localized: .ui("\(total) events"))
        )
        .accessibilityAddTraits(.isButton)
        // Hover names the month and its count without a tap, which is the
        // pointer equivalent of the label above.
        .help(
            Text(
                CalendarHeading.day(first, template: "MMMMy", locale: locale, timeZone: timeZone)
                    + ", " + String(localized: .ui("\(total) events"))))
    }

    private func cell(
        _ day: CalendarDay, month: CalendarDay, density: YearDensity
    )
        -> some View
    {
        let isOutside = day.month != month.month
        let weight = isOutside ? 0 : density.weight(on: day)

        return Text(verbatim: isOutside ? "" : String(day.day))
            .font(.system(size: 9))
            .foregroundStyle(weight > 0.55 ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 14)
            .background(
                // The theme's accent rather than the calendar's colour: a year
                // cell holds several calendars at once and picking one of their
                // colours would say something untrue about the other two.
                ThemeAccent().opacity(weight),
                in: .rect(cornerRadius: 2)
            )
            .accessibilityHidden(true)
    }

    /// Six rows of seven, so every tile is the same height whatever weekday the
    /// month starts on — a grid whose rows change count makes the whole year
    /// jump as it scrolls.
    private func weeks(of first: CalendarDay) -> [[CalendarDay]] {
        let start = first.startOfWeek(using: calendar)

        return (0..<6).map { week in
            (0..<7).map { start.adding(days: week * 7 + $0) }
        }
    }
}

#endif
