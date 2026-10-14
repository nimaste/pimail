import Contacts
import Foundation
import JMAPKit
import OSLog

/// Where recipient suggestions come from.
///
/// Two sources, deliberately kept separate until the last moment. Mail already
/// synced knows who you actually correspond with; the address book knows people
/// you have never emailed from this device — a new colleague, someone whose
/// card arrived over AirDrop. Neither is a superset of the other, and the
/// ranking between them is the interesting part.
public protocol ContactSource: Sendable {
    /// Addresses whose name or email begins with, or contains, `fragment`.
    func addresses(matching fragment: String) async -> [EmailAddress]
}

/// The system address book.
///
/// Access is asked for **when someone first types a recipient**, not at launch.
/// A mail client demanding the address book on first run, before it has shown
/// you a single message, is the behaviour that teaches people to say no.
public actor SystemContacts: ContactSource {
    private let store = CNContactStore()
    private let logger = Logger(subsystem: "de.plmail", category: "contacts")

    /// Cached because `CNContactStore.enumerate` is not free and this is called
    /// on a keystroke. Contacts do not change often enough for a session-length
    /// cache to be wrong in a way anyone notices.
    private var cache: [EmailAddress]?
    private var hasAsked = false

    public init() {}

    public func addresses(matching fragment: String) async -> [EmailAddress] {
        let fragment = fragment.trimmingCharacters(in: .whitespaces).lowercased()

        // Two characters before touching the address book at all: one letter
        // matches most of it, and the result is a permission prompt for a list
        // nobody can use.
        guard fragment.count >= 2 else { return [] }

        guard let all = await everyone() else { return [] }

        return all.filter {
            $0.email.lowercased().contains(fragment)
                || ($0.name?.lowercased().contains(fragment) ?? false)
        }
    }

    private func everyone() async -> [EmailAddress]? {
        if let cache { return cache }

        guard await isAuthorised() else { return nil }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey]
        let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
        var found: [EmailAddress] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = CNContactFormatter.string(from: contact, style: .fullName)

                for entry in contact.emailAddresses {
                    let email = entry.value as String

                    guard email.isEmpty == false else { continue }

                    found.append(EmailAddress(name: name, email: email))
                }
            }
        } catch {
            // A refused or broken address book is not an error worth showing.
            // Suggestions simply come from mail, as they did before.
            logger.error("Could not read contacts: \(error, privacy: .public)")

            return nil
        }

        cache = found

        return found
    }

    private func isAuthorised() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return true

        case .notDetermined:
            // Only once per launch. Repeatedly asking a system that has already
            // said "not now" is how an app ends up permanently denied.
            guard hasAsked == false else { return false }

            hasAsked = true

            return (try? await store.requestAccess(for: .contacts)) ?? false

        default:
            return false
        }
    }
}

/// Merges the two sources into one ordered list.
///
/// Pure, and therefore the part that can actually be tested — the address book
/// itself cannot be, not without a device and a person tapping Allow.
public enum RecipientSuggestions {
    /// Correspondents first, then the address book.
    ///
    /// Somebody you have emailed is a better guess than somebody whose card you
    /// happen to hold, and on a phone only the first few suggestions are ever
    /// seen. Within each group the incoming order is kept: mail arrives most
    /// recent first, and contacts arrive in the address book's own sort.
    ///
    /// Matching is on a prefix first and a substring second, because typing
    /// "ada" should offer Ada before it offers everyone at `nomad.example`.
    public static func merge(
        correspondents: [EmailAddress],
        contacts: [EmailAddress],
        matching fragment: String,
        limit: Int = 5
    ) -> [EmailAddress] {
        let fragment = fragment.trimmingCharacters(in: .whitespaces).lowercased()

        guard fragment.count >= 2 else { return [] }

        var seen: Set<String> = []
        var prefix: [EmailAddress] = []
        var substring: [EmailAddress] = []

        for address in correspondents + contacts {
            let key = address.email.lowercased()

            // The same person is usually in both lists. Whichever source got
            // there first wins, which is what puts correspondents on top.
            guard key.isEmpty == false, seen.insert(key).inserted else { continue }

            let name = address.name?.lowercased() ?? ""

            // Per word, not just the whole string: a surname is a normal thing
            // to type, and "love" should rank Ada Lovelace as a prefix match
            // rather than burying her among everyone at nomad.example.
            let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })

            if key.hasPrefix(fragment) || words.contains(where: { $0.hasPrefix(fragment) }) {
                prefix.append(address)
            } else if key.contains(fragment) || name.contains(fragment) {
                substring.append(address)
            }
        }

        return Array((prefix + substring).prefix(limit))
    }
}

// MARK: - The server's address book

/// Whether recipient suggestions may be asked for from the server.
///
/// **This exists because the answer changes a promise the app makes.** Every
/// other suggestion in this client is computed on the device: from mail already
/// synced, and from the system address book, which is what
/// `NSContactsUsageDescription` tells the user. Calling `Contact/autocomplete`
/// sends a prefix of what is being typed to the server on a debounce.
///
/// Two halves, worth separating before deciding:
///
/// - The **addresses** are not new information. The server harvested them from
///   the user's own mail headers and already holds every one of them.
/// - The **keystrokes** are. The server learns what was typed, when, and from
///   which account — and when a match comes from the device address book rather
///   than from mail, it learns a name it had no other way to know.
///
/// On a box the user owns and administers this is a small thing, and it is the
/// whole premise of the product. It is still a change, so it is asked rather
/// than assumed: ``undecided`` is the shipped default and means "ask", not
/// "yes". A silent opt-in would be the app quietly editing its own privacy
/// notice.
public enum ServerSuggestionConsent: String, Sendable, CaseIterable {
    /// Never asked. Nothing is sent, and the composer offers the choice the
    /// first time the question is live — while somebody is actually typing a
    /// recipient, where it can be answered in context rather than in a settings
    /// screen nobody visits.
    case undecided
    case allowed
    case declined

    /// Whether a lookup may go out. Only an explicit yes counts.
    public var permitsLookup: Bool { self == .allowed }
}

/// Where the answer is kept.
///
/// `UserDefaults` rather than the SwiftData store, deliberately: the store's
/// governing rule is that everything in it is reconstructible from the server,
/// and it is deleted and rebuilt on any open failure. A privacy answer rebuilt
/// as "ask again" would be merely annoying; rebuilt as anything else it would
/// be the app forgetting a decision about what it may disclose.
public struct ServerSuggestionPreference: Sendable {
    /// Namespaced like every other key this app writes, so a rename of the
    /// bundle cannot collide with a system default.
    static let key = "de.plmail.compose.serverSuggestions"

    /// `UserDefaults` is thread-safe but not `Sendable`, and this value is read
    /// from an actor on every keystroke. Held unchecked rather than made a
    /// global: a test needs its own suite so one run cannot answer the privacy
    /// question for the next.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var consent: ServerSuggestionConsent {
        get {
            defaults.string(forKey: Self.key)
                .flatMap(ServerSuggestionConsent.init(rawValue:)) ?? .undecided
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

/// The server's own address book, ranked by how often each address is written
/// to or heard from.
///
/// The one thing a composing client cannot do for itself: ranking has to be
/// over the whole address book, and a phone set up this morning has synced too
/// little mail to have one.
///
/// **Fails silently and completely.** An instance without the extension answers
/// `unknownMethod` for this call, which is an ordinary supported server rather
/// than a fault, and a phone in a lift answers nothing at all. Either way the
/// caller gets an empty list and the device's own suggestions are what the user
/// sees — which is exactly what they saw before this existed.
public actor ServerContacts: ContactSource {
    private let client: JMAPClient
    private let accountID: AccountID
    private let preference: ServerSuggestionPreference
    private let logger = Logger(subsystem: "de.plmail", category: "contacts")

    public init(
        client: JMAPClient,
        accountID: AccountID,
        preference: ServerSuggestionPreference = ServerSuggestionPreference()
    ) {
        self.client = client
        self.accountID = accountID
        self.preference = preference
    }

    public func addresses(matching fragment: String) async -> [EmailAddress] {
        let fragment = fragment.trimmingCharacters(in: .whitespaces)

        // The consent is read per lookup rather than captured at init: a
        // composer left open across a change of mind must not go on sending
        // fragments because it was built before the answer changed.
        guard preference.consent.permitsLookup else { return [] }

        // The same floor the device address book applies, and for the stronger
        // reason here: one letter matches most of an address book, so the round
        // trip buys nothing and the keystroke is disclosed for no result.
        guard fragment.count >= ContactAutocomplete.minimumQueryLength else { return [] }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let suggest = builder.add(
                ContactAutocomplete(accountID: accountID, query: fragment))
            let results = try await client.send(builder)

            if let error = results.failure(of: suggest) { throw error }

            let result = try results.result(of: suggest)

            // The server echoes the query because it normalised it. A reply to
            // a fragment that is no longer being typed is discarded rather than
            // merged, so a slow answer cannot overwrite a fresh one.
            guard result.query.caseInsensitiveCompare(fragment) == .orderedSame else { return [] }

            // Already ranked — frequency, then recency. Kept in the order it
            // arrived, because re-sorting it here would be a second ranking and
            // the whole point of asking is that there is only one.
            return result.list.map(\.address)
        } catch {
            logger.error("Server suggestions unavailable: \(error, privacy: .public)")

            return []
        }
    }
}

/// Two sources asked at once, merged in the order they were given.
///
/// The device address book is a **supplement**, not a re-ranking: it holds
/// people the user has never mailed, which is precisely what the server cannot
/// know. Merging by lowercased address with first-source-wins keeps the
/// server's ranking on top, and the local answer is what remains when the
/// request fails — so a phone in a lift still suggests.
public struct CombinedContacts: ContactSource {
    private let sources: [any ContactSource]

    public init(_ sources: [any ContactSource]) {
        self.sources = sources
    }

    public func addresses(matching fragment: String) async -> [EmailAddress] {
        var found: [EmailAddress] = []

        // Sequentially, not concurrently. The server half is a request to
        // hardware that is frequently a Raspberry Pi advertising four
        // concurrent slots, shared with the message list the user may still be
        // scrolling; the address-book half is a permission prompt the first
        // time. Neither is worth a millisecond of overlap on a keystroke.
        for source in sources {
            found += await source.addresses(matching: fragment)
        }

        var seen: Set<String> = []

        return found.filter { seen.insert($0.email.lowercased()).inserted }
    }
}
