import Foundation
import JMAPKit
import Testing

@testable import PLMailCore

/// The recipient field is the one part of composing where a bug costs somebody
/// else's message: a dropped address, an invented one, or two copies of the
/// same mail. None of it is visible on the sender's screen.
@Suite("Recipient parsing")
struct RecipientParsingTests {
    @Test("A quoted display name containing a comma stays one recipient")
    func quotedNameWithComma() throws {
        let entries = RecipientParsing.entries(in: "\"Meyer, Anna\" <anna@example.org>")

        #expect(entries.count == 1)

        let address = try #require(entries.first?.address)

        #expect(address.email == "anna@example.org")
        #expect(address.name == "Meyer, Anna")
    }

    @Test("Two recipients, one of them with a comma in its name, split correctly")
    func quotedNameAmongOthers() {
        let addresses = RecipientParsing.addresses(
            in: "\"Meyer, Anna\" <anna@example.org>, bob@example.org")

        #expect(addresses.map(\.email) == ["anna@example.org", "bob@example.org"])
    }

    @Test("An unquoted display name is kept rather than used as the address")
    func angleAddress() throws {
        let address = try #require(RecipientParsing.parse("Anna Meyer <anna@example.org>"))

        #expect(address.email == "anna@example.org")
        #expect(address.name == "Anna Meyer")
    }

    @Test("A bare address parses with no name")
    func bareAddress() throws {
        let address = try #require(RecipientParsing.parse("anna@example.org"))

        #expect(address.email == "anna@example.org")
        #expect(address.name == nil)
    }

    @Test(
        "An entry that is not an address is reported rather than dropped",
        arguments: ["anna", "anna@", "@example.org", "a@@b", "anna @example.org"])
    func invalidIsReported(_ typed: String) {
        #expect(RecipientParsing.parse(typed) == nil)
        #expect(RecipientParsing.invalid(in: typed) == [typed])
        #expect(RecipientParsing.addresses(in: typed).isEmpty)
    }

    /// Two identical addresses used to send two copies, which reads to the
    /// recipient as the sender being careless.
    @Test("Duplicates are removed case-insensitively, keeping the first name")
    func deduplication() throws {
        let addresses = RecipientParsing.addresses(
            in: "Anna <anna@example.org>, ANNA@example.org, bob@example.org")

        #expect(addresses.count == 2)
        #expect(addresses.first?.name == "Anna")
        #expect(addresses.map { $0.email.lowercased() } == ["anna@example.org", "bob@example.org"])
    }

    @Test("Semicolons separate too, because people paste from everywhere")
    func semicolons() {
        #expect(
            RecipientParsing.addresses(in: "a@x.test; b@x.test").map(\.email)
                == ["a@x.test", "b@x.test"])
    }

    /// Writing a field out and reading it back has to be the identity, or a
    /// picked suggestion with a comma in its name breaks on the next keystroke.
    @Test("A field round-trips through display and parse")
    func roundTrip() {
        let original = [
            EmailAddress(name: "Meyer, Anna", email: "anna@example.org"),
            EmailAddress(name: "Bob", email: "bob@example.org"),
            EmailAddress(name: nil, email: "carol@example.org"),
        ]

        let parsed = RecipientParsing.addresses(in: RecipientParsing.field(from: original))

        #expect(parsed == original)
    }

    @Test("A separator inside angle brackets does not split")
    func angleBracketSeparator() {
        #expect(RecipientParsing.split("<a,b@x.test>").count == 1)
    }
}
