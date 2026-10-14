import Foundation
import JMAPKit
import OSLog

/// Messages written but not yet accepted by the server.
///
/// **Deliberately not in the SwiftData store.** That store's governing rule is
/// that everything in it is reconstructible from the server, which is what
/// licenses deleting and rebuilding it on any migration or corruption failure.
/// An unsent message is the one thing in this app that exists nowhere else —
/// putting it there would mean a schema change could silently throw away
/// somebody's mail.
///
/// So it lives in Application Support: backed up, and never reclaimed by the
/// system the way `Caches` may be.
///
/// One directory per message rather than one big file. Attachments are bytes,
/// sometimes tens of megabytes of them, and base64 inside a single JSON
/// document would mean rewriting every queued message to append one.
public actor Outbox {
    /// Internal rather than private so a test can plant a message file in the
    /// shape an older build wrote, which is the only way to check that the
    /// format is still lenient enough to read it.
    let directory: URL
    private let logger = Logger(subsystem: "de.plmail", category: "outbox")

    /// - Parameter serverID: Scopes the queue to one server, so signing into a
    ///   different one cannot inherit mail addressed from the previous
    ///   account.
    public init(serverID: String) {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory

        directory =
            base
            .appending(path: "plmail-outbox", directoryHint: .isDirectory)
            .appending(path: Self.slug(serverID), directoryHint: .isDirectory)

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Everything waiting, oldest first — the order it will be sent in.
    public func pending() -> [PendingMessage] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        return
            entries
            .filter { $0.hasDirectoryPath }
            .compactMap(load(from:))
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    public func count() -> Int {
        pending().count
    }

    /// Files a message for later.
    @discardableResult
    public func enqueue(_ message: PendingMessage) throws -> PendingMessage {
        let folder = directory.appending(path: message.id.uuidString, directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Attachments first: a metadata file that referenced bytes which had
        // not landed yet would be a queued message that could never be sent.
        for attachment in message.attachments where attachment.isStoredOnServer == false {
            try attachment.data.write(
                to: folder.appending(path: attachment.fileName), options: .atomic)
        }

        let record = Record(message)
        try JSONEncoder().encode(record).write(
            to: folder.appending(path: "message.json"), options: .atomic)

        return message
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(
            at: directory.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    /// Moves a scheduled message, or releases it to go out at the next drain.
    ///
    /// Rewrites the same folder rather than removing and re-adding, so a crash
    /// between the two cannot lose a message that was only being retimed.
    public func reschedule(_ id: UUID, to date: Date?) {
        guard var message = pending().first(where: { $0.id == id }) else { return }

        message.sendAfter = date

        rewriteMetadata(message)
    }

    /// Records that an attempt failed, so the UI can say so and a message that
    /// will never send can be told apart from one that has not been tried.
    public func recordFailure(_ id: UUID, reason: String) {
        guard var message = pending().first(where: { $0.id == id }) else { return }

        message.attempts += 1
        message.lastFailure = reason
        message.lastAttemptAt = .now

        rewriteMetadata(message)
    }

    /// Writes down the draft the server made for this message.
    ///
    /// **The half-step that stops a crash sending mail twice.** A new message
    /// is created and submitted in one round trip, so between the server
    /// committing and this queue forgetting the message there is a window in
    /// which the process can die. Without an Email id the next drain would
    /// create a *second* draft and submit that; with one it re-submits the same
    /// Email, and plMail sends each Email at most once — a submission's id is
    /// the Email id, `MessageSendService` is a no-op once `sentAt` is set, and
    /// re-submitting a held one re-times the single submission rather than
    /// adding another.
    public func recordDraft(_ id: UUID, emailID: String) {
        guard var message = pending().first(where: { $0.id == id }),
            message.editingEmailID != emailID
        else { return }

        message.editingEmailID = emailID

        rewriteMetadata(message)
    }

    /// Records that the server has taken this message over.
    ///
    /// After this the row is a receipt, not a queue entry:
    /// ``PendingMessage/isDue(at:)`` is false for it forever, so nothing on
    /// this device can send it again. It stays on disk only so the Outbox
    /// screen can show the schedule and cancel it without a round trip.
    public func recordHandover(_ id: UUID, _ handover: PendingMessage.Handover) {
        guard var message = pending().first(where: { $0.id == id }) else { return }

        message.handover = handover
        message.lastFailure = nil

        rewriteMetadata(message)
    }

    /// Hands a message back to this device.
    ///
    /// The undo of ``recordHandover(_:_:)``, and the only way a row becomes
    /// sendable again: used when the server says the submission it was holding
    /// is gone — cancelled elsewhere, or never really accepted — and the bytes
    /// here are once more the only copy.
    public func clearHandover(_ id: UUID) {
        guard var message = pending().first(where: { $0.id == id }), message.handover != nil
        else { return }

        message.handover = nil

        rewriteMetadata(message)
    }

    /// Rewrites one message's metadata without touching its bytes.
    ///
    /// ``enqueue(_:)`` rewrites every attachment as well, which is right when a
    /// message is first filed and wrong for the small bookkeeping writes —
    /// recording a draft id, a handover, a failure. Those happen on the send
    /// path, and re-writing thirty megabytes of video to note a string is the
    /// kind of cost that turns a flaky uplink into a device that never gets
    /// through its queue.
    ///
    /// Atomic, so a crash mid-write leaves the previous metadata rather than
    /// half a JSON document, which would read back as a message that no longer
    /// exists.
    private func rewriteMetadata(_ message: PendingMessage) {
        let folder = directory.appending(path: message.id.uuidString, directoryHint: .isDirectory)

        guard FileManager.default.fileExists(atPath: folder.path) else { return }

        try? JSONEncoder().encode(Record(message)).write(
            to: folder.appending(path: "message.json"), options: .atomic)
    }

    // MARK: - Storage

    private func load(from folder: URL) -> PendingMessage? {
        guard let data = try? Data(contentsOf: folder.appending(path: "message.json")),
            let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }

        let attachments = record.attachments.compactMap { attachment -> Attachment? in
            // A server-held part has no file here and must not be dropped for
            // not having one — that would be the queue quietly removing an
            // attachment the message names.
            if let blobID = attachment.blobID {
                return Attachment(
                    fileName: attachment.fileName, name: attachment.name, type: attachment.type,
                    data: Data(), blobID: blobID)
            }

            guard let bytes = try? Data(contentsOf: folder.appending(path: attachment.fileName))
            else { return nil }

            return Attachment(
                fileName: attachment.fileName, name: attachment.name, type: attachment.type,
                data: bytes)
        }

        return record.message(attachments: attachments)
    }

    /// Directory names come from a server id, which is a hostname and may
    /// contain characters a path should not. Internal rather than private
    /// because a slug that lets `../` through writes outside the queue.
    static func slug(_ serverID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))

        return String(
            serverID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    /// The on-disk shape. Separate from ``PendingMessage`` so the bytes are not
    /// part of what gets encoded.
    private struct Record: Codable {
        var id: UUID
        var accountKey: String
        var accountID: String
        var identityID: String
        var from: EmailAddress?
        var to: [EmailAddress]
        var cc: [EmailAddress]
        var bcc: [EmailAddress]
        var subject: String
        var body: String
        /// Optional so a queue written before formatting existed still
        /// decodes. Those messages send as plain text, which is what they
        /// were.
        var html: String?
        var inReplyTo: [String]?
        var references: [String]?
        var editingEmailID: String?
        var queuedAt: Date
        /// Optional for the same reason `html` is: a queue written by a build
        /// that had no send-later still decodes, and its messages are due now,
        /// which is what they always were.
        var sendAfter: Date?
        /// Optional so a queue written before the undo window became a server
        /// hold still decodes. Nil means "no grace", which is what those
        /// messages were filed with.
        var undoGrace: Int?
        var attempts: Int
        var lastFailure: String?
        var lastAttemptAt: Date?
        /// Optional so a queue written before server-side scheduling still
        /// decodes. Nil has always meant "this device still owns it", which is
        /// exactly right for a message written by a build that had no other
        /// option.
        var handover: HandoverRecord?
        var attachments: [AttachmentRecord]

        struct HandoverRecord: Codable {
            var submissionID: String
            var sendAt: Date
            var acceptedAt: Date
        }

        struct AttachmentRecord: Codable {
            var fileName: String
            var name: String
            var type: String
            /// Optional so a queue written before drafts carried server-held
            /// parts still decodes. Those entries have bytes on disk, which is
            /// what nil has always meant.
            var blobID: String?
        }

        init(_ message: PendingMessage) {
            id = message.id
            accountKey = message.accountKey
            accountID = message.accountID.rawValue
            identityID = message.identityID.rawValue
            from = message.from
            to = message.to
            cc = message.cc
            bcc = message.bcc
            subject = message.subject
            body = message.body
            html = message.html
            inReplyTo = message.inReplyTo
            references = message.references
            editingEmailID = message.editingEmailID
            queuedAt = message.queuedAt
            sendAfter = message.sendAfter
            undoGrace = message.undoGraceSeconds
            attempts = message.attempts
            lastFailure = message.lastFailure
            lastAttemptAt = message.lastAttemptAt
            handover = message.handover.map {
                HandoverRecord(
                    submissionID: $0.submissionID, sendAt: $0.sendAt, acceptedAt: $0.acceptedAt)
            }
            attachments = message.attachments.map {
                AttachmentRecord(
                    fileName: $0.fileName, name: $0.name, type: $0.type, blobID: $0.blobID)
            }
        }

        func message(attachments: [Attachment]) -> PendingMessage {
            var message = PendingMessage(
                id: id,
                accountKey: accountKey,
                accountID: AccountID(accountID),
                identityID: IdentityID(rawValue: identityID),
                from: from,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                body: body,
                html: html,
                inReplyTo: inReplyTo,
                references: references,
                editingEmailID: editingEmailID,
                attachments: attachments
            )
            message.queuedAt = queuedAt
            message.sendAfter = sendAfter
            message.undoGraceSeconds = undoGrace
            message.attempts = attempts
            message.lastFailure = lastFailure
            message.lastAttemptAt = lastAttemptAt
            message.handover = handover.map {
                PendingMessage.Handover(
                    submissionID: $0.submissionID, sendAt: $0.sendAt, acceptedAt: $0.acceptedAt)
            }

            return message
        }
    }
}

extension Outbox {
    /// One file waiting to go out with a queued message.
    public struct Attachment: Hashable, Sendable {
        /// Unique within the message's folder. Not the display name: two files
        /// called `photo.jpg` are ordinary, and a name from a sender is not
        /// something to build a path from.
        public var fileName: String
        public var name: String
        public var type: String
        public var data: Data
        /// Set when the bytes are already on the server — a part carried over
        /// from a reopened draft, or one being forwarded.
        ///
        /// The queue holds no copy in that case, deliberately: downloading a
        /// 30 MB video to a phone in order to upload it again to the machine it
        /// is already on is the one thing forwarding by blob id exists to
        /// avoid. Nil means "these bytes exist nowhere else", which is what the
        /// outbox is for.
        public var blobID: String?

        public var isStoredOnServer: Bool { blobID != nil }

        public init(
            fileName: String = UUID().uuidString,
            name: String,
            type: String,
            data: Data,
            blobID: String? = nil
        ) {
            self.fileName = fileName
            self.name = name
            self.type = type
            self.data = data
            self.blobID = blobID
        }
    }

    /// A message written but not yet accepted by the server.
    public struct PendingMessage: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var accountKey: String
        public var accountID: AccountID
        public var identityID: IdentityID
        public var from: EmailAddress?
        public var to: [EmailAddress]
        public var cc: [EmailAddress] = []
        public var bcc: [EmailAddress] = []
        public var subject: String
        /// The plain-text alternative.
        public var body: String
        /// The formatted body, already serialised. Serialised at queue time
        /// rather than at send time so the bytes on disk are exactly what will
        /// go out — a message that renders differently after a relaunch would
        /// be impossible to reason about.
        public var html: String?
        public var inReplyTo: [String]?
        public var references: [String]?
        /// Set when this began as an existing draft, so sending rewrites that
        /// message rather than leaving a stale copy behind.
        public var editingEmailID: String?
        public var attachments: [Attachment] = []

        public var queuedAt = Date.now

        /// How long the server should hold this before releasing it, for a send
        /// that is going out now but should stay recallable.
        ///
        /// **A hold, not a delayed call.** The old undo window kept the
        /// composer on screen for five seconds and submitted nothing, so a
        /// process death inside it dropped the send silently while the user
        /// watched the sheet close. Submitting at once with `HOLDFOR` inverts
        /// both halves: the mail leaves on time if the app dies, and the undo
        /// is a real server operation against a submission that exists.
        ///
        /// Nil means send immediately, which is also what a zero here means and
        /// what every message filed before this existed meant.
        public var undoGraceSeconds: Int?

        /// When this may go out, for a message held back on purpose. Nil is
        /// the ordinary case: send at the next opportunity.
        ///
        /// A time rather than a flag plus a time, so "scheduled" and "when"
        /// cannot disagree.
        public var sendAfter: Date?
        public var attempts = 0
        public var lastFailure: String?
        public var lastAttemptAt: Date?

        /// The server-held submission this became, once the server accepted
        /// one. Nil means this device is still the only thing that will send
        /// it.
        ///
        /// **This is the whole of the handover, and the reason it cannot send
        /// twice.** The two mechanisms are never both live for one message,
        /// because being handed over is a property of the message rather than
        /// a state kept alongside it: ``isDue(at:)`` reads it, and a row with a
        /// handover is never due again no matter how far past `sendAfter` the
        /// clock gets. It is not deleted, because a deleted row is a schedule
        /// nobody can see or call back — see ``Handover``.
        public var handover: Handover?

        /// A submission the server has taken responsibility for.
        ///
        /// The bytes stay on disk beside it rather than being thrown away.
        /// That is deliberate and costs a copy of the message: a cancel hands
        /// the mail back to this device, and a queue that had discarded the
        /// body would have to re-fetch a draft it may no longer be able to
        /// reach in order to honour an undo.
        public struct Handover: Hashable, Sendable {
            /// The submission's id, which on plMail **is** the Email id: the
            /// server stores no submission row and reconstructs one from three
            /// columns on the message. Kept under its own name anyway, because
            /// a client that hard-codes the equality cannot talk to a server
            /// that stops honouring it.
            public var submissionID: String

            /// When the server says the mail leaves — **its answer, never the
            /// time that was asked for**. The two agree on this server and
            /// would not on one that rounds, and what a person is shown has to
            /// be when their mail actually goes.
            public var sendAt: Date

            /// When this device was told. Used to retire a row that the server
            /// has stopped reporting: silence before the release time means
            /// nothing, and silence long after it means the mail has gone.
            public var acceptedAt: Date

            public init(submissionID: String, sendAt: Date, acceptedAt: Date = .now) {
                self.submissionID = submissionID
                self.sendAt = sendAt
                self.acceptedAt = acceptedAt
            }
        }

        /// Whether the sender may take this one now.
        ///
        /// A message with no `sendAfter` is always due — including every
        /// message written by a build that predates scheduling.
        ///
        /// **A handed-over message is never due.** The server is holding it;
        /// sending it from here as well would deliver the same mail twice, and
        /// this guard is the single place that cannot happen.
        public func isDue(at now: Date = .now) -> Bool {
            guard handover == nil else { return false }
            guard let sendAfter else { return true }

            return sendAfter <= now
        }

        /// Whether this message is waiting on a clock this device owns.
        ///
        /// The distinction the Outbox screen has to draw and the caveat text
        /// turns on: a device-held message really does go out "at the first
        /// check after this time", and a server-held one really does leave with
        /// the phone in a drawer. Saying either sentence over the other case is
        /// the failure this exists to prevent.
        public var isDeviceHeld: Bool {
            handover == nil && sendAfter != nil
        }

        /// When this message is expected to leave, whoever is holding it.
        public var expectedSendAt: Date? {
            handover?.sendAt ?? sendAfter
        }

        public var displayRecipient: String {
            to.first.map { $0.name ?? $0.email } ?? ""
        }
    }
}
