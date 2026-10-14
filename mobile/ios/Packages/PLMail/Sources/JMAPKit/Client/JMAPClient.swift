import Foundation

/// Talks to one plMail server.
///
/// An actor rather than a global-actor-isolated type, so the sync engine (its
/// own actor) and the UI can both drive it without either being serialised
/// behind the other.
public actor JMAPClient {
    private let discoveryURL: URL
    private let credential: Credential
    private let transport: any JMAPTransport

    private var cachedSession: Session?
    private var sessionTask: Task<Session, any Error>?
    private var gate: RequestGate?

    public init(discoveryURL: URL, credential: Credential, transport: any JMAPTransport) {
        self.discoveryURL = discoveryURL
        self.credential = credential
        self.transport = transport
    }

    /// The Session object, fetched once and reused.
    ///
    /// Single-flighted: ten callers racing at launch — the sidebar, the feed,
    /// each account's syncer — cause one request, not ten. The in-flight task
    /// is what they share, so a failure propagates to all of them and the next
    /// caller retries rather than inheriting a cached error.
    public func session() async throws -> Session {
        if let cachedSession { return cachedSession }

        if let sessionTask { return try await sessionTask.value }

        let task = Task<Session, any Error> { [discoveryURL] in
            try await fetchSession(from: discoveryURL)
        }
        sessionTask = task

        defer { sessionTask = nil }

        let session = try await task.value
        cachedSession = session
        gate = RequestGate(session: session)

        return session
    }

    /// Discards the cached Session.
    ///
    /// Call on app foreground and after recovering from a 401 — the URLs in it
    /// are the server's to change, and a client that caches them across a
    /// reverse-proxy reconfiguration silently talks to the wrong place.
    public func invalidateSession() {
        cachedSession = nil
        sessionTask = nil
    }

    /// Sends one batch of method calls.
    public func send(_ builder: RequestBuilder) async throws -> MethodResults {
        guard builder.isEmpty == false else {
            throw JMAPError.malformedResponse("Refusing to send a request with no method calls.")
        }

        let session = try await session()
        let body = try builder.encoded()

        guard body.count <= session.capabilities.core.maxSizeRequestObject else {
            throw JMAPError.requestFailed(
                type: "requestTooLarge",
                detail: "Request body is \(body.count) bytes; this server accepts "
                    + "\(session.capabilities.core.maxSizeRequestObject)."
            )
        }

        var request = URLRequest(url: session.apiURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")

        let prepared = request
        let (data, response) = try await withPermit {
            try await self.transport.send(prepared)
        }

        return try MethodResults.decode(body: data, statusCode: response.statusCode)
    }

    /// Uploads bytes and gets back a blob id (RFC 8620 §6.1).
    ///
    /// Not a method call — a plain POST of the raw bytes to the session's
    /// `uploadUrl`, with the media type in `Content-Type`. There is no
    /// batching and no back-reference: a client uploads, then names the
    /// returned id in the `Email/set` that follows.
    ///
    /// Uploaded blobs are **scratch space**; plMail reclaims unreferenced ones
    /// on a timer. That is why compose uploads at send time rather than when a
    /// file is picked — a draft left open overnight would otherwise send with
    /// its attachments already collected.
    ///
    /// The ceiling comes from the live session rather than a constant, so a
    /// server configured for larger uploads is not second-guessed here.
    public func upload(
        _ data: Data, type: String, accountID: AccountID
    ) async throws -> UploadedBlob {
        let session = try await session()

        guard data.isEmpty == false else {
            throw JMAPError.requestFailed(
                type: "invalidArguments", detail: "Refusing to upload an empty file.")
        }

        guard data.count <= session.capabilities.core.maxSizeUpload else {
            throw JMAPError.requestFailed(
                type: "tooLarge",
                detail: "This file is \(data.count) bytes; this server accepts "
                    + "\(session.capabilities.core.maxSizeUpload)."
            )
        }

        guard let url = session.uploadURL.expanded(["accountId": accountID.rawValue]) else {
            throw JMAPError.malformedResponse("The session's uploadUrl is not a usable template.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")

        let prepared = request
        let (body, response) = try await withPermit {
            try await self.transport.send(prepared)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw JMAPError.unexpectedStatus(code: response.statusCode)
        }

        do {
            return try JSONDecoder().decode(UploadedBlob.self, from: body)
        } catch {
            throw JMAPError.malformedResponse("The upload response was not an upload object.")
        }
    }

    /// Runs `body` holding one concurrency permit.
    ///
    /// Before the first Session arrives there is no advertised limit to
    /// respect, and the only request in flight is the discovery one — so the
    /// permit is skipped rather than guessed at.
    public func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard let gate else { return try await body() }
        return try await gate.withPermit(body)
    }

    /// Holds a permit back for as long as a long-lived connection is open.
    /// See ``RequestGate/reserve()``.
    public func reservePermit() async -> RequestGate.Reservation? {
        await gate?.reserve()
    }

    // MARK: - Session discovery

    private func fetchSession(from url: URL) async throws -> Session {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.send(request)

        switch response.statusCode {
        case 200:
            break
        case 401:
            let problem = try? JSONDecoder().decode(ProblemDocument.self, from: data)
            throw JMAPError.notAuthenticated(detail: problem?.detail)
        default:
            throw JMAPError.unexpectedStatus(code: response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            throw JMAPError.malformedResponse(
                "\(url.absoluteString) did not return a JMAP session: \(error)"
            )
        }
    }
}

extension JMAPClient {
    /// Checks that an address and credential actually work, and reports what
    /// the server says it is.
    ///
    /// Used by onboarding to confirm before saving anything: the user sees
    /// their own address and their connected accounts and can tell at a glance
    /// whether this is the right server — which matters when the address they
    /// typed was `nas.local` and they have two of them.
    public func verify() async throws -> Session {
        invalidateSession()
        return try await session()
    }
}
