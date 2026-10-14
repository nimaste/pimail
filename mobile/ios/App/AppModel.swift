import JMAPKit
import Network
import Observation
import PLMailCore
import PLMailUI
import SwiftData
import SwiftUI
import UIKit

/// Owns what outlives any one screen: the connection, the store, and the
/// decision about when the app is allowed to hold a live connection open.
@MainActor
@Observable
final class AppModel {
    private(set) var connection: ServerConnection?
    private(set) var hasLoaded = false

    let container = MailStack.makeContainer()

    /// Created once per connection rather than per view, so the live stream
    /// and the background refresh act on the same sync state the UI shows.
    private(set) var sync: MailSyncService?

    /// The server's appearance, read once per connection and owned here.
    ///
    /// **The composition root owns it because the root view is what paints
    /// from it.** Built anywhere lower and the theme reaches only the subtree
    /// below whoever built it — onboarding and the sign-in sheet sit outside
    /// the mail tree, so a settings-owned instance leaves them on the default
    /// palette while everything else moves.
    ///
    /// It takes ``MailSyncService/jmapClient`` rather than a client of its own.
    /// A second client shares nothing but the credential: it single-flights its
    /// own session fetch and carries its own `RequestGate`, so the two have no
    /// idea how many requests the *other* has in flight — which is the precise
    /// thing one shared client exists to prevent against a server whose PHP
    /// worker pool is small.
    private(set) var appearanceSettings: AppearanceSettings?

    private let credentials = CredentialStore()
    private let monitor = NWPathMonitor()
    private var isMonitoring = false

    var store: SyncStore { SyncStore(modelContainer: container) }

    // MARK: - Notifications

    /// Turns a sync that already happened into banners.
    ///
    /// Built once per app rather than per connection, so the dedupe record
    /// survives a re-authentication — which is precisely a moment when every
    /// message in the cache would otherwise look new.
    /// `@ObservationIgnored` because `@Observable` rewrites every stored
    /// property into a computed one, and `lazy` cannot survive that — the
    /// macro's own error says so. Nothing observes this anyway: it posts
    /// banners, it draws nothing.
    @ObservationIgnored private lazy var announcer = NewMailAnnouncer(container: container)

    /// A ``MailActions`` for the notification actions alone.
    ///
    /// Separate from the one `MailView` owns, because a lock-screen Archive
    /// happens with no view on screen and often with no view ever having
    /// existed. The consequence is that a notification action raises no undo
    /// bar — there is nothing to raise it over — which is why the actions
    /// offered on a banner are the reversible ones and not Trash.
    private(set) var notificationActions: MailActions?

    /// The ``MailActions`` every window's UI shares.
    ///
    /// Built here rather than inside `MailView`, which is where it used to be
    /// minted, for two reasons that the view could not solve for itself. The
    /// undo window has to come from `UIAccessibility` — which `PLMailCore` must
    /// not import — so a view-owned instance was stuck at a flat six seconds
    /// and silently excluded everyone who needs longer. And a second window
    /// would have got a second instance and therefore a second, independent
    /// undo stack, so undoing in one window would have left the other showing
    /// mail it had already archived.
    ///
    /// Separate from ``notificationActions`` on purpose: a lock-screen Archive
    /// happens with no view on screen and must not push an undo nobody can see
    /// onto the stack a person is looking at.
    private(set) var viewActions: MailActions?

    /// System search over what is already cached.
    ///
    /// Built once per app rather than per connection: it owns a high-water
    /// record of what has been indexed, and rebuilding it would either lose
    /// that record or re-read it on every reconnect. It reads the store and
    /// talks to no server — see ``MailSpotlightIndex``.
    @ObservationIgnored private lazy var spotlight = MailSpotlightIndex(store: store)

    /// The calendar the **shell** shows: a Spotlight result, a Shortcut, and a
    /// calendar window scene.
    ///
    /// Owned here because all three are built by the system, outside any view
    /// tree, and land before `MailView` has been asked for anything. `MailView`
    /// keeps its own for the sidebar route — the two are not merged because
    /// this change does not own that file, and one extra instance is a smaller
    /// cost than a shell that cannot answer a Spotlight tap at all. They agree
    /// by construction: one SQLite file underneath, one `UserDefaults` record
    /// for the index, and only ever one of the two calendars on screen, since
    /// the shell presents its own only when no other is showing.
    ///
    /// Nil until there is a connection, for the same reason as ``sync``: a
    /// calendar built against a signed-out server would read a store that no
    /// longer matches it.
    private(set) var calendar: CalendarService?

    /// Fetches message bodies behind a background refresh, so a conversation
    /// opened on a train has something to show.
    ///
    /// Constructed per connection: it closes over the client and the account
    /// list, and one built against a signed-out server would fetch into a
    /// store that no longer matches it.
    private var prefetcher: BodyPrefetcher?

    // MARK: - Connection

    func load() {
        guard hasLoaded == false else { return }

        #if DEBUG
        // A UI test that only passes on the second run — because the
        // first one left an account signed in — is worse than no test.
        // Debug-only and launch-argument-only: there is no way to reach
        // this from a shipped build, which matters because what it does
        // is delete someone's mailbox.
        if UserDefaults.standard.bool(forKey: "plmail.resetForUITests") {
            try? credentials.delete()

            let container = container
            let semaphore = DispatchSemaphore(value: 0)

            // Synchronously, unlike `signOut`: onboarding is about to be
            // built, and a store deleted underneath it a moment later
            // would race with the first sync.
            Task.detached {
                try? await SyncStore(modelContainer: container).deleteEverything()
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 5)
        }
        #endif

        // A malformed keychain entry means onboarding, not a crash: it is
        // replaceable, and the user can sign in again.
        connect(to: try? credentials.load())
        hasLoaded = true
    }

    func signedIn(_ connection: ServerConnection) {
        connect(to: connection)

        Task { await requestPushIfUseful() }
    }

    /// The server rejected the stored app password.
    ///
    /// **A 401 is not consent to delete.** This used to call ``signOut()``,
    /// which deletes the Keychain item *and* runs `SyncStore.deleteEverything()`
    /// — so a revoked, rotated or expired app password destroyed every cached
    /// message and every queued draft, and offered the onboarding screen as the
    /// only explanation. The credential is the irreplaceable thing here and it
    /// is precisely the thing that is already gone; the cache is the
    /// replaceable thing and it was the one being destroyed.
    ///
    /// So the cache stays, syncing stops, and the state is surfaced. The store
    /// is keyed by server and account, so signing in again against the same
    /// server leaves every cached row valid.
    private(set) var needsReauthentication = false

    /// A new credential for the **same** server, accepted without touching the
    /// store.
    ///
    /// Deliberately not ``signedIn(_:)``: that is the path a deliberate switch
    /// to a different server takes, and it is where dropping the cache is
    /// correct.
    func reauthenticated(_ connection: ServerConnection) {
        needsReauthentication = false

        Task { await sync?.endLiveUpdates() }
        connect(to: connection)

        Task { await requestPushIfUseful() }
    }

    /// Dismisses the re-authentication prompt without signing out.
    ///
    /// Someone who cannot mint a new app password right now — the web UI is on
    /// a machine they are not sitting at — still has a month of mail on this
    /// device, and closing the sheet must leave it readable rather than
    /// pushing them into the destructive path to get out.
    func postponeReauthentication() {
        needsReauthentication = false
    }

    /// The deliberate, already-confirmed sign-out.
    ///
    /// **This one really does delete everything**, and must keep doing so: the
    /// cache belonged to that credential, and leaving it would show the
    /// previous account's mail behind the next sign-in screen. It is reached
    /// only from the confirmed control in Settings, never from a rejected
    /// credential — see ``needsReauthentication``.
    func signOut() {
        needsReauthentication = false

        // Before the credential goes: a device that keeps its registration
        // would go on being woken for a mailbox it can no longer read.
        if let push {
            Task { await push.unregister() }
        }

        try? credentials.delete()

        // System search belonged to that credential too. An item left behind
        // is the previous account's subject and sender sitting in Spotlight
        // for whoever holds the device next, with no app left to explain it.
        Task { [spotlight] in await spotlight.removeEverything() }

        // Indexed events belonged to that credential too, and this is not
        // tidiness. `deleteEverything()` below drops the calendar cache
        // *because* it belonged to that credential; system search still
        // holding the same titles and times would contradict that, and would
        // put the previous account's meetings in front of whoever holds the
        // device next with no app left to explain them. It also clears the
        // widget's shared state, which is the other copy of the same data.
        Task { [calendar] in await calendar?.forgetIndexedEvents() }

        // The banners and the dedupe record belonged to that credential too.
        // Leaving them would show the previous account's mail on the lock
        // screen behind the next sign-in, and would silence the next
        // account's mail wherever the two servers issued the same message id.
        Task { [announcer] in await announcer.forgetEverything() }

        Task { [container] in
            // The cache belonged to that credential; leaving it would show the
            // previous account's mail behind the next sign-in screen.
            try? await SyncStore(modelContainer: container).deleteEverything()
        }

        Task { await sync?.endLiveUpdates() }
        connect(to: nil)
    }

    private func connect(to connection: ServerConnection?) {
        self.connection = connection

        guard let connection else {
            sync = nil
            outbox = nil
            push = nil
            appearanceSettings = nil
            // Back to this device's own choice. Left server-driven, the
            // sign-in screen behind a sign-out would go on wearing the previous
            // account's theme and the picker would go on claiming the server
            // chose it.
            AppearancePreference.shared.standAlone()
            notificationActions = nil
            viewActions = nil
            calendar = nil
            prefetcher = nil
            return
        }

        let service = MailSyncService(connection: connection, store: store)
        // Raises a state, and nothing else. Wiring this to `signOut` is what
        // made an expired app password delete the offline mailbox.
        service.onReauthenticationNeeded = { [weak self] in
            self?.needsReauthentication = true
        }
        sync = service

        let sender = OutboxSender(
            outbox: Outbox(serverID: connection.host),
            client: service.jmapClient,
            store: store
        )
        outbox = sender
        push = PushRegistrar(client: service.jmapClient)

        let actions = MailActions(client: service.jmapClient, store: store)
        // Pushed down from here rather than read inside Core: the value comes
        // from `UIAccessibility`, and `PLMailCore` must not import UIKit. A
        // fixed six seconds silently excludes the people who need longer —
        // VoiceOver has to announce the bar, then be swiped to, then
        // activated, and the action is already applied.
        actions.undoWindow = UndoWindow.current()
        notificationActions = actions

        let shellActions = MailActions(client: service.jmapClient, store: store)
        // The line whose absence made the UI's undo window a flat six seconds.
        shellActions.undoWindow = UndoWindow.current()
        viewActions = shellActions

        calendar = CalendarService.make(
            client: service.jmapClient,
            store: store,
            serverID: connection.host)

        let appearance = AppearanceSettings(client: service.jmapClient)
        appearanceSettings = appearance

        // Read at connect time rather than when Settings is opened, because
        // the theme has to be right on the first frame of the mail — not the
        // first frame of the screen where it happens to be editable.
        Task { await Self.adoptAppearance(from: appearance) }

        prefetcher = BodyPrefetcher(
            // Shorter than the default quarter of an hour, because this now
            // also runs after a *foreground* sync. A run is at most a handful
            // of `Email/get`s with a pause between them, and the alternative —
            // what this was before — is that every tap on a conversation waits
            // for its body to download. Android prefetches; the wait was the
            // most visible difference between the two clients.
            budget: BodyPrefetcher.Budget(minimumInterval: .seconds(120)),
            candidates: { [store] accountKey, limit in
                try await store.messagesWithoutBody(accountKey: accountKey, limit: limit)
            },
            hydrate: { [store, client = service.jmapClient] account, emailIDs in
                let session = try await client.session()
                var builder = RequestBuilder(session: session)

                let get = builder.add(
                    EmailGet(
                        accountID: account.accountID,
                        ids: .value(emailIDs.map { EmailID($0) }),
                        properties: EmailGet.readerProperties))

                let results = try await client.send(builder)
                let emails = try results.result(of: get).list

                try await store.storeReaderContent(emails, accountKey: account.accountKey)

                return emails.count
            },
            onProgress: { fetched, remaining in
                // Hops to the main actor because the reporter is `@MainActor`
                // and the prefetcher runs on its own.
                Task { @MainActor in
                    PrefetchActivity.shared.report(fetched: fetched, remaining: remaining)
                }
            })

        // Anything queued from a previous run goes out as soon as there is a
        // client to send it with. Someone who wrote a message on a train and
        // then killed the app expects it gone by the time they look again.
        Task {
            await sender.refreshCount()
            sender.drain()
        }

        startMonitoringNetwork()
    }

    /// Folds the server's answer into ``AppearancePreference``, which is what
    /// the root view paints from.
    ///
    /// The hint is taken when the object has not landed, and neither is taken
    /// when the instance has no appearance extension: a self-hosted server
    /// without it is supported, and the honest answer there is the last thing
    /// the user actually chose on this device rather than a palette invented
    /// for them.
    private static func adoptAppearance(from settings: AppearanceSettings) async {
        await settings.load()

        guard settings.isSupported else {
            AppearancePreference.shared.standAlone()

            return
        }

        if let appearance = settings.appearance {
            AppearancePreference.shared.adopt(ResolvedTheme(appearance: appearance))
        } else if let hint = settings.hint {
            AppearancePreference.shared.adopt(ResolvedTheme(hint: hint))
        }
    }

    // MARK: - Lifecycle

    func scenePhaseChanged(to phase: ScenePhase) async {
        switch phase {
        case .active:
            // Coming back to the app is the most likely moment for the server
            // to have become reachable again.
            outbox?.drain()

            // Nothing is opened here: the live stream belongs to whichever
            // list is on screen, and opening it before one exists would hold a
            // server worker to show nothing.
            break

        case .inactive, .background:
            // Torn down immediately. The worker this holds is not the app's to
            // keep while it is not being looked at, and the server's pool is
            // small enough that one idle client is a real cost.
            await sync?.endLiveUpdates()

            // Mail held for a time is the one thing that makes an earlier
            // wake-up worth asking for. The system decides whether to grant
            // it, which is why the interface promises "at the first check
            // after" rather than the time itself.
            BackgroundRefresh.schedule(noLaterThan: outbox?.nextDueAt)

        @unknown default:
            await sync?.endLiveUpdates()
        }
    }

    /// Queued mail waiting to go out. Nil until there is a connection.
    private(set) var outbox: OutboxSender?

    /// Push registration. Nil until there is a server to register with.
    private var push: PushRegistrar?
    private var pushDelegate: PushDelegate?

    /// Wires the delegate's callbacks up.
    ///
    /// Registration is asked for here rather than at first launch: a
    /// notification prompt before someone has seen a single message is the
    /// prompt everyone denies, and a denial is effectively permanent.
    func adopt(_ delegate: PushDelegate) {
        guard pushDelegate == nil else { return }

        pushDelegate = delegate

        delegate.onToken = { [weak self] token in
            await self?.push?.register(token: token, deviceName: UIDevice.current.name)
        }

        delegate.onSilentPush = { [weak self] in
            // Exactly what a foreground refresh does. A push is a hint that
            // it is worth pulling now, not a delivery mechanism.
            await self?.sync?.refreshInBackground()

            // The payload carries no mail — deliberately, so nothing about it
            // passes through Apple — so the banner can only be built after the
            // pull. This is the line that turns a silent push into something
            // the user sees.
            await self?.announceNewMail()
        }

        delegate.onNotificationResponse = { [weak self] response in
            await self?.handle(response)
        }

        // Before anything is posted, and not lazily beside the first post: a
        // request naming a category that is not registered yet arrives with no
        // actions at all, silently. The banner looks right and Archive is
        // simply missing.
        MailNotifications.registerCategories()

        Task { await requestPushIfUseful() }
    }

    func refreshInBackground() async {
        // Woken before any UI existed: rebuild just enough to do one pull.
        if sync == nil { load() }

        await sync?.refreshInBackground()

        // Only ever behind a background wake. Pull-to-refresh and the visible
        // sync are already competing for the server's single PHP worker pool,
        // and a prefetch racing them would make the thing the user is looking
        // at slower to fetch mail they have not asked for yet.
        if let sync, let prefetcher {
            await prefetcher.run(accounts: sync.accounts)
        }

        // After the pull, never instead of one. A banner is a consequence of a
        // sync that already happened; nothing here is a reason to ask the
        // server anything.
        await announceNewMail()

        // Same rule, same reason: the index describes what the pull left in
        // the cache, and reads nothing over the network.
        await indexForSpotlight()

        // The other half of a background wake, and the only thing that gets a
        // scheduled message out while nobody is looking at the app. Awaited
        // rather than fired off: the task reports itself complete when this
        // returns, and the system may suspend us on the next line.
        outbox?.drain()
        await outbox?.settle()

        // Resubmitted now that the queue is known: the run was rescheduled
        // before it started, when nothing here had been read yet, and a
        // request with the same identifier replaces that one.
        BackgroundRefresh.schedule(noLaterThan: outbox?.nextDueAt)
    }

    /// Posts banners for whatever the last pull left in the cache.
    ///
    /// Reads the store; talks to no server. Safe to call after any sync, and
    /// harmless when nothing arrived.
    func announceNewMail() async {
        guard let sync else { return }

        // The same formula `MailSyncService.publishSharedState` uses for the
        // widget. Two different counts called "unread" in one app is a bug
        // report nobody can reproduce.
        let unread =
            sync.mailboxes
            .filter { $0.role == .inbox }
            .reduce(0) { $0 + $1.unreadThreads }

        await announcer.announce(
            accounts: sync.accounts,
            mailboxes: sync.mailboxes,
            unreadCount: unread)
    }

    /// Brings system search up to date with the cache.
    ///
    /// Cheap by construction — an unchanged inbox costs one local fetch and no
    /// writes — so it is safe on the tail of a foreground sync as well as a
    /// background one. It is a **consequence** of a sync, never a reason for
    /// one.
    func indexForSpotlight() async {
        guard connection != nil else { return }

        await spotlight.refresh()
    }

    /// Sends a tapped Spotlight result to whichever screen owns it.
    ///
    /// **One callback, two indexes, and identifiers that look identical.**
    /// `MailSpotlightIndex.uid(for:)` and `CalendarSpotlightIndex.uid(for:)` are
    /// both `accountKey#id`, and the activity hands back only the identifier —
    /// the domain that tells them apart is not in it. Asked in the other order,
    /// or not asked at all, every event tap opens a conversation that does not
    /// exist, which is what made indexing events worse than not indexing them.
    ///
    /// The calendar answers first because it can answer *definitely*: it owns a
    /// record of what it wrote and a cache it can resolve the id against. The
    /// mail branch is the fallback, unchanged.
    func openSpotlightResult(uid: String) async {
        if await calendar?.openIndexedEvent(uid: uid) == true { return }

        guard let ids = MailSpotlightIndex.ids(forUID: uid) else { return }

        IntentRouter.shared.request(.thread(accountKey: ids.accountKey, threadID: ids.threadID))
    }

    /// Re-reads the badge after a notification action, without a sync.
    ///
    /// Archiving from a banner changes the unread count on this device
    /// immediately — the action is applied to the store first — so the badge
    /// must follow it rather than waiting for the next refresh a quarter of an
    /// hour later.
    /// Fills in message bodies for mail the reader has not opened yet.
    ///
    /// Called after a sync settles, foreground or background. Safe to call
    /// often: `BodyPrefetcher` declines a second run inside its own interval,
    /// caps what one run will fetch, and abandons an account on its first
    /// error — the server is frequently a Raspberry Pi with one PHP worker.
    func prefetchBodies() async {
        guard let sync, let prefetcher else { return }

        await prefetcher.run(accounts: sync.accounts)

        // Whatever the outcome. Counters left standing after a failure show
        // progress that has stopped moving.
        PrefetchActivity.shared.finish()
    }

    func refreshBadge() async {
        guard let sync else { return }

        await sync.loadCached()

        MailNotifications.setBadge(
            sync.mailboxes
                .filter { $0.role == .inbox }
                .reduce(0) { $0 + $1.unreadThreads })
    }

    /// Spends the notification prompt, at the first moment it is justified.
    ///
    /// **Not at first launch.** iOS's prompt is one-shot and a refusal is
    /// effectively permanent — only a trip to Settings undoes it — so asking
    /// before anyone has seen a single message is asking to be refused
    /// forever. This app already defers the contacts prompt until someone
    /// types a recipient; this is the same judgement: ask once there is mail
    /// on screen and the request explains itself.
    ///
    /// Deliberately **not** gated on `push.isSupported()`, unlike
    /// ``requestPushIfUseful()``. That check asks whether the *server* can
    /// send a push, which is false on every plMail server today. A local
    /// notification needs no APNs sender at all, so gating it on one is what
    /// made the whole feature unreachable.
    func requestNotificationPermissionIfEarned() async {
        guard connection != nil, let sync else { return }
        // A sync that finished, and a mailbox that has something in it. Both,
        // because an empty account that synced instantly is not the moment a
        // request for permission to announce mail makes sense.
        guard sync.lastCheckedAt != nil, sync.accounts.isEmpty == false else { return }
        guard await MailNotifications.authorizationStatus() == .notDetermined else { return }

        _ = await MailNotifications.requestAuthorization()
    }

    /// Cancels anything a background wake started, at the system's notice.
    ///
    /// Task cancellation alone is not enough: `BGAppRefreshTask`'s expiration
    /// handler does not run on the task that started the work.
    nonisolated func backgroundRefreshExpired() {
        Task { @MainActor in await prefetcher?.cancel() }
    }

    /// Registering and prompting are two different decisions.
    ///
    /// **Registering** for remote notifications needs no permission, shows
    /// nothing, and is what lets a silent push wake the app to sync. It costs
    /// a token. Do it whenever there is a server.
    ///
    /// **Prompting** for alerts spends a one-shot: refuse it and it never
    /// appears again without a trip to Settings. That is spent only on a
    /// server that advertises an APNs sender — against one without, granting
    /// it would deliver precisely nothing.
    ///
    /// Conflating the two is what made the first version of this untestable:
    /// gating registration behind the prompt meant an unsupported server
    /// never registered, so nothing could be delivered even by hand.
    private func requestPushIfUseful() async {
        PushDelegate.registerForSilentPushes()

        guard let push, await push.isSupported() else { return }

        await PushDelegate.requestAuthorization()
    }

    /// Reachability is the one signal worth reopening a tripped circuit for —
    /// time passing is not evidence that a NAS came back.
    private func startMonitoringNetwork() {
        guard isMonitoring == false else { return }

        isMonitoring = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }

            Task { @MainActor in
                await self?.sync?.networkPathChanged()
                // The network coming back is the other moment worth retrying:
                // the app may have been foregrounded for an hour on a train
                // with nothing to send to.
                self?.outbox?.drain()
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}
