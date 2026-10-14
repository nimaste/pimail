import Foundation

/// Which senders may load remote images.
///
/// A decision, not a cache. It records something the user chose that the
/// server does not know and cannot re-derive, so it belongs in `UserDefaults`
/// rather than the SwiftData store — whose standing rule is that everything in
/// it is reconstructible from the server and may be deleted on any migration
/// failure. Losing this on a schema change would silently re-block senders the
/// user had already trusted.
///
/// It was previously view state on the reader, which meant it survived neither
/// a relaunch nor a walk back to the list: allow images, go back, return, and
/// they were blocked again.
///
/// Trust is per sender address rather than per message, because "load images
/// from this newsletter" is the actual intent, and per-message would ask again
/// on every issue.
public struct RemoteContentPolicy {
    private static let key = "de.plmail.remoteImageSenders"

    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` but is
    /// documented as thread-safe, and this type is a thin wrapper over it. The
    /// alternative — an actor — would make reading a sender's trust an `await`
    /// inside a view body, for a lookup that is a dictionary hit.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isAllowed(sender: String?) -> Bool {
        guard let sender = Self.normalise(sender) else { return false }

        return allowed().contains(sender)
    }

    public func allow(sender: String?) {
        guard let sender = Self.normalise(sender) else { return }

        var senders = allowed()
        senders.insert(sender)
        defaults.set(Array(senders).sorted(), forKey: Self.key)
    }

    public func revoke(sender: String?) {
        guard let sender = Self.normalise(sender) else { return }

        var senders = allowed()
        senders.remove(sender)
        defaults.set(Array(senders).sorted(), forKey: Self.key)
    }

    /// Everything trusted, for a settings screen to show and undo.
    public func allowedSenders() -> [String] {
        allowed().sorted()
    }

    public func revokeAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func allowed() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Case-folded, because addresses are compared not displayed here, and a
    /// sender who varies their capitalisation is still the same sender.
    private static func normalise(_ sender: String?) -> String? {
        guard let sender else { return nil }

        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return trimmed.isEmpty ? nil : trimmed
    }
}
