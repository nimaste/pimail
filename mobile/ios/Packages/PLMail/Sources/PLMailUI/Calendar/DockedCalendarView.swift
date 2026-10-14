#if os(iOS)

public import PLMailCore

import JMAPKit

import SwiftUI

/// The calendar as a **column beside the mail**, not as a screen.
///
/// The design gives the docked calendar a shape the full screen does not have:
/// a grabber, one day rather than a range, and a band above the grid that says
/// what is about to happen. That is a different job from the calendar screen —
/// this column exists to be glanced at while a message is being read, so it
/// answers *what is next* before it answers *what is in March*, and everything
/// that needs a range lives one tap away behind the expand mark.
///
/// **The grid underneath is the same `TimeGridView` the screen draws**, at
/// twice the hour height. One day in a narrow column can afford the room, and
/// a second grid would be a second now-line and a second placement algorithm
/// to keep honest.
struct DockedCalendarView: View {
    let service: CalendarService
    /// Opens the full calendar. The column deliberately cannot change range,
    /// mode or which calendars are shown — all three belong to the screen.
    let expand: () -> Void
    /// Puts the column away and gives the width back to the mail.
    let dismiss: () -> Void

    @State private var day = CalendarDay(.now, in: .current)
    @State private var creating: NewEventAt?
    @State private var opened: EventCluster?
    @State private var openedSeries: CalendarEventSnapshot?
    @State private var isGrabbed = false

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    /// How far ahead the band looks. A week, because that is the range over
    /// which "soon" is a useful word about a flight or a delivery — a fortnight
    /// is a diary entry, and tomorrow alone would mean the band appears on the
    /// evening before and never in time to be worth anything.
    private static let lookaheadDays = 8

    /// The day drawn, the day before it, and the week after.
    ///
    /// Wider than the column draws, deliberately. The day before is fetched
    /// because an event that starts at 23:30 yesterday still occupies this
    /// morning's column and a one-day window does not return it; the week
    /// after is what ``soon`` reads, and a band that could only see today
    /// would announce a flight while its passenger was already at the gate.
    private var window: CalendarWindow? {
        CalendarWindow(from: day.adding(days: -1), to: day.adding(days: Self.lookaheadDays))
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header

            if let soon {
                HappeningSoonBanner(row: soon.row, kind: soon.kind)
            }

            Divider()

            if let ahead {
                if service.clusters.isEmpty {
                    // A grid with nothing in it says "nothing" by being empty;
                    // a list with nothing in it says nothing at all.
                    ContentUnavailableView(
                        .ui("Nothing in this period"), systemImage: "calendar"
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    AgendaView(window: ahead, clusters: service.clusters, onOpen: { open($0) })
                }
            }
        }
        .task(id: day) {
            guard let window else { return }

            await service.show(window)
        }
        .sheet(item: $creating) { request in
            NavigationStack {
                EventEditorView(service: service, creatingAt: request.start) { _ in
                    creating = nil
                }
            }
        }
        .sheet(item: $opened) { cluster in
            NavigationStack {
                EventDetailView(
                    cluster: cluster,
                    series: openedSeries,
                    calendar: service.calendar(cluster.representative.calendarID))
            }
        }
    }

    /// What the column lists: today and the week in front of it.
    ///
    /// **A list, not the hour grid the calendar screen draws.** A day grid
    /// beside the mail spends its whole height on the hours you have nothing
    /// in, which on a real diary is most of them — the column was twenty-four
    /// rows of ruled paper and one event. What a column beside a half-read
    /// message is for is *what is coming*, and that is a list: empty days are
    /// skipped, so ten quiet days cost ten pixels rather than ten screens.
    ///
    /// The hour grid is one tap away behind the expand mark, where the height
    /// to draw it exists.
    private var ahead: CalendarWindow? {
        CalendarWindow(from: day, to: day.adding(days: Self.lookaheadDays))
    }

    // MARK: - Chrome

    /// The grabber, and the gesture it promises.
    ///
    /// **Drawn only because it does something.** A grabber that cannot be
    /// grabbed is a worse control than no control: it advertises a gesture,
    /// the gesture fails, and the reader concludes the pane is broken rather
    /// than that it was decoration. Pulled down, it puts the column away —
    /// which is what a grabber means everywhere else on the platform.
    ///
    /// The hit area is the row, not the four-point capsule. The capsule is the
    /// mark; a target the size of the mark would be a target nobody could hit.
    private var grabber: some View {
        Capsule()
            .fill(isGrabbed ? PanelStyle.paneBorder : PanelStyle.hairline)
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in isGrabbed = true }
                    .onEnded { drag in
                        isGrabbed = false

                        // Downwards, and far enough to be meant. A pane that
                        // closed on a four-point twitch would close every time
                        // somebody rested a thumb on it.
                        if drag.translation.height > 44 { dismiss() }
                    }
            )
            .padding(.top, 3)
            .accessibilityElement()
            .accessibilityLabel(Text(.ui("Close the calendar")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(
                verbatim: CalendarHeading.day(
                    day, template: "EEEEdMMMM", locale: locale, timeZone: timeZone)
            )
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button(action: expand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(.ui("Open the full calendar")))

            Button {
                creating = NewEventAt(start: LocalDateTime.midnight(of: day))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(service.writableCalendars.isEmpty)
            .accessibilityLabel(Text(.ui("New event")))
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.bottom, 6)
    }

    // MARK: - What is about to happen

    /// The next event the app made for you out of a message.
    ///
    /// Extracted events only — a booking, a flight, a delivery — because the
    /// band's claim is *you did not put this here, and it is nearly upon you*.
    /// A meeting somebody typed into the calendar themselves needs no such
    /// reminder, and a band that surfaced those too would be on screen every
    /// day and read as decoration.
    private var soon: (row: EventRow, kind: String)? {
        let horizon = Date.now.addingTimeInterval(Double(Self.lookaheadDays - 1) * 24 * 60 * 60)

        for cluster in service.clusters.sorted(by: {
            $0.representative.sortInstant < $1.representative.sortInstant
        }) {
            let row = cluster.representative

            guard row.sortInstant >= .now, row.sortInstant <= horizon else { continue }
            guard let kind = service.seriesByID[row.seriesID]?.kind, kind.isEmpty == false else {
                continue
            }

            return (row, kind)
        }

        return nil
    }

    private func open(_ cluster: EventCluster) {
        opened = cluster

        Task {
            openedSeries = await service.series(cluster.representative.seriesID)
        }
    }
}

/// The band above the grid: one extracted event, its kind, and when.
struct HappeningSoonBanner: View {
    let row: EventRow
    let kind: String

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.symbol(for: kind))
                .font(.system(size: 12))
                .foregroundStyle(palette.info.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(.ui("Happening soon"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(palette.info.color)

                Text(verbatim: line)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The information tint, not the accent. The accent means *the thing
        // you chose* everywhere else in this app — on a selected mailbox, on a
        // selected day — and spending it on a band that appears without being
        // asked for is how the accent stops meaning anything.
        .background(palette.info.color.opacity(0.09))
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        let when = CalendarHeading.day(
            CalendarDay(row.start), template: "EEEdMMM", locale: locale, timeZone: timeZone)

        return row.isAllDay
            ? row.title + " · " + when
            : row.title + " · " + when + " " + EventSpeech.time(row.start, locale: locale)
    }

    /// The mark for an extraction kind. The server's vocabulary, mapped once —
    /// an unknown kind gets the envelope, because whatever it is, a message is
    /// where it came from.
    static func symbol(for kind: String) -> String {
        switch kind {
        case "flight": "airplane.departure"
        case "train": "tram.fill"
        case "delivery": "shippingbox"
        case "lodging": "bed.double"
        case "dining": "fork.knife"
        case "rental": "car"
        case "ticket": "ticket"
        case "order": "bag"
        case "call": "phone"
        case "meeting": "person.2"
        default: "envelope"
        }
    }
}

/// A start time, wrapped so it can drive a sheet.
///
/// A wrapper rather than a conformance on `LocalDateTime`: that type belongs to
/// `JMAPKit`, and a retroactive `Identifiable` on it would be a conformance the
/// wire layer neither declares nor tests.
struct NewEventAt: Identifiable {
    let start: LocalDateTime

    var id: String { start.description }
}

#endif
