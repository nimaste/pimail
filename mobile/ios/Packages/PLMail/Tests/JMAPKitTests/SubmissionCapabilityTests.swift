import Foundation
import Testing

@testable import JMAPKit

/// The scheduling ceiling, read rather than guessed.
///
/// A send that names a time past the ceiling is refused, and discovering the
/// limit that way is correct and stays. What it cannot do is stop the date
/// picker *offering* a time the server is going to reject — which the user
/// then learns from a failed Outbox row an hour later rather than while
/// choosing.
@Suite("Submission account capabilities")
struct SubmissionCapabilityTests {
    private func session(_ submission: String) throws -> Session {
        let json = Data(
            """
            {
              "capabilities": {
                "urn:ietf:params:jmap:core": {
                  "maxSizeUpload": 50000000, "maxConcurrentUpload": 4,
                  "maxSizeRequestObject": 10000000, "maxConcurrentRequests": 4,
                  "maxCallsInRequest": 32, "maxObjectsInGet": 500,
                  "maxObjectsInSet": 500, "collationAlgorithms": []
                }
              },
              "accounts": {
                "1119": {
                  "name": "Work",
                  "isPersonal": true,
                  "isReadOnly": false,
                  "accountCapabilities": {
                    "urn:ietf:params:jmap:mail": {}\(submission)
                  }
                }
              },
              "primaryAccounts": { "urn:ietf:params:jmap:mail": "1119" },
              "username": "someone@example.test",
              "apiUrl": "https://fake.test/jmap/api",
              "downloadUrl": "https://fake.test/jmap/download/{accountId}/{blobId}/{name}",
              "uploadUrl": "https://fake.test/jmap/upload/{accountId}",
              "eventSourceUrl": "https://fake.test/jmap/eventsource",
              "state": "1"
            }
            """.utf8)

        return try JSONDecoder().decode(Session.self, from: json)
    }

    /// Exactly the shape `SessionBuilder::submissionCapabilities()` publishes.
    private static let published = """
        ,
        "urn:ietf:params:jmap:submission": {
          "maxDelayedSend": 2592000,
          "submissionExtensions": { "FUTURERELEASE": ["HOLDFOR", "HOLDUNTIL"] }
        }
        """

    @Test("The published ceiling and extensions are decoded")
    func decodesWhatTheServerPublishes() throws {
        let session = try session(Self.published)
        let submission = try #require(
            session.submissionCapabilities(for: AccountID(rawValue: "1119")))

        #expect(submission.maxDelayedSend == 2_592_000)
        #expect(submission.submissionExtensions?["FUTURERELEASE"] == ["HOLDFOR", "HOLDUNTIL"])
        #expect(submission.allowsDelayedSend)
    }

    /// 30 days, which is what the picker's upper bound has to be.
    @Test("The latest hold is the ceiling from now")
    func latestHoldIsNowPlusCeiling() throws {
        let session = try session(Self.published)
        let submission = try #require(
            session.submissionCapabilities(for: AccountID(rawValue: "1119")))
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(submission.latestHold(from: now) == now.addingTimeInterval(2_592_000))
    }

    /// Zero is the server saying "no delayed send", which is a different
    /// answer from an older server that published nothing.
    @Test("Zero means no delayed send, and absence means unknown")
    func zeroAndAbsenceDiffer() throws {
        let zero = try #require(
            try session(
                """
                ,
                "urn:ietf:params:jmap:submission": { "maxDelayedSend": 0 }
                """
            ).submissionCapabilities(for: AccountID(rawValue: "1119")))

        #expect(zero.allowsDelayedSend == false)
        #expect(zero.latestHold(from: .now) == nil)

        // An older server: the capability is not published at all.
        #expect(try session("").submissionCapabilities(for: AccountID(rawValue: "1119")) == nil)

        // And when the object is there without the key, scheduling is still
        // offered — the honest answer is to try and report what comes back.
        let empty = try #require(
            try session(
                """
                ,
                "urn:ietf:params:jmap:submission": {}
                """
            ).submissionCapabilities(for: AccountID(rawValue: "1119")))

        #expect(empty.allowsDelayedSend)
    }

    /// A Session carrying a capability this build has not heard of must still
    /// decode. A client that refuses one stops logging in after a server
    /// upgrade.
    @Test("An unknown submission extension is data, not a decoding failure")
    func unknownExtensionSurvives() throws {
        let session = try session(
            """
            ,
            "urn:ietf:params:jmap:submission": {
              "maxDelayedSend": 60,
              "submissionExtensions": { "DELIVERBY": ["BY"] }
            }
            """)
        let submission = try #require(
            session.submissionCapabilities(for: AccountID(rawValue: "1119")))

        #expect(submission.submissionExtensions?["DELIVERBY"] == ["BY"])
    }

    @Test("An unknown account has no ceiling rather than the wrong one")
    func unknownAccountHasNoCeiling() throws {
        #expect(
            try session(Self.published)
                .submissionCapabilities(for: AccountID(rawValue: "nope")) == nil)
    }
}
