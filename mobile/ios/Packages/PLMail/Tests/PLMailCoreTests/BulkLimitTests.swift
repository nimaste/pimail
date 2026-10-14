import Foundation
import Testing

@testable import PLMailCore

/// What one bulk action cannot reach.
///
/// `Core/capabilities.maxObjectsInSet` is 500 on plMail, so "mark all as read"
/// on a mailbox with more unread than that marks 500 of them. That is a fine
/// thing to do and a terrible thing to do *quietly*: the user is left believing
/// a mailbox is clear because the app told them it did what they asked.
@Suite("Bulk limit")
struct BulkLimitTests {
    @Test("everything fitting leaves nothing behind")
    func nothingRemaining() {
        #expect(MailSyncService.remainingBeyondLimit(total: 12, fetched: 12) == 0)
        #expect(MailSyncService.remainingBeyondLimit(total: 0, fetched: 0) == 0)
    }

    @Test("the overflow past the limit is counted")
    func remainderIsCounted() {
        #expect(
            MailSyncService.remainingBeyondLimit(
                total: 600, fetched: MailSyncService.bulkLimit) == 100)
    }

    /// The number the user is shown has to be the number still unread, not the
    /// number the mailbox held — "600 messages are still unread" immediately
    /// after marking 500 of them read is worse than saying nothing.
    @Test("the count is what remains, not the total")
    func countIsTheRemainder() {
        #expect(MailSyncService.remainingBeyondLimit(total: 501, fetched: 500) == 1)
    }

    /// `Mailbox/query` returns `total` only when asked, and a server is free
    /// not to answer. Inventing leftovers then would send the user pressing a
    /// button that does nothing at all.
    @Test("a server that will not count is not guessed at")
    func unknownTotalClaimsNothing() {
        #expect(MailSyncService.remainingBeyondLimit(total: nil, fetched: 500) == 0)
    }

    /// A total *below* what came back is nonsense, but a negative remainder
    /// would render as "-3 messages are still unread".
    @Test("an impossible total never produces a negative count")
    func neverNegative() {
        #expect(MailSyncService.remainingBeyondLimit(total: 3, fetched: 10) == 0)
    }
}
