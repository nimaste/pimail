import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// Not asking the server for what it has already told us.
///
/// One bulk label edit in the browser produces dozens of `StateChange` events
/// carrying the same token. Pulling for each of them costs an `Email/changes`
/// round trip apiece against a server that is often a Raspberry Pi with a
/// single PHP worker pool — the aggressive polling the server guide explicitly
/// tells clients not to do.
@Suite("Live stream suppression")
struct SyncSuppressionTests {
    private func change(_ tokens: [String: String]) throws -> StateChange {
        let json = try JSONSerialization.data(
            withJSONObject: [
                "@type": "StateChange",
                "changed": tokens.mapValues { ["Email": $0] },
            ])

        return try JSONDecoder().decode(StateChange.self, from: json)
    }

    private func account(_ id: String, emailState: String?) -> AccountSnapshot {
        AccountSnapshot(
            accountKey: "srv/\(id)",
            accountID: AccountID(id),
            name: "Account \(id)",
            emailState: emailState.map { StateToken(rawValue: $0) }
        )
    }

    @Test("an account whose token has not moved is not pulled")
    func skipsUnchanged() throws {
        let accounts = [account("1", emailState: "42"), account("2", emailState: "7")]

        let moved = MailSyncService.accountsThatMoved(
            try change(["1": "42", "2": "9"]), accounts: accounts)

        #expect(moved.map(\.accountKey) == ["srv/2"])
    }

    /// Missing mail is a far worse failure than one extra request, so an
    /// account the event does not mention at all is pulled anyway.
    @Test("an account the event does not mention is pulled anyway")
    func unmentionedIsPulled() throws {
        let accounts = [account("1", emailState: "42"), account("2", emailState: "7")]

        let moved = MailSyncService.accountsThatMoved(
            try change(["1": "42"]), accounts: accounts)

        #expect(moved.map(\.accountKey) == ["srv/2"])
    }

    /// A fresh account holds no token at all, and every token differs from
    /// nothing — so its first event is always worth answering.
    @Test("an account that has never synced is always pulled")
    func freshAccountIsPulled() throws {
        let moved = MailSyncService.accountsThatMoved(
            try change(["1": "42"]), accounts: [account("1", emailState: nil)])

        #expect(moved.map(\.accountKey) == ["srv/1"])
    }

    /// One place turns an error into a drain outcome, so the `Email/set` and
    /// `Thread/set` paths cannot come to disagree about what a refusal is.
    @Test("a drain outcome follows the same rule as the queue")
    func drainOutcomeMatchesClassification() {
        #expect(
            MailSyncService.attempt(
                after: JMAPError.unreachable(host: "nas.local", code: .cannotConnectToHost))
                == .unreachable)

        let refusal = MailSyncService.attempt(
            after: JMAPError.methodFailed(
                .accountReadOnly, description: nil, callID: CallID(rawValue: "c0")))

        guard case .refused = refusal else {
            Issue.record("A read-only account is a refusal, not something to replay.")
            return
        }
    }
}
