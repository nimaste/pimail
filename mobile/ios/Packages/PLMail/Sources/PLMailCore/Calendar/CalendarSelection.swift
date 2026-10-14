import Foundation
public import JMAPKit

/// Moving the selection with the keyboard, over the events a period actually
/// shows.
///
/// **Pure, because arrow keys are the one part of the iPad treatment nothing
/// else can check.** A grid's selection is invisible to a compiler and to
/// `swift test` alike, so the *rule* — which event ↑ lands on from the third
/// one, what ↓ does at the end, what happens when the visible list changed
/// under the selection — is written here and asserted, and the view only binds
/// keys to it.
public enum CalendarSelection {
    /// The cluster `steps` away from `current`, or nil to leave the selection
    /// alone.
    ///
    /// **Clamps rather than wraps.** ↓ at the last event of a week jumping back
    /// to the first is a reader who believes they have paged and has not; a
    /// selection that simply stays put says "that is the end" without moving
    /// anything.
    ///
    /// A `current` that is no longer in `clusters` — a refresh landed, or a
    /// calendar was hidden — selects the **first** event rather than nothing,
    /// because the alternative is an arrow key that appears to do nothing at
    /// the exact moment the screen changed under the reader.
    public static func step(
        from current: CalendarEventID?,
        in clusters: [EventCluster],
        by steps: Int
    ) -> EventCluster? {
        guard clusters.isEmpty == false else { return nil }

        guard let current,
            let index = clusters.firstIndex(where: { $0.representative.occurrenceID == current })
        else {
            return steps < 0 ? clusters.last : clusters.first
        }

        let target = min(max(index + steps, 0), clusters.count - 1)

        return clusters[target]
    }

    /// The cluster a restored or refreshed screen should still be showing.
    ///
    /// Matched on the **occurrence id**, which survives a re-query of the same
    /// window: rotation, a Stage Manager resize and a pull-to-refresh all
    /// rebuild the cluster array, and comparing whole clusters would drop the
    /// selection every time a calendar colour arrived. Nil when the event is
    /// genuinely gone, which is a selection that must clear rather than point
    /// at a deleted row.
    public static func reselect(
        _ current: CalendarEventID?, in clusters: [EventCluster]
    ) -> EventCluster? {
        guard let current else { return nil }

        return clusters.first { $0.representative.occurrenceID == current }
    }
}
