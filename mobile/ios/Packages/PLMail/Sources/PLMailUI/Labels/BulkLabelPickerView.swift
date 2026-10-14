#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Labelling a whole selection.
///
/// A checklist like ``LabelPickerView``, but with a third state it does not
/// need: across forty conversations a label is on **all**, **some** or
/// **none**, and "some" is the interesting one. The previous version offered
/// bare Apply and Remove buttons precisely because a selection has no single
/// state — but that put the burden on the user to remember what was already
/// where. Reading it out of the store and showing it is strictly more
/// informative, and it makes the verb predictable: a tap on a partial label
/// completes it rather than guessing.
///
/// Labels are listed by their **user-scoped** id, so one row covers every
/// account in the selection. Accounts with no binding for the label are skipped
/// on the way out rather than blocked here — a label used in one mailbox and
/// never in another is the normal case, not an error.
struct BulkLabelPickerView: View {
    let targets: [ActionTarget]
    let sync: MailSyncService
    let actions: MailActions
    /// Optional so a caller without one still gets the picker, just without
    /// the inline create. Nil is a degradation, not a mode.
    var labelActions: LabelActions?
    let store: SyncStore
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// How many of the selected conversations carry each label. Absent until
    /// the store has answered — an unchecked box that turns out to be checked
    /// reads as the app having lost the label.
    @State private var counts: [LabelID: Int] = [:]
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            List {
                if let name = creatable {
                    Section {
                        Button {
                            Task { await createAndApply(named: name) }
                        } label: {
                            Label(
                                .ui("Create “\(name)” and apply it"), systemImage: "plus.circle")
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
                    ForEach(labels) { label in
                        row(label)
                    }
                }
            }
            .navigationTitle(.ui("Label \(targets.count) selected"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(.ui("Filter or add a label")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }
            }
            .task { await loadCounts() }
            .safeAreaInset(edge: .bottom) { refusal }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Rows

    private func row(_ label: LabelRow) -> some View {
        let state = state(of: label)

        return Button {
            // A partial label completes rather than clears: the user ticked
            // forty conversations and pressed a half-filled box, which means
            // "put this on all of them" far more often than it means "take it
            // off the twelve that have it".
            apply(state != .all, label)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag.fill")
                    // Seeded on the user-scoped label id, as before, so a label
                    // with no colour keeps one tint across every account it is
                    // bound to. The chosen colour comes from the same place for
                    // the same reason: it lives on the label, not the binding.
                    .foregroundStyle(LabelTint.color(for: label.color, seed: label.id.rawValue))

                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name)
                        .foregroundStyle(.primary)

                    if let parents = label.parentPath {
                        Text(parents)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if isLoaded {
                    if state == .some {
                        // The count is the whole point: "3 of 40" tells you
                        // what a tap is about to change.
                        Text(.ui("\(counts[label.id] ?? 0) of \(targets.count)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: state.symbolName)
                        .foregroundStyle(
                            state == .none
                                ? AnyShapeStyle(Color.secondary)
                                : AnyShapeStyle(ThemeAccent())
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state == .all ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(Text(state.accessibilityValue))
    }

    /// Whether a label is on all, some or none of the selection.
    private enum Applied {
        case all
        case some
        case none

        var symbolName: String {
            switch self {
            case .all: "checkmark.circle.fill"
            // A filled dash, not an empty circle: "partly on" has to be
            // distinguishable from "off" at a glance, which is the entire
            // reason this state is drawn at all.
            case .some: "minus.circle.fill"
            case .none: "circle"
            }
        }

        var accessibilityValue: LocalizedStringResource {
            switch self {
            case .all: .ui("On all selected")
            case .some: .ui("On some selected")
            case .none: .ui("On none selected")
            }
        }
    }

    private func state(of label: LabelRow) -> Applied {
        switch counts[label.id] ?? 0 {
        case 0: .none
        case targets.count: .all
        default: .some
        }
    }

    @ViewBuilder
    private var refusal: some View {
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

    // MARK: - Acting

    private func apply(_ isApplied: Bool, _ label: LabelRow) {
        let targets = targets

        Task {
            await actions.perform(
                .setLabel(isApplied, label.id, name: label.name), on: targets)
        }

        onFinish()
        dismiss()
    }

    private func createAndApply(named name: String) async {
        // Created on the account the first selected conversation belongs to,
        // then applied across the selection by its user-scoped label id — the
        // binding for every other account is resolved by MailActions on the
        // way out, exactly as it is for a label that already existed.
        guard let labelActions,
            let first = targets.first,
            let mailboxID = await labelActions.create(
                named: name, accountID: first.accountID),
            let labelID = sync.mailboxes.first(where: {
                $0.accountKey == first.accountKey && $0.mailboxID == mailboxID
            })?.labelID
        else { return }

        query = ""
        apply(true, LabelRow(id: labelID, name: name))
    }

    // MARK: - Contents

    /// Counts each label across the selection, one store read per conversation.
    ///
    /// Reads the *store* rather than the server: these are conversations
    /// already on screen, so their labels are already local, and forty round
    /// trips to draw a checklist would be worse than not drawing it.
    private func loadCounts() async {
        var tally: [LabelID: Int] = [:]

        for target in targets {
            guard
                let mailboxIDs = try? await store.mailboxIDs(
                    threadID: target.threadID, accountKey: target.accountKey)
            else { continue }

            // Collapsed to user-scoped ids first, so the same label reached
            // through two accounts' bindings counts once per conversation
            // rather than twice.
            let labelIDs = Set(
                sync.mailboxes.compactMap { mailbox -> LabelID? in
                    guard mailbox.accountKey == target.accountKey,
                        mailboxIDs.contains(mailbox.mailboxID.rawValue)
                    else { return nil }

                    return mailbox.labelID
                })

            for labelID in labelIDs {
                tally[labelID, default: 0] += 1
            }
        }

        counts = tally
        isLoaded = true
    }

    private var creatable: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard labelActions != nil,
            let first = targets.first,
            trimmed.isEmpty == false,
            LabelActions.complaint(about: trimmed) == nil,
            LabelActions.nameIsTaken(
                trimmed, parentID: nil, accountKey: first.accountKey,
                among: sync.mailboxes) == false
        else { return nil }

        return trimmed
    }

    /// Every custom label across the accounts in the selection, collapsed by
    /// user-scoped id so "Work" is one row rather than one per account.
    private var labels: [LabelRow] {
        let accounts = Set(targets.map(\.accountKey))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let hierarchy = LabelHierarchy(sync.mailboxes)
        var byLabel: [LabelID: LabelRow] = [:]

        for mailbox in sync.mailboxes {
            guard
                accounts.contains(mailbox.accountKey),
                mailbox.role == nil,
                let labelID = mailbox.labelID
            else { continue }

            let row = LabelRow(
                id: labelID,
                name: mailbox.name,
                parentPath: hierarchy.parentPath(for: mailbox),
                color: mailbox.color)

            // The binding that knows the most about where the label sits wins.
            // An account missing the parent's binding reports the child as
            // top-level, and letting that overwrite a fuller path would drop
            // the ancestry for every account.
            if byLabel[labelID]?.parentPath == nil {
                byLabel[labelID] = row
            }
        }

        return byLabel.values
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct LabelRow: Identifiable {
        let id: LabelID
        let name: String
        /// The ancestry of whichever binding this row was built from.
        ///
        /// One path, not one per account: a label's parent is a property of the
        /// user-scoped label, so every account that has a binding for it agrees
        /// — and where one account has no binding for the *parent*, that
        /// account's path is shorter rather than different. Showing the longest
        /// one available is the one that disambiguates.
        var parentPath: String?
        /// The colour chosen for the label itself, which is why this is safe to
        /// collapse across accounts: colour is on `Label`, not on the binding.
        var color: LabelColor?
    }
}

#endif
