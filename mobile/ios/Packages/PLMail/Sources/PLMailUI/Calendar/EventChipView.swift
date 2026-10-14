#if os(iOS)

public import PLMailCore

import SwiftUI

/// One cluster, drawn.
///
/// Three densities rather than three views, because everything that differs
/// between an agenda row, a grid block and a month chip is how much of the same
/// four facts fits — title, time, calendar, and whether rows were merged. Three
/// views would be three accessibility labels, and two of them would drift.
struct EventChipView: View {
    enum Density {
        /// A full-width row in a list: title, time and calendar all fit.
        case row
        /// A block in a day or week column, sized by the layout's fractions.
        case block
        /// A chip in a month cell: title and start time only, one line.
        case chip
    }

    let cluster: EventCluster
    var density: Density = .row
    /// Whether the block was clipped at the top or bottom of its day. Drawn as
    /// a flush edge and an arrow, because a block that simply stops looks like
    /// an event that ends at midnight — which is a different event.
    var continuesBefore = false
    var continuesAfter = false
    var isSelected = false
    /// Whether a month chip has room for its start time. Decided by
    /// ``MonthCellPlan`` from the **measured** cell, never from the idiom.
    var showsTime = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale

    private var row: EventRow { cluster.representative }

    /// The whole sentence, composed in `PLMailCore` so it is testable without a
    /// simulator. A grid is the surface where "it technically works" is
    /// furthest from usable, and this label is the entire interface for a
    /// VoiceOver reader.
    private var spokenLabel: String {
        EventSpeech.label(
            for: cluster,
            locale: locale,
            allDayWord: CalendarWords.allDay,
            floatingWord: CalendarWords.floating,
            cancelledWord: CalendarWords.cancelled,
            mergedPhrase: { count, names in
                CalendarWords.merged(count: count, names: names)
            }
        )
    }

    private var timeText: String {
        row.isAllDay
            ? CalendarWords.allDay
            : EventSpeech.time(row.start, locale: locale)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, density == .chip ? 4 : 8)
            .padding(.vertical, density == .chip ? 2 : 6)
            .background(
                CalendarTheme.fill(row.colourHex, isCancelled: row.isCancelled),
                in: .rect(cornerRadius: density == .chip ? 4 : 8)
            )
            .overlay(alignment: .leading) {
                // The calendar's colour at full strength, as a rule down the
                // leading edge. A 1pt line is what survives both appearances;
                // the fill behind it is the same colour at 18% and would not.
                Rectangle()
                    .fill(CalendarTheme.edge(row.colourHex))
                    .frame(width: density == .chip ? 2 : 3)
                    .clipShape(.rect(cornerRadius: 2))
            }
            .overlay {
                RoundedRectangle(cornerRadius: density == .chip ? 4 : 8)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(Color.clear),
                        lineWidth: 2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            // **The whole sentence on hover**, which is the pointer's answer to
            // a month chip clipped at one line: a trackpad user finds out what
            // "Sprint pla…" is without opening it, and a touch user still has
            // the same sentence through VoiceOver and through the inspector.
            .help(Text(verbatim: spokenLabel))
            .hoverEffect(.highlight)
            // Dragging a chip out carries its title and time as text, for a
            // note or a message being written beside the calendar. It moves
            // nothing: dragging an event to another *day* would move every
            // occurrence of a series, which needs a "this event / all events"
            // choice and a `recurrenceOverrides` patch that the writable
            // thirteen-property vocabulary cannot express.
            //
            // Never the only route — Copy title in the context menu and in the
            // rotor does the same thing without a drag.
            .draggable(spokenLabel)
            .eventActions(for: cluster)
    }

    @ViewBuilder
    private var content: some View {
        switch density {
        case .row:
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                HStack(spacing: 6) {
                    Text(
                        EventSpeech.timeSpan(
                            cluster, locale: locale, allDayWord: CalendarWords.allDay))
                    if let name = row.calendarName, name.isEmpty == false {
                        Text(verbatim: "·")
                        Text(name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if cluster.isMerged { mergedNote }
            }
        case .block:
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                // A short block has room for a title or a time, not both. The
                // title wins: a block's position on the axis already says when
                // it is, and its title is the only thing that says what.
                if typeSize.isAccessibilitySize == false {
                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .chip:
            HStack(spacing: 4) {
                if showsTime, row.isAllDay == false {
                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Fixed so the titles line up down the cell: a time
                        // allowed to shrink makes seven chips seven different
                        // indents, which reads as noise.
                        .layoutPriority(1)
                }

                titleLine
                Spacer(minLength: 0)
            }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 4) {
            if cluster.isMerged { MergedDot(colours: cluster.colours) }

            Text(row.title.isEmpty ? String(localized: .ui("Untitled")) : row.title)
                .font(density == .row ? .body : .caption)
                .fontWeight(density == .row ? .regular : .medium)
                .lineLimit(density == .chip ? 1 : 2)
                // Struck through as well as dimmed: a cancelled event that is
                // only paler is a cancelled event nobody notices.
                .strikethrough(row.isCancelled)
                .foregroundStyle(row.isCancelled ? .secondary : CalendarTheme.label)

            if continuesBefore {
                Image(systemName: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if continuesAfter {
                Image(systemName: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var mergedNote: some View {
        Text(
            .ui(
                "In \(cluster.members.count) calendars"
            )
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// The multi-slice dot that says two rows were collapsed into one.
///
/// Decorative and hidden from VoiceOver on purpose — the label already says "in
/// 2 calendars, Work and Personal", which is strictly more than the dot can
/// convey. Nulls are drawn as a hairline slice rather than dropped, because a
/// two-calendar meeting with a one-colour dot says something untrue.
struct MergedDot: View {
    let colours: [String?]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalendarTheme.slices(colours).enumerated()), id: \.offset) { slice in
                Rectangle().fill(slice.element)
            }
        }
        .frame(width: 8, height: 8)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

#endif
