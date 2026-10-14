import Foundation
import JMAPKit
import OSLog
import Observation

/// The addresses this login can send from, and the one thing about them the
/// server will let a client change.
///
/// Reads from the store so the screen has something the instant it opens —
/// identities are synced with every refresh — and re-fetches behind that so a
/// rename made in the web UI turns up.
///
/// **Signatures are editable, and this used to say they were not.** The claim
/// was read from a stale checkout of the server; the current `IdentitySetMethod`
/// stores `htmlSignature` in the same per-alias setting the web composer reads,
/// so a signature written here is the one the browser signs with. `replyTo` and
/// `bcc` genuinely are refused, and are still not offered.
///
/// Signatures are saved and cleared through two separate calls on purpose —
/// ``save(signature:for:in:)`` and ``clearSignature(for:in:)`` — because the
/// server distinguishes *omitting* `htmlSignature` (leave it alone) from
/// sending it *empty* (this address signs with nothing). One method taking an
/// optional would make the destructive case the one a caller reaches by
/// accident.
@MainActor
@Observable
public final class IdentityEditor {
    /// One account's sendable addresses.
    public struct Group: Identifiable, Hashable, Sendable {
        public var accountKey: String
        public var accountID: AccountID
        public var accountName: String
        public var identities: [IdentitySnapshot]

        public var id: String { accountKey }
    }

    public private(set) var groups: [Group] = []
    /// True only until the first load lands, so the screen shows a spinner
    /// rather than an empty state it would immediately replace.
    public private(set) var isLoading = true
    /// A refresh that could not reach the server. The stored identities are
    /// still shown — they are what the composer will use either way — so this
    /// is a note, not a replacement for the list.
    public private(set) var refreshFailure: String?
    /// A rename the server refused.
    public private(set) var saveFailure: String?

    private let client: JMAPClient
    private let store: SyncStore
    private let accounts: [AccountSnapshot]
    private let logger = Logger(subsystem: "de.plmail", category: "identities")

    public init(client: JMAPClient, store: SyncStore, accounts: [AccountSnapshot]) {
        self.client = client
        self.store = store
        self.accounts = accounts
    }

    /// Cached first, then the server.
    public func load() async {
        await readFromStore()
        isLoading = false
        await refresh()
    }

    public func refresh() async {
        guard accounts.isEmpty == false else { return }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let calls = accounts.map {
                (account: $0, call: builder.add(IdentityGet(accountID: $0.accountID)))
            }
            let results = try await client.send(builder)

            for pair in calls {
                // Per account: one mailbox refusing `Identity/get` — a
                // disconnected provider, a permissions change — must not blank
                // the addresses of the ones that answered.
                guard let list = try? results.result(of: pair.call).list else { continue }

                try? await store.replaceIdentities(list, accountKey: pair.account.accountKey)
            }

            refreshFailure = nil
            await readFromStore()
        } catch {
            refreshFailure = String(
                localized: "Couldn't reach the server. Showing the addresses last synced.",
                bundle: .module)
            logger.error("Identity refresh failed: \(error, privacy: .public)")
        }
    }

    /// Renames one identity, server first.
    ///
    /// The opposite order to every other action in the app, and deliberately:
    /// mail actions are undoable, so an optimistic move that the server
    /// refuses can be quietly put back. A name is not undoable and is read
    /// aloud by every recipient's client, so it is worth the round trip to
    /// avoid showing a name as saved that was rejected.
    ///
    /// - Returns: Whether it was saved.
    @discardableResult
    public func rename(
        _ identity: IdentitySnapshot, in group: Group, to name: String
    ) async -> Bool {
        saveFailure = nil

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed != (identity.name ?? "") else { return true }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(
                IdentitySet.rename(identity.id, to: trimmed, accountID: group.accountID))
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            // A 200 is not success: `Identity/set` reports per-object refusals
            // in notUpdated, the same trap as `Email/set`.
            if let refused = result.notUpdated, refused.isEmpty == false {
                saveFailure = Self.describe(refused)
                logger.error("Rename refused: \(String(describing: refused), privacy: .public)")

                return false
            }
        } catch {
            saveFailure = String(
                localized: "Couldn't reach the server. The name wasn't saved.", bundle: .module)
            logger.error("Rename failed: \(error, privacy: .public)")

            return false
        }

        await refresh()

        return true
    }

    /// Stores a plain-text signature for one address.
    ///
    /// Sent as `textSignature`, not as hand-built HTML. The server escapes it —
    /// a signature containing `<b>` is a signature containing those five
    /// characters — and escaping in the client instead would mean two
    /// implementations of one rule, disagreeing on the first signature with an
    /// ampersand in it.
    ///
    /// A blank string is routed to ``clearSignature(for:in:)`` rather than sent
    /// as text, because the two are different requests and only one of them
    /// says *"sign with nothing"* in the spelling the server records.
    ///
    /// - Returns: Whether it was saved.
    @discardableResult
    public func save(
        signature text: String, for identity: IdentitySnapshot, in group: Group
    ) async -> Bool {
        guard SignatureText.isBlank(text) == false else {
            return await clearSignature(for: identity, in: group)
        }

        return await apply(
            IdentitySet(
                accountID: group.accountID,
                update: [identity.id: IdentitySet.IdentityPatch(textSignature: text)]))
    }

    /// Records that this address signs with nothing.
    ///
    /// An explicitly empty `htmlSignature`, which is a **stored statement** and
    /// not the absence of one: on an account that has its own signature it is
    /// the only way to stop this alias inheriting it. Omitting the key would
    /// leave the inherited signature in place and look, from here, exactly the
    /// same.
    ///
    /// - Returns: Whether it was saved.
    @discardableResult
    public func clearSignature(for identity: IdentitySnapshot, in group: Group) async -> Bool {
        await apply(
            IdentitySet.setHTMLSignature("", for: identity.id, accountID: group.accountID))
    }

    /// Sends one `Identity/set` and reports honestly on what came back.
    ///
    /// Factored out because a 200 is not success: `Identity/set` reports
    /// per-object refusals in `notUpdated`, the same trap as `Email/set`, and
    /// each caller writing that check itself is how one of them ends up
    /// without it.
    private func apply(_ method: IdentitySet) async -> Bool {
        saveFailure = nil

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(method)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            if let refused = result.notUpdated, refused.isEmpty == false {
                saveFailure = Self.describe(refused)
                logger.error(
                    "Identity/set refused: \(String(describing: refused), privacy: .public)")

                return false
            }
        } catch {
            saveFailure = String(
                localized: "Couldn't reach the server. Nothing was changed.", bundle: .module)
            logger.error("Identity/set failed: \(error, privacy: .public)")

            return false
        }

        await refresh()

        return true
    }

    /// Turns a per-object refusal into something a person can act on.
    ///
    /// `notFound` is not the error it sounds like, and it is the one a plMail
    /// user is most likely to see. An account with no alias rows still gets an
    /// `Identity/get` entry — a synthetic one, standing in for the account
    /// address itself, whose id is the *account's* id. `Identity/set` looks
    /// that id up among the account's aliases, does not find it, and says so.
    /// Reported verbatim it reads as "your address does not exist", which is
    /// alarming and wrong; what it means is that there is no row to rename.
    private static func describe(_ refusals: [IdentityID: JSONValue]) -> String {
        let type =
            refusals.values
            .compactMap { $0.objectValue?["type"]?.stringValue }
            .first

        return switch type {
        case "notFound":
            String(
                localized:
                    "This address isn't set up as an alias on the server, so its name comes from the account and can't be changed here.",
                bundle: .module)
        case "forbidden", "accountReadOnly":
            String(localized: "This account is read-only.", bundle: .module)
        default:
            String(localized: "The server wouldn't save that name.", bundle: .module)
        }
    }

    public func dismissSaveFailure() {
        saveFailure = nil
    }

    private func readFromStore() async {
        var built: [Group] = []

        for account in accounts {
            guard let identities = try? await store.identities(accountKey: account.accountKey),
                identities.isEmpty == false
            else { continue }

            built.append(
                Group(
                    accountKey: account.accountKey,
                    accountID: account.accountID,
                    accountName: account.displayName,
                    identities: identities.sorted { $0.email < $1.email }
                ))
        }

        groups = built
    }
}
