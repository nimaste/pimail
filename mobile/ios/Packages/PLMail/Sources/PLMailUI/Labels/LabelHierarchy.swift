import Foundation
import JMAPKit
public import PLMailCore

/// Where a label sits in the tree, resolved once and asked many times.
///
/// plMail nests labels to unlimited depth — `maxMailboxDepth` is null in the
/// Session — and the wire carries only a **leaf** name plus a `parentId`. Draw
/// the leaf alone and two labels called `Q1`, one under `Work` and one under
/// `Personal`, are two identical rows: identical in the sidebar, identical as
/// two checkboxes in the label picker, and the user has no way to tell which
/// one they are about to apply.
///
/// Built as a value rather than computed per row because the walk is per label
/// and the index is per list: doing it inside a `ForEach` body would rescan
/// every mailbox for every row on every redraw.
public struct LabelHierarchy {
    /// How far the walk climbs before it gives up.
    ///
    /// The server has no depth limit, so there is no natural stopping point,
    /// and a `parentId` cycle — which a client cannot rule out, because it sees
    /// one account's slice of a user-scoped tree — would otherwise hang the
    /// render loop rather than draw a wrong name. Eight matches Android's guard
    /// so the two clients truncate the same paths.
    public static let maxDepth = 8

    /// What goes between two levels when the path is drawn.
    ///
    /// Spaced, unlike the web's bare `/`. `MailboxSetMethod::requireName`
    /// refuses a name containing a slash, so any name that has one predates
    /// that rule or arrived from an import — and with a bare joiner such a name
    /// would read as one more level of nesting that does not exist. The spaces
    /// keep the separator the app inserted distinguishable from a slash the
    /// name carries.
    public static let separator = " / "

    /// Marks a path that was truncated at ``maxDepth`` rather than one that
    /// genuinely starts where it appears to. Without it a deep label would
    /// claim a top-level ancestor it does not have.
    public static let truncationMark = "…"

    private let byID: [MailboxID: MailboxSnapshot]

    /// - Parameter mailboxes: **One account's** mailboxes, or a mixed list —
    ///   either works, because a parent is looked up by binding id and binding
    ///   ids are unique across the accounts a snapshot list can hold. The
    ///   account filter belongs to the caller, which knows what it is drawing.
    public init(_ mailboxes: [MailboxSnapshot]) {
        byID = Dictionary(
            mailboxes.map { ($0.mailboxID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The ancestors and the leaf, outermost first.
    ///
    /// A parent this account has no binding for stops the walk, exactly as the
    /// server intends: `MailboxMapper::parentId` reports such a child as
    /// top-level rather than pointing at an id the client cannot resolve, so
    /// there is nothing to name and inventing a level would be worse.
    public func components(for mailbox: MailboxSnapshot) -> [String] {
        var components = [mailbox.name]
        var seen: Set<MailboxID> = [mailbox.mailboxID]
        var parentID = mailbox.parentID

        while let next = parentID, seen.contains(next) == false {
            guard let parent = byID[next] else { break }

            if components.count >= Self.maxDepth {
                components.insert(Self.truncationMark, at: 0)
                break
            }

            components.insert(parent.name, at: 0)
            seen.insert(next)
            parentID = parent.parentID
        }

        return components
    }

    /// The whole path as one string, for a row that has the width for it.
    ///
    /// Draw this with `.truncationMode(.middle)`: a path truncated at the tail
    /// loses the leaf, which is the one component the user is looking for.
    public func path(for mailbox: MailboxSnapshot) -> String {
        components(for: mailbox).joined(separator: Self.separator)
    }

    /// The ancestors without the leaf, or nil for a top-level label.
    ///
    /// Offered separately so a row can draw the leaf at full weight and the
    /// parents small and secondary, which is what makes a list of paths
    /// scannable rather than a wall of similar strings.
    public func parentPath(for mailbox: MailboxSnapshot) -> String? {
        let components = components(for: mailbox).dropLast()

        return components.isEmpty ? nil : components.joined(separator: Self.separator)
    }

    /// How the row should be read out.
    ///
    /// Not the drawn path: VoiceOver reads `Work / Q1` as "Work slash Q1", and
    /// a name that itself contains a slash makes that unparseable by ear. The
    /// spoken form names the leaf first — the thing being acted on — and the
    /// ancestry after it, as a phrase.
    ///
    /// `String(localized:bundle:)` rather than the usual `.ui(…)`: this type is
    /// deliberately outside the module's `#if os(iOS)` fence so the path walk
    /// can be tested on the macOS host, and `.ui` lives inside it. The bundle
    /// is still named explicitly, which is the whole point of `.ui` — a lookup
    /// against `Bundle.main` finds no `de.lproj` and falls through to English
    /// with nothing reporting it.
    public func spokenPath(for mailbox: MailboxSnapshot) -> String {
        guard let parents = parentPath(for: mailbox) else { return mailbox.name }

        return String(
            localized: "\(mailbox.name), in \(parents)", bundle: .module)
    }

    /// Whether `mailbox` sits anywhere beneath `ancestor`, itself included.
    ///
    /// What a parent picker has to ask before it offers a row: moving `Work`
    /// under its own child `Work / Invoices` is a cycle, and the server answers
    /// it with a refusal the UI would then have to explain. Offering the choice
    /// and taking it back is worse than not offering it.
    ///
    /// The same depth cap applies, so a tree already deeper than
    /// ``maxDepth`` errs towards refusing rather than towards a cycle.
    public func isDescendant(_ mailbox: MailboxSnapshot, of ancestor: MailboxID) -> Bool {
        var current: MailboxID? = mailbox.mailboxID
        var seen: Set<MailboxID> = []

        for _ in 0..<Self.maxDepth {
            guard let id = current, seen.insert(id).inserted else { return false }

            if id == ancestor { return true }

            current = byID[id]?.parentID
        }

        return false
    }

    /// Whether anything in this list is nested at all.
    ///
    /// A flat account should not pay for path rendering: with no nesting every
    /// path equals its leaf, and drawing a second line under every row would be
    /// noise that says nothing.
    public var hasNesting: Bool {
        byID.values.contains { mailbox in
            guard let parentID = mailbox.parentID else { return false }

            return byID[parentID] != nil
        }
    }
}
