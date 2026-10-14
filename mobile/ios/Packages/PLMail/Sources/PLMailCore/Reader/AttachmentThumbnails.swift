import Foundation
import JMAPKit
import UniformTypeIdentifiers

/// Whether an attachment is worth fetching bytes for in order to draw a
/// 60-point square, and what to draw instead when it is not.
///
/// **This exists to stop a thumbnail grid from becoming a download storm.**
/// The whole app is built on not fetching eagerly, because the server is
/// somebody's NAS with one PHP worker pool. A grid is precisely the feature
/// that quietly undoes that: ten attachments on one message is ten downloads,
/// and a reader scrolled through a long thread is hundreds. So the rules are
/// stated here, in one pure value type with no I/O in it, and every one of
/// them is a brake:
///
/// - **Nothing is fetched because a view appeared.** ``Decision/download`` is
///   only ever returned to a caller that is acting on a tap; drawing the grid
///   asks with `isUserInitiated: false` and gets a placeholder.
/// - **Already on disk is free.** A blob ``Store/BlobCache`` has cached — the
///   user opened or saved it once — is rendered without asking anything,
///   online or off.
/// - **Only types Quick Look can render from a file cheaply.** An image or a
///   PDF; nothing else. A 40 MB video whose first frame is worth 60 points is
///   40 MB down a domestic line for a picture nobody asked for.
/// - **A size ceiling read from the server, not invented.**
///   See ``Limits/reading(_:accountID:)``.
/// - **One at a time.** There is no concurrency knob here on purpose: the
///   fetch loop is sequential, so a tap can never occupy more than one of the
///   server's request permits and a sync the user is actually waiting on is
///   never queued behind eight pictures.
/// - **One failure per attachment, ever.** A blob the server has evicted
///   returns the same error every time, and a grid that retries on every
///   redraw is a loop against a single-worker server.
/// - **Offline is a placeholder, not an error.** The typed icon is a true
///   statement about the attachment; a broken-image glyph is not.
public struct AttachmentThumbnailPolicy: Sendable, Equatable {
    /// The numbers a decision is measured against.
    public struct Limits: Sendable, Equatable {
        /// The largest attachment worth pulling down for a thumbnail.
        ///
        /// Bytes fetched here are bytes the user did not ask for, over a link
        /// the user does not control, from a machine that serves one request
        /// at a time. Past this the honest thing is a typed placeholder and
        /// the existing tap-to-open path, which at least happens because
        /// somebody wanted it.
        public var byteCeiling: Int
        /// How many thumbnails one message may fetch on a single tap.
        ///
        /// A newsletter with forty inline-ish attachments must not turn one
        /// tap into forty requests. Past this the remaining tiles keep their
        /// placeholders; nothing is hidden and nothing is queued for later.
        public var perMessage: Int

        public init(byteCeiling: Int, perMessage: Int) {
            self.byteCeiling = byteCeiling
            self.perMessage = perMessage
        }

        /// What this client is willing to spend before it has asked the
        /// server, and the most it will ever spend afterwards.
        ///
        /// Used to decide whether the "Show previews" control is worth drawing
        /// at all, which must not itself require a round trip. A Session read
        /// later can only lower these numbers — see ``reading(_:accountID:)``
        /// — so a control offered here and then declined per attachment leaves
        /// the placeholder in place rather than showing a failure.
        public static let local = Limits(byteCeiling: renderableByteCeiling, perMessage: 8)

        /// A local stop that no server number may raise.
        ///
        /// plMail publishes `maxSizeAttachmentsPerEmail: 50_000_000`, which is
        /// what the server will *accept*, not what is worth rendering to a
        /// 60-point square. Reading the published number and obeying it alone
        /// would authorise a 50 MB fetch for a thumbnail. So the server's
        /// number is a maximum and this is the one that usually binds — two
        /// megabytes covers virtually every photograph anyone attaches and
        /// stops well short of a scanned TIFF.
        public static let renderableByteCeiling = 2 * 1024 * 1024

        /// The limits this server actually publishes, clamped.
        ///
        /// **Read rather than invented**: `maxSizeAttachmentsPerEmail` on the
        /// account is a real number from the live Session, per install and
        /// changeable by the maintainer. A server configured smaller than
        /// ``renderableByteCeiling`` must lower the ceiling rather than have
        /// the client ask for bytes it will not serve; a server configured
        /// larger does not raise it, because 50 MB is still 50 MB.
        ///
        /// - Parameters:
        ///   - session: The live Session.
        ///   - accountID: Which account's mail capabilities to read. Limits
        ///     are per account in JMAP, and applying one account's ceiling to
        ///     another is how a client bounds itself by a number that account
        ///     never published.
        /// - Returns: The ceiling this client will actually apply, which is
        ///   never higher than ``renderableByteCeiling``.
        public static func reading(_ session: Session, accountID: AccountID) -> Limits {
            let published = session.accounts[accountID]?
                .accountCapabilities.mail?.maxSizeAttachmentsPerEmail

            return Limits(
                byteCeiling: max(0, min(published ?? renderableByteCeiling, renderableByteCeiling)),
                perMessage: local.perMessage
            )
        }
    }

    /// What the caller should do with one attachment.
    public enum Decision: Sendable, Equatable {
        /// Bytes are already on disk. Render from the file — no network, so
        /// this is also the offline answer for anything ever opened.
        case render
        /// Worth a download, and the caller is acting on an explicit tap.
        case download
        /// Draw the typed placeholder and say nothing about it. Every reason
        /// below is an ordinary state, not a fault.
        case placeholder(Reason)
    }

    /// Why an attachment is showing an icon rather than a picture.
    ///
    /// Carried rather than collapsed to a bool so a test can assert *which*
    /// brake held. "No thumbnail appeared" is also true of a crash.
    public enum Reason: Sendable, Equatable {
        /// Nothing has asked for it yet. The resting state of every tile in a
        /// freshly drawn grid, and the reason scrolling costs nothing.
        case notRequested
        /// Quick Look cannot render this type from a local file without
        /// downloading far more than the picture is worth.
        case notRenderable
        /// Bigger than ``Limits/byteCeiling``.
        case tooLarge(ceiling: Int)
        /// No network, and no cached copy. Not an error: the placeholder is
        /// still a true statement about the attachment.
        case offline
        /// A previous fetch or render failed. Never retried automatically —
        /// see the type's own documentation.
        case failed
        /// This message has already spent ``Limits/perMessage`` on one tap.
        case budgetSpent
    }

    /// What the caller already knows about one attachment when it asks.
    ///
    /// A struct rather than six parameters so a new brake cannot be added
    /// without every call site being made to state its answer.
    public struct Context: Sendable, Equatable {
        /// Whether ``Store/BlobCache`` already holds the bytes.
        public var isOnDisk: Bool
        /// Whether the user just tapped something. False for a redraw, a
        /// scroll, or a message expanding — which is the entire point.
        public var isUserInitiated: Bool
        /// Read from `MailSyncService.isDeviceOffline`. A fetch attempted with
        /// no network fails after a timeout and leaves a spinner where a
        /// perfectly good icon was.
        public var isDeviceOffline: Bool
        /// Whether this blob has already failed once in this session.
        public var hasFailed: Bool
        /// How many of this message's attachments have already been fetched.
        public var spentInMessage: Int

        public init(
            isOnDisk: Bool = false,
            isUserInitiated: Bool = false,
            isDeviceOffline: Bool = false,
            hasFailed: Bool = false,
            spentInMessage: Int = 0
        ) {
            self.isOnDisk = isOnDisk
            self.isUserInitiated = isUserInitiated
            self.isDeviceOffline = isDeviceOffline
            self.hasFailed = hasFailed
            self.spentInMessage = spentInMessage
        }
    }

    public var limits: Limits

    public init(limits: Limits = .local) {
        self.limits = limits
    }

    /// The one decision function. Everything else in this file describes it.
    ///
    /// Order matters and is not arbitrary. Renderability and size are checked
    /// *before* the disk, so a cached 40 MB TIFF is still not handed to a
    /// thumbnail generator; the ceiling is about what is worth rendering, not
    /// only about what is worth downloading. The disk is checked before
    /// offline and before user intent, because bytes already here cost
    /// nothing either way.
    public func decision(for attachment: AttachmentSnapshot, in context: Context) -> Decision {
        guard Self.isRenderable(type: attachment.type, name: attachment.name) else {
            return .placeholder(.notRenderable)
        }

        guard attachment.size <= limits.byteCeiling else {
            return .placeholder(.tooLarge(ceiling: limits.byteCeiling))
        }

        if context.isOnDisk { return .render }
        if context.hasFailed { return .placeholder(.failed) }
        guard context.isUserInitiated else { return .placeholder(.notRequested) }
        guard context.isDeviceOffline == false else { return .placeholder(.offline) }
        guard context.spentInMessage < limits.perMessage else {
            return .placeholder(.budgetSpent)
        }

        return .download
    }

    /// Whether this attachment could ever become a picture, wherever its bytes
    /// happen to be.
    ///
    /// The two checks that are about the attachment rather than about the
    /// network, pulled out so the disk path can apply them **before** touching
    /// the filesystem. A 40 MB TIFF already in the cache is still not worth
    /// rendering to a 60-point square on a five-year-old phone, and asking
    /// this first is what stops "it's local, so it's free" from becoming the
    /// argument that it is.
    public func isWorthRendering(_ attachment: AttachmentSnapshot) -> Bool {
        Self.isRenderable(type: attachment.type, name: attachment.name)
            && attachment.size <= limits.byteCeiling
    }

    /// Whether *any* fetch could ever help this message.
    ///
    /// Drives whether the "Show previews" control is drawn at all. A control
    /// that is always present and does nothing for a message of five
    /// spreadsheets is worse than its absence.
    public func hasAnythingWorthFetching(
        _ attachments: [AttachmentSnapshot], in context: Context
    ) -> Bool {
        attachments.contains { attachment in
            decision(for: attachment, in: context) == .download
        }
    }

    // MARK: - Types

    /// The types worth a thumbnail: still images and PDFs, and nothing else.
    ///
    /// `QLThumbnailGenerator` renders from a local file, so "can Quick Look
    /// preview it" is not the question — the question is what the whole file
    /// costs to get. A still image is usually the same order of magnitude as
    /// the thumbnail's own information; a PDF's first page is worth its
    /// download because the first page is what the reader wants to identify.
    /// Video, audio, archives and office documents are all cases where the
    /// download is many megabytes and the picture says little the filename and
    /// the typed icon do not — an audio file's thumbnail is a waveform of
    /// nothing.
    ///
    /// Decided from the declared type first and the filename's extension only
    /// as a fallback: the server stores what the sender declared and never
    /// parses it, so both are hints, and the declared type is the one the
    /// download will echo back in `Content-Type`.
    public static func isRenderable(type: String, name: String?) -> Bool {
        let declared = UTType(mimeType: type.lowercased())

        if let declared, isRenderable(declared) { return true }

        // The filename is consulted only when the declared type said nothing
        // useful. `application/octet-stream` — which maps to the bare `.data`
        // — is what a scanner, a mail gateway or a phone that lost the
        // extension attaches a perfectly ordinary JPEG as, and it is common
        // enough that refusing it would leave a whole class of photographs
        // permanently iconic. A sender who declared a *specific* wrong type is
        // believed instead: second-guessing that would mean downloading a zip
        // because someone called it `backup.jpg`.
        guard declared == nil || declared == .data else { return false }

        guard
            let name,
            let ext = name.split(separator: ".").last,
            name.contains("."),
            let guessed = UTType(filenameExtension: String(ext).lowercased())
        else { return false }

        return isRenderable(guessed)
    }

    private static func isRenderable(_ type: UTType) -> Bool {
        if type.conforms(to: .pdf) { return true }

        // Conformance rather than a list: HEIC, WebP and whatever Apple adds
        // next all conform to `.image`, and a hand-written list would quietly
        // stop covering the format everyone's phone starts producing.
        guard type.conforms(to: .image) else { return false }

        // Animated formats are images that Quick Look renders by decoding
        // every frame. The first frame is all a tile shows, and the rest is
        // work and memory on a device that may be a five-year-old phone.
        return type.conforms(to: .gif) == false
    }

    // MARK: - The placeholder

    /// What to draw when there is no picture: an SF Symbol and a short phrase
    /// naming the type.
    ///
    /// **Free and honest.** `UTType` already knows that
    /// `application/vnd.oasis.opendocument.spreadsheet` is a spreadsheet, and
    /// saying so costs no bytes. This is what makes "never fetch on appear" a
    /// design rather than an omission — the resting state of a tile is
    /// informative on its own.
    public struct TypedPlaceholder: Sendable, Equatable {
        /// An SF Symbol name. Hand-mapped because `UTType` offers no symbol.
        public var symbolName: String
        /// The system's own localised name for the type — "PDF Document",
        /// "JPEG image" — or nil when the type is unrecognised, in which case
        /// the caller says nothing rather than showing a MIME string at a
        /// reader who did not ask for one.
        public var typeDescription: String?

        public init(symbolName: String, typeDescription: String?) {
            self.symbolName = symbolName
            self.typeDescription = typeDescription
        }
    }

    /// The placeholder for one attachment.
    ///
    /// Derived from the declared type, which the server stores verbatim and
    /// never validates — so this is a hint for the reader, never a claim about
    /// the bytes. A wrong `Content-Type` must degrade to a generic document
    /// rather than to nothing.
    public static func placeholder(for attachment: AttachmentSnapshot) -> TypedPlaceholder {
        let declared = UTType(mimeType: attachment.type.lowercased())

        return TypedPlaceholder(
            symbolName: symbolName(for: attachment.type),
            typeDescription: declared?.localizedDescription
        )
    }

    /// Chosen from the declared type.
    ///
    /// Lifted out of the view so the grid tile and the accessibility-size row
    /// cannot drift into showing different icons for the same attachment,
    /// which is exactly the kind of difference that reads as a bug in whatever
    /// the reader saw second.
    public static func symbolName(for type: String) -> String {
        let type = type.lowercased()

        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type.contains("calendar") { return "calendar" }
        if type.hasPrefix("text/") { return "doc.text" }

        return "doc"
    }
}
