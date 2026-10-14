import CoreSpotlight
import PLMailCore
import PLMailUI
import SwiftUI

/// The app shell: onboarding until there is a connection, mail after.
struct RootView: View {
    @Bindable var model: AppModel

    /// The last `plmail://pair` link this app was opened with.
    ///
    /// Held by the shell rather than by onboarding: the link can arrive while
    /// the app is cold, before that view exists, and dropping it would send the
    /// user back to the server for another code.
    @State private var pairingLink: URL?

    /// A `mailto:` link that arrived when there was nowhere to open it.
    ///
    /// Two moments produce one: a cold launch that lands on onboarding, and a
    /// non-destructive re-authentication, whose sheet sits over the mail and
    /// would swallow a composer presented underneath it. Both used to end the
    /// same way — the link dropped, with nothing said, and the person back in
    /// whatever app sent them here wondering why plMail opened and did
    /// nothing.
    @State private var deferredMailto: MailtoRequest?

    /// Applied at the root so onboarding obeys it too. Set on `MailView`
    /// instead, a sheet presented from it would inherit the override but the
    /// sign-in screen behind a sign-out would not — the app would change
    /// appearance the moment the user signed out.
    @State private var appearance = AppearancePreference.shared

    /// Whether the shell owes somebody a calendar.
    ///
    /// **Set only when nothing else is showing one.** The calendar is normally
    /// reached from the sidebar row `MailView` owns, and that screen consumes
    /// ``CalendarIntentRouter`` requests itself. But a Spotlight tap, a
    /// Shortcut and a Handoff continuation all arrive with the calendar closed
    /// — often on a cold launch — and the router's only consumer is a view that
    /// does not exist yet, so the request would sit there for ever and the tap
    /// would look like it did nothing. This is the shell taking that case.
    @State private var owesCalendar = false

    /// Read once, here, and reconciled into `\.standardAnimation` and its two
    /// siblings for everything below.
    ///
    /// The one place in the app that consults it: a view that read it for
    /// itself would be a view that could forget to, and the failure mode of
    /// forgetting is invisible — the app looks fine to whoever wrote it and
    /// makes somebody else ill.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let connection = model.connection, let sync = model.sync, let outbox = model.outbox,
                let actions = model.viewActions
            {
                MailView(
                    connection: connection,
                    sync: sync,
                    store: model.store,
                    outbox: outbox,
                    // Built by the composition root so its undo window can see
                    // `UndoWindow.current()` — three times as long for
                    // VoiceOver and Switch Control users — and so a second
                    // window shares one undo stack rather than starting its
                    // own.
                    actions: actions,
                    onSignOut: model.signOut
                )
                // The moment the notification prompt is justified: a sync has
                // finished and there is mail on the screen behind the dialog.
                // Keyed on `lastCheckedAt` so it runs when the first sync
                // completes rather than when the view appears, which on a cold
                // launch is several seconds earlier and shows an empty list.
                .task(id: sync.lastCheckedAt) {
                    await model.requestNotificationPermissionIfEarned()

                    // System search follows the cache, and a sync that has
                    // just finished is the only moment the cache changes.
                    // Local reads only — nothing here asks the server
                    // anything.
                    await model.indexForSpotlight()

                    // Last, and after the sync it follows: bodies for mail that
                    // has not been opened. Without this every tap waits for a
                    // download, which is the difference people notice against
                    // the Android client.
                    await model.prefetchBodies()
                }
            } else if model.hasLoaded {
                ServerSetupView(pairingLink: pairingLink) { model.signedIn($0) }
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(appearance.choice.colorScheme)
        // The line that makes the whole theme layer do anything. Without it
        // every reader falls back to ``ResolvedTheme/placeholder`` — which
        // renders exactly like the shipped default, so nothing looks broken
        // and a server-set theme silently reaches nothing.
        //
        // Applied above the `Group`, not on `MailView`: onboarding and the
        // re-authentication sheet are siblings of the mail, and a theme set on
        // the mail alone would leave the sign-in screen on the default palette
        // — the appearance would change the moment somebody signed out.
        .environment(\.theme, appearance.theme)
        // Applied here as well as by `MailView`. Recomputing the same three
        // animations from the same two inputs is idempotent, and covering the
        // root is what reaches onboarding and Settings, which sit outside the
        // mail tree.
        .resolvedMotion(appearance.theme.motion, reduced: reduceMotion)
        // Handed down rather than rebuilt where it is written: the appearance
        // picker is behind a sheet several levels below this, and a second
        // instance would mean a second session fetch and a second view of what
        // the server holds.
        .environment(\.appearanceSettings, model.appearanceSettings)
        .modelContainer(model.container)
        // A sheet over the mail, not a replacement for it. Presenting
        // onboarding as the root — which is what signing out did — takes a
        // month of cached mail off the screen to fix a credential, and the two
        // are unrelated problems. Dismissing leaves the mail readable.
        .sheet(
            isPresented: Binding(
                get: { model.needsReauthentication },
                set: { if $0 == false { model.postponeReauthentication() } }
            )
        ) {
            ServerSetupView(address: model.connection?.address.baseURL.absoluteString ?? "") {
                model.reauthenticated($0)
            }
        }
        // The shell's own calendar, for the routes in from outside the app. A
        // cover rather than a sheet because a calendar in a half-height card on
        // a 13-inch iPad is the stretched-phone move the whole iPad pass exists
        // to avoid — and a cover supplies no back button, which is why
        // ``CalendarScreen`` is given an explicit Done.
        .fullScreenCover(isPresented: isPresentingCalendar) {
            if let calendar = model.calendar {
                CalendarScreen(service: calendar) { owesCalendar = false }
            }
        }
        // Watched here as well as inside the calendar itself. Whoever is on
        // screen takes the request; this only decides whether anybody is.
        .onChange(of: CalendarIntentRouter.shared.pending) { _, request in
            guard request != nil, CalendarIntentRouter.shared.isShowing == false else { return }

            owesCalendar = true
        }
        .task {
            model.load()

            // The cold-launch case, and the one `onChange` cannot see: a
            // Shortcut or a Spotlight tap that *starts* the app posts its
            // request before this view has a body, so there is no change to
            // observe — only a value already sitting there.
            if CalendarIntentRouter.shared.pending != nil,
                CalendarIntentRouter.shared.isShowing == false
            {
                owesCalendar = true
            }
        }
        // A Spotlight result — a conversation or an event. Both indexes write
        // the same `accountKey#id` shape and the activity carries no domain, so
        // the decision cannot be made here by looking; the model asks the
        // calendar first, which is the only one of the two that can answer
        // definitely. Either way it goes through a router, so there is one way
        // in from outside the view tree per surface, not three.
        //
        // Asynchronous because the calendar's answer needs one local read.
        // Nothing is fetched, and a request posted a frame later is still
        // picked up: the routers hold it until a screen takes it.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let uid = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
            else { return }

            Task { await model.openSpotlightResult(uid: uid) }
        }
        // Handoff, from the iPad to the Mac and back. The payload is two ids;
        // the conversation itself is fetched from the server this device is
        // already signed into, so nothing about the mail passes through iCloud.
        .onContinueUserActivity(ThreadReaderView.readingActivityType) { activity in
            guard
                let accountKey = activity.userInfo?[
                    ThreadReaderView.activityAccountKey] as? String,
                let threadID = activity.userInfo?[ThreadReaderView.activityThreadKey] as? String
            else { return }

            IntentRouter.shared.request(.thread(accountKey: accountKey, threadID: threadID))
        }
        .onOpenURL { url in
            // A `mailto:` from anywhere on the device: Safari, Messages,
            // another app's contact sheet. Untrusted input, parsed before it
            // is believed — and a link that parses to nothing at all is still
            // a link, so it opens a blank composer rather than failing.
            if let mailto = Mailto.parse(url) {
                open(mailto)

                return
            }

            // Only while signed out. A pairing link arriving at a device that
            // already has a mailbox would otherwise silently replace it.
            guard model.connection == nil else { return }

            pairingLink = url
        }
        // The moment a held link becomes openable: onboarding finished, or the
        // re-authentication sheet went away.
        .onChange(of: canCompose) { _, can in
            if can { releaseDeferredMailto() }
        }
    }

    /// Held back until there is a calendar to draw.
    ///
    /// A cold launch from a Shortcut runs the intent before ``AppModel/load()``
    /// has produced a connection, and presenting then would put an empty cover
    /// on the screen that never fills in. Reading the model in the getter means
    /// the cover appears on the frame the connection lands instead.
    private var isPresentingCalendar: Binding<Bool> {
        Binding(
            get: { owesCalendar && model.calendar != nil },
            set: { if $0 == false { owesCalendar = false } })
    }

    /// Whether there is a mailbox on screen to open a composer over.
    private var canCompose: Bool {
        model.connection != nil && model.needsReauthentication == false
    }

    /// Sends a parsed link to the shell, or holds it until there is a shell.
    private func open(_ mailto: MailtoRequest) {
        guard canCompose else {
            deferredMailto = mailto

            return
        }

        IntentRouter.shared.request(mailto: mailto)
    }

    /// Hands over a link that was waiting.
    ///
    /// After a beat, because the thing that just changed is a sheet going
    /// away: asking for a composer while the re-authentication sheet is still
    /// animating out presents it into a view that is about to stop being
    /// presented, and nothing appears.
    private func releaseDeferredMailto() {
        guard let mailto = deferredMailto else { return }

        deferredMailto = nil

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))

            IntentRouter.shared.request(mailto: mailto)
        }
    }
}
