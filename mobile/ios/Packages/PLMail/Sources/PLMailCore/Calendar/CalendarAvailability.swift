import Foundation
public import JMAPKit

/// Whether this install has a calendar at all — **a two-source boolean**, and
/// either source alone is wrong.
///
/// The **session** is the authority: an instance publishing no calendars
/// capability has no calendar and must not be offered one. But asking it needs
/// the network, so a cold launch on a train would hide a calendar the device is
/// holding a month of.
///
/// The **cache** answers that case and cannot answer the first: it is empty
/// before the first refresh, so a screen that could only appear after being
/// opened could never be opened.
///
/// `false` comes **first**, deliberately. A probe that has to time out must not
/// hold the answer, because what is waiting on it is a navigation row that is
/// either there or not.
@MainActor
@Observable
public final class CalendarAvailability {
    /// Starts false and stays false until something says otherwise. Never
    /// optional: a tri-state here would push "we do not know yet" into every
    /// call site, and the honest rendering of "we do not know yet" is exactly
    /// the same as "no".
    public private(set) var isAvailable = false

    /// What the Session said, for diagnostics. Nil until a session was read.
    public private(set) var sessionPublishesCalendars: Bool?

    /// The account calendar methods are addressed to, once known.
    public private(set) var accountID: AccountID?

    /// The server's own horizon strings. **Opaque PHP relative-date
    /// expressions** — quote them in diagnostics, never parse them.
    public private(set) var horizon: SessionAccount.MaterialisedHorizon?

    /// The `CalendarEvent/get` ceiling this account advertises, which is
    /// **not** core's `maxObjectsInGet`. A pager reading the wrong one fails on
    /// its first full page.
    public private(set) var maxEventsInGet = CalendarEventGet.maxEventsInGet

    private let store: CalendarStore

    public init(store: CalendarStore) {
        self.store = store
    }

    /// Re-probes **on a change in the world, never on a timer**.
    ///
    /// The bug this shape exists to prevent, dated in Android's source
    /// (2026-08-06): the probe ran once, before pairing had stored a
    /// credential, so it answered false with nothing to ask — and nothing ever
    /// asked again, so the Calendar row appeared only after the process was
    /// killed. Call this when the stored connection changes and when the
    /// account rows change, and at no other time; a probe per push timestamp is
    /// polling with extra steps.
    public func refresh(session: Session?) async {
        if let session {
            sessionPublishesCalendars = session.capabilities.calendars != nil
            accountID = session.calendarAccountID

            if let accountID,
                let capabilities = session.accounts[accountID]?.accountCapabilities.calendars
            {
                horizon = capabilities.materialisedHorizon
                maxEventsInGet = capabilities.maxEventsInGet ?? CalendarEventGet.maxEventsInGet
            }
        }

        let cached = (try? await store.calendarCount()) ?? 0

        // The session is the authority when it has spoken, and a cached
        // calendar answers for it when it has not. Both are ORed rather than
        // one overriding the other, because an unreachable server must not
        // remove a calendar the device is holding.
        isAvailable = cached > 0 || accountID != nil
    }

    /// Forgets what a session said, without touching the cache.
    ///
    /// Used on sign-out of one server before another is connected: the account
    /// id belonged to that credential, and holding it would address the next
    /// server's methods to an account it has never heard of.
    public func forgetSession() {
        sessionPublishesCalendars = nil
        accountID = nil
        horizon = nil
    }
}
