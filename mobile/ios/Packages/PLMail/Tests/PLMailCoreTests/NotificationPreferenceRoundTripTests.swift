import Foundation
import Testing

@testable import PLMailCore

/// The tri-state, through the layer that actually loses it.
///
/// `NotificationPolicy`'s own rules are tested elsewhere. What is tested here
/// is the round trip: a preference is written by a settings screen and read by
/// a background refresh in a different process lifetime, and every way of
/// collapsing `on` / `off` / `unset` into a `Bool` survives that trip looking
/// perfectly fine until the month a label is created on the web.
@Suite("Notification preference round trip")
@MainActor
struct NotificationPreferenceRoundTripTests {
    /// A private suite name per test, so two tests never share a store and a
    /// failure is never a leftover from the last run.
    private func defaults(_ name: String = UUID().uuidString) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "de.plmail.tests.\(name)"))
    }

    private func reread(_ defaults: UserDefaults) -> NotificationPreferences {
        NotificationPreferences(defaults: defaults)
    }

    /// The case the whole shape exists for. A label nobody has opened the
    /// screen about must come back as `unset` and follow its own default, not
    /// as `off` — which is what a single `Bool` would have stored.
    @Test("Never said stays never said across a relaunch")
    func unsetSurvivesARelaunch() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setEnabled(true, scopeKey: "label:Inbox")

        let reloaded = reread(defaults)

        #expect(reloaded.choice(forScope: "label:Inbox") == .on)
        #expect(reloaded.choice(forScope: "label:Newsletters") == .unset)
    }

    /// "Off, and I mean it" is a different fact from "not mentioned", and the
    /// difference has to be on disk rather than inferred.
    @Test("An explicit off survives a relaunch as an off, not as an absence")
    func explicitOffSurvives() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setEnabled(false, scopeKey: "label:Inbox")

        #expect(reread(defaults).choice(forScope: "label:Inbox") == .off)
    }

    /// A scope switched on and then off must not end up in both sets, where the
    /// order of the checks — not the user — would decide the answer.
    @Test("Changing an answer replaces it rather than adding to it")
    func answersDoNotAccumulate() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setEnabled(true, scopeKey: "label:Receipts")
        preferences.setEnabled(false, scopeKey: "label:Receipts")

        let reloaded = reread(defaults)

        #expect(reloaded.policy.enabledScopes.contains("label:Receipts") == false)
        #expect(reloaded.policy.disabledScopes.contains("label:Receipts"))
        #expect(reloaded.choice(forScope: "label:Receipts") == .off)
    }

    /// The route back to "never said", which a plain toggle cannot express and
    /// which the settings screen offers as an explicit action.
    @Test("Clearing a choice puts a scope back to the default")
    func clearingReturnsToUnset() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setEnabled(false, scopeKey: "label:Inbox")
        preferences.clearChoice(forScope: "label:Inbox")

        #expect(reread(defaults).choice(forScope: "label:Inbox") == .unset)
    }

    /// The account store's asymmetry, which is the opposite of the scope
    /// store's and equally deliberate.
    @Test("A brand-new account speaks; a muted one stays silent across a relaunch")
    func mutingIsStoredAsMutedNotAsAllowed() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setMuted(true, accountKey: "srv/work")

        let reloaded = reread(defaults)

        #expect(reloaded.isMuted(accountKey: "srv/work"))
        // An account nobody has ever said anything about — a mailbox connected
        // on the server this morning. Silence here would read as breakage.
        #expect(reloaded.isMuted(accountKey: "srv/personal") == false)
    }

    @Test("Unmuting removes the account rather than adding an allowance")
    func unmutingClearsTheEntry() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setMuted(true, accountKey: "srv/work")
        preferences.setMuted(false, accountKey: "srv/work")

        #expect(reread(defaults).policy.mutedAccounts.isEmpty)
    }

    /// The resolution the settings toggles and the notifier both go through,
    /// asserted end to end so the screen and the banner cannot disagree.
    @Test("A muted account silences a scope the user switched on")
    func muteBeatsAnEnabledScope() throws {
        let defaults = try defaults()
        let preferences = NotificationPreferences(defaults: defaults)

        preferences.setEnabled(true, scopeKey: "label:Newsletters")
        preferences.setMuted(true, accountKey: "srv/work")

        let scope = NotifyScope(
            key: "label:Newsletters", title: "Newsletters", isNotifiableByDefault: false)

        #expect(
            reread(defaults).policy.allows(accountKey: "srv/work", scopes: [scope]) == false)
        #expect(reread(defaults).policy.allows(accountKey: "srv/personal", scopes: [scope]))
    }

    /// A value written by a later version of the app is not worth a crash, and
    /// the fallback direction is the safe one: the user hears about their
    /// inbox and can mute it again.
    @Test("An unreadable stored value falls back to nothing said")
    func unreadableValueFallsBack() throws {
        let defaults = try defaults()
        defaults.set(42, forKey: "de.plmail.notify.enabledScopes")

        #expect(reread(defaults).choice(forScope: "label:Inbox") == .unset)
    }
}
