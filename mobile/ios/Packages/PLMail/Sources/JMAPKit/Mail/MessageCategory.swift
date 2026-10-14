/// The classifier's verdict on a conversation — plMail's answer to Gmail's
/// inbox tabs.
///
/// Read from `Thread.category`, never from `Email.category`: a newsletter
/// somebody replied to has messages in two categories, so a tab drawn from the
/// per-message column would put one conversation under two headings. The
/// resolved conversation value is most-recent-wins and the server computes it.
///
/// **`nil` is not Primary.** A conversation the classifier never saw — mail
/// predating it, a locally-composed draft — matches no tab at all, which is
/// what the web UI does. Folding it into Primary would put mail on the phone's
/// Primary tab that the browser's does not have, and the two would then
/// disagree about the same mailbox.
///
/// The vocabulary is closed server-side: `Email/query`'s `threadCategory`
/// condition refuses a token outside it with `invalidArguments` naming the
/// valid set, so there is no `other(_:)` escape hatch here — an unknown token
/// decodes as `nil`, meaning "no tab", rather than as a filter value that
/// would fail the query.
public enum MessageCategory: String, Hashable, Sendable, Codable, CaseIterable {
    case primary
    case social
    case promotions
    case updates
    case forums

    /// Decodes a stored or wire token, treating an unrecognised one as
    /// unclassified. See the note above on why that is not Primary.
    public init?(wire: String?) {
        guard let wire, let known = MessageCategory(rawValue: wire) else { return nil }

        self = known
    }
}
