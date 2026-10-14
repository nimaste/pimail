import Foundation
import JMAPKit
import JMAPTestSupport
import Testing

@testable import PLMailCore

/// Writing an event: what is sent, what comes back, and — the part that matters
/// most — what the cache looks like when the answer is no.
///
/// There is no `ifInState`, no queue, no retry and no undo on this surface. A
/// write either landed or never happened, and the second case has to be
/// indistinguishable from not having pressed the button.
@Suite("Calendar writes")
struct CalendarWriteTests {
    private let accountKey = "nas.local/7"
    private let account = AccountID("7")
    private let seriesID = CalendarEventID("41")

    // MARK: - Harness

    private func store() -> CalendarStore {
        CalendarStore(modelContainer: MailStack.makeContainer(inMemory: true))
    }

    private static let session = """
        {
          "capabilities": {
            "urn:ietf:params:jmap:core": {
              "maxSizeUpload": 50000000, "maxConcurrentUpload": 4,
              "maxSizeRequestObject": 10000000, "maxConcurrentRequests": 4,
              "maxCallsInRequest": 32, "maxObjectsInGet": 500,
              "maxObjectsInSet": 500, "collationAlgorithms": []
            },
            "urn:plmail:params:jmap:calendars": {}
          },
          "accounts": {
            "7": {
              "name": "me@example.test", "isPersonal": true, "isReadOnly": false,
              "accountCapabilities": {
                "urn:ietf:params:jmap:mail": {},
                "urn:plmail:params:jmap:calendars": {}
              }
            }
          },
          "primaryAccounts": { "urn:ietf:params:jmap:mail": "7" },
          "username": "me@example.test",
          "apiUrl": "https://nas.local/jmap/api",
          "downloadUrl": "https://nas.local/d/{accountId}/{blobId}/{name}",
          "uploadUrl": "https://nas.local/u/{accountId}",
          "eventSourceUrl": "https://nas.local/es",
          "state": "1"
        }
        """

    /// Answers the session with a calendar account, and every API call with
    /// `answer`.
    private func transport(answering answer: String) -> MockTransport {
        MockTransport { request in
            let isDiscovery = request.url?.path().contains(".well-known") == true
            let body = isDiscovery ? Self.session : answer

            return (Data(body.utf8), MockTransport.response(for: request))
        }
    }

    private func client(_ transport: MockTransport) throws -> JMAPClient {
        JMAPClient(
            discoveryURL: try #require(URL(string: "https://nas.local/.well-known/jmap")),
            credential: .appPassword("plmail_" + String(repeating: "a", count: 64)),
            transport: transport
        )
    }

    /// One `CalendarEvent/set` response, wrapped in a JMAP envelope.
    private func response(_ arguments: String) -> String {
        """
        {"methodResponses":[["CalendarEvent/set",\(arguments),"c0"]],"sessionState":"1"}
        """
    }

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private var window: CalendarWindow {
        get throws {
            try #require(
                CalendarWindow(
                    from: CalendarDay(year: 2026, month: 8, day: 1),
                    to: CalendarDay(year: 2026, month: 9, day: 1)))
        }
    }

    /// A cached series with one occurrence, which is what an editor is opened
    /// on.
    private func seed(_ store: CalendarStore, recurring: Bool = false) async throws {
        let calendars: [JMAPCalendar] = try decode(
            """
            [{"id":"3","name":"Work","timeZone":"Europe/Berlin",
              "myRights":{"mayReadItems":true,"mayAddItems":true,"mayUpdateAll":true,
                          "mayRemoveItems":true,"mayDelete":false}}]
            """)
        try await store.replaceCalendars(calendars, accountKey: accountKey)

        let series: [CalendarEvent] = try decode(
            """
            [{"id":"41","uid":"abc@plmail","calendarId":"3","title":"Standup",
              "start":"2026-08-03T09:00:00","duration":"PT15M","timeZone":"Europe/Berlin",
              "showWithoutTime":false,"description":"Bring numbers",
              "locations":{"1":{"@type":"Location","name":"Kitchen"}},
              "status":"confirmed","isRecurring":\(recurring),"sequence":0,
              "created":"2026-07-01T08:00:00Z","updated":"2026-07-02T08:00:00Z"}]
            """)
        try await store.upsertSeries(series, accountKey: accountKey)

        let occurrences: [CalendarEvent] = try decode(
            """
            [{"id":"41_2026-08-03T09:00:00","seriesId":"41","calendarId":"3",
              "recurrenceId":"2026-08-03T09:00:00","recurrenceIdTimeZone":"Europe/Berlin",
              "start":"2026-08-03T09:00:00","duration":"PT15M","timeZone":"Europe/Berlin",
              "showWithoutTime":false,"title":"Standup","status":"confirmed"}]
            """)
        try await store.replaceOccurrences(
            occurrences,
            in: try window,
            accountKey: accountKey,
            zone: .gmt,
            calendarZones: ["3": "Europe/Berlin"]
        )
    }

    /// Everything about the series and its occurrences, as the cache holds it.
    /// Compared whole rather than field by field, because a rollback that put
    /// *most* of it back is the failure this is looking for.
    private func cacheState(_ store: CalendarStore) async throws -> CalendarWriteRollback {
        try await store.captureRollback(for: seriesID, accountKey: accountKey)
    }

    private var draft: EventDraft {
        get throws {
            EventDraft(
                calendarID: CalendarID("3"),
                title: "Standup (moved)",
                start: try #require(LocalDateTime(rawValue: "2026-08-04T11:00:00")),
                duration: EventDuration(minutes: 30),
                location: "Roof",
                notes: nil
            )
        }
    }

    // MARK: - Creating

    /// **Server-first**, because the id is the whole point: there is nothing to
    /// draw until the server mints one, and a placeholder row would have to be
    /// reconciled on a surface with no change feed to reconcile against.
    @Test("a create returns the id the server minted, and writes nothing before it")
    func createIsServerFirst() async throws {
        let store = store()
        let transport = transport(
            answering: response(
                """
                {"accountId":"7","oldState":"fixed","newState":"fixed",
                 "created":{"new1":{"id":"97","uid":"new@plmail","calendarId":"3",
                                    "isRecurring":false,"sequence":0}},
                 "notCreated":{},"updated":{},"notUpdated":{},
                 "destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.create(
            try draft, accountID: account, accountKey: accountKey)

        #expect(outcome == .saved(CalendarEventID("97")))
        // Nothing was invented locally; the window's next query is what draws
        // the new event.
        #expect(try await store.series(id: CalendarEventID("97"), accountKey: accountKey) == nil)
    }

    @Test("a refused create is reported in the server's own words and names the properties")
    func refusedCreateNamesProperties() async throws {
        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},
                 "notCreated":{"new1":{"type":"invalidProperties",
                                       "properties":["participants","alerts"]}},
                 "updated":{},"notUpdated":{},"destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store())

        let outcome = await writer.create(
            try draft, accountID: account, accountKey: accountKey)

        #expect(outcome == .refused(reason: "participants, alerts", isForbidden: false))
        #expect(outcome.didWrite == false)
    }

    /// `forbidden` means the calendar mirrors somewhere that does not accept
    /// writes. Read from the error **type**, never guessed from `myRights` —
    /// rights grey a control out in advance, and this is what happened.
    @Test("a create on a read-only calendar is reported as forbidden")
    func forbiddenCreate() async throws {
        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},
                 "notCreated":{"new1":{"type":"forbidden",
                                       "description":"This calendar is read-only."}},
                 "updated":{},"notUpdated":{},"destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store())

        let outcome = await writer.create(
            try draft, accountID: account, accountKey: accountKey)

        #expect(outcome == .refused(reason: "This calendar is read-only.", isForbidden: true))
    }

    // MARK: - Updating

    @Test("an accepted update lands in the cache immediately")
    func acceptedUpdateApplies() async throws {
        let store = store()
        try await seed(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{"41":null},"notUpdated":{},"destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.update(
            seriesID, to: try draft, accountID: account, accountKey: accountKey)

        #expect(outcome == .saved(seriesID))

        let series = try #require(try await store.series(id: seriesID, accountKey: accountKey))

        #expect(series.title == "Standup (moved)")
        #expect(series.startLocal == "2026-08-04T11:00:00")
        #expect(series.duration == "PT30M")
        #expect(series.locationName == "Roof")

        // A non-recurring series' one occurrence moves with it, so the grid
        // does not draw the old time until the refresh lands.
        let occurrences = try await store.occurrences(in: try window, accountKey: accountKey)

        #expect(occurrences.first?.title == "Standup (moved)")
        #expect(occurrences.first?.startLocal == "2026-08-04T11:00:00")
    }

    /// **The graded rule.** A refusal that left half an optimistic edit in the
    /// cache would look, on the next refresh, exactly like somebody else's
    /// change — on a surface with no change feed to disprove it.
    @Test("a refused update leaves the cache exactly as it was")
    func refusedUpdateRollsBack() async throws {
        let store = store()
        try await seed(store)
        let before = try await cacheState(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{},
                 "notUpdated":{"41":{"type":"invalidProperties","properties":["start"],
                                     "description":"start must be Y-m-d\\\\TH:i:s"}},
                 "destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.update(
            seriesID, to: try draft, accountID: account, accountKey: accountKey)

        guard case .refused(_, let isForbidden) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")

            return
        }

        #expect(isForbidden == false)
        #expect(try await cacheState(store) == before)
    }

    /// A transport failure is not an answer, so it names the host — and it
    /// rolls back exactly as a refusal does, because in both cases the write
    /// never happened.
    @Test("an unreachable server names the host and rolls the change back")
    func unreachableRollsBack() async throws {
        let store = store()
        try await seed(store)
        let before = try await cacheState(store)

        let transport = MockTransport { request in
            let isDiscovery = request.url?.path().contains(".well-known") == true

            guard isDiscovery == false else {
                return (Data(Self.session.utf8), MockTransport.response(for: request))
            }

            // What `URLSessionTransport` throws: the transport is what names
            // the host, because a `URLError` alone does not carry one.
            throw JMAPError.unreachable(host: "nas.local", code: .cannotConnectToHost)
        }
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.update(
            seriesID, to: try draft, accountID: account, accountKey: accountKey)

        #expect(outcome == .unreachable(host: "nas.local"))
        #expect(try await cacheState(store) == before)
    }

    /// The occurrences of a recurring series are the server's to compute. This
    /// client may not expand a rule, so where a moved start lands for every
    /// other instance is a question only the refresh can answer.
    @Test("an update to a recurring series does not move its occurrences locally")
    func recurringOccurrencesAreLeftToTheServer() async throws {
        let store = store()
        try await seed(store, recurring: true)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{"41":null},"notUpdated":{},"destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        _ = await writer.update(
            seriesID, to: try draft, accountID: account, accountKey: accountKey)

        let occurrences = try await store.occurrences(in: try window, accountKey: accountKey)

        // The title is the series', so it is safe to show at once. The time is
        // not.
        #expect(occurrences.first?.title == "Standup (moved)")
        #expect(occurrences.first?.startLocal == "2026-08-03T09:00:00")
    }

    // MARK: - Deleting

    /// **The whole series, and there is no bin.** Unlike `Email/set`, where
    /// destroy means Trash.
    @Test("an accepted delete removes the series and every occurrence of it")
    func acceptedDeleteRemovesEverything() async throws {
        let store = store()
        try await seed(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{},"notUpdated":{},"destroyed":["41"],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.delete(
            seriesID, accountID: account, accountKey: accountKey)

        #expect(outcome == .deleted)
        #expect(try await store.series(id: seriesID, accountKey: accountKey) == nil)
        #expect(try await store.occurrences(in: try window, accountKey: accountKey).isEmpty)
    }

    @Test("a refused delete puts the series and its occurrences back exactly")
    func refusedDeleteRollsBack() async throws {
        let store = store()
        try await seed(store)
        let before = try await cacheState(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{},"notUpdated":{},"destroyed":[],
                 "notDestroyed":{"41":{"type":"forbidden",
                                       "description":"This calendar is read-only."}}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.delete(
            seriesID, accountID: account, accountKey: accountKey)

        #expect(outcome == .refused(reason: "This calendar is read-only.", isForbidden: true))
        #expect(try await cacheState(store) == before)

        // And it is genuinely drawable again, not merely present as columns.
        let occurrences = try await store.occurrences(in: try window, accountKey: accountKey)

        #expect(occurrences.count == 1)
        #expect(occurrences.first?.title == "Standup")
    }

    /// A `/set` that neither destroyed nor refused is a contract the client
    /// cannot act on. Reporting success would leave somebody looking for an
    /// event that is still there.
    @Test("a silent set answer is treated as a refusal, not as a success")
    func silentAnswerIsARefusal() async throws {
        let store = store()
        try await seed(store)
        let before = try await cacheState(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{},"notUpdated":{},"destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        let outcome = await writer.delete(
            seriesID, accountID: account, accountKey: accountKey)

        #expect(outcome.didWrite == false)
        #expect(try await cacheState(store) == before)
    }

    // MARK: - What is sent

    @Test("an update sends a patch keyed by the series id, with no ifInState")
    func updateRequestShape() async throws {
        let store = store()
        try await seed(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{"41":null},"notUpdated":{},"destroyed":[],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        _ = await writer.update(
            seriesID, to: try draft, accountID: account, accountKey: accountKey)

        let sent = try #require(
            transport.recorded.compactMap { recorded -> [String: Any]? in
                guard let body = recorded.body,
                    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let calls = json["methodCalls"] as? [[Any]],
                    let call = calls.first,
                    call.first as? String == "CalendarEvent/set",
                    let arguments = call.dropFirst().first as? [String: Any]
                else { return nil }

                return arguments
            }.first)

        // **A guard that cannot fail is worse than no guard**: the state is the
        // literal "fixed", and the server refuses an `ifInState` outright.
        #expect(sent.keys.contains("ifInState") == false)

        let update = try #require(sent["update"] as? [String: Any])
        let patch = try #require(update["41"] as? [String: Any])

        #expect(patch["title"] as? String == "Standup (moved)")
        #expect(patch["start"] as? String == "2026-08-04T11:00:00")
        #expect(patch.keys.contains("recurrenceRules") == false)
        #expect(patch.keys.contains("uid") == false)
        #expect(patch.keys.contains("timeZone") == false)
        // A key with a `/` in it is a JSON-pointer path, refused with
        // `invalidPatch`.
        #expect(patch.keys.allSatisfy { $0.contains("/") == false })
    }

    @Test("a delete sends the series id and nothing else")
    func deleteRequestShape() async throws {
        let store = store()
        try await seed(store)

        let transport = transport(
            answering: response(
                """
                {"accountId":"7","newState":"fixed","created":{},"notCreated":{},
                 "updated":{},"notUpdated":{},"destroyed":["41"],"notDestroyed":{}}
                """))
        let writer = CalendarWriter(client: try client(transport), store: store)

        _ = await writer.delete(seriesID, accountID: account, accountKey: accountKey)

        let body = try #require(transport.recorded.last?.body)
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(text.contains(#""destroy":["41"]"#))
        #expect(text.contains("ifInState") == false)
    }
}

/// The outcome type itself, which is what every screen branches on.
@Suite("Calendar write outcomes")
struct CalendarWriteOutcomeTests {
    @Test("a transport failure names the host and a method failure carries its words")
    func errorMapping() {
        #expect(
            CalendarWriteOutcome.from(
                JMAPError.unreachable(host: "nas.local", code: .cannotConnectToHost))
                == .unreachable(host: "nas.local"))

        #expect(
            CalendarWriteOutcome.from(
                JMAPError.methodFailed(
                    .forbidden, description: "read-only", callID: CallID(rawValue: "c0")))
                == .refused(reason: "read-only", isForbidden: true))
    }

    /// "invalidProperties" tells a user nothing; the list is the only part of
    /// the answer that says what to change.
    @Test("a refusal with no description falls back to the properties it named")
    func refusalWordsFallBackToProperties() throws {
        let error: CalendarSetError = try JSONDecoder().decode(
            CalendarSetError.self,
            from: Data(#"{"type":"invalidProperties","properties":["title"]}"#.utf8))

        #expect(CalendarWriteOutcome.from(error) == .refused(reason: "title", isForbidden: false))
    }

    @Test("only saved and deleted count as having written anything")
    func didWrite() {
        #expect(CalendarWriteOutcome.saved(CalendarEventID("1")).didWrite)
        #expect(CalendarWriteOutcome.deleted.didWrite)
        #expect(CalendarWriteOutcome.refused(reason: "no", isForbidden: false).didWrite == false)
        #expect(CalendarWriteOutcome.unreachable(host: "nas.local").didWrite == false)
        #expect(CalendarWriteOutcome.noCalendar.didWrite == false)
    }
}
