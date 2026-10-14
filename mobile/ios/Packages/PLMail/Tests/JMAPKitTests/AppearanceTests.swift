import Foundation
import Testing

@testable import JMAPKit

/// The appearance extension, pinned at the two places it fails silently: the
/// bytes that go out, and the answer that comes back holding something other
/// than what was sent.
@Suite("Appearance")
struct AppearanceTests {

    // MARK: - Encoding

    /// The single most expensive mistake available here. `Appearance/get` and
    /// `Appearance/set` **refuse** an `accountId` with `invalidArguments`
    /// rather than ignoring it, and every other method in this package starts
    /// its arguments with one — so the habit is the bug.
    @Test("neither method sends an accountId, which the server refuses")
    func noAccountID() throws {
        var builder = RequestBuilder(maxCalls: 32)
        builder.add(AppearanceGet())
        builder.add(AppearanceSet(AppearancePatch(theme: "dark")))

        let body = try String(decoding: builder.encoded(), as: UTF8.self)

        #expect(body.contains("accountId") == false)
    }

    @Test("Appearance/get and /set encode exactly, declaring the appearance URN")
    func encoding() throws {
        var builder = RequestBuilder(maxCalls: 32)
        builder.add(AppearanceGet())
        builder.add(
            AppearanceSet(
                AppearancePatch(theme: "dark", previewLines: 2),
                ifInState: StateToken(rawValue: "9f2c1ab4d0e77c31")))

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self) == """
                {"methodCalls":[["Appearance/get",{},"c0"],\
                ["Appearance/set",{"ifInState":"9f2c1ab4d0e77c31",\
                "update":{"singleton":{"previewLines":2,"theme":"dark"}}},"c1"]],\
                "using":["urn:ietf:params:jmap:core","urn:plmail:params:jmap:appearance"]}
                """
        )
    }

    /// The three per-surface densities are the only three-state fields on the
    /// wire, and an explicit `null` is the **only** way back from an override.
    /// A synthesised encoder cannot say it, so this is the check that the
    /// hand-written one still does.
    @Test("an explicit null clears a density override and an absent one leaves it alone")
    func explicitNull() throws {
        var clearing = RequestBuilder(maxCalls: 32)
        clearing.add(AppearanceSet(AppearancePatch(sidebarDensity: .some(nil))))

        #expect(
            try String(decoding: clearing.encoded(), as: UTF8.self)
                .contains("\"sidebarDensity\":null"))

        var untouched = RequestBuilder(maxCalls: 32)
        untouched.add(AppearanceSet(AppearancePatch(theme: "dark")))

        // Not merely "not null" — the key must not appear at all. The server
        // treats any mentioned property as a change, so `sidebarDensity: null`
        // riding along on a theme change would silently drop the override.
        #expect(
            try String(decoding: untouched.encoded(), as: UTF8.self)
                .contains("sidebarDensity") == false)
    }

    @Test("setting a density writes the value rather than clearing it")
    func settingDensity() throws {
        var builder = RequestBuilder(maxCalls: 32)
        builder.add(AppearanceSet(AppearancePatch(listDensity: .some("compact"))))

        #expect(
            try String(decoding: builder.encoded(), as: UTF8.self)
                .contains("\"listDensity\":\"compact\""))
    }

    @Test("an empty patch is recognisable, so a pointless round trip can be skipped")
    func emptyPatch() {
        #expect(AppearancePatch().isEmpty)
        #expect(AppearancePatch(theme: "dark").isEmpty == false)
        #expect(AppearancePatch(sidebarDensity: .some(nil)).isEmpty == false)
    }

    // MARK: - Decoding

    @Test("Appearance/get decodes the singleton, nulls included")
    func decodeGet() throws {
        let result = try Fixture.decode("appearance-get", as: AppearanceGet.Result.self)
        let appearance = try #require(result.appearance)

        #expect(result.state == StateToken(rawValue: "9f2c1ab4d0e77c31"))
        #expect(appearance.id == Appearance.singletonID)
        #expect(appearance.accent == "#0e7490")
        #expect(appearance.radius == 0.75)
        #expect(appearance.listAvatars == true)

        // A null override is not the same as the global density, and reading
        // it as one is what makes the control impossible to switch off.
        #expect(appearance.listDensity == "compact")
        #expect(appearance.sidebarDensity == nil)
        #expect(appearance.readingDensity == nil)
    }

    /// `theme: "ocean"` is a value this client cannot draw. It must decode
    /// rather than throw: the server ships 39 themes and will ship more, and a
    /// client that fails to decode its own settings after a server upgrade is
    /// a client that cannot be used.
    @Test("a theme this build has never heard of decodes as data, not as a failure")
    func unknownVocabularyDecodes() throws {
        let result = try Fixture.decode("appearance-get", as: AppearanceGet.Result.self)

        #expect(try #require(result.appearance).theme == "ocean")
    }

    /// **Numerics clamp rather than refuse**, and the clamp comes back in
    /// `updated`. A caller that assumes the value it sent is the value that
    /// stuck desyncs its own sliders from the server permanently.
    @Test("a clamped value and a layout's seeded knobs both arrive in `updated`")
    func clampReport() throws {
        let result = try Fixture.decode("appearance-set-clamped", as: AppearanceSet.Result.self)
        let changes = try #require(result.serverSideChanges)

        #expect(changes.paneAlpha == 1.0)
        #expect(changes.previewLines == 2)
        #expect(changes.radius == 1.0)
        #expect(result.failure == nil)
        #expect(result.newState == StateToken(rawValue: "3b7710cc90aa1def"))
    }

    @Test("applying the response, not the request, is what the client ends up holding")
    func applyingTheResponse() throws {
        let stored = try #require(
            try Fixture.decode("appearance-get", as: AppearanceGet.Result.self).appearance)
        let result = try Fixture.decode("appearance-set-clamped", as: AppearanceSet.Result.self)

        // What a sloppy client sends and what a careful one ends up with.
        let patch = AppearancePatch(paneAlpha: 1.4, previewLines: 9)
        let optimistic = stored.applying(patch)

        #expect(optimistic.paneAlpha == 1.4)
        #expect(optimistic.previewLines == 9)

        let settled = optimistic.merging(try #require(result.serverSideChanges))

        #expect(settled.paneAlpha == 1.0)
        #expect(settled.previewLines == 2)
        // Untouched by either the patch or the report.
        #expect(settled.accent == "#0e7490")
        #expect(settled.listDensity == "compact")
    }

    @Test("a refused vocabulary comes back as a per-object error, not a thrown one")
    func refusal() throws {
        let result = try Fixture.decode("appearance-set-refused", as: AppearanceSet.Result.self)
        let failure = try #require(result.failure)

        #expect(failure.type == .invalidProperties)
        #expect(result.serverSideChanges == nil)
        // The state did not move, so the client's `ifInState` is still good.
        #expect(result.oldState == result.newState)
    }

    // MARK: - The Session

    @Test("the appearance capability decodes with its vocabularies and ranges")
    func sessionCapability() throws {
        let session = try Fixture.decode("session-appearance", as: Session.self)
        let capability = try #require(session.capabilities.appearance)

        #expect(capability.appearance?.theme == "paper")
        #expect(capability.appearance?.accent == "#7d6b4f")
        #expect(capability.themes.contains("ocean"))
        #expect(capability.layouts == ["flat", "boxed"])
        #expect(capability.layoutDefaults["boxed"]?.paneAlpha == 0.7)
        #expect(capability.range(for: "paneAlpha") == Session.NumericRange(min: 0.15, max: 1))
    }

    /// The published range exists so a client can clamp the same way the
    /// server does. Out of range is **not** an error to show anyone.
    @Test("a published range clamps to its nearest end rather than refusing")
    func clamping() throws {
        let session = try Fixture.decode("session-appearance", as: Session.self)
        let capability = try #require(session.capabilities.appearance)
        let alpha = try #require(capability.range(for: "paneAlpha"))
        let lines = try #require(capability.range(for: "previewLines"))

        #expect(alpha.clamping(1.4) == 1.0)
        #expect(alpha.clamping(0.0) == 0.15)
        #expect(alpha.clamping(0.6) == 0.6)
        #expect(lines.clamping(9) == 2)
        #expect(lines.clamping(-3) == 0)
    }

    /// **A server without the extension is an ordinary instance.** The
    /// original fixture has no appearance capability at all, and decoding it
    /// has to keep working — a self-hosted plMail without the extension is
    /// supported, and a client that treated its absence as a failure would
    /// refuse to log in to it.
    @Test("a session without the capability decodes, and simply has no appearance")
    func absentCapability() throws {
        let session = try Fixture.decode("session", as: Session.self)

        #expect(session.capabilities.appearance == nil)
        #expect(session.capabilities.core.maxCallsInRequest == 32)
    }

    /// A published vocabulary this build has not heard of, and a missing
    /// optional key, both have to survive: this object grows server-side.
    @Test("an unfamiliar or partial capability object still decodes")
    func toleratesPartialCapability() throws {
        let json = Data(
            """
            {"themes":["system","aurora"],"somethingNew":{"a":1}}
            """.utf8)
        let capability = try JSONDecoder().decode(
            Session.AppearanceCapabilities.self, from: json)

        #expect(capability.themes == ["system", "aurora"])
        #expect(capability.layouts.isEmpty)
        #expect(capability.ranges.isEmpty)
        #expect(capability.appearance == nil)
        #expect(capability.range(for: "paneAlpha") == nil)
    }
}
