#if os(iOS)

public import PLMailCore

import SwiftUI

/// Snoozing to an exact time.
///
/// The presets cover the cases people actually pick; this is for the ones they
/// don't — a flight, a deadline, a Tuesday. Reached from the bottom of the
/// snooze menu rather than replacing it, because making everyone spin a wheel
/// to say "tomorrow" would be a worse default for the sake of a rarer case.
struct SnoozeDatePicker: View {
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    /// Opens on tomorrow morning rather than now: a snooze is by definition in
    /// the future, and starting on the present moment means every use begins
    /// by scrolling away from an invalid answer.
    init(onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        _date = State(
            wrappedValue: TimePreset.tomorrow.date() ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    .ui("Wake up"),
                    selection: $date,
                    // Nothing earlier than a minute out. The sweep runs every
                    // minute, so a time inside that window would come straight
                    // back and the gesture would look like it did nothing.
                    in: Date().addingTimeInterval(60)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle(.ui("Snooze until"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Snooze")) {
                        onPick(date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#endif
