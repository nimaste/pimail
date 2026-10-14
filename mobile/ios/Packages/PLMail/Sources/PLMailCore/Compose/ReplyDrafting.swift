import Foundation
import JMAPKit

/// Working out what a reply or a forward starts as.
///
/// Pure functions, deliberately away from ``ComposeModel``: every rule here is
/// one somebody has to be able to check without a server, and each of them was
/// wrong in a way that only shows up on somebody else's screen — a stacked
/// subject line, the sender copied on their own reply, a `References` header an
/// MTA refuses.
public enum ReplyDrafting {
    // MARK: - Subjects

    /// Reply prefixes across the languages plMail is used in.
    ///
    /// German is first-class here: `AW:` is what every Outlook in the
    /// user's own country writes, and a client that only knows `Re:` turns a
    /// three-message German thread into `Re: AW: Re: Angebot`.
    static let replyPrefixes: Set<String> = ["re", "aw", "antw", "sv", "vs", "odp", "ref"]

    /// Forward prefixes, same reasoning. `WG:` is German for `Fwd:`.
    static let forwardPrefixes: Set<String> = [
        "fw", "fwd", "wg", "tr", "rv", "enc", "vb",
    ]

    /// Strips every reply and forward prefix from the front of a subject.
    ///
    /// Repeatedly and across both families, because that is how they arrive: a
    /// reply to a forward is `Re: x`, not `Re: Fwd: x`. Outlook's `Re[2]:`
    /// counter is recognised and dropped with the prefix it belongs to —
    /// leaving it behind produced `Re: Re[2]: x`, which is the stacking this
    /// exists to stop wearing a different hat.
    public static func strippingPrefixes(_ subject: String) -> String {
        var rest = Substring(subject.trimmingCharacters(in: .whitespacesAndNewlines))

        while let stripped = strippingOnePrefix(rest) {
            rest = stripped
        }

        return String(rest)
    }

    /// One prefix, or nil when the front of the string is not one.
    private static func strippingOnePrefix(_ text: Substring) -> Substring? {
        var cursor = text.startIndex
        var token = ""

        while cursor < text.endIndex, text[cursor].isLetter {
            token.append(text[cursor])
            cursor = text.index(after: cursor)
        }

        // Two to four letters: long enough to exclude a one-letter word,
        // short enough that a real subject beginning "Report: Q3" is not
        // mistaken for a prefix. `ref` and `enc` are the longest in the lists.
        guard token.count >= 2, token.count <= 4 else { return nil }

        let lowered = token.lowercased()

        guard replyPrefixes.contains(lowered) || forwardPrefixes.contains(lowered) else {
            return nil
        }

        // Outlook's repeat counter, `Re[2]:`.
        if cursor < text.endIndex, text[cursor] == "[" {
            guard let close = text[cursor...].firstIndex(of: "]") else { return nil }

            let digits = text[text.index(after: cursor)..<close]

            guard digits.isEmpty == false, digits.allSatisfy(\.isNumber) else { return nil }

            cursor = text.index(after: close)
        }

        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }

        guard cursor < text.endIndex, text[cursor] == ":" else { return nil }

        cursor = text.index(after: cursor)

        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }

        return text[cursor...]
    }

    public static func replySubject(_ subject: String?) -> String {
        "Re: " + strippingPrefixes(subject ?? "")
    }

    public static func forwardSubject(_ subject: String?) -> String {
        "Fwd: " + strippingPrefixes(subject ?? "")
    }

    // MARK: - Threading

    /// How many ids a `References` header may carry.
    ///
    /// RFC 5537 §3.4.4. A hundred-message thread otherwise produces a header
    /// long enough that some MTAs refuse the message outright — and the failure
    /// arrives as a bounce for the person replying, not for whoever started the
    /// thread.
    public static let referencesLimit = 20

    /// The `References` header for a reply.
    ///
    /// The **first** id is always kept: every threading algorithm finds the
    /// root of a conversation through it, so trimming from the front would
    /// split a long thread in two on the recipient's screen. Ids are dropped
    /// from the second onwards.
    public static func references(
        continuing existing: [String], with messageID: String?
    ) -> [String] {
        var all = existing

        if let messageID, all.last != messageID { all.append(messageID) }

        guard all.count > referencesLimit else { return all }

        return [all[0]] + all.suffix(referencesLimit - 1)
    }

    // MARK: - Recipients

    /// Who a reply goes to.
    ///
    /// `answering` is the address being replied to — `Reply-To` where the
    /// original carried one, which is that header's entire purpose and what
    /// every mailing list depends on. `own` is every address the user can send
    /// as, lowercased.
    ///
    /// Reply-all excluded only the original sender before, so replying to a
    /// thread you are already on put you in your own Cc line: a copy of your
    /// own reply in your inbox, forever, once per message.
    public static func replyRecipients(
        answering: [EmailAddress],
        originalTo: [EmailAddress],
        originalCc: [EmailAddress],
        all: Bool,
        own: Set<String>
    ) -> (to: [EmailAddress], cc: [EmailAddress]) {
        let to = RecipientParsing.deduplicated(answering)

        guard all else { return (to, []) }

        // Header order, not alphabetical. `Array(Set(…)).sorted()` reordered
        // every Cc line, which on a thread with a team in it makes a reply look
        // like it was addressed to different people than the message it answers.
        let inTo = Set(to.map { $0.email.lowercased() })
        let cc = RecipientParsing.deduplicated(originalTo + originalCc)
            .filter { own.contains($0.email.lowercased()) == false }
            .filter { inTo.contains($0.email.lowercased()) == false }

        return (to, cc)
    }

    // MARK: - Forwarding

    /// The block that introduces a forwarded message.
    ///
    /// Not the reply quote. Reusing that produced "On 3 March, Ada wrote:" above
    /// a message the user is forwarding rather than answering, which reads as
    /// the forwarder claiming to have been written to.
    ///
    /// Every field is escaped: a subject containing `<b>` must not start
    /// rendering as markup in the recipient's client.
    public static func forwardBlock(
        from: String,
        date: Date?,
        subject: String?,
        to: [EmailAddress],
        cc: [EmailAddress]
    ) -> String {
        var rows: [String] = [
            MailHTML.escape(
                String(localized: "---------- Forwarded message ----------", bundle: .module))
        ]

        rows.append(row(String(localized: "From:", bundle: .module), from))

        if let date {
            rows.append(
                row(
                    String(localized: "Date:", bundle: .module),
                    date.formatted(date: .long, time: .shortened)))
        }

        if let subject, subject.isEmpty == false {
            rows.append(row(String(localized: "Subject:", bundle: .module), subject))
        }

        if to.isEmpty == false {
            rows.append(
                row(String(localized: "To:", bundle: .module), RecipientParsing.field(from: to)))
        }

        if cc.isEmpty == false {
            rows.append(
                row(String(localized: "Cc:", bundle: .module), RecipientParsing.field(from: cc)))
        }

        return rows.map { "<div>\($0)</div>" }.joined()
    }

    private static func row(_ label: String, _ value: String) -> String {
        "\(MailHTML.escape(label)) \(MailHTML.escape(value))"
    }
}
