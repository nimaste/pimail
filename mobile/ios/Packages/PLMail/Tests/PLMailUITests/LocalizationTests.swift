import Foundation
import Testing

/// German is not a translation layer bolted on at the end — it is one of the
/// two languages the app claims to be in. The failure mode this guards is
/// silent: a key added to `en` and forgotten in `de` falls through to the
/// English literal at runtime, which looks exactly like a deliberate
/// untranslated term and is spotted by nobody.
///
/// The files are read from source rather than from a bundle so the test names
/// the file a person has to edit, and so it covers both modules from one
/// place.
@Suite("Localisation catalogues")
struct LocalizationTests {
    private static let modules = ["PLMailCore", "PLMailUI"]

    private static func url(module: String, language: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // PLMailUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PLMail
            .appending(path: "Sources/\(module)/Resources/\(language).lproj/Localizable.strings")
    }

    private static func strings(module: String, language: String) throws -> [String: String] {
        let data = try Data(contentsOf: url(module: module, language: language))
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)

        return try #require(parsed as? [String: String])
    }

    @Test("every English key has a German one, and no more", arguments: modules)
    func noDrift(module: String) throws {
        let english = try Self.strings(module: module, language: "en")
        let german = try Self.strings(module: module, language: "de")

        let missing = Set(english.keys).subtracting(german.keys).sorted()
        let extra = Set(german.keys).subtracting(english.keys).sorted()

        #expect(missing.isEmpty, "\(module): no German for \(missing)")
        #expect(extra.isEmpty, "\(module): German for keys no longer in English: \(extra)")
    }

    /// An empty value is worse than a missing key: the key at least falls
    /// through to English, whereas an empty string renders as a blank button.
    @Test("no translation is blank", arguments: modules)
    func noBlanks(module: String) throws {
        for language in ["en", "de"] {
            for (key, value) in try Self.strings(module: module, language: language) {
                #expect(
                    value.trimmingCharacters(in: .whitespaces).isEmpty == false,
                    "\(module)/\(language): \"\(key)\" is empty")
            }
        }
    }

    /// A duplicated key parses without complaint and the last one wins, so a
    /// second definition of a string someone has already translated silently
    /// replaces it. Counting the assignments against the parsed dictionary is
    /// the only way that shows up.
    @Test("no key is defined twice", arguments: modules)
    func noDuplicates(module: String) throws {
        for language in ["en", "de"] {
            let text = try String(
                contentsOf: Self.url(module: module, language: language), encoding: .utf8)
            let defined = text.split(separator: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"")
            }

            #expect(
                defined.count == (try Self.strings(module: module, language: language)).count,
                "\(module)/\(language): a key is defined more than once")
        }
    }
}
