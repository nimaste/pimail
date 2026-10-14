#if os(iOS)

public import PLMailCore

import SwiftUI

/// The send-later choices, as menu items.
///
/// The same shape as the snooze menu, and the same times underneath it — see
/// ``TimePreset`` — because "tomorrow morning" should not mean 08:00 in one
/// corner of the app and 09:00 in another.
struct SendLaterMenu: View {
    let onPick: (Date) -> Void
    /// Menus cannot present sheets, so the date picker belongs to whoever put
    /// this menu on screen.
    let onPickExact: () -> Void

    var body: some View {
        ForEach(TimePreset.available(among: TimePreset.sendLaterChoices), id: \.preset.id) {
            entry in
            Button {
                onPick(entry.date)
            } label: {
                Label {
                    // The time as well as the name. It matters more here than
                    // in a snooze: this is when somebody else's phone lights
                    // up, and "tomorrow" alone does not say whether that is
                    // before or after they get to work.
                    Text(.ui("\(entry.preset.title) · \(SnoozeMenu.shortTime(entry.date))"))
                } icon: {
                    Image(systemName: entry.preset.symbolName)
                }
            }
        }

        Divider()

        Button(action: onPickExact) {
            Label(.ui("Pick a date and time…"), systemImage: "calendar.badge.clock")
        }
    }
}

/// Sending at an exact time.
///
/// Separate from the snooze picker rather than shared with it: the two agree
/// on the wheel and on nothing else. This one has to say what it cannot
/// promise, and that sentence is the reason the sheet exists at all rather
/// than the picker being inline.
struct SendLaterSheet: View {
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    /// Opens on tomorrow morning: the commonest reason to hold a message is
    /// that it is late at night and it should not read that way.
    init(onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        _date = State(
            wrappedValue: TimePreset.tomorrow.date() ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        .ui("Send at"),
                        selection: $date,
                        // A minute out at the very least, so "later" is not a
                        // more elaborate way of pressing Send.
                        in: Date().addingTimeInterval(60)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                } footer: {
                    Text(.ui(Self.caveat))
                }
            }
            .navigationTitle(.ui("Send later"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Schedule")) {
                        onPick(date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Said plainly, and no longer said unconditionally.
    ///
    /// **This used to be the only sentence available, and it was an apology for
    /// a limitation that has been removed.** A scheduled message is now offered
    /// to the server first, with RFC 4865 FUTURERELEASE — `HOLDUNTIL` on the
    /// submission envelope — and a server that takes it releases the mail at
    /// the chosen minute with the phone flat, in a drawer, or reinstalled.
    ///
    /// The old sentence is still true of the fallback, which is why it is still
    /// here: a message composed offline, or scheduled past whatever ceiling the
    /// server advertises as `maxDelayedSend`, is held on this device and really
    /// does go out "at the first check after this time". Both sentences are
    /// true of exactly one path, so the Outbox says the right one per row —
    /// removing this text entirely would be the same mistake in the other
    /// direction.
    static let deviceHeldCaveat = String.LocalizationValue(
        "Sent at the first check after this time. Your phone has to be awake for that, so it may be a little later."
    )

    /// What a scheduled message can be promised **before** it is known which
    /// mechanism will hold it.
    ///
    /// Which one is not decided in the composer: the message is filed with a
    /// time, and the outbox offers that time to the server on the next drain.
    /// Promising the server path here and falling back would be a promise
    /// broken after the sheet had closed.
    static let caveat = String.LocalizationValue(
        "Your server holds this and sends it on time. If it won't — too far ahead, or you're offline — this phone sends it at the first check after."
    )
}

#endif
