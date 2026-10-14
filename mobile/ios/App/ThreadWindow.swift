import PLMailCore
import PLMailUI
import SwiftUI

/// One conversation, in its own window.
///
/// P6's point, and the reason it is a scene rather than another sheet: on a
/// 13-inch iPad a modal covering the mailbox to show one message is the
/// stretched-phone move. Two mailboxes side by side, or a message beside the
/// list it came from, is what the screen is for.
///
/// **Never the only route.** Everything here is reachable in the main window
/// too — this window is opened from a visible More-menu item and from the
/// Message menu, and closing it loses nothing.
struct ThreadWindow: View {
    @Bindable var model: AppModel
    /// Ids, resolved here rather than carried in. The system persists a scene
    /// value and hands it back after a relaunch, by which time the account may
    /// have been signed out and the conversation deleted.
    let value: ThreadWindowValue

    var body: some View {
        NavigationStack {
            if let connection = model.connection, let sync = model.sync,
                let outbox = model.outbox, let actions = model.viewActions,
                let account = sync.accounts.first(where: { $0.accountKey == value.accountKey })
            {
                ThreadReaderView(
                    threadID: value.threadID,
                    accountKey: value.accountKey,
                    accountID: account.accountID,
                    subject: value.subject,
                    client: sync.jmapClient,
                    store: model.store,
                    sync: sync,
                    // Scoped to the server, exactly as the main window scopes
                    // it: one directory of blobs per server, shared between
                    // scenes, so opening a message in a second window does not
                    // download its attachments a second time.
                    blobs: BlobCache(serverID: connection.host),
                    actions: actions,
                    outbox: outbox,
                    credential: connection.credential
                )
            } else {
                // The same failure the main window already draws for a
                // disconnected mailbox, rather than an empty reader that
                // claims the mail is here.
                ContentUnavailableView {
                    Label {
                        Text(verbatim: value.subject)
                    } icon: {
                        Image(systemName: "tray.slash")
                    }
                }
            }
        }
        .modelContainer(model.container)
        .task { model.load() }
    }
}

/// The calendar, in its own window.
///
/// The third of P6's scenes, and the one the iPad pass most obviously wants: a
/// week beside the mailbox it is being scheduled from is what a 13-inch screen
/// is for, and it is the only place every wide-canvas affordance — three
/// columns, the standing inspector, the rail — gets the width it was built for.
///
/// **Never the only route.** The calendar is reachable in the main window too,
/// from the sidebar row and ⌘0, and closing this window loses nothing.
struct CalendarWindow: View {
    @Bindable var model: AppModel
    /// A day key, resolved here rather than carried as anything richer. The
    /// system persists a scene value and hands it back after a relaunch, by
    /// which time the account may have been signed out and every event on that
    /// day deleted — so the value says *where to look*, and what is there is
    /// read out of the cache when the window opens.
    let value: CalendarWindowValue

    var body: some View {
        Group {
            if let calendar = model.calendar {
                CalendarScreen(
                    service: calendar,
                    day: CalendarDeepLink.day(
                        forSceneKey: value.dayKey, today: CalendarDay(.now, in: .current)))
            } else {
                // The same failure the main window draws for a disconnected
                // mailbox, rather than an empty grid that claims there is
                // nothing on that day. Drawn by the UI module because that is
                // where the catalogue is.
                CalendarUnavailableView()
            }
        }
        .modelContainer(model.container)
        .task { model.load() }
    }
}

/// A composer, in its own window.
///
/// The other half of P6: a long message on a large screen should not be
/// trapped in a sheet over the mailbox it is about. ``MailView`` opens this
/// only where there is room for it — three panes, and a system that can open a
/// second window at all — and falls back to the sheet everywhere else, so the
/// composer is never lost to a window that cannot exist.
struct ComposeWindow: View {
    @Bindable var model: AppModel
    let value: ComposeWindowValue

    /// Nil until the message the composer starts from has been read back out
    /// of the cache. `.new` resolves immediately; the rest need one local
    /// fetch, and drawing an empty composer in the meantime would look like a
    /// draft that had lost its text.
    @State private var kind: ComposeModel.Kind?

    var body: some View {
        Group {
            if let kind, let sync = model.sync, let outbox = model.outbox,
                let account = sync.accounts.first(where: { $0.accountKey == value.accountKey })
            {
                ComposeView(
                    kind: kind,
                    accountKey: value.accountKey,
                    accountID: account.accountID,
                    client: sync.jmapClient,
                    store: model.store,
                    outbox: outbox
                )
            } else {
                ProgressView()
            }
        }
        .modelContainer(model.container)
        .task {
            model.load()
            kind = await resolve()
        }
    }

    /// The id in the scene value, turned into something the composer can open.
    ///
    /// Resolved on every appearance rather than cached in the scene value,
    /// because a scene value restored a day later names a message that may
    /// since have been deleted — and a reply quoting a message that is gone is
    /// a reply nobody can check.
    private func resolve() async -> ComposeModel.Kind? {
        switch value.mode {
        case .new:
            return .new

        case .editDraft:
            return value.emailID.map { .editDraft(emailID: $0) }

        case .reply, .replyAll, .forward:
            guard let emailID = value.emailID,
                let message = try? await model.store.message(
                    emailID: emailID, accountKey: value.accountKey)
            else { return nil }

            return switch value.mode {
            case .forward: .forward(message)
            case .replyAll: .reply(to: message, all: true)
            default: .reply(to: message, all: false)
            }
        }
    }
}
