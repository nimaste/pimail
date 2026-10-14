#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Create or change one event.
///
/// A `Form`, not a transcription of Android's screen. The rules are Android's
/// and they are load-bearing; the controls are the platform's.
///
/// **Presented as a sheet, and not a full-screen one on iPad.** On iPhone a
/// sheet is already the whole screen, which is right for a form somebody is
/// filling in. On a 13-inch iPad `.presentationSizing(.form)` keeps it a
/// centred panel over the calendar the user was reading, so the dates they are
/// working around stay visible — a full-screen cover there would hide the one
/// piece of context the editor is about.
///
/// **There is no timezone control**, no participant list, no RSVP, no alerts
/// and no privacy switch. Four of those are refused by name on the wire and are
/// unrepresentable on the write types; the zone is omitted so the calendar's
/// own is used, because sending the device's would record a decision the user
/// never made.
struct EventEditorView: View {
    private let service: CalendarService
    /// The **series** being edited, or nil on a create. Never an occurrence:
    /// an update sends whole properties, so a form seeded from one Tuesday of a
    /// weekly standup would drag the whole series onto that week.
    private let editing: CalendarEventSnapshot?
    private let onFinished: (CalendarWriteOutcome) -> Void

    @State private var form: EventFormState
    @State private var isWorking = false
    @State private var isConfirmingDelete = false
    @State private var failure: WriteFailure?

    @Environment(\.dismiss) private var dismiss
    /// The zone both directions of every picker binding use. Same zone in and
    /// out is what keeps a date from moving a day for readers east or west of
    /// whoever wrote the code.
    @Environment(\.timeZone) private var timeZone
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// A refusal, in a shape `.alert` can present. Identifiable because two
    /// consecutive failures with the same words must still raise the alert
    /// twice.
    private struct WriteFailure: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        /// The server's own sentence, shown as detail under a translated lead.
        /// Untranslated English written for a developer — but it is the only
        /// part of the answer that says what to change, and hiding it leaves
        /// the user with "something went wrong".
        let detail: String?
    }

    /// A new event at `start`, on the first calendar that accepts one.
    /// - Parameters:
    ///   - service: the calendar stack this editor writes through.
    ///   - start: the wall clock the new event is proposed at.
    ///   - title: what an App Intent asked for, or nil. **Prefilled, never
    ///     saved.** `MailIntents.swift`'s rule is that an intent opens the app
    ///     rather than acting in it, and it binds harder here than it does for
    ///     mail: a calendar has no outbox to intercept a mistake in and no bin
    ///     to recover one from.
    ///   - onFinished: how the screen reports the write's outcome.
    init(
        service: CalendarService,
        creatingAt start: LocalDateTime,
        title: String? = nil,
        onFinished: @escaping (CalendarWriteOutcome) -> Void
    ) {
        self.service = service
        editing = nil
        self.onFinished = onFinished

        var state = EventFormState(
            creatingAt: start,
            calendarID: service.writableCalendars.first { $0.isDefault }?.calendarID
                ?? service.writableCalendars.first?.calendarID
        )
        if let title { state.title = title }

        _form = State(wrappedValue: state)
    }

    /// An existing series.
    init(
        service: CalendarService,
        editing series: CalendarEventSnapshot,
        onFinished: @escaping (CalendarWriteOutcome) -> Void
    ) {
        self.service = service
        editing = series
        self.onFinished = onFinished
        _form = State(wrappedValue: EventFormState(editing: series))
    }

    /// **The deliberate iPad decision.** `.form` on a regular width keeps the
    /// editor a centred panel over the calendar the reader was looking at, so
    /// the dates they are working around stay visible; `.page` on compact is
    /// the full-height sheet an iPhone form should be. Written as two branches
    /// rather than a ternary because the two sizings are different types.
    @ViewBuilder
    var body: some View {
        if sizeClass == .compact {
            editor.presentationSizing(.page)
        } else {
            editor.presentationSizing(.form)
        }
    }

    private var editor: some View {
        NavigationStack {
            Form {
                whatSection
                whenSection
                whereSection
                repeatSection
                notesSection

                if editing != nil { deleteSection }
            }
            .navigationTitle(Text(editing == nil ? .ui("New event") : .ui("Edit event")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .disabled(isWorking)
            .alert(
                Text(failure?.title ?? .ui("This wasn't saved")),
                isPresented: isShowingFailure,
                presenting: failure
            ) { _ in
                Button(role: .cancel) {
                } label: {
                    Text(.ui("OK"))
                }
            } message: { failure in
                if let detail = failure.detail { Text(detail) }
            }
        }
    }

    // MARK: - Sections

    private var whatSection: some View {
        Section {
            TextField(text: $form.title) {
                Text(.ui("Title"))
            }
            .textInputAutocapitalization(.sentences)
            // Said rather than enforced: an empty title becomes the localised
            // word, matching what the web stores, so an event created on a
            // phone and one created in a browser are the same event.
            .accessibilityHint(Text(.ui("Left blank, this is saved as Untitled")))
        }
    }

    private var whenSection: some View {
        Section {
            Toggle(isOn: $form.isAllDay) {
                Text(.ui("All-day"))
            }

            DatePicker(
                selection: startDate,
                // **Not drawn at all** for an all-day event, rather than drawn
                // and disabled: a disabled control still invites a press, still
                // reads out to VoiceOver, and still suggests there is a time to
                // set on something that has none.
                displayedComponents: form.isAllDay ? [.date] : [.date, .hourAndMinute]
            ) {
                Text(.ui("Starts"))
            }

            DatePicker(
                selection: endDate,
                displayedComponents: form.isAllDay ? [.date] : [.date, .hourAndMinute]
            ) {
                Text(.ui("Ends"))
            }

            if let problem = form.problem, problem != .noCalendar {
                Label {
                    Text(message(for: problem))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
            }
        }
        .environment(\.timeZone, timeZone)
    }

    private var whereSection: some View {
        Section {
            TextField(text: $form.location) {
                Text(.ui("Location"))
            }

            // **One calendar per event**, not a set of ticks: `calendarId` is a
            // single value on the wire, so a multi-select would offer something
            // the server cannot express. Only calendars whose `myRights` accept
            // new items are listed.
            Picker(selection: $form.calendarID) {
                ForEach(pickableCalendars) { calendar in
                    Text(calendar.name).tag(Optional(calendar.calendarID))
                }
            } label: {
                Text(.ui("Calendar"))
            }

            if pickableCalendars.isEmpty {
                Text(.ui("You can't add events to any calendar here"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// **Editable on create and read-only on edit**, and the read-only line
    /// says what will happen rather than showing a greyed dropdown.
    ///
    /// The cache stores *whether* a series recurs and never the rule it recurs
    /// by, so a value picked here and sent as an update would flatten an
    /// elaborate imported rule to "every week" because somebody corrected a
    /// typo — or clear it entirely, since null on that property means *stop
    /// recurring*. There is no full recurrence editor on either surface.
    @ViewBuilder
    private var repeatSection: some View {
        Section {
            if form.mayEditRecurrence {
                Picker(selection: $form.repeatRule) {
                    ForEach(EventRepeat.allCases) { choice in
                        Text(label(for: choice)).tag(choice)
                    }
                } label: {
                    Text(.ui("Repeat"))
                }
            } else {
                LabeledContent {
                    Text(form.isRecurringSeries ? .ui("Repeats") : .ui("Never"))
                        .foregroundStyle(.secondary)
                } label: {
                    Text(.ui("Repeat"))
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            if form.mayEditRecurrence == false {
                Text(.ui("How often this repeats is left exactly as it is when you save."))
            }
        }
    }

    private var notesSection: some View {
        Section {
            TextField(text: $form.notes, axis: .vertical) {
                Text(.ui("Notes"))
            }
            .lineLimit(3...8)
        }
    }

    /// **Deletes the whole series and cannot be undone**, with a distinct
    /// sentence when the event repeats. There is no calendar bin to recover
    /// from, unlike mail where a destroy means Trash — so this is a
    /// confirmation rather than an undo toast, and it is a plain button rather
    /// than a swipe: a gesture must never be the only route to an action.
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Text(.ui("Delete event"))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .confirmationDialog(
                Text(.ui("Delete event")),
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    Task { await deleteEvent() }
                } label: {
                    Text(.ui("Delete"))
                }

                Button(role: .cancel) {
                } label: {
                    Text(.ui("Cancel"))
                }
            } message: {
                if form.isRecurringSeries {
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
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text(.ui("Cancel"))
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await save() }
            } label: {
                if isWorking {
                    ProgressView()
                } else {
                    Text(.ui("Save"))
                }
            }
            .disabled(form.isValid == false || isWorking)
            // **Disabled, with the reason in the label.** A control that says
            // nothing about why it will not respond is a control somebody
            // presses repeatedly.
            .accessibilityLabel(
                form.problem.map { Text(.ui("Save, \(String(localized: message(for: $0)))")) }
                    ?? Text(.ui("Save")))
        }
    }

    /// Derived rather than a second `@State`, so a failure and its alert cannot
    /// get out of step — one of them cleared and the other not is an alert that
    /// re-raises itself on the next redraw.
    private var isShowingFailure: Binding<Bool> {
        Binding {
            failure != nil
        } set: { shown in
            if shown == false { failure = nil }
        }
    }

    // MARK: - Bindings

    /// Both directions use the same zone, so the day the picker shows and the
    /// day the form holds cannot disagree.
    private var startDate: Binding<Date> {
        Binding {
            WallClockDate.date(day: form.startDate, time: form.startTime, in: timeZone)
        } set: { moved in
            // The **date** setter shifts the end by the same number of days —
            // moving a meeting from Tuesday to Thursday moves the whole
            // meeting. The time is set separately and moves only itself.
            form.startDate = WallClockDate.day(of: moved, in: timeZone)
            form.startTime = WallClockDate.time(of: moved, in: timeZone)
        }
    }

    /// **Moves only the end.** The end picker is how somebody changes how long
    /// something is, so shifting anything else here would undo the edit they
    /// just made.
    private var endDate: Binding<Date> {
        Binding {
            WallClockDate.date(day: form.endDate, time: form.endTime, in: timeZone)
        } set: { moved in
            form.endDate = WallClockDate.day(of: moved, in: timeZone)
            form.endTime = WallClockDate.time(of: moved, in: timeZone)
        }
    }

    /// The calendars offered, with the event's current one kept even when it no
    /// longer accepts items — a picker that silently dropped it would show the
    /// wrong calendar for an event nobody had moved.
    private var pickableCalendars: [CalendarSnapshot] {
        var list = service.writableCalendars

        if let current = form.calendarID,
            list.contains(where: { $0.calendarID == current }) == false,
            let calendar = service.calendar(current)
        {
            list.insert(calendar, at: 0)
        }

        return list
    }

    // MARK: - Writing

    private func save() async {
        guard let draft = form.draft(untitled: String(localized: .ui("Untitled"))) else { return }

        isWorking = true

        let outcome: CalendarWriteOutcome =
            if let id = form.editing {
                await service.update(id, to: draft)
            } else {
                await service.create(draft)
            }

        isWorking = false
        finish(outcome, failureTitle: .ui("This wasn't saved"))
    }

    private func deleteEvent() async {
        guard let id = form.editing else { return }

        isWorking = true
        let outcome = await service.delete(id)
        isWorking = false
        finish(outcome, failureTitle: .ui("This wasn't deleted"))
    }

    /// Reports, and never offers to try again. A refusal replayed is a loop
    /// that terminates never, and the optimistic change has already been rolled
    /// back — so there is nothing to undo either.
    private func finish(_ outcome: CalendarWriteOutcome, failureTitle: LocalizedStringResource) {
        onFinished(outcome)

        switch outcome {
        case .saved, .deleted:
            dismiss()
        case .refused(let reason, let isForbidden):
            failure = WriteFailure(
                title: isForbidden ? .ui("This calendar doesn't accept changes") : failureTitle,
                detail: reason
            )
        case .unreachable(let host):
            failure = WriteFailure(title: .ui("Can't reach \(host)"), detail: nil)
        case .noCalendar:
            failure = WriteFailure(title: .ui("This server does not have a calendar"), detail: nil)
        }
    }

    // MARK: - Words

    private func message(for problem: EventFormProblem) -> LocalizedStringResource {
        switch problem {
        case .endsBeforeStart: .ui("The end date can't be before the start date.")
        case .doesNotEndAfterStart: .ui("An event must end after it starts.")
        case .noCalendar: .ui("Choose a calendar you can add events to.")
        }
    }

    private func label(for choice: EventRepeat) -> LocalizedStringResource {
        switch choice {
        case .never: .ui("Never")
        case .daily: .ui("Every day")
        case .weekly: .ui("Every week")
        case .monthly: .ui("Every month")
        case .yearly: .ui("Every year")
        }
    }
}

#endif
