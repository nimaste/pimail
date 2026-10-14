/// A JMAP capability URN, as it appears in a Session object's `capabilities`
/// and in the `using` array of every request.
///
/// The distinction that matters: the server *advertises* more capabilities than
/// it accepts in `using`, and the two sets are not related. A URN the server
/// does not list in its own `Capability::SUPPORTED` fails the **whole request**
/// with `unknownCapability` — not the one call that wanted it — so a single
/// wrong entry here takes the app off the air rather than degrading a feature.
/// Hence ``supportedInUsing``, and the precondition in `RequestBuilder.add`.
///
/// **`urn:plmail:params:jmap:sync` is deliberately absent, and adding it would
/// be a regression.** The server does list it in `Capability::SUPPORTED`, so
/// declaring it would not be refused *today* — but it buys nothing and costs
/// something. It has no methods: `SessionBuilder` publishes backfill progress
/// under that URN in each account's `accountCapabilities` and nowhere else, and
/// `using` gates method dispatch only, so a client reads exactly the same
/// Session whether it declares the URN or not. Against a plMail predating the
/// commit that put SYNC in `SUPPORTED`, meanwhile, one entry in `using` refuses
/// **every** call in the batch with `unknownCapability` — the whole app, for a
/// capability nothing calls. A URN is worth declaring when a method needs it;
/// this one never will.
public enum Capability: String, Codable, CaseIterable, Sendable {
    case core = "urn:ietf:params:jmap:core"
    case mail = "urn:ietf:params:jmap:mail"
    case submission = "urn:ietf:params:jmap:submission"
    case push = "urn:plmail:params:jmap:push"
    /// APNs, which is a different thing to `push`.
    ///
    /// `push` is Web Push and carries a VAPID key; Web Push cannot reach a
    /// native iOS app, so registering an APNs device token needs its own
    /// advertisement in the Session.
    ///
    /// **Session-only, like `push`.** It was previously spelled
    /// `urn:de:plmail:params:jmap:apns` *and* listed in ``supportedInUsing``,
    /// which matched nothing on the server: `PushSubscription/set` is a Core
    /// method, so declaring this would have refused every request the moment
    /// entitlements stopped gating push. The registration method declares
    /// ``core`` and this URN exists only to be looked for in the Session.
    case apns = "urn:plmail:params:jmap:apns"
    /// plMail's calendar extension.
    ///
    /// Deliberately **not** `urn:ietf:params:jmap:calendars`: JMAP for
    /// Calendars is an unratified draft whose objects have been renamed
    /// between revisions, so the IETF URN would promise a contract that can
    /// change underneath a shipped client. This one is in the server's
    /// `Capability::SUPPORTED`, so unlike ``apns`` it really is declarable.
    case calendars = "urn:plmail:params:jmap:calendars"
    /// plMail's appearance extension — `Appearance/get` and `Appearance/set`.
    ///
    /// **Declarable**, unlike ``push`` and ``apns``: it is in the server's own
    /// `Capability::SUPPORTED`, so the two methods must name it in `using` or
    /// they are not dispatched at all. Getting that backwards is the expensive
    /// mistake in either direction — omitting it fails the two calls, and
    /// inventing a near-miss URN (`urn:ietf:…` rather than `urn:plmail:…`)
    /// fails **every** call batched with them.
    ///
    /// Absent from a Session is an ordinary, supported instance: a self-hosted
    /// server without the extension has no theme to serve and the client falls
    /// back to its local default rather than reporting an error.
    case appearance = "urn:plmail:params:jmap:appearance"

    /// The capabilities a request may declare. Advertised ≠ usable.
    public static let supportedInUsing: Set<Capability> = [
        .core, .mail, .submission, .calendars, .appearance,
    ]

    public var isSupportedInUsing: Bool {
        Self.supportedInUsing.contains(self)
    }
}
