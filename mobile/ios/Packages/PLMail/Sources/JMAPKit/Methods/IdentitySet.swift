/// `Identity/set` (RFC 8621 §6.3) — rename, and sign.
///
/// **This type used to expose only `name`, on the strength of a doc comment
/// that stated as server fact that plMail rejects `htmlSignature`.** That was
/// read from a stale checkout. On the current server (`IdentitySetMethod`), a
/// create accepts `email`, `name`, `htmlSignature` and `textSignature`, and an
/// update accepts `name`, `htmlSignature` and `textSignature`; the signature is
/// written into the same per-alias account setting the web composer reads, so a
/// signature written on a phone is the one the browser signs with. `replyTo`
/// and `bcc` are still refused — plMail has nowhere to keep them, and a client
/// that thought it had saved a per-identity Bcc would silently send without it.
///
/// Two server rules the patch shape here exists to honour:
///
/// - **`htmlSignature` wins when both are sent.** The server takes the HTML and
///   ignores the text, so sending a text form as a "fallback" beside an HTML one
///   does nothing. This type sends one or the other, never both, so nothing is
///   silently discarded.
/// - **Absent and empty are different statements.** Omitting both keys means
///   *"I am saying nothing about the signature"* and leaves the stored value
///   alone; an explicitly empty `htmlSignature` means *"this address signs with
///   nothing"*, which on an account that has a signature is not the same as
///   inheriting it. Swift's synthesised encoding drops `nil` optionals, which
///   would make "clear this signature" indistinguishable from "leave it", so
///   ``IdentityPatch`` encodes by hand.
public struct IdentitySet: JMAPMethod {
    public static let name = "Identity/set"
    public static let capability = Capability.submission

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        /// Keyed by identity id. A `nil` name clears it back to the account's
        /// own; the server writes an empty string, which `Identity/get` then
        /// reports as the account name.
        public var update: [IdentityID: IdentityPatch]
        public var ifInState: StateToken?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case update, ifInState
        }
    }

    /// A patch carrying only the keys the caller actually means to change.
    ///
    /// Every field is a *double* optional in effect: `nil` means the key is not
    /// written at all, and `.some(value)` means it is written with that value —
    /// including `.some("")`, which is the statement *"sign with nothing"*. A
    /// plain `String?` with synthesised encoding could not express both, and the
    /// one it would drop is the destructive one, so clearing a signature would
    /// look like it worked and change nothing.
    public struct IdentityPatch: Encodable, Sendable, Hashable {
        /// The display name recipients see. Empty clears it back to the
        /// account's own name, which is what the server stores for it.
        public var name: String?
        /// The signature as HTML. Sanitised server-side on arrival — this is
        /// the least trusted way a signature can be written, so nothing about
        /// the markup sent here survives unexamined.
        public var htmlSignature: String?
        /// A plain-text signature, escaped into HTML by the server rather than
        /// parsed: a signature containing `<b>` is a signature containing those
        /// five characters. **Ignored entirely when `htmlSignature` is also
        /// set**, which is why the two helpers below never set both.
        public var textSignature: String?

        public init(
            name: String? = nil, htmlSignature: String? = nil, textSignature: String? = nil
        ) {
            self.name = name
            self.htmlSignature = htmlSignature
            self.textSignature = textSignature
        }

        private enum CodingKeys: String, CodingKey {
            case name, htmlSignature, textSignature
        }

        /// Written out rather than synthesised, so that "absent" is a decision
        /// this type makes and not a side effect of how `Encodable` treats nil.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            if let name { try container.encode(name, forKey: .name) }
            if let htmlSignature {
                try container.encode(htmlSignature, forKey: .htmlSignature)
            } else if let textSignature {
                try container.encode(textSignature, forKey: .textSignature)
            }
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var oldState: StateToken?
        public var newState: StateToken?
        public var updated: [IdentityID: JSONValue]?
        public var notUpdated: [IdentityID: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case oldState, newState, updated, notUpdated
        }
    }

    public var arguments: Arguments

    public init(
        accountID: AccountID, update: [IdentityID: IdentityPatch], ifInState: StateToken? = nil
    ) {
        arguments = Arguments(accountID: accountID, update: update, ifInState: ifInState)
    }

    /// Renames one identity, saying nothing about its signature.
    ///
    /// Nothing about the signature is the point: a rename that also sent an
    /// empty `htmlSignature` would wipe a signature the user never touched.
    public static func rename(
        _ id: IdentityID, to name: String, accountID: AccountID
    ) -> IdentitySet {
        IdentitySet(accountID: accountID, update: [id: IdentityPatch(name: name)])
    }

    /// Stores an HTML signature for one identity.
    ///
    /// Pass an empty string to say *"this address signs with nothing"*. That is
    /// a stored statement, not a no-op: on an account that has its own
    /// signature it is the only way to stop this alias inheriting it.
    public static func setHTMLSignature(
        _ html: String, for id: IdentityID, accountID: AccountID
    ) -> IdentitySet {
        IdentitySet(accountID: accountID, update: [id: IdentityPatch(htmlSignature: html)])
    }
}
