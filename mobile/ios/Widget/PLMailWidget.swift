import PLMailCore
import SwiftUI
import WidgetKit

/// The unread count on the home screen.
///
/// Reads shared defaults, never the network and never the database: a widget
/// runs in a different process on the system's schedule, and one that reaches
/// for a server on a NAS would be a widget that shows a spinner forever
/// whenever you are away from home.
struct MailEntry: TimelineEntry {
    let date: Date
    let state: SharedMailState?
}

struct MailProvider: TimelineProvider {
    func placeholder(in context: Context) -> MailEntry {
        MailEntry(date: .now, state: SharedMailState(unreadCount: 3, totalCount: 128))
    }

    func getSnapshot(in context: Context, completion: @escaping (MailEntry) -> Void) {
        completion(MailEntry(date: .now, state: SharedMailStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MailEntry>) -> Void) {
        let entry = MailEntry(date: .now, state: SharedMailStore.read())

        // Ask again in fifteen minutes, matching the app's own background
        // refresh. Asking more often would not produce fresher numbers — the
        // app is what writes them — and the system would start ignoring the
        // request anyway.
        completion(
            Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct MailWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MailEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: 0) { Text(count, format: .number) }
                .gaugeStyle(.accessoryCircularCapacity)

        case .accessoryInline:
            summary

        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.tint)

                Text(count, format: .number)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())

                Text(unreadLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                // Said outright rather than implied. A widget is refreshed on
                // the system's schedule, not the app's, so a count with no age
                // on it will eventually be wrong with total confidence.
                footnote
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var count: Int { entry.state?.unreadCount ?? 0 }

    /// Three genuinely different situations, and the widget must not render
    /// them all as "0".
    ///
    /// Without an App Group — every build signed by a free Apple ID — this
    /// extension cannot see the app's numbers at all. Showing a confident
    /// zero there would be a lie: the mail may well be piling up.
    private var footnote: Text {
        if SharedMailStore.isShared == false {
            return Text(.core("Needs a paid developer account"))
        }

        guard let state = entry.state else { return Text(.core("Open plMail to sign in")) }

        // Verbatim: a formatted date is already in the reader's locale, and
        // putting it through the catalogue would ask for a key that changes
        // every minute.
        return Text(state.updatedAt.formatted(.relative(presentation: .named)))
    }

    /// Two keys rather than one with a count in it.
    ///
    /// The number is drawn above this in its own oversized digit, so the words
    /// must not repeat it — and a language whose plural rules are not English's
    /// needs the two forms separately anyway.
    private var unreadLabel: LocalizedStringResource {
        count == 1 ? .core("unread message") : .core("unread messages")
    }

    private var summary: Text {
        // The product name, and therefore never translated.
        guard SharedMailStore.isShared, entry.state != nil else { return Text(verbatim: "plMail") }

        return count == 0 ? Text(.core("No unread mail")) : Text(.core("\(count) unread"))
    }
}

struct PLMailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.plmail.unread", provider: MailProvider()) { entry in
            MailWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: .core("Unread mail")))
        .description(String(localized: .core("How much unread mail is waiting.")))
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - The calendar

/// Today's remaining events, from the same shared defaults.
///
/// **In the existing extension, deliberately.** A second app-extension target
/// could not be signed by a free Apple ID, and the rule here is that the app
/// builds clean today and stays that way; another `Widget` in the bundle that
/// already exists costs no provisioning at all.
struct CalendarEntry: TimelineEntry {
    let date: Date
    let state: SharedCalendarState?
}

struct CalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarEntry {
        CalendarEntry(
            date: .now,
            state: SharedCalendarState(
                upcoming: [
                    SharedCalendarEvent(
                        id: "1", title: "Standup", timeText: "09:00 – 09:15",
                        colourHex: "#2563eb", calendarName: "Work",
                        startsAt: .now, endsAt: .now.addingTimeInterval(900))
                ],
                dayKey: "", hasCalendar: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        completion(CalendarEntry(date: .now, state: SharedCalendarStore.read()))
    }

    /// **Cut at real event boundaries, not on a cadence.**
    ///
    /// A calendar widget is one of the very few that knows exactly when its
    /// content changes: an event ends, and it should leave the list. Asking
    /// every fifteen minutes would redraw an unchanged screen dozens of times a
    /// day and still leave a finished meeting at the top for a quarter of an
    /// hour. The last entry is the next midnight, so a day with nothing left in
    /// it turns over rather than showing yesterday for ever.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let state = SharedCalendarStore.read()
        let midnight =
            Calendar.current.nextDate(
                after: .now, matching: DateComponents(hour: 0, minute: 0),
                matchingPolicy: .nextTime) ?? .now.addingTimeInterval(3600)

        let points = CalendarWidgetPlan.refreshPoints(
            for: state?.upcoming ?? [], after: .now, nextMidnight: midnight)

        completion(
            Timeline(
                entries: points.map { CalendarEntry(date: $0, state: state) },
                policy: .after(midnight)))
    }
}

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalendarEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineSummary

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let next {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(next.timeText).font(.caption)
                } else {
                    inlineSummary.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events.prefix(family == .systemSmall ? 1 : 4)) { event in
                    row(event)
                }

                if events.isEmpty {
                    Text(emptyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                // Said outright rather than implied, exactly as the unread
                // widget says it. A list with no age on it will eventually be
                // wrong with total confidence.
                footnote
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ event: SharedCalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // The calendar's colour, and never the only thing carrying the
            // meaning: the title and the time are both there, and an event on a
            // calendar with no colour draws the same bar in the widget's own
            // tint rather than vanishing.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(swatch(event.colourHex))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 0) {
                Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
                Text(event.timeText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(height: 26)
        .accessibilityElement(children: .combine)
        // Verbatim: both halves are the user's own data, and a catalogue
        // lookup on them would ask for a key per event.
        .accessibilityLabel(Text(verbatim: "\(event.title), \(event.timeText)"))
    }

    /// `#rrggbb`, validated strictly, and the widget's own tint where it does
    /// not parse. Never an invented grey: a bar in a colour the user did not
    /// choose, beside one in a colour they did, is worse than no colour at all
    /// — so the fallback is deliberately the app's tint rather than a
    /// pseudo-calendar colour.
    private func swatch(_ hex: String?) -> Color {
        guard let hex, let colour = CalendarColour(hex: hex) else { return .accentColor }

        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }

    private var events: [SharedCalendarEvent] { entry.state?.upcoming ?? [] }
    private var next: SharedCalendarEvent? { events.first }

    /// Four genuinely different situations, and none of them is "no events".
    ///
    /// Without an App Group — every build signed by a free Apple ID — this
    /// extension cannot see the app's state at all, and a confident "Nothing
    /// today" there would be a lie. **In the Simulator a group container
    /// resolves without the entitlement**, so this cannot be detected
    /// programmatically and the honest fallback is to say what is missing
    /// whenever there is no state to draw.
    private var footnote: Text {
        if SharedMailStore.isShared == false {
            return Text(.core("Needs a paid developer account"))
        }

        guard let state = entry.state else { return Text(.core("Open plMail to sign in")) }

        return Text(state.updatedAt.formatted(.relative(presentation: .named)))
    }

    private var emptyLine: LocalizedStringResource {
        guard let state = entry.state else { return .core("No calendar loaded") }

        return state.hasCalendar ? .core("Nothing left today") : .core("This server has no calendar")
    }

    private var inlineSummary: Text {
        guard entry.state != nil else { return Text(verbatim: "plMail") }

        guard let next else { return Text(.core("Nothing left today")) }

        return Text(verbatim: "\(next.timeText) \(next.title)")
    }
}

struct PLMailCalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.plmail.calendar", provider: CalendarProvider()) { entry in
            CalendarWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: .core("Today's events")))
        .description(String(localized: .core("What is left on your calendar today.")))
        // The Lock Screen families are the best surface a calendar has, and the
        // cheapest: one line that is right most of the time beats an app icon.
        .supportedFamilies([
            .systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline,
        ])
    }
}

@main
struct PLMailWidgetBundle: WidgetBundle {
    var body: some Widget {
        PLMailWidget()
        PLMailCalendarWidget()
    }
}
