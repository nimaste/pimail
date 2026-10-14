import Foundation

/// The message a `mailto:` link asks for.
///
/// Five fields and nothing else, because five is what RFC 6068 headers are
/// worth acting on. A link that could set `From` or `Reply-To` is a link that
/// composes mail in somebody else's name from a page the user merely visited,
/// so those names are read and thrown away here rather than reaching the
/// composer.
///
/// Raw tokens rather than parsed addresses: a recipient this app cannot read
/// has to reach the composer as text so the person can see what the link
/// actually asked for. Dropping it here would show a composer addressed to
/// fewer people than the link named, with nothing saying so.
public struct MailtoRequest: Equatable, Sendable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    /// Whether the link carried more than ``Mailto`` was willing to use.
    ///
    /// Surfaced rather than swallowed. A 4 MB `body=` in a link is either a
    /// broken encoder or somebody probing, and both end the same way — a
    /// composer wedged on an editor holding a novel — but a user who watches
    /// text disappear with no explanation learns that the app loses mail.
    public var wasTrimmed: Bool

    public init(
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String = "",
        body: String = "",
        wasTrimmed: Bool = false
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.wasTrimmed = wasTrimmed
    }

    /// Whether this link asked for a blank message.
    ///
    /// `mailto:` on its own is legal and means exactly that, so this is a
    /// normal state rather than a parse failure.
    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.isEmpty
    }

    /// Whether the composer has to show Cc and Bcc for this link to be honest.
    ///
    /// A link that Ccs somebody behind a collapsed disclosure is the failure to
    /// avoid: the message goes to a person the sender never saw named.
    public var needsMoreRecipients: Bool {
        cc.isEmpty == false || bcc.isEmpty == false
    }
}

extension MailtoRequest {
    /// Writes a token list out as a recipient field.
    ///
    /// Every token that reads as an address goes through
    /// ``RecipientParsing/display(_:)``, which quotes a display name carrying a
    /// comma. A token that does **not** read as an address is kept — the person
    /// has to see what the link asked for — but its commas and semicolons are
    /// flattened to spaces first, because the field is re-split on both and one
    /// unreadable recipient must not become three.
    public static func field(from tokens: [String]) -> String {
        tokens.map(entry).joined(separator: ", ")
    }

    private static func entry(_ token: String) -> String {
        if let address = RecipientParsing.parse(token) {
            return RecipientParsing.display(address)
        }

        return String(token.map { ",;".contains($0) ? " " : $0 })
    }
}

/// `mailto:` links, read as a message to open the composer on.
///
/// **A string, not `URLComponents`.** `URLComponents` re-normalises what it is
/// given, and the one thing that must not be re-normalised is the percent
/// encoding: the decisive case is `anna+lists@example.org`, which a
/// form-decoder turns into an address with a space in it that
/// ``RecipientParsing`` then refuses. RFC 6068 is percent-encoding and says
/// nothing about form encoding, so `+` is a plus sign here and never a space. A
/// literal `+` surviving in a subject line is cosmetic; a recipient that
/// silently disappears is not.
///
/// **Every input is hostile until parsed.** A link arrives from a web page, a
/// QR code or another app, so nothing here throws, nothing here trusts a
/// length, and nothing here lets a decoded value become a header it was not.
public enum Mailto {
    /// The scheme, matched case-insensitively: links in the wild are written by
    /// hand and `MAILTO:` appears in real HTML.
    private static let scheme = "mailto:"

    /// The only header names acted on. Anything else — `from`, `reply-to`,
    /// `in-reply-to`, an invented `x-` name — is read past.
    public static let honouredHeaders: Set<String> = ["to", "cc", "bcc", "subject", "body"]

    /// RFC 5322's line limit. A subject longer than this is refused or folded
    /// by the MTA anyway, so accepting one only moves the failure to send time.
    public static let maximumSubjectLength = 998

    /// Enough for a long letter, small enough that `AttributedString` and the
    /// rich-text editor stay responsive. A link carrying more than this is not
    /// a person quoting a paragraph at you.
    public static let maximumBodyLength = 16_384

    /// Past this a recipient list is not a link somebody meant to follow. The
    /// excess is refused rather than sent, and ``MailtoRequest/wasTrimmed``
    /// says so.
    public static let maximumRecipients = 100

    /// The message this link asks for, or nil when it is not a `mailto:`.
    public static func parse(_ url: URL) -> MailtoRequest? {
        // `absoluteString` rather than the parsed components: see the type
        // note. This is the text the other app handed over, escapes intact.
        parse(url.absoluteString)
    }

    /// The string form, so the parsing is covered by tests that need no `URL`
    /// round trip to reproduce a hostile link exactly.
    public static func parse(_ text: String?) -> MailtoRequest? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard trimmed.lowercased().hasPrefix(scheme) else { return nil }

        let rest = String(trimmed.dropFirst(scheme.count))
        let mark = rest.firstIndex(of: "?")
        let head = mark.map { String(rest[rest.startIndex..<$0]) } ?? rest
        let fields = mark.map { String(rest[rest.index(after: $0)...]) } ?? ""

        var request = MailtoRequest(to: splitAddresses(head))

        for field in fields.split(separator: "&", omittingEmptySubsequences: true) {
            let field = String(field)
            let equals = field.firstIndex(of: "=")
            let name = decodePercent(equals.map { String(field[field.startIndex..<$0]) } ?? field)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = equals.map { String(field[field.index(after: $0)...]) } ?? ""

            switch name {
            // Added to what came before the `?` rather than replacing it: RFC
            // 6068 allows both spellings and one link may use both, so the two
            // lists are one list.
            case "to": request.to += splitAddresses(value)
            case "cc": request.cc += splitAddresses(value)
            case "bcc": request.bcc += splitAddresses(value)
            case "subject": request.subject = singleLine(decodePercent(value))
            case "body": request.body = plainBody(decodePercent(value))
            default: break
            }
        }

        return capped(request)
    }

    // MARK: - Recipients

    /// Splits a recipient list, then decodes what it split.
    ///
    /// That order, and it is the whole reason this is not one line. Decoding
    /// first lets a `%2C` inside a quoted display name become a separator and
    /// cut one recipient into two halves, neither of which is an address and
    /// both of which are then shown back as junk. Splitting first leaves an
    /// encoded comma inside the address it belongs to.
    private static func splitAddresses(_ field: String) -> [String] {
        field.split(separator: ",", omittingEmptySubsequences: false)
            .map { singleLine(decodePercent(String($0))) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    // MARK: - Sanitising

    /// Flattens a decoded value to one line.
    ///
    /// **This is the header-injection guard.** `?subject=Hi%0D%0ABcc:evil@x`
    /// decodes to a subject with a CRLF in it. This client sends over JMAP,
    /// where the subject is a JSON string and cannot become a second header —
    /// but the same string is written to a draft the server later renders into
    /// RFC 5322, and a newline that reaches a header field there is a header
    /// somebody else wrote.
    ///
    /// **Scalar by scalar, not character by character, and that is the whole
    /// reason this is not `map` over a `String`.** Swift reads `\r\n` as a
    /// single `Character`, so substituting per character makes the result
    /// depend on where grapheme boundaries happen to fall: `\r\n` would
    /// collapse to one space while `\n\r` produced two. A guard whose output
    /// varies with cluster boundaries is a guard nobody can write a test
    /// against. Every offending scalar becomes one space — replaced rather than
    /// removed, so `Hi\r\nThere` reads as `Hi  There` rather than `HiThere`.
    private static func singleLine(_ text: String) -> String {
        var out = String.UnicodeScalarView()

        for scalar in text.unicodeScalars {
            out.append(isLineBreak(scalar) || isForbidden(scalar) ? " " : scalar)
        }

        return String(out)
    }

    /// Strips the scalars a body has no use for, keeping the ones it does.
    ///
    /// Tabs and newlines are text and stay. A NUL, a backspace or a
    /// bidirectional override is not: the last of those reverses how the rest
    /// of the message renders, which is how a body that reads as one thing in
    /// the composer arrives as another.
    private static func plainBody(_ text: String) -> String {
        var out = String.UnicodeScalarView()

        for scalar in text.unicodeScalars where isForbidden(scalar) == false {
            out.append(scalar)
        }

        return String(out)
    }

    /// The scalars that end a line.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x2028, 0x2029: true
        default: false
        }
    }

    /// The scalars nothing arriving from a link is allowed to carry.
    ///
    /// **Named individually rather than taken from `generalCategory`.** The
    /// obvious spelling — dropping everything in `.control` and `.format` —
    /// also drops U+200D, the zero-width joiner, which is what holds a family
    /// emoji together: a body pasted from a chat app would arrive visibly
    /// broken. So this is the C0 controls except tab, LF and CR; DEL; the C1
    /// block; and the bidirectional embeddings, overrides and isolates, which
    /// are the only formatting characters that can make text render as
    /// something other than what it says.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F: true
        case 0x80...0x9F: true
        case 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// Refuses the parts of a link that are too big to be meant.
    private static func capped(_ request: MailtoRequest) -> MailtoRequest {
        var capped = request
        var trimmed = false

        for field in [\MailtoRequest.to, \MailtoRequest.cc, \MailtoRequest.bcc] {
            if capped[keyPath: field].count > maximumRecipients {
                capped[keyPath: field] = Array(capped[keyPath: field].prefix(maximumRecipients))
                trimmed = true
            }
        }

        if capped.subject.count > maximumSubjectLength {
            capped.subject = String(capped.subject.prefix(maximumSubjectLength))
            trimmed = true
        }

        if capped.body.count > maximumBodyLength {
            capped.body = String(capped.body.prefix(maximumBodyLength))
            trimmed = true
        }

        capped.wasTrimmed = trimmed

        return capped
    }

    // MARK: - Percent decoding

    /// Percent-decoding over bytes rather than over characters.
    ///
    /// A run of escapes is gathered before any of it is decoded, because one
    /// character can be up to four of them: `%C3%A4` is a single `ä`, and
    /// decoding each escape on its own yields two replacement marks. Every
    /// German subject line in a `mailto:` comes through here.
    ///
    /// A `%` not followed by two hex digits is kept as itself. A hand-written
    /// link with a per cent sign in the subject is far likelier than a
    /// truncated escape, and the alternative — failing — turns a defect in
    /// somebody else's HTML into a composer that refuses to open.
    ///
    /// Malformed UTF-8 becomes U+FFFD rather than an error, for the same
    /// reason: a link from a broken encoder still opens a composer, with one
    /// visibly wrong character in it.
    static func decodePercent(_ text: String) -> String {
        guard text.contains("%") else { return text }

        var out = ""
        var bytes: [UInt8] = []
        var index = text.startIndex

        func flush() {
            guard bytes.isEmpty == false else { return }

            out += String(decoding: bytes, as: UTF8.self)
            bytes.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            guard text[index] == "%", let byte = hexByte(in: text, after: index) else {
                flush()
                out.append(text[index])
                index = text.index(after: index)
                continue
            }

            bytes.append(byte)
            index = text.index(index, offsetBy: 3)
        }

        flush()

        return out
    }

    /// The byte spelled by the two characters after `index`, or nil when
    /// either is missing or is not a hex digit.
    private static func hexByte(in text: String, after index: String.Index) -> UInt8? {
        guard let first = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
            let second = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
            first < text.endIndex, second < text.endIndex,
            let high = text[first].hexDigitValue, let low = text[second].hexDigitValue
        else { return nil }

        return UInt8(high << 4 | low)
    }
}
