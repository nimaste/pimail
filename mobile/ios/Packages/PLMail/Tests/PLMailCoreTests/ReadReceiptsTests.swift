import Foundation
import Testing

@testable import PLMailCore

/// The restraint is the feature. Marking a whole conversation read on open is
/// easy and wrong: it clears the unread state of messages the user never saw,
/// on every device the account is signed in to, with no way to work out
/// afterwards which ones they were.
@Suite("Read receipts")
struct ReadReceiptsTests {
    private func message(_ id: String, isSeen: Bool = false) -> MessageSnapshot {
        MessageSnapshot(
            emailID: "e-\(id)",
            accountKey: "acct",
            blobID: "b-\(id)",
            subject: "Roof repair quote",
            fromName: "Dana Whitfield",
            fromAddress: "dana@example.com",
            to: [],
            cc: [],
            receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
            messageID: nil,
            references: [],
            preview: "",
            isSeen: isSeen,
            isFlagged: false,
            isDraft: false,
            htmlBody: nil,
            textBody: "Hello",
            hasBody: true,
            attachments: [],
            inlineParts: []
        )
    }

    private var thread: [MessageSnapshot] {
        (1...4).map { message("m\($0)") }
    }

    @Test("a message that is on screen but collapsed is not marked read")
    func collapsedIsNotRead() {
        var receipts = ReadReceipts()

        let claimed = receipts.claim(
            messages: thread,
            expanded: [],
            visible: ["acct#e-m1", "acct#e-m2", "acct#e-m3", "acct#e-m4"]
        )

        #expect(claimed.isEmpty)
    }

    @Test("a message that is expanded but off screen is not marked read")
    func offScreenIsNotRead() {
        var receipts = ReadReceipts()

        let claimed = receipts.claim(
            messages: thread, expanded: ["acct#e-m3"], visible: [])

        #expect(claimed.isEmpty)
    }

    @Test("only the expanded, visible message is marked read, not its thread")
    func onlyTheDisplayedOne() {
        var receipts = ReadReceipts()

        let claimed = receipts.claim(
            messages: thread,
            expanded: ["acct#e-m4"],
            visible: ["acct#e-m3", "acct#e-m4"]
        )

        #expect(claimed == ["e-m4"])
    }

    @Test("scrolling past the same message again does not write it read twice")
    func claimedOnlyOnce() {
        var receipts = ReadReceipts()
        let expanded: Set<String> = ["acct#e-m1"]
        let visible: Set<String> = ["acct#e-m1"]

        let first = receipts.claim(messages: thread, expanded: expanded, visible: visible)
        let second = receipts.claim(messages: thread, expanded: expanded, visible: visible)

        #expect(first == ["e-m1"])
        #expect(second.isEmpty)
        #expect(receipts.hasClaimed("acct#e-m1"))
    }

    @Test("a message that was already read is never claimed again")
    func alreadySeenIsSkipped() {
        var receipts = ReadReceipts()
        let messages = [message("m1", isSeen: true), message("m2")]

        let claimed = receipts.claim(
            messages: messages,
            expanded: ["acct#e-m1", "acct#e-m2"],
            visible: ["acct#e-m1", "acct#e-m2"]
        )

        #expect(claimed == ["e-m2"])
    }

    @Test("expanding a second message later claims only the new one")
    func incrementalExpansion() {
        var receipts = ReadReceipts()

        _ = receipts.claim(
            messages: thread, expanded: ["acct#e-m4"], visible: ["acct#e-m3", "acct#e-m4"])

        let claimed = receipts.claim(
            messages: thread,
            expanded: ["acct#e-m4", "acct#e-m3"],
            visible: ["acct#e-m3", "acct#e-m4"]
        )

        #expect(claimed == ["e-m3"])
    }
}
