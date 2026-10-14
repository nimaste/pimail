/// Identifies one call within a request, so its result and any back-reference
/// to it can be matched up. `c0`, `c1`, … — assigned by ``RequestBuilder``.
public struct CallID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// One `["Method/name", {arguments}, "c0"]` triple.
///
/// A heterogeneous JSON array, which is why encoding and decoding are written
/// out by hand rather than synthesised.
struct Invocation: Encodable {
    let name: String
    let arguments: any Encodable & Sendable
    let callID: CallID

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(name)
        try container.encode(arguments)
        try container.encode(callID)
    }
}

/// One entry of `methodResponses`, with its arguments still undecoded.
///
/// The name has to be read before the arguments can be given a type, and a
/// `Decoder` cannot be held onto past `init(from:)` — hence ``JSONValue``.
struct ResponseInvocation: Decodable {
    /// The method name, or the literal `"error"` for a call that failed.
    let name: String
    let arguments: JSONValue
    let callID: CallID

    /// A method that failed reports as `["error", {...}, "c0"]` **inside a
    /// 200**, so one failing call in a batch must not fail its siblings.
    var isError: Bool { name == "error" }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
        arguments = try container.decode(JSONValue.self)
        callID = try container.decode(CallID.self)
    }
}
