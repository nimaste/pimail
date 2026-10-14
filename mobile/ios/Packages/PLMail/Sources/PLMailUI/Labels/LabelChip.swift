import CoreGraphics
import JMAPKit
public import PLMailCore
import SwiftUI

/// What a chip needs, resolved once by the list rather than looked up per row:
/// a row that queried the store for its labels would put a store read inside a
/// scrolling `ForEach`.
///
/// Outside the module's iOS fence, with the views inside it, so the resolution
/// — which account's bindings count, which labels are excluded, what gets
/// spoken — is testable on the macOS host.
public struct LabelChipModel: Hashable, Sendable, Identifiable {
    public let id: String
    /// The leaf name — what the chip draws.
    public let name: String
    /// The full path, for the accessibility label. Two labels called `Q1` under
    /// different parents are one chip each and identical to look at; spoken,
    /// they have to be told apart.
    public let path: String
    /// The colour the user chose, or nil to fall back to the hashed tint.
    public let color: LabelColor?
    /// What the fallback hashes when ``color`` is nil — the user-scoped label
    /// id where there is one, so the same label keeps one colour across
    /// accounts.
    public let seed: String

    public init(id: String, name: String, path: String, color: LabelColor?, seed: String) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.seed = seed
    }

    /// The chips for one conversation.
    ///
    /// - Parameters:
    ///   - mailboxIDs: The binding ids on the conversation, as
    ///     `SyncStore.mailboxIDs(threadID:accountKey:)` and
    ///     `threadProjections` both already return them.
    ///   - accountKey: Restricts the lookup to the conversation's own account.
    ///     A binding id is per-account, and matching one against another
    ///     account's mailboxes is how a row grows a label it does not carry.
    ///   - mailboxes: `MailSyncService.mailboxes`, unfiltered.
    ///   - hierarchy: Built once per list — see ``LabelHierarchy``.
    /// - Returns: One model per custom label on the conversation, in the order
    ///   the row should draw them.
    ///
    /// **System labels are excluded.** Inbox, Sent, Trash and Archive are on
    /// nearly every conversation, so chips for them would be a constant row of
    /// noise saying nothing that distinguishes one conversation from the next —
    /// which is the whole reason to draw chips at all.
    public static func chips(
        forMailboxIDs mailboxIDs: Set<String>,
        accountKey: String,
        mailboxes: [MailboxSnapshot],
        hierarchy: LabelHierarchy
    ) -> [LabelChipModel] {
        mailboxes
            .filter {
                $0.accountKey == accountKey
                    && $0.role == nil
                    && mailboxIDs.contains($0.mailboxID.rawValue)
            }
            // Alphabetical rather than by the server's sortOrder, which is
            // always 0 for custom labels: an arbitrary order would reshuffle the
            // chips on a row between syncs.
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                LabelChipModel(
                    id: $0.id,
                    name: $0.name,
                    path: hierarchy.spokenPath(for: $0),
                    color: $0.color,
                    seed: $0.labelID?.rawValue ?? $0.name
                )
            }
    }
}

/// How many chips a row can afford.
///
/// Android measures a budget rather than letting the chips push the preview
/// out: 96dp a chip, 160dp a cluster, a 104dp floor kept for the preview, and
/// **one** slot instead of two below a 400dp pane. Copied because the failure it
/// prevents is real — a row whose preview has been squeezed to nothing tells the
/// user less than one with no chips at all.
public enum LabelChipBudget {
    /// Keyed on the **pane**, not the size class: on iPad the list column is
    /// 396–540pt, so a size-class test would answer the same at both ends of
    /// that range and would therefore do nothing.
    public static let twoChipMinimumPaneWidth: CGFloat = 400

    public static func slots(paneWidth: CGFloat) -> Int {
        paneWidth < twoChipMinimumPaneWidth ? 1 : 2
    }
}

#if os(iOS)

/// One label, drawn small enough to sit on a conversation row.
///
/// **The name is not optional decoration on a coloured pill — it is the pill.**
/// A row that carried colour alone would be unreadable to anyone who cannot
/// separate the two greens, and unreadable to everyone for a label whose colour
/// they have not memorised. The hue is the fast channel; the name is the one
/// that carries the meaning, and both are always present.
public struct LabelChip: View {
    let model: LabelChipModel

    public init(_ model: LabelChipModel) {
        self.model = model
    }

    public var body: some View {
        let tint = LabelTint.color(for: model.color, seed: model.seed)

        Text(model.name)
            .font(.caption2)
            .foregroundStyle(.primary)
            .lineLimit(1)
            // The leaf can be long and the row cannot grow, so the middle goes
            // rather than the tail: "Invoices 2…" twice is one chip repeated,
            // where "Inv…2026" and "Inv…2025" are two the user can tell apart.
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .fill(tint.opacity(0.18))
                    // A wash alone disappears against a tinted row background —
                    // selected, open, or snoozed — so the edge is stated too.
                    .overlay { Capsule().strokeBorder(tint.opacity(0.45)) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(.ui("Label: \(model.path)")))
    }
}

/// As many chips as the row can spare width for, and a count for the rest.
///
/// The overflow count is not decoration: three labels shown as two chips and
/// nothing else is a row quietly lying about what it carries.
public struct LabelChipCluster: View {
    let models: [LabelChipModel]
    /// The width of the **list pane**, not the screen. Pass the list column's
    /// measured width — see ``LabelChipBudget``.
    let paneWidth: CGFloat

    public init(_ models: [LabelChipModel], paneWidth: CGFloat) {
        self.models = models
        self.paneWidth = paneWidth
    }

    public var body: some View {
        let slots = LabelChipBudget.slots(paneWidth: paneWidth)
        let shown = models.prefix(slots)
        let hidden = models.count - shown.count

        if models.isEmpty == false {
            HStack(spacing: 4) {
                ForEach(shown) { model in
                    LabelChip(model)
                        // No chip may take more than its share: two labels
                        // called "Q1 planning, Berlin office" would otherwise
                        // push the snooze badge and the account tag off the row.
                        .frame(maxWidth: paneWidth / 3, alignment: .leading)
                }

                if hidden > 0 {
                    Text(.ui("+\(hidden)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        // Says what it stands for, since "+2" read aloud is not
                        // self-explanatory.
                        .accessibilityLabel(Text(.ui("\(hidden) more labels")))
                }
            }
        }
    }
}

#endif
