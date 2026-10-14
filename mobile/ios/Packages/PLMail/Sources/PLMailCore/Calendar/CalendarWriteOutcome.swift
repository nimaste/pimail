import Foundation
public import JMAPKit

/// What one create, update or delete came to.
///
/// The distinction between the middle three is load-bearing: **a refusal is an
/// answer and is shown in the server's own words; a transport failure is not an
/// answer and names the host.** Neither is retried and neither is queued —
/// replaying a refusal is a loop that terminates never, and this surface has no
/// `ifInState` on which to build a conflict story for a queue.
///
/// By the time one of these arrives the optimistic change has already been
/// rolled back off the cache, **which is why the screens report rather than
/// offer an undo**. There is nothing to undo: it never happened.
public enum CalendarWriteOutcome: Hashable, Sendable {
    /// Carries the id because a create's whole point is learning it — the
    /// server mints it, and the screen that opened the editor needs it to open
    /// the event.
    case saved(CalendarEventID)

    /// **The whole series is gone, and there is no bin.** `CalendarEvent/set`
    /// destroy is a real delete, unlike `Email/set` where destroy means Trash.
    case deleted

    /// The server answered and said no. ``reason`` is the server's own
    /// sentence, shown as detail under a translated lead — a generic message
    /// would hide the one thing that says what to correct.
    ///
    /// ``isForbidden`` is read from the error **type**, never guessed from
    /// `myRights`: rights grey a control out in advance, and this is what
    /// actually happened.
    case refused(reason: String, isForbidden: Bool)

    /// Names the host, because plMail users self-host and "can't reach
    /// nas.local" is the actionable half of the sentence.
    case unreachable(host: String)

    /// The server stopped offering a calendar between the editor opening and
    /// the save. A state, not a fault.
    case noCalendar

    /// Whether the cache now reflects what the server holds.
    public var didWrite: Bool {
        switch self {
        case .saved, .deleted: true
        case .refused, .unreachable, .noCalendar: false
        }
    }
}

extension CalendarWriteOutcome {
    /// A transport or method-level failure.
    ///
    /// `.methodFailed` is a refusal — the server answered — while
    /// `.unreachable` and `.untrustedCertificate` are not, and the two read
    /// differently on screen.
    public static func from(_ error: JMAPError) -> CalendarWriteOutcome {
        switch error {
        case .unreachable(let host, _), .untrustedCertificate(let host, _):
            return .unreachable(host: host)
        case .methodFailed(let type, let description, _):
            return .refused(
                reason: description ?? type.rawValue, isForbidden: type == .forbidden)
        default:
            return .refused(reason: String(describing: error), isForbidden: false)
        }
    }

    /// One object's refusal inside an otherwise-successful `CalendarEvent/set`.
    ///
    /// A `/set` succeeds at the method level and refuses per object, so a
    /// caller that only looked for a thrown ``JMAPKit/JMAPError`` would report
    /// a save that never happened as done.
    ///
    /// `invalidProperties` is spelled out with the offending names rather than
    /// as its bare type: "invalidProperties" tells a user nothing, and the list
    /// is the only part of the answer that says what to change.
    public static func from(_ error: CalendarSetError) -> CalendarWriteOutcome {
        let named = error.invalidProperties

        let reason =
            error.description
            ?? (named.isEmpty ? error.type.rawValue : named.joined(separator: ", "))

        return .refused(reason: reason, isForbidden: error.isReadOnlyCalendar)
    }
}
