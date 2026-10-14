/// `Mailbox/set` (RFC 8621 §2.5) — create, rename, re-parent and destroy
/// labels.
///
/// plMail implements this in full, so unlike ``IdentitySet`` there is nothing
/// to hold back: `name`, `parentId`, `isSubscribed`, `sortOrder` and `color`
/// are all settable, and destroy works on any label the user made.
///
/// The server's rules, which the UI has to respect *before* sending rather than
/// discover from a refusal:
///
/// - **System labels are immutable.** Anything with a ``MailboxRole`` maps onto
///   a provider built-in like INBOX, which no API can rename or delete.
///   `Mailbox/get` says so in ``MailboxRights/mayRename`` and
///   ``MailboxRights/mayDelete``; trust those rather than inferring from `role`,
///   because the server is the one that decides.
/// - **A name may not contain `/`.** Gmail encodes hierarchy in the name, so a
///   slash in a leaf name would silently create a nested label on the provider.
///   Use ``parentID`` for nesting.
/// - **Siblings must have distinct names.** Same-named children of the same
///   parent are refused with `invalidProperties`.
/// - **A label with children cannot be destroyed** (`mailboxHasChild`); the
///   children go first.
/// - **`onDestroyRemoveEmails` is refused outright**, not ignored — plMail
///   never deletes mail as a side effect of removing a label. It is therefore
///   not modelled here at all, because the only value it could carry is the one
///   the server rejects.
///
/// Destroying is per-account: a Mailbox is a label *binding*, so this
/// un-materialises the label here and leaves the user's other accounts alone.
public struct MailboxSet: JMAPMethod {
    public static let name = "Mailbox/set"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Keyed by a client-chosen creation id, which the response echoes back
        /// alongside the real id the server assigned.
        public var create: [String: Creation]?
        public var update: [MailboxID: Patch]?
        public var destroy: [MailboxID]?
        public var ifInState: StateToken?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case create, update, destroy, ifInState
        }
    }

    /// A new label.
    public struct Creation: Encodable, Sendable, Hashable {
        /// The **leaf** name. May not contain `/`.
        public var name: String
        /// The parent's binding id, or nil for a top-level label.
        public var parentID: MailboxID?
        /// Whether the label shows in the sidebar. Defaults to visible, which
        /// is what someone who just typed a name into a "New label" field
        /// means — a label created hidden looks like a label that failed.
        public var isSubscribed: Bool?
        public var sortOrder: Int?
        /// The colour to give the new label, or nil for "no colour chosen".
        ///
        /// A plain optional rather than the double optional ``Patch/color``
        /// needs: `MailboxSetMethod` reads a create's colour as
        /// `$properties['color'] ?? null`, so an absent key and an explicit
        /// null are the same request here and there is no third state to
        /// express. Sending `color: null` anyway would be a key the user never
        /// asked for, which is the habit that makes the *update* path
        /// dangerous.
        ///
        /// Typed as ``LabelColor`` rather than `String` because the server
        /// refuses an unknown token outright with `invalidProperties` — a
        /// create that fails after the user typed a name is worse than a
        /// vocabulary the compiler enforces.
        public var color: LabelColor?

        public init(
            name: String,
            parentID: MailboxID? = nil,
            isSubscribed: Bool? = nil,
            sortOrder: Int? = nil,
            color: LabelColor? = nil
        ) {
            self.name = name
            self.parentID = parentID
            self.isSubscribed = isSubscribed
            self.sortOrder = sortOrder
            self.color = color
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case parentID = "parentId"
            case isSubscribed, sortOrder, color
        }
    }

    /// A change to an existing label.
    ///
    /// Every field is doubly optional on the wire: absent means "leave it
    /// alone", present-and-null means "clear it". Two properties can actually
    /// be cleared — ``parentID``, moving a nested label back to the top level,
    /// and ``color``, taking a colour off again — and for both of them `nil`
    /// and "not mentioned" are different requests, which is why neither can be
    /// a plain optional encoded with the synthesised encoder: that would send
    /// `parentId: null` on every rename and silently flatten the user's
    /// hierarchy, and `color: null` on every re-parent and silently discard
    /// the colour.
    public struct Patch: Encodable, Sendable, Hashable {
        public var name: String?
        /// `.some(nil)` moves the label to the top level; `nil` leaves the
        /// parent untouched.
        public var parentID: MailboxID??
        public var isSubscribed: Bool?
        public var sortOrder: Int?
        /// `.some(nil)` clears the colour; `nil` leaves it untouched.
        ///
        /// Clearing is a real operation — "no colour chosen" is a state the
        /// user can return a label to, and it is not the same as colouring it
        /// grey — so the third state has to be expressible. `MailboxSetMethod`
        /// reads this arm as `$label->color = $this->requireColor($value)`,
        /// where a null value is accepted and stored.
        ///
        /// Note the server does **not** gate this on `assertMutable`: a system
        /// label's colour is the one thing about it a user may change, so this
        /// is settable even where ``MailboxRights/mayRename`` is false.
        public var color: LabelColor??

        public init(
            name: String? = nil,
            parentID: MailboxID?? = nil,
            isSubscribed: Bool? = nil,
            sortOrder: Int? = nil,
            color: LabelColor?? = nil
        ) {
            self.name = name
            self.parentID = parentID
            self.isSubscribed = isSubscribed
            self.sortOrder = sortOrder
            self.color = color
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case parentID = "parentId"
            case isSubscribed, sortOrder, color
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(isSubscribed, forKey: .isSubscribed)
            try container.encodeIfPresent(sortOrder, forKey: .sortOrder)

            // The one case the synthesised encoder cannot express. An unset
            // parent must not appear as a key at all: the server treats any
            // mentioned property as a change, and `parentId: null` on a rename
            // would move the label to the top level as a side effect.
            if let parentID {
                if let parentID {
                    try container.encode(parentID, forKey: .parentID)
                } else {
                    try container.encodeNil(forKey: .parentID)
                }
            }

            // Same shape, same reason. An unset colour must not appear as a
            // key at all, or every rename would clear a colour the user chose
            // in the web UI — and the user would have no way to tell which of
            // the two clients did it.
            if let color {
                if let color {
                    try container.encode(color, forKey: .color)
                } else {
                    try container.encodeNil(forKey: .color)
                }
            }
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken?
        /// Keyed by the *creation* id sent in ``Arguments/create``, carrying
        /// the server-assigned ``Mailbox`` — its `id` is what everything else
        /// then refers to.
        public var created: [String: Mailbox]?
        public var notCreated: [String: JSONValue]?
        public var updated: [MailboxID: JSONValue]?
        public var notUpdated: [MailboxID: JSONValue]?
        public var destroyed: [MailboxID]?
        public var notDestroyed: [MailboxID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState
            case created, notCreated, updated, notUpdated, destroyed, notDestroyed
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID,
        create: [String: Creation]? = nil,
        update: [MailboxID: Patch]? = nil,
        destroy: [MailboxID]? = nil,
        ifInState: StateToken? = nil
    ) {
        arguments = Arguments(
            accountID: accountID,
            create: create,
            update: update,
            destroy: destroy,
            ifInState: ifInState
        )
    }

    // MARK: - The three things the app actually does

    /// The creation id used by ``create(name:parentID:accountID:)``, and the
    /// key to read the new mailbox back out of ``Result/created``.
    public static let creationID = "new"

    public static func create(
        name: String, parentID: MailboxID? = nil, color: LabelColor? = nil,
        accountID: AccountID
    ) -> MailboxSet {
        MailboxSet(
            accountID: accountID,
            create: [creationID: Creation(name: name, parentID: parentID, color: color)]
        )
    }

    public static func rename(
        _ id: MailboxID, to name: String, accountID: AccountID
    ) -> MailboxSet {
        MailboxSet(accountID: accountID, update: [id: Patch(name: name)])
    }

    /// Sets or clears one label's colour and touches nothing else.
    ///
    /// `color` is `.some(nil)` to clear. Spelt out as a double optional at the
    /// call site rather than defaulted, because the difference between "make
    /// it blue" and "make it uncoloured" is the whole point of this method and
    /// a caller that cannot see which one it is asking for will eventually ask
    /// for the wrong one.
    public static func recolor(
        _ id: MailboxID, to color: LabelColor?, accountID: AccountID
    ) -> MailboxSet {
        MailboxSet(accountID: accountID, update: [id: Patch(color: .some(color))])
    }

    /// Moves a label under a new parent, or to the top level when `parentID`
    /// is nil. The name is left alone: re-parenting is not renaming, and a
    /// patch that mentions both is two changes the server can refuse as one.
    public static func reparent(
        _ id: MailboxID, to parentID: MailboxID?, accountID: AccountID
    ) -> MailboxSet {
        MailboxSet(accountID: accountID, update: [id: Patch(parentID: .some(parentID))])
    }

    public static func destroy(_ id: MailboxID, accountID: AccountID) -> MailboxSet {
        MailboxSet(accountID: accountID, destroy: [id])
    }
}
