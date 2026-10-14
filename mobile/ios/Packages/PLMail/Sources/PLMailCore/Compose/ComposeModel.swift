import Foundation
import JMAPKit
import OSLog
import Observation

/// Writing and sending a message.
///
/// One draft is created and submitted in a **single round trip**: the draft
/// gets a creation id, and the submission refers to it as `#draft`. Over a
/// home uplink that is the difference between sending feeling instant and
/// feeling like two requests.
///
/// Everything typed is also written to the account's Drafts mailbox on a
/// debounce. Before that existed, dismissing the composer discarded the text
/// silently: no confirmation, nothing on the server, nothing on another device,
/// and nothing left after a crash.
@MainActor
@Observable
public final class ComposeModel {
    public enum Kind: Sendable, Equatable {
        case new
        case reply(to: MessageSnapshot, all: Bool)
        case forward(MessageSnapshot)
        /// Carrying on with a draft. The id rather than a snapshot: the list
        /// row knows which message it is but has not loaded its body, and a
        /// composer that opened with an empty body and filled in a moment
        /// later would look like it had lost the text.
        case editDraft(emailID: String)
    }

    public enum Status: Equatable, Sendable {
        case editing
        /// Being written to disk on the way out. Brief, and deliberately not
        /// cancellable: the recall window is a hold the **server** applies once
        /// the message has been submitted, which is what makes it survive the
        /// app being killed. Blocking the composer for five seconds and
        /// submitting nothing, as this used to, meant a process death inside
        /// the window dropped the send silently while the user watched the
        /// sheet close.
        case queuing
        case sent
        case failed(String)
        /// The composer is finished with and the draft has been dealt with —
        /// saved or trashed. Distinct from ``sent`` so the view can dismiss
        /// without claiming a message went out.
        case closed
    }

    /// Where what is on screen currently lives.
    ///
    /// Shown, quietly, because a composer that silently saves and a composer
    /// that silently does not look identical — and the difference is whether
    /// closing the lid costs somebody an afternoon's letter.
    public enum SaveState: Equatable, Sendable {
        /// Nothing worth saving yet, or nothing changed since the last save.
        case idle
        case saving
        case saved(Date)
        /// The reason, already localised. The text is still in the composer,
        /// which is what the message has to make clear.
        case failed(String)
    }

    public var to: String = "" { didSet { noteEdited(recipientsChanged: true) } }
    public var cc: String = "" { didSet { noteEdited(recipientsChanged: true) } }
    public var bcc: String = "" { didSet { noteEdited(recipientsChanged: true) } }
    public var subject: String = "" { didSet { noteEdited() } }
    /// What someone actually typed, formatting and all.
    ///
    /// The quoted original is deliberately **not** in here — see
    /// ``quotedHTML``.
    public var body = AttributedString() { didSet { noteEdited() } }
    /// The address this message goes out as, and the account it goes out
    /// through.
    ///
    /// Changing it can change the account, which is why the swap is a method
    /// rather than a plain assignment — see ``selectIdentity(_:)``.
    public private(set) var selectedIdentity: SendingIdentity?

    /// Every address the user may send as, across **every** connected account.
    ///
    /// One login here fronts several mailboxes, and a composer opened from the
    /// unified inbox has no business insisting the reply leaves from whichever
    /// account the thread happened to arrive in. The picker used to be fixed to
    /// the `accountKey` the sheet was constructed with, so sending a work reply
    /// from a personal address meant closing the composer and starting again in
    /// another mailbox.
    public private(set) var identities: [SendingIdentity] = []
    public private(set) var status: Status = .editing
    public private(set) var saveState: SaveState = .idle

    /// The draft on the server, once there is one.
    ///
    /// Read by the send path so an autosaved draft is *rewritten* rather than
    /// duplicated: without it, writing a message, waiting three seconds and
    /// pressing Send left one copy in Drafts forever.
    public private(set) var draftID: EmailID?

    /// Files picked for this message.
    public private(set) var attachments: [PendingAttachment] = []

    /// What this server will accept, once the Session has been read.
    public private(set) var limits: AttachmentLimits = .unknown

    /// The most recent refusal at pick time, already localised.
    public private(set) var attachmentRefusal: String?

    /// Recipients that are not addresses, in the order they were typed.
    ///
    /// Surfaced rather than filtered at send: a typo used to be dropped
    /// silently, so the composer named five people and the message went to
    /// four.
    public var invalidRecipients: [String] {
        RecipientParsing.invalid(in: to) + RecipientParsing.invalid(in: cc)
            + RecipientParsing.invalid(in: bcc)
    }

    /// Everyone this account has corresponded with, for autocomplete.
    ///
    /// Harvested from synced mail rather than fetched: the addresses someone
    /// actually writes to are all in the mail already on the device.
    public private(set) var suggestions: [EmailAddress] = []

    /// Matches from the address book for whatever is being typed right now.
    ///
    /// Separate from ``suggestions`` because it arrives asynchronously and per
    /// keystroke, where the correspondents list is loaded once and then sits
    /// still.
    public private(set) var contactMatches: [EmailAddress] = []
    private var contactLookup: Task<Void, Never>?

    /// The original being replied to or forwarded, as HTML, kept out of the
    /// editor.
    ///
    /// Gmail's arrangement, and for Gmail's reason: a real message's HTML is
    /// tables, inline styles and images, and parsing it into an editable
    /// rich-text buffer to put it on screen would mangle it — every quote would
    /// come back subtly worse than it went in. Held aside verbatim, it is
    /// appended untouched at send time, so what the recipient sees quoted is
    /// byte-for-byte what arrived.
    public private(set) var quotedHTML: String?

    /// Drops the quoted original.
    public func removeQuote() {
        quotedHTML = nil
        noteEdited()
    }

    /// A file waiting to be sent.
    ///
    /// Either bytes on the device or a part already stored on the server. The
    /// second case is what reopening a draft produces, and it is the whole
    /// reason this is not a `Data`: a draft's files came back as nothing at
    /// all before, and sending it then rewrote the draft without them —
    /// opening a draft to check it destroyed its attachments.
    public struct PendingAttachment: Identifiable, Sendable, Hashable {
        public var id = UUID()
        public var name: String
        public var type: String
        public var size: Int
        /// The bytes, for a file picked on this device. Nil for a part that
        /// only exists on the server.
        public var data: Data?
        /// The blob this is already stored as, if it is. A `p-` id from a
        /// reopened draft, or a `u-` id from an upload this composer made —
        /// either way, re-listing it costs no bytes.
        public var blobID: BlobID?

        public init(
            name: String, type: String, size: Int, data: Data? = nil, blobID: BlobID? = nil
        ) {
            self.name = name
            self.type = type
            self.size = size
            self.data = data
            self.blobID = blobID
        }
    }

    /// One sendable address, with the account it belongs to.
    ///
    /// `IdentitySnapshot` carries neither, because identities are stored per
    /// account and nothing needed to ask across them until the From picker did.
    /// Pairing them here rather than widening the snapshot keeps the change
    /// inside the composer, which is the only place that has to reason about
    /// two accounts at once.
    public struct SendingIdentity: Hashable, Sendable, Identifiable {
        public var identity: IdentitySnapshot
        public var accountKey: String
        public var accountID: AccountID
        /// What the account is called, for a picker that would otherwise show
        /// two identical display names from two different mailboxes.
        public var accountName: String

        /// Unique across accounts. An identity id is only unique within one, so
        /// keying a picker on it alone collapses two accounts' primaries into
        /// one row.
        public var id: String { "\(accountKey)#\(identity.id.rawValue)" }

        public var address: EmailAddress { identity.address }
        public var displayName: String { identity.displayName }
        public var textSignature: String? { identity.textSignature }
    }

    /// Why a From change was refused.
    public enum IdentityRefusal: Equatable, Sendable {
        /// The message carries a file that only exists on the other account's
        /// server. Blob ids are per account, so the part cannot be re-listed
        /// under the new one and there are no bytes here to upload instead.
        case attachmentIsNotOnThisDevice(name: String)
    }

    /// The most recent refusal to change From, already localised.
    public private(set) var identityRefusal: String?

    public func clearIdentityRefusal() {
        identityRefusal = nil
    }

    /// Chooses the address this message leaves as.
    ///
    /// **Crossing an account boundary abandons the server-side draft.** A draft
    /// belongs to the account it was created in, and so does every blob id on
    /// it: submitting account A's Email id under account B is refused, and
    /// re-listing account A's `p-` blob under B resolves to nothing. So the
    /// draft id is dropped and the files this device still holds are marked for
    /// re-upload, and the next autosave writes a fresh draft in the new
    /// account.
    ///
    /// The old draft is deliberately **left where it is** rather than trashed.
    /// It is a copy of what the user has written, and throwing it away before
    /// the replacement has been accepted would make a failed save a loss.
    public func selectIdentity(_ identity: SendingIdentity?) {
        guard identity != selectedIdentity else { return }

        let previous = selectedIdentity

        if let identity, let previous, identity.accountKey != previous.accountKey {
            // A part with no local bytes cannot follow the message across. Said
            // now, while both choices are still on screen, rather than as a
            // failed send hours later.
            if let orphan = attachments.first(where: { $0.data == nil }) {
                identityRefusal = String(
                    localized:
                        "\(orphan.name) is stored on \(previous.accountName) and can't move to another account. Remove it, or send from \(previous.displayName).",
                    bundle: .module)

                return
            }

            draftID = nil
            savedAttachmentBlobs = []

            for index in attachments.indices { attachments[index].blobID = nil }
        }

        selectedIdentity = identity
        applySignature(of: identity)
    }

    private let kind: Kind
    private let accountKey: String
    private let accountID: AccountID
    private let client: JMAPClient
    private let store: SyncStore
    private let outbox: Outbox
    private let contacts: any ContactSource
    private let preference: ServerSuggestionPreference
    /// The user's account order, which decides the fallback sending address and
    /// the order of the From picker. Injected rather than read from
    /// ``AccountOrder/shared`` inside, so a test can state an order instead of
    /// writing to the real `UserDefaults` of whatever machine it runs on.
    private let order: AccountOrder
    /// Asks the sender to try now. Separate from the outbox itself because
    /// draining is main-actor work that touches observable state.
    private let onQueued: @MainActor () -> Void
    private let logger = Logger(subsystem: "de.plmail", category: "compose")
    private var sendTask: Task<Void, Never>?
    /// Exactly what was appended, and where it ends.
    ///
    /// Two jobs, both of which need the text rather than a marker. ``isEmpty``
    /// must not count the user's own sign-off as something worth keeping —
    /// without that, opening a composer and changing your mind leaves a draft
    /// containing only your name — and a From swap has to replace **over this
    /// extent and nothing else**, so changing the sending address never costs a
    /// typed paragraph.
    ///
    /// **Tracked in composer state rather than by a marker in the body, and
    /// that is not laziness.** The server's `MailBodySanitizer` allows `style`
    /// and drops `class` and every `data-` attribute from a stored draft body,
    /// and it runs on every save. So a `data-pl-signature` block written here
    /// comes back as a bare `<div>`: the round trip Android's `Signatures.kt`
    /// documents does not happen on this server, and a client that scoped its
    /// swap to the marker would find nothing to scope to.
    private var appendedSignature: String?

    /// How long the server holds a send before releasing it, so it can still be
    /// called back.
    ///
    /// **Handed to the server as `HOLDFOR`, not counted down here.** The old
    /// five-second composer block was the weaker of the two ways to have an
    /// undo window: nothing was submitted, so the "undo" cancelled a call that
    /// had never been made, and a process death inside the window lost the mail
    /// outright. A hold is a real submission the server is sitting on, which
    /// means it goes out on time if this app never runs again — and the cancel
    /// is `undoStatus: "canceled"`, which the server documents as reliable for
    /// exactly the held case.
    ///
    /// Five seconds is long enough to catch the "wait, wrong person" moment and
    /// short enough that nobody wonders whether it went.
    public static let undoGrace = 5

    // MARK: - Autosave state

    /// How long typing has to stop before a save.
    ///
    /// Android's number, and a **floor rather than a target**: the audience
    /// runs this against a Raspberry Pi advertising four concurrent requests,
    /// shared with the message list they may still be scrolling.
    static let autosaveDebounce = Duration.seconds(3)

    /// The ceiling on the back-off after a failed save.
    ///
    /// A failed autosave must never turn into a tight loop against somebody's
    /// home server: each failure doubles the wait, and nothing retries on its
    /// own — the next attempt happens when the user types again, no sooner
    /// than this.
    static let autosaveBackoffCeiling = Duration.seconds(300)

    private var autosaveTask: Task<Void, Never>?
    private var autosaveFailures = 0
    /// Whether anything has changed since the last successful save. The whole
    /// point of the flag is that closing an unchanged composer costs no
    /// request.
    private var hasUnsavedChanges = false
    /// Set once `load()` has finished. Prefilling a reply must not look like
    /// somebody typing, or every opened reply would autosave itself.
    private var isLoaded = false
    /// Whether the user has touched the recipient fields, so the reply-all
    /// recomputation that happens when identities arrive cannot overwrite
    /// somebody's edit.
    private var hasEditedRecipients = false

    /// The account's Email state as of the last thing this composer read or
    /// wrote, sent as `ifInState` on every draft save.
    ///
    /// Nil means "unconditional", which is where a composer starts and where
    /// ``overwriteDraftElsewhere()`` deliberately puts it back. Everywhere
    /// else it is the mechanism that stops two devices editing one draft from
    /// silently clobbering each other: the second save is refused with
    /// `stateMismatch` rather than landing on top.
    private var confirmedState: StateToken?

    /// True once a `stateMismatch` has been traced to this draft actually
    /// having been rewritten somewhere else.
    ///
    /// Autosave stops while it is set. Without that, every keystroke would
    /// re-run the conflict check against a state that cannot advance, which is
    /// a loop against somebody's home server that also buries the one message
    /// the user needs to answer.
    public private(set) var isDraftConflicted = false

    /// The attachment set as the server last confirmed it, by blob id.
    ///
    /// `nil` means "not known" — a draft that could not be fully read. In that
    /// state the attachment array is **never** sent, because the whole-value
    /// rule turns a guess into a deletion.
    private var savedAttachmentBlobs: [BlobID]?

    /// Threading headers for whatever is being written.
    private var threading: (inReplyTo: [String], references: [String])?

    public init(
        kind: Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore,
        outbox: Outbox,
        contacts: (any ContactSource)? = nil,
        preference: ServerSuggestionPreference = ServerSuggestionPreference(),
        order: AccountOrder = .shared,
        onQueued: @escaping @MainActor () -> Void = {}
    ) {
        self.order = order
        self.kind = kind
        self.accountKey = accountKey
        self.accountID = accountID
        self.client = client
        self.store = store
        self.outbox = outbox
        self.preference = preference
        // Server first, device second, and that order is the ranking: the
        // server ranks by how often an address is actually written to, which no
        // prefix match on a phone can know, while the address book holds people
        // the user has never mailed, which the server cannot know either.
        // Neither is a superset of the other.
        self.contacts =
            contacts
            ?? CombinedContacts([
                ServerContacts(client: client, accountID: accountID, preference: preference),
                SystemContacts(),
            ])
        self.onQueued = onQueued

        if case .editDraft(let emailID) = kind { draftID = EmailID(emailID) }

        prefill()
    }

    // MARK: - Suggestions

    /// Whether the server may be asked who the user is typing.
    ///
    /// Read through rather than cached, so an answer given in one composer is
    /// live in another that is already open.
    public var serverSuggestions: ServerSuggestionConsent { preference.consent }

    /// Whether the composer should put the question in front of somebody.
    ///
    /// Only while a recipient field is actually being used, and only once: a
    /// privacy question asked on an empty composer is a modal nobody has
    /// context for, and one asked on every keystroke is a thing to dismiss
    /// rather than read.
    public var isAskingAboutServerSuggestions: Bool {
        preference.consent == .undecided && hasTypedARecipient
    }

    private var hasTypedARecipient = false

    /// Records the answer and, when it is yes, re-runs the lookup that was
    /// waiting on it — so saying yes fills the list rather than requiring
    /// another keystroke.
    public func answerServerSuggestions(allowed: Bool, for fragment: String = "") {
        preference.consent = allowed ? .allowed : .declined

        guard allowed, fragment.isEmpty == false else { return }

        lookUpContacts(for: fragment)
    }

    /// The suggestions to show under a recipient field.
    ///
    /// Called as somebody types, so the address book lookup is debounced and
    /// cancelled rather than fired per keystroke — and the correspondents half
    /// is answered immediately from memory, so the list never feels like it is
    /// waiting on permission.
    public func suggestions(for fragment: String) -> [EmailAddress] {
        RecipientSuggestions.merge(
            correspondents: suggestions, contacts: contactMatches, matching: fragment)
    }

    /// Asks the address book about what is being typed.
    public func lookUpContacts(for fragment: String) {
        contactLookup?.cancel()

        let trimmed = fragment.trimmingCharacters(in: .whitespaces)

        // Enough typed for the question to be about something concrete.
        if trimmed.count >= 2 { hasTypedARecipient = true }

        guard trimmed.count >= 2 else {
            contactMatches = []

            return
        }

        contactLookup = Task { [contacts] in
            // Long enough that typing a name is one lookup rather than eight.
            try? await Task.sleep(for: .milliseconds(200))

            guard Task.isCancelled == false else { return }

            let found = await contacts.addresses(matching: trimmed)

            guard Task.isCancelled == false else { return }

            contactMatches = found
        }
    }

    // MARK: - Recipients

    /// Whether this message can go out.
    ///
    /// **Any** recipient field will do. Requiring `to` meant a Bcc-only
    /// message — a mail to a list of people who should not see each other's
    /// addresses, which is the entire purpose of Bcc — could not be sent at
    /// all, with a disabled button and no explanation.
    public var canSend: Bool {
        allRecipients.isEmpty == false && status == .editing
    }

    private var allRecipients: [EmailAddress] {
        RecipientParsing.addresses(in: to) + RecipientParsing.addresses(in: cc)
            + RecipientParsing.addresses(in: bcc)
    }

    // MARK: - Attachments

    /// Adds a file to this message.
    ///
    /// Photos lose their GPS tags on the way in — see ``ImagePrivacy``. Done
    /// here rather than at the picker so it applies however a file arrives:
    /// the photo library, the document browser, and anything added later.
    ///
    /// Refused **at pick time, by name**, while the user is still standing in
    /// the picker and can choose something else. A refusal that arrives at send
    /// reaches them hours later, from a screen with no picker on it.
    @discardableResult
    public func attach(name: String, type: String, data: Data) -> Bool {
        let stripped = ImagePrivacy.strippingLocation(from: data, type: type)

        if let refusal = limits.refusal(
            forFileNamed: name, size: stripped.count, currentTotal: attachmentsSize)
        {
            attachmentRefusal = refusal.message

            return false
        }

        attachments.append(
            PendingAttachment(name: name, type: type, size: stripped.count, data: stripped))
        noteEdited()

        return true
    }

    public func removeAttachment(_ id: PendingAttachment.ID) {
        attachments.removeAll { $0.id == id }
        noteEdited()
    }

    public func clearAttachmentRefusal() {
        attachmentRefusal = nil
    }

    public var attachmentsSize: Int {
        attachments.reduce(0) { $0 + $1.size }
    }

    public var isSending: Bool {
        status == .queuing
    }

    // MARK: - Setup

    public func load() async {
        // Before the identity work: a draft carries its own recipients and
        // body, and overwriting them with a prefill would be worse than a
        // slow open.
        await loadDraftIfNeeded()

        identities = await loadIdentities()
        selectIdentity(selectedIdentity ?? preferredIdentity)
        suggestions = (try? await store.knownAddresses(accountKey: accountKey)) ?? []
        applyOwnAddressExclusions()

        if let session = try? await client.session() {
            limits = AttachmentLimits(session: session, accountID: accountID)
        }

        // A composer that opened is not a composer that was written in.
        isLoaded = true
        hasUnsavedChanges = false

        // Fetching is cheap and the list is small, but a stale identity list
        // means sending from an alias that no longer exists.
        await refreshIdentities()
    }

    /// Every sendable address on every connected account.
    ///
    /// The composer's own account first, so the address a reply would naturally
    /// leave as is the one already selected and the picker is a change rather
    /// than a decision. **Everything after it is in the user's own account
    /// order**, which is what dragging an account to the top of the accounts
    /// screen was supposed to mean: it decides which address the composer
    /// falls back to when this account has none to offer, and the order the
    /// From picker reads in. Accounts the server marked read-only are skipped:
    /// an alias that cannot send is a row that can only disappoint.
    ///
    /// Partitioned rather than sorted with a predicate. `sorted(by:)` is not
    /// stable in Swift, so ranking with one comparison and then re-sorting
    /// with another can reorder the ranked accounts — silently, and only on
    /// some inputs, which is the worst way for an ordering bug to arrive.
    private func loadIdentities() async -> [SendingIdentity] {
        let stored = (try? await store.accounts()) ?? []
        let ranked = order.ordered(stored, key: \.accountKey)
        let accounts =
            ranked.filter { $0.accountKey == accountKey }
            + ranked.filter { $0.accountKey != accountKey }
        var found: [SendingIdentity] = []

        for account in accounts {
            guard account.isReadOnly == false else { continue }

            let identities = (try? await store.identities(accountKey: account.accountKey)) ?? []

            found += identities.map {
                SendingIdentity(
                    identity: $0,
                    accountKey: account.accountKey,
                    accountID: account.accountID,
                    accountName: account.name)
            }
        }

        return found
    }

    /// What to send as when nothing has been chosen: the composer's own
    /// account's first identity, which is its primary.
    ///
    /// The fallback is not arbitrary. An account with no sendable identity —
    /// read-only, or not yet synced — used to hand the composer whichever
    /// account the store returned first, so a work reply could open as a
    /// personal address for no reason the user could see. ``loadIdentities()``
    /// orders by ``AccountOrder``, which makes this the account the user put at
    /// the top.
    private var preferredIdentity: SendingIdentity? {
        identities.first { $0.accountKey == accountKey } ?? identities.first
    }

    /// Refreshes the identity list for the composer's own account.
    ///
    /// Only this one, deliberately. A stale identity means sending from an
    /// alias that no longer exists, which is worth a request for the account
    /// the message is actually going out through; doing it for five connected
    /// mailboxes on every composer open would be five requests to somebody's
    /// NAS for a picker most people never touch. The others are answered from
    /// the store, which the sync keeps current.
    private func refreshIdentities() async {
        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(IdentityGet(accountID: accountID))
            let results = try await client.send(builder)

            try await store.replaceIdentities(
                try results.result(of: get).list, accountKey: accountKey)

            let refreshed = await loadIdentities()

            guard refreshed.isEmpty == false else { return }

            identities = refreshed
            selectIdentity(
                identities.first { $0.id == selectedIdentity?.id } ?? preferredIdentity)
            applyOwnAddressExclusions()
        } catch {
            logger.error("Could not refresh identities: \(error, privacy: .public)")
        }
    }

    /// Every address this user can send as, lowercased.
    private var ownAddresses: Set<String> {
        Set(identities.map { $0.identity.email.lowercased() })
    }

    /// Re-runs reply-all now that the identity list is known.
    ///
    /// The identities are not loaded when ``prefill()`` runs, so the first pass
    /// cannot exclude them. Without this second pass, replying-all to a thread
    /// you are on Ccs you on your own reply — a copy of everything you write,
    /// in your own inbox, forever.
    private func applyOwnAddressExclusions() {
        guard case .reply(let message, let all) = kind, all, hasEditedRecipients == false else {
            return
        }

        let recipients = ReplyDrafting.replyRecipients(
            answering: RecipientParsing.addresses(in: to),
            originalTo: message.to,
            originalCc: message.cc,
            all: true,
            own: ownAddresses
        )

        setRecipients(cc: recipients.cc)
    }

    /// The draft being continued, if this composer opened on one.
    private var editingEmailID: String? {
        guard case .editDraft(let emailID) = kind else { return nil }

        return emailID
    }

    /// Reads an existing draft back into the composer.
    ///
    /// Straight from `Email/get` rather than from the cached snapshot, because
    /// the snapshot has no `bcc`: restoring to/cc/subject/body and then
    /// rewriting the draft on send delivered a message without the blind
    /// copies it named, and no screen anywhere showed that it had.
    ///
    /// The cache is the fallback, and a fallback load is recorded as an
    /// **incomplete** one: with the attachment set unknown, nothing may send
    /// an `attachments` array, because a whole value assembled from a partial
    /// read deletes the parts it did not see.
    private func loadDraftIfNeeded() async {
        guard let editingEmailID else { return }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let get = builder.add(
                EmailGet(
                    accountID: accountID,
                    ids: .value([EmailID(editingEmailID)]),
                    properties: EmailGet.readerProperties,
                    fetchTextBodyValues: true,
                    fetchHTMLBodyValues: true
                )
            )

            let results = try await client.send(builder)
            let read = try results.result(of: get)
            let list = read.list

            guard let email = list.first else { throw DraftFailure.notFound }

            // The state this copy of the draft was read at, so the first
            // autosave is already conditional. Taken from the read rather than
            // from the sync cursor: the cursor is wherever the last delta pull
            // reached, which on a phone that has been asleep is behind, and a
            // stale `ifInState` refuses every save rather than the conflicting
            // ones.
            confirmedState = read.state

            // Written through to the store as well, so the Drafts list row and
            // the composer cannot disagree about what the draft says.
            try? await store.storeReaderContent(list, accountKey: accountKey)

            apply(email)

            return
        } catch {
            logger.error("Draft load failed: \(error, privacy: .public)")
        }

        if let cached = try? await store.message(emailID: editingEmailID, accountKey: accountKey),
            cached.hasBody
        {
            applyPartial(cached)
            saveState = .failed(
                String(
                    localized: "Couldn't reach the server. Showing the draft last synced.",
                    bundle: .module))
        } else {
            status = .failed(String(localized: "Couldn't open this draft.", bundle: .module))
        }
    }

    private enum DraftFailure: Error {
        case notFound
        case noDraftsMailbox
        case refused(String)
        /// Another client rewrote this draft while it was open here. Named
        /// separately from ``refused(_:)`` because it is the one failure the
        /// user can actually resolve, and the only one that must never be
        /// retried on its own.
        case changedElsewhere
    }

    /// Puts the identity's signature on the message, and swaps it when the
    /// From changes.
    ///
    /// Above the quoted original on a reply, which is where every mail client
    /// puts it and where it is actually read; at the end of a new message. On a
    /// reply the quote is not in the editor at all, so "at the end of what was
    /// typed" is already the right place.
    ///
    /// **The swap replaces over ``appendedSignature`` and nothing else.**
    /// Everything outside that extent is untouched, so choosing a different
    /// From can never cost a typed paragraph — which is the failure a
    /// body-rescanning implementation makes, because a signature is arbitrary
    /// user text and a scan that guesses where it ends welds the tail of the
    /// old one onto the front of the new.
    ///
    /// **Never on a draft being continued.** That text already contains
    /// whatever signature it was written with; there is no marker left in it to
    /// scope to, because the server strips every `data-` attribute on save, and
    /// appending again would stack two sign-offs.
    ///
    /// An empty signature produces **no block at all**, not an empty one: a
    /// stray separator under every message from that address is worse than
    /// none.
    ///
    /// Idempotent, so the several places that settle the identity — the first
    /// load, the refresh, a From swap — can all call it without counting.
    private func applySignature(of identity: SendingIdentity?) {
        guard editingEmailID == nil else { return }

        let block = Self.signatureBlock(identity?.textSignature)

        guard block != appendedSignature else { return }

        let wasUnsaved = hasUnsavedChanges

        if let appendedSignature { removeTrailing(appendedSignature) }
        if let block { body.append(AttributedString(block)) }

        appendedSignature = block
        // Signing is the app writing, not the user. Restored rather than
        // cleared, so a signature arriving late cannot swallow a sentence
        // somebody typed while the identity list was loading.
        hasUnsavedChanges = wasUnsaved
    }

    /// The block a signature is written as, or nil when there is nothing to
    /// write.
    ///
    /// `\n\n-- \n` is the Usenet separator every mail client and every mailing
    /// list still recognises, which is what makes a quoting client trim it
    /// rather than quote it back.
    static func signatureBlock(_ signature: String?) -> String? {
        guard let signature,
            signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        return "\n\n-- \n" + signature
    }

    /// Takes an exact suffix off the body, leaving its formatting alone.
    ///
    /// A no-op when the text does not end in it — somebody who edited their own
    /// signature has made it theirs, and silently deleting the last N
    /// characters of whatever is there instead is how a From swap eats a
    /// paragraph.
    private func removeTrailing(_ text: String) {
        let characters = body.characters

        guard characters.count >= text.count, text.isEmpty == false,
            String(characters.suffix(text.count)) == text
        else { return }

        let end = characters.endIndex
        let start = characters.index(end, offsetBy: -text.count)

        body.removeSubrange(start..<end)
    }

    /// Everything a full `Email/get` gives back.
    private func apply(_ email: Email) {
        setRecipients(
            to: email.to ?? [], cc: email.cc ?? [], bcc: email.bcc ?? [])

        subject = email.subject ?? ""

        if let inReplyTo = email.inReplyTo, inReplyTo.isEmpty == false {
            threading = (inReplyTo: inReplyTo, references: email.references ?? [])
        }

        applyBody(html: email.htmlBodyValue, text: email.textBodyValue)

        // Non-inline parts only. A `cid:` image belongs to the body, and
        // listing it as a removable file confuses people into deleting half
        // their own message.
        let parts = (email.attachments ?? []).filter { $0.isInline == false }

        attachments = parts.compactMap { part in
            guard let blobID = part.blobID else { return nil }

            return PendingAttachment(
                name: part.name ?? "attachment",
                type: part.type ?? "application/octet-stream",
                size: part.size ?? 0,
                blobID: blobID)
        }

        savedAttachmentBlobs = attachments.compactMap(\.blobID)
        hasUnsavedChanges = false
    }

    /// The cached snapshot: everything except the blind copies and the files.
    private func applyPartial(_ draft: MessageSnapshot) {
        setRecipients(to: draft.to, cc: draft.cc)
        subject = draft.subject ?? ""
        applyBody(html: draft.htmlBody, text: draft.textBody ?? draft.preview)

        // Deliberately left unknown. See ``savedAttachmentBlobs``.
        savedAttachmentBlobs = nil
        hasUnsavedChanges = false
    }

    private func applyBody(html: String?, text: String?) {
        // HTML first: a draft written here or in the web composer is HTML, and
        // reading its text alternative back would quietly strip the formatting
        // every time someone reopened it.
        if let html {
            let split = MailHTML.splitQuote(fromHTML: html)

            body = MailHTML.attributedString(fromHTML: split.body)
            quotedHTML = split.quote
        } else {
            body = AttributedString(text ?? "")
        }
    }

    /// Writes recipient fields without counting the write as an edit.
    ///
    /// Every caller is the app filling something in — a prefill, a loaded
    /// draft, or reply-all being recomputed once the identities arrive. Letting
    /// those count as typing meant merely *opening* a reply-all wrote a draft
    /// three seconds later, so abandoning one left a copy in Drafts.
    private func setRecipients(
        to newTo: [EmailAddress]? = nil,
        cc newCc: [EmailAddress]? = nil,
        bcc newBcc: [EmailAddress]? = nil
    ) {
        let wasEdited = hasEditedRecipients
        let wasUnsaved = hasUnsavedChanges

        if let newTo { to = RecipientParsing.field(from: newTo) }
        if let newCc { cc = RecipientParsing.field(from: newCc) }
        if let newBcc { bcc = RecipientParsing.field(from: newBcc) }

        hasEditedRecipients = wasEdited
        hasUnsavedChanges = wasUnsaved
    }

    /// Fills this composer in from a `mailto:` link.
    ///
    /// **Not counted as typing**, exactly as ``setRecipients(to:cc:bcc:)`` is
    /// not: a link tapped by accident and closed again must not leave a draft
    /// in the Drafts mailbox on every device. The first keystroke after this
    /// arms the autosave in the ordinary way, so nothing here bypasses the
    /// draft machinery — it only declines to start it.
    ///
    /// **The body goes in ahead of what is already there, not over it.** What
    /// is already there on a loaded composer is the signature, and
    /// ``appendedSignature`` is only removable while it is still the suffix —
    /// overwriting the body would strand it and make the next From swap eat a
    /// paragraph.
    ///
    /// The body is inserted as text. A `mailto:` body is plain by definition
    /// and arrives from a web page: handing it to the editor as markup is the
    /// difference between a link that prefills a message and a link that draws
    /// one.
    public func apply(_ mailto: MailtoRequest) {
        let wasEdited = hasEditedRecipients
        let wasUnsaved = hasUnsavedChanges

        wasFilledFromLink = true

        if mailto.to.isEmpty == false { to = MailtoRequest.field(from: mailto.to) }
        if mailto.cc.isEmpty == false { cc = MailtoRequest.field(from: mailto.cc) }
        if mailto.bcc.isEmpty == false { bcc = MailtoRequest.field(from: mailto.bcc) }
        if mailto.subject.isEmpty == false { subject = mailto.subject }
        if mailto.body.isEmpty == false { body = AttributedString(mailto.body) + body }

        hasEditedRecipients = wasEdited
        hasUnsavedChanges = wasUnsaved
    }

    /// Whether this composer was opened by a `mailto:` link.
    ///
    /// Set by ``apply(_:)`` and never cleared: what it gates —
    /// ``isUntouchedLink`` — is already narrowed by the two conditions that do
    /// change, and a flag that flipped back would make closing ask again for a
    /// reason nobody could see.
    private var wasFilledFromLink = false

    /// Fills in what a reply or forward already knows.
    private func prefill() {
        switch kind {
        case .new:
            break

        case .reply(let message, let all):
            let answering = message.fromAddress.map {
                [EmailAddress(name: message.fromName, email: $0)]
            }
            let recipients = ReplyDrafting.replyRecipients(
                answering: answering ?? [],
                originalTo: message.to,
                originalCc: message.cc,
                all: all,
                // Empty here on purpose: identities are not loaded yet. See
                // ``applyOwnAddressExclusions()``.
                own: []
            )

            setRecipients(to: recipients.to, cc: recipients.cc)

            subject = ReplyDrafting.replySubject(message.subject)
            quotedHTML = Self.quote(message)

            if let messageID = message.messageID {
                threading = (
                    inReplyTo: [messageID],
                    references: ReplyDrafting.references(
                        continuing: message.references, with: messageID)
                )
            }

        case .forward(let message):
            subject = ReplyDrafting.forwardSubject(message.subject)
            quotedHTML = Self.forwardQuote(message)

            // A forward carries the original's files by blob id — nothing is
            // downloaded and nothing is re-uploaded. Forwarding used to send
            // the quote alone, so a message whose whole point was the PDF
            // arrived without it.
            attachments = message.attachments
                .filter { $0.isInline == false }
                .map {
                    PendingAttachment(
                        name: $0.displayName,
                        type: $0.type,
                        size: $0.size,
                        blobID: BlobID($0.blobID))
                }

        case .editDraft:
            // Nothing to guess: `load()` reads the real thing.
            break
        }

        hasEditedRecipients = false
        hasUnsavedChanges = false
    }

    /// The quoted original, in the convention every mail client understands.
    static func quote(_ message: MessageSnapshot) -> String {
        MailHTML.quote(
            author: message.displayName,
            // `sentAt` before `receivedAt` would be better still, but the
            // snapshot carries only the latter — see the report accompanying
            // this change.
            date: message.receivedAt,
            html: message.htmlBody,
            text: message.textBody ?? message.preview
        )
    }

    /// A forwarded original: a header block, not "X wrote:".
    static func forwardQuote(_ message: MessageSnapshot) -> String {
        MailHTML.forwarded(
            block: ReplyDrafting.forwardBlock(
                from: message.displayName,
                date: message.receivedAt,
                subject: message.subject,
                to: message.to,
                cc: message.cc),
            html: message.htmlBody,
            text: message.textBody ?? message.preview
        )
    }

    /// What goes on the wire: what was typed, then the quote.
    var outgoingHTML: String {
        let written = MailHTML.html(from: body)

        guard let quotedHTML else { return written }

        return written + "<div><br></div>" + quotedHTML
    }

    // MARK: - Emptiness

    /// Whether there is anything here worth saving.
    ///
    /// The signature and the quoted original are both excluded. Counting them
    /// meant that opening a reply and changing your mind left a draft in the
    /// mailbox containing nothing but your own sign-off under somebody else's
    /// message — once per abandoned composer, on every device.
    public var isEmpty: Bool {
        guard allRecipients.isEmpty, invalidRecipients.isEmpty else { return false }
        guard subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard attachments.isEmpty else { return false }

        return Self.isBlank(MailHTML.plainText(from: body), ignoring: appendedSignature)
    }

    /// Whether a body is blank once the signature is taken off it.
    ///
    /// `&nbsp;` and U+00A0 are stripped before the test: a rich editor emits a
    /// non-breaking space for a line somebody backspaced through, and treating
    /// that as content is how an empty composer became a draft.
    static func isBlank(_ text: String, ignoring signature: String?) -> Bool {
        var remaining = text

        if let signature, remaining.hasSuffix(signature) {
            remaining.removeLast(signature.count)
        }

        return
            remaining
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    // MARK: - Autosave

    /// Records that something changed and re-arms the debounce.
    private func noteEdited(recipientsChanged: Bool = false) {
        if recipientsChanged, isLoaded { hasEditedRecipients = true }

        guard isLoaded, isSending == false else { return }

        hasUnsavedChanges = true

        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()

        // Doubling per failure, capped. Nothing here retries on its own: this
        // task only exists because somebody typed, so a server that is down
        // sees one request per burst of typing rather than a loop.
        let delay = Self.autosaveDelay(afterFailures: autosaveFailures)

        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)

            guard Task.isCancelled == false else { return }

            await self?.saveDraft()
        }
    }

    static func autosaveDelay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return autosaveDebounce }

        let multiplier = 1 << min(failures, 8)
        let backoff = autosaveDebounce * multiplier

        return min(backoff, autosaveBackoffCeiling)
    }

    /// Writes what is on screen to the account's Drafts mailbox.
    ///
    /// Public so Cancel can force one, and so a test can drive it without
    /// waiting three seconds.
    public func saveDraft() async {
        guard status == .editing, hasUnsavedChanges, isEmpty == false else { return }

        // Held, not queued. The user has been told the draft changed elsewhere
        // and has to say what happens next; saving anyway is exactly the
        // overwrite the telling was meant to prevent. Said rather than
        // returned silently, so `saveAndClose` refuses to close on it and the
        // question cannot be walked past.
        guard isDraftConflicted == false else {
            saveState = .failed(Self.describe(DraftFailure.changedElsewhere))

            return
        }

        saveState = .saving

        do {
            try await write()

            autosaveFailures = 0
            hasUnsavedChanges = false
            saveState = .saved(.now)
        } catch {
            autosaveFailures += 1
            saveState = .failed(Self.describe(error))
            logger.error("Draft save failed: \(error, privacy: .public)")
        }
    }

    /// One save: upload anything new, then create or patch.
    ///
    /// `isRetry` is set on the second attempt after a `stateMismatch` that
    /// turned out not to be about this draft — see
    /// ``resolveStateMismatch()``. It exists only to stop a server whose
    /// state keeps moving from turning one save into a loop against somebody's
    /// NAS.
    private func write(isRetry: Bool = false) async throws {
        try await uploadNewAttachments()

        let content = DraftContent(
            to: RecipientParsing.addresses(in: to),
            cc: RecipientParsing.addresses(in: cc),
            bcc: RecipientParsing.addresses(in: bcc),
            subject: subject,
            text: MailHTML.plainText(from: body),
            html: outgoingHTML,
            inReplyTo: threading?.inReplyTo,
            references: threading?.references,
            attachments: attachmentWrite()
        )

        var builder = RequestBuilder(session: try await client.session())

        guard let draftID else {
            guard let drafts = try await store.mailbox(role: .drafts, accountKey: accountKey)
            else { throw DraftFailure.noDraftsMailbox }

            let create = builder.add(
                EmailCreate(
                    accountID: accountID,
                    draft: EmailCreate.Draft(drafts: drafts, content: content)))
            let results = try await client.send(builder)

            if let error = results.failure(of: create) { throw error }

            let result = try results.result(of: create)

            if let refused = result.notCreated?.values.first {
                throw DraftFailure.refused(Self.reason(refused))
            }

            guard let created = result.created?[EmailCreate.creationID] else {
                throw DraftFailure.notFound
            }

            self.draftID = created.id
            savedAttachmentBlobs = attachments.compactMap(\.blobID)
            // The state this composer's own write left the account in. Every
            // later save is conditional on it, which is what makes a second
            // device's edit visible instead of silently overwritten.
            confirmedState = result.newState

            return
        }

        let update = builder.add(
            DraftUpdate(
                accountID: accountID, emailID: draftID, content: content,
                ifInState: confirmedState))
        let results = try await client.send(builder)

        if let error = results.failure(of: update) {
            // The server refuses the whole call, not the object, so this
            // arrives here rather than in `notUpdated`.
            guard case .methodFailed(.stateMismatch, _, _) = error else { throw error }
            guard isRetry == false else { throw DraftFailure.changedElsewhere }

            try await resolveStateMismatch()

            return try await write(isRetry: true)
        }

        let result = try results.result(of: update)

        if let refused = result.notUpdated?.values.first {
            throw DraftFailure.refused(Self.reason(refused))
        }

        confirmedState = result.newState

        if case .whole = content.attachments {
            savedAttachmentBlobs = attachments.compactMap(\.blobID)
        }
    }

    // MARK: - Conflicts

    /// Decides whether a `stateMismatch` was actually about this draft.
    ///
    /// **It usually is not, and that is the whole reason this exists.**
    /// `Email/set`'s `ifInState` is checked against the *account's* Email
    /// state, which every arriving message moves. Reporting the refusal
    /// straight through would tell somebody their draft had changed elsewhere
    /// because a newsletter landed while they were typing — a warning that is
    /// wrong most of the time is a warning people learn to dismiss, and the one
    /// time it is right is the time it needed to be read.
    ///
    /// So the change log is asked what actually moved. If this draft's id is in
    /// it, another client wrote the draft and the user has to be told. If it is
    /// not, the cursor is advanced and the save is tried again — which is a
    /// retry, not a merge: nothing has been overwritten, because nothing else
    /// touched it.
    ///
    /// A truncated answer (`hasMoreChanges` still set after the loop) is
    /// treated as a conflict. Guessing "probably fine" from a partial log is
    /// how the one case this whole mechanism is for gets lost.
    private func resolveStateMismatch() async throws {
        guard let draftID, var since = confirmedState else {
            throw DraftFailure.changedElsewhere
        }

        // Small on purpose. This runs on a debounce inside a composer, and a
        // client that pages a busy account's whole change log before saving a
        // subject line has made typing depend on how much mail arrived.
        for _ in 0..<Self.conflictChangeLoops {
            var builder = RequestBuilder(session: try await client.session())
            let changes = builder.add(EmailChanges(accountID: accountID, sinceState: since))
            let results = try await client.send(builder)

            if let error = results.failure(of: changes) { throw error }

            let result = try results.result(of: changes)

            if result.updated.contains(draftID) || result.destroyed.contains(draftID) {
                isDraftConflicted = true

                throw DraftFailure.changedElsewhere
            }

            since = result.newState

            guard result.hasMoreChanges else {
                confirmedState = since

                return
            }
        }

        isDraftConflicted = true

        throw DraftFailure.changedElsewhere
    }

    /// How many `Email/changes` pages a conflict check will read before giving
    /// up and calling it a conflict. Each page is 256 rows, so this covers a
    /// composer left open through a thousand-message delivery.
    static let conflictChangeLoops = 4

    /// Keeps what is in the composer and lets it replace the newer copy.
    ///
    /// One of the two answers to the conflict, and the one that keeps this
    /// device's text. It does **not** merge — there is no way to interleave two edits
    /// to one letter — and it does not discard, because what is on screen is
    /// the only copy of the last few minutes of typing. Dropping the
    /// conditional is what makes the next save unconditional: an explicit
    /// last-writer-wins the user asked for, rather than one they never saw.
    ///
    /// The other choice is to close the composer, which leaves the other
    /// device's version on the server untouched.
    public func overwriteDraftElsewhere() {
        guard isDraftConflicted else { return }

        isDraftConflicted = false
        confirmedState = nil
        hasUnsavedChanges = true
        autosaveFailures = 0

        Task { await saveDraft() }
    }

    /// Closes the composer and leaves the other device's copy exactly as it is.
    ///
    /// The other half of the conflict question, and deliberately the explicit
    /// one: it costs whatever was typed here since the last successful save,
    /// which is a price only the user may agree to. Nothing is trashed — the
    /// draft on the server is the newer copy, and it stays.
    public func closeKeepingRemoteDraft() {
        autosaveTask?.cancel()
        isDraftConflicted = false
        status = .closed
    }

    /// Whether this save should carry the attachment array at all.
    ///
    /// Only when the set actually changed. `attachments` is a whole value:
    /// restating a dozen blob ids on every keystroke is pure cost over
    /// somebody's uplink, and each restatement is another chance for one
    /// unresolvable id to fail the whole patch — subject included.
    private func attachmentWrite() -> DraftAttachmentWrite {
        let current = attachments.compactMap(\.blobID)

        // Unknown set: never a whole value. See ``savedAttachmentBlobs``.
        guard let savedAttachmentBlobs else { return .unchanged }

        guard current != savedAttachmentBlobs else { return .unchanged }

        return .whole(
            attachments.compactMap { attachment in
                attachment.blobID.map {
                    DraftAttachment(blobID: $0, type: attachment.type, name: attachment.name)
                }
            })
    }

    /// Uploads any file that does not yet have a blob id.
    ///
    /// **At save, not at pick.** The server reclaims unreferenced blobs on a
    /// timer, so a file uploaded when it was chosen and referenced only days
    /// later — a draft left open over a holiday — would be sent with its
    /// attachment already collected. The save that first references it is what
    /// makes the `p-` id durable.
    ///
    /// Sequentially, because `maxConcurrentUpload` is 4 and the audience runs
    /// this against hardware where four simultaneous multi-megabyte POSTs is
    /// the difference between a save and a timeout.
    private func uploadNewAttachments() async throws {
        // A create has nothing to compare against, so an unknown saved set is
        // the empty set rather than "leave it alone".
        if draftID == nil, savedAttachmentBlobs == nil { savedAttachmentBlobs = [] }

        // Nothing to upload *for*: on a draft that could not be read whole,
        // the array will not be sent, and a blob nothing references is scratch
        // the server reclaims on a timer. Uploading it would be megabytes over
        // somebody's uplink for a file that is then collected.
        guard savedAttachmentBlobs != nil else { return }

        for index in attachments.indices where attachments[index].blobID == nil {
            guard let data = attachments[index].data else { continue }

            let blob = try await client.upload(
                data, type: attachments[index].type, accountID: accountID)

            attachments[index].blobID = blob.blobID
        }
    }

    // MARK: - Closing

    /// Saves whatever is here and finishes.
    ///
    /// The Save Draft half of Cancel. An empty composer saves nothing and
    /// simply closes — there is no draft to make.
    public func saveAndClose() async {
        autosaveTask?.cancel()

        guard isEmpty == false else {
            status = .closed
            return
        }

        // Forced: a close has to write even when the debounce has not fired.
        hasUnsavedChanges = true
        await saveDraft()

        if case .failed = saveState { return }

        status = .closed
    }

    /// Throws the draft away.
    ///
    /// Trash, not a hard delete: nothing in this product deletes irreversibly,
    /// and a composer is the last place to start.
    public func discardDraft() async {
        autosaveTask?.cancel()

        guard let draftID else {
            status = .closed
            return
        }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let trash = builder.add(
                EmailSet.trash(ids: [draftID], accountID: accountID))
            let results = try await client.send(builder)

            if let error = results.failure(of: trash) { throw error }
        } catch {
            // The draft stays. Saying so beats claiming a deletion that did
            // not happen — the copy on the server would reappear at the next
            // sync and look like the app resurrecting it.
            saveState = .failed(Self.describe(error))
            logger.error("Draft discard failed: \(error, privacy: .public)")

            return
        }

        self.draftID = nil
        status = .closed
    }

    /// Whether closing needs to ask.
    ///
    /// A composer with nothing in it just closes: a confirmation over an empty
    /// sheet is a dialogue that can only be answered one way.
    ///
    /// So is a composer holding nothing but a `mailto:` link — see
    /// ``isUntouchedLink``.
    public var needsCloseConfirmation: Bool {
        isEmpty == false && status == .editing && isUntouchedLink == false
    }

    /// Whether everything here came from a link and nothing from a person.
    ///
    /// Tapping an address on a web page opens a composer with a recipient in
    /// it, which is not empty — so without this, backing out of a link
    /// somebody tapped by accident asks them to choose between deleting and
    /// saving a draft they never wrote a word of. Nothing would be lost by
    /// either answer, which is the definition of a question not worth asking.
    ///
    /// Narrow on purpose. It stops holding the moment the first keystroke sets
    /// ``hasUnsavedChanges``, and it never holds once ``draftID`` exists: a
    /// draft that has reached the server is a thing on other devices, and
    /// closing over one has to offer to delete it.
    private var isUntouchedLink: Bool {
        wasFilledFromLink && hasUnsavedChanges == false && draftID == nil
    }

    // MARK: - Sending

    /// Sends the message, with a few seconds' grace to change your mind.
    ///
    /// Closes at once. The recall window is a ``undoGrace``-second `HOLDFOR` on
    /// the submission itself, offered from the Outbox rather than from a
    /// composer kept open to run a countdown — so the mail leaves on time if
    /// the app is killed, and the undo cancels something that actually exists.
    public func send() {
        guard canSend, let identity = selectedIdentity else { return }

        // Before anything else: a late autosave landing after the send has
        // been prepared would overwrite the body being sent with an older one.
        autosaveTask?.cancel()

        status = .queuing
        sendTask = Task { await deliver(identity: identity, undoGrace: Self.undoGrace) }
    }

    /// Queues the message to go out no earlier than `date`.
    ///
    /// No grace period here, unlike ``send()``. The few seconds exist to catch
    /// the "wrong person" moment on a message that is about to leave; one held
    /// back until tomorrow morning is recallable for as long as it waits, from
    /// the Outbox, so a second window inside it would be theatre.
    ///
    /// **Where it is held is not decided here.** The message is filed with a
    /// time, and the outbox offers that time to the server on the next drain:
    /// accepted, the mail leaves with the phone in a drawer; refused — past the
    /// server's ceiling, or an older instance — it stays on this device and
    /// goes out at the first check after. Deciding here would mean guessing at
    /// a ceiling this client cannot yet read, and guessing high loses mail to a
    /// refusal that arrives after the composer has closed.
    public func scheduleSend(at date: Date) {
        guard canSend, let identity = selectedIdentity else { return }

        autosaveTask?.cancel()

        status = .queuing
        sendTask = Task { await deliver(identity: identity, sendAfter: date) }
    }

    /// Queues the message and asks the outbox to send it.
    ///
    /// Always queued first, even when the server is right there. The previous
    /// version sent directly and, when the request failed, told the user "the
    /// message is saved as a draft" — which was false: the draft creation *was*
    /// the request that failed, so dismissing the composer lost the text. For a
    /// mail client whose server is somebody's NAS, being unreachable is a
    /// normal Tuesday, and it must not be the way mail disappears.
    ///
    /// Writing to disk before sending also means the message survives the app
    /// being killed mid-send, which no amount of retry logic in memory does.
    private func deliver(
        identity: SendingIdentity, sendAfter: Date? = nil, undoGrace: Int? = nil
    ) async {
        var queued = Outbox.PendingMessage(
            accountKey: identity.accountKey,
            accountID: identity.accountID,
            identityID: identity.identity.id,
            from: identity.address,
            to: RecipientParsing.addresses(in: to),
            cc: RecipientParsing.addresses(in: cc),
            bcc: RecipientParsing.addresses(in: bcc),
            subject: subject,
            body: MailHTML.plainText(from: body),
            html: outgoingHTML,
            inReplyTo: threading?.inReplyTo,
            references: threading?.references,
            // Whatever draft this composer has on the server, autosaved or
            // opened. Without it a message written, left for three seconds and
            // then sent leaves its own draft behind in Drafts.
            editingEmailID: draftID?.rawValue,
            attachments: attachments.map {
                Outbox.Attachment(
                    name: $0.name,
                    type: $0.type,
                    // Bytes only for what this device holds. A part that
                    // already lives on the server travels as its blob id, so a
                    // forwarded 30 MB video is never downloaded to be sent.
                    data: $0.data ?? Data(),
                    blobID: $0.data == nil ? $0.blobID?.rawValue : nil)
            }
        )

        queued.sendAfter = sendAfter
        queued.undoGraceSeconds = undoGrace

        do {
            try await outbox.enqueue(queued)
        } catch {
            // Nowhere left to put it. Keeping the composer open with the text
            // intact is the only honest response.
            status = .failed(
                String(
                    localized: "Couldn't save this message. Don't close the composer yet.",
                    bundle: .module))
            logger.error("Outbox enqueue failed: \(error, privacy: .public)")

            return
        }

        // Closes immediately. The send happens in the outbox, which outlives
        // this sheet — waiting here would make an offline send look like a
        // hang, and the message is already safe on disk.
        onQueued()
        status = .sent
    }

    // MARK: - Failures

    private static func reason(_ refusal: JSONValue) -> String {
        refusal.objectValue?["type"]?.stringValue ?? "unknown"
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DraftFailure.noDraftsMailbox:
            String(localized: "This account has no Drafts mailbox to send from.", bundle: .module)

        case DraftFailure.changedElsewhere:
            String(
                localized: "This draft changed on another device. Nothing here has been lost.",
                bundle: .module)

        case DraftFailure.refused("stateMismatch"):
            String(
                localized: "This draft changed somewhere else. Reopen it to see the newest copy.",
                bundle: .module)

        case DraftFailure.refused:
            String(localized: "The server wouldn't save this draft.", bundle: .module)

        case JMAPError.notAuthenticated:
            String(localized: "Sign in again to save this.", bundle: .module)

        default:
            String(
                localized: "Couldn't reach the server. This is still on your phone.",
                bundle: .module)
        }
    }
}

extension ComposeModel.Kind: Identifiable {
    /// Stable enough to drive a sheet: what is being written, and about what.
    public var id: String {
        switch self {
        case .new: "new"
        case .reply(let message, let all): "reply-\(all)-\(message.id)"
        case .forward(let message): "forward-\(message.id)"
        case .editDraft(let emailID): "draft-\(emailID)"
        }
    }
}
