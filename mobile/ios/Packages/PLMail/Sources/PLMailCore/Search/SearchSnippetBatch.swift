import Foundation

/// Splits a set of ids into requests `SearchSnippet/get` will actually accept.
///
/// `SearchSnippetGetMethod` refuses more than 500 ids with `requestTooLarge`,
/// and this client's snippet fetch treats any failure as "no highlighting" and
/// carries on. Together those two reasonable decisions meant that the moment a
/// search paged past 500 results, **every** row in **every** account lost its
/// highlighting at once, silently — the one feature that tells a person why a
/// result came back.
///
/// A separate type rather than a `chunked` call at the call site so the cap has
/// a name, a source, and a test, instead of being a 500 somebody has to
/// recognise.
public enum SearchSnippetBatch {
    /// `SearchSnippetGetMethod::MAX_OBJECTS`, which matches the session's
    /// `maxObjectsInGet`.
    ///
    /// A snippet costs a `ts_headline` over a whole message body, so this is
    /// the one get the server enforces the ceiling on rather than assuming it.
    public static let maximumIDs = 500

    /// `ids` in request-sized runs, in order, with no empty batch.
    ///
    /// Order is preserved because the rows are already on screen in date order:
    /// highlighting that arrives top-down looks like the page sharpening, and
    /// highlighting that arrives in an arbitrary order looks like flicker.
    public static func batches<ID>(_ ids: [ID]) -> [[ID]] {
        guard ids.isEmpty == false else { return [] }

        return stride(from: 0, to: ids.count, by: maximumIDs).map { start in
            Array(ids[start..<min(start + maximumIDs, ids.count)])
        }
    }
}
