/// `SearchSnippet/get` (RFC 8621 §5).
///
/// The part of a message that actually matched. Without it a ranked full-text
/// search looks exactly like a plain filter — every row shows the same opening
/// line, and the reason a message came back is invisible until it is opened.
///
/// The filter is sent again rather than referred to: the spec has no notion of
/// a stored query, so the snippet call has to be told what was searched for.
/// Sending a *different* filter than the query used is the way to get snippets
/// that highlight something the results were not matched on.
public struct SearchSnippetGet: JMAPMethod {
    public static let name = "SearchSnippet/get"
    public static let capability = Capability.mail

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var filter: EmailFilter?
        public var emailIDs: [EmailID]

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case filter
            case emailIDs = "emailIds"
        }
    }

    /// One message's highlights.
    ///
    /// Both strings are nil when that field had no hit, which is the common
    /// case for `subject` — matching in the body is what a snippet is for.
    /// They are **HTML**: escaped content with `<mark>` around each hit, never
    /// to be shown raw.
    public struct Snippet: Decodable, Sendable, Identifiable {
        public var emailID: EmailID
        public var subject: String?
        public var preview: String?

        public var id: EmailID { emailID }

        private enum CodingKeys: String, CodingKey {
            case emailID = "emailId"
            case subject, preview
        }
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        public var list: [Snippet]
        public var notFound: [EmailID]?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case list, notFound
        }
    }

    public var arguments: Arguments

    public init(accountID: AccountID, filter: EmailFilter?, emailIDs: [EmailID]) {
        arguments = Arguments(accountID: accountID, filter: filter, emailIDs: emailIDs)
    }
}
