#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Recolouring one label, and nothing else.
///
/// **The only way to reach `Mailbox/set`'s colour arm on a built-in label.**
/// `MailboxSetMethod` gates `name` and `parentId` behind `assertMutable` and
/// deliberately does not gate `color`, with the reason written out beside it:
/// renaming or destroying Inbox breaks the invariants hanging off its role,
/// recolouring its chip breaks nothing. iOS still could not do it, because the
/// one sheet that offered a colour picker also renamed and re-parented, and so
/// was gated on ``MailboxSnapshot/mayRename``. A capability the server grants
/// and the client cannot reach is worse than one neither has: the web UI
/// colours Inbox, the phone shows the result, and there is no control for it.
///
/// Separate from ``LabelNameSheet`` rather than a mode of it. One sheet with
/// half its fields conditionally absent is a sheet whose Save button means two
/// different things, and the difference matters here — a patch that mentions
/// `name` on a system label is refused whole, colour included.
struct LabelColorSheet: View {
    /// The label being recoloured. Held rather than passed as an id so the
    /// sheet can say which label it is acting on, which is the whole reason a
    /// manager screen shows a hierarchy path at all.
    let mailbox: MailboxSnapshot
    let accountID: AccountID
    let labels: LabelActions

    /// The pending choice, owned by the presenter. Held outside so dismissing
    /// and reopening starts from the label's real colour rather than from
    /// whatever was last tapped — the same arrangement ``LabelNameSheet`` uses.
    @Binding var color: LabelColor?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabelColorPicker(selection: $color, fallbackSeed: seed)
                } header: {
                    Text(mailbox.name)
                } footer: {
                    // Says why this sheet is smaller than the other one. A
                    // control that silently offers less than the neighbouring
                    // row does reads as a bug rather than as a rule.
                    Text(
                        .ui(
                            "Built-in labels can't be renamed or moved, but their colour is yours to choose."
                        ))
                }
            }
            .navigationTitle(.ui("Colour"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Save")) { submit() }
                        .disabled(labels.isBusy)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// What the fallback tint hashes when no colour is chosen — the
    /// user-scoped label id where there is one, so the swatch shows the colour
    /// this label actually has in every account it reaches.
    private var seed: String {
        mailbox.labelID?.rawValue ?? mailbox.name
    }

    private func submit() {
        let chosen = color

        // Nothing to send when it did not move. The server treats every
        // property mentioned in a patch as a change, so a Save that always
        // wrote would overwrite a colour the web UI set while this was open
        // with the value this client read before it did.
        guard chosen != mailbox.color else {
            dismiss()
            return
        }

        Task {
            // Only closes if the server agreed, exactly as the name sheet
            // does: a sheet that dismisses on a refusal leaves the explanation
            // behind the user.
            if await labels.recolor(mailbox.mailboxID, to: chosen, accountID: accountID) {
                dismiss()
            }
        }
    }
}

#endif
