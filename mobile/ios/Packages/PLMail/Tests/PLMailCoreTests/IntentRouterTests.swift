import Testing

@testable import PLMailCore

/// The one indirection between the system and the view tree.
///
/// Everything that arrives from outside the app holding ids — a notification
/// tap, a Spotlight result, a Handoff continuation, Siri — goes through here,
/// so the guarantees worth pinning are that a request survives until something
/// takes it and that taking it clears it. A request that were left behind
/// would re-open the same conversation every time the shell redrew.
@Suite("Intent router")
@MainActor
struct IntentRouterTests {
    @Test("a thread request carries both ids to whoever takes it")
    func threadRequestRoundTrips() {
        let router = IntentRouter.shared

        router.request(.thread(accountKey: "nas.local/karat", threadID: "T42"))

        #expect(router.take() == .thread(accountKey: "nas.local/karat", threadID: "T42"))
    }

    /// The failure this prevents: a tap that opened the conversation, then
    /// opened it again on the next redraw, and went on doing so for as long as
    /// the app was running.
    @Test("taking a request clears it")
    func takingClears() {
        let router = IntentRouter.shared

        router.request(.thread(accountKey: "a", threadID: "b"))

        _ = router.take()

        #expect(router.take() == nil)
    }

    /// Not a queue, deliberately. Two things asking at once means the second
    /// is what the person most recently did.
    @Test("a second request replaces the first rather than queueing behind it")
    func lastRequestWins() {
        let router = IntentRouter.shared

        router.request(.thread(accountKey: "a", threadID: "b"))
        router.request(.search("invoice"))

        #expect(router.take() == .search("invoice"))
        #expect(router.take() == nil)
    }
}
