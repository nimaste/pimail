import Foundation

/// Creating a draft with `Email/set create`.
///
/// Goes through the same draft writer the web composer uses, so a draft made
/// here is the same object the browser would have made.
public struct EmailCreate: JMAPMethod {
    public static let name = "Email/set"
    public static let capability = Capability.mail

    public struct Draft: Encodable, Sendable {
        public var mailboxIDs: JMAPIDSet<MailboxID>
        public var keywords: KeywordSet
        public var from: [EmailAddress]?
        public var to: [EmailAddress]?
        public var cc: [EmailAddress]?
        public var bcc: [EmailAddress]?
        public var subject: String?
        /// Threading is by RFC Message-ID, so a reply that omits these starts
        /// a new conversation instead of continuing one.
        public var inReplyTo: [String]?
        public var references: [String]?
        /// The part list, **not** `bodyStructure`.
        ///
        /// RFC 8621 allows either, but the server's draft writer reads
        /// `textBody`/`htmlBody` and keys them into `bodyValues`. Sending
        /// `bodyStructure` instead is silently ignored — the draft is created
        /// with everything else intact and no body at all, which looks like
        /// the text was lost rather than never read.
        public var textBody: [BodyPart]?
        /// The formatted body, when there is one.
        ///
        /// The server's draft writer prefers `htmlBody` and falls back to
        /// `textBody`. Verified against a live server: when both are sent,
        /// plMail keeps the HTML and **regenerates** the plain text from it,
        /// discarding what was sent — so `textBody` here is for other JMAP
        /// clients that might read the draft, not for plMail.
        public var htmlBody: [BodyPart]?
        public var bodyValues: [String: BodyValue]?
        /// Files, named by the blob ids a prior upload returned. Omitted
        /// entirely when there are none — an empty array is a different thing
        /// to say than nothing.
        public var attachments: [Attachment]?

        private enum CodingKeys: String, CodingKey {
            case mailboxIDs = "mailboxIds"
            case keywords, from, to, cc, bcc, subject, inReplyTo, references
            case textBody, htmlBody, bodyValues, attachments
        }

        /// One file on a draft.
        ///
        /// A cut-down `EmailBodyPart`: the three fields the server reads, and
        /// nothing else. `name` is a display label — the server takes its
        /// basename before it touches the filesystem — and `type` is echoed
        /// back rather than trusted.
        public struct Attachment: Encodable, Sendable {
            public var blobID: BlobID
            public var type: String
            public var name: String

            private enum CodingKeys: String, CodingKey {
                case blobID = "blobId"
                case type, name
            }

            public init(blobID: BlobID, type: String, name: String) {
                self.blobID = blobID
                self.type = type
                self.name = name
            }
        }

        public init(
            drafts: MailboxID,
            from: EmailAddress?,
            to: [EmailAddress],
            cc: [EmailAddress] = [],
            bcc: [EmailAddress] = [],
            subject: String,
            text: String,
            html: String? = nil,
            inReplyTo: [String]? = nil,
            references: [String]? = nil,
            attachments: [Attachment] = []
        ) {
            mailboxIDs = JMAPIDSet([drafts])
            // The draft keyword is what makes the row open the composer rather
            // than the reader, in this client and in the web UI.
            keywords = KeywordSet([.draft])
            self.from = from.map { [$0] }
            self.to = to.isEmpty ? nil : to
            self.cc = cc.isEmpty ? nil : cc
            self.bcc = bcc.isEmpty ? nil : bcc
            self.subject = subject
            self.inReplyTo = inReplyTo
            self.references = references

            var plain = BodyPart()
            plain.partID = "text"
            plain.type = "text/plain"
            textBody = [plain]

            var values = ["text": BodyValue(value: text)]

            if let html {
                var rich = BodyPart()
                rich.partID = "html"
                rich.type = "text/html"
                htmlBody = [rich]
                values["html"] = BodyValue(value: html)
            }

            bodyValues = values
            self.attachments = attachments.isEmpty ? nil : attachments
        }
    }

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Keyed by a creation id, which later calls in the same request refer
        /// to as `#id` — this is how a draft is created and submitted in one
        /// round trip.
        public var create: [String: Draft]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var newState: StateToken
        public var created: [String: CreatedEmail]?
        public var notCreated: [String: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case newState, created, notCreated
        }
    }

    public struct CreatedEmail: Decodable, Sendable {
        public var id: EmailID
        public var blobID: BlobID?
        public var threadID: ThreadID?

        private enum CodingKeys: String, CodingKey {
            case id
            case blobID = "blobId"
            case threadID = "threadId"
        }
    }

    public var arguments: Arguments

    public static let creationID = "draft"

    public init(accountID: AccountID, draft: Draft) {
        arguments = Arguments(accountID: accountID, create: [Self.creationID: draft])
    }
}

// MARK: - Rewriting a draft

/// One file on a draft, named by a blob id.
///
/// `p-…` for a part the draft already holds and `u-…` for something just
/// uploaded. Re-listing a `p-` id keeps the stored bytes and does **not**
/// re-upload them, which is what makes attaching a file to a draft and then
/// changing its subject cost one small request rather than the whole payload
/// again over a home uplink.
public struct DraftAttachment: Encodable, Sendable, Hashable {
    public var blobID: BlobID
    public var type: String
    public var name: String

    private enum CodingKeys: String, CodingKey {
        case blobID = "blobId"
        case type, name
    }

    public init(blobID: BlobID, type: String, name: String) {
        self.blobID = blobID
        self.type = type
        self.name = name
    }
}

/// What a draft save says about the attachment set — three states, not two.
///
/// `attachments` on `Email/set update` is a **whole value**, so the difference
/// between these cases is the difference between keeping somebody's files and
/// deleting them:
///
/// - ``unchanged`` omits the key. The stored parts are left exactly as they
///   are. This is what almost every autosave sends, because almost every
///   autosave is somebody typing another sentence.
/// - ``whole`` sends the complete list. Parts left out are removed **and their
///   bytes deleted**, so `.whole([])` is a destructive statement and must only
///   be made when the user really did remove the last file.
///
/// There is a fourth failure this shape guards against by making the array
/// rare: **one blob id that will not resolve fails the entire patch**, subject
/// included, with `notUpdated[id].type = "invalidProperties"` and nothing
/// applied. Restating a dozen blob ids on every keystroke is a dozen chances
/// per keystroke to lose the whole save.
public enum DraftAttachmentWrite: Sendable, Hashable {
    case unchanged
    case whole([DraftAttachment])
}

/// Everything a draft save carries.
///
/// A value rather than arguments, because the same content is written by two
/// callers — the composer's autosave and the outbox's send — and two spellings
/// of "what a draft is" would drift.
public struct DraftContent: Sendable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    /// The plain-text alternative. plMail regenerates its own from the HTML,
    /// so this is for other JMAP clients that might read the draft.
    public var text: String
    public var html: String?
    public var inReplyTo: [String]?
    public var references: [String]?
    public var attachments: DraftAttachmentWrite

    public init(
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String = "",
        text: String = "",
        html: String? = nil,
        inReplyTo: [String]? = nil,
        references: [String]? = nil,
        attachments: DraftAttachmentWrite = .unchanged
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.html = html
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }
}

/// Rewriting a draft that already exists, with the properties the server will
/// actually accept.
///
/// **This replaces an `EmailUpdateDraft` that shipped broken.** That type's
/// patch copied `from` out of the draft it was built from, and `from` is not in
/// the server's `EmailPatchApplier::DRAFT_PROPERTIES` (`subject, to, cc, bcc,
/// textBody, htmlBody, bodyValues, inReplyTo, references, attachments`). An
/// `Email/set update` naming it throws `invalidPatch`, which `EmailSetMethod`
/// catches per object into `notUpdated` — so **nothing** was applied, the body
/// included, and editing a draft and sending it failed outright while looking
/// like it had worked. The allow-list is the reason every property below is
/// written out by hand rather than copied off a `Draft`: a field that creeps
/// into this encoder is a field that silently voids the whole save.
///
/// It was also unable to say ``DraftAttachmentWrite/unchanged``, which is the
/// state an autosave is in nearly all of the time.
///
/// `mailboxIds` and `keywords` are deliberately absent for the reason they
/// always were: the draft is already in Drafts and already flagged.
public struct DraftUpdate: JMAPMethod {
    public static let name = "Email/set"
    public static let capability = Capability.mail

    /// The only properties this encoder may ever name.
    ///
    /// Kept as data as well as code so a test can assert the one thing that
    /// broke the last implementation: `from` is not here, and an update naming
    /// it is refused whole.
    public static let patchProperties: Set<String> = [
        "subject", "to", "cc", "bcc", "textBody", "htmlBody", "bodyValues",
        "inReplyTo", "references", "attachments",
    ]

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var emailID: EmailID
        public var content: DraftContent
        /// Conflict detection, honoured by the server.
        ///
        /// Once a draft autosaves, two devices editing one draft is a real
        /// scenario rather than a hypothetical, and `stateMismatch` is how the
        /// second one finds out instead of overwriting the first.
        public var ifInState: StateToken?

        public func encode(to encoder: any Encoder) throws {
            var root = encoder.container(keyedBy: JMAPCodingKey.self)

            try root.encode(accountID, forKey: JMAPCodingKey("accountId"))

            if let ifInState {
                try root.encode(ifInState, forKey: JMAPCodingKey("ifInState"))
            }

            var update = root.nestedContainer(
                keyedBy: JMAPCodingKey.self, forKey: JMAPCodingKey("update"))
            var patch = update.nestedContainer(
                keyedBy: JMAPCodingKey.self, forKey: JMAPCodingKey(emailID.rawValue))

            try patch.encode(content.subject, forKey: JMAPCodingKey("subject"))
            // Encoded even when empty: an address list the user cleared has to
            // reach the server as `null`, or removing the last Cc would look
            // like it worked and be there again on the next device.
            try patch.encode(nilIfEmpty(content.to), forKey: JMAPCodingKey("to"))
            try patch.encode(nilIfEmpty(content.cc), forKey: JMAPCodingKey("cc"))
            try patch.encode(nilIfEmpty(content.bcc), forKey: JMAPCodingKey("bcc"))

            if let inReplyTo = content.inReplyTo {
                try patch.encode(inReplyTo, forKey: JMAPCodingKey("inReplyTo"))
            }

            if let references = content.references {
                try patch.encode(references, forKey: JMAPCodingKey("references"))
            }

            var plain = BodyPart()
            plain.partID = Email.SyntheticPart.text
            plain.type = "text/plain"

            var values = [Email.SyntheticPart.text: BodyValue(value: content.text)]

            try patch.encode([plain], forKey: JMAPCodingKey("textBody"))

            if let html = content.html {
                var rich = BodyPart()
                rich.partID = Email.SyntheticPart.html
                rich.type = "text/html"

                values[Email.SyntheticPart.html] = BodyValue(value: html)

                try patch.encode([rich], forKey: JMAPCodingKey("htmlBody"))
            }

            // Without `bodyValues` the server reads the body through the part
            // ids and finds nothing: naming `htmlBody` alone is a save that
            // silently changes nothing.
            try patch.encode(values, forKey: JMAPCodingKey("bodyValues"))

            if case .whole(let attachments) = content.attachments {
                try patch.encode(attachments, forKey: JMAPCodingKey("attachments"))
            }
        }

        private func nilIfEmpty(_ addresses: [EmailAddress]) -> [EmailAddress]? {
            addresses.isEmpty ? nil : addresses
        }
    }

    public typealias Result = EmailSet.Result

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        emailID: EmailID,
        content: DraftContent,
        ifInState: StateToken? = nil
    ) {
        arguments = Arguments(
            accountID: accountID, emailID: emailID, content: content, ifInState: ifInState)
    }
}

extension EmailCreate.Draft {
    /// The create form of the same content.
    ///
    /// `attachments` is sent only when the composer holds some: an empty array
    /// on a create says the same destructive thing it says on an update, and
    /// there is nothing there to destroy yet only because nothing has been
    /// written.
    public init(drafts: MailboxID, from: EmailAddress? = nil, content: DraftContent) {
        self.init(
            drafts: drafts,
            from: from,
            to: content.to,
            cc: content.cc,
            bcc: content.bcc,
            subject: content.subject,
            text: content.text,
            html: content.html,
            inReplyTo: content.inReplyTo,
            references: content.references,
            attachments: {
                guard case .whole(let files) = content.attachments else { return [] }

                return files.map {
                    EmailCreate.Draft.Attachment(blobID: $0.blobID, type: $0.type, name: $0.name)
                }
            }()
        )
    }
}

// MARK: - Sending

/// When a submission is allowed to leave, as RFC 8621 §7 carries it.
///
/// There is no scheduling property in the spec: it passes the SMTP
/// FUTURERELEASE extension (RFC 4865) through as envelope parameters on
/// `mailFrom`, and plMail implements exactly that shape — `SubmissionEnvelope`
/// on the server reads `HOLDFOR` and `HOLDUNTIL`, refuses both together, and
/// refuses a hold longer than the ceiling it advertises as `maxDelayedSend`.
///
/// The two are not interchangeable and picking the wrong one is a real bug:
///
/// - ``until`` is for a time a person chose. It is an instant, so a phone whose
///   clock runs a minute fast still names the minute the user picked.
/// - ``seconds`` is for a duration this client means as a duration — the undo
///   window. Counted from when the request *arrives*, which is what "give me
///   five seconds to change my mind" actually means.
public enum SubmissionHold: Hashable, Sendable {
    case seconds(Int)
    case until(Date)
}

/// The envelope a submission carries, and the one thing plMail reads from it.
///
/// **Only `mailFrom.parameters` is ever sent.** The server validates the rest
/// rather than applying it: an `envelope.mailFrom.email` naming anything but
/// the address the submission already resolved to is refused with
/// `forbiddenFrom`, and an `envelope.rcptTo` that is not exactly the Email's
/// To/Cc/Bcc as a set is refused with `invalidRecipients`. Sending either would
/// be this client describing mail the server will not send, and being told so
/// hours after the composer closed. The From is chosen with `identityId`.
///
/// Unknown keys are rejected by name, so this encodes nothing it does not mean.
public struct SubmissionEnvelope: Encodable, Sendable, Hashable {
    public var hold: SubmissionHold

    public init(hold: SubmissionHold) {
        self.hold = hold
    }

    public func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: JMAPCodingKey.self)
        var mailFrom = root.nestedContainer(
            keyedBy: JMAPCodingKey.self, forKey: JMAPCodingKey("mailFrom"))
        var parameters = mailFrom.nestedContainer(
            keyedBy: JMAPCodingKey.self, forKey: JMAPCodingKey("parameters"))

        switch hold {
        case .seconds(let seconds):
            // A string, because ESMTP parameters are text (RFC 4865 §3) and
            // that is the spelling the server's own error messages quote.
            // Clamped at zero: a negative hold is not a thing to ask for, and
            // the server would refuse the whole submission over it.
            try parameters.encode(String(max(0, seconds)), forKey: JMAPCodingKey("HOLDFOR"))

        case .until(let date):
            try parameters.encode(UTCDate(date), forKey: JMAPCodingKey("HOLDUNTIL"))
        }
    }
}

/// Sending, with `EmailSubmission/set`.
///
/// Queued on the same message bus the web composer uses: that pipeline does the
/// whole draft-to-sent transition itself — adds Sent, removes Drafts, clears
/// the draft flag, sets `sentAt` — so a client that omits
/// `onSuccessUpdateEmail` still ends up correct.
///
/// **A submission's id is the Email id.** plMail stores no submission row; it
/// reconstructs one from three columns on the message. Two consequences this
/// client depends on: re-submitting the same Email re-times the one submission
/// rather than creating a second, and `MessageSendService` is a no-op once
/// `sentAt` is set — which together are why a crash between the server
/// accepting a submission and this client recording it cannot send the mail
/// twice, so long as the retry names the same Email id.
///
/// **The web UI's ten-second grace period is deliberately not applied to JMAP
/// submissions** — a JMAP client asked to send now. A client that wants a
/// window says so with ``SubmissionHold/seconds``, which is a real hold the
/// server honours, rather than by delaying the call: a delayed call is lost
/// when the process dies, and its "undo" cancels nothing because nothing was
/// ever submitted.
public struct EmailSubmissionSet: JMAPMethod {
    public static let name = "EmailSubmission/set"
    public static let capability = Capability.submission

    /// The creation id every submission this client makes is keyed by.
    public static let creationID = "send"

    public struct Submission: Encodable, Sendable {
        /// May be a `#creationId` referring to a draft created in the same
        /// request — which is how a message is written and sent in one round
        /// trip.
        public var emailID: String
        public var identityID: IdentityID
        /// Absent for "send now". See ``SubmissionEnvelope``.
        public var envelope: SubmissionEnvelope?

        private enum CodingKeys: String, CodingKey {
            case emailID = "emailId"
            case identityID = "identityId"
            case envelope
        }
    }

    /// The only update RFC 8621 §7.5 allows, and the only one plMail accepts:
    /// `undoStatus` to `"canceled"`, on a submission that is still pending.
    ///
    /// A patch with any other key — or any other value — is refused with
    /// `invalidProperties`, so this type has exactly one inhabitant on purpose.
    public struct CancelPatch: Encodable, Sendable, Hashable {
        public let undoStatus = "canceled"

        public init() {}
    }

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var create: [String: Submission]?
        public var update: [String: CancelPatch]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create, update
        }
    }

    /// What the server says about a submission it accepted.
    ///
    /// `sendAt` is **the server's answer, not the time that was asked for**.
    /// They agree on this server today and would not on one that rounds, and
    /// what the user is shown has to be when the mail actually leaves.
    public struct CreatedSubmission: Decodable, Sendable, Hashable {
        public var id: String
        public var sendAt: UTCDate?
        public var undoStatus: String?
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var newState: StateToken
        public var created: [String: CreatedSubmission]?
        public var notCreated: [String: JSONValue]?
        public var updated: [String: JSONValue?]?
        public var notUpdated: [String: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case newState, created, notCreated, updated, notUpdated
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        emailID: String,
        identityID: IdentityID,
        hold: SubmissionHold? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            create: [
                Self.creationID: Submission(
                    emailID: emailID,
                    identityID: identityID,
                    envelope: hold.map { SubmissionEnvelope(hold: $0) })
            ],
            update: nil
        )
    }

    /// Calls a submission back.
    ///
    /// Reliable while the submission is held and a race once it has been
    /// dispatched with no hold, which is the whole reason an undo window is a
    /// hold rather than a delayed call. The refusals mean different things and
    /// must be told apart: `cannotUnsend` is "the mail has gone" and must never
    /// be reported as an undo, while `notFound` is "nothing was ever submitted"
    /// and there is nothing to call back.
    public static func cancel(_ id: String, accountID: AccountID) -> EmailSubmissionSet {
        EmailSubmissionSet(
            arguments: Arguments(accountID: accountID, create: nil, update: [id: CancelPatch()]))
    }

    private init(arguments: Arguments) {
        self.arguments = arguments
    }
}

/// What a submission is doing, read back from the server.
///
/// The three values RFC 8621 §7 defines, decoded permissively: an unknown
/// string is ``unknown`` rather than a decoding failure, because a submission
/// this client cannot classify must still be visible as *something* rather than
/// take the whole response down.
public enum UndoStatus: String, Decodable, Sendable, Hashable {
    case pending
    case final
    case canceled
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)

        self = UndoStatus(rawValue: raw) ?? .unknown
    }
}

/// One submission as the server reports it.
public struct EmailSubmission: Decodable, Sendable, Hashable {
    public var id: String
    public var emailID: String?
    public var identityID: String?
    /// When the mail left where it has, and when it is due where it has not.
    public var sendAt: UTCDate?
    public var undoStatus: UndoStatus?

    private enum CodingKeys: String, CodingKey {
        case id
        case emailID = "emailId"
        case identityID = "identityId"
        case sendAt, undoStatus
    }
}

/// `EmailSubmission/get` (RFC 8621 §7.2) — what happened to a send.
///
/// The only way to retire a locally recorded schedule honestly. A row that
/// still says "leaving at 08:00" at half past nine is worse than no row, and
/// the three answers lead somewhere different: `pending` keep, `canceled` drop,
/// `final` drop. An id the server has never heard of comes back in `notFound`,
/// which for a submission means the draft was never submitted — not that the
/// mail went.
///
/// `ids` is required and capped at 500 per call by the server.
public struct EmailSubmissionGet: JMAPMethod {
    public static let name = "EmailSubmission/get"
    public static let capability = Capability.submission

    /// The server's own cap. Asking for more is refused with `requestTooLarge`,
    /// which fails the call rather than truncating it.
    public static let maxIDs = 500

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var ids: [String]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case ids
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var state: StateToken?
        public var list: [EmailSubmission]
        public var notFound: [String]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case state, list, notFound
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, ids: [String]) {
        arguments = Arguments(accountID: accountID, ids: Array(ids.prefix(Self.maxIDs)))
    }
}
