import Testing

@testable import PLMailCore

/// Which strategy a message gets is the whole difference between dark mail
/// that reads well and dark mail that looks broken, and the inputs are real
/// messages rather than anything this app controls.
@Suite("Message colour profile")
struct MessageColorProfileTests {
    // MARK: - Profiling

    /// A reply typed into a compose box. Nothing to preserve, so it can be
    /// restyled outright — the only strategy with no artefacts at all.
    @Test("a plain reply declares no colours of its own")
    func plainReply() {
        let profile = MessageColorProfile.profile(
            of: "<div>Thanks, that works for me.</div><br><div>— Sam</div>")

        #expect(profile.declaresOwnColors == false)
        #expect(profile.supportsDarkMode == false)
        #expect(profile.hasImagery == false)
    }

    @Test(
        "a message that paints itself is detected however it does it",
        arguments: [
            "<table bgcolor=\"#ffffff\"><tr><td>Hi</td></tr></table>",
            "<div style=\"background-color:#f5f5f5\">Hi</div>",
            "<div style=\"color:#333333\">Hi</div>",
            "<style>.wrap { background: #fff; }</style><div class=\"wrap\">Hi</div>",
            "<div style=\"background-image:url(bg.png)\">Hi</div>",
        ]
    )
    func designedMessage(html: String) {
        #expect(MessageColorProfile.profile(of: html).declaresOwnColors)
    }

    /// A newsletter that already has dark styles has done the work. Inverting
    /// it would double-invert into something worse than either.
    @Test("mail with its own dark styles is recognised")
    func alreadySupportsDark() {
        let html = """
            <style>@media (prefers-color-scheme: dark) { body { background: #111; } }</style>
            <div>Newsletter</div>
            """

        #expect(MessageColorProfile.profile(of: html).supportsDarkMode)
    }

    /// Imagery is what makes naive inversion look wrong — a photo comes out as
    /// a negative and a logo comes out in the wrong brand colours.
    @Test(
        "imagery is detected",
        arguments: [
            "<img src=\"logo.png\">",
            "<picture><source srcset=\"a.webp\"></picture>",
            "<svg><circle r=\"4\"/></svg>",
            "<div style=\"background-image:url(hero.jpg)\"></div>",
        ]
    )
    func imagery(html: String) {
        #expect(MessageColorProfile.profile(of: html).hasImagery)
    }

    // MARK: - Choosing

    @Test("light appearance always renders the message as sent")
    func lightIsUntouched() {
        let designed = MessageColorProfile(
            declaresOwnColors: true, supportsDarkMode: false, hasImagery: true)

        #expect(
            MessageRenderStyle.choose(profile: designed, isDark: false, prefersOriginal: false)
                == .original
        )
    }

    @Test("a plain message is restyled rather than inverted")
    func plainIsRestyled() {
        let plain = MessageColorProfile(
            declaresOwnColors: false, supportsDarkMode: false, hasImagery: false)

        #expect(
            MessageRenderStyle.choose(profile: plain, isDark: true, prefersOriginal: false)
                == .darkRestyled
        )
    }

    @Test("a designed message is inverted, since restyling would fight it")
    func designedIsInverted() {
        let designed = MessageColorProfile(
            declaresOwnColors: true, supportsDarkMode: false, hasImagery: true)

        #expect(
            MessageRenderStyle.choose(profile: designed, isDark: true, prefersOriginal: false)
                == .darkInverted
        )
    }

    /// Checked before the own-colours case: mail that handles dark itself
    /// almost always also declares colours, and inverting it would undo work
    /// the sender already did.
    @Test("mail that handles dark itself is left to do so")
    func nativeWins() {
        let adaptive = MessageColorProfile(
            declaresOwnColors: true, supportsDarkMode: true, hasImagery: true)

        #expect(
            MessageRenderStyle.choose(profile: adaptive, isDark: true, prefersOriginal: false)
                == .darkNative
        )
    }

    /// Inversion gets some messages wrong. When it does, the user needs to see
    /// what was actually sent rather than be told it is fine.
    @Test("the escape hatch returns the original at any appearance")
    func escapeHatch() {
        let designed = MessageColorProfile(
            declaresOwnColors: true, supportsDarkMode: false, hasImagery: true)

        #expect(
            MessageRenderStyle.choose(profile: designed, isDark: true, prefersOriginal: true)
                == .original
        )
    }

    /// The control is only worth showing where something could be wrong.
    @Test("only inversion offers a way back")
    func onlyInversionIsTransformed() {
        #expect(MessageRenderStyle.darkInverted.isTransformed)
        #expect(MessageRenderStyle.darkRestyled.isTransformed == false)
        #expect(MessageRenderStyle.darkNative.isTransformed == false)
        #expect(MessageRenderStyle.original.isTransformed == false)
    }
}
