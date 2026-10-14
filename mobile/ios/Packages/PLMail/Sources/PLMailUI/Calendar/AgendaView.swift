#if os(iOS)

public import PLMailCore

import SwiftUI

/// The rolling list — the default, and the right default on a phone.
///
/// A `List` with one `Section` per day and pinned headers, rather than a
/// `ScrollView` of hand-drawn rows: the section header behaviour, the swipe
/// gutters and the accessibility grouping are all things `List` already does
/// correctly and a hand-rolled stack would do approximately.
///
/// **Empty days are omitted.** A 30-day window with four events in it is four
/// rows and four headers, not thirty headers with "nothing" under twenty-six of
/// them — the grid is where an empty day is worth drawing, because there the
/// space is the information.
struct AgendaView: View {
    let window: CalendarWindow
    let clusters: [EventCluster]
    let onOpen: (EventCluster) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    /// Days that actually have something on them, each with its own placed
    /// contents. All-day first, then timed in start order — which is what the
    /// layout already returns and what a reader expects at the top of a day.
    private var days: [(day: CalendarDay, clusters: [EventCluster])] {
        window.days.compactMap { day in
            let grid = DayGridLayout.place(clusters, on: day)
            let contents = grid.allDay + grid.timed.map(\.cluster)

            return contents.isEmpty ? nil : (day, contents)
        }
    }

    var body: some View {
        List {
            ForEach(days, id: \.day) { entry in
                Section {
                    ForEach(entry.clusters) { cluster in
                        Button {
                            onOpen(cluster)
                        } label: {
                            EventChipView(cluster: cluster, density: .row)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        // The card underneath is the surface. A `List` paints
                        // its own rows over it, which is how a chip on cream
                        // ended up on a white band the design never drew.
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(
                        CalendarHeading.day(
                            entry.day,
                            template: "EEEEdMMM",
                            locale: locale,
                            timeZone: timeZone
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

#endif
