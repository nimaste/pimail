#if os(iOS)

public import PLMailCore

import Foundation

/// What a list row pushes.
///
/// A value rather than a model object: navigation state outlives the view
/// that created it, and `@Model` types are not `Sendable` and must not
/// leave the actor that owns their context.
public struct ThreadRef: Hashable, Identifiable, Sendable {
    public var threadID: String
    public var accountKey: String
    public var subject: String

    /// Scoped by account: thread ids are unique only within one.
    public var id: String { "\(accountKey)#\(threadID)" }

    init(thread: StoredThread) {
        threadID = thread.threadID
        accountKey = thread.accountKey
        subject = thread.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
    }
}

#endif
