import Foundation
import Testing

/// Every string the code asks for has to be a key the catalogue has.
///
/// The existing catalogue tests compare `en` against `de`, which catches a key
/// translated into only one language. They cannot catch the other silent
/// failure: a key the *code* asks for that neither catalogue defines. That one
/// falls through to the literal, so English readers see the right words and
/// German readers see English — and nothing anywhere reports it.
///
/// This bites hardest on interpolation, where the key is generated rather than
/// typed. `Text(.ui("\(a) of \(b)"))` asks for `"%lld of %lld"`, and a
/// catalogue entry written as `"%1$lld of %2$lld"` — which is what a person
/// reaching for positional arguments writes — is a different key that is never
/// consulted. Both files stay in perfect `en`/`de` agreement while the string
/// is untranslated.
@Suite("Catalogue coverage")
struct CatalogueCoverageTests {
    private static func packageRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // PLMailUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PLMail
    }

    private static func keys(module: String) throws -> Set<String> {
        let url = packageRoot()
            .appending(path: "Sources/\(module)/Resources/en.lproj/Localizable.strings")
        let parsed = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), options: [], format: nil)

        return Set(try #require(parsed as? [String: String]).keys)
    }

    private static func swiftFiles(module: String) throws -> [URL] {
        let root = packageRoot().appending(path: "Sources/\(module)")
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)

        return (all?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Literals passed to `.ui(…)`, with interpolations left in place so the
    /// caller can decide what to do about them.
    private static func requested(module: String) throws -> [(literal: String, file: String)] {
        // Deliberately simple: match `.ui("` and read to the closing quote,
        // honouring backslash escapes. A Swift parser would be more correct
        // and much more code, and every call in this package is a plain
        // literal on one line.
        var found: [(String, String)] = []

        for file in try swiftFiles(module: module) {
            // Comments are stripped first: the doc comment on `.ui` itself
            // demonstrates the call, and a documentation example is not a
            // string anyone will ever look up.
            let text =
                try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") == false }
                .joined(separator: "\n")

            var index = text.startIndex

            while let start = text.range(of: ".ui(\"", range: index..<text.endIndex) {
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

                found.append((literal, file.lastPathComponent))
                index = cursor
            }
        }

        return found
    }

    @Test("every plain .ui literal is a key in the catalogue")
    func plainLiteralsAreDefined() throws {
        let defined = try Self.keys(module: "PLMailUI")

        for (literal, file) in try Self.requested(module: "PLMailUI")
        where literal.contains("\\(") == false && literal.isEmpty == false {
            // An empty literal is excluded above rather than here: it is how a
            // view asks for *no* navigation title, and there is nothing to
            // translate.
            #expect(defined.contains(literal), "PLMailUI/\(file): no catalogue key \"\(literal)\"")
        }
    }

    /// An interpolated literal becomes a format string, and the key is that
    /// format string. This checks the *shape* — one placeholder per
    /// interpolation, none of them positional — because a positional key
    /// (`%1$lld`) is never the one the runtime looks up.
    @Test("every interpolated .ui literal has a matching non-positional key")
    func interpolatedLiteralsAreDefined() throws {
        let defined = try Self.keys(module: "PLMailUI")

        for (literal, file) in try Self.requested(module: "PLMailUI")
        where literal.contains("\\(") {
            let placeholders = Self.interpolationCount(literal)

            // A key with the right number of placeholders and no positional
            // specifiers. The type behind each one is not knowable from the
            // source text, so any of the forms actually used here counts.
            let candidates = defined.filter { key in
                key.contains("$") == false
                    && Self.placeholderCount(key) == placeholders
                    && Self.skeleton(key) == Self.skeleton(Self.asFormat(literal))
            }

            #expect(
                candidates.isEmpty == false,
                "PLMailUI/\(file): no non-positional catalogue key for \"\(literal)\"")
        }
    }

    private static func interpolationCount(_ literal: String) -> Int {
        literal.components(separatedBy: "\\(").count - 1
    }

    private static func placeholderCount(_ key: String) -> Int {
        var count = 0
        var characters = Array(key)
        var index = 0

        while index < characters.count {
            if characters[index] == "%" {
                if index + 1 < characters.count && characters[index + 1] == "%" {
                    index += 2
                    continue
                }

                count += 1
            }

            index += 1
        }

        return count
    }

    /// The literal with every `\(…)` replaced by a marker, so it can be
    /// compared against a key with the specifiers replaced the same way.
    private static func asFormat(_ literal: String) -> String {
        var result = ""
        var rest = Substring(literal)

        while let start = rest.range(of: "\\(") {
            result += rest[rest.startIndex..<start.lowerBound]
            result += "\u{1}"

            var depth = 1
            var cursor = start.upperBound

            while cursor < rest.endIndex && depth > 0 {
                if rest[cursor] == "(" { depth += 1 }
                if rest[cursor] == ")" { depth -= 1 }
                cursor = rest.index(after: cursor)
            }

            rest = rest[cursor...]
        }

        return result + rest
    }

    /// A key with every format specifier replaced by the same marker.
    private static func skeleton(_ text: String) -> String {
        var result = ""
        var characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index] == "%" else {
                result.append(characters[index])
                index += 1
                continue
            }

            index += 1

            if index < characters.count && characters[index] == "%" {
                result.append("%")
                index += 1
                continue
            }

            // Skip flags, width, length modifiers and the conversion itself.
            while index < characters.count, "0123456789.#-+ lhqLzjt".contains(characters[index]) {
                index += 1
            }

            if index < characters.count { index += 1 }

            result.append("\u{1}")
        }

        return result
    }
}
