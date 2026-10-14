#if os(iOS)

public import PLMailCore

import SwiftUI

/// The mailboxes this login can see, and where they actually come from.
///
/// Worth stating plainly, because the app looks like it has multi-account
/// settings and does not: **plMail owns the accounts, the app owns one
/// credential.** The IMAP, Gmail and Outlook mailboxes listed here were
/// connected in plMail's web interface and are handed to every client through
/// one JMAP session. There is no JMAP method to connect or disconnect one, so
/// this screen shows them and links out rather than offering an Add button
/// that would have to lie.
///
/// The same fact is why signing out is all-or-nothing: there is one app
/// password in the Keychain covering the lot, and "sign out of just this
/// mailbox" would mean revoking something the app does not hold. Said in the
/// footer rather than left to be discovered by someone who expected otherwise.
///
/// What this screen *can* change is the order — which is not decoration, since
/// the first account is the one the composer opens on and the one a new label
/// is created in — and whether an account is allowed to make a sound.
struct AccountsView: View {
    let connection: ServerConnection
    let sync: MailSyncService
    let store: SyncStore

    @State private var accounts: [AccountSnapshot] = []
    /// Cached-window facts, keyed by account. Loaded once per appearance
    /// rather than per row: each is two store queries, and a row that fetched
    /// its own would run them again on every scroll.
    @State private var windows: [String: CachedWindowSnapshot] = [:]
    @State private var order = AccountOrder.shared
    @State private var preferences = NotificationPreferences.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if sync.status == .unauthenticated {
                attentionSection
            }

            Section {
                ForEach(displayedAccounts) { account in
                    AccountRow(
                        account: account,
                        window: windows[account.accountKey],
                        isMuted: preferences.isMuted(accountKey: account.accountKey),
                        degradedMessage: degradedMessage(for: account))
                }
                .onMove(perform: move)
            } header: {
                Text(.ui("Mailboxes on this server"))
            } footer: {
                Text(
                    .ui(
                        "These are the mailboxes plMail collects for you. Connecting or disconnecting one is done on the server, not here. The first one is where a new message and a new label start."
                    ))
            }

            Section {
                Button(.ui("Open plMail in a browser"), systemImage: "safari") {
                    openURL(connection.address.baseURL)
                }
            }

            Section {
                LabeledContent(.ui("Server"), value: connection.host)
                LabeledContent(.ui("Signed in as"), value: connection.username ?? "—")
            } footer: {
                Text(
                    .ui(
                        "One app password covers every mailbox above, so signing out signs out of all of them. To use a different server, sign out and pair again — this app holds one at a time."
                    ))
            }
        }
        .navigationTitle(Text(.ui("Accounts")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // VoiceOver has a first-class reorder rotor on a `List` in edit
            // mode, so `EditButton` is the accessible answer here and no
            // hand-written up/down actions are needed — unlike Android, where
            // the two arrow buttons *are* the custom action.
            ToolbarItem(placement: .primaryAction) {
                if displayedAccounts.count > 1 { EditButton() }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    /// Sign-in has failed and the cached mail is still here.
    ///
    /// Said explicitly because the alternative is a mailbox that quietly stops
    /// updating. **Nothing on this screen deletes anything**: a rejected app
    /// password is not consent to throw away the offline mail, and the only
    /// path that deletes the cache is the confirmed sign-out one screen up.
    private var attentionSection: some View {
        Section {
            Label {
                Text(.ui("Your app password was rejected. Mail on this device is untouched."))
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ActionTint.spam)
            }

            Button(.ui("Open plMail in a browser"), systemImage: "safari") {
                openURL(connection.address.baseURL)
            }
        } header: {
            Text(.ui("Needs attention"))
        } footer: {
            Text(
                .ui(
                    "Issue a new app password in the web interface, then sign out and pair again. Signing out is the only thing that deletes the mail already downloaded."
                ))
        }
    }

    /// The store's copy is preferred because it carries the last sync time and
    /// the last error; the service's in-memory list is a snapshot taken before
    /// those were written and would show "never synced" straight after a sync.
    private var displayedAccounts: [AccountSnapshot] {
        order.ordered(accounts.isEmpty ? sync.accounts : accounts, key: \.accountKey)
    }

    private func degradedMessage(for account: AccountSnapshot) -> String? {
        sync.degradedAccounts[account.accountKey] ?? account.lastSyncError
    }

    private func move(from source: IndexSet, to destination: Int) {
        var keys = displayedAccounts.map(\.accountKey)
        keys.move(fromOffsets: source, toOffset: destination)
        order.setOrder(keys)
    }

    private func reload() async {
        accounts = (try? await store.accounts()) ?? []

        var loaded: [String: CachedWindowSnapshot] = [:]

        for account in displayedAccounts {
            loaded[account.accountKey] =
                (try? await store.cachedWindow(accountKey: account.accountKey))
        }

        windows = loaded
    }
}

/// One mailbox: what it is called, how much of it is here, and what went wrong.
struct AccountRow: View {
    let account: AccountSnapshot
    let window: CachedWindowSnapshot?
    let isMuted: Bool
    let degradedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: account.displayName)

            if account.isReadOnly {
                Label(.ui("Read-only"), systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isMuted {
                // A muted account still syncs and still counts unread, so
                // without this line "muted" and "push is broken" look the same
                // from here — which is the state people report as a bug.
                Label(.ui("Notifications off"), systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let degradedMessage {
                Label {
                    Text(verbatim: degradedMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(ActionTint.spam)
            } else if let lastSyncedAt = account.lastSyncedAt {
                Text(
                    .ui(
                        "Synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                // Not an error, and not dressed as one: a mailbox added on the
                // server a minute ago has legitimately never synced here.
                Text(.ui("Not synced yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            cachedWindowLine
        }
        .accessibilityElement(children: .combine)
    }

    /// One sentence rather than two labelled facts.
    ///
    /// *"412 messages, back to 3 March"* is the shape of the answer somebody
    /// wants when they cannot find an old mail; a count in one row and a date
    /// in another makes them do the joining themselves. It says **on this
    /// device** because the number is the cache's, not the server's, and
    /// conflating the two is how "where is my old mail" becomes a bug report.
    @ViewBuilder
    private var cachedWindowLine: some View {
        if let window, window.isEmpty == false {
            if let oldest = window.oldestReceivedAt {
                Text(
                    .ui(
                        "\(window.messageCount) messages on this device, back to \(oldest.formatted(date: .abbreviated, time: .omitted))"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(.ui("\(window.messageCount) messages on this device"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#endif
