import Foundation
import JMAPKit

/// Turning words typed on a lock screen into a message the outbox can send.
///
/// **Through the outbox, never straight to the server.** The whole reason
/// inline reply is safe to offer here is that `Outbox.enqueue` writes to
/// Application Support before anything is attempted: the words survive a
/// failed request, a dropped connection, and the app being killed. A reply
/// that posted directly would lose them at exactly the moment someone is least
/// able to retype them — phone in one hand, screen locked, walking.
///
/// In `PLMailCore` rather than in `App/` so it can reuse ``ReplyDrafting``'s
/// own subject and threading rules, and so it can build an
/// ``Outbox/PendingMessage`` at all — that type's memberwise initialiser is
/// internal. A second implementation of "Re:" would drift from the composer's,
/// and the drift would show up as a reply that starts a new conversation
/// instead of continuing one, on the recipient's screen where nobody can fix
/// it.
public enum NotificationReply {
    /// A plain-text reply to `original`.
    ///
    /// - Parameters:
    ///   - original: The message being answered. Its `From`, `Message-ID` and
    ///     `References` are the whole of what keeps the conversation together.
    ///   - identity: Which address it goes out as. The account's first
    ///     identity at the call site — a lock-screen reply is not the place to
    ///     make someone choose an alias, and the composer is one tap away for
    ///     when it matters.
    ///   - accountID: The JMAP account the submission belongs to.
    ///   - text: Exactly what was typed. Not quoted and not decorated: the
    ///     notification field has no room to show a quote, so adding one would
    ///     send something the sender never saw.
    /// - Returns: Nil when the original has no reply address. A message with
    ///   no `From` — a bounce from a misconfigured relay — cannot be replied
    ///   to, and queueing a message with no recipients only moves the failure
    ///   to the server.
    public static func pendingMessage(
        replyingTo original: MessageSnapshot,
        identity: IdentitySnapshot,
        accountID: AccountID,
        text: String
    ) -> Outbox.PendingMessage? {
        guard let address = original.fromAddress,
            address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else { return nil }

        // Threading headers, byte for byte what the composer sends. Without
        // them the reply arrives as an unrelated message and the conversation
        // splits in two — in the recipient's client, where nobody can fix it.
        let threading: (inReplyTo: [String]?, references: [String]?) = {
            guard let messageID = original.messageID else { return (nil, nil) }

            return (
                [messageID],
                ReplyDrafting.references(continuing: original.references, with: messageID)
            )
        }()

        return Outbox.PendingMessage(
            accountKey: original.accountKey,
            accountID: accountID,
            identityID: identity.id,
            from: identity.address,
            to: [EmailAddress(name: original.fromName, email: address)],
            subject: ReplyDrafting.replySubject(original.subject),
            body: trimmed,
            // No HTML part. A one-line reply is plain text, and generating a
            // markup version of it would only give two representations to keep
            // in agreement for no visible gain.
            html: nil,
            inReplyTo: threading.inReplyTo,
            references: threading.references)
    }
}
