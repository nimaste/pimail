import Foundation

/// Decides which messages have actually been *read*, as opposed to loaded.
///
/// Marking a whole conversation read the moment it opens clears the unread
/// state of messages nobody looked at: open a forty-message thread to see the
/// newest reply and thirty-nine older ones silently go read, in this client and
/// on every other device the account is signed in to. That is unrecoverable
/// from the user's side — they cannot tell which of the thirty-nine they had
/// already seen.
///
/// The rule this type encodes is the server guide's own: a message counts as
/// read when it is **expanded and on screen**, never on prefetch and never
/// because it scrolled past folded shut. Collapsed messages, and messages
/// inside ``ThreadReaderView``'s folded middle, are explicitly not read.
public struct ReadReceipts: Sendable, Equatable {
    /// Messages already handed to a caller.
    ///
    /// Without this, every scroll that re-fires a visibility callback would
    /// issue another `Email/set` for mail already marked read — a write per
    /// frame against somebody's home server.
    private var reported: Set<String> = []

    public init() {}

    /// The messages that have just become read, and are therefore owed a write.
    ///
    /// - Parameters:
    ///   - messages: The conversation, as the loader currently has it.
    ///   - expanded: Message ``MessageSnapshot/id``s the reader has open.
    ///   - visible: Message ids the scroll view reports as on screen. A message
    ///     expanded far below the fold has not been read yet, and the user may
    ///     well back out before it ever is.
    /// - Returns: The `emailID`s to mark read, in conversation order. Empty
    ///   when nothing new qualifies, which is the common case — callers rely on
    ///   that to skip the round trip entirely.
    public mutating func claim(
        messages: [MessageSnapshot],
        expanded: Set<String>,
        visible: Set<String>
    ) -> [String] {
        var claimed: [String] = []

        for message in messages
        where message.isSeen == false
            && reported.contains(message.id) == false
            && expanded.contains(message.id)
            && visible.contains(message.id)
        {
            reported.insert(message.id)
            claimed.append(message.emailID)
        }

        return claimed
    }

    /// Whether this message has already been claimed.
    ///
    /// Exposed so a caller can answer "did we do this?" without claiming it as
    /// a side effect — a query that mutates is how a test ends up asserting the
    /// behaviour it caused.
    public func hasClaimed(_ messageID: String) -> Bool { reported.contains(messageID) }
}
