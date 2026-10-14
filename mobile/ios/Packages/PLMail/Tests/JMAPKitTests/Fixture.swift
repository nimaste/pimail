import Foundation
import Testing

/// Loads a checked-in JSON fixture.
///
/// The fixtures are written to match `src/Jmap/Mapper/` exactly — the shapes
/// that are easy to get wrong are the ones worth pinning: `{}` rather than
/// `[]` for empty maps, `null` rather than `[]` for empty address lists, and a
/// method error arriving inline in a 200.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Missing fixture \(name).json"
        )

        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
