import Foundation

/// One address the server offers while somebody types a recipient.
///
/// A JMAP `EmailAddress` (`{name, email}`) with the ranking signals hung off
/// it, which is why it carries an ``address`` rather than being one: the extra
/// keys are what let this client explain or re-sort a list rather than having
/// to trust the order it was given.
///
/// There is **no id**, deliberately, and nothing here may be cached as an
/// object: the server publishes no `Contact/get`, so an id would invite a
/// re-fetch against a method that does not exist. The address is the identity,
/// and the server's `(user, email)` uniqueness agrees.
public struct ContactSuggestion: Decodable, Sendable, Hashable {
    public var name: String?
    public var email: String
    /// How many times this address has been seen in a header, in either
    /// direction. The primary sort key, and the whole reason to ask the server
    /// at all: a correspondent written to twice a year outranks a mailing list
    /// seen once, and no prefix match on the device can know that.
    public var frequency: Int?
    /// When it was last seen. The tie-break under ``frequency``.
    public var lastSeenAt: UTCDate?
    /// Whether the user has ever *written* to this address rather than merely
    /// heard from it. Not a sort key — enough to mark a real correspondent.
    public var isCorrespondent: Bool?

    /// The form every other part of this client speaks.
    ///
    /// An empty `name` is dropped to nil rather than passed on: the server
    /// sends null for an address it only ever saw bare, and `"" <a@b>` renders
    /// as a formatting bug.
    public var address: EmailAddress {
        guard let name, name.isEmpty == false else { return EmailAddress(email: email) }

        return EmailAddress(name: name, email: email)
    }
}

/// `Contact/autocomplete` — frequency-ranked recipient suggestions from the
/// user's own mail.
///
/// The one thing a composing client cannot do for itself. Ranking has to be
/// over the whole address book, and a phone that has just been set up has
/// synced too little mail to have one; the server harvested this from headers
/// and already holds every address in it.
///
/// **Not RFC 8621, and not the JMAP Contacts draft** — hence `autocomplete`
/// rather than `query`. There is no `Contact/get`, no id space, and nothing
/// here a client may create or destroy, so a `/query` returning ids would
/// promise a pattern the server does not implement.
///
/// **The capability is `mail`, not the server's `urn:plmail:params:jmap:contacts`,
/// and that is not an oversight.** `JmapProcessor::assertCapabilities()` checks
/// only that every URN in `using` is one the server *supports*; it does not gate
/// method dispatch on the capability a method belongs to. So declaring the
/// contacts URN buys this call nothing — while an instance that predates the
/// extension fails the **entire request** with `unknownCapability` rather than
/// the one call, taking the message list down with the type-ahead. Declaring a
/// URN every plMail has always supported costs nothing and cannot do that.
///
/// A server too old to know the method answers `unknownMethod` for this call
/// alone, which is a failure the caller can absorb by falling back to the
/// device's own suggestions. That is the whole degradation story.
///
/// **Sending this is a change to a promise.** Every other suggestion in this
/// app is computed on the device; this sends a prefix of what the user is
/// typing to their server. It is their own server, which is the point of the
/// product, but it is still a different statement from "your contacts never
/// leave the device" — so the caller is expected to have asked.
public struct ContactAutocomplete: JMAPMethod {
    public static let name = "Contact/autocomplete"
    public static let capability = Capability.mail

    /// The server's default when `limit` is omitted, and the number the web
    /// composer asks for. Repeated here so a suggestion list is not a different
    /// length on the phone.
    public static let defaultLimit = 8

    /// The server's cap. Low on purpose: the query is four case-folded `LIKE`s
    /// with no index behind them, so a client asking for a thousand rows per
    /// keystroke is asking for a sequential scan per keystroke — on hardware
    /// that is frequently a Raspberry Pi also serving the message list.
    ///
    /// The server caps rather than refuses, and echoes what it used. Asking for
    /// more than this is not an error; it is a request that quietly means this.
    public static let maxLimit = 50

    /// The shortest fragment worth sending.
    ///
    /// One letter matches most of an address book, so the round trip buys
    /// nothing and the keystroke is disclosed for no result. The same floor the
    /// device address book already applies.
    public static let minimumQueryLength = 2

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var query: String
        public var limit: Int

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case query, limit
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        /// Echoed because it was normalised — the server trims before it
        /// reaches SQL. A stale answer can be spotted by comparing it with what
        /// is being typed now, rather than being merged over a fresher one.
        public var query: String
        /// Echoed because it was capped. A client that asked for 500 and got 50
        /// can see that here rather than conclude the address book holds 50
        /// people.
        public var limit: Int?
        public var list: [ContactSuggestion]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case query, limit, list
        }
    }

    public var arguments: Arguments

    /// `query` is what the user has typed so far, trimmed here as well as on
    /// the server: an empty query is refused with `invalidArguments` rather
    /// than answered, because "no matches" and "you sent no query" are
    /// different facts and only one of them is worth showing.
    ///
    /// `limit` is capped rather than passed on, because the server caps rather
    /// than refuses — a client that does not cap cannot tell a truncated list
    /// from a small address book.
    public init(accountID: AccountID, query: String, limit: Int = Self.defaultLimit) {
        arguments = Arguments(
            accountID: accountID,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: min(max(1, limit), Self.maxLimit)
        )
    }
}
