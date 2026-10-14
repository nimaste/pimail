import Foundation
import Testing

@testable import PLMailCore

/// The three offline sentences have to stay three sentences.
///
/// Nothing drew `OfflineState` at all until the list banner did, and the
/// failure it exists to prevent is the easy one: collapsing "you're offline"
/// and "nothing on nas.local answered" into one line. They send the reader to
/// two different places — a router and a server — and only one of them can be
/// retried. These tests fail if the wording is ever merged or the retry rule
/// inverted, which a view reading the cases by hand would not notice.
@Suite("Offline state")
struct OfflineStateTests {
    private typealias State = MailSyncService.OfflineState

    @Test("a healthy sync says nothing at all")
    func currentIsSilent() {
        #expect(State.current.message == nil)
        #expect(State.current.queued == 0)
        #expect(State.current.isRetryable == false)
    }

    /// The one that matters most. A device with no network and a server that is
    /// not answering look identical from the list, and describing the first as
    /// the second sends somebody to restart a NAS that is working.
    @Test("being offline and the server being silent are different sentences")
    func deviceAndServerDiffer() throws {
        let device = try #require(State.deviceOffline(queued: 0).message)
        let server = try #require(State.wholeServer(host: "nas.local", queued: 0).message)

        #expect(device != server)
        // The host is named, because "nothing answered" without saying what was
        // asked is not a fact anybody can act on.
        #expect(server.contains("nas.local"))
        #expect(device.contains("nas.local") == false)
    }

    /// A single failing account keeps the message the sync itself recorded:
    /// that one already names the account's own problem, and rewording it here
    /// would replace a specific failure with a generic one.
    @Test("one failing account keeps the reason the sync recorded")
    func accountKeepsItsMessage() {
        let state = State.account(
            accountKey: "srv/1", message: "Mailbox is no longer connected", queued: 0)

        #expect(state.message == "Mailbox is no longer connected")
    }

    /// A retry while the device has no network can only fail, and a button that
    /// cannot work is worse than no button — it turns a wait into a loop of
    /// pressing something.
    @Test("only the states a retry could fix offer one")
    func retryability() {
        #expect(State.deviceOffline(queued: 3).isRetryable == false)
        #expect(State.wholeServer(host: "nas.local", queued: 3).isRetryable)
        #expect(State.account(accountKey: "srv/1", message: "down", queued: 3).isRetryable)
    }

    /// The count has to survive every case, because the banner reads it from
    /// the state rather than from the service: a case that dropped it would
    /// silently stop saying that changes are still waiting to send.
    @Test("the queued count is carried by every state that has one")
    func queuedIsCarried() {
        #expect(State.deviceOffline(queued: 4).queued == 4)
        #expect(State.wholeServer(host: "nas.local", queued: 4).queued == 4)
        #expect(State.account(accountKey: "srv/1", message: "down", queued: 4).queued == 4)
    }
}
