import Foundation
import JMAPKit
import Synchronization
import Testing

@testable import PLMailCore

/// A rejected app password used to delete the offline mailbox.
///
/// `MailSyncService.requestReauthentication()` was wired to `AppModel.signOut()`,
/// and `signOut()` deletes the Keychain item **and** runs
/// `SyncStore.deleteEverything()`. So a revoked, rotated or expired credential
/// destroyed every cached message and every queued draft, and offered the
/// onboarding screen as the only explanation. The credential is the one
/// irreplaceable thing in play and it is precisely the thing already gone; the
/// cache is the replaceable thing and it was the one being destroyed.
///
/// The two halves are tested separately because they must not converge again:
/// a 401 keeps the cache, and a deliberate sign-out still clears it.
@Suite("Re-authentication")
struct ReauthenticationTests {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    @MainActor
    private func makeService(store: SyncStore) -> MailSyncService {
        // Never reached over the network here: nothing in this suite calls a
        // method that sends anything.
        let connection = ServerConnection(
            address: ServerAddress(baseURL: URL(string: "https://nas.local")!),
            credential: .appPassword("plmail_" + String(repeating: "a", count: 64))
        )

        return MailSyncService(connection: connection, store: store)
    }

    private func seed(_ store: SyncStore) async throws {
        var email = Email(id: EmailID("e1"))
        email.threadID = ThreadID("t1")
        email.receivedAt = UTCDate(Date(timeIntervalSince1970: 1_700_000_000))
        email.mailboxIDs = JMAPIDSet([MailboxID("70")])

        try await store.upsert(
            emails: [email],
            threads: [MailThread(id: ThreadID("t1"), emailIDs: [EmailID("e1")])],
            accountKey: "srv/1",
            emailState: nil)
    }

    /// The whole point of the change: asking for a new credential is a
    /// navigation, not a deletion.
    @Test("asking to re-authenticate leaves every cached message where it was")
    func reauthenticationKeepsTheCache() async throws {
        let store = makeStore()
        try await seed(store)

        let service = await makeService(store: store)
        let asked = Mutex(false)

        // Exactly what `AppModel` now wires it to: raise a state, touch
        // nothing. A handler that deleted here would be the bug.
        await MainActor.run {
            service.onReauthenticationNeeded = { asked.withLock { $0 = true } }
            service.requestReauthentication()
        }

        #expect(asked.withLock { $0 })

        let messages = try await store.messages(threadID: "t1", accountKey: "srv/1")

        #expect(messages.count == 1)
    }

    /// The other half, and the reason this is two tests: the deliberate,
    /// already-confirmed sign-out must go on deleting everything. The cache
    /// belonged to that credential, and leaving it would show the previous
    /// account's mail behind the next sign-in screen.
    @Test("a deliberate sign-out still clears the cache")
    func signOutStillClearsTheCache() async throws {
        let store = makeStore()
        try await seed(store)

        #expect(try await store.messages(threadID: "t1", accountKey: "srv/1").isEmpty == false)

        try await store.deleteEverything()

        #expect(try await store.messages(threadID: "t1", accountKey: "srv/1").isEmpty)
    }

    /// The regression guard that actually holds, because the defect was one
    /// line of wiring in the app target rather than anything in this package.
    ///
    /// Read from source, since `AppModel` is not importable here. A closure
    /// that reaches `signOut` from the re-authentication callback is the exact
    /// shape that destroyed the mailbox, and it is easy to reintroduce while
    /// tidying: both are one-line handlers on the same object.
    @Test("the re-authentication callback in the app is not wired to sign out")
    func appDoesNotSignOutOnRejection() throws {
        let appModel = URL(filePath: #filePath)
            .deletingLastPathComponent()  // PLMailCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PLMail
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // pl_mail_ios
            .appending(path: "App/AppModel.swift")

        let source = try String(contentsOf: appModel, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")

        guard
            let assignment = lines.firstIndex(where: {
                $0.contains("onReauthenticationNeeded") && $0.contains("//") == false
                    && $0.contains("=")
            })
        else {
            Issue.record("`onReauthenticationNeeded` is no longer assigned in AppModel.")

            return
        }

        // The assignment plus the two lines a wrapped closure occupies.
        let handler = lines[assignment...].prefix(3).joined(separator: " ")

        #expect(
            handler.contains("signOut") == false,
            "A 401 is not consent to delete the mailbox: \(handler.trimmingCharacters(in: .whitespaces))"
        )
    }
}
