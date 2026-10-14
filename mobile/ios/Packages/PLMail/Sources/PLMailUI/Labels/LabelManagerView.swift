#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Making, renaming and deleting labels.
///
/// Grouped by account rather than collapsed by label id, unlike the sidebar. A
/// JMAP Mailbox is a per-account *binding*, so "Work" reachable from three
/// accounts is three things that can be renamed and deleted independently —
/// and a screen whose whole job is to rename and delete has to show what it is
/// actually acting on. The sidebar collapses them because there it is one
/// place to look at mail; this is not that.
///
/// System labels appear, greyed and unactionable, rather than being filtered
/// out. A list of "your labels" that silently omits Inbox invites the user to
/// go looking for the screen that does have it.
struct LabelManagerView: View {
    let sync: MailSyncService
    let labels: LabelActions

    @Environment(\.dismiss) private var dismiss
    /// The Inbox row's colour and the Edit button's tint both come from here
    /// rather than from `Color.accentColor`, which ignores a server-set accent.
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// The order the user dragged their accounts into on the accounts screen.
    ///
    /// Read here because this screen is where a label gets created without a
    /// conversation to say which account it belongs to: the first section is
    /// the first "New label" button anyone reaches, so the account at the top
    /// is where a new label lands. Leaving it at whatever order the store
    /// happened to return made dragging an account to the top a change that
    /// visibly did nothing outside Settings.
    @State private var order = AccountOrder.shared

    @State private var creatingIn: AccountSnapshot?
    @State private var renaming: MailboxSnapshot?
    /// The built-in label whose colour is being changed.
    ///
    /// Its own state rather than a flag on ``renaming``: the two sheets do
    /// different things, and one binding for both would let a stale rename
    /// target decide which label a colour lands on.
    @State private var recolouring: MailboxSnapshot?
    @State private var deleting: MailboxSnapshot?
    @State private var draftName = ""
    /// The sheet's pending colour and parent, held here rather than inside the
    /// sheet so that dismissing and reopening starts from the label's real
    /// state instead of from whatever was last typed.
    @State private var draftColor: LabelColor?
    @State private var draftParent: MailboxID?

    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedAccounts) { account in
                    Section {
                        ForEach(rows(for: account), id: \.id) { mailbox in
                            row(mailbox)
                        }

                        Button {
                            draftName = ""
                            draftColor = nil
                            draftParent = nil
                            labels.dismissFailure()
                            creatingIn = account
                        } label: {
                            Label(.ui("New label"), systemImage: "plus.circle")
                        }
                        .disabled(labels.isBusy)
                    } header: {
                        Text(account.displayName)
                    }
                }
            }
            .navigationTitle(.ui("Labels"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { refusal }
            .sheet(item: $creatingIn) { account in
                LabelNameSheet(
                    title: .ui("New label"),
                    confirm: .ui("Create"),
                    name: $draftName,
                    color: $draftColor,
                    parentID: $draftParent,
                    labels: labels,
                    accountKey: account.accountKey,
                    mailboxes: sync.mailboxes
                ) { name, color, parentID in
                    await labels.create(
                        named: name, parentID: parentID, color: color,
                        accountID: account.accountID) != nil
                }
            }
            .sheet(item: $renaming) { mailbox in
                LabelNameSheet(
                    title: .ui("Edit label"),
                    confirm: .ui("Save"),
                    name: $draftName,
                    color: $draftColor,
                    parentID: $draftParent,
                    labels: labels,
                    accountKey: mailbox.accountKey,
                    mailboxes: sync.mailboxes,
                    // Its own name is not a clash with itself, and neither it
                    // nor anything under it can become its own parent.
                    ignoring: mailbox.mailboxID
                ) { name, color, parentID in
                    await save(mailbox, name: name, color: color, parentID: parentID)
                }
            }
            .sheet(item: $recolouring) { mailbox in
                if let accountID = accountID(for: mailbox) {
                    LabelColorSheet(
                        mailbox: mailbox,
                        accountID: accountID,
                        labels: labels,
                        color: $draftColor)
                }
            }
            .alert(
                .ui("Delete this label?"),
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if $0 == false { deleting = nil } }
                ),
                presenting: deleting
            ) { mailbox in
                Button(.ui("Delete"), role: .destructive) {
                    guard let accountID = accountID(for: mailbox) else { return }

                    Task { await labels.delete(mailbox.mailboxID, accountID: accountID) }
                }

                Button(.ui("Cancel"), role: .cancel) {}
            } message: { mailbox in
                // Says what survives, because that is the part people fear.
                // Deleting a label in plMail detaches it; it does not delete
                // mail, and the messages stay wherever else they are.
                Text(
                    .ui(
                        "“\(mailbox.name)” will be removed from this account. No mail is deleted — the messages keep every other label they carry."
                    ))
            }
        }
    }

    // MARK: - Saving

    /// Applies whatever the sheet changed, one property per request.
    ///
    /// Three requests rather than one patch, because plMail treats every
    /// property *mentioned* in a patch as a change: sending name, colour and
    /// parent together would overwrite whatever the web UI did to the other two
    /// while this sheet was open, with values this client read before it was.
    /// Each is skipped when it did not move, so a pure rename is still one
    /// round trip.
    private func save(
        _ mailbox: MailboxSnapshot, name: String, color: LabelColor?, parentID: MailboxID?
    ) async -> Bool {
        guard let accountID = accountID(for: mailbox) else { return false }

        if name.trimmingCharacters(in: .whitespacesAndNewlines) != mailbox.name {
            guard await labels.rename(mailbox.mailboxID, to: name, accountID: accountID)
            else { return false }
        }

        if color != mailbox.color {
            guard await labels.recolor(mailbox.mailboxID, to: color, accountID: accountID)
            else { return false }
        }

        if parentID != mailbox.parentID {
            guard
                await labels.reparent(
                    mailbox.mailboxID, under: parentID, accountID: accountID)
            else { return false }
        }

        return true
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ mailbox: MailboxSnapshot) -> some View {
        let hierarchy = LabelHierarchy(sync.mailboxes)

        HStack(spacing: 12) {
            Image(systemName: mailbox.role?.symbolName ?? "tag.fill")
                .foregroundStyle(
                    MailboxSidebarView.tint(
                        for: mailbox.role, accent: theme.accentColor(in: colorScheme))
                        ?? LabelTint.color(
                            for: mailbox.color,
                            seed: mailbox.labelID?.rawValue ?? mailbox.name))

            VStack(alignment: .leading, spacing: 1) {
                Text(mailbox.name)
                    .foregroundStyle(mailbox.mayRename ? .primary : .secondary)

                // Drawn only where there is nesting, and above the leaf in
                // weight order rather than instead of it: this screen renames
                // and deletes, and acting on the wrong `Q1` of two is exactly
                // the mistake the path is here to prevent.
                if let parents = hierarchy.parentPath(for: mailbox) {
                    Text(parents)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            // Named rather than left to the greying-out alone: "why can't I
            // rename this" is answered here instead of by trying.
            if mailbox.mayRename == false && mailbox.mayDelete == false {
                Text(.ui("Built in"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            if mailbox.mayDelete {
                Button(role: .destructive) {
                    labels.dismissFailure()
                    deleting = mailbox
                } label: {
                    Label(.ui("Delete"), systemImage: "trash")
                }
            }

            if mailbox.mayRename {
                Button {
                    draftName = mailbox.name
                    draftColor = mailbox.color
                    draftParent = mailbox.parentID
                    labels.dismissFailure()
                    renaming = mailbox
                } label: {
                    Label(.ui("Edit"), systemImage: "pencil")
                }
                .tint(theme.accentColor(in: colorScheme))
            }

            // The colour arm of `Mailbox/set` is not gated by `assertMutable`,
            // so this is the one change a built-in label accepts — and without
            // a control of its own it was unreachable, because Edit above
            // renames and is gated on `mayRename`.
            if mailbox.mayRename == false {
                Button {
                    draftColor = mailbox.color
                    labels.dismissFailure()
                    recolouring = mailbox
                } label: {
                    Label(.ui("Colour"), systemImage: "paintpalette")
                }
                .tint(theme.accentColor(in: colorScheme))
            }
        }
        // Combined so the path is read with the name rather than as a second
        // stop, and labelled explicitly so "Q1" in a list of four "Q1"s is
        // still identifiable by ear.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spokenLabel(for: mailbox, in: hierarchy)))
        // Named outright as well as offered as a swipe. A swipe is the only
        // route to this on a built-in row, and a gesture with no spoken
        // equivalent is a capability VoiceOver users do not have.
        .accessibilityActions {
            if mailbox.mayRename == false {
                Button(.ui("Colour")) {
                    draftColor = mailbox.color
                    labels.dismissFailure()
                    recolouring = mailbox
                }
            }
        }
    }

    /// What the row reads out as: the label's place in the hierarchy, then the
    /// colour by **name**.
    ///
    /// The hue is drawn on the icon and nowhere else, so without this the one
    /// property a built-in label has — and the only one this screen can change
    /// about it — is invisible to anyone reading the screen rather than looking
    /// at it, and to anyone who cannot separate two of the nine.
    private func spokenLabel(
        for mailbox: MailboxSnapshot, in hierarchy: LabelHierarchy
    ) -> String {
        let path = hierarchy.spokenPath(for: mailbox)

        guard let color = mailbox.color else { return path }

        return "\(path), \(String(localized: LabelTint.name(for: color)))"
    }

    @ViewBuilder
    private var refusal: some View {
        if let failure = labels.failure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(failure)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(.ui("Dismiss")) { labels.dismissFailure() }
                    .font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Contents

    /// Accounts in the user's order, with any the stored order does not know
    /// about kept where they were rather than promoted to the top.
    private var orderedAccounts: [AccountSnapshot] {
        order.ordered(sync.accounts, key: \.accountKey)
    }

    /// This account's mailboxes: custom labels first, since they are what can
    /// be acted on here, then the built-ins.
    private func rows(for account: AccountSnapshot) -> [MailboxSnapshot] {
        sync.mailboxes
            .filter { $0.accountKey == account.accountKey }
            .sorted { first, second in
                if (first.role == nil) != (second.role == nil) {
                    return first.role == nil
                }

                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    private func accountID(for mailbox: MailboxSnapshot) -> AccountID? {
        sync.accounts.first { $0.accountKey == mailbox.accountKey }?.accountID
    }
}

/// The one text field, shared by Create and Rename.
///
/// The two differ only in their words and in what they do on confirm, and a
/// second copy of the validation is a second place for it to drift from the
/// server's rules.
struct LabelNameSheet: View {
    let title: LocalizedStringResource
    let confirm: LocalizedStringResource
    @Binding var name: String
    /// Nil is "no colour chosen", which is a state the label can be returned
    /// to — not a synonym for grey, and not the same as leaving the colour
    /// alone. See ``LabelTint``.
    @Binding var color: LabelColor?
    /// The parent binding id, nil for a top-level label.
    @Binding var parentID: MailboxID?
    let labels: LabelActions
    let accountKey: String
    let mailboxes: [MailboxSnapshot]
    var ignoring: MailboxID?
    let perform: (String, LabelColor?, MailboxID?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.ui("Label name"), text: $name)
                        .focused($isFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .onSubmit { if isValid { submit() } }
                } footer: {
                    // Said while typing rather than after pressing. Both of
                    // these are rules the server enforces, and finding out
                    // from a refusal means retyping a name already gone from
                    // the field.
                    if let complaint {
                        Text(complaint)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    // Only same-account labels: a parent is a *binding* id, so
                    // another account's would be an id this account cannot
                    // resolve, refused as `invalidProperties` and reported to
                    // the user as a name clash.
                    Picker(selection: $parentID) {
                        Text(.ui("None")).tag(MailboxID?.none)

                        ForEach(parentOptions, id: \.mailboxID) { option in
                            Text(hierarchy.path(for: option))
                                .tag(MailboxID?.some(option.mailboxID))
                        }
                    } label: {
                        Text(.ui("Nested under"))
                    }
                } footer: {
                    // Names the rule the picker's own contents already enforce,
                    // because a missing row is not an explanation.
                    Text(
                        .ui(
                            "A label can be nested under another on the same account. Its own name never contains a slash."
                        ))
                }

                Section {
                    LabelColorPicker(selection: $color, fallbackSeed: name)
                } header: {
                    Text(.ui("Colour"))
                } footer: {
                    // Says what nil means, since the swatch for it looks like
                    // a colour.
                    Text(.ui("Without a colour, plMail picks one from the name."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: confirm)) { submit() }
                        .disabled(isValid == false || labels.isBusy)
                }
            }
            .task { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let name = name
        let color = color
        let parentID = parentID

        Task {
            // Only closes if the server agreed. A sheet that dismisses on a
            // refusal drops the user back to a list unchanged, with the
            // explanation behind them.
            if await perform(name, color, parentID) { dismiss() }
        }
    }

    private var hierarchy: LabelHierarchy {
        LabelHierarchy(mailboxes)
    }

    /// The labels this one may be nested under.
    ///
    /// Excludes itself and everything already beneath it — that is a cycle, and
    /// the server refuses it after a round trip — and every system label, whose
    /// children plMail does not model as user labels.
    private var parentOptions: [MailboxSnapshot] {
        let hierarchy = hierarchy

        return
            mailboxes
            .filter { candidate in
                guard candidate.accountKey == accountKey, candidate.role == nil else {
                    return false
                }

                guard let ignoring else { return true }

                return hierarchy.isDescendant(candidate, of: ignoring) == false
            }
            .sorted {
                hierarchy.path(for: $0).localizedStandardCompare(hierarchy.path(for: $1))
                    == .orderedAscending
            }
    }

    private var complaint: String? {
        // Silent on an empty field: the user has not typed anything wrong
        // yet, they have simply not finished. The button is disabled, which
        // says enough.
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        // Already localised by PLMailCore, which owns the rule and therefore
        // owns the wording of it.
        if let complaint = LabelActions.complaint(about: name) { return complaint }

        if isTaken {
            return String(localized: .ui("There's already a label with that name here."))
        }

        return nil
    }

    /// Siblings are siblings *under the chosen parent*, which is why this reads
    /// ``parentID`` rather than passing nil. Checking against the top level
    /// instead would refuse "Invoices" under `Work` because a top-level
    /// "Invoices" exists — a name the server would have accepted.
    private var isTaken: Bool {
        LabelActions.nameIsTaken(
            name,
            parentID: parentID,
            accountKey: accountKey,
            among: mailboxes.filter { $0.mailboxID != ignoring }
        )
    }

    private var isValid: Bool {
        LabelActions.complaint(about: name) == nil && isTaken == false
    }
}

#endif
