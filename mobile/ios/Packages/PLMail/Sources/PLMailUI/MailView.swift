#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// The mail app.
///
/// A `NavigationSplitView` on both idioms: it collapses to a stack on
/// iPhone by itself, and expands to the sidebar-plus-list layout the web UI
/// uses on iPad — with one piece of state driving both, so a rotation or a
/// Stage Manager resize keeps the selection rather than resetting it.
public struct MailView: View {
    @State private var sync: MailSyncService
    /// Handed in by the composition root rather than built here.
    ///
    /// It used to be minted in `init`, which meant the shell's undo window was
    /// a flat six seconds and could not see ``UndoWindow/current()`` — that
    /// value is read from `UIAccessibility`, which `PLMailCore` must not
    /// import, so it can only be pushed down from the app. VoiceOver and
    /// Switch Control users get three times the window, and with a private
    /// instance they silently did not.
    ///
    /// It also settles P6's question: two windows share one `MailActions` and
    /// therefore one undo stack, so undoing in the second window undoes the
    /// archive you did in the first — which is what "undo" means to a person
    /// looking at two windows of the same mailbox.
    @State private var actions: MailActions
    @State private var labels: LabelActions
    /// Discovered, not assumed: a plMail instance without the calendar
    /// extension is a supported instance, not a degraded one, and
    /// `availability` emits `false` first so the entry point cannot flicker in
    /// on launch and out again.
    @State private var calendar: CalendarService
    @State private var selectedFeed: FeedID?
    /// Which slice of the inbox is showing, or nil for the whole of it.
    ///
    /// Held beside ``selectedFeed`` rather than folded into it, and that is the
    /// point of the design: a category is the inbox with a condition on it, not
    /// a sixth destination. So ⌘1 still means Inbox, the sidebar still has one
    /// row for it, and nothing about the navigation gained an axis — the list
    /// simply narrows. See ``listFeed``.
    ///
    /// **Nil is All, never Primary.** A conversation the classifier never saw
    /// belongs to no tab; if nil meant Primary the unnarrowed inbox would be
    /// unreachable and mail predating the classifier would vanish from the
    /// phone while still sitting in the browser's inbox.
    @State private var inboxCategory: MessageCategory?
    @State private var selectedThread: ThreadRef?
    /// Three columns by default on iPad. Left to the system on iPhone, where
    /// the split view is collapsed and this is ignored.
    ///
    /// Re-seeded from `layout` whenever the mode changes rather than pinned,
    /// so a Stage Manager window narrowed to 700pt gives the sidebar back
    /// instead of keeping three columns and leaving the reader 80pt. Between
    /// mode changes it is the user's — ⌘⌃S has to survive the next redraw.
    @State private var columns = NavigationSplitViewVisibility.all
    /// The split view's own width, measured rather than inferred.
    ///
    /// Zero until the first layout pass. `MailLayout.resolve` treats that as
    /// "unmeasured" and falls back to the size class, which is what the app
    /// did before this existed.
    @State private var containerWidth: CGFloat = 0
    /// Raised by ⌘⌥F, so the search field can be reached without a trackpad.
    @FocusState private var isSearchFocused: Bool
    @State private var isShowingSettings = false
    /// Whether the calendar has been pushed onto the sidebar column.
    ///
    /// Held here rather than inside the sidebar because it is also what stands
    /// the ⌘1…⌘9 mailbox numbers down: `CalendarView` binds ⌘1…⌘4 to its own
    /// view modes, and two different actions on one key is a coin toss rather
    /// than a shortcut.
    @State private var isShowingCalendar = false

    /// Whether the calendar is docked beside the mail rather than taking the
    /// window. The design's three-way pane switch: with it on, the sidebar
    /// drops to an icon rail and the calendar becomes a card of its own.
    @State private var isCalendarDocked = false

    /// The label manager, reachable from the rail — where the sidebar's own
    /// "Edit labels" row has no room to exist.
    @State private var isShowingLabelManager = false
    @State private var isSelectionActive = false
    @State private var composing: ComposeModel.Kind?
    /// What an intent asked us to fill in, consumed when the composer opens.
    @State private var prefilled: (recipient: String?, subject: String?)?
    @State private var searchText = ""
    /// Debounced separately from `searchText`, so a keystroke does not start a
    /// query against someone's home server.
    @State private var settledSearch = ""
    /// Addresses from mail already synced, for the sender suggestions. Loaded
    /// once when the field is first used rather than at launch: it is a fetch
    /// over every stored message, and most sessions never search at all.
    @State private var correspondents: [EmailAddress] = []
    @State private var hasLoadedCorrespondents = false

    /// Past searches. A plain value rather than `@State`: it is a wrapper over
    /// `UserDefaults` with nothing of its own to observe.
    private let recents = RecentSearches()

    /// Where results belong depends on the layout, and the search field can
    /// only live in the sidebar — the detail column's navigation bar is not
    /// owned by its own stack when the split view collapses, so a field
    /// attached there simply never renders.
    ///
    /// Compact: the sidebar *is* the screen, so results replace it in place.
    /// Regular: the sidebar stays as navigation and results fill the detail,
    /// which is where a wide layout expects a list.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The resolved theme, for the motion level the server set.
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    /// **The one place the two motion preferences meet.** Read here rather
    /// than at any call site: `Motion` exists so that a view can never honour
    /// the server's setting and forget Reduce Motion, and reading it in ten
    /// views would be ten chances to do exactly that.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// P6's scenes. Read here rather than in the app so the *decision* about
    /// when a window is better than a sheet sits beside the layout that
    /// answers it.
    @Environment(\.openWindow) private var openWindow
    /// False on iPhone, and false on an iPad where the user has turned
    /// multitasking off. Checked rather than assumed: a composer that opens
    /// nowhere is a lost letter.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private let connection: ServerConnection
    private let store: SyncStore
    private let outbox: OutboxSender
    private let blobs: BlobCache
    private let onSignOut: () -> Void

    public init(
        connection: ServerConnection,
        sync: MailSyncService,
        store: SyncStore,
        outbox: OutboxSender,
        actions: MailActions,
        onSignOut: @escaping () -> Void
    ) {
        self.connection = connection
        self.store = store
        self.outbox = outbox
        self.onSignOut = onSignOut
        // Scoped to the server, so signing into another one cannot serve the
        // previous server's attachments out of a shared directory.
        blobs = BlobCache(serverID: connection.host)
        // Owned by the app rather than this view: the live stream and the
        // background refresh have to act on the same sync state the UI shows.
        _sync = State(wrappedValue: sync)
        _actions = State(wrappedValue: actions)
        // One `CalendarStore` over the same container, so there is one SQLite
        // file and no second copy of anything.
        _calendar = State(
            wrappedValue: CalendarService.make(
                client: sync.jmapClient, store: store, serverID: connection.host))
        // Re-reads structure once the server agrees: the sidebar and both
        // pickers read the sync service's mailbox list, and nothing local
        // recomputes it after a label is created or destroyed.
        _labels = State(
            wrappedValue: LabelActions(client: sync.jmapClient) { [sync] in
                await sync.refreshStructure()
            })
        _selectedFeed = State(wrappedValue: .unified(.inbox))
    }

    /// The reader for one thread.
    ///
    /// Built here rather than in the row so it gets the sync service's own
    /// client: one cached session, one concurrency gate.
    @ViewBuilder
    private func reader(for ref: ThreadRef) -> some View {
        if let account = sync.accounts.first(where: { $0.accountKey == ref.accountKey }) {
            ThreadReaderView(
                threadID: ref.threadID,
                accountKey: ref.accountKey,
                accountID: account.accountID,
                subject: ref.subject,
                client: sync.jmapClient,
                store: store,
                sync: sync,
                blobs: blobs,
                actions: actions,
                outbox: outbox,
                credential: connection.credential
            )
        } else {
            // The account went away between the row rendering and the push —
            // a disconnected mailbox, or a sign-out mid-navigation.
            ContentUnavailableView(
                .ui("This mailbox is no longer connected"),
                systemImage: "tray.slash"
            )
        }
    }

    /// Which account a new message is sent from.
    ///
    /// Acts on whatever Shortcuts or Siri asked for.
    ///
    /// Both cases open the UI rather than doing the thing silently. Sending
    /// mail without showing someone what is about to go out, and to whom,
    /// is not a favour — the recipient list is the one part of a message
    /// that cannot be taken back.
    private func performPendingIntent() {
        guard let request = IntentRouter.shared.take() else { return }

        switch request {
        case .compose(let recipient, let subject):
            // **Never over an open composer.** This used to assign
            // unconditionally, and `composing` drives a `.sheet(item:)` — so a
            // Siri "new message to Anna" arriving while somebody was part-way
            // through a reply changed the item's identity, tore the
            // `ComposeView` down and took up to three seconds of un-autosaved
            // typing with it. A dictated intent is worth less than what the
            // person is already writing.
            //
            // The `mailto:` route is unaffected and deliberately so: it rides
            // alongside on `IntentRouter.mailto`, and `ComposeView` picks that
            // up on an open composer and *asks* before replacing anything.
            // That is the surface where the question can be put; here there is
            // no composer of ours to put it in.
            guard composing == nil else { break }

            composing = .new
            prefilled = (recipient, subject)

        case .search(let query):
            searchText = query
            settledSearch = query

        case .thread(let accountKey, let threadID):
            open(accountKey: accountKey, threadID: threadID)
        }
    }

    /// Puts one conversation on screen, from ids alone.
    ///
    /// The subject is read from the cache rather than carried, because the
    /// three routes that arrive here — a notification tap, a Spotlight result
    /// and a Handoff continuation — all hold two ids and nothing else. A
    /// conversation that has been deleted since resolves to nothing and the
    /// selection is left alone, which is honest: opening an empty reader would
    /// say the mail is here.
    private func open(accountKey: String, threadID: String) {
        Task {
            let messages = try? await store.messages(threadID: threadID, accountKey: accountKey)

            guard let messages, messages.isEmpty == false else { return }

            selectedThread = ThreadRef(
                accountKey: accountKey,
                threadID: threadID,
                subject: messages.last?.subject ?? "")
        }
    }

    /// The account whose mailbox is on screen when there is one, so composing
    /// from a specific inbox sends from that address rather than whichever
    /// account happens to sort first.
    private var composeAccount: AccountSnapshot? {
        if case .mailbox(let accountKey, _) = selectedFeed {
            return sync.accounts.first { $0.accountKey == accountKey }
        }

        // The unified inbox has no account of its own, so this is the only
        // place the choice is made — and `sync.accounts` is `Session`'s order,
        // which is alphabetical by account name. Without this the account the
        // user dragged to the top of the accounts screen is ignored by every
        // composer opened from the unified list, from a `mailto:` link and from
        // ⌘N, which is precisely where most messages are written.
        return AccountOrder.shared.ordered(sync.accounts, key: \.accountKey).first
    }

    // New Message on a layout between the phone and the three-column iPad now
    // lives in the list's own header row — `ThreadListView(onCompose:)` — and
    // no longer in that column's navigation bar, which is hidden there so the
    // pane card has a top edge. ⌘N is unaffected: it is bound in the ⌘ menu
    // below, which is on screen whatever the layout.
    //
    // The bare `c` stays on the floating button only, because on iPad the
    // reader is on screen at the same time and already claims bare letters.

    /// The compose button, where every mail app has put it for a decade.
    private var composeButton: some View {
        Button {
            newMessage()
        } label: {
            Label(.ui("New message"), systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 56, height: 56)
        }
        // Prominent glass: it is the one thing on this screen that creates
        // rather than acts on what is already there, and it floats over a
        // scrolling list where a flat fill would sit oddly on top of the rows
        // passing under it.
        .buttonStyle(.glassProminent)
        .clipShape(.circle)
        .padding(.trailing, 20)
        // Sits close to the bottom, where a thumb is, and steps up out of
        // the way only while the undo bar is actually showing rather than
        // reserving that space permanently for a toast that is usually
        // absent.
        .padding(.bottom, isUndoBarShowing ? 84 : 20)
        // Reconciled here rather than read from `\.standardAnimation`. This
        // view *publishes* that value below itself, so its own environment
        // still holds whatever its ancestor set — reading it back would be
        // the one place in the tree where the shell's own motion setting did
        // not apply.
        .animation(Motion.standard(theme.motion, reduced: reduceMotion), value: isUndoBarShowing)
        .accessibilityLabel(Text(.ui("New message")))
        // Gmail's "c", and ⌘N for anyone who expects the Mac convention.
        // Both reach the same button, so neither is a second code path.
        // Two bindings for one action. "c" is what someone arriving from
        // Gmail will press; ⌘N is what someone arriving from the rest of the
        // platform will press, and it is the one that appears in the shortcut
        // overlay when the Command key is held.
        .keyboardShortcut("c", modifiers: [])
        .background {
            Button(.ui("New message")) { newMessage() }
                .keyboardShortcut("n", modifiers: .command)
                .hidden()
        }
    }

    /// Opens a new message where it belongs for this window's width.
    ///
    /// A sheet on anything narrower than three panes, and its own window on a
    /// 13-inch iPad — which is P6's point: a modal sheet over a screen that
    /// size hides the mail you are replying about. Gated on
    /// `supportsMultipleWindows` as well as the layout, so an iPhone (where it
    /// is always false) can never lose the composer to a window it cannot
    /// open.
    private func newMessage() {
        guard composesInOwnWindow, let account = composeAccount else {
            composing = .new
            return
        }

        openWindow(value: ComposeWindowValue(accountKey: account.accountKey, mode: .new))
    }

    /// Whether composing gets a window instead of a sheet.
    ///
    /// **Never by default.** Opening a second window for an ordinary New
    /// Message is a jarring transition — the mail slides away, a fresh scene
    /// animates in, and it reads as having launched a different app rather than
    /// started a message. A window is still available, but only when it is
    /// asked for by name: the ⌘ menu's *Open in new window*.
    private var composesInOwnWindow: Bool { false }

    /// What the ⌘ menu bar can ask this shell to do.
    ///
    /// Rebuilt per redraw, which is free: it is five closures and a list of at
    /// most nine titles. Every closure is the body of a control that already
    /// exists on screen, so nothing here is reachable *only* from the menu.
    private var shellCommands: MailShellCommands {
        MailShellCommands(
            newMessage: { newMessage() },
            searchMail: { isSearchFocused = true },
            openSettings: { isShowingSettings = true },
            openCalendar: calendar.availability.isAvailable
                ? { isShowingCalendar = true } : nil,
            // Empty while the calendar is open, for the same reason the hidden
            // ⌘1…⌘9 buttons stand down: `CalendarView` binds ⌘1…⌘4 to its own
            // view modes, and an absent menu item is the only way to leave
            // those keys to it.
            mailboxes: isShowingCalendar
                ? []
                : numberedFeeds.enumerated().map { index, role in
                    MailShellCommands.Mailbox(
                        number: index + 1,
                        title: role.displayName,
                        select: { selectedFeed = .unified(role) })
                }
        )
    }

    /// The unified rows ⌘1…⌘9 address.
    ///
    /// Capped at nine because there are nine number keys, and taken from the
    /// sidebar's own ordering function so the numbering matches what is on
    /// screen for an account whose Archive is hidden.
    private var numberedFeeds: [MailboxRole] {
        Array(MailboxSidebarView.unifiedRoles(in: sync.mailboxes).prefix(9))
    }

    /// How many panes this window is wide enough for, and everything that
    /// follows from it.
    ///
    /// One value replacing `isSeparated = sizeClass != .compact`, which was a
    /// single boolean answering four different questions and therefore could
    /// not be right about all of them at once. See ``MailLayout``.
    private var layout: MailLayout {
        MailLayout.resolve(width: containerWidth, isCompactSizeClass: sizeClass == .compact)
    }

    private var isUndoBarShowing: Bool {
        actions.pending != nil || actions.failure != nil
    }

    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    /// What to offer under the field. Recomputed per keystroke, which is cheap:
    /// the operator list is nine entries and the addresses are already in
    /// memory.
    private var suggestions: [SearchSuggestion] {
        SearchSuggestions.suggest(
            for: searchText, recents: recents.all(), correspondents: correspondents)
    }

    /// Every address in synced mail, across accounts.
    ///
    /// Deduplicated by address, because the same person turns up in several
    /// accounts and one of them being a different display name is not a reason
    /// to offer them twice.
    private func loadCorrespondents() async {
        guard hasLoadedCorrespondents == false else { return }

        hasLoadedCorrespondents = true

        var byAddress: [String: EmailAddress] = [:]

        for account in sync.accounts {
            let addresses = (try? await store.knownAddresses(accountKey: account.accountKey)) ?? []

            for address in addresses {
                byAddress[address.email.lowercased()] = address
            }
        }

        correspondents = byAddress.values.sorted { $0.email < $1.email }
    }

    /// The sidebar, or the results that replaced it on a narrow screen.
    ///
    /// Compact: the sidebar *is* the screen, so results have to appear where
    /// the field is — putting them one column over would mean typing here and
    /// navigating there.
    @ViewBuilder
    private var sidebarContent: some View {
        if isSearching, layout.placesSearchResultsInSidebar {
            SearchResultsView(
                raw: settledSearch, sync: sync, actions: actions, outbox: outbox,
                selection: $selectedThread, queryText: $searchText)
        } else {
            // Nil everywhere but the resident sidebar, so the compose control
            // is never drawn twice. See ``usesSidebarCompose``.
            let compose: (() -> Void)? = usesSidebarCompose ? { newMessage() } : nil

            MailboxSidebarView(
                sync: sync, outbox: outbox, labelActions: labels, actions: actions,
                calendar: calendar,
                openCalendar: { isShowingCalendar = true },
                compose: compose,
                selection: $selectedFeed)
        }
    }

    /// Whether New Message lives at the top of the sidebar.
    ///
    /// Only where the sidebar is a resident column. In `.dual` it is a floating
    /// overlay that goes away the moment it is used, so a compose button there
    /// would be one dismissal away from being invisible; on a phone the
    /// floating button already has the job.
    ///
    /// The three compose entry points — this, the list toolbar item and the
    /// floating button — are alternatives and never two at once: two New
    /// Message controls on one screen is one too many, and both would answer
    /// ⌘N.
    private var usesSidebarCompose: Bool { layout.mode == .triple }

    /// The list actually on screen, which is the selected mailbox narrowed by
    /// whatever category is chosen.
    ///
    /// Resolved here rather than by writing a category feed into
    /// ``selectedFeed``, because the sidebar's `List(selection:)` is bound to
    /// that and a value it has no row for deselects everything — the Inbox row
    /// would stop looking selected the moment a tab was picked.
    ///
    /// Only the unified inbox narrows. A single account's inbox mailbox is
    /// deliberately left alone: the category filter is cross-account by
    /// construction, so offering it there would be a control that quietly
    /// changes which accounts the list covers.
    private var listFeed: FeedID? {
        guard let selectedFeed else { return nil }
        guard selectedFeed.isUnifiedInbox, let inboxCategory else { return selectedFeed }

        return .category(inboxCategory)
    }

    /// Whether the category control is drawn at all.
    ///
    /// **Both halves, and the second is the one that matters.** A plMail
    /// instance whose classifier has never run answers every category query
    /// with nothing, and five permanently empty tabs above a working inbox
    /// reads as mail having gone missing rather than as a feature this server
    /// does not have. ``MailSyncService/hasCategories`` starts false, so the
    /// control cannot flicker in on launch and out again.
    private var offersCategories: Bool {
        selectedFeed?.isUnifiedInbox == true && sync.hasCategories
    }

    /// The middle column: results while searching, otherwise the mailbox.
    @ViewBuilder
    private var listContent: some View {
        if isSearching, layout.placesSearchResultsInSidebar == false {
            SearchResultsView(
                raw: settledSearch, sync: sync, actions: actions, outbox: outbox,
                selection: $selectedThread, queryText: $searchText,
                // The middle column hides its navigation bar on a separated
                // layout, so the results list carries the only visible way back
                // to the mailboxes. See `ThreadListView(onToggleSidebar:)`.
                onToggleSidebar: { columns = columns == .all ? .doubleColumn : .all })
        } else if let listFeed {
            // `.inline`, not large: a large title silently fails to render
            // when this column is restored rather than pushed, which is
            // exactly the cold-launch path, and an untitled list reads as a
            // bug.
            ThreadListView(
                feed: listFeed, sync: sync, actions: actions, labelActions: labels,
                outbox: outbox,
                selection: $selectedThread, isSelectionActive: $isSelectionActive,
                categorySelection: offersCategories ? $inboxCategory : nil,
                // The list draws its own header bar on a separated layout, so
                // the two controls the shell used to hang in that column's
                // navigation bar are handed down instead. Both stay the
                // shell's decisions: the split view's visibility is state here,
                // and New Message is the same closure the sidebar and the
                // floating button call — see ``usesSidebarCompose``.
                onToggleSidebar: { columns = columns == .all ? .doubleColumn : .all },
                onCompose: layout.usesFloatingCompose == false && usesSidebarCompose == false
                    ? { newMessage() } : nil
            )
            // Identity per feed. The list builds its `@Query` in `init`, so a
            // reused view keeps the descriptor — and the category binding — it
            // was first created with. Leaving the inbox and coming back gave a
            // view still holding the nil binding it had while another mailbox
            // was selected, which is why the tabs did not return until the app
            // was force-quit.
            .id(listFeed)
        } else {
            ContentUnavailableView(
                .ui("Pick a mailbox"), systemImage: "tray.2",
                description: Text(.ui("Choose a list from the sidebar.")))
        }
    }

    /// A message is open and filling the screen, rather than sitting in its
    /// own column beside the list.
    private var isReadingOnPhone: Bool {
        sizeClass == .compact && selectedThread != nil
    }

    /// Drives the phone's push, and is inert on iPad.
    private var compactReader: Binding<ThreadRef?> {
        sizeClass == .compact ? $selectedThread : .constant(nil)
    }

    /// The phone's shell, and the one the app has always used.
    private var splitShell: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebarContent
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(.ui("Search mail"))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .searchSuggestions {
                    SearchSuggestionsView(suggestions: suggestions) { completion, shouldSubmit in
                        searchText = completion

                        // A finished suggestion is a search; a half one — the
                        // `from:` that still wants a name — leaves the caret
                        // where the value goes and runs nothing.
                        if shouldSubmit {
                            settledSearch = completion
                            recents.record(completion)
                        }
                    }
                }
                // The moment a search is deliberately run, as opposed to the
                // debounce firing mid-word. Recording every settled keystroke
                // would fill the history with "inv", "invo", "invoi".
                .onSubmit(of: .search) { recents.record(searchText) }
                // Attached where the field is, not on the split view: the
                // binding resolves against the nearest enclosing `searchable`,
                // and one declared a column away simply never binds.
                .searchFocused($isSearchFocused)
                .navigationTitle(Text(verbatim: "plMail"))
                // Compact only. Here the sidebar *is* the screen, so pushing
                // `CalendarView` into its stack gives the calendar the whole
                // width — and `CalendarView` deliberately carries no
                // `NavigationStack` of its own precisely so it can be a column.
                //
                // On a separated layout the same push would draw the calendar
                // into the sidebar's 220–320pt, which is narrower than a phone:
                // its three-column board, standing inspector and year grid
                // would all collapse to their smallest form on the largest
                // screen. That case is covered by the full-screen cover below.
                .navigationDestination(
                    isPresented: Binding(
                        get: { isShowingCalendar && layout.isSeparated == false },
                        set: { isShowingCalendar = $0 })
                ) {
                    CalendarView(service: calendar)
                }
                .toolbar {
                    // The calendar is reached from its sidebar row, not from
                    // here. The sidebar is the root column on compact and is
                    // permanently visible on iPad, so a toolbar button would be
                    // a second control for one destination — and two controls
                    // for one place is how they drift apart.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(.ui("Settings"), systemImage: "gearshape") {
                            isShowingSettings = true
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                // **Flat, never a card.** The list and the reader are cards;
                // the sidebar sits directly on the window colour, which is
                // what lets a selected row's pill run out to its leading edge
                // and stops the mailboxes carrying the same visual weight as
                // the mail. It still paints the window per column and hides
                // the bar background — see ``SwiftUI/View/sidebarPane(isResident:)``.
                //
                // Only where the sidebar is a resident column. In `.dual` the
                // system presents it as a floating overlay with its own panel
                // material, and chrome of ours inside that fights the panel it
                // is drawn on.
                .sidebarPane(isResident: layout.mode == .triple)
        } content: {
            listContent
                // The push that a collapsed split view would normally do for
                // us. It does that only for a `List(selection:)`, and these
                // rows are buttons — they have to be, so a tap can mean
                // "add to the selection" while multi-select is on. Without
                // this, tapping a row on a phone marked it read and then sat
                // there, which is about the worst possible failure: it looks
                // like the app noticed you and decided not to help.
                //
                // Bound to nothing at regular width, where the reader has its
                // own column and pushing would put the message in the middle
                // of the list.
                .navigationDestination(item: compactReader) { thread in
                    // Identity per conversation. `ThreadReaderView` starts its
                    // load from `.task`, which runs once per view lifetime — so
                    // without this SwiftUI reuses the same reader for the next
                    // conversation, the task never runs again, and its `@State`
                    // keeps the previous thread's messages while the title
                    // (which comes from the reference, not the loader) updates.
                    // The symptom is a second message that never replaces the
                    // first.
                    reader(for: thread)
                        .id(thread)
                }
                .mailPane(isSeparated: layout.isSeparated, column: .middle)
                // Wider than the system default, which is sized for a list of
                // short titles. A conversation row carries an avatar, a
                // subject and a snippet, and at the default width the subject
                // truncates on almost every message. The minimum matters more
                // than the ideal: when the detail column is hungry the split
                // view hands this one its minimum, so a generous ideal alone
                // changes nothing.
                //
                // The inset comes out of this width, so it is a little wider
                // than it was before the panes were separated.
                // No compose item in this column's toolbar any more. The
                // layouts that put New Message here are exactly the separated
                // ones, and those hide the navigation bar so the card's top
                // edge is the card's — so the button is passed to
                // `ThreadListView` and drawn in the header row inside the pane.
                // Still exactly one control per layout: floating on a phone, in
                // the sidebar on three columns, in the list header between.
                .navigationSplitViewColumnWidth(min: 396, ideal: 440, max: 540)
        } detail: {
            // Its own stack so the reader can push further — an attachment
            // preview, a sender's other mail — without disturbing the columns
            // to its left.
            NavigationStack {
                if let selectedThread {
                    reader(for: selectedThread)
                        .id(selectedThread)
                } else {
                    ContentUnavailableView(
                        .ui("No conversation selected"), systemImage: "envelope",
                        description: Text(.ui("Pick a message to read it here.")))
                }
            }
            .mailPane(isSeparated: layout.isSeparated, column: .trailing)
        }
        .navigationSplitViewStyle(.balanced)
        // Zero-sized and hidden; it exists only to reach the split view
        // controller and switch its column separator off. See the type.
        .background {
            if layout.hidesColumnSeparator { SplitSeparatorHider().frame(width: 0, height: 0) }
        }
    }

    /// The window's own header, spanning every column.
    ///
    /// **The search field is centred in the window, not in a column.** A
    /// `.searchable` field belongs to whichever navigation bar encloses it, so
    /// it can only ever sit above one pane; the design puts it across the whole
    /// width, which is why this is a plain field rather than the system one.
    /// What is lost with it — the search bar's own suggestion popover — is
    /// rebuilt below the field, and the token grammar is unchanged.
    private var globalHeader: some View {
        HStack(spacing: 8) {
            Button {
                // **Never to nothing.** This used to hide the sidebar
                // outright, which took away every destination and left a
                // button whose only job was to put them back. It collapses to
                // the icon rail instead — the same rail a narrow window gets —
                // so both states are usable and the toggle is a width choice
                // rather than an on/off.
                sidebarIsRailed = isRailed == false
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.inkSoft.color)
            .disabled(isCalendarDocked)
            .accessibilityLabel(
                isRailed
                    ? Text(.ui("Show mailbox names")) : Text(.ui("Collapse the sidebar to icons"))
            )

            HStack(spacing: 8) {
                // The mark, not the word. The design puts the seven-stroke
                // glyph here and nothing else — a wordmark beside it would say
                // the app's name twice to somebody who has already opened it.
                PLMark(size: 26)

                // **The change stream, which is what the web's dot means.**
                // It used to show whether the last *poll* had succeeded, and
                // that stays green on a server whose event stream has been
                // refused for an hour — so the one thing the dot could tell
                // you was the one thing it did not.
                //
                // Three states rather than two: something is wrong, live, or
                // simply not live. The middle one is the only good news, and a
                // grey dot is not a warning — the app still syncs when it
                // checks.
                Circle()
                    .fill(liveDot.colour)
                    .frame(width: 6, height: 6)
                    .help(Text(liveDot.label))
                    .accessibilityLabel(Text(liveDot.label))
            }
            .frame(width: 196, alignment: .leading)

            headerSearchField
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)

            Button {
                Task { if let listFeed { await sync.refresh(feed: listFeed) } }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.inkSoft.color)
            .accessibilityLabel(Text(.ui("Check now")))

            if calendar.availability.isAvailable {
                // The three-way pane switch. Tinted while the calendar is
                // docked, because a toggle that looks the same in both states
                // says nothing about what it just did.
                Button {
                    isCalendarDocked.toggle()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 15))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isCalendarDocked ? palette.accentSoft.color : .clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isCalendarDocked
                        ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(palette.inkSoft.color)
                )
                .accessibilityLabel(Text(.ui("Dock the calendar")))
                .accessibilityAddTraits(isCalendarDocked ? [.isButton, .isSelected] : .isButton)

                Button {
                    isShowingCalendar = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.inkSoft.color)
                .accessibilityLabel(Text(.ui("Calendar")))
            }

        }
        .frame(height: 52)
        .padding(.horizontal, 12)
    }

    /// What the header's dot says, and the sentence that says it.
    ///
    /// The colour is never the only carrier: the same three states are in the
    /// accessibility label and in the pointer's tooltip, because a dot six
    /// points across is not a control anybody can interrogate.
    private var liveDot: (colour: Color, label: LocalizedStringResource) {
        if sync.offlineState != .current {
            return (palette.warning.color, .ui("Can't reach your server"))
        }

        return sync.isLive
            ? (palette.success.color, .ui("Live — changes arrive as they happen"))
            : (palette.inkFaint.color, .ui("Not live — mail arrives when the app checks"))
    }

    /// The header's search field.
    private var headerSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.inkFaint.color)

            TextField(text: $searchText) { Text(.ui("Search mail")) }
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(palette.ink.color)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .onSubmit {
                    settledSearch = searchText
                    recents.record(searchText)
                }

            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                    settledSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.inkFaint.color)
                .accessibilityLabel(Text(.ui("Clear search")))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(
            palette.sunken.color,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Which shell is on screen.
    ///
    /// A `NavigationSplitView` collapses to a stack on a phone, which is
    /// exactly what a phone wants and why it is kept there. It cannot,
    /// however, express the design's regular layout: a header spanning every
    /// column with the search field centred in the *window*, a sidebar drawn
    /// straight onto the window with no chrome of its own, and the list and
    /// reader sharing **one** card divided by a hairline. A split view owns
    /// its own bars and column separators and insists each column is a peer,
    /// so the regular layout is built by hand instead.
    @ViewBuilder
    private var shell: some View {
        if layout.isSeparated {
            regularShell
        } else {
            splitShell
        }
    }

    /// The hand-built regular layout: header, then sidebar beside one card.
    private var regularShell: some View {
        VStack(spacing: PanelStyle.inset) {
            globalHeader

            HStack(spacing: PanelStyle.inset) {
                if isRailed {
                    // Icons only: at 56pt the sidebar's words do not fit, and a
                    // column of truncated names is worse than a column of marks.
                    SidebarRail(
                        sync: sync,
                        compose: { newMessage() },
                        openLabels: { isShowingLabelManager = true },
                        openSettings: { isShowingSettings = true },
                        selection: $selectedFeed)
                } else if columns != .detailOnly {
                    sidebarContent
                        .frame(width: Self.sidebarWidth)
                }

                paneCard

                if isCalendarDocked, calendar.availability.isAvailable {
                    calendarCard
                }
            }
        }
        .padding(PanelStyle.outerMargin)
        .background(palette.window.color.ignoresSafeArea())
    }

    /// The list and the reader, in **one** card.
    ///
    /// Not two cards with a gutter between them: the design draws a single
    /// surface divided by a one-pixel rule, and two cards read as two
    /// documents rather than one mailbox. The card is the only thing in the
    /// regular layout that carries a border or a shadow — the sidebar has
    /// neither, which is what makes it read as the ground the card sits on.
    private var paneCard: some View {
        HStack(spacing: 0) {
            NavigationStack {
                listContent
            }
            // Fixed beside a reader, elastic beside the calendar: with the
            // reader gone the list is the only thing that can use the width.
            .frame(width: isCalendarDocked ? nil : listWidth)
            .frame(maxWidth: isCalendarDocked ? .infinity : listWidth)

            if isCalendarDocked == false {
                Rectangle()
                    .fill(palette.line.color)
                    .frame(width: 1)

                NavigationStack {
                    if let selectedThread {
                        reader(for: selectedThread)
                            .id(selectedThread)
                    } else {
                        ContentUnavailableView(
                            .ui("No conversation selected"), systemImage: "envelope",
                            description: Text(.ui("Pick a message to read it here.")))
                    }
                }
            }
        }
        .paneSurface(palette)
    }

    /// The calendar, docked as a card of its own beside the mail.
    ///
    /// **Its own card, not a third column inside the mail's.** The design draws
    /// two separate surfaces with a gap between them, and that gap is what says
    /// these are two things rather than one screen split three ways — the mail
    /// keeps its list and its reader, the calendar keeps its day.
    private var calendarCard: some View {
        NavigationStack {
            DockedCalendarView(
                service: calendar,
                expand: { isShowingCalendar = true },
                dismiss: { isCalendarDocked = false })
        }
        .frame(width: Self.calendarWidth)
        .paneSurface(palette)
    }

    /// The sidebar's width, the list's, and the docked calendar's, as the
    /// design draws them.
    private static let calendarWidth: CGFloat = 392

    /// Whether the reader's own choice overrides the width's. Nil follows the
    /// layout, which is what a window that has never been told otherwise does.
    @State private var sidebarIsRailed: Bool?

    /// The docked calendar asks for the rail for the same reason a narrow
    /// window does: three panes and a named sidebar do not fit beside each
    /// other, and the sidebar is the one whose words can be spared. That one
    /// is not negotiable — with a calendar docked there is genuinely no room —
    /// so it wins over the toggle rather than being overridden by it.
    private var isRailed: Bool {
        isCalendarDocked || (sidebarIsRailed ?? layout.usesSidebarRail)
    }

    private var listWidth: CGFloat {
        // The narrow width whenever the sidebar is showing names on a window
        // that would not normally carry them — the reader has to come from
        // somewhere, and it is the pane with the least to give.
        isRailed && layout.mode == .triple ? layout.listWidth : min(layout.listWidth, 320)
    }

    private static let sidebarWidth: CGFloat = 224

    /// The palette for the appearance actually on screen.
    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    public var body: some View {
        // Three columns — mailboxes, conversations, message — which is the
        // web UI's three regions and what an iPad has room for. On iPhone the
        // split view collapses the same three into one stack, so `Back`
        // genuinely means back and no second layout has to be maintained.
        shell
            // Over the whole split view rather than over the list column, so on a
            // tablet it sits at the window's right edge instead of floating in the
            // middle against a column divider. Collapsed on iPhone the two are the
            // same place.
            .overlay(alignment: .bottomTrailing) {
                // The bulk action bar occupies this corner while a selection is
                // up, and composing is not something anyone reaches for
                // mid-selection anyway.
                //
                // Hidden over an open message on a phone too: the reader puts
                // Reply, Reply all and Forward along the bottom, and a floating
                // button there sits on top of Forward. The reader has its own
                // reply actions, so nothing is lost by standing aside.
                // And only where the layout still wants a floating button at all:
                // above phone width it is in the list toolbar, and below ~400pt —
                // a Slide Over panel — a 56pt circle with a 20pt inset is a
                // quarter of the window sitting on top of the mail.
                if isSelectionActive == false, isReadingOnPhone == false,
                    layout.usesFloatingCompose
                {
                    composeButton
                }
            }
            // The separated counterpart to the sidebar push above. The calendar
            // earns the whole window here rather than a 260pt column: a full-screen
            // cover is what lets its board, standing inspector and rail all appear
            // on a 13-inch iPad. `CalendarScreen` rather than `CalendarView`,
            // because a cover has no stack of its own to supply.
            .fullScreenCover(
                isPresented: Binding(
                    get: { isShowingCalendar && layout.isSeparated },
                    set: { isShowingCalendar = $0 })
            ) {
                // Not `CalendarScreen`: a full-screen cover supplies no back
                // button, and `CalendarView`'s own toolbar has none either — it
                // relied on the pushed presentation for the way out. The way out
                // is handed in instead, and `CalendarBar` draws it as the design's
                // collapse mark at the end of the calendar's own bar rather than
                // as a Done button floating above the card.
                NavigationStack {
                    CalendarView(service: calendar) { isShowingCalendar = false }
                }
                // A cover is its own hosting context too, and the calendar's
                // card is drawn from the palette — so without this it asked for
                // the system's appearance rather than the theme's.
                .themedSheet(theme, reduceMotion: reduceMotion)
            }
            // Measured rather than classified. A size class reports two widths and
            // Stage Manager produces every width, so this is the only honest input
            // to the layout decision. See `MailLayout`.
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                containerWidth = $0
            }
            // Follows the mode, not every resize: within a mode the visibility is
            // whatever the user last chose, so ⌘⌃S is not undone by the next
            // redraw.
            .onChange(of: layout.mode, initial: true) { _, _ in
                columns = layout.preferredColumnVisibility
            }
            // Read by every pane below, including the `ThreadListView` that
            // `SearchResultsView` builds — which this package cannot reach with an
            // initialiser argument.
            .environment(\.mailLayout, layout)
            .shortcuts {
                // Every one of these has a visible equivalent: the sidebar rows,
                // the sidebar toggle in the split view's own chrome, the search
                // field, and the Settings toolbar button. They are accelerators,
                // not the only route.
                HiddenShortcut(
                    title: .ui("Search mail"), key: "f", modifiers: [.command, .option]
                ) {
                    isSearchFocused = true
                }

                HiddenShortcut(
                    title: .ui("Show or hide the sidebar"), key: "s",
                    modifiers: [
                        .command, .control,
                    ]
                ) {
                    columns = columns == .all ? .doubleColumn : .all
                }

                HiddenShortcut(title: .ui("Settings"), key: ",") { isShowingSettings = true }

                // ⌘1…⌘9 over exactly the rows the sidebar draws, in the order it
                // draws them — numbered from the same function, so ⌘3 cannot mean
                // Drafts on the keyboard and Sent on screen.
                //
                // Withdrawn while the calendar is open, because `CalendarView`
                // binds ⌘1…⌘4 to its own view modes. One key with two meanings is
                // not a shortcut, it is a guess.
                if isShowingCalendar == false {
                    ForEach(Array(numberedFeeds.enumerated()), id: \.offset) { index, role in
                        HiddenShortcut(
                            title: .ui("Go to mailbox \(index + 1)"),
                            key: KeyEquivalent(Character("\(index + 1)"))
                        ) {
                            selectedFeed = .unified(role)
                        }
                    }
                }
            }
            // What the ⌘ menu bar drives. A scene value rather than a focused
            // value: the menu has to work when focus is in the search field, in
            // the list or nowhere at all, and `focusedValue` publishes only while
            // the modified view itself holds focus.
            //
            // Every closure here is the same one a control or a hidden shortcut in
            // this file already calls. The menu is a second *route*, never a
            // second implementation — see ``MailShellCommands``.
            .focusedSceneValue(\.mailShellCommands, shellCommands)
            // Once, when the screen exists and again if the account list changes.
            // **Never on a timer**: the calendar surface has no `/changes` and no
            // push — `state` is the literal string "fixed" — and this audience runs
            // the server on a Raspberry Pi with one PHP worker pool.
            .task(id: sync.accounts.count) { await calendar.probeAvailability() }
            // Shortcuts and Siri. The router holds the request because an intent
            // is built by the system and cannot be handed a reference to any of
            // this; here is where it gets picked up.
            .onChange(of: IntentRouter.shared.pending) { _, _ in performPendingIntent() }
            .task { performPendingIntent() }
            .task(id: searchText) {
                // The first keystroke is the signal that this session will search
                // at all, and the addresses are wanted before the debounce is up.
                if searchText.isEmpty == false { await loadCorrespondents() }

                // 350ms: long enough that typing a word is one query rather than
                // five, short enough not to feel laggy.
                try? await Task.sleep(for: .milliseconds(350))

                guard Task.isCancelled == false else { return }

                let abandoned = settledSearch
                settledSearch = searchText

                if searchText.isEmpty, abandoned.isEmpty == false {
                    await sync.discardSearch(feed: .search(abandoned))
                }
            }
            // Switching mailbox leaves the reader showing a thread that is no
            // longer in the list beside it — on a wide layout the two columns
            // would visibly disagree.
            .onChange(of: selectedFeed) { _, _ in
                selectedThread = nil
                // Leaving the inbox drops the narrowing with it. Keeping it would
                // put the user back on Promotions the next time they pressed
                // Inbox — a filter they set once and cannot see from Sent.
                inboxCategory = nil
            }
            // Keyed on the *effective* feed, not the selected mailbox: picking a
            // category changes which list is on screen, and a task that ignored
            // that would leave the live-update stream attached to the unnarrowed
            // inbox while a tab was showing.
            // Whether the server classifies mail is a fact about the cache, not
            // about this screen — but the tabs are drawn from it, so it is re-read
            // whenever the visible feed changes rather than once at launch.
            .task(id: selectedFeed) { await sync.refreshCategoryAvailability() }
            .task(id: listFeed) {
                guard let listFeed else { return }

                await sync.start(feed: listFeed)

                // Only once a list is actually on screen, and torn down as soon as
                // it is not — each stream holds a server worker for its life.
                await sync.beginLiveUpdates(feed: listFeed)
            }
            .sheet(item: $composing) { kind in
                if let account = composeAccount {
                    ComposeView(
                        kind: kind,
                        accountKey: account.accountKey,
                        accountID: account.accountID,
                        client: sync.jmapClient,
                        store: store,
                        outbox: outbox,
                        prefill: prefilled
                    )
                    // **Injected explicitly.** A sheet is presented in its own
                    // hosting context, and the environment set further down this
                    // modifier chain does not reliably reach it — so the composer
                    // came up on the placeholder theme while the mail behind it was
                    // themed, which reads as opening a different app.
                    .themedSheet(theme, reduceMotion: reduceMotion)
                    // A page, not the stock form sheet. The form sheet is
                    // sized for a settings pane: on an iPad it left the body
                    // field a few lines tall with the formatting bar half off
                    // the bottom edge, and there was nowhere for a software
                    // keyboard to go. (`.fitted` was tried in between and is
                    // worse still — a `Form` reports no intrinsic height, so
                    // the sheet collapses to its toolbar.)
                    .presentationSizing(.page)
                }
            }
            .onChange(of: composing) { _, kind in
                // Consumed when the sheet closes, so opening the composer by hand
                // afterwards does not resurrect a dictated recipient.
                if kind == nil { prefilled = nil }
            }
            .sheet(isPresented: $isShowingLabelManager) {
                LabelManagerView(sync: sync, labels: labels)
                    .themedSheet(theme, reduceMotion: reduceMotion)
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(
                    connection: connection,
                    sync: sync,
                    store: store,
                    onSignOut: onSignOut
                )
                .themedSheet(theme, reduceMotion: reduceMotion)
            }
            // Applied here as well as at the app's root, which owns the
            // `AppearanceSettings` this view only reads. The root is in another
            // module and another agent's file; this shell is the ancestor of every
            // list, reader, sidebar and toast in the app, so putting it here means
            // Reduce Motion is honoured whether or not the root remembered — and
            // recomputing the same three animations from the same two inputs is
            // idempotent, so doing it twice costs a comparison.
            .resolvedMotion(theme.motion, reduced: reduceMotion)
    }
}

// MARK: - Reaching one conversation from outside the view tree

extension ThreadRef {
    /// Rebuilt from the two ids an outside caller has.
    ///
    /// A notification tap, a Spotlight result and a Handoff continuation all
    /// arrive holding an account key and a thread id and nothing else — a
    /// scene value has to survive being written to disk and read back after a
    /// relaunch, so it cannot carry a `StoredThread` and must not carry a
    /// snapshot of one either. The subject is cosmetic here: the reader loads
    /// the conversation for itself, and an empty header for one frame is a
    /// smaller lie than a stale one.
    init(accountKey: String, threadID: String, subject: String) {
        self.accountKey = accountKey
        self.threadID = threadID
        self.subject = subject.isEmpty ? "(no subject)" : subject
    }
}

// MARK: - Scene values

/// One conversation, as a second window.
///
/// Ids and a subject, `Codable` because the system persists a scene value and
/// hands it back after a relaunch. Anything richer would be restored stale;
/// ids re-resolve against whatever the cache holds now, or resolve to nothing
/// and the window says so.
public struct ThreadWindowValue: Codable, Hashable, Sendable {
    public var accountKey: String
    public var threadID: String
    /// Shown in the window's title while the thread loads, so a second window
    /// is identifiable in the app switcher rather than being one of two
    /// identically blank cards.
    public var subject: String

    public init(accountKey: String, threadID: String, subject: String) {
        self.accountKey = accountKey
        self.threadID = threadID
        self.subject = subject
    }
}

/// A composer, as its own window.
///
/// The message it starts from is named by id rather than carried, for the same
/// reason as ``ThreadWindowValue``: `ComposeModel.Kind` carries a
/// `MessageSnapshot`, and a snapshot restored from disk a day later is a copy
/// of a message that may since have been deleted. The window resolves the id
/// against the store when it opens.
public struct ComposeWindowValue: Codable, Hashable, Sendable {
    /// What the composer is for. Deliberately not `ComposeModel.Kind`: that
    /// type is not `Codable` and should not become so just to satisfy a window.
    public enum Mode: String, Codable, Hashable, Sendable {
        case new
        case reply
        case replyAll
        case forward
        case editDraft
    }

    public var accountKey: String
    public var mode: Mode
    /// The message being replied to, forwarded or resumed. Nil only for
    /// ``Mode/new``.
    public var emailID: String?

    public init(accountKey: String, mode: Mode, emailID: String? = nil) {
        self.accountKey = accountKey
        self.mode = mode
        self.emailID = emailID
    }
}

// MARK: - What the menu bar drives

/// The shell's half of the ⌘ menu bar.
///
/// Closures, published by ``MailView`` itself, so a menu item runs **the same
/// function** the on-screen control and the hidden ⌘ twin already run. A menu
/// that re-implemented "go to mailbox 3" would be a second answer to a
/// question the sidebar already answers, and the two would disagree the first
/// time an account hid its Archive.
///
/// Not `Equatable` and not `Sendable`: it is closures over view state, read on
/// the main actor by the command builder and by nothing else.
public struct MailShellCommands: Equatable {
    /// **Compared on what the menu draws, never on the closures.**
    ///
    /// `focusedSceneValue` republishes whenever the value differs, and a
    /// closure is never equal to another closure — so a struct of closures
    /// reports a change on *every* body evaluation, and iPadOS answers each one
    /// by rebuilding the main menu. `UIKitMainMenuController.buildMenu` is
    /// heavyweight, and rebuilding it continuously saturates the main thread:
    /// touches stop arriving, and any `MainActor` work queued behind it — the
    /// fetch that would finish a conversation, for instance — never runs, so
    /// the spinner turns forever. Measured on a device; it was the cause of the
    /// reader locking the interface entirely.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasCalendar == rhs.hasCalendar
            && lhs.mailboxes.map(\.number) == rhs.mailboxes.map(\.number)
            && lhs.mailboxes.map(\.title) == rhs.mailboxes.map(\.title)
    }

    /// Whether the calendar item is offered at all.
    private var hasCalendar: Bool { openCalendar != nil }

    /// One numbered mailbox row, exactly as the sidebar draws it.
    public struct Mailbox: Identifiable {
        /// 1…9. The key equivalent and the position in the sidebar are the
        /// same number by construction, so ⌘3 cannot mean Drafts on the
        /// keyboard and Sent on screen.
        public var number: Int
        public var title: String
        public var select: () -> Void

        public var id: Int { number }

        public init(number: Int, title: String, select: @escaping () -> Void) {
            self.number = number
            self.title = title
            self.select = select
        }
    }

    public var newMessage: () -> Void
    public var searchMail: () -> Void
    public var openSettings: () -> Void
    /// Nil on a server without the calendar extension, which is what takes the
    /// item out of the menu rather than greying it out.
    public var openCalendar: (() -> Void)?
    public var mailboxes: [Mailbox]

    public init(
        newMessage: @escaping () -> Void,
        searchMail: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openCalendar: (() -> Void)? = nil,
        mailboxes: [Mailbox] = []
    ) {
        self.newMessage = newMessage
        self.searchMail = searchMail
        self.openSettings = openSettings
        self.openCalendar = openCalendar
        self.mailboxes = mailboxes
    }
}

/// The reader's half of the ⌘ menu bar.
///
/// Published by ``ThreadReaderView`` while a conversation is on screen, and
/// nil otherwise — which is what greys the whole Message menu out rather than
/// leaving items that would act on nothing. Every closure is the body of a
/// toolbar or More-menu button in that view; the bare-letter keys stay on
/// those controls and are deliberately **not** repeated here.
public struct MailMessageCommands: Equatable {
    /// What this set of commands was built for — the conversation, its newest
    /// message, and the state the menu titles depend on.
    ///
    /// Equality is decided on this alone. Comparing the closures is impossible
    /// and comparing nothing would leave a stale closure acting on a message
    /// that has since been replaced, so the identity has to move whenever the
    /// thing the closures captured moves. See ``MailShellCommands`` for why
    /// equality matters here at all.
    public var identity: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
            && lhs.isFlagged == rhs.isFlagged
            && (lhs.reply == nil) == (rhs.reply == nil)
            && (lhs.replyAll == nil) == (rhs.replyAll == nil)
            && (lhs.forward == nil) == (rhs.forward == nil)
            && (lhs.openInNewWindow == nil) == (rhs.openInNewWindow == nil)
    }

    /// Nil when the thread has no message to reply to yet — it is still
    /// loading, or the account went away underneath it.
    public var reply: (() -> Void)?
    public var replyAll: (() -> Void)?
    public var forward: (() -> Void)?
    public var archive: () -> Void
    public var trash: () -> Void
    public var markUnread: () -> Void
    /// Whether the conversation is starred, so the item can say which way it
    /// is about to go instead of offering "Star" over a starred thread.
    public var isFlagged: Bool
    public var toggleFlagged: () -> Void
    public var pickLabels: () -> Void
    public var snooze: () -> Void
    public var find: () -> Void
    /// Nil where the system cannot open a second window — an iPhone, or an
    /// iPad with multitasking off.
    public var openInNewWindow: (() -> Void)?

    public init(
        identity: String = "",
        reply: (() -> Void)? = nil,
        replyAll: (() -> Void)? = nil,
        forward: (() -> Void)? = nil,
        archive: @escaping () -> Void,
        trash: @escaping () -> Void,
        markUnread: @escaping () -> Void,
        isFlagged: Bool,
        toggleFlagged: @escaping () -> Void,
        pickLabels: @escaping () -> Void,
        snooze: @escaping () -> Void,
        find: @escaping () -> Void,
        openInNewWindow: (() -> Void)? = nil
    ) {
        self.identity = identity
        self.reply = reply
        self.replyAll = replyAll
        self.forward = forward
        self.archive = archive
        self.trash = trash
        self.markUnread = markUnread
        self.isFlagged = isFlagged
        self.toggleFlagged = toggleFlagged
        self.pickLabels = pickLabels
        self.snooze = snooze
        self.find = find
        self.openInNewWindow = openInNewWindow
    }
}

extension FocusedValues {
    /// Published with `focusedSceneValue`, not `focusedValue`.
    ///
    /// A focused *value* exists only while the view that published it holds
    /// keyboard focus, which on this screen is usually the search field or
    /// nothing at all — the menu would grey itself out for no reason a person
    /// could see. A scene value is published for as long as the scene is
    /// frontmost, which is the question the menu is actually asking.
    @Entry public var mailShellCommands: MailShellCommands?
    @Entry public var mailMessageCommands: MailMessageCommands?
}

// MARK: - The menu bar itself

/// P2's File/Edit/Message/View table, attached to the `WindowGroup`.
///
/// Lives here rather than in `App/` for one reason: every title has to be
/// localised through `Localization.ui(_:)`, which names this package's own
/// bundle explicitly. A `Text("New message")` written in the app target
/// resolves against `Bundle.main`, misses, and ships the English literal —
/// which is exactly how Android shipped an untranslated menu.
///
/// **Nothing here implements an action.** Each item calls a closure published
/// by the view that owns the control doing the same job, so the menu is a
/// route rather than a second code path, and an item whose closure is absent
/// is disabled rather than silently doing nothing.
public struct MailCommands: Commands {
    @FocusedValue(\.mailShellCommands) private var shell: MailShellCommands?
    @FocusedValue(\.mailMessageCommands) private var message: MailMessageCommands?
    @Environment(\.openWindow) private var openWindow

    /// The scene id of the main mail window, so File ▸ New Window opens
    /// another one of those rather than guessing.
    public static let mailWindowID = "mail"

    public init() {}

    public var body: some Commands {
        // Replaces the system's own "New…" group: leaving it would put an
        // inert New Item above a New Message that works.
        CommandGroup(replacing: .newItem) {
            Button(.ui("New message")) { shell?.newMessage() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(shell == nil)

            Button(.ui("New window")) { openWindow(id: Self.mailWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // In the Edit menu, after Cut/Copy/Paste, which is where a Mac user
        // looks for Find.
        CommandGroup(after: .pasteboard) {
            Divider()

            Button(.ui("Find in conversation")) { message?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(message == nil)

            Button(.ui("Search mail")) { shell?.searchMail() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(shell == nil)
        }

        CommandMenu(Text(.ui("Message"))) {
            Button(.ui("Reply")) { message?.reply?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(message?.reply == nil)

            Button(.ui("Reply all")) { message?.replyAll?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(message?.replyAll == nil)

            Button(.ui("Forward")) { message?.forward?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(message?.forward == nil)

            Divider()

            Button(.ui("Archive")) { message?.archive() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(message == nil)

            Button(.ui("Trash")) { message?.trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(message == nil)

            Button(.ui("Mark as unread")) { message?.markUnread() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(message == nil)

            // Says which way it is about to go. "Star" over an already-starred
            // conversation is a menu that lies about what pressing it does.
            Button(message?.isFlagged == true ? .ui("Remove star") : .ui("Star")) {
                message?.toggleFlagged()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(message == nil)

            Button(.ui("Snooze")) { message?.snooze() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(message == nil)

            Button(.ui("Labels")) { message?.pickLabels() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(message == nil)

            Divider()

            Button(.ui("Open in new window")) { message?.openInNewWindow?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(message?.openInNewWindow == nil)
        }

        // Into the system's View menu, beside its own sidebar item, rather
        // than a second menu called View sitting next to it.
        // **No sidebar item here.** iPadOS already puts "Show Sidebar" ⌘⌃S in
        // its own View menu for a `NavigationSplitView`, and adding a second
        // item with the same key equivalent does not merely look untidy: the
        // menu builder throws `NSInvalidArgumentException` ("Replacement
        // elements contain duplicates") and the app terminates on launch. The
        // in-view ⌘⌃S in `MailView` is a responder-chain key command, which is
        // a different mechanism and does not collide.
        CommandGroup(after: .sidebar) {
            if let openCalendar = shell?.openCalendar {
                // ⌘0, deliberately outside ⌘1…⌘9: the mailbox numbers are
                // taken from the sidebar's own ordering, and giving the
                // calendar one of them would silently shift what every number
                // below it means.
                Button(.ui("Calendar"), action: openCalendar)
                    .keyboardShortcut("0", modifiers: .command)
            }

            Divider()

            ForEach(shell?.mailboxes ?? []) { mailbox in
                Button(mailbox.title, action: mailbox.select)
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(mailbox.number)")), modifiers: .command)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button(.ui("Settings")) { shell?.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(shell == nil)
        }
    }
}

#endif
