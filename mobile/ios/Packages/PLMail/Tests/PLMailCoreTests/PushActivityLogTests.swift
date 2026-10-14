import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The log is evidence, so losing an entry is the failure that matters.
///
/// An entry that silently disappears is indistinguishable from the push it was
/// evidence of never having arrived, which is the exact question somebody opens
/// this screen to answer.
@Suite("Push activity log")
struct PushActivityLogTests {
    private func makeLog() -> PushActivityLog {
        PushActivityLog(
            fileURL: URL.temporaryDirectory
                .appending(path: "plmail-tests-\(UUID().uuidString)")
                .appending(path: "push-log.json"))
    }

    /// Built by decoding, which is the only way one ever arrives — and keeps
    /// the test honest about the wire shape rather than about a memberwise
    /// initialiser no server can call.
    private func change(_ accountID: String, _ types: [String]) throws -> StateChange {
        let inner = types.map { "\"\($0)\": \"s1\"" }.joined(separator: ", ")
        let json = Data("{\"changed\": {\"\(accountID)\": {\(inner)}}}".utf8)

        return try JSONDecoder().decode(StateChange.self, from: json)
    }

    @Test("A recorded change keeps the accounts and types and nothing else")
    func recordsAccountsAndTypes() async throws {
        let log = makeLog()

        await log.record(
            try change("1119", ["Email", "Mailbox"]), route: .stream)

        let entries = await log.recent()
        let entry = entries.first

        #expect(entries.count == 1)
        #expect(entry?.route == .stream)
        #expect(entry?.changed["1119"]?.sorted() == ["Email", "Mailbox"])
        // The state tokens are deliberately not kept: opaque, long, and the
        // current ones are already on the diagnostics screen where they can be
        // compared against something.
        #expect(entry?.summary == "1119: Email, Mailbox")
    }

    /// Two deliveries a moment apart both reading the same array is how one
    /// entry silently disappears. Serialising the read-modify-write inside the
    /// actor is the whole defence, and this is what would catch its removal.
    @Test("Concurrent deliveries all survive")
    func concurrentRecordsAreNotLost() async throws {
        let log = makeLog()

        // Built up front so the concurrent part is only the recording, which is
        // the thing under test.
        let changes = try (0..<40).map { try change("\($0)", ["Email"]) }

        await withTaskGroup(of: Void.self) { group in
            for change in changes {
                group.addTask { await log.record(change, route: .stream) }
            }
        }

        #expect(await log.recent().count == 40)
    }

    @Test("The log is bounded and keeps the newest")
    func oldEntriesAreDropped() async {
        let log = makeLog()
        let start = Date(timeIntervalSince1970: 0)

        for index in 0..<(PushActivityLog.capacity + 10) {
            await log.append(
                PushLogEntry(
                    receivedAt: start.addingTimeInterval(TimeInterval(index)),
                    route: .stream, changed: ["a": ["Email"]]))
        }

        let entries = await log.recent()

        #expect(entries.count == PushActivityLog.capacity)
        #expect(
            entries.first?.receivedAt
                == start.addingTimeInterval(TimeInterval(PushActivityLog.capacity + 9)))
    }

    /// The way anyone actually tests push: clear, send yourself a message,
    /// expect exactly one line.
    @Test("Clearing empties it, and it stays empty when read back from disk")
    func clearingPersists() async throws {
        let url = URL.temporaryDirectory
            .appending(path: "plmail-tests-\(UUID().uuidString)")
            .appending(path: "push-log.json")
        let log = PushActivityLog(fileURL: url)

        await log.record(try change("1119", ["Email"]), route: .stream)
        await log.clear()

        #expect(await log.recent().isEmpty)
        #expect(await PushActivityLog(fileURL: url).recent().isEmpty)
    }

    @Test("Entries written by one instance are read by the next")
    func entriesPersistAcrossInstances() async throws {
        let url = URL.temporaryDirectory
            .appending(path: "plmail-tests-\(UUID().uuidString)")
            .appending(path: "push-log.json")

        await PushActivityLog(fileURL: url)
            .record(try change("1119", ["Email"]), route: .stream)

        #expect(await PushActivityLog(fileURL: url).recent().count == 1)
    }

    /// Diagnostics must not be the thing that fails. A corrupt file becomes an
    /// empty log rather than a screen that cannot open.
    @Test("An unreadable file reads as an empty log")
    func corruptFileIsEmpty() async throws {
        let url = URL.temporaryDirectory
            .appending(path: "plmail-tests-\(UUID().uuidString)")
            .appending(path: "push-log.json")

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        #expect(await PushActivityLog(fileURL: url).recent().isEmpty)
    }
}
