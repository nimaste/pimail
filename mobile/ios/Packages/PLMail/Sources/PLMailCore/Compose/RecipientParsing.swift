import Foundation
import JMAPKit

/// Turning a typed recipient field into addresses.
///
/// Split out of ``ComposeModel`` so it can be tested without a server, a store
/// or a main actor — this is the code path every message goes through, and the
/// failures it prevents are all silent ones: a recipient dropped, a recipient
/// invented, or a message delivered twice to the same person.
public enum RecipientParsing {
    /// One entry someone typed, after splitting but before it is trusted.
    ///
    /// The raw text is kept beside the parsed address so an entry that is
    /// *not* an address can be shown back to the person who typed it. The
    /// previous behaviour — filtering on `contains("@")` at send time — meant a
    /// typo left the composer looking correct and the message going to fewer
    /// people than it named.
    public struct Entry: Hashable, Sendable, Identifiable {
        public var raw: String
        public var address: EmailAddress?

        public var id: String { raw }
        public var isValid: Bool { address != nil }
    }

    /// Splits a field into entries, respecting quotes and angle brackets.
    ///
    /// `"Meyer, Anna" <anna@example.org>` is an ordinary Outlook address and
    /// contains a comma inside its quoted display name. Splitting on every
    /// comma cut it into `"Meyer` — dropped for having no `@` — and
    /// `Anna" <anna@example.org>`, which was then used verbatim as the address.
    /// The mail went to a syntactically broken recipient and nothing said so.
    public static func split(_ field: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        var angleDepth = 0

        for character in field {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            switch character {
            case "\\" where isQuoted:
                current.append(character)
                isEscaped = true

            case "\"":
                isQuoted.toggle()
                current.append(character)

            case "<" where isQuoted == false:
                angleDepth += 1
                current.append(character)

            case ">" where isQuoted == false:
                angleDepth = max(0, angleDepth - 1)
                current.append(character)

            case ",", ";":
                // A separator inside a quoted name or an angle-address is part
                // of the address, not between two of them.
                if isQuoted || angleDepth > 0 {
                    current.append(character)
                } else {
                    tokens.append(current)
                    current = ""
                }

            default:
                current.append(character)
            }
        }

        tokens.append(current)

        return
            tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    /// Reads one entry as `Name <address>`, `<address>` or a bare address.
    ///
    /// The name is kept. Throwing it away — which the previous field did by
    /// building `EmailAddress(email:)` from the whole token — meant the
    /// recipient of a reply saw a raw address where the sender had typed a
    /// person's name, and meant a picked suggestion lost the name the contact
    /// list had just supplied.
    public static func parse(_ token: String) -> EmailAddress? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else { return nil }

        guard let open = trimmed.lastIndex(of: "<"),
            let close = trimmed[open...].firstIndex(of: ">")
        else {
            guard isAddress(trimmed) else { return nil }

            return EmailAddress(name: nil, email: trimmed)
        }

        let address = String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isAddress(address) else { return nil }

        let name = unquote(String(trimmed[trimmed.startIndex..<open]))

        return EmailAddress(name: name.isEmpty ? nil : name, email: address)
    }

    /// Every entry in a field, valid or not, in the order they were typed.
    public static func entries(in field: String) -> [Entry] {
        split(field).map { Entry(raw: $0, address: parse($0)) }
    }

    /// The addresses a message should actually go to.
    ///
    /// De-duplicated case-insensitively on the address, keeping the first
    /// spelling of the name: pasting a list that names one person twice used to
    /// deliver two copies, and a recipient who gets a message twice reads it as
    /// the sender being careless.
    public static func addresses(in field: String) -> [EmailAddress] {
        deduplicated(entries(in: field).compactMap(\.address))
    }

    /// The entries that are not addresses, so the composer can say so.
    public static func invalid(in field: String) -> [String] {
        entries(in: field).filter { $0.isValid == false }.map(\.raw)
    }

    /// Case-insensitive de-duplication, first spelling wins.
    public static func deduplicated(_ addresses: [EmailAddress]) -> [EmailAddress] {
        var seen: Set<String> = []

        return addresses.filter { seen.insert($0.email.lowercased()).inserted }
    }

    /// Writes a field back out, which is how a picked suggestion and a
    /// normalised field reach the text box.
    public static func field(from addresses: [EmailAddress]) -> String {
        addresses.map(display).joined(separator: ", ")
    }

    /// One address as a person would type it.
    public static func display(_ address: EmailAddress) -> String {
        guard let name = address.name, name.isEmpty == false else { return address.email }

        // Quoted whenever it carries anything that would re-split — otherwise
        // writing the field back out and reading it again is not the identity
        // it has to be.
        let needsQuoting = name.contains(where: { ",;<>\"".contains($0) })
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return needsQuoting ? "\"\(escaped)\" <\(address.email)>" : "\(name) <\(address.email)>"
    }

    /// Whether a bare string is usable as an address.
    ///
    /// Deliberately narrow rather than RFC-complete: exactly one `@` with
    /// something either side and no whitespace. `a@@b`, `@b` and `a@` were all
    /// accepted before and all bounce at the far end, hours later, in a
    /// delivery report most people never read.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)

        guard parts.count == 2, parts[0].isEmpty == false, parts[1].isEmpty == false else {
            return false
        }

        return text.contains(where: { $0.isWhitespace }) == false
            && text.contains(where: { "<>,;\"".contains($0) }) == false
    }

    /// Strips the quotes around a display name and undoes its escapes.
    private static func unquote(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }

        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
