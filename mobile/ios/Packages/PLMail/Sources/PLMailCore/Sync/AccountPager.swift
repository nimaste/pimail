import Foundation
import JMAPKit

/// Pages one account's slice of one feed.
///
/// **Pages by date, never by `position`.** Two independent reasons:
///
/// 1. `EmailQueryRunner` runs the filter with no SQL `LIMIT` — it pulls every
///    matching row into PHP, collapses threads there, and slices. So
///    `position: 5000` costs exactly what `position: 0` costs: the whole
///    mailbox, on every page, on someone's NAS.
/// 2. `position` is unstable. Mail arriving between page one and page two
///    shifts every index, which shows up as duplicated and skipped rows.
///
/// `before` is a first-class filter condition (`received_at < :x`), so paging
/// on it is ordinary API use rather than a workaround, and new mail is always
/// newer than the cursor and cannot disturb the window.
public struct AccountPager: Sendable {
    /// Pages are 50 rows. The server caps a query at 500, but a page is what a
    /// person scrolls past, not what a machine can carry.
    public static let pageSize = 50

    public let accountKey: String
    public let accountID: AccountID

    /// Everything the feed selects, before paging narrows it.
    public let baseFilter: EmailFilter?

    public init(accountKey: String, accountID: AccountID, baseFilter: EmailFilter?) {
        self.accountKey = accountKey
        self.accountID = accountID
        self.baseFilter = baseFilter
    }

    public struct Page: Sendable {
        public var rows: [FeedRow]
        public var emails: [Email]
        public var threads: [MailThread]
        public var emailState: StateToken?
        public var cursor: FeedCursorSnapshot
    }

    /// Fetches the page after `cursor`.
    public func page(
        after cursor: FeedCursorSnapshot, using client: JMAPClient
    ) async throws -> Page {
        guard cursor.isExhausted == false else {
            return Page(rows: [], emails: [], threads: [], emailState: nil, cursor: cursor)
        }

        let session = try await client.session()
        var builder = RequestBuilder(session: session)

        let query = builder.add(
            EmailQuery(
                accountID: accountID,
                filter: filter(for: cursor),
                sort: [.newestFirst],
                collapseThreads: true,
                limit: Self.pageSize + cursor.boundaryIDs.count
            )
        )

        let get = builder.add(
            EmailGet(
                accountID: accountID,
                ids: .reference(query.reference(path: "/ids")),
                properties: EmailGet.listRowProperties
            )
        )

        // Chained back-reference: the thread ids come out of the *previous*
        // call's result via the `/*` wildcard, so one round trip carries
        // query, emails and the thread membership behind each row. Verified
        // against the server — the alternative is a second round trip per page
        // over a home uplink.
        let threads = builder.add(
            ThreadGet(
                accountID: accountID,
                ids: .reference(get.reference(path: "/list/*/threadId"))
            )
        )

        let results = try await client.send(builder)

        let queryResult = try results.result(of: query)
        let emails = try results.result(of: get).list
        let threadList = try results.result(of: threads).list

        // `Email/get` answers in repository order, not the order asked for.
        // Re-ordering against the query is what keeps the list in date order
        // rather than database-id order.
        let ordered = reorder(emails, toMatch: queryResult.ids)

        return page(
            from: ordered, threads: threadList, state: queryResult.queryState, after: cursor)
    }

    // MARK: - Filtering

    private func filter(for cursor: FeedCursorSnapshot) -> EmailFilter? {
        guard let lastSortDate = cursor.lastSortDate else { return baseFilter }

        // `before` is a strict `<`, so asking for `< lastSortDate` would drop
        // every other message sharing that second. Ask for one second later
        // and filter the already-seen ids out client-side instead: exact,
        // and one extra second of overlap is cheaper than a missing message.
        let bound = UTCDate(lastSortDate.addingTimeInterval(1))

        guard let baseFilter else { return .before(bound) }

        return .and([baseFilter, .before(bound)])
    }

    private func reorder(_ emails: [Email], toMatch ids: [EmailID]) -> [Email] {
        let byID = Dictionary(emails.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return ids.compactMap { byID[$0] }
    }

    private func page(
        from emails: [Email],
        threads: [MailThread],
        state: StateToken,
        after cursor: FeedCursorSnapshot
    ) -> Page {
        var rows: [FeedRow] = []
        var lastDate = cursor.lastSortDate
        var boundary = cursor.boundaryIDs

        for email in emails {
            // Already emitted at exactly the boundary second on a previous
            // page. This is the whole reason boundary ids are tracked.
            guard cursor.boundaryIDs.contains(email.id.rawValue) == false else { continue }
            guard let threadID = email.threadID else { continue }

            let sortDate = email.receivedAt?.date ?? .distantPast

            rows.append(
                FeedRow(
                    threadID: threadID.rawValue,
                    emailID: email.id.rawValue,
                    sortDate: sortDate
                )
            )

            if lastDate != sortDate {
                lastDate = sortDate
                boundary = [email.id.rawValue]
            } else {
                boundary.insert(email.id.rawValue)
            }
        }

        // Short page means the mailbox is exhausted. Judged on what the server
        // returned, not on what was kept: filtering boundary ids out could
        // otherwise make a full page look like the end of the list.
        let isExhausted = emails.count < Self.pageSize

        return Page(
            rows: rows,
            emails: emails,
            threads: threads,
            emailState: state,
            cursor: FeedCursorSnapshot(
                lastSortDate: lastDate,
                boundaryIDs: boundary,
                isExhausted: isExhausted
            )
        )
    }
}
