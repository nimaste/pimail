import Testing

@testable import PLMailUI

/// The avatar is decoration, but the *stability* of it is not: a correspondent
/// whose colour changes between launches is worse than no colour at all,
/// because the list stops being scannable by shape and starts looking broken.
@Suite("Avatar palette")
struct AvatarPaletteTests {
    @Test("the same address always lands on the same colour")
    func stableAcrossCalls() {
        let first = AvatarPalette.index(for: "ada@example.com")

        for _ in 0..<50 {
            #expect(AvatarPalette.index(for: "ada@example.com") == first)
        }
    }

    /// The reason `index(for:)` spells out FNV-1a instead of calling
    /// `hashValue`: Swift seeds `Hashable` per process, so this exact value
    /// would differ on every launch. Pinning it means a refactor back to
    /// `hashValue` fails here rather than shipping.
    @Test("the hash is not the per-process seeded one")
    func pinnedValues() {
        #expect(AvatarPalette.index(for: "ada@example.com") == 10)
        #expect(AvatarPalette.index(for: "grace@example.com") == 2)
        #expect(AvatarPalette.index(for: "") == 5)
    }

    @Test("case and surrounding whitespace do not change the colour")
    func caseInsensitive() {
        #expect(
            AvatarPalette.index(for: "Ada@Example.COM")
                == AvatarPalette.index(for: "ada@example.com"))
    }

    @Test("every index is a real slot in the palette")
    func inBounds() {
        for seed in ["", "a", "z@z", "ünïcödé@example.com", String(repeating: "x", count: 500)] {
            let index = AvatarPalette.index(for: seed)

            #expect(index >= 0)
            #expect(index < AvatarPalette.count)
        }
    }

    @Test(
        "initials come from the name when there is one",
        arguments: [
            ("Ada Lovelace", "ada@example.com", "AL"),
            ("Lovelace, Ada", "ada@example.com", "LA"),
            // Three or more words still give two letters; "Jean Baptiste
            // Joseph Fourier" must not become a four-letter block.
            ("Jean Baptiste Joseph Fourier", "jbjf@example.com", "JB"),
            ("Ada", "ada@example.com", "A"),
        ]
    )
    func initialsFromName(name: String, address: String, expected: String) {
        #expect(AvatarPalette.initials(name: name, address: address) == expected)
    }

    /// Mail clients routinely put the address in the display-name slot. Taking
    /// initials from it would render "AD" for `ada@…` and "IN" for
    /// `info@…` — worse than the local part's first letter, since every
    /// no-reply address in the inbox would collide.
    @Test("an address masquerading as a name falls through to the address")
    func addressAsName() {
        #expect(AvatarPalette.initials(name: "ada@example.com", address: "ada@example.com") == "A")
    }

    @Test(
        "anything with no letter in it yields nothing rather than punctuation",
        arguments: [
            ("", ""),
            ("🎉", "123@example.com"),
            ("", "+49-123@example.com"),
        ]
    )
    func noLetters(name: String, address: String) {
        let initials = AvatarPalette.initials(name: name, address: address)

        // Either empty — the view substitutes "?" — or a real letter. Never a
        // digit or a symbol, which reads as corruption in a circle.
        #expect(initials.isEmpty || initials.allSatisfy(\.isLetter))
    }

    @Test("a name with no address still produces initials")
    func nameOnly() {
        #expect(AvatarPalette.initials(name: "Ada Lovelace", address: nil) == "AL")
    }
}
