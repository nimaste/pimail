import Foundation
import Observation

/// Where an intent's request goes.
///
/// Intents are constructed by the system, not by the app, so they cannot be
/// handed a reference to anything. This is the one place that indirection
/// lives.
@MainActor
@Observable
public final class IntentRouter {
    public static let shared = IntentRouter()

    public enum Request: Equatable, Sendable {
        case compose(recipient: String?, subject: String?)
        case search(String)
        /// Open one conversation.
        ///
        /// The case that makes a notification tap, a Spotlight result and a
        /// Handoff continuation land on the mail they are about rather than on
        /// the inbox. All three arrive from outside the view tree holding
        /// exactly these two ids and nothing else — `App/NotificationResponder`
        /// had both in hand at the default action and dropped them, because
        /// there was nowhere to put them.
        ///
        /// Ids rather than a thread: the conversation may have been deleted
        /// between the banner being posted and the tap, and re-resolving
        /// against the cache is what lets that fail as "not here any more"
        /// rather than as a stale object.
        case thread(accountKey: String, threadID: String)
    }

    /// The most recent request, cleared once acted on. Not a queue: two
    /// intents arriving before the UI can respond means the second one is
    /// what the person most recently asked for.
    public private(set) var pending: Request?

    /// The rest of a `mailto:` link, riding alongside ``pending``.
    ///
    /// **A companion to `.compose`, not a sixth `Request` case, and the reason
    /// is ownership rather than taste.** `MailView.performPendingIntent`
    /// switches over `Request` exhaustively and lives in a file this change
    /// does not own; adding a case there stops the shell compiling. So the
    /// shell keeps seeing the `.compose` it already knows how to open — a
    /// recipient and a subject — and the composer picks the Cc, Bcc and body
    /// up from here once it is on screen.
    ///
    /// Cleared by ``takeMailto()`` rather than by whoever consumed `pending`,
    /// because the two are consumed in different places. Leaving it set is the
    /// failure worth naming: the next composer opened by hand, hours later,
    /// would fill itself in from a link somebody tapped this morning.
    public private(set) var mailto: MailtoRequest?

    private init() {}

    public func request(_ request: Request) {
        pending = request
        // A plain compose request is not a link. Clearing here means a Siri
        // "new message to Anna" cannot inherit the body of a `mailto:` that
        // never got opened.
        mailto = nil
    }

    /// Asks for a composer prefilled from a `mailto:` link.
    ///
    /// Both halves are set together, and in this order, so the `pending`
    /// change that wakes the shell always sees a `mailto` already in place.
    public func request(mailto request: MailtoRequest) {
        mailto = request
        pending = .compose(
            recipient: MailtoRequest.field(from: request.to),
            subject: request.subject.isEmpty ? nil : request.subject)
    }

    public func take() -> Request? {
        defer { pending = nil }

        return pending
    }

    /// The `mailto:` payload, consumed once.
    public func takeMailto() -> MailtoRequest? {
        defer { mailto = nil }

        return mailto
    }
}
