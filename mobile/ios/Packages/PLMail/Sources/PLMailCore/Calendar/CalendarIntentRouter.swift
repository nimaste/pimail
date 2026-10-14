import Foundation
public import JMAPKit
import Observation

/// Where a request to open the calendar at a particular place goes.
///
/// **A second router rather than a case on `IntentRouter`, and the reason is
/// ownership rather than taste.** `MailView.performPendingIntent` switches over
/// `IntentRouter.Request` exhaustively and lives in a file this change does not
/// own; a sixth case there stops the shell compiling for whoever is editing it
/// at the time. The same argument the `mailto:` work already made, and it
/// reaches the same conclusion — one channel too many is still better than a
/// build nobody can finish.
///
/// It carries the ``.shared`` comment the house style demands of a singleton:
/// an App Intent, a Spotlight result and a Handoff continuation are all built
/// by the *system*, outside the view tree, and cannot be handed a reference to
/// anything. This is the one place that indirection lives for the calendar, and
/// it should be folded into `IntentRouter` the moment one agent owns both
/// files.
///
/// **Nothing here acts.** Following `MailIntents.swift`'s rule, a request opens
/// a screen — an editor is presented prefilled and never saved unattended.
/// Saving an event by voice, on a surface with no undo and no bin, is exactly
/// the class of action this codebase refuses to take without somebody looking
/// at it.
@MainActor
@Observable
public final class CalendarIntentRouter {
    public static let shared = CalendarIntentRouter()

    public enum Request: Equatable, Sendable {
        /// Show the calendar on a day. Nil means today, which is what a bare
        /// "open my calendar" means and what a `nil` parameter from Shortcuts
        /// arrives as.
        case show(CalendarDay?)

        /// Open a **prefilled editor**, never a saved event.
        case create(title: String?, day: CalendarDay?)

        /// Open one occurrence, from a Spotlight result or a Handoff
        /// continuation.
        ///
        /// Ids rather than an event: the occurrence may have been deleted
        /// between the index being written and the tap, and re-resolving
        /// against the cache is what lets that fail as "not here any more"
        /// rather than as a stale object drawn from a search result.
        case occurrence(accountKey: String, occurrenceID: CalendarEventID)
    }

    /// The most recent request, cleared once acted on.
    ///
    /// Not a queue: two intents arriving before the screen can respond means
    /// the second one is what the person most recently asked for.
    public private(set) var pending: Request?

    /// How many calendar screens are currently on screen.
    ///
    /// **The shell needs it and nothing else can answer it.** A request arriving
    /// while the calendar is already up is consumed by that screen; a request
    /// arriving while it is not would sit in ``pending`` for ever, because the
    /// only consumer is a view that does not exist. So the shell presents one —
    /// but only when it has to, since presenting a second calendar over the one
    /// the reader is already looking at is a screen appearing for no reason.
    ///
    /// A count rather than a flag: on iPad a window scene and the main window
    /// can both be showing a calendar, and a flag cleared by whichever
    /// disappeared first would tell the shell nobody was listening while
    /// somebody was.
    public private(set) var showing = 0

    /// Whether any calendar screen is up to take a request.
    public var isShowing: Bool { showing > 0 }

    private init() {}

    public func request(_ request: Request) {
        pending = request
    }

    /// Called by every calendar screen as it appears and disappears.
    ///
    /// Balanced by construction — one `beganShowing` per `stoppedShowing` in
    /// the same view's lifecycle — and clamped at zero, because an unbalanced
    /// teardown that drove the count negative would leave the shell believing
    /// a calendar was up for the rest of the session and silently swallow every
    /// intent after it.
    public func beganShowing() {
        showing += 1
    }

    public func stoppedShowing() {
        showing = max(0, showing - 1)
    }

    public func take() -> Request? {
        defer { pending = nil }

        return pending
    }
}
