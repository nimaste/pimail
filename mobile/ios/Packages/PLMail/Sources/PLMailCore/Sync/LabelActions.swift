import Foundation
import JMAPKit
import OSLog
import Observation

/// Creating, renaming and deleting labels.
///
/// Deliberately not part of ``MailActions``. Everything there is optimistic and
/// undoable: the row moves first and the request follows, because the cost of
/// being wrong is a message in the wrong list for a second. These are neither.
///
/// - **Not optimistic.** A label's id comes from the server, and everything
///   that refers to a label refers to it by that id. Inventing one locally so a
///   row could appear immediately would mean every message labelled in the
///   meantime carried an id that never existed.
/// - **Not undoable.** Undoing a delete would have to recreate the label *and*
///   reattach it to every message that carried it, and the server does not
///   remember which those were once the binding is gone. An undo bar that
///   silently restored an empty label would be a lie, so deletion asks first
///   instead.
///
/// A label is per-account, because a JMAP Mailbox is a label *binding*.
/// Deleting one here leaves the user's other accounts untouched — which is the
/// server's behaviour, and worth saying out loud in the UI.
@MainActor
@Observable
public final class LabelActions {
    /// Why the last attempt did not work, in words that name the rule.
    public private(set) var failure: String?

    /// True while a request is in flight, so a form can refuse a second press
    /// rather than creating two labels with the same name — the second of
    /// which the server refuses, leaving an error next to a label that did get
    /// created.
    public private(set) var isBusy = false

    private let client: JMAPClient
    /// Re-reads mailbox structure once the server has agreed.
    ///
    /// A closure rather than the ``MailSyncService`` itself: this needs one
    /// method of it, and taking the whole thing would make every test here
    /// need a live server connection to construct one.
    private let refresh: @MainActor @Sendable () async -> Void
    private let logger = Logger(subsystem: "de.plmail", category: "labels")

    public init(
        client: JMAPClient,
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.client = client
        self.refresh = refresh
    }

    public func dismissFailure() {
        failure = nil
    }

    // MARK: - Creating

    /// Creates a label on one account.
    ///
    /// `color` is the colour to give it, or nil for "no colour chosen". Nil is
    /// a real third state and not a synonym for `.gray`: a label with no colour
    /// falls back to the hashed tint, and one coloured grey on purpose stays
    /// grey.
    ///
    /// - Returns: The new mailbox's id, or nil if the server refused. Returned
    ///   rather than discarded so a picker can create a label and apply it in
    ///   one gesture, which is the only reason to offer creation from a picker
    ///   at all.
    @discardableResult
    public func create(
        named name: String, parentID: MailboxID? = nil, color: LabelColor? = nil,
        accountID: AccountID
    ) async -> MailboxID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Checked here as well as on the server, because the server's answer
        // is a refusal after a round trip and this one is instant. The server
        // remains the authority; this is only about which of two identical
        // outcomes the user waits for.
        guard let complaint = Self.complaint(about: name) else {
            return await send(
                MailboxSet.create(
                    name: name, parentID: parentID, color: color, accountID: accountID),
                accountID: accountID
            ) { result in
                result.created?[MailboxSet.creationID]?.id
            }
        }

        failure = complaint

        return nil
    }

    /// The rules plMail enforces on a name, phrased as the fix rather than as
    /// the violation. Nil when the name is fine.
    public static func complaint(about name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            return String(localized: "A label needs a name.", bundle: .module)
        }

        // Gmail encodes hierarchy in the name, so a slash here would silently
        // create a nested label on the provider rather than one called "a/b".
        if name.contains("/") {
            return String(
                localized: "A label name can't contain a slash. Use a parent label to nest it.",
                bundle: .module)
        }

        return nil
    }

    /// Whether a sibling of `parentID` on `accountKey` is already called this.
    ///
    /// Offered so a form can say so while the name is being typed. The server
    /// enforces the rule regardless; this only decides whether the user finds
    /// out before or after pressing Create.
    ///
    /// Case-insensitive, which is *stricter* than the server's exact-match
    /// comparison. Deliberately: "work" and "Work" side by side in a sidebar
    /// are indistinguishable at a glance, so warning about the second is more
    /// use than allowing it.
    public static func nameIsTaken(
        _ name: String,
        parentID: MailboxID?,
        accountKey: String,
        among mailboxes: [MailboxSnapshot]
    ) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard name.isEmpty == false else { return false }

        return mailboxes.contains {
            $0.accountKey == accountKey
                && $0.parentID == parentID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    // MARK: - Renaming

    public func rename(
        _ mailboxID: MailboxID, to name: String, accountID: AccountID
    ) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let complaint = Self.complaint(about: name) {
            failure = complaint
            return false
        }

        return await send(
            MailboxSet.rename(mailboxID, to: name, accountID: accountID),
            accountID: accountID
        ) { result in
            // The id has to appear in `updated`. A server that answers 200
            // with every bucket empty has neither done it nor refused it, and
            // reporting that as a rename leaves the sidebar showing a name
            // nothing else in the world agrees with.
            result.updated?.keys.contains(mailboxID) == true ? true : nil
        } ?? false
    }

    // MARK: - Recolouring

    /// Sets or clears one label's colour, leaving its name and parent alone.
    ///
    /// Its own request rather than a parameter on ``rename(_:to:accountID:)``:
    /// the server treats every property *mentioned* in a patch as a change, so
    /// folding the two together would mean a rename that also sent the colour
    /// the client last knew about — overwriting whatever the web UI did in the
    /// meantime with stale data the user never touched.
    ///
    /// A nil `color` clears it. Allowed on system labels too: plMail
    /// deliberately does not gate `color` on mutability, because recolouring
    /// Inbox's chip breaks none of the invariants that renaming it would.
    ///
    /// - Returns: Whether the server said it did it. False covers both a
    ///   refusal and a 200 whose `updated` bucket never mentions the label,
    ///   which is a server that has neither done it nor said why.
    public func recolor(
        _ mailboxID: MailboxID, to color: LabelColor?, accountID: AccountID
    ) async -> Bool {
        await send(
            MailboxSet.recolor(mailboxID, to: color, accountID: accountID),
            accountID: accountID
        ) { result in
            result.updated?.keys.contains(mailboxID) == true ? true : nil
        } ?? false
    }

    // MARK: - Re-parenting

    /// Moves a label under `parentID`, or to the top level when that is nil.
    ///
    /// The parent is a **binding** id in this account. Passing one from
    /// another account would be an id the server cannot resolve, which comes
    /// back as `invalidProperties` and reads to the user as "there's already a
    /// label with that name here" — so callers filter by `accountKey` first.
    ///
    /// - Returns: Whether the server said it did it.
    public func reparent(
        _ mailboxID: MailboxID, under parentID: MailboxID?, accountID: AccountID
    ) async -> Bool {
        // A label cannot be its own parent, and the server answers that with a
        // refusal the UI would then have to explain. Refusing here costs a
        // round trip and says the same thing.
        guard parentID != mailboxID else {
            failure = String(
                localized: "A label can't be nested inside itself.", bundle: .module)
            return false
        }

        return await send(
            MailboxSet.reparent(mailboxID, to: parentID, accountID: accountID),
            accountID: accountID
        ) { result in
            result.updated?.keys.contains(mailboxID) == true ? true : nil
        } ?? false
    }

    // MARK: - Deleting

    public func delete(_ mailboxID: MailboxID, accountID: AccountID) async -> Bool {
        await send(
            MailboxSet.destroy(mailboxID, accountID: accountID),
            accountID: accountID
        ) { result in
            // `destroyed` is the only proof. A 200 whose destroyed array is
            // empty means the server declined, and reading the status as the
            // answer is how a label that is still there disappears from the
            // sidebar until the next sync puts it back.
            result.destroyed?.contains(mailboxID) == true ? true : nil
        } ?? false
    }

    // MARK: - Machinery

    /// Sends one `Mailbox/set` and reads the outcome out of it.
    ///
    /// `outcome` returns nil for "the server did not do it", which is what
    /// turns an empty `created`/`destroyed` into a visible failure rather than
    /// a silent no-op.
    private func send<Value>(
        _ request: MailboxSet,
        accountID: AccountID,
        outcome: (MailboxSet.Result) -> Value?
    ) async -> Value? {
        guard isBusy == false else { return nil }

        failure = nil
        isBusy = true

        defer { isBusy = false }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(request)
            let results = try await client.send(builder)

            if let error = results.failure(of: call) { throw error }

            let result = try results.result(of: call)

            // Per-object refusals come back inside a 200. Checked before the
            // outcome, so the user is told *why* rather than just that
            // nothing happened.
            for refusals in [result.notCreated?.values.map { $0 }] {
                if let first = refusals?.first {
                    failure = Self.describe(first)
                    logger.error("Refused: \(String(describing: first), privacy: .public)")

                    return nil
                }
            }

            for refusals in [
                result.notUpdated?.values.map { $0 }, result.notDestroyed?.values.map { $0 },
            ] {
                if let first = refusals?.first {
                    failure = Self.describe(first)
                    logger.error("Refused: \(String(describing: first), privacy: .public)")

                    return nil
                }
            }

            guard let value = outcome(result) else {
                failure = String(
                    localized: "The server didn't make that change.", bundle: .module)
                return nil
            }

            // The sidebar, both pickers and the manager all read the sync
            // service's mailbox list, and nothing local recomputes it. Without
            // this a label the user just made does not exist as far as the
            // rest of the app is concerned until the next refresh.
            await refresh()

            return value
        } catch {
            failure = String(
                localized: "Couldn't reach the server. Nothing was changed.", bundle: .module)
            logger.error("Label change failed: \(error, privacy: .public)")

            return nil
        }
    }

    /// Turns one of plMail's refusal types into something a person can act on.
    static func describe(_ refusal: JSONValue) -> String {
        switch refusal.objectValue?["type"]?.stringValue {
        case "invalidProperties":
            // The only two rules a client can hit here after the local checks:
            // a duplicate sibling name, and a parent that has gone away.
            String(
                localized: "There's already a label with that name here.", bundle: .module)
        case "mailboxHasChild":
            String(
                localized: "Delete the labels nested inside this one first.", bundle: .module)
        case "forbidden":
            String(
                localized: "Built-in labels like Inbox and Sent can't be changed.",
                bundle: .module)
        case "notFound":
            String(localized: "That label no longer exists.", bundle: .module)
        case "stateMismatch":
            String(
                localized: "Your labels changed elsewhere. Try again.", bundle: .module)
        default:
            String(localized: "The server didn't accept that change.", bundle: .module)
        }
    }
}
