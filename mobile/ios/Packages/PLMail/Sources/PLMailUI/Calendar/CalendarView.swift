#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI
import UniformTypeIdentifiers

/// The calendar screen, on every canvas it can be given.
///
/// **One view for both idioms, resolved from the measured width rather than
/// from the idiom**, exactly as `MailView` does: `MailLayout.resolve` answers
/// how many panes the container can carry, and a phone, a Slide Over panel and
/// a 700pt Stage Manager window get the same answer for the same reason. There
/// is deliberately no second set of breakpoints here — a competing one would
/// disagree with mail's about the same window.
///
/// - `.single` — the board fills the container, an event pushes.
/// - `.dual` — the board with a **standing inspector** beside it, so scanning a
///   week and reading an event are simultaneous rather than alternating.
/// - `.triple` — a calendar rail as well, carrying the visibility toggles and
///   Today.
///
/// **Refreshes happen while somebody is looking and at no other time.** There
/// is no timer here, no background task and no push subscription: the calendar
/// state is the literal `"fixed"`, `canCalculateChanges` is false, and this
/// audience runs the server on a Raspberry Pi with a single PHP worker pool.
/// The window is re-queried when it appears and when the reader pulls, and
/// stepping to another period is another window rather than another poll.
public struct CalendarView: View {
    private let onCollapse: (() -> Void)?

    @State private var service: CalendarService
    @State private var mode: CalendarViewMode
    @State private var anchor: CalendarDay
    @State private var selectedDay: CalendarDay?
    /// The standing selection, shared by every mode and **kept across a
    /// rotation or a Stage Manager resize**: it is an occurrence id underneath,
    /// so a re-query of the same window re-resolves it rather than dropping it.
    @State private var selection: EventCluster?
    /// What a compact layout has pushed. Separate from ``selection`` on
    /// purpose — a window widened while an event is selected must not leave a
    /// pushed screen behind the inspector, and a window narrowed must not
    /// push something the reader did not tap.
    @State private var pushed: EventCluster?
    @State private var openSeries: CalendarEventSnapshot?
    @State private var editing: EditorRequest?
    @State private var deleting: CalendarEventSnapshot?
    @State private var writeFailure: WriteFailure?
    @State private var sharing: ICSDocument?
    @State private var searchText = ""
    /// Whether the bar's magnifier has opened the field beneath it. Only a
    /// regular width has one — a compact width keeps `.searchable`, which is
    /// what a phone reader already knows how to reach.
    @State private var isShowingSearchField = false
    /// Zero until the first layout pass. `MailLayout.resolve` treats that as
    /// "unmeasured" and falls back to the size class.
    @State private var containerWidth: CGFloat = 0

    /// An occurrence named from outside the app, waiting for the window it is
    /// on to finish drawing.
    ///
    /// Held rather than selected on the spot because the anchor has only just
    /// moved: the clusters on screen at that instant are still the *previous*
    /// day's, so selecting immediately would find nothing and read as a
    /// Spotlight result that did nothing. Cleared by the re-query that lands.
    @State private var awaitingOccurrence: CalendarEventID?

    /// True when a route in from outside named an event the cache no longer
    /// holds.
    ///
    /// The whole reason indexing events is safe: system search can hand back a
    /// meeting that has since been cancelled, and the honest answer is a
    /// sentence saying so rather than the calendar sitting on today looking as
    /// though the tap missed.
    @State private var isShowingVanishedEvent = false

    @Environment(\.openWindow) private var openWindow
    /// False on iPhone and on an iPad with multitasking switched off, where an
    /// "Open in new window" that opens nothing is worse than its absence.
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private let preferences = CalendarPreferences()

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    /// - Parameters:
    ///   - service: the calendar stack this screen drives.
    ///   - day: where to open. Nil means today, which is what every caller
    ///     inside the app wants; a window scene restored from disk passes the
    ///     day it was persisted with, so reopening the app does not silently
    ///     drag a window the reader left on next March back to this morning.
    ///   - onCollapse: the way back out, drawn as the design's collapse mark at
    ///     the right of the calendar's own bar. Nil where the presentation
    ///     already supplies one — a pushed column, a window scene — because two
    ///     ways out of one screen is how they drift apart.
    public init(
        service: CalendarService, day: CalendarDay? = nil, onCollapse: (() -> Void)? = nil
    ) {
        self.onCollapse = onCollapse
        _service = State(wrappedValue: service)
        let stored = CalendarPreferences().mode
        _mode = State(wrappedValue: stored)
        _anchor = State(wrappedValue: day ?? CalendarDay(.now, in: .current))
    }

    /// How many panes this container can carry. The tested resolver, on this
    /// view's own measured width — not the window's, because the calendar may
    /// be a column inside something else.
    private var layout: MailLayout {
        MailLayout.resolve(width: containerWidth, isCompactSizeClass: sizeClass == .compact)
    }

    /// Compact month is the grid-plus-list split, which is what iOS Calendar
    /// does and what the web calls `month-agenda`.
    private var isCompact: Bool { layout.mode == .single }

    private var window: CalendarWindow {
        mode.window(anchor: anchor, using: calendar)
    }

    /// What is asked for, which is **not** always what is drawn.
    ///
    /// The week strip marks the days that have something on them, and it can
    /// only mark what the service has been asked to load. In day mode the
    /// window is one day, so exactly one dot could ever appear — the day you
    /// were already looking at — which made the strip look broken rather than
    /// empty.
    ///
    /// So a day or an agenda fetches the whole week the strip is drawing.
    /// Nothing downstream has to know: the grid places clusters by day and the
    /// agenda filters by `window.days`, so the extra days are loaded and not
    /// drawn. It also means stepping a day inside the same week asks the
    /// server for nothing at all.
    private var fetchWindow: CalendarWindow {
        guard mode == .day || mode == .agenda else { return window }

        let weekStart = anchor.startOfWeek(using: calendar)
        let weekEnd = weekStart.adding(days: 7)

        return CalendarWindow(from: min(weekStart, window.from), to: max(weekEnd, window.to))
            ?? window
    }

    /// **No `NavigationStack` of its own.**
    ///
    /// The enclosing container supplies one — `MailView`'s split view already
    /// does for every column — because a stack nested inside another stack
    /// swallows the push and leaves the detail screen unreachable. Presenting
    /// this from a sheet or a tab means wrapping it in ``CalendarScreen``,
    /// which is the one place a stack is created.
    public var body: some View {
        panes
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                containerWidth = $0
            }
            // Said once. ``CalendarBar`` carries the heading wherever it is
            // drawn, and a navigation bar repeating it above the card is the
            // same date twice in two type sizes.
            .navigationTitle(
                layout.mode == .single
                    ? CalendarHeading.text(
                        mode: mode,
                        anchor: anchor,
                        locale: locale,
                        calendar: calendar,
                        timeZone: timeZone
                    )
                    : ""
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarVisibility(layout.mode == .single ? .automatic : .hidden, for: .navigationBar)
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text(.ui("Search these dates"))
            )
            .refreshable { await service.refresh(window) }
            .task(id: fetchWindow) { await show() }
            .environment(\.calendarEventActions, eventActions)
            .navigationDestination(item: $pushed) { cluster in
                detail(for: cluster)
            }
            .sheet(item: $editing) { request in
                editor(for: request)
            }
            .sheet(item: $sharing) { document in
                ICSShareSheet(document: document)
            }
            .confirmationDialog(
                Text(.ui("Delete event")),
                isPresented: isConfirmingDelete,
                titleVisibility: .visible,
                presenting: deleting
            ) { series in
                Button(role: .destructive) {
                    Task { await delete(series) }
                } label: {
                    Text(.ui("Delete"))
                }

                Button(role: .cancel) {
                } label: {
                    Text(.ui("Cancel"))
                }
            } message: { series in
                // **A calendar has no bin.** Said here rather than only after
                // the fact, and with a distinct sentence when the event
                // repeats, because "delete" on a series is a much larger action
                // than "delete" on one entry looks.
                if series.isRecurring {
                    Text(
                        .ui(
                            "This deletes every occurrence of this repeating event. There is no bin to get it back from."
                        ))
                } else {
                    Text(
                        .ui(
                            "This deletes this event on the server. There is no bin to get it back from."
                        ))
                }
            }
            .alert(
                Text(writeFailure?.title ?? .ui("This wasn't deleted")),
                isPresented: isShowingWriteFailure,
                presenting: writeFailure
            ) { _ in
                Button(role: .cancel) {
                } label: {
                    Text(.ui("OK"))
                }
            } message: { failure in
                if let detail = failure.detail { Text(detail) }
            }
            .onChange(of: selection) { _, cluster in
                guard let cluster else {
                    openSeries = nil

                    return
                }

                Task {
                    openSeries = await service.series(cluster.representative.seriesID)
                }
            }
            // A re-query rebuilds every cluster, so the selection is matched
            // back by occurrence id rather than by value: comparing whole
            // clusters would drop it the moment a calendar's colour arrived.
            .onChange(of: service.clusters) { _, clusters in
                selection = CalendarSelection.reselect(
                    selection?.representative.occurrenceID, in: clusters)

                openAwaitedOccurrence(in: clusters)
            }
            .onChange(of: CalendarIntentRouter.shared.pending) { _, _ in performPendingRequest() }
            // The first pick-up, and the one that matters most: an App Intent,
            // a Spotlight tap and a Handoff continuation all post their request
            // **before** this view exists, so an `onChange` alone would never
            // fire for the very launches these routes are for. The same pairing
            // `MailView` uses.
            .task { performPendingRequest() }
            // Told rather than inferred, because the shell has to know whether
            // there is anybody here to consume a request before it decides to
            // present a calendar of its own.
            .onAppear { CalendarIntentRouter.shared.beganShowing() }
            .onDisappear { CalendarIntentRouter.shared.stoppedShowing() }
            .alert(
                Text(.ui("That event isn't here any more")),
                isPresented: $isShowingVanishedEvent
            ) {
                Button(role: .cancel) {
                } label: {
                    Text(.ui("OK"))
                }
            } message: {
                Text(.ui("It may have been deleted since it was last synced."))
            }
            .background(hiddenShortcuts)
    }

    // MARK: - The panes

    @ViewBuilder
    private var panes: some View {
        if service.availability.isAvailable == false {
            // **A supported instance, not an error.** A user can delete their
            // last mailbox and keep a calendar, and a server that publishes
            // none has to read as a server without the feature.
            ContentUnavailableView(
                .ui("This server does not have a calendar"),
                systemImage: "calendar",
                description: Text(.ui("Calendars are set up in plMail on the web."))
            )
        } else {
            VStack(spacing: 0) {
                // The bar and the week span the **whole** card, above the rule
                // rather than beside it: they are about the calendar, and a
                // heading that stopped two thirds of the way across would read
                // as belonging to the grid alone.
                if layout.mode != .single {
                    CalendarBar(
                        heading: CalendarHeading.text(
                            mode: mode, anchor: anchor, locale: locale, calendar: calendar,
                            timeZone: timeZone),
                        mode: $mode,
                        canPage: mode.isPageable,
                        onStep: { step($0) },
                        onToday: goToToday,
                        onCreate: canCreate ? { editing = .create(proposedStart) } : nil,
                        isSearching: $isShowingSearchField,
                        onCollapse: onCollapse)

                    if isShowingSearchField {
                        CalendarSearchField(text: $searchText) {
                            searchText = ""
                            isShowingSearchField = false
                        }
                    }

                    // Only above a day. A week grid already draws its seven
                    // days, and a month grid draws thirty of them — a strip
                    // over either is the same week said twice.
                    if mode == .day || mode == .agenda {
                        WeekStrip(anchor: anchor, clusters: service.clusters, selection: $anchor)
                    }
                }

                HStack(spacing: 0) {
                    // **No sidebar of its own.** It used to carry Today, the five
                    // view modes and the calendar toggles in a 220pt column; the
                    // design puts the first two in the bar across the top of the
                    // card, and a screen offering the same state twice is a screen
                    // where the two drift. The toggles moved to the overflow menu,
                    // which is where every width now finds them.
                    // **One card, divided by a rule** — not two cards side by
                    // side. The container already draws the card: whoever presents
                    // this view carries `paneSurface`, and a pane drawing a second
                    // one inside it is the "card inside a card" the redesign spent
                    // three rounds removing from the mail side.
                    board
                        .frame(maxWidth: .infinity)

                    if layout.mode != .single {
                        Rectangle()
                            .fill(palette.line.color)
                            .frame(width: 1)

                        inspector
                            .frame(width: inspectorWidth)
                    }
                }
            }
            // The card, drawn here rather than by whoever presents this: a
            // cover, a window scene and a sheet all present it, and three
            // presenters each remembering to draw the same card is three
            // chances for one of them to forget. Regular widths only — a
            // phone's calendar fills its screen, and a 12pt moat around it
            // would be twelve points taken off a day that already has none to
            // spare.
            .modifier(CalendarCard(isDrawn: layout.isSeparated, palette: palette))
        }
    }

    /// Wide enough for a title, a date line and two buttons without wrapping,
    /// and no wider — every point here comes off the grid, which is the pane
    /// the reader is actually scanning.
    private var inspectorWidth: CGFloat { layout.mode == .triple ? 320 : 300 }

    /// The standing detail column: **the payoff of a large canvas**.
    ///
    /// On a phone, opening an event replaces the calendar; here it does not, so
    /// arrowing down a week reads each event in turn without anything being
    /// covered up. Empty is a real state and says so rather than being blank.
    @ViewBuilder
    private var inspector: some View {
        if let selection {
            detail(for: selection)
        } else {
            ContentUnavailableView(
                .ui("No event selected"),
                systemImage: "calendar.day.timeline.left",
                description: Text(.ui("Choose an event to see it here."))
            )
        }
    }

    @ViewBuilder
    private var board: some View {
        VStack(spacing: 0) {
            statusNotice

            content

            if service.mayBeIncomplete { horizonFooter }
        }
    }

    @ViewBuilder
    private var content: some View {
        // Only the list says "nothing". A grid with nothing in it is already
        // the clearest possible statement that nothing is in it, and covering
        // the hours with a message takes away the one thing a grid is for —
        // seeing where the free time is.
        if visible.isEmpty, isSearching {
            // A different sentence from an empty period, because it is a
            // different fact. `CalendarEvent/query` refuses every condition but
            // `inCalendar`, `after` and `before` — there is no server-side text
            // search — so a search here covers the dates that happen to be
            // cached and has to say so rather than reading as "you have no such
            // meeting".
            ContentUnavailableView(
                .ui("Nothing found in these dates"),
                systemImage: "magnifyingglass",
                description: Text(.ui("Search only covers the dates you have loaded."))
            )
        } else if visible.isEmpty, mode == .agenda || shouldFallBackToAgenda {
            ContentUnavailableView(
                .ui("Nothing in this period"),
                systemImage: "calendar"
            )
        } else if shouldFallBackToAgenda {
            // At accessibility text sizes a week grid is seven columns of
            // hyphenated fragments, which is worse than the list it replaced.
            // The honest answer at the top sizes is a different view, not
            // smaller text.
            AgendaView(window: window, clusters: visible, onOpen: open)
        } else {
            switch mode {
            case .agenda:
                AgendaView(window: window, clusters: visible, onOpen: open)
            case .day, .week:
                TimeGridView(
                    window: window,
                    clusters: visible,
                    onOpen: open,
                    // The slot **unrounded**: `slotAt` already snapped it to
                    // the quarter hour, and rounding again would move a tap on
                    // the 14:15 line to 15:00 — the one thing the gesture
                    // promises not to do.
                    onCreate: canCreate ? { editing = .create($0) } : nil,
                    // A week names its seven columns; a day does not need to.
                    // The bar says the date and the strip above it says the
                    // week, so a third row saying "Tue 25" is the same fact a
                    // third time.
                    showsDayHeader: mode == .week
                )
            case .month:
                MonthGridView(
                    window: window,
                    anchor: anchor,
                    clusters: visible,
                    isCompact: isCompact,
                    selection: $selectedDay,
                    onOpen: open,
                    onCreate: canCreate ? { editing = .create(start(on: $0)) } : nil
                )
            case .year:
                YearGridView(
                    anchor: anchor,
                    clusters: visible,
                    onOpenMonth: { month in
                        anchor = month
                        mode = .month
                    }
                )
            }
        }
    }

    /// What the board draws: the window's clusters, narrowed by the search
    /// field.
    ///
    /// Local, over the cache, and it cannot be anything else — see
    /// ``content``'s empty state.
    private var visible: [EventCluster] {
        CalendarSearch.filter(service.clusters, query: searchText, series: service.seriesByID)
    }

    private var isSearching: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    /// Whether any calendar on this server accepts a new event. Straight from
    /// `myRights`, which is the only authority: guessing from anything else
    /// produces a `forbidden` after the user has typed the whole event.
    private var canCreate: Bool { service.writableCalendars.isEmpty == false }

    private var shouldFallBackToAgenda: Bool {
        typeSize.isAccessibilitySize && (mode == .week || mode == .month || mode == .year)
    }

    /// The three empty and failure states, which are genuinely different and
    /// must read differently.
    @ViewBuilder
    private var statusNotice: some View {
        switch service.status {
        case .failed(.unreachable(let host)):
            // Names the host, because plMail users self-host and the hostname
            // is the actionable half of the sentence.
            notice(text: Text(.ui("Can't reach \(host)")), symbol: "wifi.slash")
        case .failed(.rejected):
            notice(
                text: Text(.ui("The server refused this request")),
                symbol: "exclamationmark.triangle")
        case .failed(.beyondHorizon):
            notice(
                text: Text(.ui("This range is outside what the server keeps")),
                symbol: "calendar.badge.exclamationmark")
        case .failed(.noCalendarAccount):
            notice(text: Text(.ui("This server does not have a calendar")), symbol: "calendar")
        default:
            EmptyView()
        }
    }

    private func notice(text: Text, symbol: String) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PanelStyle.inset)
        .padding(.vertical, 6)
        .background(PanelStyle.hairline)
        .accessibilityElement(children: .combine)
    }

    /// **Never a silent stop.** The clamp says "there may be more" rather than
    /// letting a month end without explanation — and the server's own
    /// `materialisedHorizon` strings stay in diagnostics, since they are PHP
    /// relative-date expressions nothing here may parse.
    private var horizonFooter: some View {
        Text(.ui("There may be more beyond this range"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Paging, the mode switch and Today live in ``CalendarBar`` wherever
        // that bar is drawn. They stay here for a compact width, which has no
        // room for the bar and keeps the system's navigation bar instead —
        // offering both at once would be two controls for one piece of state.
        if layout.mode == .single {
            if mode.isPageable {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        step(-1)
                    } label: {
                        Label(.ui("Previous"), systemImage: "chevron.left")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        step(1)
                    } label: {
                        Label(.ui("Next"), systemImage: "chevron.right")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(.ui("Today")) { goToToday() }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                editing = .create(proposedStart)
            } label: {
                Label(.ui("New event"), systemImage: "plus")
            }
            // **Disabled, not hidden**, when `myRights` accepts new items
            // nowhere. A control that vanishes teaches nothing; this one says
            // why, and the sentence is what sends somebody to the web UI to fix
            // their sharing.
            .disabled(canCreate == false)
            .accessibilityLabel(
                canCreate
                    ? Text(.ui("New event"))
                    : Text(
                        .ui(
                            "New event, \(String(localized: .ui("You can't add events to any calendar here")))"
                        ))
            )
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if layout.mode == .single {
                    Picker(selection: $mode) {
                        modeChoices
                    } label: {
                        Text(.ui("View"))
                    }
                }

                // The rail carries these where there is one, so they are not
                // offered twice on the same screen — two controls for one state
                // is how they drift apart.
                // The visible route to a calendar window. Absent rather than
                // disabled where the system cannot open one at all, and
                // deliberately **without a keyboard shortcut**: ⌘0 already
                // opens the calendar and ⌘1…⌘5 are its view modes, and
                // iPadOS installs shortcuts of its own for a
                // `NavigationSplitView` — a duplicate makes
                // `UIKitMainMenuController.buildMenu` throw and the app
                // terminates on launch.
                if supportsMultipleWindows {
                    Divider()

                    Button(action: openInNewWindow) {
                        Label(.ui("Open in new window"), systemImage: "macwindow.on.rectangle")
                    }
                }

                if service.calendars.isEmpty == false {
                    Divider()

                    calendarToggles
                }
            } label: {
                Label(.ui("View"), systemImage: "calendar.day.timeline.left")
            }
            .onChange(of: mode) { _, new in
                preferences.setMode(new, isCompactMonth: isCompact)
            }
        }
    }

    /// Every mode, always, driven by an array rather than by five inline
    /// `Text`s.
    ///
    /// **Year is never withdrawn**, and that is the fix for a bug worth
    /// recording: it used to be offered only above a width threshold, and a
    /// saved Year preference then opened on Month and *rewrote itself on the
    /// way past* — a preference silently destroyed by a layout decision. A
    /// `Picker` also cannot reliably select a tag that lives inside a
    /// conditional, so the two failures compounded and looked like the
    /// preference never being read. It degrades instead: the year grid is an
    /// adaptive grid of month tiles, so a narrow container gets two columns
    /// rather than four and every tile stays a hit target.
    private var modeChoices: some View {
        ForEach(CalendarViewMode.allCases, id: \.self) { choice in
            Text(CalendarModeName.text(choice)).tag(choice)
        }
    }

    @ViewBuilder
    private var calendarToggles: some View {
        ForEach(service.calendars) { calendar in
            Button {
                Task {
                    await service.setHidden(
                        service.isShown(calendar), calendar: calendar.calendarID)
                }
            } label: {
                Label {
                    Text(calendar.name)
                } icon: {
                    Image(
                        systemName: service.isShown(calendar)
                            ? "checkmark.circle.fill" : "circle")
                }
            }
        }
    }

    // MARK: - Keyboard

    /// The keyboard map, with every shortcut also present as a visible control.
    ///
    /// Hidden buttons in `.background` rather than modifiers on the toolbar
    /// items, so both routes hit exactly one action — the house style's rule
    /// for hardware keyboards, and the reason ⌘ variants do not drift from what
    /// the button does.
    ///
    /// **Nothing here is a menu item, deliberately.** `MailCommands` lives in a
    /// file this change does not own, and an item whose key equivalent collides
    /// with one iPadOS installs for `NavigationSplitView` does not merely look
    /// untidy: `UIKitMainMenuController.buildMenu` throws
    /// `NSInvalidArgumentException` and the app terminates on launch. These are
    /// responder-chain key commands, which is a different mechanism.
    ///
    /// What was added to the four ⌘1…⌘4 the calendar already owned, and why:
    ///
    /// | Key | Action | Visible equivalent |
    /// |---|---|---|
    /// | `⌘5` | Year | the mode picker |
    /// | `⌘⌥N` | New event | the **+** toolbar button |
    /// | `⌘T` | Today | the Today button |
    /// | `↑` `↓` | select the previous/next event | tapping the chip |
    /// | `⏎` | open the selected event | tapping the chip |
    /// | `⌫` | delete the selected event | Delete in the inspector |
    /// | `Esc` | clear the selection | the inspector's empty state |
    ///
    /// ⌘N is **not** taken: `MailView` binds it to New Message and keeps doing
    /// so while the calendar is up, and one key with two meanings is a guess
    /// rather than a shortcut. ⌘F is left to Find for the same reason; the
    /// search field is in the toolbar and reachable without it.
    private var hiddenShortcuts: some View {
        Group {
            Button(.ui("Day")) { mode = .day }.keyboardShortcut("1", modifiers: .command)
            Button(.ui("Week")) { mode = .week }.keyboardShortcut("2", modifiers: .command)
            Button(.ui("Month")) { mode = .month }.keyboardShortcut("3", modifiers: .command)
            Button(.ui("Agenda")) { mode = .agenda }.keyboardShortcut("4", modifiers: .command)
            Button(.ui("Year")) { mode = .year }.keyboardShortcut("5", modifiers: .command)

            Button(.ui("Today")) { goToToday() }.keyboardShortcut("t", modifiers: [])
            Button(.ui("Today")) { goToToday() }.keyboardShortcut("t", modifiers: .command)
            Button(.ui("Previous")) { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button(.ui("Next")) { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])

            Button(.ui("New event")) { editing = .create(proposedStart) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(canCreate == false)

            Button(.ui("Previous event")) { moveSelection(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button(.ui("Next event")) { moveSelection(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button(.ui("Open")) { if let selection { open(selection) } }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selection == nil)
            Button(.ui("Delete event")) { deleting = openSeries }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(openSeries == nil)
            Button(.ui("Clear selection")) { selection = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(selection == nil)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func moveSelection(_ steps: Int) {
        guard
            let next = CalendarSelection.step(
                from: selection?.representative.occurrenceID, in: visible, by: steps)
        else { return }

        selection = next
    }

    // MARK: - Writing

    /// Which editor to present. A closed pair rather than two optionals, so
    /// "create" and "edit" cannot both be set and race to present a sheet.
    private enum EditorRequest: Identifiable, Hashable {
        /// A new event at this wall clock — the next whole hour from the
        /// toolbar, or the tapped slot **unrounded** from the grid.
        ///
        /// The title rides along because an App Intent can supply one. It is
        /// **prefilled and never saved**: an event created unattended by voice,
        /// on a surface with no undo and no bin, is the class of action this
        /// codebase refuses to take without somebody looking at it.
        case create(LocalDateTime, title: String? = nil)
        case edit(CalendarEventSnapshot)

        var id: String {
            switch self {
            case .create(let start, let title): "create/" + start.rawValue + "/" + (title ?? "")
            case .edit(let series): "edit/" + series.id
            }
        }
    }

    /// A refusal, in a shape an alert can present.
    private struct WriteFailure: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        /// The server's own sentence, as detail under a translated lead. It is
        /// untranslated English, and it is also the only part of the answer
        /// that says what went wrong.
        let detail: String?
    }

    @ViewBuilder
    private func editor(for request: EditorRequest) -> some View {
        switch request {
        case .create(let start, let title):
            EventEditorView(service: service, creatingAt: start, title: title) { outcome in
                report(outcome, failureTitle: .ui("This wasn't saved"))
            }
        case .edit(let series):
            EventEditorView(service: service, editing: series) { outcome in
                report(outcome, failureTitle: .ui("This wasn't saved"))
            }
        }
    }

    private func detail(for cluster: EventCluster) -> some View {
        EventDetailView(
            cluster: cluster,
            series: openSeries,
            calendar: service.calendar(cluster.representative.calendarID),
            onEdit: { if let openSeries { editing = .edit(openSeries) } },
            onDelete: { deleting = openSeries },
            onShare: { share(cluster) }
        )
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding {
            deleting != nil
        } set: { shown in
            if shown == false { deleting = nil }
        }
    }

    private var isShowingWriteFailure: Binding<Bool> {
        Binding {
            writeFailure != nil
        } set: { shown in
            if shown == false { writeFailure = nil }
        }
    }

    private func delete(_ series: CalendarEventSnapshot) async {
        let outcome = await service.delete(series.eventID)

        // The screens are showing something that no longer exists, so they are
        // dismissed before the report rather than after — a detail that stays
        // open on a deleted event is the next thing somebody taps.
        if outcome.didWrite {
            pushed = nil
            selection = nil
            openSeries = nil
        }

        report(outcome, failureTitle: .ui("This wasn't deleted"))
    }

    /// Reports and never retries. A refusal replayed is a loop that terminates
    /// never, and the optimistic change has already been rolled back — so there
    /// is nothing to undo either.
    private func report(
        _ outcome: CalendarWriteOutcome, failureTitle: LocalizedStringResource
    ) {
        switch outcome {
        case .saved, .deleted:
            writeFailure = nil
        case .refused(let reason, let isForbidden):
            writeFailure = WriteFailure(
                title: isForbidden ? .ui("This calendar doesn't accept changes") : failureTitle,
                detail: reason)
        case .unreachable(let host):
            writeFailure = WriteFailure(title: .ui("Can't reach \(host)"), detail: nil)
        case .noCalendar:
            writeFailure = WriteFailure(
                title: .ui("This server does not have a calendar"), detail: nil)
        }
    }

    // MARK: - Actions on one event

    /// What a chip's context menu and its VoiceOver rotor both offer.
    ///
    /// Composed here rather than in each grid so that a mode cannot be missed:
    /// the actions go into the environment once and every chip below picks them
    /// up. Edit and Delete are **nil where `myRights` refuse them**, which
    /// takes the item out of the menu rather than leaving a row that does
    /// nothing — the inspector is where a refusal is explained, because it has
    /// room to say why.
    private var eventActions: CalendarEventActions {
        CalendarEventActions(
            open: open,
            edit: rights(\.mayUpdateAll) ? { cluster in beginEdit(cluster) } : nil,
            delete: rights(\.mayRemoveItems) ? { cluster in beginDelete(cluster) } : nil,
            copyTitle: { cluster in
                UIPasteboard.general.string = cluster.representative.title
            },
            share: share
        )
    }

    /// Whether **any** visible calendar grants a right.
    ///
    /// Any rather than all, because the menu is built once for every chip on
    /// screen and the chips are on different calendars. A `forbidden` is still
    /// handled at the write, since rights can change between the menu opening
    /// and the save.
    private func rights(_ path: KeyPath<CalendarSnapshot, Bool>) -> Bool {
        service.calendars.contains { $0[keyPath: path] }
    }

    private func beginEdit(_ cluster: EventCluster) {
        Task {
            guard let series = await service.series(cluster.representative.seriesID) else {
                return
            }

            openSeries = series
            editing = .edit(series)
        }
    }

    private func beginDelete(_ cluster: EventCluster) {
        Task { deleting = await service.series(cluster.representative.seriesID) }
    }

    /// Writes the occurrence to a temporary `.ics` and offers it to the share
    /// sheet.
    ///
    /// **Not EventKit.** `EKEventEditViewController` needs
    /// `NSCalendarsWriteOnlyAccessUsageDescription` in the app's `Info.plist`,
    /// which is a file this change does not own, and a build that reaches the
    /// system editor without it terminates rather than degrades. An `.ics`
    /// needs no entitlement and no usage string, and Apple's own Calendar
    /// accepts one as readily as anything else does.
    private func share(_ cluster: EventCluster) {
        Task {
            let series = await service.series(cluster.representative.seriesID)
            let text = ICSExport.file(
                for: cluster,
                series: series,
                untitled: String(localized: .ui("Untitled")))

            sharing = ICSDocument(name: ICSExport.filename(for: cluster), contents: text)
        }
    }

    // MARK: - Moving about

    /// Where the **+** button proposes a new event.
    ///
    /// The next whole hour on the anchored day: an editor opened at 14:07 that
    /// proposes 14:07 asks the user to correct a time nobody would ever choose.
    /// When the anchor is not today the hour is carried across, so creating on
    /// a day the user is looking at does not silently open on today.
    private var proposedStart: LocalDateTime {
        start(on: selectedDay ?? anchor)
    }

    private func start(on day: CalendarDay) -> LocalDateTime {
        let hour = EventFormState.nextWholeHour(after: .now, in: timeZone)

        return LocalDateTime(
            year: day.year, month: day.month, day: day.day,
            hour: hour.components.hour ?? 9, minute: 0, second: 0)
    }

    private func goToToday() {
        anchor = CalendarDay(.now, in: timeZone)
        selectedDay = nil
    }

    private func step(_ direction: Int) {
        anchor = mode.step(from: anchor, by: direction)
        selectedDay = nil
    }

    private func open(_ cluster: EventCluster) {
        selection = cluster

        // A phone replaces the calendar with the event; a wide layout has a
        // column standing ready and must not also push.
        if layout.mode == .single { pushed = cluster }
    }

    // MARK: - Showing, and its two consequences

    /// The window on screen, drawn from the cache and then refreshed — and the
    /// two things that follow from a refresh having happened.
    ///
    /// Both are **consequences**, never reasons: system search indexes what the
    /// cache already holds, and the widget is handed what the screen already
    /// drew. Neither asks the server anything, which is the whole of why they
    /// are allowed to exist at all against a Raspberry Pi with one PHP worker
    /// pool.
    private func show() async {
        await service.show(fetchWindow)
        publishWidgetState()
        await service.indexForSpotlight()
    }

    private func publishWidgetState() {
        service.publishWidgetState(allDayWord: CalendarWords.allDay, locale: locale)
    }

    /// An App Intent, a Spotlight result or a Handoff continuation, picked up
    /// from the router the system's own objects can reach.
    private func performPendingRequest() {
        guard let request = CalendarIntentRouter.shared.take() else { return }

        switch request {
        case .show(let day):
            anchor = day ?? CalendarDay(.now, in: timeZone)
            selectedDay = day
        case .create(let title, let day):
            // Prefilled and presented, never saved. Creating an event by voice
            // on a surface with no undo and no bin is not something this app
            // does without somebody looking at it.
            anchor = day ?? anchor
            editing = .create(start(on: day ?? anchor), title: title)
        case .occurrence(let accountKey, let occurrenceID):
            Task { await show(occurrenceID, accountKey: accountKey) }
        }
    }

    /// Opens one occurrence named from outside the app.
    ///
    /// **Resolved against the cache first, and the whole route hangs off that
    /// read.** The index was written at one moment and tapped at another, and
    /// in between the meeting can be cancelled and its row dropped. A nil here
    /// is answered with a sentence; anything else would leave the reader on
    /// today's calendar with no idea whether the tap missed, the event moved or
    /// the app is broken — which is exactly what makes an indexed-but-
    /// unreachable event worse than an unindexed one.
    ///
    /// It asks the server nothing. The event is either already cached — it had
    /// to be, or it would never have been indexed — or it is gone.
    private func show(_ occurrenceID: CalendarEventID, accountKey: String) async {
        guard let row = await service.occurrence(occurrenceID, accountKey: accountKey),
            let day = CalendarDeepLink.day(of: row)
        else {
            isShowingVanishedEvent = true

            return
        }

        // Selected only once the window it lives on has been drawn: moving the
        // anchor restarts `task(id: window)`, and the clusters on screen at
        // this instant are still the previous period's.
        awaitingOccurrence = occurrenceID
        anchor = day
        selectedDay = day

        // Already on the right window — nothing will re-query, so nothing
        // would ever deliver the selection.
        openAwaitedOccurrence(in: service.clusters)
    }

    /// Selects the occurrence a route in from outside was waiting for.
    ///
    /// Silent when the clusters do not carry it yet: this runs on every
    /// re-query, and treating the first one as proof of absence would report a
    /// perfectly present event as deleted. The cache read in
    /// ``show(_:accountKey:)`` is what decides that question, once.
    private func openAwaitedOccurrence(in clusters: [EventCluster]) {
        guard let awaitingOccurrence,
            let cluster = CalendarSelection.reselect(awaitingOccurrence, in: clusters)
        else { return }

        self.awaitingOccurrence = nil
        open(cluster)
    }

    /// The same calendar, in a window of its own.
    ///
    /// The day travels as its **key** rather than as a model: a scene value is
    /// persisted and handed back after a relaunch, so a value holding a whole
    /// event would restore a copy of something that may since have been
    /// deleted. See ``CalendarWindowValue``.
    private func openInNewWindow() {
        openWindow(value: CalendarWindowValue(dayKey: (selectedDay ?? anchor).key))
    }
}

/// What a calendar window draws when there is nothing behind it.
///
/// Lives here rather than in the shell because `Localization.ui(_:)` is
/// internal to this module: a shell-side copy would have to be an English
/// literal, and a German reader restoring a window after a sign-out would get
/// the one screen in the app that is not translated.
///
/// A restored scene is exactly when this happens — the system reopens a window
/// from days ago, and the account it belonged to may since have been signed
/// out. An empty grid would claim there was nothing on that day.
public struct CalendarUnavailableView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text(.ui("This mailbox is no longer connected"))
            } icon: {
                Image(systemName: "calendar.badge.exclamationmark")
            }
        }
    }
}

/// The calendar, as its own window.
///
/// **Ids only, never a model**, for the same reason as `ThreadWindowValue`:
/// the system persists a scene value and hands it back after a relaunch, by
/// which time the account may have been signed out and the events deleted. A
/// day key is a fact about the grid rather than about anything in the cache, so
/// it cannot go stale — the events on it are resolved when the window opens.
public struct CalendarWindowValue: Codable, Hashable, Sendable {
    /// `yyyy-MM-dd`, the spelling ``CalendarDay/key`` writes. A string rather
    /// than a `Date` because a persisted instant reopens on the wrong day for
    /// anybody who has since travelled, and the window is meant to reopen where
    /// it was left.
    public var dayKey: String

    public init(dayKey: String) {
        self.dayKey = dayKey
    }
}

/// The card around the calendar, or nothing at all on a compact width.
private struct CalendarCard: ViewModifier {
    let isDrawn: Bool
    let palette: ThemePalette

    func body(content: Content) -> some View {
        if isDrawn {
            content
                .paneSurface(palette)
                .padding(PanelStyle.outerMargin)
                .background(palette.window.color.ignoresSafeArea())
        } else {
            content
        }
    }
}

/// ``CalendarView`` with a navigation container of its own, for a sheet, a tab
/// or a window scene.
///
/// Separate from the view itself so that exactly one of the two shapes creates
/// a stack. A `NavigationStack` nested inside another one swallows the push,
/// and the failure looks like a detail screen that simply does nothing when
/// tapped — which is a long way from the code that caused it.
public struct CalendarScreen: View {
    private let service: CalendarService
    private let day: CalendarDay?
    private let onDone: (() -> Void)?

    /// - Parameters:
    ///   - service: the calendar stack this screen drives.
    ///   - day: where to open. Nil is today.
    ///   - onDone: a way out, for a presentation that supplies none. A cover
    ///     has no back button and ``CalendarView``'s toolbar has none either,
    ///     so a cover without this is a room with no door. A window scene
    ///     passes nil — its door is the window's own close control, and a
    ///     second one inside it would be a Done button that dismissed nothing.
    public init(
        service: CalendarService,
        day: CalendarDay? = nil,
        onDone: (() -> Void)? = nil
    ) {
        self.service = service
        self.day = day
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            CalendarView(service: service, day: day)
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.ui("Done"), action: onDone)
                        }
                    }
                }
        }
    }
}

#endif
