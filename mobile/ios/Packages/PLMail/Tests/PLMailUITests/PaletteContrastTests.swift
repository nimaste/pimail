import Testing

@testable import PLMailUI

/// The palette, measured rather than described.
///
/// **This suite exists because the description was wrong.** `ActionTint`'s doc
/// comment has always said its five values were "walked down in lightness until
/// white text and a white glyph clear 4.5:1"; two of them measured 4.36:1 and
/// 4.35:1, and one avatar measured 4.49:1. Nothing caught it, because a
/// palette written as `Color` literals cannot be read back and a claim in
/// prose cannot be run. Every value below is now a ``Swatch``, and every claim
/// about it is a test.
///
/// It matters more, not less, now that themes are server-driven: the
/// combinations multiply the moment a palette is derived rather than tuned,
/// and a floor nobody can check is a floor that is not there.
@Suite("Palette contrast")
struct PaletteContrastTests {
    /// WCAG AA for normal text.
    private static let readable = 4.5
    /// WCAG AAA. Mail is read for hours; body ink is held here.
    private static let comfortable = 7.0
    /// WCAG AA for large text and non-text. The floor for anything decorative.
    private static let discernible = 3.0

    // MARK: - The hand-tuned values

    /// A swipe button is a coloured block with white content on it. One that
    /// merely looks nice at rest is unreadable mid-gesture with a thumb over
    /// half of it.
    @Test("every swipe tint carries white content at 4.5:1")
    func actionTints() {
        for tint in ActionTint.all {
            let ratio = tint.swatch.contrastRatio(against: .white)

            #expect(
                ratio >= Self.readable,
                "ActionTint.\(tint.name) is \(ratio) against white, under \(Self.readable)")
        }
    }

    /// The avatar is a solid fill on both a cream and a near-black surface, so
    /// one set has to work on both — which is only possible because the
    /// surface behind never shows through.
    @Test("every avatar colour carries white initials at 4.5:1")
    func avatarColours() {
        for entry in AvatarPalette.swatches {
            let ratio = entry.swatch.contrastRatio(against: .white)

            #expect(
                ratio >= Self.readable,
                "AvatarPalette \(entry.name) is \(ratio) against white, under \(Self.readable)")
        }
    }

    /// The order is a sender's colour, so reordering or resizing renumbers
    /// everybody. Pinned here as well as in `AvatarPaletteTests` because this
    /// file is the one that touches the array.
    @Test("the twelve avatar hues stay in their published order")
    func avatarOrderUnchanged() {
        #expect(AvatarPalette.count == 12)
        #expect(
            AvatarPalette.swatches.map(\.name) == [
                "terracotta", "clay", "mustard", "sage", "eucalyptus", "dusty blue",
                "periwinkle", "heather", "mauve", "dusty rose", "stone", "taupe",
            ])
    }

    // MARK: - The derived palettes

    /// Swept across every shipped theme rather than checked on one, because
    /// the derivation is what is being tested: a theme added as two lines of
    /// data has to be safe without anybody looking at it.
    @Test("body ink clears 7:1 on every surface of every shipped theme")
    func inkOnEverySurface() {
        for entry in ThemePalette.allShipped {
            for surface in entry.palette.surfaces {
                let ratio = entry.palette.ink.contrastRatio(against: surface)

                #expect(
                    ratio >= Self.comfortable,
                    "\(entry.name): ink is \(ratio) on a surface, under \(Self.comfortable)")
            }
        }
    }

    @Test("the ink ladder clears its floor at every rung, on every theme")
    func inkLadder() {
        for entry in ThemePalette.allShipped {
            let palette = entry.palette
            let rungs: [(String, Swatch, Double)] = [
                ("inkSoft", palette.inkSoft, Self.readable),
                ("inkMuted", palette.inkMuted, Self.readable),
                ("inkFaint", palette.inkFaint, Self.discernible),
            ]

            for (name, colour, floor) in rungs {
                for surface in palette.surfaces {
                    let ratio = colour.contrastRatio(against: surface)

                    #expect(
                        ratio >= floor,
                        "\(entry.name): \(name) is \(ratio) on a surface, under \(floor)")
                }
            }
        }
    }

    /// Both directions. An accent is drawn *as* text on a surface and drawn
    /// *behind* text as a fill, and a palette that only checks one of those
    /// ships an unreadable button.
    @Test("the accent is readable on every surface, and readable content sits on it")
    func accentBothWays() {
        for entry in ThemePalette.allShipped {
            let palette = entry.palette

            for surface in palette.surfaces {
                let ratio = palette.accent.contrastRatio(against: surface)

                #expect(
                    ratio >= Self.readable,
                    "\(entry.name): accent is \(ratio) on a surface, under \(Self.readable)")
            }

            let onAccent = palette.accentInk.contrastRatio(against: palette.accent)

            #expect(
                onAccent >= Self.readable,
                "\(entry.name): accentInk is \(onAccent) on the accent")
        }
    }

    @Test("status colours are readable as text on every surface of every theme")
    func statusColours() {
        for entry in ThemePalette.allShipped {
            let palette = entry.palette
            let named: [(String, Swatch)] = [
                ("danger", palette.danger), ("warning", palette.warning),
                ("success", palette.success), ("info", palette.info),
            ]

            for (name, colour) in named {
                for surface in palette.surfaces {
                    let ratio = colour.contrastRatio(against: surface)

                    #expect(
                        ratio >= Self.readable,
                        "\(entry.name): \(name) is \(ratio) on a surface")
                }
            }
        }
    }

    /// Not a contrast floor but a legibility one: the hairline's job is to
    /// stop two rows merging without drawing a grid, so it has to differ from
    /// the surface at all while staying well under text contrast.
    @Test("the hairline is visible against its surface without reading as a rule")
    func hairline() {
        for entry in ThemePalette.allShipped {
            let ratio = entry.palette.line.contrastRatio(against: entry.palette.surface)

            #expect(ratio > 1.02, "\(entry.name): the hairline is invisible")
            #expect(ratio < Self.discernible, "\(entry.name): the hairline reads as a rule")
        }
    }

    // MARK: - The arithmetic itself

    /// Every assertion above is only as good as this. A luminance that skips
    /// the gamma expansion overstates mid-tone contrast by enough to pass a
    /// palette that fails on a phone in daylight.
    @Test("contrast maths agrees with WCAG's published extremes")
    func knownRatios() {
        #expect(abs(Swatch.black.contrastRatio(against: .white) - 21) < 0.001)
        #expect(abs(Swatch.white.contrastRatio(against: .white) - 1) < 0.001)

        // #767676 on white is WCAG's own canonical 4.54:1 boundary case.
        let boundary = Swatch(hex: "#767676") ?? .black
        let ratio = boundary.contrastRatio(against: .white)

        #expect(ratio > 4.5 && ratio < 4.6)
    }

    @Test("contrast is symmetric, so an argument order cannot be got wrong")
    func symmetry() {
        let one = Swatch(0.2, 0.5, 0.7)
        let two = PanelStyle.surfaceLight

        #expect(one.contrastRatio(against: two) == two.contrastRatio(against: one))
    }

    /// The mechanism the whole server-driven palette rests on: an accent
    /// chosen against the web's white has to become legible here without being
    /// discarded.
    @Test("a colour is walked only as far as it needs to clear a floor")
    func adjustment() {
        // Pale yellow on white: unreadable, and the classic generated-hue
        // failure the fixed avatar palette exists to avoid.
        let pale = Swatch(hex: "#ffe066") ?? .white
        let fixed = pale.adjusted(toContrast: 4.5, against: .white)

        #expect(fixed.contrastRatio(against: .white) >= 4.5)

        // Already fine, so untouched — moving it would throw away a choice the
        // user made for no reason.
        let strong = Swatch(hex: "#7d6b4f") ?? .black

        #expect(strong.adjusted(toContrast: 3, against: .white) == strong)
    }

    @Test("a hex colour round-trips through the parser the server's spelling uses")
    func hexParsing() {
        let accent = try? #require(Swatch(hex: "#7d6b4f"))

        #expect(accent == Swatch(125 / 255, 107 / 255, 79 / 255))
        #expect(Swatch(hex: "7D6B4F") == accent)
        // Refused rather than defaulted: substituting a colour nobody asked
        // for is the failure the server's own `invalidProperties` prevents.
        #expect(Swatch(hex: "#abc") == nil)
        #expect(Swatch(hex: "not a colour") == nil)
        #expect(Swatch(hex: "") == nil)
    }
}
