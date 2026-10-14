/// An RFC 8621 `EmailAddress`.
///
/// Note the property is `email`, not `address`: plMail stores
/// `{name, address}` internally and translates at the JMAP boundary. Getting
/// this wrong yields addresses that decode to nil rather than an error.
public struct EmailAddress: Hashable, Sendable, Codable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }

    /// What to show in a list row or a header: the display name when there is
    /// one, the address otherwise. Never an empty string.
    public var displayName: String {
        guard let name, name.isEmpty == false else { return email }
        return name
    }
}
