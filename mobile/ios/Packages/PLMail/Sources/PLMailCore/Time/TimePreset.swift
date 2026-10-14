import Foundation

/// The times people actually pick.
///
/// Offered as a short list rather than a date picker because both the gestures
/// that use it — snoozing a conversation, holding a message back until the
/// morning — are gestures, not appointments: the whole value is that they take
/// one tap. A picker is still reachable for the rare exact time.
///
/// Every case resolves against a calendar rather than by adding intervals, so
/// "tomorrow" lands at 08:00 local on the next day and not 24 hours from now —
/// and so a daylight-saving boundary does not shift it by an hour. That
/// arithmetic is the part worth having exactly once, which is why this is one
/// type shared by snooze and send-later rather than two lists that agree today
/// and drift apart at the next change.
///
/// Which cases each of them offers differs, though — see ``snoozeChoices`` and
/// ``sendLaterChoices``.
public enum TimePreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday
    case tomorrow
    case tomorrowEvening
    case thisWeekend
    case nextWeek

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .laterToday: String(localized: "Later today", bundle: .module)
        case .tomorrow: String(localized: "Tomorrow", bundle: .module)
        case .tomorrowEvening: String(localized: "Tomorrow evening", bundle: .module)
        case .thisWeekend: String(localized: "This weekend", bundle: .module)
        case .nextWeek: String(localized: "Next week", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .laterToday: "sun.max"
        case .tomorrow: "sunrise"
        case .tomorrowEvening: "sunset"
        case .thisWeekend: "beach.umbrella"
        case .nextWeek: "calendar"
        }
    }

    /// What a snooze offers: a weekend is a real thing to put a conversation
    /// off until.
    public static let snoozeChoices: [TimePreset] = [
        .laterToday, .tomorrow, .thisWeekend, .nextWeek,
    ]

    /// What send-later offers. No weekend: mail held for Saturday morning
    /// arrives when nobody is reading it, and an evening slot is there instead
    /// because "after they have stopped working" is a thing people aim at.
    public static let sendLaterChoices: [TimePreset] = [
        .laterToday, .tomorrow, .tomorrowEvening, .nextWeek,
    ]

    /// Hours the presets aim at, in local time.
    private static let morning = 8
    private static let evening = 18

    /// When this preset lands, or nil when it has already passed for today.
    ///
    /// "Later today" is the one that can vanish: past the evening hour there is
    /// no later today left, and offering it would mean picking a time in the
    /// past. Callers drop a nil rather than substituting something else,
    /// because a preset that quietly means a different time than its label is
    /// worse than one that is not offered.
    public func date(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .laterToday:
            let candidate = calendar.date(
                bySettingHour: Self.evening, minute: 0, second: 0, of: now)

            // A margin, not a strict comparison: "later today" at 17:59 would
            // technically be in the future and useless.
            guard let candidate, candidate.timeIntervalSince(now) > 30 * 60 else { return nil }

            return candidate

        case .tomorrow:
            return Self.day(after: now, days: 1, hour: Self.morning, calendar: calendar)

        case .tomorrowEvening:
            return Self.day(after: now, days: 1, hour: Self.evening, calendar: calendar)

        case .thisWeekend:
            // Saturday morning. On a Saturday or Sunday it means *next*
            // weekend rather than a time in the past or a few hours away.
            let weekday = calendar.component(.weekday, from: now)
            let saturday = 7
            let daysAhead = weekday >= saturday ? 7 : saturday - weekday

            return Self.day(after: now, days: daysAhead, hour: Self.morning, calendar: calendar)

        case .nextWeek:
            // Monday morning, always at least one day out.
            let weekday = calendar.component(.weekday, from: now)
            let monday = 2
            let daysAhead = weekday < monday ? monday - weekday : 9 - weekday

            return Self.day(
                after: now, days: daysAhead == 0 ? 7 : daysAhead, hour: Self.morning,
                calendar: calendar)
        }
    }

    private static func day(after now: Date, days: Int, hour: Int, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: days, to: now) else { return nil }

        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    /// The presets from `choices` that still make sense at this moment.
    public static func available(
        among choices: [TimePreset] = allCases,
        from now: Date = .now,
        calendar: Calendar = .current
    )
        -> [(preset: TimePreset, date: Date)]
    {
        var seen: Set<Date> = []

        return choices.compactMap { preset -> (preset: TimePreset, date: Date)? in
            guard let date = preset.date(from: now, calendar: calendar) else { return nil }

            // Presets collide — on a Friday, "tomorrow" and "this weekend" are
            // the same Saturday morning. Two menu entries with identical times
            // read as a bug, so the earlier-listed, more specific one wins.
            guard seen.insert(date).inserted else { return nil }

            return (preset, date)
        }
    }
}

/// The snooze presets, computed at most once a minute.
///
/// **This exists because it was measured.** `TimePreset.available` resolves each
/// preset through `Calendar.date(bySettingHour:…)`, which searches forward for a
/// matching component — the single most expensive thing this app does per call.
/// `SnoozeMenu` evaluates it inside a `ForEach`, and the reader mentions that
/// menu three times (toolbar, reply bar, ⌘ commands), so every body evaluation
/// of an open conversation ran five calendar searches several times over. On an
/// iPad Pro that showed up in Instruments as `_CalendarGregorian.dateComponents`
/// and `dateAfterMatchingHour` dominating the profile while the interface was
/// unusable.
///
/// A minute of staleness is harmless: every preset lands on an hour boundary.
@MainActor
public enum SnoozeChoices {
    private static var cached: (minute: Date, value: [(preset: TimePreset, date: Date)])?

    /// The presets that still make sense now, from cache where possible.
    public static func current(
        among choices: [TimePreset] = TimePreset.snoozeChoices,
        now: Date = .now
    ) -> [(preset: TimePreset, date: Date)] {
        let seconds = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        let minute = Date(timeIntervalSinceReferenceDate: seconds)

        if let cached, cached.minute == minute { return cached.value }

        let fresh = TimePreset.available(among: choices, from: now)

        cached = (minute, fresh)

        return fresh
    }
}
