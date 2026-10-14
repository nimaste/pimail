#if os(iOS)

public import PLMailCore

import CoreTransferable
import JMAPKit
import UniformTypeIdentifiers

extension UTType {
    /// The drag payload one plMail pane hands another.
    ///
    /// Its own type rather than `.json` or `.plainText`, so a label row cannot
    /// accept an arbitrary file dragged in from Files and then fail to decode
    /// it halfway through applying a label. A drop target that lights up for
    /// things it cannot act on is worse than one that stays dark.
    ///
    /// Declared in code only. Exporting it properly needs a
    /// `UTExportedTypeDeclarations` entry in `App/Info.plist`, which this
    /// package does not own; without it the identifier still works for drags
    /// inside the app, which is every drag this type is used for. Dragging a
    /// conversation *out* of plMail falls back to the plain-text
    /// representation below.
    public static let plMailThreads = UTType(exportedAs: "de.plmail.threads")
}

/// Conversations being dragged, as ids.
///
/// Ids and nothing else. A drag payload can outlive the row that started it —
/// the finger is still down while a sync deletes the thread — so carrying a
/// `StoredThread` would be carrying a `@Model` object across an actor boundary
/// and into a future where it may no longer exist. Ids re-resolve, or they
/// resolve to nothing and the drop is a no-op, which is the correct outcome.
///
/// `emailIDs` travels with the payload rather than being looked up on drop for
/// the same reason `ThreadRef` carries a subject: the alternative is an async
/// store read inside a drop handler that has to answer synchronously whether
/// it accepted.
public struct ThreadTransfer: Codable, Hashable, Sendable, Transferable {
    /// One conversation.
    public struct Item: Codable, Hashable, Sendable {
        public var accountKey: String
        public var threadID: String
        public var subject: String
        /// Every message in the thread. Actions are thread-wide — archiving one
        /// reply and leaving the rest is not something anyone means from a
        /// list of conversations.
        public var emailIDs: [String]

        public init(accountKey: String, threadID: String, subject: String, emailIDs: [String]) {
            self.accountKey = accountKey
            self.threadID = threadID
            self.subject = subject
            self.emailIDs = emailIDs
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// What a drag out of the app leaves behind.
    ///
    /// Subjects, not a serialised payload: another app has no use for plMail's
    /// ids, and dropping a wall of JSON into a note is a worse outcome than
    /// dropping the one line that says what the mail was.
    public var plainTextSummary: String {
        items.map(\.subject).joined(separator: "\n")
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plMailThreads)

        ProxyRepresentation(exporting: \.plainTextSummary)
    }
}

extension ThreadTransfer {
    /// The dragged conversations, as things an action can be applied to.
    ///
    /// Accounts are resolved at drop time rather than carried: an account can
    /// be signed out mid-drag, and a target built against an `AccountID` that
    /// no longer exists would send a write to a server this app can no longer
    /// reach. Unresolvable items are dropped silently — the drag is over, and
    /// an alert about a mailbox that has gone is noise.
    public func targets(accounts: [AccountSnapshot]) -> [ActionTarget] {
        items.compactMap { item in
            guard
                let account = accounts.first(where: { $0.accountKey == item.accountKey })
            else { return nil }

            return ActionTarget(
                threadID: item.threadID,
                accountKey: item.accountKey,
                accountID: account.accountID,
                emailIDs: item.emailIDs.map { EmailID(rawValue: $0) })
        }
    }
}

#endif
