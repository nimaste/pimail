import Foundation
import JMAPKit
import OSLog
import Observation

/// Gets queued mail out once the server can be reached.
///
/// Kept separate from the composer because the composer is gone by the time
/// most of this matters: someone writes a message on a train, dismisses the
/// sheet, and the send has to happen later without any UI being on screen.
@MainActor
@Observable
public final class OutboxSender {
    /// How many messages are waiting. Drives the sidebar row, so it is the one
    /// piece of state a view observes.
    public private(set) var pendingCount = 0
    public private(set) var isSending = false

    /// The earliest time something in the queue becomes due, or nil when
    /// nothing is being held back. Read by the app when it goes to the
    /// background, to ask the system for a wake-up nearer that time.
    public private(set) var nextDueAt: Date?

    /// Exposed so the composer files into the same queue this drains. Two
    /// `Outbox` values over one directory would work — it is all on disk — but
    /// sharing one keeps the count and the queue from disagreeing.
    public let queue: Outbox
    private let client: JMAPClient
    private let store: SyncStore
    private let logger = Logger(subsystem: "de.plmail", category: "outbox")
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?

    /// Messages this pass is in the middle of a request about.
    ///
    /// A drain is single-flighted, but a discard or a cancel is not: tapping
    /// Discard while a send is in flight used to remove a message that had
    /// already gone, so the row vanished as though it were never sent. A claim
    /// held across the request is what makes "still here" and "not yet sent"
    /// the same statement.
    private var inFlight: Set<UUID> = []

    public init(outbox: Outbox, client: JMAPClient, store: SyncStore) {
        queue = outbox
        self.client = client
        self.store = store
    }

    public func refreshCount() async {
        let queued = await queue.pending()

        pendingCount = queued.count
        armWake(among: queued)
    }

    public func pending() async -> [Outbox.PendingMessage] {
        await queue.pending()
    }

    /// Drops a queued message. The only way out for one the server will never
    /// accept — a recipient that does not exist, an account since removed.
    ///
    /// **Device-held rows only.** A message the server has taken over is not
    /// this device's to forget: deleting the row locally would leave the mail
    /// on its way with nothing on the phone able to call it back, which is
    /// worse than not offering the button. Callers route through ``cancel(_:)``,
    /// which does the right thing for both.
    ///
    /// A message with a request in flight is left alone. Removing one that has
    /// already been accepted makes a sent message look like it never existed.
    public func discard(_ id: UUID) async {
        guard inFlight.contains(id) == false else { return }

        await cancel(id)
    }

    /// Releases a message that was being held back, and sends it now.
    ///
    /// A server-held message has to be called back first: the hold is the
    /// server's, so releasing it here without cancelling there would send the
    /// mail twice — once now and once when the hold expires.
    public func sendNow(_ id: UUID) async {
        guard inFlight.contains(id) == false else { return }

        if let message = await queue.pending().first(where: { $0.id == id }),
            message.handover != nil
        {
            guard await releaseHold(message) else { return }
        }

        await queue.reschedule(id, to: nil)
        await refreshCount()
        drain()
    }

    /// Moves a scheduled message to a different time.
    ///
    /// Same rule as ``sendNow(_:)``: a schedule the server owns is changed by
    /// cancelling it and re-offering it, never by rewriting the local row and
    /// hoping the two agree.
    public func reschedule(_ id: UUID, to date: Date) async {
        guard inFlight.contains(id) == false else { return }

        if let message = await queue.pending().first(where: { $0.id == id }),
            message.handover != nil
        {
            guard await releaseHold(message) else { return }
        }

        await queue.reschedule(id, to: date)
        await refreshCount()
    }

    /// Tries to send everything waiting.
    ///
    /// Single-flighted: this is called from app foreground, from the sync
    /// service when a refresh succeeds, and from the composer right after
    /// queuing. Two drains at once would send the same message twice.
    public func drain() {
        guard drainTask == nil else { return }

        drainTask = Task { [weak self] in
            defer { self?.drainTask = nil }

            await self?.drainNow()
        }
    }

    /// Waits for a drain that is already running.
    ///
    /// Almost nothing waits on a drain — the composer closes the moment the
    /// message is on disk, which is the point. The exception is the background
    /// refresh, which must not report itself finished while a send is still in
    /// flight: the system is entitled to suspend the process the instant it
    /// does, and the send would be cut off mid-request.
    public func settle() async {
        await drainTask?.value
    }

    // MARK: - Draining

    /// One pass over the queue: retire what the server has finished with, hand
    /// over what it can hold, send what is due.
    ///
    /// The order matters. Reconciling first means a message the server has
    /// already sent is off the queue before anything considers sending it
    /// again, and handing over before sending means a message that becomes due
    /// during the pass is sent once rather than handed over and then sent.
    private func drainNow() async {
        await reconcileHandovers()
        await handOverScheduled()

        let queued = await queue.pending()

        pendingCount = queued.count
        armWake(among: queued)

        // Everything held back for later is left exactly where it is — by this
        // device or by the server. A drain happens on foreground, on the
        // network returning and on launch, moments that say nothing about
        // whether a scheduled message is ready.
        let now = Date.now
        let due = queued.filter { $0.isDue(at: now) }

        guard due.isEmpty == false else { return }

        isSending = true
        defer { isSending = false }

        for message in due {
            // Claimed before the request, released after. Without it a discard
            // tapped while a send is in flight removes a message that has
            // already gone, and the row disappears as though it were never
            // sent.
            guard claim(message.id) else { continue }

            defer { inFlight.remove(message.id) }

            do {
                let accepted = try await send(
                    message, hold: message.undoGraceSeconds.map { .seconds($0) })

                // A grace period is a handover like any other: the server is
                // holding the mail, this device must never send it again, and
                // the row survives only so the undo has something to cancel.
                if let sendAt = accepted.sendAt, accepted.wasHeld {
                    await queue.recordHandover(
                        message.id,
                        Outbox.PendingMessage.Handover(
                            submissionID: accepted.emailID, sendAt: sendAt))
                } else {
                    await queue.remove(message.id)
                }
            } catch let refusal as HoldRefused {
                // The server would not take the hold but the draft is written.
                // Sending it now would ignore a grace the user was promised, so
                // the message goes out on the next pass with no envelope — one
                // drain later at worst, and never twice, because the draft id
                // is on disk.
                await queue.recordDraft(message.id, emailID: refusal.emailID)
                await queue.reschedule(message.id, to: nil)
                logger.error(
                    "Hold refused, sending unheld next pass: \(refusal.emailID, privacy: .public)")
            } catch {
                // Stop at the first failure rather than working through the
                // rest. They share one server: if this one could not go out,
                // neither can the next, and hammering an unreachable NAS with
                // the whole queue is exactly what the circuit breaker exists to
                // prevent.
                await queue.recordFailure(message.id, reason: Self.describe(error))
                logger.error("Outbox send failed: \(error, privacy: .public)")

                break
            }
        }

        await refreshCount()
    }

    /// Whether this pass may touch a message, or another one already is.
    private func claim(_ id: UUID) -> Bool {
        inFlight.insert(id).inserted
    }

    // MARK: - The handover

    /// Offers every device-held schedule to the server.
    ///
    /// **This is the only place a queued message leaves this device without
    /// being sent from it**, and the whole of the "never twice, never dropped"
    /// guarantee is the order of the three writes below: the draft is written
    /// first, the submission second, and the row is marked handed over only
    /// after the server has said it accepted one. A crash between any two
    /// leaves a draft in Drafts and a message still in the outbox — visible,
    /// recoverable, and sendable exactly once, because the draft id is on disk
    /// and plMail sends each Email at most once.
    ///
    /// Nothing here retries on its own. A drain is caused by the app coming
    /// forward, the network returning, a launch or a granted background
    /// refresh, and a message whose handover was refused waits for the next one
    /// behind ``handoverBackoff``.
    private func handOverScheduled() async {
        let now = Date.now
        let candidates = await queue.pending().filter {
            $0.isDeviceHeld && $0.isDue(at: now) == false && readyToRetryHandover($0, now: now)
        }

        guard candidates.isEmpty == false else { return }

        for message in candidates {
            guard let sendAfter = message.sendAfter else { continue }
            guard claim(message.id) else { continue }

            defer { inFlight.remove(message.id) }

            do {
                let accepted = try await send(message, hold: .until(sendAfter))

                await queue.recordDraft(message.id, emailID: accepted.emailID)

                // The server's own answer, never the time that was asked for.
                // They agree on this server and would not on one that rounds,
                // and what the Outbox screen says has to be when the mail
                // actually leaves.
                await queue.recordHandover(
                    message.id,
                    Outbox.PendingMessage.Handover(
                        submissionID: accepted.emailID, sendAt: accepted.sendAt ?? sendAfter))
            } catch let refusal as HoldRefused {
                // Past the server's ceiling, or an envelope it would not take.
                // The message stays exactly where it is and goes out the way it
                // always did — the device-held fallback this queue exists for.
                // The draft id is kept so the eventual send rewrites that draft
                // rather than leaving a second copy in Drafts.
                await queue.recordDraft(message.id, emailID: refusal.emailID)
                await queue.recordFailure(message.id, reason: Self.deviceHeldFallback)
                logger.notice(
                    "Server would not hold until \(sendAfter, privacy: .public); keeping it here")
            } catch {
                // Unreachable, most likely. The schedule is still honoured by
                // this device, which is what it was before the attempt.
                await queue.recordFailure(message.id, reason: Self.describe(error))
                logger.error("Handover failed: \(error, privacy: .public)")

                break
            }
        }
    }

    /// Whether enough time has passed to offer this message to the server
    /// again.
    ///
    /// Doubling per failed attempt, capped. A server that refuses the hold —
    /// because it is too far ahead, or because it is an older build — would
    /// otherwise be asked once per drain forever, which on an app that drains
    /// every time it comes forward is a request per glance at the phone.
    private func readyToRetryHandover(_ message: Outbox.PendingMessage, now: Date) -> Bool {
        guard let lastAttemptAt = message.lastAttemptAt, message.attempts > 0 else { return true }

        let multiplier = Double(1 << min(message.attempts, 8))

        return now.timeIntervalSince(lastAttemptAt) >= Self.handoverBackoff * multiplier
    }

    /// The floor between handover attempts, doubled per failure.
    static let handoverBackoff: TimeInterval = 60

    /// How long after its release time a handed-over row is worth asking about.
    ///
    /// **Never retire on silence before the release time**, and never leave a
    /// row saying "leaving at 08:00" at half past nine. The grace is what sits
    /// between those two rules: a submission a minute overdue is a worker that
    /// has not got to it, not a schedule to question.
    static let retirementGrace: TimeInterval = 120

    /// Asks the server what happened to the sends it took over, and acts on the
    /// answer.
    ///
    /// Only for rows whose release time has passed by ``retirementGrace``, so a
    /// message scheduled for next Tuesday costs nothing until next Tuesday.
    /// One request, on a drain, never on a timer of its own.
    private func reconcileHandovers() async {
        let cutoff = Date.now.addingTimeInterval(-Self.retirementGrace)
        let overdue = await queue.pending().filter {
            guard let handover = $0.handover else { return false }

            return handover.sendAt <= cutoff
        }

        guard overdue.isEmpty == false else { return }

        // Grouped by account: EmailSubmission/get is per account, and a phone
        // with three connected mailboxes must not send one request per message.
        let byAccount = Dictionary(grouping: overdue) { $0.accountID }

        for (accountID, messages) in byAccount {
            let ids = messages.compactMap { $0.handover?.submissionID }

            do {
                var builder = RequestBuilder(session: try await client.session())
                let get = builder.add(EmailSubmissionGet(accountID: accountID, ids: ids))
                let results = try await client.send(builder)

                if let error = results.failure(of: get) { throw error }

                let result = try results.result(of: get)
                let byID = Dictionary(result.list.map { ($0.id, $0) }) { first, _ in first }
                let notFound = Set(result.notFound ?? [])

                for message in messages {
                    guard let submissionID = message.handover?.submissionID else { continue }

                    if notFound.contains(submissionID) {
                        // The server has no record of a submission for this
                        // Email, so nothing is going to send it. Handing it
                        // back is the only answer that does not silently drop
                        // somebody's mail.
                        await queue.clearHandover(message.id)
                        continue
                    }

                    switch byID[submissionID]?.undoStatus {
                    case .final, .canceled:
                        // Gone, or called off elsewhere. Either way this row has
                        // nothing left to say and the bytes are no longer the
                        // only copy.
                        await queue.remove(message.id)

                    case .pending, .unknown, .none:
                        // Still on its way, or a status this build does not
                        // recognise. Keeping the row is the conservative answer:
                        // a receipt nobody needed is cheaper than a send nobody
                        // can see.
                        continue
                    }
                }
            } catch {
                // Silence is not evidence. The rows stay and the next drain
                // asks again.
                logger.error("Could not reconcile submissions: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Cancelling

    /// Calls back a message the server is holding.
    ///
    /// The real undo, and the reason the composer no longer blocks for five
    /// seconds: this cancels a submission that exists rather than a call that
    /// was never made. Reliable while the submission is held, which is every
    /// case this method is offered for.
    ///
    /// - Returns: what actually happened, because the three outcomes lead
    ///   somewhere different and "Undone" over delivered mail is the one
    ///   sentence this whole path exists to avoid.
    @discardableResult
    public func cancel(_ id: UUID) async -> CancelOutcome {
        guard let message = await queue.pending().first(where: { $0.id == id }) else {
            return .notFound
        }

        guard let handover = message.handover else {
            // Never handed over: this device is the only thing holding it, and
            // removing the row is a complete cancel.
            await queue.remove(id)
            await refreshCount()

            return .cancelled
        }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let cancel = builder.add(
                EmailSubmissionSet.cancel(handover.submissionID, accountID: message.accountID))
            let results = try await client.send(builder)

            if let error = results.failure(of: cancel) { throw error }

            let result = try results.result(of: cancel)

            if let refusal = result.notUpdated?[handover.submissionID] {
                let type = refusal.objectValue?["type"]?.stringValue

                // "The mail has gone" and "there was no submission" are not the
                // same fact and only one of them leaves anything to do.
                if type == "cannotUnsend" {
                    await queue.remove(id)

                    return .alreadySent
                }

                await queue.clearHandover(id)

                return .notFound
            }

            await queue.remove(id)
            await refreshCount()

            return .cancelled
        } catch {
            logger.error("Cancel failed: \(error, privacy: .public)")

            return .failed(Self.describe(error))
        }
    }

    /// Takes a message back off the server so this device may act on it again.
    ///
    /// The half of a cancel that keeps the message: used by "send now" and by
    /// re-timing, where the mail is not being called off, only taken out of the
    /// server's hands first. Sequenced this way round on purpose — a local
    /// change made before the server has let go is a second copy of the mail
    /// waiting to be released.
    ///
    /// - Returns: false when the server would not let go, in which case nothing
    ///   local has been touched and the schedule the user can see is still the
    ///   one that will happen.
    private func releaseHold(_ message: Outbox.PendingMessage) async -> Bool {
        guard let handover = message.handover else { return true }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let cancel = builder.add(
                EmailSubmissionSet.cancel(handover.submissionID, accountID: message.accountID))
            let results = try await client.send(builder)

            if let error = results.failure(of: cancel) { throw error }

            if try results.result(of: cancel).notUpdated?[handover.submissionID] != nil {
                // Refused, and the two reasons both mean "leave it alone": the
                // mail has gone, or there was never a submission. Reconcile
                // will sort the row out on the next drain from the server's own
                // answer rather than from a guess made here.
                return false
            }

            await queue.clearHandover(message.id)

            return true
        } catch {
            logger.error("Could not release a held send: \(error, privacy: .public)")

            return false
        }
    }

    /// What a cancel actually did.
    public enum CancelOutcome: Equatable, Sendable {
        case cancelled
        /// The mail had already left. Reported rather than swallowed: a person
        /// who is told "undone" about a message their recipient is reading has
        /// been lied to at the worst possible moment.
        case alreadySent
        /// Nothing was submitted, so there was nothing to call back.
        case notFound
        case failed(String)
    }

    // MARK: - Waking

    /// Arranges to drain again when the next scheduled message falls due.
    ///
    /// **A timer, not a promise.** It only runs while the process does, which
    /// is why nothing depends on it: a message becomes due on the wall clock,
    /// and the drains on foreground, on the network returning, on launch and on
    /// the background refresh are what actually get it out. This is the case
    /// where the app happens to be open at the moment — worth having, because
    /// otherwise a message scheduled for ten minutes' time sits there while
    /// somebody watches it.
    ///
    /// **Handed-over rows are counted too**, at their release time plus the
    /// retirement grace, so a send the server completed while the app was open
    /// stops being shown as pending without waiting for the user to background
    /// the app and come back.
    private func armWake(among queued: [Outbox.PendingMessage]) {
        let now = Date.now
        let deviceHeld = queued.filter(\.isDeviceHeld).compactMap(\.sendAfter)
        let handedOver = queued.compactMap {
            $0.handover?.sendAt.addingTimeInterval(Self.retirementGrace)
        }
        let next = (deviceHeld + handedOver).filter { $0 > now }.min()

        wakeTask?.cancel()
        nextDueAt = deviceHeld.filter { $0 > now }.min()

        guard let next else { return }

        wakeTask = Task { [weak self] in
            // A second past the due time rather than exactly on it: waking a
            // hair early would find nothing due, re-arm, and spin.
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 1))

            guard Task.isCancelled == false else { return }

            self?.drain()
        }
    }

    // MARK: - Sending

    /// What the server said about a submission it took.
    private struct Accepted {
        var emailID: String
        /// The release time the server chose, which is what gets recorded.
        var sendAt: Date?
        /// Whether an envelope was sent at all, so an unheld send is not
        /// mistaken for a hold that happened to resolve to now.
        var wasHeld: Bool
    }

    /// The draft was written and the submission was refused.
    ///
    /// Carries the Email id because that is the thing worth keeping: the draft
    /// exists, and a retry that does not name it leaves a second copy in Drafts
    /// and — for a message with no id yet — risks sending twice.
    private struct HoldRefused: Error {
        var emailID: String
    }

    /// The one send path.
    ///
    /// The composer queues and then asks for a drain rather than sending
    /// directly, so there is exactly one implementation of "turn this into a
    /// draft and submit it" — two would drift, and the one that drifted would
    /// be the one nobody watches.
    private func send(
        _ message: Outbox.PendingMessage, hold: SubmissionHold?
    ) async throws -> Accepted {
        var files: [DraftAttachment] = []

        for attachment in message.attachments {
            // Already on the server: listed by blob id and never re-uploaded.
            // A `p-` id re-listed on the same draft keeps the stored bytes
            // exactly where they are.
            if let blobID = attachment.blobID {
                files.append(
                    DraftAttachment(
                        blobID: BlobID(blobID), type: attachment.type, name: attachment.name))

                continue
            }

            let blob = try await client.upload(
                attachment.data, type: attachment.type, accountID: message.accountID)

            files.append(
                DraftAttachment(
                    blobID: blob.blobID, type: attachment.type, name: attachment.name))
        }

        let content = DraftContent(
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            subject: message.subject,
            text: message.body,
            html: message.html,
            inReplyTo: message.inReplyTo,
            references: message.references,
            // A whole value, on purpose and only here: the send is the one
            // moment the composer's list is definitive. Every part the message
            // still names is in it, including the ones that were never
            // downloaded.
            attachments: .whole(files)
        )

        var builder = RequestBuilder(session: try await client.session())

        // Continuing an existing draft rewrites it; a new message creates one
        // and refers to it by creation id in the same round trip. The single
        // round trip is the point — over a home uplink it is the difference
        // between sending feeling instant and feeling like two requests.
        if let editingEmailID = message.editingEmailID {
            let update = builder.add(
                DraftUpdate(
                    accountID: message.accountID,
                    emailID: EmailID(editingEmailID),
                    content: content))
            let submit = builder.add(
                EmailSubmissionSet(
                    accountID: message.accountID,
                    emailID: editingEmailID,
                    identityID: message.identityID,
                    hold: hold))

            let results = try await client.send(builder)

            if let error = results.failure(of: update) { throw error }
            if let refused = try results.result(of: update).notUpdated, refused.isEmpty == false {
                throw SendFailure.refused
            }

            return try accept(
                results.failure(of: submit), try results.result(of: submit),
                emailID: editingEmailID, hold: hold)
        }

        guard
            let drafts = try await store.mailbox(role: .drafts, accountKey: message.accountKey)
        else {
            throw SendFailure.noDraftsMailbox
        }

        let draft = EmailCreate.Draft(drafts: drafts, from: message.from, content: content)
        let create = builder.add(EmailCreate(accountID: message.accountID, draft: draft))
        let submit = builder.add(
            EmailSubmissionSet(
                accountID: message.accountID,
                emailID: "#\(EmailCreate.creationID)",
                identityID: message.identityID,
                hold: hold))

        let results = try await client.send(builder)

        if let error = results.failure(of: create) { throw error }

        let created = try results.result(of: create)

        if let refused = created.notCreated, refused.isEmpty == false {
            throw SendFailure.refused
        }

        guard let emailID = created.created?[EmailCreate.creationID]?.id else {
            throw SendFailure.refused
        }

        // Written down before the submission is even inspected. This is the
        // narrow window a crash can land in, and an Email id on disk is what
        // turns a retry from "create and submit a second copy" into "re-submit
        // the one the server already has".
        await queue.recordDraft(message.id, emailID: emailID.rawValue)

        return try accept(
            results.failure(of: submit), try results.result(of: submit),
            emailID: emailID.rawValue, hold: hold)
    }

    /// Reads the submission half of a send.
    ///
    /// A refusal with an envelope attached is treated as the envelope being
    /// refused, because it is the only thing about the call that could be: the
    /// Email exists, the identity came from `Identity/get`, and the recipients
    /// were validated in the composer. That inference is safe in the direction
    /// it matters — being wrong means the message stays on this device and goes
    /// out from here, which is where it already was.
    private func accept(
        _ failure: (any Error)?,
        _ result: EmailSubmissionSet.Result,
        emailID: String,
        hold: SubmissionHold?
    ) throws -> Accepted {
        if let failure { throw failure }

        if let refused = result.notCreated, refused.isEmpty == false {
            guard hold != nil else { throw SendFailure.refused }

            throw HoldRefused(emailID: emailID)
        }

        let accepted = result.created?[EmailSubmissionSet.creationID]

        return Accepted(emailID: emailID, sendAt: accepted?.sendAt?.date, wasHeld: hold != nil)
    }

    enum SendFailure: Error {
        case noDraftsMailbox
        case refused
    }

    /// Shown on a row the server declined to hold.
    ///
    /// Not an error — the message is safe and will be sent — but the promise
    /// changed, and the person who scheduled it is entitled to know that the
    /// minute is now this phone's problem rather than their server's.
    static let deviceHeldFallback = String(
        localized: "Your server won't hold mail this far ahead. This phone will send it.",
        bundle: .module)

    private static func describe(_ error: any Error) -> String {
        switch error {
        case SendFailure.noDraftsMailbox:
            String(localized: "This account has no Drafts mailbox to send from.", bundle: .module)
        case SendFailure.refused:
            String(localized: "The server wouldn't accept this message.", bundle: .module)
        case JMAPError.notAuthenticated:
            String(localized: "Sign in again to send this.", bundle: .module)
        default:
            String(localized: "Waiting for the server.", bundle: .module)
        }
    }
}
