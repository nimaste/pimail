#if os(iOS)

public import PLMailCore

import JMAPKit

import SwiftUI

/// Day and week: a vertical hour axis with placed blocks.
///
/// One view for both, because a week is seven of a day's columns beside one
/// gutter and nothing else differs. Two views would be two copies of the
/// now-line, the all-day band and the scroll-to-now.
///
/// **The blocks are positioned from `PlacedCluster`'s fractions**, not from
/// points computed here. That is exactly what keeps the same layout correct at
/// every height — a phone, an iPad, and an hour row grown by Dynamic Type — and
/// it means nothing recomputes when the column resizes.
struct TimeGridView: View {
    let window: CalendarWindow
    let clusters: [EventCluster]
    let onOpen: (EventCluster) -> Void
    /// A tap on empty space proposes a start. Snapped **down** to the quarter
    /// hour by `DayGridLayout.slotAt`, because a tap just above the 10:00 line
    /// meaning *ten* is the same gesture as one just below it.
    var onCreate: ((LocalDateTime) -> Void)?
    /// How tall an hour is, as a multiple of the default row.
    ///
    /// The docked column draws the same grid at twice the height: it has one
    /// day where the full screen has seven, so it can spend the width on
    /// legibility, and a quarter-hour block is unreadable at the default row.
    var hourScale: CGFloat = 1
    /// Whether the weekday names sit above the columns. A single-day grid
    /// already says its date in the pane's own header, and repeating it is a
    /// row of chrome spent on nothing.
    var showsDayHeader = true

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The height of one hour row, scaled with Dynamic Type so that a block
    /// carrying two lines of text at `.accessibility1` still has room for them.
    @ScaledMetric(relativeTo: .caption2) private var hourHeight: CGFloat = 48

    /// The gutter's width. Wide enough for a short time at the current text
    /// size — the bare-hour compromise Android made ("10:00 AM needs ~70dp and
    /// the gutter is 56") is a phone-width constraint, and it does not bind
    /// here once the gutter is allowed to scale.
    @ScaledMetric(relativeTo: .caption2) private var gutterWidth: CGFloat = 56

    private var grids: [DayGrid] {
        window.days.map { DayGridLayout.place(clusters, on: $0) }
    }

    private var rowHeight: CGFloat { hourHeight * hourScale }

    private var columnHeight: CGFloat { rowHeight * 24 }

    var body: some View {
        VStack(spacing: 0) {
            if showsDayHeader {
                header
            }

            allDayBand

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        gutter
                        ForEach(grids, id: \.date) { grid in
                            column(grid)
                        }
                    }
                    .frame(height: columnHeight)
                }
                .onAppear {
                    // Day and week open scrolled so the current hour is in
                    // view. A calendar that opens at midnight opens on the one
                    // part of the day nothing is ever in.
                    proxy.scrollTo(nowHourID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 0) {
            // Height zero, deliberately. `Color.clear` is greedy in **both**
            // axes, and constraining only the width let this spacer eat every
            // spare point of the column — a day grid opened with six hundred
            // points of nothing above it and the hours pushed off the bottom.
            Color.clear.frame(width: gutterWidth, height: 0)

            ForEach(window.days, id: \.self) { day in
                Text(CalendarHeading.day(day, locale: locale, timeZone: timeZone))
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.vertical, 4)
    }

    /// All-day and multi-day clusters, above the axis.
    ///
    /// They never enter the lane algorithm: a 24-hour block would fill the
    /// column and hide every timed event behind it, which is the one thing a
    /// day view exists to show.
    @ViewBuilder
    private var allDayBand: some View {
        let bands = grids.filter { $0.allDay.isEmpty == false }

        if bands.isEmpty == false {
            HStack(alignment: .top, spacing: 8) {
                // Upper case and small, in the gutter's own width: the band's
                // label is a column heading rather than a row of its own, and
                // at body size a long translation of "All day" is wider than
                // the axis it has to line up with.
                Text(.ui("All day"))
                    .font(.system(size: 10, weight: .regular))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.top, 5)

                ForEach(grids, id: \.date) { grid in
                    VStack(spacing: 4) {
                        ForEach(grid.allDay) { cluster in
                            Button {
                                onOpen(cluster)
                            } label: {
                                EventChipView(cluster: cluster, density: .chip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var gutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: rowHeight, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
                    .id(hour)
            }
        }
        .frame(width: gutterWidth)
        // The axis is scenery. A reader swiping through 24 numbers before
        // reaching the first event is a reader who stops using the grid.
        .accessibilityHidden(true)
    }

    // MARK: - One day

    private func column(_ grid: DayGrid) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                hourLines

                ForEach(grid.timed) { placed in
                    block(placed, in: geometry.size)
                }

                if grid.date == CalendarDay(.now, in: timeZone) {
                    nowLine(in: geometry.size)
                }
            }
            .contentShape(.rect)
            // A `SpatialTapGesture` rather than `onTapGesture`, because the
            // slot is decided by *where* the finger landed and the plain tap
            // modifier does not report it.
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    guard let onCreate else { return }

                    onCreate(
                        DayGridLayout.slotStart(
                            on: grid.date,
                            fraction: tap.location.y / max(geometry.size.height, 1)
                        ))
                }
            )
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Divider() }
        // The whole day is one element for a reader, with its events as
        // children — not 24 hour lines to swipe past before the first one.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            dayLabel(grid)
        )
    }

    /// Where the day has got to.
    ///
    /// A `TimelineView` around the line and nothing else: the minute it counts
    /// is the only thing on this screen that changes without the data
    /// changing, and wrapping the whole column in it would redraw every block
    /// once a minute for a line two points tall.
    ///
    /// Drawn only on today's column, and never on a week that does not contain
    /// today — a red rule across a fortnight-old Tuesday is a lie about where
    /// the day is.
    private func nowLine(in size: CGSize) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let fraction = Self.fraction(of: context.date, in: timeZone)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 1.5)
                    .offset(y: size.height * fraction)

                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: -3.5, y: size.height * fraction - 2.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        // Scenery. The current time is on the status bar, said better.
        .accessibilityHidden(true)
    }

    /// How far through the day `instant` is, as 0…1.
    static func fraction(of instant: Date, in zone: TimeZone) -> Double {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)

        return Double(minutes) / Double(DayGridLayout.minutesInDay)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Divider().frame(height: rowHeight, alignment: .top)
            }
        }
        .accessibilityHidden(true)
    }

    private func block(_ placed: PlacedCluster, in size: CGSize) -> some View {
        let laneWidth = size.width / CGFloat(max(placed.lanes, 1))

        return Button {
            onOpen(placed.cluster)
        } label: {
            EventChipView(
                cluster: placed.cluster,
                density: .block,
                continuesBefore: placed.continuesBefore,
                continuesAfter: placed.continuesAfter
            )
        }
        .buttonStyle(.plain)
        .frame(
            width: max(laneWidth - 2, 8),
            height: max(size.height * placed.height - 1, 12),
            alignment: .topLeading
        )
        .offset(
            x: laneWidth * CGFloat(placed.lane) + 1,
            y: size.height * placed.top
        )
    }

    // MARK: - Text

    private func hourLabel(_ hour: Int) -> String {
        EventSpeech.time(
            LocalDateTime(
                year: window.from.year, month: window.from.month, day: window.from.day,
                hour: hour, minute: 0, second: 0),
            locale: locale
        )
    }

    private func dayLabel(_ grid: DayGrid) -> String {
        let count = grid.allDay.count + grid.timed.count
        let name = CalendarHeading.day(
            grid.date, template: "EEEEdMMM", locale: locale, timeZone: timeZone)

        return name + ", " + String(localized: .ui("\(count) events"))
    }

    /// Which hour row to open on. Read once, from the device's clock, because
    /// "now" is the only thing on this screen that is about the reader rather
    /// than about the data.
    private var nowHourID: Int {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        return calendar.component(.hour, from: .now)
    }
}

#endif
