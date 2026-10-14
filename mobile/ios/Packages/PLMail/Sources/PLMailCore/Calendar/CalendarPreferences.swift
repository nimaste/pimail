import Foundation

/// The whole persisted preference surface of the calendar: **one key**.
///
/// A wrapper over `UserDefaults` rather than a row in the store, because the
/// store's rule is that everything in it is reconstructible from the server and
/// a view preference is not — it is small, it is the user's, and it belongs
/// where the rest of this app's preferences live.
///
/// The value is a `CalendarViewMode` **wire** string shared with the web UI, so
/// a person who set their view in a browser finds it here. An unknown value
/// degrades to the default rather than crashing: a preference written by a
/// newer release must never leave the screen unable to open.
public struct CalendarPreferences {
    /// The same key the Android client uses, so the two agree about what they
    /// are storing even though neither reads the other's.
    static let viewKey = "calendar_view"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var mode: CalendarViewMode {
        CalendarViewMode.fromWire(defaults.string(forKey: Self.viewKey))
    }

    /// `isCompactMonth` says whether month is being drawn as a grid with the
    /// selected day expanded below it, which is what the web calls
    /// `month-agenda`. Writing the value the other surface uses is what stops
    /// the two stranding each other.
    public func setMode(_ mode: CalendarViewMode, isCompactMonth: Bool) {
        defaults.set(mode.persistedWire(isCompactMonth: isCompactMonth), forKey: Self.viewKey)
    }
}
