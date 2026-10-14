#if os(iOS)

public import PLMailCore

import SwiftUI

/// The things a search result list cannot say for itself.
///
/// Two of them, and both used to be pure silence:
///
/// - **A contradiction.** `is:read is:unread` returns nothing, on this client
///   and in the browser, because both flags are honoured independently. That is
///   correct and it is invisible: the person sees an empty list with two lit
///   tokens above it and no reason. The chips already drop a conflicting
///   `is:read` when a chip is what set it; typing both by hand got nothing.
/// - **A skipped account.** An account with no binding for the role `in:` named
///   — or, since `label:` arrived, for the label it named — is dropped from the
///   merge entirely, because including it unfiltered would return that
///   account's whole mailbox as "results". Right, and it looks exactly like
///   mail having gone missing. Archive is created unsubscribed on this server,
///   so `in:archive` hits this on a perfectly healthy install.
///
/// Deliberately a strip above the results rather than a `ContentUnavailableView`
/// underneath them: a skipped account matters even when the accounts that did
/// answer found plenty.
struct SearchNoticesView: View {
    /// The query as typed, so the notices track the field rather than the
    /// settled search a debounce behind it.
    let query: ParsedSearchQuery

    /// Every account and its mailboxes, for working out which accounts the
    /// query cannot reach.
    let accounts: [AccountSnapshot]
    let mailboxes: [MailboxSnapshot]

    /// The field's contents, and the way to rewrite them. The contradiction
    /// notice resolves itself by editing visible text, never by overriding the
    /// query behind the person's back.
    let raw: String
    let onChange: (String) -> Void

    var body: some View {
        if query.isContradictory || skipped.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                if query.isContradictory { contradiction }

                if skipped.isEmpty == false { skippedAccounts }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var contradiction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(.ui("Nothing can be both read and unread, so this finds nothing."))
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // One button, not two. "Unread only" is what somebody who typed
            // both almost always wanted, and a pair of buttons here would be a
            // quiz about a mistake.
            Button(.ui("Show unread only")) {
                onChange(SearchQueryEditor.removingRead(in: raw))
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .accessibilityElement(children: .combine)
    }

    private var skippedAccounts: some View {
        Label {
            skippedDescription
        } icon: {
            Image(systemName: "questionmark.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(skippedDescription)
    }

    /// Names the accounts rather than counting them: "1 account was skipped"
    /// leaves the person to work out which of their three it was.
    private var skippedDescription: Text {
        Text(.ui("Not searched, having no matching mailbox: "))
            + Text(skipped.map(\.displayName).sorted().formatted(.list(type: .and)))
    }

    /// Accounts the query cannot be asked of at all.
    ///
    /// Computed here from the same resolver the search itself uses, so the note
    /// cannot drift from the merge — a note derived from a second rule would
    /// eventually name an account that did take part.
    private var skipped: [AccountSnapshot] {
        guard query.mailboxRole != nil || query.label?.isEmpty == false else { return [] }

        return accounts.filter { account in
            SearchQueryCompiler.scope(
                for: query,
                mailboxes: mailboxes.filter { $0.accountKey == account.accountKey }
            ).canSearch == false
        }
    }
}

#endif
