#if os(iOS)

public import PLMailCore

import SwiftUI

/// What can be done to one event, wherever it is drawn.
///
/// **In the environment rather than passed down**, because the same chip is
/// built by four different views — the agenda list, the day and week columns,
/// the all-day band and the month cell — and threading five closures through
/// each of them would be four initialisers to change every time an action is
/// added, with four chances to forget one. A chip that silently lost its Delete
/// in one mode is exactly the sort of inconsistency nobody notices until they
/// need it.
///
/// Every closure is optional and the default is empty, so a chip rendered in a
/// preview, in a widget or in any container that has not published these is
/// inert rather than crashing — and, more importantly, **shows no menu item it
/// cannot honour**.
public struct CalendarEventActions {
    public var open: ((EventCluster) -> Void)?
    /// Nil where `myRights` refuse it. The item is then absent from the menu
    /// rather than present and doing nothing: a context menu has no room to
    /// explain a disabled row, and the detail screen — which does — greys its
    /// own Edit button with the reason instead.
    public var edit: ((EventCluster) -> Void)?
    public var delete: ((EventCluster) -> Void)?
    public var copyTitle: ((EventCluster) -> Void)?
    /// Share the occurrence as an `.ics`. Always available: it reads the cache
    /// and writes nothing to the server, so no right can refuse it.
    public var share: ((EventCluster) -> Void)?

    public init(
        open: ((EventCluster) -> Void)? = nil,
        edit: ((EventCluster) -> Void)? = nil,
        delete: ((EventCluster) -> Void)? = nil,
        copyTitle: ((EventCluster) -> Void)? = nil,
        share: ((EventCluster) -> Void)? = nil
    ) {
        self.open = open
        self.edit = edit
        self.delete = delete
        self.copyTitle = copyTitle
        self.share = share
    }

    /// Nothing offered, which is what a preview and a detached chip get.
    ///
    /// `nonisolated(unsafe)` because the type holds main-actor closures and is
    /// therefore not `Sendable`, while this particular value holds **five
    /// nils** and has nothing to race over. Marking the whole type `Sendable`
    /// instead would demand `@Sendable` closures at every call site, and the
    /// call sites are methods on a `View` — which is exactly the capture
    /// `@Sendable` would refuse.
    nonisolated(unsafe) public static let none = CalendarEventActions()

    var isEmpty: Bool {
        open == nil && edit == nil && delete == nil && copyTitle == nil && share == nil
    }
}

extension EnvironmentValues {
    /// Published once by `CalendarView` and read by every chip below it.
    @Entry public var calendarEventActions = CalendarEventActions.none
}

extension View {
    /// The context menu **and** the matching accessibility actions, together.
    ///
    /// One modifier for both because they must not be able to drift: a context
    /// menu is a long press, and the house rule is that a gesture is never the
    /// only route to an action. Writing them side by side at one call site is
    /// what makes "there is a menu item with no custom action" a change to this
    /// function rather than a bug in four views.
    func eventActions(for cluster: EventCluster) -> some View {
        modifier(EventActionsModifier(cluster: cluster))
    }
}

private struct EventActionsModifier: ViewModifier {
    let cluster: EventCluster

    @Environment(\.calendarEventActions) private var actions

    func body(content: Content) -> some View {
        if actions.isEmpty {
            content
        } else {
            content
                .contextMenu { menu }
                .modifier(EventAccessibilityActions(cluster: cluster, actions: actions))
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let open = actions.open {
            Button {
                open(cluster)
            } label: {
                Label(.ui("Open"), systemImage: "info.circle")
            }
        }

        if let edit = actions.edit {
            Button {
                edit(cluster)
            } label: {
                Label(.ui("Edit"), systemImage: "pencil")
            }
        }

        if let share = actions.share {
            Button {
                share(cluster)
            } label: {
                Label(.ui("Share"), systemImage: "square.and.arrow.up")
            }
        }

        if let copyTitle = actions.copyTitle {
            Button {
                copyTitle(cluster)
            } label: {
                Label(.ui("Copy title"), systemImage: "doc.on.doc")
            }
        }

        if let delete = actions.delete {
            Divider()

            Button(role: .destructive) {
                delete(cluster)
            } label: {
                Label(.ui("Delete event"), systemImage: "trash")
            }
        }
    }
}

/// The same five actions as VoiceOver rotor actions.
///
/// Separate from the menu builder only because `accessibilityAction(named:)` is
/// a modifier rather than a menu item; the list is deliberately the same list,
/// in the same order, from the same optional closures — so a menu item without
/// a custom action is a change to this file rather than a bug in four views.
private struct EventAccessibilityActions: ViewModifier {
    let cluster: EventCluster
    let actions: CalendarEventActions

    func body(content: Content) -> some View {
        content
            .eventAction(actions.open, named: .ui("Open"), on: cluster)
            .eventAction(actions.edit, named: .ui("Edit"), on: cluster)
            .eventAction(actions.share, named: .ui("Share"), on: cluster)
            .eventAction(actions.copyTitle, named: .ui("Copy title"), on: cluster)
            .eventAction(actions.delete, named: .ui("Delete event"), on: cluster)
    }
}

extension View {
    /// One custom action, **only where there is something behind it**.
    ///
    /// An unconditional `accessibilityAction` whose closure is nil is worse
    /// than no action at all: the rotor offers it, the reader chooses it, and
    /// nothing happens — which is indistinguishable from the app having
    /// crashed silently.
    @ViewBuilder
    fileprivate func eventAction(
        _ action: ((EventCluster) -> Void)?,
        named name: LocalizedStringResource,
        on cluster: EventCluster
    ) -> some View {
        if let action {
            accessibilityAction(named: Text(name)) { action(cluster) }
        } else {
            self
        }
    }
}

#endif
