/// A JMAP set, which the wire format models as a map to `true` rather than as
/// an array: `{"42": true}`, and `{}` when empty — **never** `[]`.
///
/// This covers `Email.mailboxIds` and `Email.keywords`, and it is worth a type
/// because both halves of the shape are easy to get wrong in opposite
/// directions. Decoding an array fails loudly; *encoding* one does not — the
/// server would simply see a property it cannot read.
///
/// Encoding through a keyed container gives `{}` for the empty case for free,
/// which is exactly the required behaviour.
public struct JMAPIDSet<Element: Hashable & RawRepresentable & Sendable>: Hashable, Sendable
where Element.RawValue == String {
    public var elements: Set<Element>

    public init(_ elements: Set<Element> = []) {
        self.elements = elements
    }

    public init(_ elements: some Sequence<Element>) {
        self.elements = Set(elements)
    }

    public var isEmpty: Bool { elements.isEmpty }

    public func contains(_ element: Element) -> Bool { elements.contains(element) }
}

extension JMAPIDSet: Codable where Element: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JMAPCodingKey.self)
        var elements: Set<Element> = []

        for key in container.allKeys {
            // RFC 8620 says the value is always true, so a false is malformed
            // rather than meaningful. Being liberal here costs nothing and
            // avoids treating a server quirk as data corruption.
            guard try container.decode(Bool.self, forKey: key) else { continue }
            guard let element = Element(rawValue: key.stringValue) else { continue }

            elements.insert(element)
        }

        self.elements = elements
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JMAPCodingKey.self)

        // Sorted so the encoded form is deterministic — otherwise the golden
        // request test would depend on Set iteration order.
        for element in elements.map(\.rawValue).sorted() {
            try container.encode(true, forKey: JMAPCodingKey(element))
        }
    }
}

extension JMAPIDSet: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) {
        self.elements = Set(elements)
    }
}

/// A `CodingKey` with no fixed cases, for the map-shaped parts of the protocol.
public struct JMAPCodingKey: CodingKey, Sendable {
    public let stringValue: String
    public let intValue: Int? = nil

    public init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    public init?(stringValue: String) {
        self.stringValue = stringValue
    }

    public init?(intValue: Int) {
        nil
    }
}
