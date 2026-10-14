import AppIntents
import Foundation
import PLMailCore
import SwiftUI

/// Shortcuts and Siri for the calendar.
///
/// The same rule as `MailIntents.swift`, and it bites harder here: these
/// **open the app** rather than acting in the background. A calendar has no bin
/// and no undo — a destroy is a real delete, for everybody the event is shared
/// with — so an intent that created or changed an event unattended would be a
/// way to put a meeting in somebody's diary by voice with nobody looking. So
/// "create" means "open an editor, filled in"; the save is still a deliberate
/// act by a person reading the screen.
///
/// Nothing here touches the network either. Both post to
/// ``CalendarIntentRouter`` and return; the shell decides what to show, which
/// is what keeps a Shortcut from waking a Raspberry Pi with one PHP worker pool
/// merely because somebody said "open my calendar".
struct ShowCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Open calendar"
    static let description = IntentDescription("Opens the calendar, on a day of your choosing.")

    /// Opening is the point, not a side effect.
    static let openAppWhenRun = true

    /// Optional because "open my calendar" with no date is the common case and
    /// arrives as nil, which means today.
    @Parameter(title: "Date")
    var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult {
        CalendarIntentRouter.shared.request(
            .show(date.map { CalendarDeepLink.day(forIntentDate: $0, in: .current) }))

        return .result()
    }
}

/// A new event, prefilled and **never saved**.
///
/// The title and the day are hints for an editor, not a write. Dictated titles
/// arrive padded and sometimes empty, so they go through
/// ``CalendarDeepLink/title(forIntent:)`` — an editor prefilled with a single
/// space looks filled in and would save a nameless event.
struct CreateEventIntent: AppIntent {
    static let title: LocalizedStringResource = "New event"
    static let description = IntentDescription(
        "Opens a new event, filled in. Nothing is saved until you save it.")

    static let openAppWhenRun = true

    @Parameter(title: "Title", requestValueDialog: "What is it called?")
    var eventTitle: String?

    @Parameter(title: "Date")
    var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult {
        CalendarIntentRouter.shared.request(
            .create(
                title: CalendarDeepLink.title(forIntent: eventTitle),
                day: date.map { CalendarDeepLink.day(forIntentDate: $0, in: .current) }))

        return .result()
    }
}
