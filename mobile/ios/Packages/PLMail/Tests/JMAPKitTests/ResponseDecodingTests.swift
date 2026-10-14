import Foundation
import Testing

@testable import JMAPKit

@Suite("Response decoding")
struct ResponseDecodingTests {
    // MARK: - Session

    @Test("the session decodes, including the two-account case")
    func session() throws {
        let session = try Fixture.decode("session", as: Session.self)

        #expect(session.username == "me@example.com")
        #expect(session.apiURL.absoluteString == "https://nas.local/plmail/jmap/api")
        #expect(session.capabilities.core.maxCallsInRequest == 32)
        #expect(session.capabilities.core.maxConcurrentRequests == 4)
        #expect(session.capabilities.push?.isConfigured == true)

        // One JMAP account per connected mailbox, keyed by id. If the
        // dictionary key type were not CodingKeyRepresentable this would
        // decode as an array and the count would be wrong rather than the
        // decode failing.
        #expect(session.accounts.count == 2)
        #expect(session.accounts[AccountID("7")]?.name == "work@example.com")
        #expect(session.primaryMailAccountID == AccountID("7"))
    }

    /// Every other URL in the protocol is discovered from the session, and two
    /// of them are templates that are not valid URLs until filled in.
    @Test("download URLs expand, with path separators encoded")
    func downloadTemplate() throws {
        let session = try Fixture.decode("session", as: Session.self)

        let url = session.downloadURL.expanded([
            "accountId": "7",
            "blobId": "p-770",
            "name": "receipt 42.pdf",
            "type": "application/pdf",
        ])

        #expect(
            url?.absoluteString
                == "https://nas.local/plmail/jmap/download/7/p-770/receipt%2042.pdf?accept=application%2Fpdf"
        )
    }

    // MARK: - Email

    @Test("a fully populated Email decodes")
    func fullEmail() throws {
        let email = try emails(from: "email-get-full")[0]

        #expect(email.id == EmailID("1041"))
        #expect(email.blobID == BlobID("m-1041"))
        #expect(email.threadID == ThreadID("88"))
        #expect(email.subject == "Invoice 42 attached")
        #expect(email.from?.first?.displayName == "Acme Billing")
        #expect(email.to?.first?.email == "ops@example.test")
        #expect(email.mailboxIDs?.elements == [MailboxID("13"), MailboxID("14")])
        #expect(email.keywords?.elements == [.seen, .flagged])
        #expect(email.hasAttachment == true)
        #expect(email.htmlBodyValue == "<p>Please arrange a wire transfer.</p>")
        #expect(email.attachments?.count == 2)
    }

    /// Inline parts are referenced from the HTML by `cid:` and have no
    /// filename. They must be served into the renderer from a local cache —
    /// handing a web view the download URL does not work, because only
    /// `image/*` is served inline and `nosniff` is always set.
    @Test("inline parts are distinguishable from attachments")
    func inlineParts() throws {
        let attachments = try #require(emails(from: "email-get-full")[0].attachments)

        #expect(attachments[0].isInline == false)
        #expect(attachments[0].name == "receipt-42.pdf")
        #expect(attachments[1].isInline)
        #expect(attachments[1].cid == "logo@acme.test")
        #expect(attachments[1].name == nil)
    }

    /// `Email/get` honours a `properties` filter, so a partial object is the
    /// normal case. Only `id` is guaranteed.
    @Test("a sparse Email decodes without its absent properties")
    func sparseEmail() throws {
        let email = try emails(from: "email-get-sparse")[0]

        #expect(email.id == EmailID("1042"))
        #expect(email.subject == nil)
        #expect(email.blobID == nil)
        #expect(email.attachments == nil)
    }

    /// `{}` and `[]` are not interchangeable here: RFC 8621 requires the map
    /// form, and the server emits `new \stdClass()` precisely so an empty set
    /// does not encode as an array.
    @Test("empty maps decode to empty sets, and empty address lists are null")
    func emptyMapsAndNullAddresses() throws {
        let email = try emails(from: "email-get-sparse")[0]

        #expect(email.mailboxIDs?.isEmpty == true)
        #expect(email.keywords?.isEmpty == true)
        #expect(email.from == nil)
        #expect(email.to == nil)
    }

    /// A fifth keyword must not fail the decode — the alternative is one
    /// server-side addition breaking every installed copy of the app.
    @Test("an unknown keyword decodes rather than failing")
    func unknownKeyword() throws {
        let keywords = try #require(emails(from: "email-get-sparse")[1].keywords)

        #expect(keywords.contains(.seen))
        #expect(keywords.contains(.other("$muted")))
    }

    /// The server emits whole seconds today. Being strict about that would
    /// mean a future server release breaks every shipped client.
    @Test("dates decode with and without fractional seconds")
    func dateTolerance() throws {
        let withFraction = try emails(from: "email-get-sparse")[0].receivedAt
        let withoutFraction = try emails(from: "email-get-full")[0].receivedAt

        #expect(withFraction != nil)
        #expect(withoutFraction != nil)
        // 2026-07-15T10:00:00Z
        #expect(withoutFraction?.date == Date(timeIntervalSince1970: 1_784_109_600))
    }

    @Test("UTCDate round-trips through the server's own spelling")
    func dateRoundTrip() throws {
        let original = UTCDate(Date(timeIntervalSince1970: 1_784_109_600))
        let encoded = try JSONEncoder().encode(original)

        #expect(String(decoding: encoded, as: UTF8.self) == "\"2026-07-15T10:00:00Z\"")
        #expect(try JSONDecoder().decode(UTCDate.self, from: encoded) == original)
    }

    // MARK: - Mailbox

    @Test("Mailbox decodes both id spaces without conflating them")
    func mailboxIDSpaces() throws {
        let results = try results(from: "batch-with-inline-error")
        let handle = CallHandle<MailboxGet>(callID: CallID(rawValue: "c2"))
        let mailboxes = try results.result(of: handle).list

        #expect(mailboxes[0].id == MailboxID("13"))
        #expect(mailboxes[0].labelID == LabelID("4"))
        #expect(mailboxes[0].role == .inbox)
        #expect(mailboxes[0].myRights?.mayDelete == false)

        // A custom label is fully mutable, and its parent is expressed as a
        // binding id — never a label id.
        #expect(mailboxes[1].role == nil)
        #expect(mailboxes[1].parentID == MailboxID("16"))
        #expect(mailboxes[1].myRights?.mayDelete == true)
    }

    @Test("system mailboxes carry the web UI's sidebar order")
    func sidebarOrder() {
        #expect(MailboxRole.inbox.sidebarOrder < MailboxRole.sent.sidebarOrder)
        #expect(MailboxRole.trash.sidebarOrder < MailboxRole.archive.sidebarOrder)
        #expect(MailboxRole.other("whatever").sidebarOrder > MailboxRole.archive.sidebarOrder)
    }

    // MARK: - Errors

    /// A method error arrives **inside a 200**, alongside results that
    /// succeeded. Failing the whole batch would throw away good data — and for
    /// a multi-account request, one bad account would blank the unified inbox.
    @Test("one failing call in a batch does not lose its siblings")
    func inlineErrorIsIsolated() throws {
        let results = try results(from: "batch-with-inline-error")

        let query = CallHandle<EmailQuery>(callID: CallID(rawValue: "c0"))
        let broken = CallHandle<EmailGet>(callID: CallID(rawValue: "c1"))
        let mailboxes = CallHandle<MailboxGet>(callID: CallID(rawValue: "c2"))

        #expect(try results.result(of: query).ids == [EmailID("1041"), EmailID("1042")])
        #expect(try results.result(of: mailboxes).list.count == 2)

        #expect(throws: JMAPError.self) { try results.result(of: broken) }
        #expect(results.failure(of: query) == nil)

        guard
            case .methodFailed(let type, let description, let callID) = results.failure(of: broken)
        else {
            Issue.record("expected a method error")
            return
        }

        #expect(type == .unsupportedFilter)
        #expect(callID == CallID(rawValue: "c1"))
        #expect(description?.contains("snoozed") == true)
    }

    /// `unsupportedFilter` can only be caused by this client building a bad
    /// query, so it is worth an assertion in debug — and must never reach a
    /// user as a raw JMAP error type.
    @Test("errors are classified by what the caller should do")
    func errorClassification() {
        let auth = JMAPError.notAuthenticated(detail: "Invalid or revoked app password.")
        #expect(auth.isRetryable == false)

        let filter = JMAPError.methodFailed(
            .unsupportedFilter, description: nil, callID: CallID(rawValue: "c1"))
        #expect(filter.isProgrammerError)
        #expect(filter.isRetryable == false)

        let stale = JMAPError.methodFailed(
            .cannotCalculateChanges, description: nil, callID: CallID(rawValue: "c0"))
        #expect(stale.requiresResync)
        #expect(stale.isProgrammerError == false)

        #expect(JMAPError.unreachable(host: "nas.local", code: .timedOut).isRetryable)
    }

    /// A 401 is `application/problem+json` with no `methodResponses` at all —
    /// a different shape from a method error, and it has to be recognised
    /// before anything tries to read results.
    @Test("a 401 problem document becomes a re-auth signal")
    func unauthorized() throws {
        let body = try Fixture.data("problem-401")

        #expect(throws: JMAPError.notAuthenticated(detail: "Invalid or revoked app password.")) {
            try MethodResults.decode(body: body, statusCode: 401)
        }
    }

    // MARK: - Changes

    /// `/changes` caps at 256 rows, so the flag is the loop condition. Reading
    /// `newState` and stopping would silently lose every change past the first
    /// page.
    @Test("changes carry the resume cursor and the more-to-come flag")
    func changes() throws {
        let results = try results(from: "email-changes-hasmore")
        let handle = CallHandle<EmailChanges>(callID: CallID(rawValue: "c0"))
        let changes = try results.result(of: handle)

        #expect(changes.oldState == StateToken.initial)
        #expect(changes.newState == StateToken(rawValue: "256"))
        #expect(changes.hasMoreChanges)
        #expect(changes.created == [EmailID("1041"), EmailID("1042")])
        #expect(changes.destroyed.isEmpty)
    }

    /// plMail's change log uses one sequence shared across every
    /// (account, type), so a type's first row can sit at any number and `"0"`
    /// must always be answerable — otherwise every freshly-connected client is
    /// told to resync.
    @Test("the initial cursor is the string zero")
    func initialCursor() {
        #expect(StateToken.initial.rawValue == "0")
    }

    // MARK: - Helpers

    private func results(from fixture: String) throws -> MethodResults {
        try MethodResults.decode(body: Fixture.data(fixture), statusCode: 200)
    }

    private func emails(from fixture: String) throws -> [Email] {
        let handle = CallHandle<EmailGet>(callID: CallID(rawValue: "c1"))
        return try results(from: fixture).result(of: handle).list
    }
}
