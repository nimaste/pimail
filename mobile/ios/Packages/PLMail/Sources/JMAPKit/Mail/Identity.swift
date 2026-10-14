/// An RFC 8621 `Identity` — a sendable address for one account.
///
/// Comes from the same list the web composer's From dropdown shows: the
/// account's sendable aliases, primary first. An account with no alias rows
/// yields one synthetic identity for the account address itself, so the list
/// is never empty.
public struct Identity: Hashable, Sendable, Codable {
    public var id: IdentityID
    public var name: String?
    public var email: String?
    public var replyTo: [EmailAddress]?
    public var bcc: [EmailAddress]?
    public var textSignature: String?
    public var htmlSignature: String?
    public var mayDelete: Bool?

    public init(id: IdentityID) {
        self.id = id
    }
}
