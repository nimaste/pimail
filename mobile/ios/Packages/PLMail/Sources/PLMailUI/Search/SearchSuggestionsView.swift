#if os(iOS)

import PLMailCore
import SwiftUI

/// What to offer under the search field while somebody is typing.
///
/// Three kinds of row, visibly different so the list reads as help rather than
/// as a set of results: a past search, a person, and an operator with what it
/// does written beside it. The operators are the reason this exists — they are
/// the most useful thing about this field and nobody discovers them by
/// guessing.
///
/// Rows are plain buttons rather than `.searchCompletion`, which sets the text
/// *and* submits. Half of these suggestions are deliberately unfinished:
/// `from:` is an invitation to keep typing, and submitting it would run a
/// search for nothing.
struct SearchSuggestionsView: View {
    let suggestions: [SearchSuggestion]

    /// Called with the new field contents, and whether the search should run.
    let onPick: (_ completion: String, _ shouldSubmit: Bool) -> Void

    var body: some View {
        ForEach(suggestions) { suggestion in
            Button {
                onPick(suggestion.completion, suggestion.isComplete)
            } label: {
                row(for: suggestion)
            }
            // Plain, or every row is tinted like a link and the list reads as
            // nine actions rather than nine things to choose between.
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(for suggestion: SearchSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: suggestion.kind))
                .foregroundStyle(.secondary)
                // A fixed box, so the titles line up down the list rather than
                // stepping in and out with each glyph's width.
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    // Monospaced for the operators: they are syntax to be typed
                    // exactly, and it sets them apart from the prose beside
                    // them.
                    .font(suggestion.kind == .searchOperator ? .body.monospaced() : .body)
                    .foregroundStyle(.primary)

                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func symbol(for kind: SearchSuggestion.Kind) -> String {
        switch kind {
        case .recent: "clock.arrow.circlepath"
        case .sender: "person.crop.circle"
        case .searchOperator: "line.3.horizontal.decrease.circle"
        }
    }
}

#endif
