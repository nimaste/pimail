import Foundation
import Testing

@testable import PLMailCore

/// Localisation in a Swift package fails silently in two different ways, and
/// this app has already been bitten by one of them.
///
/// The first: `String(localized:)` without `bundle: .module` looks in the app
/// bundle, misses, and returns the English literal. Nothing warns. The strings
/// ship, are never consulted, and everything looks fine in English.
///
/// The second is subtler and only affects interpolated strings. The key the
/// compiler generates for `"Can't reach \(host)."` is `Can't reach %@.` — if
/// the `.strings` file spells the placeholder differently, or puts it in a
/// different position for a language whose word order differs, the lookup
/// misses and falls back to English.
///
/// Asserting on German output catches both, because English fallback is
/// indistinguishable from success in English.
@Suite("Localization")
struct LocalizationTests {
    /// The German table, loaded directly.
    ///
    /// **Not** `String(localized:locale:)`. That parameter formats numbers and
    /// dates inside the string; it does not choose which translation to load —
    /// the bundle does, from the process's preferred languages. Passing
    /// `locale: Locale(identifier: "de")` and asserting on the result looks
    /// exactly right and silently tests nothing, because every lookup falls
    /// back to English and every English assertion passes. That is how this
    /// test was written the first time.
    private var germanBundle: Bundle {
        get throws {
            let path = try #require(
                Bundle.module.path(forResource: "de", ofType: "lproj"),
                "No de.lproj in the bundle — check `resources:` in Package.swift.")

            return try #require(Bundle(path: path), "de.lproj is not a readable bundle.")
        }
    }

    @Test(
        "Error messages resolve in German",
        arguments: [
            ("Waiting for the server.", "Warte auf den Server."),
            ("Sign-in is no longer valid.", "Die Anmeldung ist nicht mehr gültig."),
            ("This account has no Spam mailbox.", "Dieses Konto hat kein Werbung-Postfach."),
            ("That isn't a plMail pairing code.", "Das ist kein plMail-Kopplungscode."),
            (
                "Couldn't reach the server. Nothing was changed.",
                "Server nicht erreichbar. Es wurde nichts geändert."
            ),
        ])
    func errorsInGerman(key: String.LocalizationValue, expected: String) throws {
        #expect(String(localized: key, bundle: try germanBundle) == expected)
    }

    /// The placeholder case, end to end: the compiler turns
    /// `"Can't reach \(host)."` into the key `Can't reach %@.`, and German puts
    /// the host first. A `.strings` entry that copied the English word order,
    /// or spelled the placeholder differently, fails here.
    @Test("An interpolated host lands in the right place")
    func interpolatedHost() throws {
        let host = "nas.local"

        #expect(
            String(localized: "Can't reach \(host).", bundle: try germanBundle)
                == "nas.local ist nicht erreichbar.")

        #expect(
            String(localized: "Can't reach \(host).", bundle: .module)
                == "Can't reach nas.local.")
    }

    @Test("Mailbox roles resolve in German")
    func rolesInGerman() throws {
        #expect(String(localized: "Inbox", bundle: try germanBundle) == "Posteingang")
        #expect(String(localized: "Spam", bundle: try germanBundle) == "Werbung")
    }

    /// The bug this app actually shipped: `String(localized:)` without
    /// `bundle: .module` searches the *app* bundle, misses, and returns the
    /// English literal. It compiles, it runs, and it is invisible until
    /// somebody switches the phone to German.
    ///
    /// Checked by reading the source, because there is no runtime signal to
    /// assert on — a missed lookup and a correct English lookup are the same
    /// string.
    @Test("Every localized string in PLMailCore names the module bundle")
    func everyLookupNamesTheBundle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PLMailCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PLMail
            .appending(path: "Sources/PLMailCore")

        var offenders: [String] = []

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)

        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                let source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            let lines = source.components(separatedBy: "\n")

            for (number, line) in lines.enumerated() {
                guard line.contains("String(localized:") else { continue }

                // Comments talk about this API precisely because it is the
                // trap — the note in FeedID explaining why the bundle is named
                // is not itself a lookup.
                let code = line.trimmingCharacters(in: .whitespaces)

                guard code.hasPrefix("//") == false, code.hasPrefix("*") == false else {
                    continue
                }

                // The call may wrap, so look at the next couple of lines too.
                // Truncated at the *next* lookup. A fixed window of lines
                // bleeds into the following call, and in a `switch` full of
                // adjacent lookups it finds that call's `bundle:` and
                // pronounces this one fine — which is how the first version of
                // this check passed while the bug was present.
                var window = lines[number...].prefix(4).joined(separator: " ")

                if let first = window.range(of: "String(localized:"),
                    let next = window.range(
                        of: "String(localized:", range: first.upperBound..<window.endIndex)
                {
                    window = String(window[..<next.lowerBound])
                }

                if window.contains("bundle: .module") == false {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            "These lookups will silently return English: \(offenders.joined(separator: ", "))")
    }

    /// Drift between the two files is the ordinary way translations rot: a
    /// string is added to English, the German file is forgotten, and the app
    /// silently speaks English at one screen.
    @Test("Every English key has a German one, and the reverse")
    func noDrift() throws {
        let en = try keys(in: "en")
        let de = try keys(in: "de")

        #expect(en.isEmpty == false, "No English keys were found — is the bundle wired up?")
        #expect(
            en.subtracting(de).isEmpty,
            "Missing German: \(en.subtracting(de).sorted().joined(separator: ", "))")
        #expect(
            de.subtracting(en).isEmpty,
            "Missing English: \(de.subtracting(en).sorted().joined(separator: ", "))")
    }

    /// PLMailUI carries the larger of the two string tables and has no test
    /// target of its own — its views are `#if os(iOS)` and would not build on
    /// the host. Read from the source tree instead: drift between two files is
    /// a property of the files, not of the bundle they end up in.
    @Test("The UI strings do not drift either")
    func uiStringsDoNotDrift() throws {
        let en = try uiKeys(language: "en")
        let de = try uiKeys(language: "de")

        #expect(en.isEmpty == false, "No English UI keys were found.")
        #expect(
            en.subtracting(de).isEmpty,
            "Missing German: \(en.subtracting(de).sorted().joined(separator: ", "))")
        #expect(
            de.subtracting(en).isEmpty,
            "Missing English: \(de.subtracting(en).sorted().joined(separator: ", "))")
    }

    /// A spot check that the UI table really is translated, not just present
    /// on both sides with the English copied across.
    @Test("UI strings are actually in German")
    func uiStringsAreGerman() throws {
        let de = try uiTable(language: "de")

        #expect(de["Subject"] == "Betreff")
        #expect(de["Outbox"] == "Postausgang")
        #expect(de["Deselect all"] == "Auswahl aufheben")
    }

    private var uiResources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/PLMailUI/Resources")
    }

    private func uiTable(language: String) throws -> [String: String] {
        let url =
            uiResources
            .appending(path: "\(language).lproj")
            .appending(path: "Localizable.strings")

        return try #require(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language) UI strings are missing or malformed.")
    }

    private func uiKeys(language: String) throws -> Set<String> {
        Set(try uiTable(language: language).keys)
    }

    /// Reads the shipped `.strings` rather than the source tree, so this also
    /// proves the resources are actually in the bundle.
    private func keys(in language: String) throws -> Set<String> {
        let url = try #require(
            Bundle.module.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                localization: language),
            "No \(language) strings file in the bundle.")

        let contents = try #require(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(language) strings file is malformed.")

        return Set(contents.keys)
    }
}
