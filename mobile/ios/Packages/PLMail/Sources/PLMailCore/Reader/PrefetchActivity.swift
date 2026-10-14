#if os(iOS)

import Foundation
import Observation

/// What the background prefetch is doing, for the one line of interface that
/// says so.
///
/// **Prefetch is deliberately invisible to the app's behaviour** — nothing on
/// screen waits for it, a failure is swallowed, and it declines to run more
/// often than its own interval. That is the right design and it has one cost:
/// work that quietly occupies somebody's Raspberry Pi with no way to see it.
/// This is the way to see it.
///
/// Shared rather than injected because the prefetcher is built in the
/// composition root and the line that reports it lives several columns away, in
/// a view this package cannot hand an initialiser argument to. The state is one
/// counter pair with no identity of its own, so a second instance would be
/// meaningless rather than merely wasteful.
@MainActor
@Observable
public final class PrefetchActivity {
    public static let shared = PrefetchActivity()

    /// How many message bodies this run has fetched.
    public private(set) var fetched = 0

    /// How many it still means to fetch. Zero when nothing is running.
    public private(set) var remaining = 0

    public var isRunning: Bool { remaining > 0 }

    /// What fraction is done, or nil before the first chunk lands — a bar at
    /// zero for a run that has not reported yet reads as stalled.
    public var completion: Double? {
        let total = fetched + remaining

        guard total > 0, fetched > 0 else { return nil }

        return Double(fetched) / Double(total)
    }

    private init() {}

    public func report(fetched: Int, remaining: Int) {
        self.fetched = fetched
        self.remaining = remaining
    }

    /// Called whether the run finished, stopped early or failed. Leaving the
    /// counters up after a failure would show progress that has stopped moving.
    public func finish() {
        fetched = 0
        remaining = 0
    }
}

#endif
