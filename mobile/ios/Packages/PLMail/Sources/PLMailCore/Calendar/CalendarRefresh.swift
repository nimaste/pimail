import Foundation
public import JMAPKit

/// What one refresh of one window came to.
///
/// A closed set rather than a thrown error, because three of the four are
/// **states rather than failures** and the screens read differently for each.
/// An instance that publishes no calendar is supported, not broken; a refusal
/// is an answer; a transport failure is not an answer and names the host,
/// because plMail users self-host and "can't reach nas.local" is genuinely more
/// actionable than "the network is unavailable".
public enum CalendarRefresh: Hashable, Sendable {
    case refreshed(CalendarRefreshSummary)

    /// Not paired, or this server publishes no calendar account at all. **A
    /// state, not an error** — a user can delete their last mailbox and keep a
    /// calendar, and an install with no calendar is a supported install.
    case noCalendarAccount

    /// The server could not be reached. The cache still draws everything it
    /// last held, so this is a banner rather than an empty screen.
    case unreachable(host: String)

    /// The server answered, and said no. Carries its own words for
    /// diagnostics; the UI shows a translated sentence, since the server's is
    /// untranslated English written for a developer.
    case rejected(reason: String)

    /// The clamp left nothing to ask for — a window entirely outside the
    /// client's guaranteed horizon. Reported rather than queried, because an
    /// expanded window past the server's own horizon is refused **whole** with
    /// `cannotCalculateOccurrences` rather than answered short.
    case beyondHorizon
}

/// What a successful refresh moved.
public struct CalendarRefreshSummary: Hashable, Sendable {
    /// Series stored — the unit an editor writes through.
    public var series: Int
    /// Occurrences stored — the unit a grid draws.
    public var occurrences: Int
    /// Round trips made. One for the window, plus one per page beyond the
    /// first. Worth surfacing in diagnostics: the whole design of this feature
    /// is that a visible span costs one request.
    public var requests: Int

    /// **True does not mean anything is missing.** It means the client cannot
    /// promise nothing is — a different sentence, and the only honest one
    /// available while `materialisedHorizon` is a string nothing here may
    /// parse.
    public var mayBeIncomplete: Bool

    public init(
        series: Int = 0,
        occurrences: Int = 0,
        requests: Int = 0,
        mayBeIncomplete: Bool = false
    ) {
        self.series = series
        self.occurrences = occurrences
        self.requests = requests
        self.mayBeIncomplete = mayBeIncomplete
    }
}

extension CalendarRefresh {
    /// Maps a transport or method failure onto the outcome the screens branch
    /// on.
    ///
    /// `cannotCalculateOccurrences` is singled out because it is the one
    /// refusal with a remedy the client owns: ask for less. Everything else is
    /// reported in the server's own words rather than guessed at.
    public static func from(_ error: JMAPError) -> CalendarRefresh {
        switch error {
        case .unreachable(let host, _), .untrustedCertificate(let host, _):
            return .unreachable(host: host)
        case .methodFailed(let type, let description, _):
            if type == .cannotCalculateOccurrences { return .beyondHorizon }

            return .rejected(reason: description ?? type.rawValue)
        default:
            return .rejected(reason: String(describing: error))
        }
    }
}
