import AppIntents
import PLMailCore
import SwiftUI

/// Shortcuts, Siri and Spotlight.
///
/// These deliberately **open the app** rather than acting in the background.
/// An intent that sent mail without showing anyone what it was about to send
/// would be a way to send the wrong thing to the wrong person by voice, in a
/// client where the recipient list is the one thing you cannot take back. So
/// "compose" means "open a composer, filled in" — the send is still a
/// deliberate act by a person looking at the screen.
struct ComposeMailIntent: AppIntent {
    static let title: LocalizedStringResource = "New message"
    static let description = IntentDescription(
        "Opens a new message, optionally addressed to someone.")

    /// Opening is the point, not a side effect.
    static let openAppWhenRun = true

    @Parameter(title: "To", requestValueDialog: "Who is it for?")
    var recipient: String?

    @Parameter(title: "Subject")
    var subject: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.compose(recipient: recipient, subject: subject))

        return .result()
    }
}

/// Searching by voice, which is the one thing a phone is genuinely better at
/// than a laptop: "find the mail from the plumber" while your hands are full.
struct SearchMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Search mail"
    static let description = IntentDescription("Searches your mail.")

    static let openAppWhenRun = true

    @Parameter(title: "Query", requestValueDialog: "What are you looking for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.search(query))

        return .result()
    }
}

/// The unread count, answerable without opening anything.
///
/// Reads the local store, so it works on a train and never wakes the server.
/// It reports what the app last knew, and says so — a count presented as live
/// when it is minutes old is the kind of small lie that makes people stop
/// trusting the number.
struct UnreadCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Unread count"
    static let description = IntentDescription("How many unread conversations you have.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = UnreadCountReader.shared.current()

        return .result(
            value: count,
            dialog: count == 0
                ? "No unread mail."
                : "\(count) unread.")
    }
}

struct MailShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ComposeMailIntent(),
            phrases: [
                "New message in \(.applicationName)",
                "Write a mail in \(.applicationName)",
            ],
            shortTitle: "New message",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: SearchMailIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find mail in \(.applicationName)",
            ],
            shortTitle: "Search mail",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: UnreadCountIntent(),
            phrases: [
                "Unread in \(.applicationName)",
                "How much mail do I have in \(.applicationName)",
            ],
            shortTitle: "Unread count",
            systemImageName: "envelope.badge"
        )

        // The calendar's two, declared here rather than in a provider of their
        // own: the system takes one `AppShortcutsProvider` per app, and a
        // second one does not fail loudly — it simply leaves whichever set lost
        // the race absent from Shortcuts with nothing said.
        AppShortcut(
            intent: ShowCalendarIntent(),
            phrases: [
                "Open my calendar in \(.applicationName)",
                "Show my \(.applicationName) calendar",
            ],
            shortTitle: "Open calendar",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: CreateEventIntent(),
            phrases: [
                "New event in \(.applicationName)",
                "Add an event to \(.applicationName)",
            ],
            shortTitle: "New event",
            systemImageName: "calendar.badge.plus"
        )
    }
}
