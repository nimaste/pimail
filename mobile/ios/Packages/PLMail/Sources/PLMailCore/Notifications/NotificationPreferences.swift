import Foundation
import Observation

/// The whole notification preference, frozen into a value.
///
/// Separate from ``NotificationPreferences`` so the decision can be made off
/// the main actor — a background refresh resolves this on whatever thread the
/// sync finished on — and so the resolution rules can be tested without a
/// database, a simulator or `UserDefaults`.
///
/// **The store is deliberately tri-state.** A single "enabled" set cannot tell
/// *"the user switched Inbox off"* from *"the user has never opened this
/// screen"*, and the two must behave differently: the first is silence the
/// user asked for, the second is a brand-new install that has to speak.
public struct NotificationPolicy: Hashable, Sendable {
    /// Accounts the user has silenced. Stored as **muted**, never as
    /// "allowed", so an account added tomorrow — or an account whose key
    /// changed because the server was renamed — speaks by default. An allow
    /// list would make a new mailbox look broken, which is the failure people
    /// report as "notifications stopped working".
    public var mutedAccounts: Set<String>

    /// Scopes the user explicitly switched **on**, overriding a default of
    /// off. This is how a custom label gets a voice.
    public var enabledScopes: Set<String>

    /// Scopes the user explicitly switched **off**. Checked before
    /// ``enabledScopes`` so a message in a muted label stays silent even when
    /// it is also in a label the user turned on.
    public var disabledScopes: Set<String>

    public init(
        mutedAccounts: Set<String> = [],
        enabledScopes: Set<String> = [],
        disabledScopes: Set<String> = []
    ) {
        self.mutedAccounts = mutedAccounts
        self.enabledScopes = enabledScopes
        self.disabledScopes = disabledScopes
    }

    /// What the user has said about one scope, if anything.
    public enum Choice: Hashable, Sendable {
        case on
        case off
        /// Never said. The case that exists so a label created on the web next
        /// month does not inherit a decision nobody made about it.
        case unset
    }

    public func choice(forScope key: String) -> Choice {
        if disabledScopes.contains(key) { return .off }
        if enabledScopes.contains(key) { return .on }

        return .unset
    }

    /// Whether a message in these scopes, on this account, may be announced.
    ///
    /// Order matters and is the whole rule:
    ///
    /// 1. A muted account is silent, whatever its labels say. It is the
    ///    coarsest switch and the one the user reaches for first.
    /// 2. A message in **no** scope is silent. That is not an oversight — it
    ///    is how ``NotifyScopes/neverNotifiableRoles`` vetoes the sender's own
    ///    copy of a message they just sent.
    /// 3. An explicit *off* on any scope wins. Muting a label has to work even
    ///    when the message is also in Inbox, or muting it achieves nothing.
    /// 4. Then an explicit *on*.
    /// 5. Then the default, which is on only for Inbox.
    public func allows(accountKey: String, scopes: [NotifyScope]) -> Bool {
        guard mutedAccounts.contains(accountKey) == false else { return false }
        guard scopes.isEmpty == false else { return false }

        if scopes.contains(where: { disabledScopes.contains($0.key) }) { return false }
        if scopes.contains(where: { enabledScopes.contains($0.key) }) { return true }

        return scopes.contains(where: \.isNotifiableByDefault)
    }
}

/// Where the notification preference is kept.
///
/// `UserDefaults` rather than the store: `SchemaV1`'s standing rule is that
/// everything in it is reconstructible from the server and may be deleted on
/// any open failure, and this is neither. Losing it would un-mute every
/// account someone had deliberately silenced, which reads as the app ignoring
/// a setting rather than as a cache being rebuilt.
///
/// One shared instance because the settings screen writes it and the
/// background refresh reads it, several levels apart — the same argument
/// `AppearancePreference` makes. `@Observable` is what re-renders the toggles
/// without every view observing `UserDefaults` itself.
@MainActor
@Observable
public final class NotificationPreferences {
    public static let shared = NotificationPreferences()

    /// Namespaced and defined once. Two spellings of one key in two files is a
    /// preference that saves and never loads, and nothing about it looks wrong
    /// at the call site.
    private enum Key {
        static let mutedAccounts = "de.plmail.notify.mutedAccounts"
        static let enabledScopes = "de.plmail.notify.enabledScopes"
        static let disabledScopes = "de.plmail.notify.disabledScopes"
    }

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    public private(set) var policy: NotificationPolicy

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // An unreadable value falls back to "nothing said" rather than
        // throwing. A preference written by a later version of the app is not
        // worth a crash, and the fallback is the safe direction: the user
        // hears about their inbox and can mute it again.
        policy = NotificationPolicy(
            mutedAccounts: Set(defaults.stringArray(forKey: Key.mutedAccounts) ?? []),
            enabledScopes: Set(defaults.stringArray(forKey: Key.enabledScopes) ?? []),
            disabledScopes: Set(defaults.stringArray(forKey: Key.disabledScopes) ?? []))
    }

    /// Whether this account is allowed to speak at all.
    public func isMuted(accountKey: String) -> Bool {
        policy.mutedAccounts.contains(accountKey)
    }

    public func setMuted(_ isMuted: Bool, accountKey: String) {
        var muted = policy.mutedAccounts

        if isMuted {
            muted.insert(accountKey)
        } else {
            muted.remove(accountKey)
        }

        policy.mutedAccounts = muted
        defaults.set(Array(muted).sorted(), forKey: Key.mutedAccounts)
    }

    public func choice(forScope key: String) -> NotificationPolicy.Choice {
        policy.choice(forScope: key)
    }

    /// Records a deliberate answer about one scope.
    ///
    /// Writing to **both** sets is the point: switching Inbox off has to land
    /// in `disabledScopes` and leave `enabledScopes`, or the next read finds
    /// it in both and the order of the checks decides the answer.
    public func setEnabled(_ isEnabled: Bool, scopeKey: String) {
        var enabled = policy.enabledScopes
        var disabled = policy.disabledScopes

        if isEnabled {
            enabled.insert(scopeKey)
            disabled.remove(scopeKey)
        } else {
            enabled.remove(scopeKey)
            disabled.insert(scopeKey)
        }

        policy.enabledScopes = enabled
        policy.disabledScopes = disabled

        defaults.set(Array(enabled).sorted(), forKey: Key.enabledScopes)
        defaults.set(Array(disabled).sorted(), forKey: Key.disabledScopes)
    }

    /// Puts a scope back to "never said", so it follows the default again.
    public func clearChoice(forScope key: String) {
        var enabled = policy.enabledScopes
        var disabled = policy.disabledScopes

        enabled.remove(key)
        disabled.remove(key)

        policy.enabledScopes = enabled
        policy.disabledScopes = disabled

        defaults.set(Array(enabled).sorted(), forKey: Key.enabledScopes)
        defaults.set(Array(disabled).sorted(), forKey: Key.disabledScopes)
    }
}
