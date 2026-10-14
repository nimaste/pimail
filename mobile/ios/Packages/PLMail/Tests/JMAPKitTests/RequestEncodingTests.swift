import Foundation
import Testing

@testable import JMAPKit

/// The highest-value tests in the project.
///
/// Every detail asserted here fails **silently** if it is wrong: the server
/// either rejects the whole request with a message that does not name the
/// cause, or — worse — accepts it and answers something plausible. None of it
/// is visible in a debugger after the fact, so it is pinned byte for byte.
@Suite("Request encoding")
struct RequestEncodingTests {
    /// The canonical page fetch: query for ids, then get those ids in the same
    /// round trip. Over a home uplink the difference between one round trip
    /// and two is the difference between a list that appears and a list that
    /// arrives.
    @Test("Email/query + back-referenced Email/get encodes exactly")
    func queryAndGetPairing() throws {
        var builder = RequestBuilder(maxCalls: 32)

        let query = builder.add(
            EmailQuery(
                accountID: AccountID("7"),
                filter: .inMailbox(MailboxID("13")),
                sort: [.newestFirst],
                collapseThreads: true,
                limit: 50
            )
        )
        builder.add(
            EmailGet(
                accountID: AccountID("7"),
                ids: .reference(query.reference(path: "/ids")),
                properties: ["id", "subject"]
            )
        )

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self) == """
                {"methodCalls":[["Email/query",{"accountId":"7","collapseThreads":true,\
                "filter":{"inMailbox":"13"},"limit":50,"position":0,\
                "sort":[{"isAscending":false,"property":"receivedAt"}]},"c0"],\
                ["Email/get",{"#ids":{"name":"Email/query","path":"/ids","resultOf":"c0"},\
                "accountId":"7","properties":["id","subject"]},"c1"]],\
                "using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:mail"]}
                """
        )
    }

    /// An integer `accountId` is rejected with `invalidArguments` — the server
    /// does not coerce it. The id newtypes make this structural, and this
    /// pins it.
    @Test("accountId is always a JSON string")
    func accountIDIsAString() throws {
        var builder = RequestBuilder()
        builder.add(MailboxGet(accountID: AccountID("7")))

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self).contains("\"accountId\":\"7\""))
    }

    /// RFC 8621 spells it `fetchHTMLBodyValues`. Spelled `fetchHtmlBodyValues`
    /// it is simply an argument the server does not recognise: `bodyValues`
    /// comes back empty, with no error anywhere.
    @Test("fetchHTMLBodyValues is capitalised the way the server reads it")
    func htmlBodyValuesCapitalisation() throws {
        var builder = RequestBuilder()
        builder.add(
            EmailGet(
                accountID: AccountID("7"),
                ids: .value([EmailID("1041")]),
                fetchTextBodyValues: true,
                fetchHTMLBodyValues: true
            )
        )

        let encoded = try String(decoding: builder.encoded(), as: UTF8.self)

        #expect(encoded.contains("\"fetchHTMLBodyValues\":true"))
        #expect(encoded.contains("\"fetchHtmlBodyValues\"") == false)
    }

    /// A plain `ids` argument keeps its plain key. The `#` prefix is what
    /// marks a back-reference, and using it on a literal value is a 400.
    @Test("a literal ids argument does not get the # prefix")
    func literalIDsKeepTheirKey() throws {
        var builder = RequestBuilder()
        builder.add(EmailGet(accountID: AccountID("7"), ids: .value([EmailID("1041")])))

        let encoded = try String(decoding: builder.encoded(), as: UTF8.self)

        #expect(encoded.contains("\"ids\":[\"1041\"]"))
        #expect(encoded.contains("\"#ids\"") == false)
    }

    /// The push URN is advertised in the Session but rejected in `using` with
    /// a hard 400 on *every* request. `using` is unioned from the methods
    /// actually added, so it can only ever name capabilities in play.
    @Test("`using` is unioned from the methods added, and never names push")
    func usingIsDerived() throws {
        var mailOnly = RequestBuilder()
        mailOnly.add(MailboxGet(accountID: AccountID("7")))

        #expect(
            mailOnly.makeRequest().using
                == ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]
        )

        // Identity/get is a submission method, so asking for it widens `using`
        // on its own — no call site has to remember.
        var withSubmission = RequestBuilder()
        withSubmission.add(MailboxGet(accountID: AccountID("7")))
        withSubmission.add(IdentityGet(accountID: AccountID("7")))

        #expect(
            withSubmission.makeRequest().using == [
                "urn:ietf:params:jmap:core",
                "urn:ietf:params:jmap:mail",
                "urn:ietf:params:jmap:submission",
            ]
        )
        #expect(
            withSubmission.makeRequest().using.contains(Capability.push.rawValue) == false
        )
    }

    /// `EmailQueryRunner` materialises every matching row in PHP before
    /// slicing, so a deep `position` costs the whole mailbox on someone's NAS —
    /// and `position` is unstable under concurrent insertion besides. Paging is
    /// by `before` instead, which means this must never drift.
    @Test("Email/query always pages from position 0")
    func queriesNeverOffsetPage() throws {
        let query = EmailQuery(accountID: AccountID("7"), limit: 50)

        #expect(query.arguments.position == 0)
    }

    @Test("the call limit comes from the session, not a constant")
    func callLimitIsFromSession() throws {
        let session = try Fixture.decode("session", as: Session.self)
        let builder = RequestBuilder(session: session)

        #expect(builder.maxCalls == 32)
        #expect(builder.hasRoom(for: 32))
        #expect(builder.hasRoom(for: 33) == false)
    }

    /// Nesting is where a filter builder usually goes wrong, and the server's
    /// `NOT` means "none of", not "not all of".
    @Test("nested filter operators encode as the compiler reads them")
    func nestedFilters() throws {
        var builder = RequestBuilder()
        builder.add(
            EmailQuery(
                accountID: AccountID("7"),
                filter: .and([
                    .inMailbox(MailboxID("13")),
                    .not([.hasKeyword(.seen)]),
                    .or([.from("acme"), .subject("invoice")]),
                ]),
                sort: nil
            )
        )

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self).contains(
                """
                "filter":{"conditions":[{"inMailbox":"13"},\
                {"conditions":[{"hasKeyword":"$seen"}],"operator":"NOT"},\
                {"conditions":[{"from":"acme"},{"subject":"invoice"}],"operator":"OR"}],\
                "operator":"AND"}
                """
            )
        )
    }

    /// The one write v1 makes. The patch path matters: `keywords/$seen` is a
    /// patch into the keywords map, not a replacement of it — sending the
    /// whole map would clear `$flagged` as a side effect.
    @Test("marking read encodes as a keyword patch, not a keyword replacement")
    func seenPatch() throws {
        var builder = RequestBuilder()
        builder.add(
            EmailSetKeywords(
                accountID: AccountID("7"),
                ids: [EmailID("1041")],
                isSeen: true
            )
        )

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self).contains(
                "\"update\":{\"1041\":{\"keywords/$seen\":true}}"
            )
        )
    }

    /// plMail's `Identity/set` rejects the whole update if it carries any
    /// property beyond `name` — `textSignature`, `replyTo` and `bcc` all come
    /// back as `invalidProperties` rather than being quietly dropped. So the
    /// patch has to contain exactly one key, and a rename that accidentally
    /// serialised a nil signature alongside it would fail every time.
    @Test("renaming an identity sends only the name")
    func identityRenameSendsOnlyName() throws {
        var builder = RequestBuilder()
        builder.add(
            IdentitySet.rename(IdentityID("4"), to: "Paul", accountID: AccountID("7")))

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self) == """
                {"methodCalls":[["Identity/set",{"accountId":"7",\
                "update":{"4":{"name":"Paul"}}},"c0"]],\
                "using":["urn:ietf:params:jmap:core","urn:ietf:params:jmap:submission"]}
                """
        )
    }
}
