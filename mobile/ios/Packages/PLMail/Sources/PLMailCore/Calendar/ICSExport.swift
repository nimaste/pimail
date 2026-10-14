import Foundation
public import JMAPKit

/// One occurrence, written as an `.ics` file.
///
/// **This is the whole of the "add this to another calendar" story, and it is
/// deliberately not EventKit.** `EKEventEditViewController` would need
/// `NSCalendarsWriteOnlyAccessUsageDescription` in the app's `Info.plist` — a
/// file this change does not own — and a build reaching the system editor
/// without it terminates rather than degrades. An `.ics` needs no entitlement,
/// no usage string and no permission prompt, it opens in Apple's own Calendar
/// as readily as in anything else, and it is the format every other calendar
/// on the device already accepts.
///
/// **An occurrence, not a series.** The cache stores *whether* an event
/// recurs and never the rule it recurs by (see `CalendarService.seriesProperties`),
/// so there is no `RRULE` to write and inventing one from "repeats weekly"
/// would export a different event from the one on screen. What leaves here is
/// the single dated entry the reader was looking at, and ``summaryNote`` says
/// so where a UI can show it.
///
/// Pure and `static`: the escaping, the folding and the three date spellings
/// are exactly the parts that are wrong in a hundred implementations, and they
/// are testable without a simulator.
public enum ICSExport {
    /// RFC 5545 wants CRLF, and a lone LF is what makes a file import
    /// everywhere except Outlook.
    private static let newline = "\r\n"

    /// The `PRODID`, which is what a support request quotes when an import goes
    /// wrong somewhere else.
    static let productID = "-//plMail//iOS calendar//EN"

    /// The file's contents.
    ///
    /// - Parameters:
    ///   - cluster: the row on screen. Only its representative is written: a
    ///     merged cluster is **one meeting** that reached plMail twice, so
    ///     exporting both copies would recreate the duplicate in the
    ///     destination calendar — which is the thing the collapse exists to
    ///     hide.
    ///   - series: the series row, for the description and location the
    ///     occurrence does not carry. Optional, because a share offered before
    ///     the series has been read must still produce a valid file.
    ///   - untitled: what an event with no title is called. Passed in rather
    ///     than written here, because the catalogue lives in `PLMailUI` and a
    ///     literal would ship a German user a file saying "Untitled".
    /// - Returns: a complete `VCALENDAR` with exactly one `VEVENT`, CRLF-ended
    ///   and folded at 75 octets.
    public static func file(
        for cluster: EventCluster,
        series: CalendarEventSnapshot?,
        untitled: String
    ) -> String {
        let row = cluster.representative

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:" + productID,
            // No `METHOD:REQUEST`. That would make the file an iTIP invitation,
            // and an invitation sent from a client that cannot process a reply
            // is a promise nothing here can keep — §5.6.
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:" + uid(for: row),
            "DTSTAMP:" + stamp(),
        ]

        lines += [
            property("DTSTART", row.start, isAllDay: row.isAllDay, zone: row.timeZoneName),
            property("DTEND", row.end, isAllDay: row.isAllDay, zone: row.timeZoneName),
            "SUMMARY:" + escape(row.title.isEmpty ? untitled : row.title),
        ]

        if let location = series?.locationName, location.isEmpty == false {
            lines.append("LOCATION:" + escape(location))
        }

        if let text = series?.eventDescription, text.isEmpty == false {
            lines.append("DESCRIPTION:" + escape(text))
        }

        if row.isCancelled { lines.append("STATUS:CANCELLED") }

        lines += ["END:VEVENT", "END:VCALENDAR"]

        return lines.map(fold).joined(separator: newline) + newline
    }

    /// A filename that is safe on every filesystem a share sheet can reach.
    ///
    /// Derived from the title rather than the id, because a share sheet shows
    /// the filename and `10867_20260803T080000Z.ics` tells the recipient
    /// nothing. Anything outside letters, digits, spaces and dashes is dropped
    /// rather than substituted — a slash in a title is a directory separator on
    /// the other side, and a percent-escape is a filename nobody can read.
    public static func filename(for cluster: EventCluster) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let title = cluster.representative.title.unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespaces)

        return (title.isEmpty ? "event" : String(title.prefix(60))) + ".ics"
    }

    /// A **fresh** uid, never the server's.
    ///
    /// Reusing the JSCalendar `uid` would tell the destination calendar that
    /// this file is the same object as the series it came from — so importing
    /// two occurrences of one standup would overwrite each other, and importing
    /// one would claim to be the whole repeating series. The occurrence id is
    /// unique per dated entry, which is exactly the granularity of what is
    /// being exported.
    static func uid(for row: EventRow) -> String {
        row.occurrenceID.rawValue + "@plmail.export"
    }

    /// `DTSTART`/`DTEND` in the one of three spellings that matches how the
    /// event is actually stored.
    ///
    /// An all-day event is a `VALUE=DATE`, a zoned one carries `TZID`, and a
    /// floating one carries neither — appending a `Z` to a floating event, the
    /// obvious shortcut, moves somebody's birthday by their UTC offset.
    static func property(
        _ name: String, _ local: LocalDateTime, isAllDay: Bool, zone: String?
    ) -> String {
        let parts = local.components

        let date = String(
            format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)

        if isAllDay { return "\(name);VALUE=DATE:\(date)" }

        let time = String(
            format: "%02d%02d%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)

        guard let zone, zone.isEmpty == false else { return "\(name):\(date)T\(time)" }

        return "\(name);TZID=\(zone):\(date)T\(time)"
    }

    /// Now, in UTC, which is the one property RFC 5545 requires to be absolute.
    private static func stamp(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"

        return formatter.string(from: now)
    }

    /// The four characters RFC 5545 gives meaning to inside a value.
    ///
    /// Backslash first, or every escape this function adds is escaped again by
    /// the passes that follow it.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Content lines wrapped at 75 **octets**, continued with a leading space.
    ///
    /// Octets rather than characters: a description in German is full of
    /// two-byte scalars, and a parser counting bytes will split one in half if
    /// the writer counted characters. Splitting on scalar boundaries and
    /// measuring in UTF-8 is what keeps an umlaut intact across a fold.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }

        var folded = ""
        var current = ""
        var budget = 75

        for scalar in line.unicodeScalars {
            let width = String(scalar).utf8.count

            if current.utf8.count + width > budget {
                folded += (folded.isEmpty ? "" : newline + " ") + current
                current = ""
                // A continuation line's leading space counts against its own
                // 75, so every line after the first has one octet less.
                budget = 74
            }

            current.unicodeScalars.append(scalar)
        }

        return folded + (folded.isEmpty ? "" : newline + " ") + current
    }
}
