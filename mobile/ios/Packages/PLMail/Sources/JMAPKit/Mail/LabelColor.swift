/// The colour a label was given, as a closed vocabulary rather than a string.
///
/// plMail puts colour on the wire in both directions — `MailboxMapper` emits
/// it and `MailboxSetMethod` accepts it — as one of nine Tailwind tokens, never
/// hex. Modelling it as a `String` would let a client send `"#ff0000"`, which
/// the server refuses with `invalidProperties`, and would put the vocabulary in
/// no single place to compare against the web UI's swatch row.
///
/// **Absent is a third state, not grey.** A label with no colour chosen is
/// distinct from one deliberately coloured grey, and only the first may fall
/// back to the hashed `AvatarPalette` tint. Collapsing them would repaint every
/// label somebody chose grey on purpose.
public enum LabelColor: String, Hashable, Sendable, Codable, CaseIterable {
    case gray
    case red
    case orange
    case amber
    case green
    case teal
    case blue
    case violet
    case pink

    /// Decodes a token, treating one this build has not heard of as *no colour
    /// chosen*.
    ///
    /// The server's vocabulary can grow, and a newer instance sending a tenth
    /// token must not make a label undecodable — a label that fails to parse
    /// disappears from the sidebar, which is a far worse outcome than one drawn
    /// in its fallback tint.
    public init?(wire: String?) {
        guard let wire, let known = LabelColor(rawValue: wire) else { return nil }

        self = known
    }
}
