#if os(iOS)

public import PLMailCore

import SwiftUI

/// The snooze choices, as menu items.
///
/// One view used by the reader's toolbar and by a row's context menu, so the
/// two can never drift into offering different times.
struct SnoozeMenu: View {
    let isSnoozed: Bool
    let onPick: (Date?) -> Void
    /// Menus cannot present sheets, so the date picker belongs to whoever put
    /// this menu on screen.
    let onPickExact: () -> Void

    var body: some View {
        ForEach(SnoozeMenuItems.current(), id: \.id) { entry in
            Button {
                onPick(entry.date)
            } label: {
                Label {
                    // The time as well as the name: "Tomorrow" is only useful
                    // if you know when tomorrow starts, and that is a choice
                    // this app made rather than one the user set.
                    Text(.ui("\(entry.title) · \(entry.label)"))
                } icon: {
                    Image(systemName: entry.symbolName)
                }
            }
        }

        Divider()

        Button(action: onPickExact) {
            Label(.ui("Pick a date and time…"), systemImage: "calendar.badge.clock")
        }

        if isSnoozed {
            Button {
                onPick(nil)
            } label: {
                Label(.ui("Wake now"), systemImage: "bell")
            }
        }
    }

    static func shortTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDateInTomorrow(date) {
            return "tomorrow " + date.formatted(date: .omitted, time: .shortened)
        }

        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// How a snoozed row says when it is due back.
    static func badge(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow"
        }

        if let week = Calendar.current.date(byAdding: .day, value: 7, to: .now), date < week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }

        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The snooze menu's finished rows — label included — rebuilt at most once a
/// minute.
///
/// Caching the *dates* was not enough. ``SnoozeMenu/shortTime(_:)`` asks
/// `Calendar.current.isDateInToday` and `isDateInTomorrow`, each of which
/// resolves a day interval, and it runs once per menu row. The reader mentions
/// this menu three times — toolbar, reply bar and ⌘ commands — so a single body
/// evaluation of an open conversation paid for fifteen day-interval
/// calculations plus fifteen format-style resolutions. Instruments showed
/// `_CalendarGregorian.dateInterval(of:for:)` still hot after the dates
/// themselves were cached.
@MainActor
enum SnoozeMenuItems {
    struct Item: Identifiable {
        let id: String
        let date: Date
        let title: String
        let symbolName: String
        /// The formatted time, resolved once here rather than per body.
        let label: String
    }

    private static var cached: (minute: Date, value: [Item])?

    static func current(now: Date = .now) -> [Item] {
        let seconds = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let minute = Date(timeIntervalSinceReferenceDate: seconds)

        if let cached, cached.minute == minute { return cached.value }

        let fresh = SnoozeChoices.current(now: now).map {
            Item(
                id: $0.preset.id, date: $0.date, title: $0.preset.title,
                symbolName: $0.preset.symbolName, label: SnoozeMenu.shortTime($0.date))
        }

        cached = (minute, fresh)

        return fresh
    }
}

#endif
