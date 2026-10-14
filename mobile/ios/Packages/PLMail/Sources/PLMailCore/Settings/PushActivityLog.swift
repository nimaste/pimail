import Foundation
import JMAPKit
import OSLog
import Observation

/// One state change this device was actually told about, and how.
///
/// **No mail content, ever.** JMAP pushes none, which makes this easy to hold
/// to, but the reason is stronger than the protocol: a subject line here would
/// be a copy of somebody's mail sitting in a diagnostics list for the next two
/// hundred messages, on a screen whose whole purpose is to be read out to
/// somebody else.
public struct PushLogEntry: Hashable, Sendable, Identifiable, Codable {
    /// How the news arrived.
    ///
    /// The distinction is the point of the log. Someone watching mail appear
    /// instantly while the app is open and never while it is closed is looking
    /// at a stream doing the work of a subscription that was never verified,
    /// and every other screen in the app draws those two situations
    /// identically.
    public enum Route: String, Hashable, Sendable, Codable {
        /// The EventSource connection, held only while the app is in front.
        case stream
        /// A remote notification from Apple. Nothing produces this today — the
        /// server has no APNs key — and the case exists so that when one
        /// arrives the log distinguishes it rather than being rewritten under
        /// somebody who is mid-diagnosis.
        case apns
    }

    public var id: UUID
    public var receivedAt: Date
    public var route: Route

    /// The `changed` map, flattened to `accountId: Type, Type` and sorted, so
    /// two entries a second apart can be compared by eye. Sorted rather than
    /// dictionary-ordered because an unordered rendering of the same event
    /// looks like two different events.
    public var changed: [String: [String]]

    public init(
        id: UUID = UUID(), receivedAt: Date = .now, route: Route, changed: [String: [String]]
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.route = route
        self.changed = changed
    }

    /// One line: `1119: Email, Mailbox`.
    public var summary: String {
        changed
            .map { "\($0.key): \($0.value.sorted().joined(separator: ", "))" }
            .sorted()
            .joined(separator: "\n")
    }
}

/// A bounded record of push and stream deliveries, kept so that "does push
/// work?" has an answer other than waiting.
///
/// **Deliberately not SwiftData.** `SchemaV1`'s standing rule is that
/// everything in it is reconstructible from the server, which is what licenses
/// deleting the whole store on any open failure. This is the exact opposite: a
/// record of events the server cannot replay. A schema bump for an unrelated
/// column would erase the evidence somebody had spent a week collecting, which
/// is why it lives in its own file under Application Support instead.
///
/// One shared instance, and an `actor` rather than a lock, because the writer
/// is whatever task a delivery arrives on and the reader is a settings screen.
/// The read-modify-write **must** be serialised: two deliveries a moment apart
/// otherwise both read the same array and one entry silently disappears — which
/// is indistinguishable from the push that entry was evidence of never having
/// arrived.
public actor PushActivityLog {
    /// One instance, for the same reason `AppearancePreference` has one: it is
    /// written from the sync engine and read from a settings screen several
    /// levels apart, and a second instance would be a second file that
    /// disagrees with the first about what arrived.
    public static let shared = PushActivityLog()

    /// Old entries are dropped rather than the file being allowed to grow.
    ///
    /// Two hundred is roughly a busy day, which is the window anyone
    /// diagnosing this actually looks at, and it bounds a file that is written
    /// on every delivery on a device that may be syncing all day.
    public static let capacity = 200

    private let fileURL: URL
    private let logger = Logger(subsystem: "de.plmail", category: "pushlog")
    private var entries: [PushLogEntry]?

    public init(fileURL: URL? = nil) {
        self.fileURL =
            fileURL
            ?? URL.applicationSupportDirectory
            .appending(path: "plmail-diagnostics", directoryHint: .isDirectory)
            .appending(path: "push-log.json")
    }

    /// Newest first, which is the order the question is asked in.
    public func recent(limit: Int = capacity) -> [PushLogEntry] {
        Array(loaded().sorted { $0.receivedAt > $1.receivedAt }.prefix(limit))
    }

    /// Records one delivery.
    ///
    /// - Parameters:
    ///   - change: The `StateChange` as it arrived. Only the account ids and
    ///     the object type names are kept; the new state tokens are dropped
    ///     because they are opaque, long, and already on the diagnostics
    ///     screen for the *current* state, which is the one worth comparing.
    ///   - route: Which transport carried it.
    public func record(_ change: StateChange, route: PushLogEntry.Route) {
        var flattened: [String: [String]] = [:]

        for (accountID, types) in change.changed {
            flattened[accountID] = Array(types.keys)
        }

        append(PushLogEntry(route: route, changed: flattened))
    }

    /// Records an already-built entry. Exists for tests and for a caller that
    /// has the shape but not a `StateChange`.
    public func append(_ entry: PushLogEntry) {
        var all = loaded()
        all.append(entry)

        // Trimmed by receipt time rather than by insertion order: an entry
        // recorded late still belongs where it happened.
        if all.count > Self.capacity {
            all = Array(all.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.capacity))
        }

        entries = all
        persist(all)
    }

    /// Empties the log.
    ///
    /// A log that cannot be reset is a log nobody can use: the way anyone tests
    /// this is to clear it, send themselves a message, and expect exactly one
    /// line.
    public func clear() {
        entries = []
        persist([])
    }

    // MARK: - File

    private func loaded() -> [PushLogEntry] {
        if let entries { return entries }

        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return []
        }

        // An unreadable file becomes an empty log rather than a thrown error.
        // This is diagnostics: failing to open the screen that explains a
        // failure is a worse outcome than losing the history.
        let decoded = (try? JSONDecoder().decode([PushLogEntry].self, from: data)) ?? []
        entries = decoded

        return decoded
    }

    private func persist(_ all: [PushLogEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        } catch {
            // Logged and swallowed. A diagnostics record that cannot be written
            // must not take down the delivery it was recording.
            logger.error("Push log write failed: \(error, privacy: .public)")
        }
    }
}
