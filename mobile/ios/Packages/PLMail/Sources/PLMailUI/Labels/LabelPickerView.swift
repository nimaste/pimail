#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Applying labels to a conversation.
///
/// Labels are what plMail is: not folders a message lives in one of, but tags
/// it carries any number of. So this is a checklist rather than a picker — the
/// list stays open, several labels can be toggled in a row, and each toggle is
/// its own undoable action rather than a batch applied on dismiss.
///
/// Only labels belonging to *this* conversation's account are offered. A
/// binding exists per account, and offering another account's would send an id
/// the server cannot resolve.
struct LabelPickerView: View {
    let target: ActionTarget
    let sync: MailSyncService
    let actions: MailActions
    let store: SyncStore
    /// Optional so a caller that has no ``LabelActions`` to hand still gets
    /// the picker, just without the inline create. Nil is a degradation, not a
    /// mode: every call site that can pass one should.
    var labelActions: LabelActions?

    @Environment(\.dismiss) private var dismiss

    /// Mirrors the store so a tap responds immediately. Re-read after each
    /// action rather than assumed, because a refusal puts the old value back
    /// and the checkmark has to follow it.
    @State private var applied: Set<String> = []
    @State private var isLoaded = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                // Offered before the list, where the search text already is:
                // the reason to create a label from here is that you looked
                // for one and it was not there.
                if let name = creatable {
                    Section {
                        Button {
                            Task { await createAndApply(named: name) }
                        } label: {
                            Label(
                                .ui("Create “\(name)” and apply it"),
                                systemImage: "plus.circle")
                        }
                        .disabled(labelActions?.isBusy ?? true)
                    }
                }

                if labels.isEmpty && query.isEmpty {
                    ContentUnavailableView {
                        Label(.ui("No labels yet"), systemImage: "tag")
                    } description: {
                        Text(
                            labelActions == nil
                                ? .ui("Labels you create in plMail's web UI appear here.")
                                : .ui("Type a name above to make your first one."))
                    }
                } else {
                    ForEach(labels, id: \.mailboxID) { label in
                        row(for: label)
                    }
                }
            }
            .navigationTitle(.ui("Labels"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(.ui("Filter or add a label")))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }
            }
            .task {
                applied =
                    (try? await store.mailboxIDs(
                        threadID: target.threadID, accountKey: target.accountKey)) ?? []
                isLoaded = true
            }
            // The app's undo bar is attached to the list, which is *behind*
            // this sheet — so a refusal here would put its explanation
            // somewhere nobody can see, leaving a checkmark that silently
            // refused to move. This says it where it happened.
            .safeAreaInset(edge: .bottom) { refusal }
        }
        .presentationDetents([.medium, .large])
    }

    /// The name the search field would create, or nil when there is nothing
    /// sensible to offer.
    ///
    /// Silent when the typed name already exists — the row for it is right
    /// there, and offering to create a second one that the server would refuse
    /// is worse than offering nothing.
    private var creatable: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard labelActions != nil,
            trimmed.isEmpty == false,
            LabelActions.complaint(about: trimmed) == nil,
            LabelActions.nameIsTaken(
                trimmed, parentID: nil, accountKey: target.accountKey,
                among: sync.mailboxes) == false
        else { return nil }

        return trimmed
    }

    /// Creates the label and puts it on this conversation in one go.
    ///
    /// Both, not just the create: the button is reached by looking for a label
    /// to apply, so stopping at "created" would leave the user to find the new
    /// row and tap it — having already said what they wanted.
    private func createAndApply(named name: String) async {
        guard let labelActions,
            let mailboxID = await labelActions.create(
                named: name, accountID: target.accountID)
        else { return }

        query = ""

        await actions.setLabel(true, mailbox: mailboxID, named: name, target)

        applied =
            (try? await store.mailboxIDs(
                threadID: target.threadID, accountKey: target.accountKey)) ?? applied
    }

    @ViewBuilder
    private var refusal: some View {
        // Either layer can refuse, and both refusals belong in the same place.
        if let failure = labelActions?.failure ?? actions.failure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(failure)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }

    private func row(for label: MailboxSnapshot) -> some View {
        let hierarchy = LabelHierarchy(sync.mailboxes)

        return Button {
            Task { await toggle(label) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(
                        LabelTint.color(
                            for: label.color, seed: label.labelID?.rawValue ?? label.name))

                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name)
                        .foregroundStyle(.primary)

                    // Without this, two labels called `Q1` under different
                    // parents are two identical checkboxes and the user has no
                    // way to tell which one they are about to apply.
                    if let parents = hierarchy.parentPath(for: label) {
                        Text(parents)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                // Nothing is shown as on or off until the store has actually
                // answered: an unchecked box that turns out to be checked
                // reads as the app having lost the label.
                if isLoaded {
                    Image(systemName: isApplied(label) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            isApplied(label)
                                ? AnyShapeStyle(ThemeAccent())
                                : AnyShapeStyle(HierarchicalShapeStyle.secondary)
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(hierarchy.spokenPath(for: label)))
        .accessibilityAddTraits(isApplied(label) ? [.isButton, .isSelected] : .isButton)
    }

    private func isApplied(_ label: MailboxSnapshot) -> Bool {
        applied.contains(label.mailboxID.rawValue)
    }

    private func toggle(_ label: MailboxSnapshot) async {
        let shouldApply = isApplied(label) == false

        await actions.setLabel(shouldApply, mailbox: label.mailboxID, named: label.name, target)

        // Re-read rather than toggling the local set: a refusal — removing the
        // last label a message has — leaves the store unchanged, and a
        // checkmark that moved anyway would be the app disagreeing with the
        // server about where the mail is.
        applied =
            (try? await store.mailboxIDs(
                threadID: target.threadID, accountKey: target.accountKey)) ?? applied
    }

    /// This account's custom labels. Roles are excluded: Inbox, Trash and Sent
    /// are reached by archiving, trashing and sending, and offering them as
    /// checkboxes would present two different ways to do the same thing that
    /// behave differently.
    private var labels: [MailboxSnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        return
            sync.mailboxes
            .filter { $0.accountKey == target.accountKey && $0.role == nil }
            .filter {
                trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

#endif
