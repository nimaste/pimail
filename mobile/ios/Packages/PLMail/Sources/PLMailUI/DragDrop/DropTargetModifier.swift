#if os(iOS)

import SwiftUI

extension View {
    /// Makes this row accept dragged conversations, and say so while one is
    /// over it.
    ///
    /// The highlight is driven by a binding owned by the *list* rather than by
    /// per-row state. SwiftUI does not promise to tell a row the drag left
    /// before it tells the next row the drag arrived, so two rows can believe
    /// they are targeted at once — and two lit drop targets read as two
    /// destinations for one finger.
    ///
    /// `accept` returns whether anything was actually done, which is what the
    /// system uses to decide between the drop animation and the snap-back. A
    /// row that swallows a drop it could not act on leaves the impression the
    /// mail moved.
    func dropTarget<Target: Hashable>(
        _ target: Target,
        current: Binding<Target?>,
        accept: @escaping (ThreadTransfer, Target) -> Bool
    ) -> some View {
        dropDestination(for: ThreadTransfer.self) { payloads, _ in
            current.wrappedValue = nil

            // Reduced rather than short-circuited: a drag can carry more than
            // one payload, and `||` would stop acting on the rest as soon as
            // one of them succeeded.
            return payloads.reduce(false) { done, payload in accept(payload, target) || done }
        } isTargeted: { isOver in
            if isOver {
                current.wrappedValue = target
            } else if current.wrappedValue == target {
                // Only clears its own claim. Clearing unconditionally would
                // let a row leaving erase the highlight the row being entered
                // has already set.
                current.wrappedValue = nil
            }
        }
        .background {
            if current.wrappedValue == target {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // The same accent-at-low-opacity the list rows already use
                    // for open and selected, so "this row is the destination"
                    // is drawn in the same language as "this row is the one you
                    // are on" rather than in a colour invented here.
                    .fill(ThemeAccent().opacity(0.20))
            }
        }
    }
}

#endif
