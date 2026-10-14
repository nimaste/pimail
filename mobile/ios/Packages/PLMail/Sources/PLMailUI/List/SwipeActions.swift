#if os(iOS)

import Foundation
import SwiftUI

/// What a swipe across a conversation does.
///
/// One action per edge, which is what Gmail offers and what a full swipe can
/// honestly mean: a second button on an edge is unreachable by the gesture most
/// people actually make. Everything here is also in the row's context menu, so
/// turning an edge off never takes an action away — it only takes away the
/// shortcut.
///
/// Snooze is deliberately not on the list. Choosing when is the whole of
/// snoozing, and a swipe that silently picked tomorrow morning would be a
/// different action wearing its name.
enum SwipeAction: String, CaseIterable, Identifiable, Sendable {
    case archive
    case trash
    case readState
    case star
    case spam
    /// An edge that reveals nothing, for people who keep catching the gesture
    /// by accident.
    case nothing

    var id: String { rawValue }

    /// What the preference calls it, as opposed to what the button says.
    ///
    /// The button's title flips with the row it is on — "Read" or "Unread",
    /// "Star" or "Unstar" — but a setting has no row, so it has to name both
    /// halves rather than guess which one the reader will meet first.
    var title: LocalizedStringResource {
        switch self {
        case .archive: .ui("Archive")
        case .trash: .ui("Trash")
        case .readState: .ui("Read or unread")
        case .star: .ui("Star or unstar")
        case .spam: .ui("Report spam")
        case .nothing: .ui("Nothing")
        }
    }

    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .trash: "trash"
        case .readState: "envelope.open"
        case .star: "star"
        case .spam: "exclamationmark.shield"
        case .nothing: "minus"
        }
    }

    var tint: Color {
        switch self {
        case .archive: ActionTint.archive
        case .trash: ActionTint.destructive
        case .readState: ActionTint.readState
        case .star: ActionTint.star
        case .spam: ActionTint.spam
        case .nothing: .clear
        }
    }

    /// Only Trash. Archive is reversible from the Archive list without the
    /// undo toast, and spam is a move; a role on either would make three
    /// buttons look equally final.
    var isDestructive: Bool { self == .trash }
}

/// Which action each edge is set to.
///
/// A choice the server neither knows nor can re-derive, so it lives in
/// `UserDefaults` rather than the store — whose standing rule is that
/// everything in it is reconstructible and may be deleted on any migration
/// failure. Losing this would silently re-arm a Trash swipe on someone who had
/// turned it off.
///
/// One shared instance rather than a value passed down, because the list and
/// the sheet that changes it are siblings; `@Observable` is what makes the
/// rows re-render the moment the picker moves, without the list observing
/// `UserDefaults` itself.
@MainActor
@Observable
final class SwipeActionPreference {
    static let shared = SwipeActionPreference()

    /// Namespaced and defined once. Two spellings of the same key in two files
    /// is a preference that saves and never loads, and nothing about it looks
    /// wrong at the call site.
    private enum Key {
        static let leading = "de.plmail.swipe.leading"
        static let trailing = "de.plmail.swipe.trailing"
    }

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    /// Revealed by swiping a row to the right.
    var leading: SwipeAction {
        didSet { defaults.set(leading.rawValue, forKey: Key.leading) }
    }

    /// Revealed by swiping a row to the left.
    var trailing: SwipeAction {
        didSet { defaults.set(trailing.rawValue, forKey: Key.trailing) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Archive and Trash, matching the web UI and what the app shipped
        // before the edges became a choice. An unreadable value — a key written
        // by a later version, or by hand — falls back rather than throwing:
        // a preference is not worth a crash.
        leading = SwipeAction(rawValue: defaults.string(forKey: Key.leading) ?? "") ?? .archive
        trailing = SwipeAction(rawValue: defaults.string(forKey: Key.trailing) ?? "") ?? .trash
    }
}

/// Where the edges are chosen.
///
/// In the list's own menu rather than in Settings: it is a property of this
/// list's rows, and a swipe is discovered by making it, not by going looking
/// for a preferences screen.
struct SwipeActionSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var preference: SwipeActionPreference

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    picker(selection: $preference.leading)
                } header: {
                    Text(.ui("Swipe right"))
                }

                Section {
                    picker(selection: $preference.trailing)
                } header: {
                    Text(.ui("Swipe left"))
                } footer: {
                    Text(
                        .ui(
                            "Everything a swipe does is also in the menu you get by holding a conversation, so an edge set to Nothing takes away the shortcut and not the action."
                        ))
                }
            }
            .navigationTitle(Text(.ui("Swipe actions")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }
            }
        }
    }

    /// Inline rather than a menu: with six options and two edges, a menu means
    /// four taps to see what is on offer and no way to compare the edges.
    private func picker(selection: Binding<SwipeAction>) -> some View {
        Picker(selection: selection) {
            ForEach(SwipeAction.allCases) { action in
                Label {
                    Text(action.title)
                } icon: {
                    Image(systemName: action.symbol)
                        // The tint is the point: it is how the setting says
                        // which coloured block the gesture will reveal.
                        .foregroundStyle(action == .nothing ? Color.secondary : action.tint)
                }
                .tag(action)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

#endif
