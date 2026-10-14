import Foundation
import Testing

/// The widget's words are the ones nobody proof-reads.
///
/// `Widget/PLMailWidget.swift` is outside the package — it is an Xcode target,
/// so nothing in `swift test` compiles it and no catalogue check reached it.
/// Every string in it was a bare literal until `.core(_:)` existed, which on a
/// German phone meant an English home screen with no error anywhere to explain
/// it. `PLMailUITests/CatalogueCoverageTests` does this job for `.ui(…)` in
/// `PLMailUI`; this is the same guarantee for `.core(…)`, and it has to live
/// here because this is the module that owns the catalogue being read.
///
/// Read from the source tree rather than from a bundle for the same reason
/// that test does: the failure names the file a person has to edit.
@Suite("Widget localisation")
struct WidgetLocalizationTests {
    private static func repositoryRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // PLMailCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PLMail
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // pl_mail_ios
    }

    private static func catalogue(language: String) throws -> [String: String] {
        let url =
            repositoryRoot()
            .appending(path: "Packages/PLMail/Sources/PLMailCore/Resources")
            .appending(path: "\(language).lproj/Localizable.strings")
        let parsed = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), options: [], format: nil)

        return try #require(parsed as? [String: String])
    }

    /// Every `.core("…")` literal in a directory, comments stripped first so
    /// the shim's own doc comment does not count as a request.
    private static func requested(in directory: String) throws -> [(String, String)] {
        let root = repositoryRoot().appending(path: directory)
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var found: [(String, String)] = []

        for case let url as URL in all?.allObjects ?? [] where url.pathExtension == "swift" {
            let text =
                try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") == false }
                .joined(separator: "\n")

            var index = text.startIndex

            while let start = text.range(of: ".core(\"", range: index..<text.endIndex) {
                var cursor = start.upperBound
                var literal = ""
                var isEscaped = false

                while cursor < text.endIndex {
                    let character = text[cursor]

                    if isEscaped {
                        literal.append(character)
                        isEscaped = false
                    } else if character == "\\" {
                        literal.append(character)
                        isEscaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        literal.append(character)
                    }

                    cursor = text.index(after: cursor)
                }

                found.append((literal, url.lastPathComponent))
                index = cursor
            }
        }

        return found
    }

    @Test("the widget asks for at least one localised string")
    func theWidgetIsLocalisedAtAll() throws {
        // A guard on the guard: if somebody reverts the widget to literals,
        // every other assertion here passes vacuously.
        #expect(try Self.requested(in: "Widget").isEmpty == false)
    }

    /// An interpolated literal becomes a format string, so `\(count) unread`
    /// asks for the key `%lld unread` and nothing else will be consulted.
    @Test(
        "every .core literal is a key in both catalogues",
        arguments: ["Widget", "Packages/PLMail/Sources/PLMailCore"])
    func literalsAreDefined(directory: String) throws {
        let english = try Self.catalogue(language: "en")
        let german = try Self.catalogue(language: "de")

        for (literal, file) in try Self.requested(in: directory) {
            let key = literal.replacingOccurrences(of: "\\(count)", with: "%lld")

            #expect(
                key.contains("\\(") == false,
                "\(file): \"\(literal)\" interpolates something this test cannot spell")
            #expect(english[key] != nil, "\(file): no English key \"\(key)\"")
            #expect(german[key] != nil, "\(file): no German key \"\(key)\"")
        }
    }

    /// The point of the exercise. English on both sides would pass every
    /// structural check above and still ship an English widget.
    @Test("the widget's strings are actually translated")
    func theyAreInGerman() throws {
        let german = try Self.catalogue(language: "de")

        #expect(german["Nothing left today"] == "Heute nichts mehr")
        #expect(german["unread messages"] == "ungelesene Nachrichten")
        #expect(german["Open plMail to sign in"] == "plMail öffnen und anmelden")
    }
}
