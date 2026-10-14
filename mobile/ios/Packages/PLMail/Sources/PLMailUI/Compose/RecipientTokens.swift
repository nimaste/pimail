import PLMailCore

/// Splitting a recipient field into the part that is settled and the part
/// still being typed.
///
/// **Deliberately not `#if os(iOS)`, and deliberately not inside the view.**
/// This is the arithmetic behind the chips, and every one of its failures
/// loses somebody a recipient — a dropped token, a fragment silently promoted
/// to an address, a removal that takes the wrong one out. That is exactly the
/// kind of thing that has to be testable without a simulator, so it lives here
/// as plain functions over strings rather than as computed properties on a
/// `View` no test can reach.
///
/// The field itself stays one comma-separated string throughout: it is what
/// the draft saves, what the autosave compares and what
/// ``RecipientParsing/addresses(in:)`` reads at send. Chips are a view of it,
/// never a second copy of it.
enum RecipientTokens {
    /// The recipients that have been typed past, in order.
    ///
    /// Split by ``RecipientParsing/split(_:)`` rather than on every comma, so
    /// `"Meyer, Anna" <anna@example.org>` stays one recipient — the same rule
    /// the send path applies, which is the point of borrowing it.
    static func committed(in field: String) -> [String] {
        let tokens = RecipientParsing.split(field)

        guard endsWithSeparator(field) == false else { return tokens }

        return tokens.isEmpty ? [] : Array(tokens.dropLast())
    }

    /// What is being typed now: whatever follows the last separator.
    static func fragment(in field: String) -> String {
        endsWithSeparator(field) ? "" : RecipientParsing.split(field).last ?? ""
    }

    /// Whether the last non-blank character commits the recipient before it.
    static func endsWithSeparator(_ field: String) -> Bool {
        guard let last = field.last(where: { $0.isWhitespace == false }) else { return false }

        return last == "," || last == ";"
    }

    /// Puts the field back together.
    ///
    /// The trailing `", "` after the settled recipients is what keeps them
    /// settled: without it the last one would come apart into the fragment
    /// again the moment the text after it changed.
    static func joined(_ tokens: [String], typing fragment: String) -> String {
        guard tokens.isEmpty == false else { return fragment }

        return tokens.joined(separator: ", ") + ", " + fragment
    }

    /// Drops one settled recipient, leaving what is being typed alone.
    ///
    /// By position rather than by value: the same address can legitimately
    /// appear twice — a list pasted over one already there — and tapping the
    /// second chip has to remove the second one. De-duplication happens at
    /// send, where it can be seen.
    static func removing(at index: Int, in field: String) -> String {
        var tokens = committed(in: field)

        guard tokens.indices.contains(index) else { return field }

        tokens.remove(at: index)

        return joined(tokens, typing: fragment(in: field))
    }
}
