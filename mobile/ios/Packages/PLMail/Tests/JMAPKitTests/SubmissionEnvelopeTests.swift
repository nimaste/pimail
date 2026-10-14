import Foundation
import JMAPKit
import Testing

/// The wire shapes of sending, and the one that has been shipping wrong.
///
/// Every assertion here is about a byte the server reads. The server validates
/// an envelope by name and refuses unknown keys, and it refuses a draft patch
/// naming a property outside its allow-list — so a shape that looks right and
/// is wrong comes back as a whole call failing, hours after the composer closed.
@Suite("Submission envelope")
struct SubmissionEnvelopeTests {
    private func encode(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)

        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The submission this call would make, as JSON.
    private func submission(_ method: EmailSubmissionSet) throws -> [String: Any] {
        let arguments = try encode(method.arguments)
        let create = try #require(arguments["create"] as? [String: Any])

        return try #require(create[EmailSubmissionSet.creationID] as? [String: Any])
    }

    // MARK: - The draft patch

    /// **The regression this suite exists for.**
    ///
    /// `EmailUpdateDraft` copied `from` into its patch, and `from` is not in
    /// the server's `EmailPatchApplier::DRAFT_PROPERTIES`. An `Email/set update`
    /// naming it throws `invalidPatch`, which is caught per object into
    /// `notUpdated` — so **nothing** was applied, the body included. Editing a
    /// draft and sending it failed outright while looking to the user like it
    /// had worked.
    ///
    /// Asserted as a whole-set containment rather than as "not `from`", so the
    /// next property somebody reaches for is caught by the same test rather
    /// than needing a new one.
    @Test("A draft patch names only properties the server will accept")
    func draftPatchStaysInsideTheAllowList() throws {
        let update = DraftUpdate(
            accountID: AccountID("1"),
            emailID: EmailID("42"),
            content: DraftContent(
                to: [EmailAddress(email: "ada@example.org")],
                cc: [EmailAddress(email: "bob@example.org")],
                bcc: [EmailAddress(email: "secret@example.org")],
                subject: "Quarterly numbers",
                text: "Here they are.",
                html: "<div>Here they are.</div>",
                inReplyTo: ["<a@example.org>"],
                references: ["<a@example.org>"],
                attachments: .whole([
                    DraftAttachment(blobID: BlobID("p-9"), type: "application/pdf", name: "q3.pdf")
                ])
            )
        )

        let arguments = try encode(update.arguments)
        let patch = try #require(
            (arguments["update"] as? [String: Any])?["42"] as? [String: Any])
        let named = Set(patch.keys)

        #expect(named.contains("from") == false, "an update naming `from` applies nothing at all")
        #expect(named.isSubset(of: DraftUpdate.patchProperties))
    }

    /// A cleared address list has to reach the server as `null`, not as an
    /// omitted key: removing the last Cc would otherwise look like it worked
    /// and be back on the next device.
    @Test("Clearing every recipient sends null rather than saying nothing")
    func clearedRecipientsAreExplicit() throws {
        let update = DraftUpdate(
            accountID: AccountID("1"), emailID: EmailID("42"), content: DraftContent())
        let arguments = try encode(update.arguments)
        let patch = try #require(
            (arguments["update"] as? [String: Any])?["42"] as? [String: Any])

        #expect(patch["cc"] is NSNull)
        #expect(patch["bcc"] is NSNull)
    }

    /// `attachments` is a whole value and omitting it is how a save says "leave
    /// the files alone". Sending an empty array instead deletes them.
    @Test("An unchanged attachment set is not mentioned at all")
    func unchangedAttachmentsAreOmitted() throws {
        let update = DraftUpdate(
            accountID: AccountID("1"), emailID: EmailID("42"),
            content: DraftContent(subject: "Just the subject"))
        let arguments = try encode(update.arguments)
        let patch = try #require(
            (arguments["update"] as? [String: Any])?["42"] as? [String: Any])

        #expect(patch["attachments"] == nil)
    }

    // MARK: - The envelope

    /// Send now carries no envelope at all. An empty one would still be an
    /// object the server validates, and `mailFrom`/`rcptTo` are refused when
    /// they disagree with the Email — so the safest envelope is no envelope.
    @Test("An immediate send sends no envelope")
    func immediateSendHasNoEnvelope() throws {
        let set = EmailSubmissionSet(
            accountID: AccountID("1"), emailID: "42", identityID: IdentityID(rawValue: "3"))

        #expect(try submission(set)["envelope"] == nil)
    }

    /// A user-chosen time is an instant, so it goes as `HOLDUNTIL`. `HOLDFOR`
    /// is counted from when the request arrives, which on a phone whose clock
    /// runs fast promises a minute that has not happened.
    @Test("A scheduled send carries HOLDUNTIL as a UTC instant")
    func scheduledSendUsesHoldUntil() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let set = EmailSubmissionSet(
            accountID: AccountID("1"), emailID: "42", identityID: IdentityID(rawValue: "3"),
            hold: .until(when))

        let envelope = try #require(try submission(set)["envelope"] as? [String: Any])
        let mailFrom = try #require(envelope["mailFrom"] as? [String: Any])
        let parameters = try #require(mailFrom["parameters"] as? [String: Any])

        #expect(parameters["HOLDUNTIL"] as? String == "2027-01-15T08:00:00Z")
        #expect(parameters["HOLDFOR"] == nil, "the server refuses both together")

        // Nothing else. The server rejects unknown envelope keys by name, and
        // refuses a mailFrom or rcptTo that disagrees with the stored Email —
        // so describing them is a way to be told no, not a way to be precise.
        #expect(Set(envelope.keys) == ["mailFrom"])
        #expect(Set(mailFrom.keys) == ["parameters"])
    }

    /// The undo window is a duration, and means one: give me five seconds from
    /// when you get this.
    @Test("An undo window carries HOLDFOR as a string of seconds")
    func undoWindowUsesHoldFor() throws {
        let set = EmailSubmissionSet(
            accountID: AccountID("1"), emailID: "42", identityID: IdentityID(rawValue: "3"),
            hold: .seconds(5))

        let envelope = try #require(try submission(set)["envelope"] as? [String: Any])
        let parameters = try #require(
            (envelope["mailFrom"] as? [String: Any])?["parameters"] as? [String: Any])

        // A string, because ESMTP parameters are text — and the server's own
        // refusal message quotes it that way.
        #expect(parameters["HOLDFOR"] as? String == "5")
        #expect(parameters["HOLDUNTIL"] == nil)
    }

    /// A negative hold is not a thing to ask for, and asking would fail the
    /// whole submission rather than the envelope.
    @Test("A hold that has already elapsed is sent as zero, not as a negative")
    func negativeHoldIsClamped() throws {
        let set = EmailSubmissionSet(
            accountID: AccountID("1"), emailID: "42", identityID: IdentityID(rawValue: "3"),
            hold: .seconds(-30))

        let envelope = try #require(try submission(set)["envelope"] as? [String: Any])
        let parameters = try #require(
            (envelope["mailFrom"] as? [String: Any])?["parameters"] as? [String: Any])

        #expect(parameters["HOLDFOR"] as? String == "0")
    }

    // MARK: - Cancelling

    /// The only update the server accepts, and only to this one value.
    @Test("A cancel names undoStatus and nothing else")
    func cancelIsExactlyOneProperty() throws {
        let set = EmailSubmissionSet.cancel("42", accountID: AccountID("1"))
        let arguments = try encode(set.arguments)
        let update = try #require(arguments["update"] as? [String: Any])
        let patch = try #require(update["42"] as? [String: Any])

        #expect(Set(patch.keys) == ["undoStatus"])
        #expect(patch["undoStatus"] as? String == "canceled")
        #expect(arguments["create"] == nil, "a cancel must not also submit something")
    }

    /// An unrecognised status must not take the whole response down. A
    /// submission this build cannot classify still has to be visible.
    @Test("An unknown undoStatus decodes rather than failing")
    func unknownStatusDecodes() throws {
        let json = Data(
            """
            {"id": "42", "emailId": "42", "sendAt": "2027-01-15T08:00:00Z",
             "undoStatus": "somethingNew"}
            """.utf8)

        let submission = try JSONDecoder().decode(EmailSubmission.self, from: json)

        #expect(submission.undoStatus == .unknown)
        #expect(submission.sendAt?.date == Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Contacts

    /// The server rejects any argument it does not know by name, so a helpful
    /// extra — a filter, a position — fails the call rather than being ignored.
    @Test("Contact/autocomplete sends only the three arguments the server takes")
    func autocompleteSendsNothingExtra() throws {
        let method = ContactAutocomplete(accountID: AccountID("1"), query: "  ada ")
        let arguments = try encode(method.arguments)

        #expect(Set(arguments.keys) == ["accountId", "query", "limit"])
        #expect(arguments["query"] as? String == "ada", "trimmed before it reaches SQL")
        #expect(arguments["limit"] as? Int == ContactAutocomplete.defaultLimit)
    }

    /// Capped rather than sent, because the server caps rather than refuses —
    /// and a client that does not cap cannot tell a truncated list from a small
    /// address book.
    @Test("A limit past the server's ceiling is capped before it is sent")
    func autocompleteLimitIsCapped() throws {
        let method = ContactAutocomplete(accountID: AccountID("1"), query: "ada", limit: 500)

        #expect(try encode(method.arguments)["limit"] as? Int == ContactAutocomplete.maxLimit)
    }

    /// A suggestion drops straight into an `Email/set` create, so the address
    /// it produces has to be the shape the rest of the client speaks — and an
    /// empty name has to become no name, or it renders as `"" <a@b>`.
    @Test("A suggestion with no name becomes a bare address")
    func suggestionWithoutAName() throws {
        let json = Data(
            """
            [{"name": null, "email": "ada@example.org", "frequency": 12,
              "lastSeenAt": "2026-08-01T09:14:00Z", "isCorrespondent": true},
             {"name": "", "email": "bob@example.org"}]
            """.utf8)

        let list = try JSONDecoder().decode([ContactSuggestion].self, from: json)

        #expect(list[0].address.name == nil)
        #expect(list[0].frequency == 12)
        #expect(list[0].isCorrespondent == true)
        #expect(list[1].address.name == nil)
    }
}
