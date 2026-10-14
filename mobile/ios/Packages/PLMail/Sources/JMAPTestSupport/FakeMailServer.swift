public import Foundation
public import JMAPKit
import Synchronization

/// A plMail server with a synthetic corpus, good enough to page against.
///
/// Not a stub that replays a canned response — it actually implements
/// `Email/query`'s `before` and `limit`, `Email/get`'s repository ordering and
/// `Thread/get`. That matters because the thing under test is a merge across
/// several paged sources, and every interesting failure it can have — a
/// duplicate at a page boundary, a row dropped where timestamps collide, a gap
/// when mail arrives mid-paging — only appears when paging behaves like paging.
///
/// It also reproduces two server behaviours a client will otherwise get wrong:
/// `Email/get` answers in id order rather than the order asked for, and one
/// account can fail while its siblings succeed.
public final class FakeMailServer: Sendable {
    public struct Message: Sendable, Hashable {
        public var id: String
        public var threadID: String
        public var subject: String
        public var from: String
        public var receivedAt: Date
        public var isSeen: Bool

        public init(
            id: String,
            threadID: String? = nil,
            subject: String = "Subject",
            from: String = "sender@example.test",
            receivedAt: Date,
            isSeen: Bool = false
        ) {
            self.id = id
            self.threadID = threadID ?? "t\(id)"
            self.subject = subject
            self.from = from
            self.receivedAt = receivedAt
            self.isSeen = isSeen
        }
    }

    /// A sendable address, as plMail models one: an address and a display
    /// name, and nothing else. There is deliberately no signature field —
    /// plMail's `Identity/set` refuses one, and a fake that accepted it would
    /// let a test pass against behaviour the real server does not have.
    public struct Identity: Sendable, Hashable {
        public var id: String
        public var name: String
        public var email: String
        /// The stand-in plMail invents for an account with no alias rows. It
        /// appears in `Identity/get` like any other, but its id is the
        /// *account's* id, so `Identity/set` looks it up among the aliases,
        /// misses, and answers `notFound`. Reproduced because it is the
        /// default state of a fresh account and a client has to survive it.
        public var isSynthetic: Bool

        public init(id: String, name: String = "", email: String, isSynthetic: Bool = false) {
            self.id = id
            self.name = name
            self.email = email
            self.isSynthetic = isSynthetic
        }
    }

    /// A custom label, as `Mailbox/set` creates one. System mailboxes are not
    /// modelled here: the fake's Inbox is a constant, exactly as immutable as
    /// the real server's.
    public struct CustomLabel: Sendable, Hashable {
        public var id: String
        public var labelID: String
        public var name: String
        public var parentID: String?
        public var isSubscribed: Bool

        public init(
            id: String, labelID: String, name: String, parentID: String? = nil,
            isSubscribed: Bool = true
        ) {
            self.id = id
            self.labelID = labelID
            self.name = name
            self.parentID = parentID
            self.isSubscribed = isSubscribed
        }
    }

    private struct State {
        var accounts: [String: [Message]] = [:]
        var identities: [String: [Identity]] = [:]
        var failing: Set<String> = []
        var refusesRenames = false
        var queryCount = 0
        /// Custom labels per account, in creation order.
        var labels: [String: [CustomLabel]] = [:]
        /// Makes `Mailbox/set` answer 200 with every bucket empty — neither
        /// done nor refused. Nothing in RFC 8621 promises a reason, so a
        /// client that reads "no refusal" as "success" reports a label
        /// created that does not exist.
        var silentMailboxSet = false
        /// Every `name` a create was asked for, exactly as it arrived. Kept
        /// raw so a test can tell the *client's* trimming from the server's.
        var receivedLabelNames: [String] = []
        /// Ids are per-account in plMail, but a single counter keeps them
        /// unique across the whole fake, which makes a test that muddles two
        /// accounts' ids fail rather than accidentally pass.
        var nextLabelID = 500
    }

    private let state = Mutex(State())
    private let mailboxID = "1"

    public init(accounts: [String: [Message]] = [:]) {
        state.withLock { $0.accounts = accounts }
    }

    // MARK: - Corpus control

    public func setMessages(_ messages: [Message], accountID: String) {
        state.withLock { $0.accounts[accountID] = messages }
    }

    /// Inserts mail *while* a merge is in progress, which is how the
    /// mid-paging insertion case is exercised.
    public func insert(_ message: Message, accountID: String) {
        state.withLock { $0.accounts[accountID, default: []].append(message) }
    }

    /// Makes one account fail every request, leaving the others healthy.
    public func setFailing(_ isFailing: Bool, accountID: String) {
        state.withLock {
            if isFailing {
                $0.failing.insert(accountID)
            } else {
                $0.failing.remove(accountID)
            }
        }
    }

    public func setIdentities(_ identities: [Identity], accountID: String) {
        state.withLock { $0.identities[accountID] = identities }
    }

    public func identities(accountID: String) -> [Identity] {
        state.withLock { $0.identities[accountID] ?? [] }
    }

    /// Makes `Identity/set` answer 200 with the rename in `notUpdated` — the
    /// shape a client is most likely to mistake for success.
    public func setRefusesRenames(_ refuses: Bool) {
        state.withLock { $0.refusesRenames = refuses }
    }

    public func setLabels(_ labels: [CustomLabel], accountID: String) {
        state.withLock { $0.labels[accountID] = labels }
    }

    public func labels(accountID: String) -> [CustomLabel] {
        state.withLock { $0.labels[accountID] ?? [] }
    }

    /// Makes `Mailbox/set` answer 200 with nothing created, updated, destroyed
    /// *or* refused — the shape a client is most likely to mistake for success.
    public func setSilentlyIgnoresMailboxSet(_ silent: Bool) {
        state.withLock { $0.silentMailboxSet = silent }
    }

    /// The `name` values creates arrived with, untrimmed.
    public var receivedLabelNames: [String] {
        state.withLock(\.receivedLabelNames)
    }

    public var queryCount: Int { state.withLock(\.queryCount) }

    public var accountIDs: [String] { state.withLock { $0.accounts.keys.sorted() } }

    // MARK: - Transport

    public func makeTransport() -> MockTransport {
        MockTransport { [self] request in
            let isDiscovery = request.url?.path.hasSuffix("/.well-known/jmap") == true
            let body =
                isDiscovery
                ? try sessionJSON()
                : try respond(to: request.httpBody ?? Data())

            return (body, MockTransport.response(for: request))
        }
    }

    public func makeClient(
        credential: Credential = .appPassword("plmail_" + String(repeating: "a", count: 64))
    ) -> JMAPClient {
        JMAPClient(
            discoveryURL: URL(string: "https://fake.test/.well-known/jmap")!,
            credential: credential,
            transport: makeTransport()
        )
    }

    // MARK: - Session

    private func sessionJSON() throws -> Data {
        let ids = accountIDs

        let accounts = ids.map { id in
            """
            "\(id)": {
              "name": "account-\(id)@example.test",
              "isPersonal": true,
              "isReadOnly": false,
              "accountCapabilities": { "urn:ietf:params:jmap:mail": {} }
            }
            """
        }

        return Data(
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
              "accounts": { \(accounts.joined(separator: ",")) },
              "primaryAccounts": { "urn:ietf:params:jmap:mail": "\(ids.first ?? "1")" },
              "username": "fake@example.test",
              "apiUrl": "https://fake.test/jmap/api",
              "downloadUrl": "https://fake.test/jmap/download/{accountId}/{blobId}/{name}",
              "uploadUrl": "https://fake.test/jmap/upload/{accountId}",
              "eventSourceUrl": "https://fake.test/jmap/eventsource",
              "state": "1"
            }
            """.utf8
        )
    }

    // MARK: - API

    private func respond(to body: Data) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let calls = request["methodCalls"] as? [[Any]]
        else {
            throw FakeError.badRequest
        }

        var responses: [[Any]] = []
        // Results of earlier calls in the same request, so back-references can
        // be resolved the way the real server resolves them.
        var byCallID: [String: [String: Any]] = [:]

        for call in calls {
            guard let name = call.first as? String,
                let arguments = call.count > 1 ? call[1] as? [String: Any] : nil,
                let callID = call.count > 2 ? call[2] as? String : nil
            else { continue }

            let accountID = arguments["accountId"] as? String ?? ""

            if state.withLock({ $0.failing.contains(accountID) }) {
                responses.append(["error", ["type": "serverUnavailable"], callID])
                continue
            }

            let result: [String: Any]

            switch name {
            case "Email/query": result = emailQuery(arguments, accountID: accountID)
            case "Email/get": result = emailGet(arguments, accountID: accountID, prior: byCallID)
            case "Thread/get": result = threadGet(arguments, accountID: accountID, prior: byCallID)
            case "Mailbox/get": result = mailboxGet(accountID: accountID)
            case "Mailbox/set": result = mailboxSet(arguments, accountID: accountID)
            case "Identity/get": result = identityGet(accountID: accountID)
            case "Identity/set": result = identitySet(arguments, accountID: accountID)
            default:
                responses.append(["error", ["type": "unknownMethod"], callID])
                continue
            }

            byCallID[callID] = result
            responses.append([name, result, callID])
        }

        return try JSONSerialization.data(
            withJSONObject: ["methodResponses": responses, "sessionState": "1"])
    }

    private func identityGet(accountID: String) -> [String: Any] {
        let list = identities(accountID: accountID).map { identity -> [String: Any] in
            [
                "id": identity.id,
                "name": identity.name,
                "email": identity.email,
                // Always empty, always present: that is what plMail answers,
                // and a client must not read it as "not supported".
                "textSignature": "",
                "htmlSignature": "",
                "mayDelete": false,
            ]
        }

        return ["accountId": accountID, "state": "1", "list": list, "notFound": []]
    }

    private func identitySet(_ arguments: [String: Any], accountID: String) -> [String: Any] {
        let update = arguments["update"] as? [String: Any] ?? [:]
        var updated: [String: Any] = [:]
        var notUpdated: [String: Any] = [:]

        for (id, patch) in update {
            let patch = patch as? [String: Any] ?? [:]

            // Exactly plMail's rule: anything but "name" is refused outright,
            // rather than accepted and dropped.
            let unsupported = patch.keys.filter { $0 != "name" }

            guard unsupported.isEmpty else {
                notUpdated[id] = [
                    "type": "invalidProperties",
                    "description": "plMail stores no signature, replyTo or bcc.",
                ]
                continue
            }

            guard state.withLock({ $0.refusesRenames }) == false else {
                notUpdated[id] = ["type": "forbidden", "description": "Refused."]
                continue
            }

            let isSynthetic = state.withLock {
                $0.identities[accountID]?.first { $0.id == id }?.isSynthetic ?? true
            }

            guard isSynthetic == false else {
                notUpdated[id] = [
                    "type": "notFound", "description": "No such Identity in this account.",
                ]
                continue
            }

            state.withLock {
                guard let index = $0.identities[accountID]?.firstIndex(where: { $0.id == id })
                else { return }

                $0.identities[accountID]?[index].name = patch["name"] as? String ?? ""
            }

            updated[id] = NSNull()
        }

        return [
            "accountId": accountID, "oldState": "1", "newState": "2",
            "updated": updated, "notUpdated": notUpdated,
        ]
    }

    private func emailQuery(_ arguments: [String: Any], accountID: String) -> [String: Any] {
        state.withLock { $0.queryCount += 1 }

        let before = boundDate(in: arguments["filter"])
        let limit = arguments["limit"] as? Int ?? 50

        var matching = messages(accountID)
            .sorted { $0.receivedAt > $1.receivedAt }

        if let before {
            // Strict `<`, exactly as the server compiles it. Getting this
            // wrong would hide the tie case the client's boundary tracking
            // exists to handle.
            matching = matching.filter { $0.receivedAt < before }
        }

        if excludesSeen(arguments["filter"]) {
            matching = matching.filter { $0.isSeen == false }
        }

        // Honoured rather than assumed: a query that wants every unread
        // *message* must not be handed one per thread, or a conversation with
        // two unread replies comes back half marked.
        if arguments["collapseThreads"] as? Bool ?? false {
            var seenThreads: Set<String> = []
            matching = matching.filter { seenThreads.insert($0.threadID).inserted }
        }

        let page = Array(matching.prefix(limit))

        return [
            "accountId": accountID,
            "queryState": "q1",
            "canCalculateChanges": false,
            "position": 0,
            "ids": page.map(\.id),
            "total": matching.count,
        ]
    }

    private func emailGet(
        _ arguments: [String: Any], accountID: String, prior: [String: [String: Any]]
    ) -> [String: Any] {
        let ids = resolveIDs(arguments, key: "ids", prior: prior)
        let wanted = Set(ids)

        // Repository order, not requested order — the real server does this,
        // and a client that forgets to re-order shows a list sorted by
        // database id.
        let found = messages(accountID)
            .filter { wanted.contains($0.id) }
            .sorted { $0.id < $1.id }

        return [
            "accountId": accountID,
            "state": "e1",
            "list": found.map { message in
                [
                    "id": message.id,
                    "threadId": message.threadID,
                    "subject": message.subject,
                    "from": [["name": message.from, "email": message.from]],
                    "receivedAt": Self.format(message.receivedAt),
                    "preview": "preview of \(message.subject)",
                    "keywords": message.isSeen ? ["$seen": true] : [:],
                    "hasAttachment": false,
                    "mailboxIds": [mailboxID: true],
                ] as [String: Any]
            },
            "notFound": ids.filter { id in found.contains { $0.id == id } == false },
        ]
    }

    private func threadGet(
        _ arguments: [String: Any], accountID: String, prior: [String: [String: Any]]
    ) -> [String: Any] {
        let ids = Set(resolveIDs(arguments, key: "ids", prior: prior))
        let all = messages(accountID)

        let threads = ids.sorted().map { threadID in
            [
                "id": threadID,
                "emailIds": all.filter { $0.threadID == threadID }.map(\.id).sorted(),
            ] as [String: Any]
        }

        return ["accountId": accountID, "state": "t1", "list": threads, "notFound": []]
    }

    private func mailboxGet(accountID: String) -> [String: Any] {
        let inbox =
            [
                "id": mailboxID,
                "labelId": "100",
                "name": "Inbox",
                "parentId": NSNull(),
                "role": "inbox",
                "sortOrder": 0,
                "totalEmails": messages(accountID).count,
                "unreadEmails": messages(accountID).filter { $0.isSeen == false }.count,
                "totalThreads": Set(messages(accountID).map(\.threadID)).count,
                "unreadThreads": 0,
                // A system mailbox, and the fake says so the way the real
                // server does: through myRights, not by leaving the client to
                // infer it from the role.
                "myRights": ["mayRename": false, "mayDelete": false],
                "isSubscribed": true,
            ] as [String: Any]

        let custom = labels(accountID: accountID).map { label in
            [
                "id": label.id,
                "labelId": label.labelID,
                "name": label.name,
                "parentId": label.parentID.map { $0 as Any } ?? NSNull(),
                "role": NSNull(),
                "sortOrder": 0,
                "totalEmails": 0,
                "unreadEmails": 0,
                "totalThreads": 0,
                "unreadThreads": 0,
                "myRights": ["mayRename": true, "mayDelete": true],
                "isSubscribed": label.isSubscribed,
            ] as [String: Any]
        }

        return [
            "accountId": accountID,
            "state": "m1",
            "list": [inbox] + custom,
            "notFound": [],
        ]
    }

    /// `Mailbox/set`, with plMail's rules rather than the spec's supersets: a
    /// fake that accepted a slash in a name, or a duplicate sibling, would let
    /// a test pass against behaviour the real server refuses.
    private func mailboxSet(_ arguments: [String: Any], accountID: String) -> [String: Any] {
        var created: [String: Any] = [:]
        var notCreated: [String: Any] = [:]
        var updated: [String: Any] = [:]
        var notUpdated: [String: Any] = [:]
        var destroyed: [String] = []
        var notDestroyed: [String: Any] = [:]

        state.withLock { state in
            for properties in (arguments["create"] as? [String: Any] ?? [:]).values {
                state.receivedLabelNames.append(
                    (properties as? [String: Any] ?? [:])["name"] as? String ?? "")
            }

            guard state.silentMailboxSet == false else { return }

            var labels = state.labels[accountID] ?? []

            func nameIsTaken(_ name: String, parentID: String?, ignoring: String?) -> Bool {
                labels.contains {
                    $0.name == name && $0.parentID == parentID && $0.id != ignoring
                }
            }

            for (creationID, properties) in arguments["create"] as? [String: Any] ?? [:] {
                let properties = properties as? [String: Any] ?? [:]
                let name = (properties["name"] as? String ?? "").trimmingCharacters(
                    in: .whitespaces)
                let parentID = properties["parentId"] as? String

                if name.isEmpty {
                    notCreated[creationID] = ["type": "invalidProperties"]
                    continue
                }

                if name.contains("/") {
                    notCreated[creationID] = ["type": "invalidProperties"]
                    continue
                }

                if nameIsTaken(name, parentID: parentID, ignoring: nil) {
                    notCreated[creationID] = ["type": "invalidProperties"]
                    continue
                }

                let id = String(state.nextLabelID)
                state.nextLabelID += 1

                let label = CustomLabel(
                    id: id,
                    labelID: "9" + id,
                    name: name,
                    parentID: parentID,
                    isSubscribed: properties["isSubscribed"] as? Bool ?? true
                )

                labels.append(label)

                created[creationID] = [
                    "id": id,
                    "labelId": label.labelID,
                    "role": NSNull(),
                    "sortOrder": 0,
                    "totalEmails": 0,
                    "unreadEmails": 0,
                    "totalThreads": 0,
                    "unreadThreads": 0,
                ]
            }

            for (id, patch) in arguments["update"] as? [String: Any] ?? [:] {
                let patch = patch as? [String: Any] ?? [:]

                // The Inbox is the fake's one system mailbox, and it refuses
                // exactly as the real server does.
                if id == mailboxID {
                    notUpdated[id] = ["type": "forbidden"]
                    continue
                }

                guard let index = labels.firstIndex(where: { $0.id == id }) else {
                    notUpdated[id] = ["type": "notFound"]
                    continue
                }

                var label = labels[index]
                var refusal: [String: Any]?

                for (property, value) in patch {
                    switch property {
                    case "name":
                        let name = (value as? String ?? "").trimmingCharacters(in: .whitespaces)

                        if name.isEmpty || name.contains("/")
                            || nameIsTaken(name, parentID: label.parentID, ignoring: label.id)
                        {
                            refusal = ["type": "invalidProperties"]
                        } else {
                            label.name = name
                        }

                    case "parentId":
                        label.parentID = value as? String

                    case "isSubscribed":
                        label.isSubscribed = value as? Bool ?? true

                    case "sortOrder":
                        break

                    default:
                        refusal = ["type": "invalidPatch"]
                    }
                }

                if let refusal {
                    notUpdated[id] = refusal
                    continue
                }

                labels[index] = label
                updated[id] = NSNull()
            }

            for id in arguments["destroy"] as? [String] ?? [] {
                if id == mailboxID {
                    notDestroyed[id] = ["type": "forbidden"]
                    continue
                }

                guard labels.contains(where: { $0.id == id }) else {
                    notDestroyed[id] = ["type": "notFound"]
                    continue
                }

                if labels.contains(where: { $0.parentID == id }) {
                    notDestroyed[id] = ["type": "mailboxHasChild"]
                    continue
                }

                labels.removeAll { $0.id == id }
                destroyed.append(id)
            }

            state.labels[accountID] = labels
        }

        return [
            "accountId": accountID,
            "oldState": "m1",
            "newState": "m2",
            "created": created,
            "notCreated": notCreated,
            "updated": updated,
            "notUpdated": notUpdated,
            "destroyed": destroyed,
            "notDestroyed": notDestroyed,
        ]
    }

    // MARK: - Helpers

    private func messages(_ accountID: String) -> [Message] {
        state.withLock { $0.accounts[accountID] ?? [] }
    }

    /// Resolves either a literal `ids` or a `#ids` back-reference, including
    /// the `/list/*/threadId` wildcard the client uses to chain Thread/get
    /// onto Email/get.
    private func resolveIDs(
        _ arguments: [String: Any], key: String, prior: [String: [String: Any]]
    ) -> [String] {
        if let literal = arguments[key] as? [String] { return literal }

        guard let reference = arguments["#\(key)"] as? [String: Any],
            let resultOf = reference["resultOf"] as? String,
            let path = reference["path"] as? String,
            let source = prior[resultOf]
        else { return [] }

        if path == "/ids" { return source["ids"] as? [String] ?? [] }

        if path.hasPrefix("/list/*/") {
            let property = String(path.dropFirst("/list/*/".count))
            let list = source["list"] as? [[String: Any]] ?? []

            return list.compactMap { $0[property] as? String }
        }

        return []
    }

    /// Whether the filter carries `notKeyword: $seen` anywhere inside it.
    private func excludesSeen(_ filter: Any?) -> Bool {
        guard let filter = filter as? [String: Any] else { return false }

        if filter["notKeyword"] as? String == "$seen" { return true }

        if let conditions = filter["conditions"] as? [[String: Any]] {
            return conditions.contains { excludesSeen($0) }
        }

        return false
    }

    private func boundDate(in filter: Any?) -> Date? {
        guard let filter = filter as? [String: Any] else { return nil }

        if let before = filter["before"] as? String { return Self.parse(before) }

        if let conditions = filter["conditions"] as? [[String: Any]] {
            for condition in conditions {
                if let found = boundDate(in: condition) { return found }
            }
        }

        return nil
    }

    private static let formatter = Date.ISO8601FormatStyle(timeZone: .gmt)

    public static func format(_ date: Date) -> String { date.formatted(formatter) }
    public static func parse(_ text: String) -> Date? { try? Date(text, strategy: formatter) }

    enum FakeError: Error { case badRequest }
}
