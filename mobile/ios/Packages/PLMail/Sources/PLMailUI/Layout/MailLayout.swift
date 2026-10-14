import SwiftUI

/// How many panes the window is actually wide enough for.
///
/// Named for the count rather than the device, because the device stopped
/// predicting the width: Stage Manager hands an iPad app any width between
/// about 320pt and the full screen, continuously, and a size class reports
/// only two of them.
public enum MailLayoutMode: String, Hashable, Sendable, CaseIterable {
    /// One pane at a time, the split view collapsed to a stack. iPhone, Slide
    /// Over, and any window too narrow to show a list beside a message.
    case single
    /// List and reader, with the sidebar reachable but not resident. The
    /// sidebar is the pane worth spending width on last: it is navigation, and
    /// navigation that is already done costs nothing to hide.
    case dual
    /// Sidebar, list and reader all resident.
    case triple
}

/// What the window's width means, resolved once and read everywhere.
///
/// Replaces `isSeparated = sizeClass != .compact`, which was one boolean doing
/// four unrelated jobs — the pane treatment, the column separator, the search
/// placement and the compose button — and therefore could not be right about
/// all of them at once. A 700pt Stage Manager window is "regular", so it was
/// given a 220pt sidebar plus a 396pt minimum list plus gutters and the reader
/// got what was left, which was nothing.
///
/// A plain value with a static resolver rather than a pile of inline
/// conditionals in `MailView`, so the breakpoints are testable without booting
/// a simulator. Every threshold below is arithmetic on the column minimums
/// that are already declared in `MailView`, not a taste.
public struct MailLayout: Equatable, Sendable {
    /// Below this, a list and a message cannot both be legible: the list column
    /// alone declares a 396pt minimum, and a reader squeezed into what is left
    /// of 500pt is a column of two-word lines.
    public static let dualThreshold: CGFloat = 500

    /// Sidebar minimum (220) + list minimum (396) + a reader wide enough to
    /// read a paragraph in (~340) + four pane gutters (~40) ≈ 1000.
    ///
    /// Deliberately above the 834pt of an 11-inch iPad in portrait. Three
    /// columns fit there arithmetically and are miserable in practice — the
    /// reader gets ~200pt — so portrait gets `.dual` with the sidebar as an
    /// overlay, which is what every shipping iPad mail app does.
    public static let tripleThreshold: CGFloat = 1000

    public let mode: MailLayoutMode
    /// The container's own width, kept so a caller can make a finer decision
    /// than the three modes carry without re-measuring.
    public let width: CGFloat

    public init(mode: MailLayoutMode, width: CGFloat) {
        self.mode = mode
        self.width = width
    }

    /// What a view tree with no `MailView` above it gets.
    ///
    /// `.single` rather than `.triple`: applying the pane treatment where there
    /// is no pane behind it draws a rounded card floating on a background
    /// nobody can see around it, whereas the reverse is merely plain. A preview
    /// or a test host should get the cheaper wrong guess.
    public static let standalone = MailLayout(mode: .single, width: 0)

    /// The width decides, with the size class as a veto.
    ///
    /// The size class is not ignored, because it is not merely a width report:
    /// a compact horizontal size class is what makes `NavigationSplitView`
    /// collapse itself into a stack. Claiming two panes while the system is
    /// showing one would put the search results in a column that is not on
    /// screen.
    ///
    /// A non-positive width means nothing has been measured yet — the first
    /// frame, or a view off screen — and falls back to the size class alone.
    public static func resolve(width: CGFloat, isCompactSizeClass: Bool) -> MailLayout {
        guard isCompactSizeClass == false else { return MailLayout(mode: .single, width: width) }

        guard width > 0 else { return MailLayout(mode: .triple, width: width) }

        let mode: MailLayoutMode =
            switch width {
            case ..<dualThreshold: .single
            case ..<tripleThreshold: .dual
            default: .triple
            }

        return MailLayout(mode: mode, width: width)
    }

    /// Whether the sidebar is down to its 56-point rail of icons.
    ///
    /// **True on `.dual`**, which is an 11-inch iPad held upright at 834
    /// points. A 224pt sidebar there leaves the reader 169 points once the
    /// list has taken its share, and a reader 169 points wide is not a reader.
    /// The rail keeps every destination one tap away and hands the difference
    /// to the two panes carrying the mail — which is what the design does at
    /// that width, and the whole of why the rail exists.
    ///
    /// False on `.single`: a phone has one pane at a time and no sidebar
    /// beside it to shrink.
    public var usesSidebarRail: Bool { mode == .dual }

    /// How wide the list is beside a reader. Narrower once the sidebar is a
    /// rail, because that width is what the rail was traded for.
    public var listWidth: CGFloat { mode == .triple ? 404 : 320 }

    /// Whether panes are drawn as separate inset surfaces over a gutter.
    ///
    /// Only where more than one is on screen. One pane filling the window has
    /// nothing to be separated *from*, and insetting it wastes the only width
    /// there is.
    public var isSeparated: Bool { mode != .single }

    /// Whether the split view's own column separator has to be suppressed.
    ///
    /// The same question as `isSeparated` today, and a different one on
    /// purpose: the separator only exists where two columns meet, and if the
    /// pane treatment ever becomes optional this must not follow it.
    /// The cards supply the division, so the system's rule down the middle of
    /// the gutter is the one thing that makes a composed layout look stitched.
    public var hidesColumnSeparator: Bool { mode != .single }

    /// Whether there is a middle column for search results to fill.
    ///
    /// The search field can only live in the sidebar, so with one pane the
    /// results have to replace the sidebar in place — typing here and reading
    /// there is not a layout. This is a different question from whether panes
    /// get gutters, which is why it is a different property.
    public var placesSearchResultsInSidebar: Bool { mode == .single }

    /// Whether New Message is the floating glass circle.
    ///
    /// One pane only. With two or three it belongs in the list column's
    /// toolbar, beside the other things that act on the list, rather than
    /// pinned to the bottom-trailing corner of the reader.
    ///
    /// **No width floor, deliberately.** A Slide Over panel is 320pt wide and
    /// so is an iPhone SE, and nothing SwiftUI exposes here tells them apart —
    /// the window-to-screen ratio that would is not in a `GeometryProxy`.
    /// Standing the button down below ~400pt would have taken it away from
    /// every small phone to tidy up a Slide Over, which is the wrong trade:
    /// on the phone it is the primary action, and in Slide Over it is merely
    /// large.
    public var usesFloatingCompose: Bool { mode == .single }

    /// What the split view should be showing.
    ///
    /// At medium widths the sidebar becomes an overlay rather than a resident
    /// column, which is the whole point of the `.dual` mode: it is the
    /// difference between a reader with 80pt and a reader with 300pt.
    /// `.automatic` when collapsed, because a collapsed split view manages its
    /// own stack and a pinned value fights it.
    public var preferredColumnVisibility: NavigationSplitViewVisibility {
        switch mode {
        case .single: .automatic
        case .dual: .doubleColumn
        case .triple: .all
        }
    }
}

extension EnvironmentValues {
    /// Resolved once at the top of `MailView` and read by every pane below it.
    ///
    /// In the environment rather than passed down as a parameter because
    /// `SearchResultsView` builds a `ThreadListView` of its own, and threading
    /// a layout through a view this package does not own would be a new
    /// initialiser argument on every intermediate.
    @Entry public var mailLayout: MailLayout = .standalone
}
