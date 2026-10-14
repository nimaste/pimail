/// One JMAP method call.
///
/// Arguments and result are associated types so a call site cannot pair
/// `Email/query` arguments with a `Mailbox/get` result, and so the capability
/// a method needs travels with the method rather than being remembered at each
/// call site — ``RequestBuilder`` unions them into `using`.
public protocol JMAPMethod: Sendable {
    associatedtype Arguments: Encodable & Sendable
    associatedtype Result: Decodable & Sendable

    /// The wire name, e.g. `"Email/query"`.
    static var name: String { get }
    /// The capability that must appear in `using` for this method to be
    /// dispatched.
    static var capability: Capability { get }

    var arguments: Arguments { get }
}

/// An argument that may instead be a back-reference to an earlier call.
///
/// A back-reference changes the JSON **key**, not just the value — `ids`
/// becomes `#ids` — so it cannot be a value in the arguments struct and be
/// encoded by the synthesised `Codable`. The types that accept one write
/// `encode(to:)` by hand.
public enum Argument<Value: Encodable & Sendable>: Sendable {
    case value(Value)
    case reference(ResultReference)
}

extension Argument {
    /// The key this argument encodes under, given its plain name.
    func key(_ name: String) -> JMAPCodingKey {
        switch self {
        case .value: JMAPCodingKey(name)
        case .reference: JMAPCodingKey("#\(name)")
        }
    }

    func encode(into container: inout KeyedEncodingContainer<JMAPCodingKey>, as name: String) throws
    {
        switch self {
        case .value(let value):
            try container.encode(value, forKey: key(name))
        case .reference(let reference):
            try container.encode(reference, forKey: key(name))
        }
    }
}

/// The shape every `/changes` method returns.
public struct ChangesResult<ID: Decodable & Sendable & Hashable>: Decodable, Sendable {
    public var accountID: AccountID
    public var oldState: StateToken
    public var newState: StateToken

    /// Whether more changes remain. `/changes` returns at most **256** rows
    /// per call — deliberately modest for mobile — so callers loop until this
    /// clears, feeding `newState` back in as `sinceState`.
    public var hasMoreChanges: Bool

    public var created: [ID]
    public var updated: [ID]
    public var destroyed: [ID]

    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case oldState, newState, hasMoreChanges, created, updated, destroyed
    }
}

/// The shape every `/get` method returns.
public struct GetResult<Object: Decodable & Sendable>: Decodable, Sendable {
    public var accountID: AccountID
    public var state: StateToken

    /// **In repository order, not the order the ids were requested in.**
    /// Callers that paired this with a query must re-order it themselves.
    public var list: [Object]

    public var notFound: [String]

    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case state, list, notFound
    }
}
