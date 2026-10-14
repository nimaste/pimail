#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftData
import SwiftUI

/// The conversation list.
///
/// Driven entirely by `@Query` over the feed table, never by the network.
/// That is what makes a cold launch show mail immediately and what keeps
/// the list intact when the server is unreachable — which for a NAS is a
/// normal Tuesday, not an error state.
public struct ThreadListView: View {
    private let feed: FeedID
    private let sync: MailSyncService
    private let actions: MailActions
    /// Optional so a caller without one still gets the list, just without
    /// the inline label create. Nil is a degradation, not a mode.
    private let labelActions: LabelActions?
    /// Only for the composer a draft row opens. The list itself has nothing
    /// queued.
    private let outbox: OutboxSender

    /// Owned by the split view, not by this list.
    ///
    /// Selection *is* the navigation on a wide layout — it fills the third
    /// column — and on a narrow one the collapsed split view turns the same
    /// binding into a push. One piece of state drives both, which is what
    /// keeps the open thread open across a rotation or a Stage Manager
    /// resize instead of dumping the reader.
    @Binding private var selection: ThreadRef?
    /// Raised while a bulk selection is up, so the compose button can get out
    /// of the way — it occupies the same corner as the action bar's last
    /// button and would sit on top of Trash.
    @Binding private var isSelectionActive: Bool

    @Query private var entries: [StoredFeedEntry]
    @Query private var threads: [StoredThread]

    /// How many threads the join will hold at once. See the descriptor in
    /// `init` for why this is bounded rather than open.
    private static let joinableThreadLimit = 2_000

    /// How many feed entries are built into rows right now. Grows as the reader
    /// reaches the end; see ``rows`` for why it is bounded at all.
    @State private var visibleCount = Self.windowSize

    /// One screenful many times over, so reaching the end is rare and the step
    /// is never visible.
    private static let windowSize = 150

    /// Grows the built window when the reader gets close to its end.
    ///
    /// Returns nothing useful — it exists to be called from the row builder,
    /// where `onAppear` would fire after the row is already missing.
    @discardableResult
    private func widenWindowIfNeeded(reaching entry: StoredFeedEntry) -> Bool {
        guard let windowTriggerUID, entry.uid == windowTriggerUID else { return false }

        Task { @MainActor in
            visibleCount = min(visibleCount + Self.windowSize, entries.count)
        }

        return true
    }

    /// The one row whose appearance widens the window.
    ///
    /// A single identity compared per row, rather than a search through the
    /// built window — the first version of this scanned the prefix for every
    /// row it drew, which is the quadratic this whole change exists to remove.
    private var windowTriggerUID: String? {
        let built = min(visibleCount, entries.count)

        guard built < entries.count, built > 0 else { return nil }

        return entries[max(built - 20, 0)].uid
    }

    /// See ``rows``. Rebuilt from `threads` when they change, never per frame.
    @State private var cachedThreadsByKey: [ThreadKey: StoredThread] = [:]

    /// Shared because the prefetcher is built in the composition root, several
    /// columns away from the line that reports it.
    private let prefetch = PrefetchActivity.shared

    /// Resolved by `MailView` from the window's measured width. Read here for
    /// the one thing this list does differently when it is the only pane:
    /// paint its own surface, because there is no pane behind it to supply one.
    @Environment(\.mailLayout) private var layout

    /// The server's theme, for the one surface this view paints itself.
    ///
    /// Read from the environment rather than stored, because the colour
    /// depends on **two** environment values at once — the theme and the
    /// appearance — and a call site that captured only one would resolve to
    /// something that looks right under the default palette and silently
    /// ignores whatever the server set.
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// Both inputs resolved together, for the header's ink. Computed rather
    /// than stored for the reason above: either one changing has to repaint.
    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    @State private var isLoadingMore = false
    /// Conversations picked out for a bulk action. Non-empty *is* selection
    /// mode: there is no separate toggle to get out of sync with it.
    @State private var checked: Set<ThreadRef> = []
    /// Guards the menu item while the round trip is in flight. The action is
    /// two requests and a structure refresh, which is long enough on a home
    /// server for somebody to press it twice.
    @State private var isMarkingAllRead = false
    /// How much unread mail one press could not reach, when there was any.
    /// Nil is the normal case: everything fitted in one write.
    @State private var bulkNotice: Int?
    @State private var isPickingBulkLabel = false
    @State private var isPickingSwipeActions = false
    /// Where the keyboard is, which is not the same as what is open.
    ///
    /// On a wide layout moving the cursor *is* reading — the reader is the
    /// next column — so the two travel together. Collapsed there is no reader
    /// beside the list, and moving the cursor cannot mean pushing a message:
    /// `j` would leave the list and the second `j` would go to the reader.
    /// So the cursor moves alone and Return opens.
    ///
    /// Cleared whenever the rows change out from under it, because a cursor
    /// pointing at a conversation that has been archived is a highlight on
    /// nothing.
    @State private var cursor: ThreadRef?

    /// Shared rather than owned, so the two lists a split view has on screen at
    /// once cannot disagree about what a swipe does.
    private var swipes: SwipeActionPreference { .shared }
    /// The conversation whose exact snooze time is being picked.
    @State private var snoozing: ActionTarget?
    /// Whether the whole ticked selection is picking an exact snooze time.
    /// Separate from ``snoozing`` because that one is a single target and the
    /// two sheets must not be able to be up at once.
    @State private var isPickingBulkSnooze = false

    /// The measured width of the list column.
    ///
    /// Measured rather than derived from the size class: on iPad the list pane
    /// runs 396–540pt and a size-class test answers the same at both ends, so
    /// it would decide nothing about how many label chips fit. Zero until the
    /// first layout pass, which buys the conservative one-chip budget for a
    /// frame rather than briefly overflowing a column nobody has sized.
    @State private var paneWidth: CGFloat = 0

    /// Label chips per conversation, keyed `accountKey#threadID`.
    ///
    /// Built once per list rather than per row: resolving a row's labels means
    /// reading its messages' mailbox ids out of the store, and doing that
    /// inside a scrolling `ForEach` is a store read per row per redraw.
    @State private var chips: [String: [LabelChipModel]] = [:]

    /// Unread conversations per category, for the strip's counts. Held rather
    /// than computed in `body` for the same reason ``chips`` is: four store
    /// counts per redraw of a scrolling list is four store counts a frame.
    @State private var categoryCounts: [MessageCategory: Int] = [:]
    /// Bumped when something in this view changes a conversation's labels.
    ///
    /// Neither the feed table nor the mailbox list changes when a label is
    /// applied to a thread, so without this the chips would go on showing the
    /// labels the row had before the picker was opened.
    @State private var chipRevision = 0
    @State private var editingDraft: DraftRef?

    /// Which inbox category is on screen, or nil for the whole inbox.
    ///
    /// Owned by the shell rather than by this list, because changing it changes
    /// the ``FeedID`` and therefore rebuilds this view — a binding held here
    /// would be reset by the very change it made. Nil (not a nil *binding*)
    /// means the whole inbox; a nil **binding** means this list has no category
    /// surface at all, which is every list that is not the unified inbox and
    /// every list on a server that classifies nothing.
    private var categorySelection: Binding<MessageCategory?>?

    /// Shows or hides the mailbox column, where this list draws its own header
    /// bar instead of using the navigation bar.
    ///
    /// **Not decoration.** With the bar hidden the split view's own sidebar
    /// toggle goes with it, and on the layouts where that button is the only
    /// visible way back to the mailboxes, hiding it would strand anyone who
    /// closed the sidebar with nothing but ⌘⌃S to reopen it. The shell owns
    /// the visibility, so it hands the action down rather than this view
    /// reaching for it. Nil where there is nothing to toggle — a phone, or a
    /// search results list.
    private let onToggleSidebar: (() -> Void)?

    /// New Message, for the layouts that put it here.
    ///
    /// It used to be a `ToolbarItem` the shell attached to this column. The
    /// bar it lived in is gone on a separated layout, so the shell passes the
    /// action instead and the header draws it — still the same single closure,
    /// so the three compose entry points cannot drift.
    private let onCompose: (() -> Void)?

    /// Conversations badged **New** for as long as this feed is on screen.
    ///
    /// Held here rather than read from `StoredThread.isNew`, and that is the
    /// whole reason it exists. Drawing the row reports the display, the server
    /// accepts it, the column is cleared and `@Query` republishes — so a badge
    /// bound to the column would appear and vanish inside a second while
    /// somebody was looking at it.
    ///
    /// **Never persisted.** After a relaunch the server has already been told,
    /// so there is nothing new left; restoring this would be the phone badging
    /// mail on its own memory rather than on the marker.
    @State private var badgedNew: Set<String> = []

    /// Which draft the composer is continuing.
    struct DraftRef: Identifiable, Hashable {
        let emailID: String
        let accountKey: String

        var id: String { "\(accountKey)#\(emailID)" }
    }
    /// The conversation whose labels are being edited. A target rather than a
    /// Bool, so the sheet cannot outlive the row that opened it.
    @State private var labelling: ActionTarget?

    public init(
        feed: FeedID,
        sync: MailSyncService,
        actions: MailActions,
        labelActions: LabelActions? = nil,
        outbox: OutboxSender,
        selection: Binding<ThreadRef?>,
        isSelectionActive: Binding<Bool> = .constant(false),
        categorySelection: Binding<MessageCategory?>? = nil,
        onToggleSidebar: (() -> Void)? = nil,
        onCompose: (() -> Void)? = nil
    ) {
        self.feed = feed
        self.sync = sync
        self.actions = actions
        self.labelActions = labelActions
        self.outbox = outbox
        self.categorySelection = categorySelection
        self.onToggleSidebar = onToggleSidebar
        self.onCompose = onCompose
        _selection = selection
        _isSelectionActive = isSelectionActive

        let feedID = feed.rawValue

        _entries = Query(
            filter: #Predicate<StoredFeedEntry> { $0.feedID == feedID },
            sort: \.sortDate,
            order: .reverse
        )
        // **Bounded on purpose.** An unfiltered `Query()` here materialises
        // every thread in the store, on the main thread, and SwiftData stores
        // `StoredThread.emailIDs` as an archived binary plist — so each row
        // costs an `NSKeyedUnarchiver` pass. Every `SyncStore` write
        // republishes the query, so during a first sync the list re-materialised
        // the whole table several times a second and the main thread hung in
        // 500ms blocks, back to back. Measured on an iPad Pro with Instruments,
        // not guessed.
        //
        // The join only ever needs the threads the feed's entries name, and
        // entries are paged newest-first, so the most recent slice is the part
        // that can appear. The limit is generous against what any feed can
        // show; a thread older than the whole window simply is not on screen.
        var recent = FetchDescriptor<StoredThread>(
            sortBy: [SortDescriptor(\.latestReceivedAt, order: .reverse)]
        )

        recent.fetchLimit = Self.joinableThreadLimit
        _threads = Query(recent)
    }

    public var body: some View {
        // A proxy rather than `.scrollPosition`: the cursor is moved by a key
        // press, and the row it lands on is almost always off screen after two
        // presses. A selection that moves invisibly is a selection that is not
        // there.
        // The chrome sits *above* the list rather than inside it as a
        // `safeAreaInset`. Inset content rides the scroll view's rubber-band,
        // so the category strip drifted up and down whenever the list was
        // dragged — the tabs appeared to be draggable themselves.
        VStack(spacing: 0) {
            categoryStrip
            listHeader

            ScrollViewReader { scroll in
                list
                    .shortcuts { keyboardShortcuts(scroll) }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(rows, id: \.entry.uid) { row in
                // Widen the window as the end comes into view. Cheap: it fires
                // once per row, and only the last few rows do anything.
                let _ = widenWindowIfNeeded(reaching: row.entry)

                // A Button rather than List's own selection binding. The
                // system's selected appearance is a hard blue fill that also
                // recolours the row's text, and none of it is restylable — on
                // a mail list, where the row's own colours carry unread and
                // starred, that erases the state it is sitting on top of.
                // Owning the tap means owning the highlight.
                Button {
                    let ref = ThreadRef(thread: row.thread)

                    if isSelecting {
                        // Ticking a row for a bulk action is not opening it.
                        // Spending the badge here would clear "New" off forty
                        // conversations somebody was about to archive
                        // unread — the badge is what tells them which those
                        // were.
                        toggle(ref)
                    } else if row.thread.isDraft, let emailID = row.thread.newestEmailID {
                        spendBadge(for: row.thread)
                        // A draft is unfinished writing, not something to read.
                        // The web UI opens the composer here too.
                        editingDraft = DraftRef(
                            emailID: emailID, accountKey: row.thread.accountKey)
                    } else {
                        spendBadge(for: row.thread)
                        immediately { selection = ref }
                    }
                } label: {
                    rowContent(for: row)
                }
                .buttonStyle(.plain)
                // A rule between rows rather than whitespace. With three lines
                // of text per row, gaps alone leave it ambiguous which subject
                // belongs to which sender at a glance; a hairline settles it
                // and lets the rows sit closer together. Inset to the text
                // column by the row itself.
                .listRowSeparator(.visible)
                .listRowSeparatorTint(PanelStyle.hairline)
                .listRowInsets(.init(top: 0, leading: 6, bottom: 0, trailing: 6))
                // Hiding the *scroll* background is not enough: rows paint
                // their own on top of it, which on a separated pane shows as
                // an opaque band sitting over the card.
                .listRowBackground(Color.clear)
                .task { await loadMoreIfNeeded(at: row.entry) }
                // A row appearing is a display; a page arriving from the pager,
                // a delta pull, a notification and the body prefetcher are not.
                // This is the only place in the app that reports one, which is
                // why it is on the row and not on the sync path.
                .onAppear {
                    noteDisplayed(row.thread)
                    noteOnScreen(row.entry)
                }
                // Both edges chosen by the user, both undoable, and everything
                // a swipe does is also reachable from the row's context menu —
                // a gesture must never be the only way to reach an action.
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    swipeButton(swipes.leading, for: row.thread)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    swipeButton(swipes.trailing, for: row.thread)
                }
                .contextMenu { rowMenu(for: row.thread) }
                // Ids, never the `StoredThread`: a drag outlives the row that
                // started it, `@Model` objects are not `Sendable`, and by the
                // time the finger lifts the thread may have been archived by
                // a sync running underneath.
                //
                // Whatever is ticked travels together, so dragging one row out
                // of a bulk selection carries the selection rather than
                // silently acting on one of it.
                .draggable(dragPayload(for: row.thread))
                // The pointer morphs over a row, as it does over every other
                // list on the platform. `.buttonStyle(.plain)` opts out of the
                // system's own hover treatment, so it has to be asked for.
                .hoverEffect(.highlight)
            }

            if degraded.isEmpty == false {
                degradedSection
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        // iOS 26 paints a "hard" edge effect behind a bar over scrolling
        // content. Over a pane card that lands as an opaque square band across
        // the top of the column, which is what broke the card's top edge while
        // the reader — whose bar carries no title — looked whole.
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The pane behind supplies the surface; a List painting its own would
        // square off the pane's rounded corners.
        .scrollContentBackground(.hidden)
        // Collapsed there is no pane behind, so the list has to lay the paper
        // down itself — otherwise the system's cool white shows through and
        // the one appearance most people use is the one that misses the point.
        //
        // From the palette rather than from `PanelStyle`, and this was the last
        // hole in the theming work: `.mailPane` is a deliberate no-op on
        // compact, so a themed phone drew a themed reader above an unthemed
        // list — which reads as a rendering fault rather than as a theme. The
        // default palette is pinned equal to `PanelStyle.surface`, so the
        // default appearance is unchanged.
        .background(
            layout.isSeparated
                ? Color.clear
                : theme.palette(for: colorScheme).surface.color
        )
        .safeAreaInset(edge: .bottom) { bulkBar }
        .safeAreaInset(edge: .bottom) { prefetchBar }
        // Rebuilt only when the rows' right-hand side actually changes.
        // `rows` runs on every body evaluation, and `threads` is an
        // unfiltered query over the whole table — building this inside it
        // walked every thread in the store many times a second.
        .onChange(of: threads, initial: true) { _, latest in
            cachedThreadsByKey = Dictionary(
                latest.map { (ThreadKey($0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        .onChange(of: isSelecting) { _, active in isSelectionActive = active }
        // Tapping a row moves the cursor to it, so `j` afterwards continues
        // from where the finger left off rather than from wherever the
        // keyboard last was.
        .onChange(of: selection) { _, ref in
            if let ref { cursor = ref }
        }
        // A cursor pointing at a conversation that is no longer in this list —
        // the mailbox changed, or the thread was archived from another device —
        // is a highlight on nothing and a `j` that jumps to the top.
        .onChange(of: feed) { _, _ in
            cursor = nil
            // A badge means "new since I last looked at *this* list", so it
            // does not travel to the next one. Emptied rather than merged: a
            // conversation carried across would be badged on a list whose rows
            // this device has already been through.
            badgedNew = []
        }
        // The reports for the page just drawn, sent rather than dropped on the
        // floor because the scene was torn down 300ms into a 750ms window. This
        // is the case that matters: leaving a list is exactly when somebody has
        // finished looking at it.
        .onDisappear { Task { await sync.flushDisplayReports() } }
        // The list column's real width, which is what decides how many chips a
        // row can afford. Read here rather than passed down from the shell:
        // this view is the column.
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            paneWidth = $0
        }
        .task(id: chipKey) { await loadChips() }
        // Its own key. The chips answer to "which conversations are visible";
        // a category count answers to "how many are unread", and reading one
        // message changes the second without touching the first — so sharing
        // the chips' key left every tab showing the figure it had when the
        // mailbox was opened.
        .task(id: categoryCountKey) { await loadCategoryCounts() }
        // Applying a label changes neither the feed table nor the mailbox list,
        // so nothing else would tell the chips to re-resolve and the row would
        // go on showing the labels it had before the sheet opened.
        .sheet(isPresented: $isPickingBulkLabel, onDismiss: { chipRevision += 1 }) {
            BulkLabelPickerView(
                targets: checkedTargets,
                sync: sync,
                actions: actions,
                labelActions: labelActions,
                store: sync.store
            ) {
                immediately { checked = [] }
            }
        }
        .alert(
            .ui("Not everything fitted"),
            isPresented: Binding(
                get: { bulkNotice != nil },
                set: { if $0 == false { bulkNotice = nil } }
            ),
            presenting: bulkNotice
        ) { _ in
            Button(.ui("OK"), role: .cancel) {}
        } message: { remaining in
            Text(
                .ui(
                    "Your server accepts a limited number of changes per request, so \(remaining) messages are still unread. Press Mark all as read again to continue."
                ))
        }
        .sheet(isPresented: $isPickingSwipeActions) {
            SwipeActionSettingsView(preference: swipes)
        }
        .sheet(item: $editingDraft) { draft in
            if let account = sync.accounts.first(where: { $0.accountKey == draft.accountKey }) {
                ComposeView(
                    kind: .editDraft(emailID: draft.emailID),
                    accountKey: draft.accountKey,
                    accountID: account.accountID,
                    client: sync.jmapClient,
                    store: sync.store,
                    outbox: outbox
                )
            }
        }
        // Its own sheet rather than reusing `snoozing`, which carries a single
        // target: one binding for both would let a stale single-row target
        // decide what a bulk pick applies to.
        .sheet(isPresented: $isPickingBulkSnooze) {
            SnoozeDatePicker { until in snoozeSelection(until: until) }
        }
        .sheet(item: $snoozing) { target in
            SnoozeDatePicker { until in
                act { await actions.snooze(target, until: until) }
            }
        }
        .sheet(item: $labelling, onDismiss: { chipRevision += 1 }) { target in
            LabelPickerView(
                target: target, sync: sync, actions: actions, store: sync.store,
                labelActions: labelActions)
        }
        .undoOverlay(actions)
        .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
        .refreshable { await sync.refresh(feed: feed) }
        .overlay { emptyState }
        // The title carries the count while selecting, so the number is where
        // the eye already is rather than in a second bar.
        // **Empty on a card, named on a phone.** A navigation bar with text in
        // it paints an opaque background, and over a pane card that lands as a
        // square band across the card's top edge — the card appears to start
        // below the bar instead of behind it. So on a separated layout the
        // title is empty and the bar collapses, and `listHeader` names the list
        // inside the card.
        //
        // A phone has no card and no such problem, and an empty title there
        // left a hundred and thirty points of nothing above the categories with
        // a back chevron floating in it.
        .navigationTitle(
            layout.isSeparated
                ? Text(verbatim: "") : Text(verbatim: feed.title(mailboxes: sync.mailboxes))
        )
        // **Gone entirely on a separated layout**, which is what reclaims the
        // band of empty pane above the header. The bar was already carrying no
        // title — see above — so all it drew was one floating ellipsis in
        // roughly a hundred and eighty points of cream, and a card whose top
        // edge nothing reached. Everything the bar held now sits in
        // ``listHeader``, at the top of the card where the mock draws it, which
        // is also the only place a control is inside the pane's margins: the
        // system lays a navigation bar out in the column's *full* bounds, so a
        // button in it hugs the screen edge past the card. Collapsed the bar
        // stays: it carries the back button to the mailboxes.
        .toolbarVisibility(layout.isSeparated ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            // Only where the bar is still on screen. Drawn as well as the
            // header's own copies, these would be two controls for one action
            // — and on the separated layouts they would be two invisible ones.
            if layout.isSeparated == false {
                if isSelecting == false {
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                }

                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(.ui("Cancel")) { immediately { checked = [] } }
                    }

                    ToolbarItem(placement: .topBarTrailing) { selectAllButton }
                }
            }
        }
        // Inline, not large. A large title silently fails to render when
        // the split view restores its detail column rather than pushing
        // it, which is exactly the cold-launch path — and an untitled list
        // reads as a bug. Inline also matches the list-then-reader flow.
        .navigationBarTitleDisplayMode(.inline)
        // Applied here as well as in `mailPane`. The reader's bar carries an
        // empty title so it collapses and its card looks whole; this one has
        // text, and a bar with something in it paints an opaque background —
        // which lands as a square white band across the top of a rounded card.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }

    /// The list's name and its controls, drawn inside the card rather than in
    /// the bar.
    ///
    /// See the empty `navigationTitle` for why the name is here. Since the
    /// separated layouts hide the navigation bar outright, this is also the
    /// list's *toolbar*: the sidebar toggle, New Message, the overflow menu and
    /// the selection buttons all live in this row. That is the point — a
    /// control in a navigation bar is laid out in the column's full bounds and
    /// hugs the screen edge past the card, while everything in here is inside
    /// the pane's own margins along with the mail.
    ///
    /// Carries the selection count while selecting, so the number stays where
    /// the eye already is.
    private var listHeader: some View {
        HStack(spacing: 10) {
            if isSelecting {
                Button(.ui("Cancel")) { immediately { checked = [] } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ThemeAccent())
            }

            selectAllBox

            // The mailbox, named. The design puts it here, and the docked
            // calendar is the case that proves it needs to be: the sidebar
            // shrinks to a 56pt rail of icons there, and this becomes the only
            // place on screen that says which list you are looking at. While a
            // selection is up the count takes the slot instead — it is the one
            // number with nowhere else to go.
            // Not on a phone, where the navigation bar above it already says
            // the name — the same name in two bars two lines apart reads as a
            // mistake rather than as emphasis.
            if isSelecting || layout.isSeparated {
                Text(
                    verbatim: isSelecting
                        ? "\(checked.count) selected" : feed.title(mailboxes: sync.mailboxes)
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink.color)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isSelecting {
                selectAllButton
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ThemeAccent())
            } else {
                // What is in the list, on the trailing edge — the one number
                // the header has room for and the only one people ask it for.
                // Tabular so it does not shuffle as rows page in.
                //
                // Counted from the feed table rather than from `rows`, which is
                // the *built window* and would read "150 conversations" in a
                // 60,000-message mailbox.
                Text(.ui("\(entries.count) conversations"))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkFaint.color)
                    .lineLimit(1)

                // Only where the bar that used to hold them is gone. Collapsed
                // they are still toolbar items, and drawing them twice would
                // put two ellipses on one phone screen.
                if layout.isSeparated {
                    // No compose or sidebar-toggle icon: on a separated layout
                    // the window header owns the toggle and the sidebar owns
                    // Compose. Two controls for one destination is how they
                    // drift apart.
                    moreMenu
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.inkMuted.color)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // The rows scroll *under* this, so it has to be paper rather than
        // nothing — and the pane card is what supplies the colour, so the
        // header takes the same surface rather than a fill of its own. Clear
        // where there is no card behind it to disagree with.
        .background {
            if layout.isSeparated {
                palette.surface.color
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// One of the header's own toolbar buttons: a 32pt icon, the size the mock
    /// draws every circular control at, with a 44pt-tall row around it.
    private func headerIcon(
        _ title: LocalizedStringResource, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 15))
                .foregroundStyle(palette.inkMuted.color)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(title))
    }

    /// The overflow, drawn by the header on a separated layout and by the
    /// navigation bar on a collapsed one — one definition either way.
    private var moreMenu: some View {
        Menu {
            Button(.ui("Mark all as read"), systemImage: "envelope.open") {
                markAllAsRead()
            }
            .disabled(isMarkingAllRead)

            Button(.ui("Swipe actions"), systemImage: "hand.draw") {
                isPickingSwipeActions = true
            }

            // No category picker here any more. The strip above the rows is now
            // drawn on every layout, and a second control in the menu would be
            // two places that say what is showing — the failure the strip's own
            // comment warns about, in the other direction.
        } label: {
            Label(.ui("More"), systemImage: "ellipsis.circle")
        }
    }

    /// Named for what it does. "Select all" next to a paged list reads as the
    /// whole mailbox, and it is not — it is the rows that have actually loaded.
    private var selectAllButton: some View {
        Button(allChecked ? .ui("Deselect all") : .ui("Select all loaded")) {
            immediately {
                checked = allChecked ? [] : Set(rows.map { ThreadRef(thread: $0.thread) })
            }
        }
    }

    /// Select-all, as a checkbox in the header rather than only as a toolbar
    /// button that appears once something is already ticked.
    ///
    /// It says the same thing the toolbar's "Select all loaded" says, and
    /// deliberately with the same limit: the box covers the rows that have
    /// actually paged in, never the whole mailbox. Spelled out for VoiceOver
    /// for that reason — the glyph cannot carry "loaded".
    ///
    /// Hidden when there is nothing to tick, so an empty list does not offer a
    /// control that would do nothing.
    ///
    /// Both the emptiness test and the ticked test are written to avoid
    /// building ``rows`` while the header merely draws: `entries` is the query
    /// itself, and `allChecked` — which does build the window — is only
    /// reached once something is actually ticked. The header redraws on every
    /// body evaluation, and this is the same hot path the join is cached for.
    @ViewBuilder
    private var selectAllBox: some View {
        if entries.isEmpty == false {
            let isAllChecked = isSelecting && allChecked

            Button {
                immediately {
                    checked = isAllChecked ? [] : Set(rows.map { ThreadRef(thread: $0.thread) })
                }
            } label: {
                Image(systemName: isAllChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        isAllChecked
                            ? AnyShapeStyle(ThemeAccent())
                            : AnyShapeStyle(palette.inkFaint.color)
                    )
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(
                Text(isAllChecked ? .ui("Deselect all") : .ui("Select all loaded")))
        }
    }

    /// The tabs, on every layout.
    ///
    /// Drawn on one pane as well as three since the redesign: the same control
    /// used to be demoted to the overflow menu on a phone, which made the
    /// categories something you had to already know about. The strip's job is
    /// to say what the list is currently narrowed to, and a menu item cannot
    /// do that without being opened.
    ///
    /// Still absent entirely on a server that classifies nothing — the shell
    /// withholds the binding — because five permanently empty tabs above a
    /// working inbox reads as mail having gone missing.
    @ViewBuilder
    private var categoryStrip: some View {
        if let categorySelection {
            InboxCategoryPicker(
                selection: categorySelection, isStrip: true, unreadCounts: categoryCounts)
        }
    }

    /// Says that the background prefetch is working, and how far it has got.
    ///
    /// Present only while it runs. Prefetch is invisible to everything else by
    /// design — nothing on screen waits for it — and the one thing that costs
    /// is a server quietly occupied with no way to tell. This is that way.
    @ViewBuilder
    private var prefetchBar: some View {
        if prefetch.isRunning {
            HStack(spacing: 8) {
                // Determinate where there is a figure to show, indeterminate
                // only before the first chunk lands — a bar sitting at zero
                // reads as stalled rather than as starting.
                if let completion = prefetch.completion {
                    ProgressView(value: completion)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }

                Text(.ui("Downloading \(prefetch.fetched) messages for offline"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(.ui("Downloading \(prefetch.fetched) messages for offline")))
        }
    }

    // MARK: - Keyboard

    /// Everything the list can be driven with from a hardware keyboard.
    ///
    /// Bound to hidden buttons rather than `.onKeyPress`, which only fires
    /// while the view it is attached to holds focus — and on iPad the list, the
    /// sidebar and the reader are all on screen at once, so "which one has
    /// focus" becomes a question the user has to answer before they can press
    /// a key. A shortcut works wherever the eye already is, and SwiftUI
    /// suppresses all of them while a text field is being typed into.
    ///
    /// Bare letters only where the reader has not already claimed them: it is
    /// visible beside this list on a wide layout, and two controls answering
    /// one bare key is a coin toss. Message verbs — `e`, `r`, `a`, `f`, `l`,
    /// `u`, `s` — are the reader's, and the cursor below is what feeds it.
    ///
    /// Every one of these is also a visible control: the rows themselves, the
    /// avatar's Select tap target, and the Cancel and Select all buttons the
    /// selection toolbar puts up.
    @ViewBuilder
    private func keyboardShortcuts(_ scroll: ScrollViewProxy) -> some View {
        // Gmail's j/k, and ⌘↓/⌘↑ for the rest of the platform. Plain arrows
        // are deliberately not taken: they scroll the list, and a mail client
        // that cannot be scrolled with the arrow keys is a worse trade than one
        // whose next-message key needs a modifier.
        HiddenShortcut(title: .ui("Next conversation"), key: "j", modifiers: []) {
            moveCursor(by: 1, using: scroll)
        }

        HiddenShortcut(title: .ui("Next conversation"), key: .downArrow) {
            moveCursor(by: 1, using: scroll)
        }

        HiddenShortcut(title: .ui("Previous conversation"), key: "k", modifiers: []) {
            moveCursor(by: -1, using: scroll)
        }

        HiddenShortcut(title: .ui("Previous conversation"), key: .upArrow) {
            moveCursor(by: -1, using: scroll)
        }

        HiddenShortcut(title: .ui("Open conversation"), key: .return, modifiers: []) {
            open(cursor)
        }

        // What Escape means everywhere else: back out of the narrowest thing
        // first. A selection is narrower than a cursor, so it goes first —
        // otherwise one press would drop both and there would be no way to
        // keep a selection while moving the cursor off it.
        HiddenShortcut(title: .ui("Clear selection"), key: .escape, modifiers: []) {
            if isSelecting {
                immediately { checked = [] }
            } else {
                immediately { cursor = nil }
            }
        }

        // Gmail's "x". The same thing tapping an avatar does.
        HiddenShortcut(title: .ui("Select conversation"), key: "x", modifiers: []) {
            if let cursor { toggle(cursor) }
        }

        HiddenShortcut(title: .ui("Select all loaded"), key: "a") {
            checked = Set(rows.map { ThreadRef(thread: $0.thread) })
        }
    }

    /// Moves the cursor one row and brings it into view.
    ///
    /// From nothing, a forward move lands on the first row and a backward move
    /// on the last, so the first key press does something whichever direction
    /// it is. Clamped rather than wrapped: a list that jumps from the bottom
    /// back to the top loses the reader's place, and this one is paged — the
    /// "end" is only the end of what has loaded.
    private func moveCursor(by offset: Int, using scroll: ScrollViewProxy) {
        // Bound once: `rows` joins two `@Query` results on every read, and
        // this method reads it three times.
        let loaded = rows

        guard loaded.isEmpty == false else { return }

        let current = loaded.firstIndex { ThreadRef(thread: $0.thread) == cursor }
        let next =
            if let current {
                min(max(current + offset, 0), loaded.count - 1)
            } else {
                offset > 0 ? 0 : loaded.count - 1
            }

        let row = loaded[next]
        let ref = ThreadRef(thread: row.thread)

        immediately { cursor = ref }

        // Moving the cursor *is* reading where the reader is the next column
        // over. Collapsed it is not, and following the cursor would push a
        // message on the first press and leave nothing to move through.
        if layout.isSeparated, isSelecting == false, row.thread.isDraft == false {
            spendBadge(for: row.thread)
            immediately { selection = ref }
        }

        scroll.scrollTo(row.entry.uid, anchor: .center)
    }

    /// Return, which means whatever tapping the row means.
    private func open(_ ref: ThreadRef?) {
        guard let ref, let row = rows.first(where: { ThreadRef(thread: $0.thread) == ref })
        else { return }

        if isSelecting {
            toggle(ref)
        } else if row.thread.isDraft, let emailID = row.thread.newestEmailID {
            spendBadge(for: row.thread)
            editingDraft = DraftRef(emailID: emailID, accountKey: row.thread.accountKey)
        } else {
            spendBadge(for: row.thread)
            immediately { selection = ref }
        }
    }

    // MARK: - The New marker

    /// How a conversation is named in ``badgedNew``.
    ///
    /// Account-qualified, because two servers can and do hand out the same
    /// thread id — an unqualified key would badge an unrelated conversation in
    /// the other account.
    private static func key(of thread: StoredThread) -> String {
        "\(thread.accountKey)#\(thread.threadID)"
    }

    /// One row has been drawn.
    ///
    /// Two things happen, in this order and for different reasons. The badge is
    /// raised locally and held for the life of this feed, because reporting the
    /// display is what *spends* the marker. And the display is reported to the
    /// server, because only a client that draws a row can retire that row's
    /// marker — an app that badged without reporting would leave the web UI and
    /// Android badging this conversation until the window lapsed.
    ///
    /// Both are guarded on the stored column, so a row scrolled back onto
    /// screen after its marker was retired does not raise the badge again.
    /// ``ShownThreads`` batches and de-duplicates the reporting half, so a fling
    /// through fifty rows is one request rather than fifty.
    /// Rows that have come into view and whose bodies have not been asked for.
    ///
    /// Collected rather than fetched one at a time: scrolling produces a
    /// dozen `onAppear`s in a frame, and a request per row would be a dozen
    /// round trips against a server with one worker.
    @State private var onScreen: [String: Set<String>] = [:]
    @State private var warmTask: Task<Void, Never>?

    /// Notes a row as visible and schedules a warm.
    ///
    /// **Debounced, and deliberately after the scroll rather than during it.**
    /// A flick down a long list makes hundreds of rows appear and disappear
    /// inside a second; fetching for each would be worse than fetching for
    /// none. Waiting for the scroll to settle means the request is for the
    /// rows somebody has actually stopped on — which is also the set they are
    /// about to tap.
    private func noteOnScreen(_ entry: StoredFeedEntry) {
        guard entry.emailID.isEmpty == false else { return }

        onScreen[entry.accountKey, default: []].insert(entry.emailID)

        warmTask?.cancel()
        warmTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))

            guard Task.isCancelled == false else { return }

            let batch = onScreen
            onScreen = [:]

            for (accountKey, emailIDs) in batch {
                await sync.warmBodies(accountKey: accountKey, emailIDs: Array(emailIDs))
            }
        }
    }

    private func noteDisplayed(_ thread: StoredThread) {
        guard thread.isNew else { return }

        let key = Self.key(of: thread)

        guard badgedNew.contains(key) == false else { return }

        badgedNew.insert(key)
        sync.reportDisplayed(threadID: thread.threadID, accountKey: thread.accountKey)
    }

    /// Spends one conversation's badge the moment it is opened.
    ///
    /// Coming back from a message you have just read to a row still shouting
    /// "New" reads as the app not having noticed what you did.
    private func spendBadge(for thread: StoredThread) {
        badgedNew.remove(Self.key(of: thread))
    }

    // MARK: - Drag

    /// What dragging this row carries.
    ///
    /// The whole ticked set when the row is part of one, so dragging a
    /// selection to a label does not quietly apply it to one conversation and
    /// leave the other thirty behind. Otherwise just this row — including when
    /// a selection exists but this row is not in it, which is a drag *out* of
    /// the selection and means what it says.
    private func dragPayload(for thread: StoredThread) -> ThreadTransfer {
        let ref = ThreadRef(thread: thread)
        let dragged =
            checked.contains(ref)
            ? rows.filter { checked.contains(ThreadRef(thread: $0.thread)) }.map(\.thread)
            : [thread]

        return ThreadTransfer(
            items: dragged.map {
                ThreadTransfer.Item(
                    accountKey: $0.accountKey,
                    threadID: $0.threadID,
                    subject: ThreadRef(thread: $0).subject,
                    emailIDs: $0.emailIDs)
            })
    }

    // MARK: - Selection

    /// In the Spam list the verb reverses: everything here is already spam,
    /// and the useful action is rescuing it.
    private var isJunkFeed: Bool {
        if case .unified(.junk) = feed { return true }

        if case .mailbox(let accountKey, let mailboxID) = feed {
            return sync.mailboxes.contains {
                $0.accountKey == accountKey && $0.mailboxID == mailboxID && $0.role == .junk
            }
        }

        return false
    }

    /// One row's contents.
    ///
    /// Also extracted for the type-checker: six arguments, two of them
    /// closures, one an interpolated dictionary lookup, inside a `List` that
    /// already carries the swipe and menu builders was past what it will solve.
    private func rowContent(
        for row: (entry: StoredFeedEntry, thread: StoredThread)
    )
        -> some View
    {
        let ref = ThreadRef(thread: row.thread)
        // `highlights`, not the compatibility `snippets` view: the row draws a
        // subject match on the subject line and a body match in the preview
        // slot, and the body-only dictionary cannot tell it which it has.
        let highlight = sync.highlights["\(row.entry.accountKey)#\(row.entry.emailID)"]

        return ThreadRowView(
            thread: row.thread,
            account: accountTag(for: row.entry),
            isSelected: checked.contains(ref),
            isOpen: selection == ref,
            isFocused: cursor == ref,
            highlight: highlight,
            labels: chips["\(row.entry.accountKey)#\(row.entry.threadID)"] ?? [],
            paneWidth: paneWidth,
            // From the in-memory set, never from `thread.isNew`: the column is
            // cleared the moment the server accepts the report this same draw
            // sent, and a badge bound to it would flicker away while somebody
            // was reading it.
            isNew: badgedNew.contains(Self.key(of: row.thread)),
            onToggleStar: {
                act {
                    await actions.setFlagged(
                        row.thread.isFlagged == false, target(for: row.thread))
                }
            },
            onToggleSelection: { toggle(ref) }
        )
    }

    /// Marks everything unread in this list as read.
    ///
    /// The targets are asked of the server rather than taken from the rows on
    /// screen: the store holds only what has been paged in, and "mark all as
    /// read" that quietly meant "mark the first fifty as read" would leave the
    /// mailbox still showing unread mail immediately after being told not to.
    private func markAllAsRead() {
        isMarkingAllRead = true

        Task {
            defer { isMarkingAllRead = false }

            let selection = await sync.unreadTargets(in: feed)

            guard selection.targets.isEmpty == false else { return }

            await actions.perform(.setSeen(true), on: selection.targets)

            // Unread counts come from `Mailbox/get` and nothing local
            // recomputes them, so without this the sidebar goes on claiming
            // unread mail in a list the user has just cleared.
            await sync.refreshStructure()

            // Said plainly rather than left to the badge. One write carries at
            // most `maxObjectsInSet` objects, so a mailbox with more unread
            // than that is not cleared by one press — and "mark all as read"
            // that silently marked some of it would have the user believing a
            // mailbox is empty when it is not.
            bulkNotice = selection.remaining > 0 ? selection.remaining : nil
        }
    }

    // MARK: - Row actions
    //
    // Extracted from the `List` body rather than written inline. Every one of
    // these is a ternary picking both a title and a symbol, and with a dozen of
    // them in one expression the type-checker gives up — which surfaces as
    // "unable to type-check in reasonable time", not as an error pointing at
    // any of them.

    /// One edge's button.
    ///
    /// The title flips with the row's own state — a read conversation offers
    /// Unread — because a swipe that says "Read" on something already read is
    /// a button whose effect you cannot predict until you have pressed it.
    @ViewBuilder
    private func swipeButton(_ action: SwipeAction, for thread: StoredThread) -> some View {
        if action != .nothing {
            Button(role: action.isDestructive ? .destructive : nil) {
                perform(action, on: thread)
            } label: {
                swipeLabel(action, for: thread)
            }
            // Set even for the destructive role, which otherwise takes the
            // system red — the one colour on this palette that has to be
            // exactly the shade the rest of the app calls destructive.
            .tint(action.tint)
        }
    }

    @ViewBuilder
    private func swipeLabel(_ action: SwipeAction, for thread: StoredThread) -> some View {
        switch action {
        case .archive: Label(.ui("Archive"), systemImage: "archivebox")
        case .trash: Label(.ui("Trash"), systemImage: "trash")
        case .readState: readLabel(for: thread, long: false)
        case .star: starLabel(for: thread)
        case .spam: spamLabel
        case .nothing: EmptyView()
        }
    }

    private func perform(_ action: SwipeAction, on thread: StoredThread) {
        let target = target(for: thread)

        switch action {
        case .archive: act { await actions.archive(target) }
        case .trash: act { await actions.trash(target) }
        case .readState: act { await actions.setSeen(thread.isUnread, target) }
        case .star: act { await actions.setFlagged(thread.isFlagged == false, target) }
        case .spam: act { await actions.setSpam(isJunkFeed == false, target) }
        case .nothing: break
        }
    }

    @ViewBuilder
    private func rowMenu(for thread: StoredThread) -> some View {
        Button {
            act { await actions.setFlagged(thread.isFlagged == false, target(for: thread)) }
        } label: {
            starLabel(for: thread)
        }

        Button {
            act { await actions.setSeen(thread.isUnread, target(for: thread)) }
        } label: {
            readLabel(for: thread, long: true)
        }

        Button {
            labelling = target(for: thread)
        } label: {
            Label(.ui("Labels"), systemImage: "tag")
        }

        Menu {
            SnoozeMenu(
                isSnoozed: thread.snoozedUntil != nil,
                onPick: { until in
                    act { await actions.snooze(target(for: thread), until: until) }
                },
                onPickExact: { snoozing = target(for: thread) }
            )
        } label: {
            Label(.ui("Snooze"), systemImage: "clock")
        }

        Button {
            act { await actions.setSpam(isJunkFeed == false, target(for: thread)) }
        } label: {
            spamLabel
        }

        Button {
            act { await actions.archive(target(for: thread)) }
        } label: {
            Label(.ui("Archive"), systemImage: "archivebox")
        }

        Button(role: .destructive) {
            act { await actions.trash(target(for: thread)) }
        } label: {
            Label(.ui("Move to Trash"), systemImage: "trash")
        }
    }

    private func readLabel(for thread: StoredThread, long: Bool) -> some View {
        let title: LocalizedStringResource =
            switch (thread.isUnread, long) {
            case (true, true): .ui("Mark as read")
            case (true, false): .ui("Read")
            case (false, true): .ui("Mark as unread")
            case (false, false): .ui("Unread")
            }

        return Label(
            title, systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
    }

    private func starLabel(for thread: StoredThread) -> some View {
        Label(
            thread.isFlagged ? .ui("Remove star") : .ui("Star"),
            systemImage: thread.isFlagged ? "star.slash" : "star")
    }

    private var spamLabel: some View {
        Label(
            isJunkFeed ? .ui("Not spam") : .ui("Report spam"),
            systemImage: isJunkFeed ? "tray.and.arrow.down" : "exclamationmark.shield"
        )
    }

    private var isSelecting: Bool { checked.isEmpty == false }

    /// Performs a selection change with no animation.
    ///
    /// **`List` is a collection view underneath**, and anything that changes
    /// how many rows are marked is a *batch update* over every row it holds —
    /// not the fifteen on screen. Animated, that is UIKit interpolating three
    /// thousand cells because somebody tapped one of them, and it is the whole
    /// of why selecting a conversation, and ticking all of them, felt slow and
    /// stuttery on a real mailbox.
    ///
    /// Nothing here is a transition worth easing either. Opening a
    /// conversation, ticking a row and moving the keyboard cursor are direct
    /// manipulation: the mark belongs under the finger when it lifts, not a
    /// fifth of a second later. Arrivals and departures — a message deleted, a
    /// page paging in — still animate, which is where an animation earns its
    /// place, because there the reader did not cause the change.
    private func immediately(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction, change)
    }

    private func toggle(_ ref: ThreadRef) {
        immediately {
            if checked.contains(ref) {
                checked.remove(ref)
            } else {
                checked.insert(ref)
            }
        }
    }

    /// The selected conversations, as things an action can be applied to.
    ///
    /// Resolved from the rows on screen rather than stored alongside the
    /// selection: a thread that gained a reply since it was ticked should be
    /// acted on whole, and a thread that vanished should drop out silently
    /// rather than sending ids the server no longer has.
    private var checkedTargets: [ActionTarget] {
        rows
            .filter { checked.contains(ThreadRef(thread: $0.thread)) }
            .map { target(for: $0.thread) }
    }

    /// The bulk action bar.
    ///
    /// Only the actions that make sense on a heap of conversations. Reply is
    /// deliberately absent — replying to forty threads at once is not an
    /// operation.
    ///
    /// Snooze is here because `BulkAction.snooze` batches per account and undoes
    /// to each conversation's **own** previous time: without it the only way to
    /// clear forty conversations until Monday was forty separate row menus, and
    /// forty separate undo bars.
    @ViewBuilder
    private var bulkBar: some View {
        if isSelecting {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 0) {
                    bulkButton(.ui("Archive"), "archivebox") { .archive }
                    bulkButton(.ui("Labels"), "tag", action: nil) { isPickingBulkLabel = true }
                    bulkSnooze
                    bulkButton(
                        anyUnread ? .ui("Read") : .ui("Unread"),
                        anyUnread ? "envelope.open" : "envelope.badge"
                    ) {
                        .setSeen(anyUnread)
                    }
                    bulkButton(
                        anyUnstarred ? .ui("Star") : .ui("Unstar"),
                        anyUnstarred ? "star" : "star.slash"
                    ) {
                        .setFlagged(anyUnstarred)
                    }
                    bulkButton(.ui("Trash"), "trash", role: .destructive) { .trash }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .transition(.move(edge: .bottom))
        }
    }

    /// Snooze, for the whole ticked selection.
    ///
    /// A `Menu` rather than a `Button` because snooze is the one bulk action
    /// that needs a *when*, and the presets are the same ones a single row
    /// offers — one `SnoozeMenu` for both, so the two cannot drift into
    /// offering different times.
    ///
    /// `.snooze` batches per account and undoes to each conversation's **own**
    /// previous time, so undoing a bulk snooze does not flatten forty different
    /// wake times into one.
    private var bulkSnooze: some View {
        Menu {
            SnoozeMenu(
                isSnoozed: anySnoozed,
                onPick: { until in snoozeSelection(until: until) },
                onPickExact: { isPickingBulkSnooze = true }
            )
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.body)
                Text(.ui("Snooze"))
                    .font(.caption2)
                    .bulkButtonTitle()
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .foregroundStyle(.themeAccent)
    }

    /// Applies a bulk snooze and drops the selection.
    ///
    /// Targets resolved *before* the tick marks are cleared, for the same
    /// reason ``bulkButton`` does it: `checkedTargets` reads `checked`, and
    /// reading it afterwards snoozes nothing at all.
    private func snoozeSelection(until: Date?) {
        let targets = checkedTargets

        immediately { checked = [] }
        Task { await actions.perform(.snooze(until), on: targets) }
    }

    /// Whether anything ticked is already snoozed, which is what puts "Wake
    /// now" in the menu. A mixed selection still offers it: waking something
    /// that is awake is a no-op, where hiding the item strands the snoozed part
    /// of the selection.
    private var anySnoozed: Bool {
        rows.contains {
            checked.contains(ThreadRef(thread: $0.thread)) && $0.thread.snoozedUntil != nil
        }
    }

    private func bulkButton(
        _ title: LocalizedStringResource,
        _ symbol: String,
        role: ButtonRole? = nil,
        action: (() -> MailActions.BulkAction)? = nil,
        perform: (() -> Void)? = nil
    ) -> some View {
        Button(role: role) {
            if let action {
                // Both resolved *before* the selection is cleared. The action
                // is a closure over `checked` — `anyUnstarred` and friends read
                // it — so evaluating it afterwards computes the verb against an
                // empty set and sends the opposite of what the button said.
                let targets = checkedTargets
                let resolved = action()

                // Cleared before the request, not after: leaving rows ticked
                // while an archive is in flight invites a second tap on a
                // selection that is already on its way out.
                immediately { checked = [] }
                Task { await actions.perform(resolved, on: targets) }
            } else {
                perform?()
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption2)
                    .bulkButtonTitle()
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            role == .destructive
                ? AnyShapeStyle(Color.red) : AnyShapeStyle(ThemeAccent()))
    }

    /// Mixed selections get the action that changes the most rows: ticking a
    /// read and an unread message and pressing Read should leave both read,
    /// not flip each one.
    private var anyUnread: Bool {
        rows.contains { checked.contains(ThreadRef(thread: $0.thread)) && $0.thread.isUnread }
    }

    /// Only the rows actually loaded. "Select all" cannot mean the whole
    /// mailbox: the list is paged, and acting on messages nobody has seen is
    /// not something a button should quietly offer.
    private var allChecked: Bool {
        rows.isEmpty == false && checked.count >= rows.count
    }

    private var anyUnstarred: Bool {
        rows.contains {
            checked.contains(ThreadRef(thread: $0.thread)) && $0.thread.isFlagged == false
        }
    }

    // MARK: - Rows

    /// The feed table gives the order; the thread table gives the content.
    /// Joined here rather than denormalised into the feed row so that a
    /// thread changing — read, starred, a new reply — updates every list it
    /// appears in without touching the ordering.
    private var rows: [(entry: StoredFeedEntry, thread: StoredThread)] {
        // **Sliced, not whole.** `List` is lazy about drawing rows; it is not
        // lazy about the array it is handed. A 60,000-message mailbox built
        // 60,000 tuples and asked `ForEach` to diff 60,000 identities on every
        // body evaluation — every scroll frame, every selection change. The
        // window grows as the reader reaches the end, so nothing is
        // unreachable; it simply is not all built at once.
        entries.prefix(visibleCount).compactMap { entry in
            guard let thread = cachedThreadsByKey[ThreadKey(entry)] else { return nil }

            return (entry, thread)
        }
    }

    /// The join's right-hand side, built when the threads change rather than on
    /// every read.
    ///
    /// **This is a hot path.** `rows` is read by `ForEach`, so it runs on every
    /// body evaluation — every scroll, cursor move, hover and selection change —
    /// and `threads` is an unfiltered `@Query` over the whole table. Building
    /// the dictionary inside `rows` therefore walked every thread in the store,
    /// allocating an interpolated `String` per thread, many times a second. On a
    /// real mailbox on a real device that is the difference between a list that
    /// scrolls and one that does not.
    /// A pair of ids, so the join key costs no allocation.
    ///
    /// The interpolated `"\(account)#\(thread)"` it replaces allocated twice per
    /// row per frame and hashed a whole string to compare two short ids.
    private struct ThreadKey: Hashable {
        let accountKey: String
        let threadID: String

        init(_ entry: StoredFeedEntry) {
            accountKey = entry.accountKey
            threadID = entry.threadID
        }

        init(_ thread: StoredThread) {
            accountKey = thread.accountKey
            threadID = thread.threadID
        }
    }

    // MARK: - Label chips

    /// What the resolved chips were built for.
    ///
    /// Three inputs because three different things invalidate them: the rows on
    /// screen, the labels that exist (a rename or a recolour changes what a chip
    /// says, not just which rows have one), and a label applied from this
    /// screen, which moves neither of the other two.
    private struct ChipKey: Hashable {
        let threads: [String]
        let labels: [String]
        let revision: Int
    }

    /// What a category count depends on: the mailboxes' own unread figures,
    /// which the server refreshes on every sync and which move the moment a
    /// message is read.
    private var categoryCountKey: String {
        sync.mailboxes.map { "\($0.id)|\($0.unreadThreads)" }.joined(separator: ",")
    }

    private var chipKey: ChipKey {
        ChipKey(
            threads: entries.map { "\($0.accountKey)#\($0.threadID)" },
            labels: sync.mailboxes.map {
                "\($0.id)|\($0.name)|\($0.color?.rawValue ?? "")|\($0.parentID?.rawValue ?? "")"
            },
            revision: chipRevision
        )
    }

    /// Resolves every visible row's chips in one pass.
    ///
    /// One store call per account rather than per row. A binding id belongs to
    /// one account, so the projections have to be asked for per account anyway;
    /// what this avoids is asking per conversation, inside a `ForEach`, while
    /// the list is being flung.
    /// Counts the unread mail under each tab.
    ///
    /// Silent on failure, and deliberately: a strip with no numbers on it is
    /// the state it was in before this existed, and an alert about a count is
    /// an alert about nothing the reader can act on.
    private func loadCategoryCounts() async {
        guard categorySelection != nil else {
            categoryCounts = [:]

            return
        }

        categoryCounts = (try? await sync.store.unreadCountsByCategory()) ?? [:]
    }

    private func loadChips() async {
        let mailboxes = sync.mailboxes

        // An account with no custom labels can only ever produce empty chips,
        // and asking the store for projections to prove it is a walk over every
        // message of every visible conversation for nothing.
        guard mailboxes.contains(where: { $0.role == nil }) else {
            chips = [:]

            return
        }

        let hierarchy = LabelHierarchy(mailboxes)
        var threadsByAccount: [String: Set<String>] = [:]

        for entry in entries {
            threadsByAccount[entry.accountKey, default: []].insert(entry.threadID)
        }

        var resolved: [String: [LabelChipModel]] = [:]

        for (accountKey, threadIDs) in threadsByAccount {
            guard
                let projections = try? await sync.store.threadProjections(
                    threadIDs: Array(threadIDs), accountKey: accountKey)
            else { continue }

            for projection in projections {
                let models = LabelChipModel.chips(
                    forMailboxIDs: projection.mailboxIDs,
                    accountKey: accountKey,
                    mailboxes: mailboxes,
                    hierarchy: hierarchy
                )

                // Only rows that have any. A key per conversation in a mailbox
                // where nobody uses labels is a dictionary the size of the feed
                // holding nothing.
                if models.isEmpty == false {
                    resolved["\(accountKey)#\(projection.threadID)"] = models
                }
            }
        }

        chips = resolved
    }

    /// What an action applies to.
    ///
    /// The whole thread: archiving one reply and leaving the rest is not
    /// something anyone means, and this is a list of conversations.
    private func target(for thread: StoredThread) -> ActionTarget {
        ActionTarget(
            threadID: thread.threadID,
            accountKey: thread.accountKey,
            accountID: sync.accounts.first { $0.accountKey == thread.accountKey }?.accountID
                ?? AccountID(""),
            emailIDs: thread.emailIDs.map { EmailID(rawValue: $0) }
        )
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        Task { await work() }
    }

    private func accountTag(for entry: StoredFeedEntry) -> ThreadRowView.AccountTag? {
        guard sync.accounts.count > 1 else { return nil }

        guard
            let name = sync.accounts.first(where: { $0.accountKey == entry.accountKey })?
                .displayName
        else { return nil }

        return ThreadRowView.AccountTag(name: name, key: entry.accountKey)
    }

    // MARK: - Paging

    private func loadMoreIfNeeded(at entry: StoredFeedEntry) async {
        guard entry.uid == entries.last?.uid, isLoadingMore == false else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        await sync.loadMore(of: feed)
    }

    // MARK: - States

    /// Offline is a state, not an error.
    ///
    /// A home server is unreachable far more often than a cloud one — it
    /// reboots, the VPN drops, someone is upstairs. Showing cached mail
    /// with a quiet line saying so is honest; showing it silently would
    /// let someone believe they had seen everything.
    ///
    /// **"You're offline" is a different sentence from "nothing on nas.local
    /// answered".** One is about this device and nothing can be retried; the
    /// other is about the server and a retry is exactly the right thing to
    /// offer. Drawing them as one banner sends half the users to check a router
    /// that is working. `OfflineState` writes all three sentences, so the view
    /// picks rather than phrases.
    @ViewBuilder
    private var offlineBanner: some View {
        let offline = sync.offlineState
        let message = bannerText(offline)

        // Queued changes put the banner up on their own. A conversation that
        // has been archived has already left the list whether the server has
        // heard about it or not, so with nothing said, mail that is only
        // half-sent looks exactly like mail that is sent.
        if entries.isEmpty == false, message != nil || queuedCount(offline) > 0 {
            HStack(spacing: 8) {
                // A rejected credential is not a network problem, and the
                // wifi icon sent people to check their router. It is also the
                // one banner state with something to do about it — the mail
                // below stays readable either way, which is the whole point of
                // not signing out. Nothing being *wrong* — only slow — gets
                // neither icon.
                Image(systemName: bannerSymbol(offline, hasMessage: message != nil))

                VStack(alignment: .leading, spacing: 1) {
                    if let message {
                        Text(message)
                    }

                    // Said, not implied. An archive that has not reached the
                    // server is a change this device is holding, and a row that
                    // has already moved out of the list looks identical whether
                    // it was sent or is still waiting.
                    if queuedCount(offline) > 0 {
                        Text(.ui("\(queuedCount(offline)) changes waiting to send"))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                if sync.status == .unauthenticated {
                    Button(.ui("Sign in again")) { sync.requestReauthentication() }
                        .font(.footnote.weight(.semibold))
                } else if isRetryable(offline) {
                    // Absent while the device is offline, because pressing it
                    // could only fail — a button that cannot work is worse than
                    // no button.
                    Button(.ui("Retry")) { retry(offline) }
                        .font(.footnote.weight(.semibold))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) { Divider() }
            // `.contain` rather than `.combine`: combining folds the Sign in
            // again button into the sentence and leaves VoiceOver with no way
            // to press it, which would make the banner the only surface that
            // states the problem without offering the fix.
            .accessibilityElement(children: .contain)
        }
    }

    /// Which sentence the banner shows.
    ///
    /// A rejected credential wins outright: it is the one state a retry cannot
    /// fix, and describing it as a network problem is what sends people to
    /// check their router. Otherwise the offline state's own wording is
    /// preferred over the status line, because it distinguishes this device
    /// from the server where the status alone cannot.
    private func bannerText(_ offline: MailSyncService.OfflineState) -> String? {
        if sync.status == .unauthenticated { return sync.bannerMessage }

        return offline.message ?? sync.bannerMessage
    }

    /// How many changes are waiting to reach the server.
    ///
    /// The larger of the two counts. `MailSyncService.queuedActionCount` is only
    /// re-read when the queue is drained or a screen comes forward, so an action
    /// queued a second ago is not in it yet; `MailActions.queuedCount` is bumped
    /// as each one is enqueued but knows nothing about what an earlier launch
    /// left behind. Taking the maximum is the only reading that is never *lower*
    /// than the truth, and a banner that undercounts is one that quietly claims
    /// work it has not done.
    private func queuedCount(_ offline: MailSyncService.OfflineState) -> Int {
        max(offline.queued, actions.queuedCount)
    }

    /// Which glyph stands beside the sentence.
    ///
    /// A queue draining against a working server is not a fault, and a
    /// `wifi.slash` beside it would say the connection is down when it is not —
    /// which is the same conflation this banner was rewritten to stop making.
    private func bannerSymbol(
        _ offline: MailSyncService.OfflineState, hasMessage: Bool
    ) -> String {
        if sync.status == .unauthenticated { return "key.slash" }

        return hasMessage ? "wifi.slash" : "arrow.up.circle"
    }

    /// Whether a retry could plausibly work.
    ///
    /// `OfflineState` answers this for the states it can see, and deliberately
    /// says no while the device is offline. It reports `.current` when the
    /// *session* fetch failed before any per-account work ran, though —
    /// `degradedAccounts` is only ever filled by an account that got as far as
    /// syncing — so a whole-server failure has to be read off the status as
    /// well, or the one screen that names the problem offers nothing to do
    /// about it.
    private func isRetryable(_ offline: MailSyncService.OfflineState) -> Bool {
        if case .deviceOffline = offline { return false }

        if offline.isRetryable { return true }

        if case .failed = sync.status { return true }

        return false
    }

    /// Retries exactly the accounts that failed.
    ///
    /// One at a time, and never the healthy ones: this audience runs the server
    /// on a Raspberry Pi with a single PHP worker pool, and a retry that fans
    /// out across every account is how a server having a bad day is finished
    /// off by the client.
    ///
    /// A whole refresh only when there is no failing account to name — the case
    /// where the session itself never answered and there is nothing narrower to
    /// try.
    private func retry(_ offline: MailSyncService.OfflineState) {
        let keys = sync.degradedAccounts.keys.sorted()

        guard keys.isEmpty == false else {
            Task { await sync.refresh(feed: feed) }

            return
        }

        Task {
            for key in keys {
                await sync.retry(accountKey: key)
            }
        }
    }

    /// What stands in for the list when there is nothing in it.
    ///
    /// Three empties that look identical to a bare spinner are three different
    /// situations, and the difference is the only thing worth saying: mail is
    /// on its way, mail has never been fetched, or there genuinely is none. The
    /// last is the only one that is a fact about the mailbox, and it is the only
    /// one stated as one.
    @ViewBuilder
    private var emptyState: some View {
        if entries.isEmpty {
            switch sync.status {
            // A spinner alone says "wait" without saying for what, and on a
            // home server behind a VPN that wait is long enough to read a
            // sentence. The list also stays empty for the whole first sync, so
            // this is the screen a new install sits on.
            case .syncing:
                ContentUnavailableView {
                    Label {
                        Text(.ui("Still catching up"))
                    } icon: {
                        ProgressView()
                    }
                } description: {
                    Text(
                        .ui(
                            "Fetching mail from \(sync.serverID). Conversations appear as they arrive."
                        ))
                }

            // A rejected credential is not a network problem, and offering
            // "try again" for it would send someone to check their wifi.
            case .unauthenticated:
                ContentUnavailableView {
                    Label(.ui("Sign in again"), systemImage: "key.slash")
                } description: {
                    Text(
                        """
                        \(sync.serverID) rejected this app password. It may have been revoked in \
                        Settings → App passwords, or the account may have been removed.
                        """
                    )
                } actions: {
                    // Not `role: .destructive`, and not a sign-out. Replacing
                    // the app password keeps every cached message and every
                    // queued draft: the store is keyed by server and account,
                    // so it is still valid for the same server.
                    Button(.ui("Sign in again")) { sync.requestReauthentication() }
                }

            case .failed(let message):
                ContentUnavailableView {
                    Label(.ui("Can't reach your server"), systemImage: "wifi.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button(.ui("Try again")) { Task { await sync.refresh(feed: feed) } }
                }
            // Idle without ever having reached the server: the app is between
            // launch and its first request, or a sync was cancelled before it
            // started. The list is empty, but nothing has established that the
            // mailbox is — and "No mail here" would be a claim made on no
            // evidence, which is the one thing this app tries not to do.
            case .idle where sync.lastCheckedAt == nil:
                ContentUnavailableView {
                    Label(.ui("Nothing synced yet"), systemImage: "tray")
                } description: {
                    Text(
                        .ui(
                            "This list shows what is already on this device, and your server hasn't been reached yet."
                        ))
                } actions: {
                    Button(.ui("Check now")) { Task { await sync.refresh(feed: feed) } }
                }

            case .idle:
                ContentUnavailableView {
                    Label(.ui("No mail here"), systemImage: "tray")
                } description: {
                    Text(
                        .ui(
                            "This list covers mail plMail has synced. Older mail arrives as the sync window widens."
                        ))
                } actions: {
                    Button(.ui("Check now")) { Task { await sync.refresh(feed: feed) } }
                }
            }
        }
    }

    /// One failing account is named without emptying the list, because
    /// multi-account is the normal case: the other mailboxes are still
    /// perfectly usable.
    private var degradedSection: some View {
        Section {
            ForEach(degraded, id: \.key) { entry in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountName(entry.key)).font(.footnote)
                        Text(entry.value).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(.ui("Some accounts didn't sync"))
        }
    }

    /// Empty while the device itself is offline.
    ///
    /// Every account fails for that one reason, and listing five "couldn't
    /// reach nas.local" rows implies five separate faults to go and look at.
    /// The banner has already said the true one.
    private var degraded: [(key: String, value: String)] {
        guard sync.isDeviceOffline == false else { return [] }

        return sync.degradedAccounts.sorted { $0.key < $1.key }
    }

    private func accountName(_ accountKey: String) -> String {
        sync.accounts.first { $0.accountKey == accountKey }?.displayName ?? accountKey
    }
}

/// Keeps a bulk-bar caption on one line.
///
/// Six captions share a phone's width, and German is roughly a third longer
/// than English — untreated, "Zurückstellen" wraps and hyphenates itself into
/// "Zurückstel-len" while its neighbours stay on one line, which reads as a
/// broken row rather than a long word. Shrinking a little is the smaller cost,
/// and the floor is high enough to stay legible.
extension View {
    fileprivate func bulkButtonTitle() -> some View {
        lineLimit(1).minimumScaleFactor(0.7)
    }
}

#endif
