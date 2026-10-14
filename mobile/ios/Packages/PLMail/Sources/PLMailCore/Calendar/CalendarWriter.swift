import Foundation
public import JMAPKit
import OSLog

/// Creates, changes and deletes events — **outside the mail outbox, and
/// deliberately.**
///
/// The outbox exists for operations that are safe to replay. These are not:
/// there is no `ifInState` to build a conflict story on (the calendar state is
/// the literal `"fixed"`, so a guard could only ever answer "nothing has
/// changed"), and a refusal replayed is a loop that terminates never. So there
/// is no queue, no retry and no undo here. A write is attempted once and its
/// answer is reported.
///
/// **A create is server-first and a change is optimistic.** The two differ
/// because the id matters: a created event's id is minted by the server, so
/// there is nothing to draw until it answers, and a placeholder row would have
/// to be reconciled against a real one on a surface with no change feed to
/// reconcile against. An update or a delete already has an id, so it lands in
/// the cache immediately and is **rolled back** on refusal or transport
/// failure.
public struct CalendarWriter: Sendable {
    private let client: JMAPClient
    private let store: CalendarStore
    private let logger = Logger(subsystem: "de.plmail", category: "calendar")

    public init(client: JMAPClient, store: CalendarStore) {
        self.client = client
        self.store = store
    }

    // MARK: - Creating

    /// Server-first: nothing is written locally until the id comes back.
    public func create(
        _ draft: EventDraft, accountID: AccountID, accountKey: String
    ) async -> CalendarWriteOutcome {
        do {
            let session = try await client.session()
            var builder = RequestBuilder(session: session)
            let call = builder.add(
                CalendarEventSet(accountID: accountID, create: ["new1": draft.newEvent()]))

            let result = try await client.send(builder).result(of: call)

            if let failure = result.notCreated?["new1"] ?? result.firstFailure {
                return .from(failure)
            }

            guard let created = result.created?["new1"] else {
                // A `/set` that neither created nor refused is a contract the
                // client cannot act on. Reported as a refusal rather than as a
                // success, because reporting success would leave the user
                // looking for an event that does not exist.
                return .refused(reason: CalendarEventSet.name, isForbidden: false)
            }

            return .saved(created.id)
        } catch let error as JMAPError {
            logger.error("Event create failed: \(String(describing: error), privacy: .public)")

            return .from(error)
        } catch {
            return .refused(reason: String(describing: error), isForbidden: false)
        }
    }

    // MARK: - Changing

    /// Optimistic, then reconciled against the answer.
    public func update(
        _ id: CalendarEventID,
        to draft: EventDraft,
        accountID: AccountID,
        accountKey: String
    ) async -> CalendarWriteOutcome {
        await write(id: id, accountKey: accountKey) {
            try await store.applyLocally(draft, to: id, accountKey: accountKey)
        } send: { session in
            var builder = RequestBuilder(session: session)
            let call = builder.add(
                CalendarEventSet(accountID: accountID, update: [id: draft.patch()]))
            let result = try await client.send(builder).result(of: call)

            if let failure = result.notUpdated?[id] ?? result.firstFailure {
                return .from(failure)
            }

            // The **key** is the whole answer: `updated[id]` is null, meaning
            // no properties changed beyond what was asked for.
            guard result.updated?.keys.contains(id) == true else {
                return .refused(reason: CalendarEventSet.name, isForbidden: false)
            }

            return .saved(id)
        }
    }

    /// **Removes the whole series, and it cannot be undone.** A calendar has no
    /// bin, unlike mail where destroy means Trash. The only way to cancel a
    /// single occurrence is a `recurrenceOverrides` entry marking it excluded,
    /// which is a different operation with a different control.
    public func delete(
        _ id: CalendarEventID, accountID: AccountID, accountKey: String
    ) async -> CalendarWriteOutcome {
        await write(id: id, accountKey: accountKey) {
            try await store.removeLocally(id, accountKey: accountKey)
        } send: { session in
            var builder = RequestBuilder(session: session)
            let call = builder.add(CalendarEventSet(accountID: accountID, destroy: [id]))
            let result = try await client.send(builder).result(of: call)

            if let failure = result.notDestroyed?[id] ?? result.firstFailure {
                return .from(failure)
            }

            guard result.destroyed?.contains(id) == true else {
                return .refused(reason: CalendarEventSet.name, isForbidden: false)
            }

            return .deleted
        }
    }

    // MARK: - The shared shape

    /// Capture, apply, send, and put it back if the answer is anything but yes.
    ///
    /// One function for both changing paths because the rollback is the part
    /// that must not be got wrong twice: a refusal that left half an optimistic
    /// edit in the cache would look, on the next refresh, exactly like somebody
    /// else's change — on a surface with no change feed to disprove it.
    private func write(
        id: CalendarEventID,
        accountKey: String,
        apply: () async throws -> Void,
        send: (Session) async throws -> CalendarWriteOutcome
    ) async -> CalendarWriteOutcome {
        var rollback: CalendarWriteRollback?

        do {
            let session = try await client.session()
            rollback = try await store.captureRollback(for: id, accountKey: accountKey)
            try await apply()

            let outcome = try await send(session)

            if outcome.didWrite == false, let rollback {
                try await store.rollBack(rollback)
            }

            return outcome
        } catch let error as JMAPError {
            logger.error("Event write failed: \(String(describing: error), privacy: .public)")
            await restore(rollback)

            return .from(error)
        } catch {
            await restore(rollback)

            return .refused(reason: String(describing: error), isForbidden: false)
        }
    }

    /// A rollback that itself fails is logged and swallowed: the cache is
    /// reconstructible from one windowed query, so the worst case is a stale
    /// row until the next refresh — and throwing here would replace a reported
    /// refusal with an unreported crash.
    private func restore(_ rollback: CalendarWriteRollback?) async {
        guard let rollback else { return }

        do {
            try await store.rollBack(rollback)
        } catch {
            logger.error("Calendar rollback failed: \(String(describing: error), privacy: .public)")
        }
    }
}
