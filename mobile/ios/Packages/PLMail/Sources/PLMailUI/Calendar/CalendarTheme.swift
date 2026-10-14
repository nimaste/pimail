#if os(iOS)

import PLMailCore
import SwiftUI

/// How a calendar's own colour is painted, and the one place in the app a
/// colour is not a token.
///
/// A calendar colour is a literal `#rrggbb` the user picked in a browser
/// **against a white background**, so painting it raw on this app's cream
/// surface or on near-black is how a chip becomes unreadable in exactly one
/// appearance and nobody notices. Every use goes through here: a low-alpha fill
/// derived from the colour, a hairline in the colour at full strength, and a
/// label colour computed for contrast the way `ActionTint` already is.
///
/// **Colour is never the only carrier of meaning.** A chip says its calendar's
/// name in its accessibility label, a merged cluster says how many rows it
/// collapsed, and a cancelled event is struck through as well as dimmed — so a
/// calendar with no colour, or a reader who cannot see one, loses nothing but
/// the shortcut.
enum CalendarTheme {
    /// The accent for a calendar, or nil when the server sent nothing usable.
    ///
    /// Nil rather than an invented grey: a calendar drawn in a colour the user
    /// did not pick, beside one drawn in a colour they did, is worse than one
    /// drawn with none.
    static func accent(_ hex: String?) -> Color? {
        guard let hex, let colour = CalendarColour(hex: hex) else { return nil }

        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }

    /// The block's fill: the calendar's colour at low alpha, or the app's own
    /// surface where there is none.
    ///
    /// Alpha rather than a blend so the paper underneath still reads as paper
    /// in light and as near-black in dark, which is what keeps a chip looking
    /// like part of this app rather than a web widget pasted into it.
    static func fill(_ hex: String?, isCancelled: Bool = false) -> Color {
        guard let accent = accent(hex) else {
            return PanelStyle.hairline.opacity(isCancelled ? 0.4 : 1)
        }

        return accent.opacity(isCancelled ? 0.08 : 0.18)
    }

    /// The hairline, at full strength, because a 1pt line at 18% alpha is not a
    /// line.
    static func edge(_ hex: String?) -> Color {
        accent(hex) ?? PanelStyle.hairline
    }

    /// Text on a chip.
    ///
    /// Deliberately the system's own label colour rather than the calendar's:
    /// the fill is at 18% alpha, so the surface behind it is what the text is
    /// actually read against, and tinting the text as well is how a chip in a
    /// pale yellow calendar becomes invisible.
    static let label = Color.primary

    /// The multi-slice dot for a merged cluster, in member order, with nulls
    /// kept.
    ///
    /// A calendar not yet refreshed has no colour, and dropping it would give a
    /// two-calendar meeting a one-colour dot — which says something untrue. The
    /// missing slice is drawn in the hairline instead.
    static func slices(_ colours: [String?]) -> [Color] {
        colours.map { accent($0) ?? PanelStyle.hairline }
    }
}

/// The localised words the pure formatters in `PLMailCore` need handed to them.
///
/// The sentence a VoiceOver reader hears is composed in Core so that it can be
/// tested without a simulator; the words in it are catalogue keys, which only
/// this module has. This is the seam between the two.
enum CalendarWords {
    static var allDay: String { String(localized: .ui("All day")) }
    static var floating: String { String(localized: .ui("Floating time")) }
    static var cancelled: String { String(localized: .ui("Cancelled")) }

    /// "in 2 calendars, Work and Personal".
    ///
    /// Composed with `ListFormatter` so the conjunction and the separator come
    /// from the locale — German's *und* and English's *and* are the easy half;
    /// the comma rules are not.
    static func merged(count: Int, names: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        let phrase = String(localized: .ui("in \(count) calendars"))

        return list.isEmpty ? phrase : phrase + ", " + list
    }
}

#endif
