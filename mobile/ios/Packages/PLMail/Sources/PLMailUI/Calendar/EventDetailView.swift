#if os(iOS)

public import PLMailCore

import SwiftUI

/// One event, read-only.
///
/// **There are no RSVP controls and no editable participant list, and that is
/// not an omission.** `CalendarEvent/set` refuses `participants` by name,
/// because an RSVP is answered through the invite flow which sends an iTIP
/// reply — accepting an attendee list here would record answers nobody was
/// told about. Participants are readable, so an attendee list is the most that
/// could ever be shown; alerts and privacy are the same shape.
///
/// Recurrence is stated rather than offered. The cache stores *whether* a
/// series recurs and never the rule it recurs by, so a control built from that
/// would flatten an elaborate imported rule to "every week" because somebody
/// corrected a typo — or clear it, since null on that property means *stop
/// recurring*.
struct EventDetailView: View {
    let cluster: EventCluster
    /// The **series**, fetched by `seriesId` — never the tapped occurrence.
    let series: CalendarEventSnapshot?

    /// The calendar this event sits on, for its `myRights`. Nil where the
    /// calendar list has not been refreshed yet, which reads as **no rights**:
    /// offering a write on nothing is the refusal this defaults away from.
    var calendar: CalendarSnapshot?

    /// Nil when the caller has no editor to present — a widget or a preview.
    /// The controls are then absent rather than disabled, because there is no
    /// reason to explain.
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Export this occurrence as an `.ics`. Never nil for a right reason: it
    /// reads the cache and writes nothing to the server, so no `myRights` can
    /// refuse it — it is nil only where the caller has no share sheet to
    /// present, which is a preview or a widget.
    var onShare: (() -> Void)?

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var row: EventRow { cluster.representative }

    var body: some View {
        List {
            Section {
                Text(row.title.isEmpty ? String(localized: .ui("Untitled")) : row.title)
                    .font(.title3.weight(.semibold))
                    .strikethrough(row.isCancelled)

                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(
                            CalendarHeading.day(
                                row.start.calendarDay,
                                template: "EEEEdMMMy",
                                locale: locale,
                                timeZone: timeZone
                            ))
                        Text(
                            EventSpeech.timeSpan(
                                cluster, locale: locale, allDayWord: CalendarWords.allDay)
                        )
                        .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(.ui("When"))
                }

                // A floating event says so. Its time is the same clock
                // everywhere, and a reader who assumes their own zone will be
                // an hour out the first time they travel.
                if row.isAllDay == false, row.timeZoneName == nil {
                    Label(.ui("Floating time"), systemImage: "globe")
                        .foregroundStyle(.secondary)
                } else if let zone = row.timeZoneName {
                    LabeledContent {
                        Text(zone)
                    } label: {
                        Text(.ui("Time zone"))
                    }
                }
            }

            Section {
                if let name = row.calendarName {
                    LabeledContent {
                        Text(name)
                    } label: {
                        Text(.ui("Calendar"))
                    }
                }

                if let location = series?.locationName, location.isEmpty == false {
                    LabeledContent {
                        Text(location)
                    } label: {
                        Text(.ui("Location"))
                    }
                }

                if series?.isRecurring == true {
                    Label(.ui("Repeats"), systemImage: "repeat")
                        .foregroundStyle(.secondary)
                }

                if row.isCancelled {
                    Label(.ui("Cancelled"), systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if let text = series?.eventDescription, text.isEmpty == false {
                Section {
                    Text(text)
                } header: {
                    Text(.ui("Notes"))
                }
            }

            if cluster.isMerged {
                Section {
                    ForEach(cluster.members) { member in
                        Text(member.calendarName ?? String(localized: .ui("Unknown calendar")))
                    }
                } header: {
                    Text(.ui("In \(cluster.members.count) calendars"))
                } footer: {
                    // Said out loud rather than implied by a two-slice dot: both
                    // rows are correct, and the server keeps both deliberately.
                    Text(.ui("This meeting reached plMail more than once."))
                }
            }

            writeSection
        }
        .navigationTitle(Text(.ui("Event")))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Edit and Delete, **disabled rather than hidden** when `myRights` refuse
    /// them, with the reason folded into the accessibility label.
    ///
    /// Hiding a control teaches nothing: somebody who cannot change an event on
    /// a calendar shared read-only needs to be told that is why, not left
    /// wondering whether the app forgot to draw a button. The rights come from
    /// `myRights` and from nothing else — and a `forbidden` is still handled at
    /// the write, because rights can change between this screen opening and the
    /// save.
    @ViewBuilder
    private var writeSection: some View {
        if onEdit != nil || onDelete != nil || onShare != nil {
            Section {
                if let onShare {
                    // Above Edit and Delete because it is the one action here
                    // that cannot fail and cannot be refused, and because it is
                    // the whole of the "put this in another calendar" story —
                    // see `ICSExport` for why that is not EventKit.
                    Button(action: onShare) {
                        Label(.ui("Share"), systemImage: "square.and.arrow.up")
                    }
                }

                if let onEdit {
                    Button(action: onEdit) {
                        Label(.ui("Edit"), systemImage: "pencil")
                    }
                    .disabled(mayEdit == false)
                    .accessibilityLabel(mayEdit ? Text(.ui("Edit")) : Self.editRefused)
                }

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Label(.ui("Delete event"), systemImage: "trash")
                    }
                    .disabled(mayDelete == false)
                    .accessibilityLabel(
                        mayDelete ? Text(.ui("Delete event")) : Self.deleteRefused)
                }
            } footer: {
                // The consequence, said before the press rather than only in
                // the confirmation: a calendar has no bin.
                if mayDelete {
                    Text(.ui("Deleting an event removes it for everyone it is shared with."))
                }
            }
        }
    }

    private var mayEdit: Bool { calendar?.mayUpdateAll ?? false }
    private var mayDelete: Bool { calendar?.mayRemoveItems ?? false }

    /// The refusal, folded into the label rather than left to a separate hint.
    ///
    /// VoiceOver reads a hint only when the user has hints switched on, and
    /// they are off by default — so a reason kept there is a reason most
    /// readers of a disabled button never hear.
    private static var editRefused: Text {
        let reason = String(localized: .ui("You can't change events in this calendar"))

        return Text(.ui("Edit, \(reason)"))
    }

    private static var deleteRefused: Text {
        let reason = String(localized: .ui("You can't delete events in this calendar"))

        return Text(.ui("Delete event, \(reason)"))
    }
}

#endif
