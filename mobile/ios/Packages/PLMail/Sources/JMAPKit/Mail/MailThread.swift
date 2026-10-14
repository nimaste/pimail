/// An RFC 8621 `Thread`.
///
/// Named `MailThread` rather than `Thread` to stay clear of `Foundation.Thread`
/// at every call site.
///
/// Threading is currently RFC Message-ID based rather than Gmail-native, so
/// expect occasional divergence from what the Gmail web UI groups together.
public struct MailThread: Hashable, Sendable, Codable {
    public var id: ThreadID

    /// In date order, oldest first.
    public var emailIDs: [EmailID]

    /// When this conversation is due back — a **plMail extension**, not
    /// RFC 8621, which gives Thread only an id and its emails.
    ///
    /// The server nils an elapsed snooze rather than reporting a time in the
    /// past, so a non-nil value here is always still pending and nothing has to
    /// re-check the clock to know that.
    ///
    /// Note that nothing in plMail *filters* on this, the web list included: a
    /// snoozed conversation stays where it is and is badged. Hiding it here
    /// would make the two clients disagree about what an inbox contains.
    public var snoozedUntil: UTCDate?

    /// The classifier's tab for this conversation — a **plMail extension**.
    ///
    /// Read from here and never from `Email.category`: a newsletter somebody
    /// replied to has messages in two categories, so a tab drawn from the
    /// per-message signal would put one conversation under two headings. This
    /// is the resolved, most-recent-wins value the server computes, and the one
    /// `Email/query`'s `threadCategory` condition agrees with.
    ///
    /// **Nil is not Primary.** A conversation the classifier never saw belongs
    /// under no heading at all; folding it into Primary would put mail on the
    /// phone's Primary tab that the browser's does not have.
    public var category: MessageCategory?

    /// Never put in front of this user, and arrived inside the server's
    /// 24-hour window — a **plMail extension**.
    ///
    /// Both halves are decided server-side against **one clock reading per
    /// response**, so two threads in one answer cannot straddle the boundary.
    /// Re-deriving the window here would be a second implementation of it that
    /// drifts the day the server changes the constant.
    ///
    /// **New is not unread and the two are allowed to disagree**: a
    /// conversation read on a laptop is still new to a client that has never
    /// drawn its row. Retire it with ``ThreadSet/Patch/shown``.
    public var isNew: Bool

    public init(
        id: ThreadID,
        emailIDs: [EmailID] = [],
        snoozedUntil: UTCDate? = nil,
        category: MessageCategory? = nil,
        isNew: Bool = false
    ) {
        self.id = id
        self.emailIDs = emailIDs
        self.snoozedUntil = snoozedUntil
        self.category = category
        self.isNew = isNew
    }

    /// Hand-written for the two extensions, which a standard server does not
    /// send at all.
    ///
    /// The synthesised decoder requires every non-optional key to be present,
    /// so a `Thread/get` from anything but plMail would fail to decode
    /// outright — the whole conversation list would come back empty rather
    /// than merely unbadged. An unknown `category` token decodes as nil for the
    /// same reason it does in ``MessageCategory/init(wire:)``: "no tab" is a
    /// real answer, where a value that names nothing is not.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(ThreadID.self, forKey: .id)
        emailIDs = try container.decodeIfPresent([EmailID].self, forKey: .emailIDs) ?? []
        snoozedUntil = try container.decodeIfPresent(UTCDate.self, forKey: .snoozedUntil)
        category = MessageCategory(
            wire: try container.decodeIfPresent(String.self, forKey: .category))
        isNew = try container.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case emailIDs = "emailIds"
        case snoozedUntil
        case category
        case isNew
    }
}
