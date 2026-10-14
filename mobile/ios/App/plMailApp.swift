import PLMailUI
import SwiftUI

@main
struct PLMailApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Only here because the device-token callback is delivered nowhere else.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push

    init() {
        let model = _model.wrappedValue

        BackgroundRefresh.register(
            refresh: { await model.refreshInBackground() },
            // The body prefetcher holds a flag of its own, because the
            // expiration handler does not run on the task doing the work and
            // cancelling that task alone would not stop it at the next chunk.
            expire: { model.backgroundRefreshExpired() })
    }

    var body: some Scene {
        // Named so File ▸ New Window can open a second one of *these* rather
        // than guessing which group it meant. Every window in this group
        // shares one `AppModel`, and therefore one connection, one sync
        // service and one undo stack — which is the answer to P6's "audit the
        // singleton assumptions first": two windows of the same mailbox are
        // two views of one thing, not two copies of it.
        WindowGroup(id: MailCommands.mailWindowID) {
            RootView(model: model)
                .task { model.adopt(push) }
        }
        // Attached once, on the primary group. Menus are app-wide on iPadOS,
        // so declaring them on each scene would draw every item twice.
        .commands { MailCommands() }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.scenePhaseChanged(to: phase) }
        }

        // P6. Both take ids rather than objects, because the system persists a
        // scene value and hands it back after a relaunch — see
        // ``ThreadWindowValue``.
        WindowGroup(for: ThreadWindowValue.self) { $value in
            if let value {
                ThreadWindow(model: model, value: value)
            }
        }

        WindowGroup(for: ComposeWindowValue.self) { $value in
            if let value {
                ComposeWindow(model: model, value: value)
            }
        }

        // The calendar's scene. Same rule again, and it matters most here: the
        // value is a day *key*, never an event, because a scene value restored
        // a week later would otherwise hand back a copy of a meeting that has
        // since been cancelled — and a window that reopens on a deleted event
        // is a window arguing with the calendar beside it.
        WindowGroup(for: CalendarWindowValue.self) { $value in
            if let value {
                CalendarWindow(model: model, value: value)
            }
        }
    }
}
