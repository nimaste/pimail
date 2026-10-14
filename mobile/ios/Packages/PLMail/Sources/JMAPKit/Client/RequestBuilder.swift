import Foundation

/// A typed handle on one call in a request. Hand it back to
/// ``MethodResults/result(of:)`` to get that call's decoded result, or ask it
/// for a ``ResultReference`` to feed a later call in the same request.
public struct CallHandle<Method: JMAPMethod>: Sendable {
    public let callID: CallID

    /// Makes a back-reference into this call's result, for a later call in the
    /// same request.
    ///
    /// - Parameter path: A restricted JSON Pointer, e.g. `"/ids"`.
    /// - Returns: A reference the receiving argument encodes under a `#`-prefixed key.
    public func reference(path: String) -> ResultReference {
        ResultReference(resultOf: callID, name: Method.name, path: path)
    }
}

/// Assembles one `POST /jmap/api` body.
///
/// Three things it takes care of so no call site has to: assigning call ids,
/// unioning `using` from the methods actually added, and refusing to build a
/// request with more calls than the server accepts.
public struct RequestBuilder: Sendable {
    /// RFC 8620's floor for `maxCallsInRequest`, used only when no Session has
    /// been seen yet. The real ceiling comes from the Session and is higher.
    public static let conservativeCallLimit = 16

    private var invocations: [Invocation] = []
    /// Core is always declared, even when no `Core/*` method is in the batch.
    /// RFC 8620 defines the request envelope itself under this capability, and
    /// it is what the server's own documentation shows clients sending.
    private var capabilities: Set<Capability> = [.core]
    private var nextIndex = 0

    /// The ceiling on calls, read from the live Session rather than hardcoded.
    public var maxCalls: Int

    public init(maxCalls: Int = RequestBuilder.conservativeCallLimit) {
        self.maxCalls = maxCalls
    }

    public init(session: Session) {
        maxCalls = session.capabilities.core.maxCallsInRequest
    }

    public var callCount: Int { invocations.count }
    public var isEmpty: Bool { invocations.isEmpty }

    /// Whether another `count` calls would still fit. Callers batching across
    /// accounts use this to decide where to split.
    public func hasRoom(for count: Int = 1) -> Bool {
        invocations.count + count <= maxCalls
    }

    @discardableResult
    public mutating func add<Method: JMAPMethod>(_ method: Method) -> CallHandle<Method> {
        precondition(
            hasRoom(),
            """
            Request would carry \(invocations.count + 1) calls, over this \
            server's limit of \(maxCalls). Split the batch — check hasRoom(for:) \
            before adding.
            """
        )

        // `push` and `apns` are advertised in the Session and rejected in
        // `using`: an unknown capability refuses the *whole* request with
        // `unknownCapability`, so one wrong declaration takes every unrelated
        // call in the batch with it and the message names none of them. This
        // caught `PushSubscriptionSet` declaring `apns` — a Core method — and
        // is left in place as the guard that no future method repeats it.
        precondition(
            Method.capability.isSupportedInUsing,
            "\(Method.name) declares \(Method.capability.rawValue), which cannot appear in `using`."
        )

        let callID = CallID(rawValue: "c\(nextIndex)")
        nextIndex += 1

        invocations.append(
            Invocation(name: Method.name, arguments: method.arguments, callID: callID))
        capabilities.insert(Method.capability)

        return CallHandle(callID: callID)
    }

    /// The encodable request body.
    public func makeRequest() -> JMAPRequest {
        JMAPRequest(
            // Sorted for a deterministic body — otherwise the encoded request
            // would depend on Set iteration order and could not be asserted on.
            using: capabilities.map(\.rawValue).sorted(),
            methodCalls: invocations
        )
    }

    public func encoded(with encoder: JSONEncoder = JMAPRequest.encoder) throws -> Data {
        try encoder.encode(makeRequest())
    }
}

/// The body of a `POST` to the Session's `apiUrl`.
public struct JMAPRequest: Encodable, Sendable {
    public var using: [String]
    var methodCalls: [Invocation]

    /// Sorted keys so an encoded request is byte-stable and can be asserted
    /// on; unescaped slashes because `Email\/query` is valid JSON but makes
    /// every logged request harder to read than it needs to be. Both cost
    /// nothing at these sizes.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
