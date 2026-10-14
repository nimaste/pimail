import Foundation

/// The user's appearance, as `Appearance/get` returns it.
///
/// **A singleton, and not per account.** Appearance hangs off the user, not a
/// mail account, so there is no `accountId` anywhere in this file — the server
/// *refuses* one with `invalidArguments` rather than ignoring it, which is why
/// neither method's `Arguments` has the field the rest of this package's
/// methods all start with. A user with three mailboxes has one theme.
///
/// **Every property is optional and nothing here is an enum.** Two separate
/// failures are being avoided. `Appearance/get` honours a `properties`
/// argument, so a partial read is a legitimate response rather than a
/// truncated one; and the theme vocabulary is 39 values and growing, so a
/// client that decoded `theme` as a Swift enum would stop being able to read
/// its own settings the first time the server shipped a new palette. Unknown
/// values are carried as strings and resolved to a default by the layer that
/// paints them.
///
/// The same all-optional shape is what lets ``AppearanceSet/Result/updated``
/// decode as this type: a clamp report is a partial object, and giving it a
/// second near-identical struct would be two things to keep in step.
public struct Appearance: Hashable, Sendable, Decodable, Identifiable {
    /// The only id this object ever has. Any other id is `notFound`.
    public static let singletonID = "singleton"

    /// Optional even though `/get` always returns it — RFC 8620 §5.1 makes
    /// `id` unconditional — because ``AppearanceSet/Result/updated`` decodes
    /// into this same type and a clamp report carries no id at all. A
    /// non-optional here would make every successful write fail to decode with
    /// `keyNotFound`, which is a confusing way to learn that a change worked.
    public var id: String?

    // MARK: - Palette

    /// One of 39 server-side values. Unrecognised is not an error: render the
    /// default and, above all, **never write a flattened value back**. A phone
    /// that read `ocean`, drew it as system dark and then saved `system` would
    /// destroy the user's choice in the browser.
    public var theme: String?
    /// `flat` or `boxed`. Setting it seeds the knobs below, which is why
    /// `Appearance/set` reports them back even when the patch did not name
    /// them.
    public var layout: String?
    /// **Read-only and derived** from the theme, from whether the user
    /// unlinked the mark, and only then from the stored column — it is the
    /// colourway the mark is actually *wearing*, not the stored field. Echoing
    /// it back unchanged is tolerated; changing it is refused. Excluded from
    /// the Session hint on purpose, so anything committed outside the app
    /// reads it from here.
    public var logoStyle: String?
    /// Six-digit hex, e.g. `#7d6b4f`. Malformed is refused, not defaulted —
    /// the server's own fallback would be a colour nobody asked for.
    public var accent: String?

    // MARK: - Pane treatment

    /// Clamped to 0.15…1.0.
    public var paneAlpha: Double?
    /// Clamped to 0…60.
    public var paneBlur: Int?
    /// In **rem**, clamped to 0.0…2.0. Panes only: a 2.0rem radius on a button
    /// is the mistake the server's own client documentation calls out.
    public var radius: Double?
    /// `comfortable`, `cosy` or `compact`.
    public var density: String?
    /// `full`, `minimal` or `none`.
    public var motion: String?

    // MARK: - Background

    /// `theme`, `preset`, `custom` or `solid`.
    public var backgroundKind: String?
    public var backgroundPreset: String?
    /// **Read-only.** A filename uploaded through the web settings pane and
    /// served from behind the session firewall: a JMAP client can neither
    /// upload one nor fetch it. Reported anyway, so a client seeing
    /// `backgroundKind: "custom"` can tell "the user chose a photo I cannot
    /// draw" from "this value is broken".
    public var backgroundFile: String?
    public var backgroundSolid: String?
    /// Clamped to 0.0…0.7.
    public var scrimAlpha: Double?

    // MARK: - Ink overrides

    /// Null means "use the theme's own ink", which is a different instruction
    /// from any colour. A client that substitutes its default here cannot tell
    /// the two apart and can never put the user back.
    public var inkColor: String?
    public var inkMuted: String?
    public var inkFaint: String?
    public var mainTint: String?
    /// Clamped to 0.15…1.0 when present.
    public var mainAlpha: Double?

    // MARK: - List and typography

    public var accountCorner: Bool?
    public var listAvatars: Bool?
    /// Clamped to 0…2.
    public var previewLines: Int?
    /// `subtle`, `standard` or `strong`.
    public var unreadEmphasis: String?
    /// `system`, `grotesk`, `serif` or `monospace`.
    public var fontFamily: String?
    /// Clamped to 0.875…1.25. **iOS deliberately does not offer this**:
    /// Dynamic Type owns text size on this platform, and a second scale on top
    /// of it produces sizes nobody tested.
    public var fontScale: Double?

    // MARK: - Per-surface density overrides

    /// Null is a **value**, not an absence: it means this surface follows the
    /// global ``density``, and it is the only way back from an override. Code
    /// that writes `sidebarDensity ?? density` anywhere on this path breaks the
    /// control permanently, because the override can then never be cleared.
    public var sidebarDensity: String?
    public var listDensity: String?
    public var readingDensity: String?

    public init() {}
}

// MARK: - Appearance/get

/// `Appearance/get` — the one object.
///
/// `ids: nil` returns it, which is the only call this client ever makes: there
/// is nothing to enumerate. `properties: nil` returns all 28, which is also
/// what this client wants — a partial read would have to be merged, and the
/// object is small.
///
/// **There is no `Appearance/changes` and there never will be.** `state` is an
/// `xxh128` of the object rather than a change-log sequence, so it is not
/// monotonic and cannot be paged from. A client that notices the token moved
/// re-fetches the one object, which is this single call.
public struct AppearanceGet: JMAPMethod {
    public static let name = "Appearance/get"
    public static let capability = Capability.appearance

    public struct Arguments: Encodable, Sendable {
        /// Nil for "the one object". A non-nil array containing anything other
        /// than ``Appearance/singletonID`` comes back in `notFound`.
        public var ids: [String]?
        /// Nil for all 28. Naming a property this server does not have is
        /// `invalidArguments` rather than a silently shorter response.
        public var properties: [String]?
    }

    /// **Not ``GetResult``**, and the difference is the whole point of the
    /// method: there is no `accountId` in the response, so decoding this into
    /// the shared type would fail on every call.
    public struct Result: Decodable, Sendable {
        /// A hash of the object. Re-fetch when it differs from the one held;
        /// do not attempt to order two of them.
        public var state: StateToken
        public var list: [Appearance]
        public var notFound: [String]

        /// The one object, or nil on a response that carried none.
        public var appearance: Appearance? { list.first }
    }

    public var arguments: Arguments

    public init(ids: [String]? = nil, properties: [String]? = nil) {
        arguments = Arguments(ids: ids, properties: properties)
    }
}

// MARK: - Appearance/set

/// A change to the appearance.
///
/// Only the properties this client can honour honestly are representable.
/// `fontScale` is absent because Dynamic Type owns text size on iOS;
/// `backgroundFile` and `logoStyle` are absent because they are read-only.
/// Making them unrepresentable turns a round trip that fails after the user
/// has moved a control into a compile error.
///
/// **Nullable properties are doubly optional.** `nil` means "leave it alone"
/// and `.some(nil)` means "clear it" — the server treats every mentioned
/// property as a change, so a synthesised encoder emitting `sidebarDensity:
/// null` on an unrelated patch would silently drop the user's override. This
/// is the same shape `MailboxSet.Patch` uses for `parentId` and for the same
/// reason.
public struct AppearancePatch: Encodable, Sendable, Hashable {
    public var theme: String?
    public var layout: String?
    public var accent: String?
    public var paneAlpha: Double?
    public var paneBlur: Int?
    public var radius: Double?
    public var density: String?
    public var motion: String?
    public var previewLines: Int?
    public var unreadEmphasis: String?
    public var fontFamily: String?
    public var accountCorner: Bool?
    public var listAvatars: Bool?

    /// `.some(nil)` puts the sidebar back on the global density; `nil` leaves
    /// the override alone. There is no third spelling that clears it.
    public var sidebarDensity: String??
    public var listDensity: String??
    public var readingDensity: String??

    public init(
        theme: String? = nil,
        layout: String? = nil,
        accent: String? = nil,
        paneAlpha: Double? = nil,
        paneBlur: Int? = nil,
        radius: Double? = nil,
        density: String? = nil,
        motion: String? = nil,
        previewLines: Int? = nil,
        unreadEmphasis: String? = nil,
        fontFamily: String? = nil,
        accountCorner: Bool? = nil,
        listAvatars: Bool? = nil,
        sidebarDensity: String?? = nil,
        listDensity: String?? = nil,
        readingDensity: String?? = nil
    ) {
        self.theme = theme
        self.layout = layout
        self.accent = accent
        self.paneAlpha = paneAlpha
        self.paneBlur = paneBlur
        self.radius = radius
        self.density = density
        self.motion = motion
        self.previewLines = previewLines
        self.unreadEmphasis = unreadEmphasis
        self.fontFamily = fontFamily
        self.accountCorner = accountCorner
        self.listAvatars = listAvatars
        self.sidebarDensity = sidebarDensity
        self.listDensity = listDensity
        self.readingDensity = readingDensity
    }

    private enum CodingKeys: String, CodingKey {
        case theme, layout, accent, paneAlpha, paneBlur, radius, density, motion
        case previewLines, unreadEmphasis, fontFamily, accountCorner, listAvatars
        case sidebarDensity, listDensity, readingDensity
    }

    /// Whether this patch would change anything. An empty `update` is a
    /// pointless round trip that still moves the state token.
    public var isEmpty: Bool { self == AppearancePatch() }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(theme, forKey: .theme)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(accent, forKey: .accent)
        try container.encodeIfPresent(paneAlpha, forKey: .paneAlpha)
        try container.encodeIfPresent(paneBlur, forKey: .paneBlur)
        try container.encodeIfPresent(radius, forKey: .radius)
        try container.encodeIfPresent(density, forKey: .density)
        try container.encodeIfPresent(motion, forKey: .motion)
        try container.encodeIfPresent(previewLines, forKey: .previewLines)
        try container.encodeIfPresent(unreadEmphasis, forKey: .unreadEmphasis)
        try container.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try container.encodeIfPresent(accountCorner, forKey: .accountCorner)
        try container.encodeIfPresent(listAvatars, forKey: .listAvatars)

        try Self.encodeNullable(sidebarDensity, forKey: .sidebarDensity, into: &container)
        try Self.encodeNullable(listDensity, forKey: .listDensity, into: &container)
        try Self.encodeNullable(readingDensity, forKey: .readingDensity, into: &container)
    }

    /// The three-state encoding the synthesised one cannot express: absent,
    /// explicit null, or a value.
    private static func encodeNullable(
        _ value: String??,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard let value else { return }

        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

/// `Appearance/set` — update the singleton.
///
/// `create` and `destroy` are answered with RFC 8620 §5.3's own `singleton`
/// SetError, so neither is offered here: a user has exactly one appearance and
/// resetting it means updating `"singleton"`.
///
/// **Apply the response, not the request.** Numeric properties are clamped
/// rather than refused, and the clamp lands in ``Result/updated`` — so a
/// caller that assumes the value it sent is the value that stuck desyncs its
/// sliders from the server. Setting `layout` does the same thing for a
/// different reason: a layout seeds four knobs the patch never named, and they
/// come back the same way.
public struct AppearanceSet: JMAPMethod {
    public static let name = "Appearance/set"
    public static let capability = Capability.appearance

    public struct Arguments: Encodable, Sendable {
        /// Honoured, and a mismatch is `stateMismatch` — which is how two
        /// devices editing the theme avoid silently overwriting each other.
        /// Nil skips the check.
        public var ifInState: StateToken?
        /// Keyed by ``Appearance/singletonID``. Any other key comes back in
        /// `notUpdated` as `notFound`.
        public var update: [String: AppearancePatch]
    }

    public struct Result: Decodable, Sendable {
        public var oldState: StateToken?
        public var newState: StateToken?

        /// **Properties the server changed beyond what was asked for**, keyed
        /// by object id, decoded as a partial ``Appearance``. A clamped slider
        /// and the knobs a layout seeded both arrive here, and null means
        /// "exactly what you sent".
        public var updated: [String: Appearance?]?
        public var notUpdated: [String: AppearanceSetError]?

        /// The clamps and seeded knobs for the singleton, if the server
        /// reported any.
        public var serverSideChanges: Appearance? {
            updated?[Appearance.singletonID] ?? nil
        }

        /// Why the change was refused, if it was.
        public var failure: AppearanceSetError? {
            notUpdated?[Appearance.singletonID]
        }
    }

    public var arguments: Arguments

    public init(_ patch: AppearancePatch, ifInState: StateToken? = nil) {
        arguments = Arguments(
            ifInState: ifInState, update: [Appearance.singletonID: patch])
    }
}

/// Why `Appearance/set` refused a patch.
///
/// `invalidProperties` is the one that matters and the one a caller can act
/// on: a closed vocabulary was sent a value it does not contain, or a colour
/// was not six hex digits. A numeric out of range is **not** here — that is
/// clamped and reported in `updated` — so nothing in this type should ever be
/// shown to a user as "that number is too big".
public struct AppearanceSetError: Hashable, Sendable, Decodable {
    public var type: MethodErrorType

    /// The server's own sentence, in untranslated English written for a
    /// developer. Diagnostic only — never put in front of a user.
    public var description: String?

    /// The offending property names, present on `invalidProperties`.
    public var properties: [String]?
}

// MARK: - Merging

extension Appearance {
    /// This object with every property `other` states written over it.
    ///
    /// **What ``AppearanceSet/Result/serverSideChanges`` is applied with.**
    /// Numerics are clamped rather than refused and layouts seed four knobs
    /// the patch never named, so the value a client sent is routinely not the
    /// value that stuck — and a client that assumes otherwise leaves its
    /// sliders sitting at numbers the server does not hold. `nil` in `other`
    /// means "not mentioned", which is the only reading available: a partial
    /// object cannot distinguish an omitted property from one explicitly set
    /// to null, and the server only ever sends this map to report what it
    /// *did* change.
    public func merging(_ other: Appearance) -> Appearance {
        var merged = self

        merged.theme = other.theme ?? theme
        merged.layout = other.layout ?? layout
        merged.logoStyle = other.logoStyle ?? logoStyle
        merged.accent = other.accent ?? accent
        merged.paneAlpha = other.paneAlpha ?? paneAlpha
        merged.paneBlur = other.paneBlur ?? paneBlur
        merged.radius = other.radius ?? radius
        merged.density = other.density ?? density
        merged.motion = other.motion ?? motion
        merged.backgroundKind = other.backgroundKind ?? backgroundKind
        merged.backgroundPreset = other.backgroundPreset ?? backgroundPreset
        merged.backgroundFile = other.backgroundFile ?? backgroundFile
        merged.backgroundSolid = other.backgroundSolid ?? backgroundSolid
        merged.scrimAlpha = other.scrimAlpha ?? scrimAlpha
        merged.inkColor = other.inkColor ?? inkColor
        merged.inkMuted = other.inkMuted ?? inkMuted
        merged.inkFaint = other.inkFaint ?? inkFaint
        merged.mainTint = other.mainTint ?? mainTint
        merged.mainAlpha = other.mainAlpha ?? mainAlpha
        merged.accountCorner = other.accountCorner ?? accountCorner
        merged.listAvatars = other.listAvatars ?? listAvatars
        merged.previewLines = other.previewLines ?? previewLines
        merged.unreadEmphasis = other.unreadEmphasis ?? unreadEmphasis
        merged.fontFamily = other.fontFamily ?? fontFamily
        merged.fontScale = other.fontScale ?? fontScale
        merged.sidebarDensity = other.sidebarDensity ?? sidebarDensity
        merged.listDensity = other.listDensity ?? listDensity
        merged.readingDensity = other.readingDensity ?? readingDensity

        return merged
    }

    /// This object with a patch optimistically applied, before the server has
    /// answered.
    ///
    /// Optimistic on purpose — a theme picker that waits a round trip before
    /// repainting reads as a broken control on a phone over a slow link. The
    /// answer is then merged over the top through ``merging(_:)``, so a clamp
    /// or a seeded knob corrects the guess rather than the guess standing.
    ///
    /// The three densities are the only three-state fields: `.some(nil)`
    /// clears the override back to the global density, and collapsing that to
    /// `nil` here would make the control impossible to switch off.
    public func applying(_ patch: AppearancePatch) -> Appearance {
        var applied = self

        applied.theme = patch.theme ?? theme
        applied.layout = patch.layout ?? layout
        applied.accent = patch.accent ?? accent
        applied.paneAlpha = patch.paneAlpha ?? paneAlpha
        applied.paneBlur = patch.paneBlur ?? paneBlur
        applied.radius = patch.radius ?? radius
        applied.density = patch.density ?? density
        applied.motion = patch.motion ?? motion
        applied.previewLines = patch.previewLines ?? previewLines
        applied.unreadEmphasis = patch.unreadEmphasis ?? unreadEmphasis
        applied.fontFamily = patch.fontFamily ?? fontFamily
        applied.accountCorner = patch.accountCorner ?? accountCorner
        applied.listAvatars = patch.listAvatars ?? listAvatars

        if let sidebarDensity = patch.sidebarDensity { applied.sidebarDensity = sidebarDensity }
        if let listDensity = patch.listDensity { applied.listDensity = listDensity }
        if let readingDensity = patch.readingDensity { applied.readingDensity = readingDensity }

        return applied
    }
}
