#if os(iOS)

public import PLMailCore

import SwiftUI
import UIKit
import UserNotifications

/// Which mail is allowed to make a sound.
///
/// The model behind this screen is **tri-state** and the screen has to keep it
/// that way. A `Toggle` bound to a plain `Bool` collapses *"the user switched
/// Newsletters off"* into *"the user has never opened this screen"*, and the two
/// have to behave differently: a label created on the web next month must
/// default to off rather than inheriting a yes somebody gave to a different
/// label a year ago. So every row's binding reads
/// ``NotificationPolicy/choice(forScope:)`` and falls back to the scope's own
/// default only when nothing has been said, the row says which of the two it is
/// showing, and there is an explicit way back to *nothing said* —
/// **Use the default** — that plain toggles cannot express.
///
/// Accounts work the other way round and also deliberately: the store holds
/// *muted* accounts, never allowed ones, so a mailbox connected on the server
/// tomorrow speaks without anyone visiting this screen. An allow list would
/// make a new mailbox look broken, which is the thing people report as
/// "notifications stopped working".
///
/// **No per-account channels.** That is Android's model; iOS has one app-level
/// permission the user owns, which is what the link at the top goes to.
struct NotificationsView: View {
    let sync: MailSyncService

    @State private var preferences = NotificationPreferences.shared
    /// The system's answer, not the app's. A screen full of switches on a
    /// device where notifications are denied is a screen of controls that
    /// cannot do anything, and saying so is the only useful thing it can do.
    @State private var systemAuthorisation: UNAuthorizationStatus = .notDetermined
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            permissionSection
            accountsSection
            scopesSection
        }
        .navigationTitle(Text(.ui("Notifications")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await readAuthorisation() }
    }

    // MARK: - Permission

    @ViewBuilder
    private var permissionSection: some View {
        Section {
            if systemAuthorisation == .denied {
                Label(.ui("Notifications are turned off for plMail"), systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(ActionTint.spam)
            }

            Button(.ui("Open iOS notification settings"), systemImage: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } footer: {
            Text(
                .ui(
                    "Sounds, banners and the lock screen are iOS's settings, not this app's. Everything below decides only which mail is worth telling you about."
                ))
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountsSection: some View {
        if sync.accounts.isEmpty == false {
            Section {
                ForEach(sync.accounts) { account in
                    Toggle(isOn: muteBinding(for: account)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: account.displayName)

                            if preferences.isMuted(accountKey: account.accountKey) {
                                // A muted account still syncs and still shows
                                // unread counts, so without this sentence
                                // "muted" and "push is broken" look identical
                                // from the outside.
                                Text(.ui("Still synced, never announced"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel(Text(verbatim: account.displayName))
                }
            } header: {
                Text(.ui("Announce mail from"))
            } footer: {
                Text(
                    .ui(
                        "A mailbox added on your server later is announced without being switched on here."
                    ))
            }
        }
    }

    /// Inverted on purpose: the store keeps *muted* accounts, and the switch
    /// reads "announce mail from this account". Storing the switch's own sense
    /// would mean an account absent from the list is silent, which is the
    /// failure mode the store's shape exists to prevent.
    private func muteBinding(for account: AccountSnapshot) -> Binding<Bool> {
        Binding(
            get: { preferences.isMuted(accountKey: account.accountKey) == false },
            set: { preferences.setMuted($0 == false, accountKey: account.accountKey) })
    }

    // MARK: - Scopes

    @ViewBuilder
    private var scopesSection: some View {
        let scopes = NotifyScopes.selectable(in: sync.mailboxes)

        Section {
            if scopes.isEmpty {
                Text(.ui("Labels appear here once your mail has synced."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scopes) { scope in
                    scopeRow(scope)
                }
            }
        } header: {
            Text(.ui("Labels"))
        } footer: {
            Text(
                .ui(
                    "Listed by their full path, so two labels with the same name are told apart. A label made later starts off, except your inbox."
                ))
        }
    }

    private func scopeRow(_ scope: NotifyScope) -> some View {
        let choice = preferences.choice(forScope: scope.key)

        return Toggle(isOn: scopeBinding(scope)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: scope.title)

                // The third state, drawn. Without it the screen shows an
                // untouched Inbox and a deliberately switched-on Inbox
                // identically, and the only way to get back to the default is
                // to know it exists.
                if choice == .unset {
                    Text(.ui("Default"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(Text(verbatim: scope.title))
        .accessibilityValue(accessibilityValue(for: choice, scope: scope))
        // A custom action rather than a swipe: returning a row to "nothing
        // said" has no other route, and an action reachable only by swiping is
        // an action VoiceOver users do not have.
        .accessibilityAction(named: Text(.ui("Use the default"))) {
            preferences.clearChoice(forScope: scope.key)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if choice != .unset {
                Button(.ui("Use the default")) {
                    preferences.clearChoice(forScope: scope.key)
                }
            }
        }
    }

    /// What the switch will do, resolved the same way the notifier resolves it.
    ///
    /// `.unset` is not "off": it means the row shows the scope's own default,
    /// which is on for the inbox and off for everything else. Reading the
    /// stored choice as the switch position would draw every untouched label
    /// as off and the inbox wrongly among them.
    private func scopeBinding(_ scope: NotifyScope) -> Binding<Bool> {
        Binding(
            get: {
                switch preferences.choice(forScope: scope.key) {
                case .on: true
                case .off: false
                case .unset: scope.isNotifiableByDefault
                }
            },
            // Flipping a switch is a deliberate answer, so it always writes one
            // — including when the new position happens to equal the default.
            // "Off, and I mean it" has to survive the label's default changing.
            set: { preferences.setEnabled($0, scopeKey: scope.key) })
    }

    private func accessibilityValue(
        for choice: NotificationPolicy.Choice, scope: NotifyScope
    ) -> Text {
        switch choice {
        case .on: Text(.ui("On"))
        case .off: Text(.ui("Off"))
        case .unset:
            scope.isNotifiableByDefault
                ? Text(.ui("On, by default")) : Text(.ui("Off, by default"))
        }
    }

    private func readAuthorisation() async {
        systemAuthorisation = await UNUserNotificationCenter.current()
            .notificationSettings()
            .authorizationStatus
    }
}

#endif
