/// A back-reference to an earlier call's result within the same request
/// (RFC 8620 §3.7).
///
/// This is how `Email/query` and `Email/get` are paired in one round trip
/// instead of two, which matters a great deal over a home uplink:
///
/// ```
/// ["Email/query", {…}, "c0"],
/// ["Email/get",   {"#ids": {"resultOf": "c0", "name": "Email/query", "path": "/ids"}}, "c1"]
/// ```
///
/// Note it changes the argument's **key**, not just its value — `ids` becomes
/// `#ids` — which is why it cannot be modelled as an ordinary value. See
/// ``Argument``.
public struct ResultReference: Hashable, Sendable, Encodable {
    /// The call id of the earlier invocation.
    public var resultOf: CallID
    /// The method name of that invocation. The server checks it matches.
    public var name: String
    /// A restricted JSON Pointer into that result.
    public var path: String

    public init(resultOf: CallID, name: String, path: String) {
        self.resultOf = resultOf
        self.name = name
        self.path = path
    }
}
