import Foundation
public import JMAPKit
import OSLog
import Observation

/// The user's server-side appearance, read and written.
///
/// **An instance without the extension is a supported instance, not an
/// error.** plMail is self-hosted; somebody running a build without
/// `urn:plmail:params:jmap:appearance` has no theme to serve, and the right
/// answer is a client that keeps its own default palette and hides the picker
/// — not a red banner about a capability nobody asked for. That is what
/// ``isSupported`` is for, and it is checked before either method is ever
/// added to a request: naming an undeclared capability in `using` would refuse
/// the **whole** batch with `unknownCapability`, taking every unrelated call
/// with it.
///
/// **Two reads, and only one of them is truth.** The Session carries a compact
/// `{theme, layout, accent, density}` hint so the chrome can be painted on the
/// first frame instead of flashing the wrong palette, but the Session's `state`
/// is a hash of the user's account ids and does not move when a theme changes
/// — so a cached Session holds a stale hint indefinitely. ``hint`` is
/// published for the splash frame; ``appearance`` is what anything else reads.
@MainActor
@Observable
public final class AppearanceSettings {
    /// The authoritative read, or nil before one has landed.
    public private(set) var appearance: Appearance?

    /// The Session's compact hint. Available before any request is sent, and
    /// superseded the moment ``appearance`` arrives.
    public private(set) var hint: Session.CompactAppearance?

    /// The vocabularies and clamp ranges the server published, so a picker is
    /// drawn from the server's list rather than from a copy of it that goes
    /// stale. Nil on an instance without the extension.
    public private(set) var vocabulary: Session.AppearanceCapabilities?

    /// The object hash. Not a sequence — do not order two of them. Sent as
    /// `ifInState` on the next write so two devices editing the theme are told
    /// about the conflict rather than silently overwriting each other.
    public private(set) var state: StateToken?

    /// False on a server without the extension. Every call site must check it:
    /// the picker is hidden, not disabled, because a control that cannot ever
    /// work is worse than no control.
    public private(set) var isSupported = false

    /// True until the first load settles, so a screen shows a placeholder
    /// rather than an empty state it would immediately replace.
    public private(set) var isLoading = true

    /// A read that could not reach the server. The last-known appearance still
    /// stands — a theme is not worth blanking a screen over — so this is a
    /// note, not a replacement for it.
    public private(set) var loadFailure: String?

    /// A write the server refused, already reduced to something a caller can
    /// act on. **Never a clamped number**: those are applied, not reported,
    /// because a value out of range is not an error to put in front of a user.
    public private(set) var saveFailure: SaveFailure?

    /// Why a write failed, in the only three flavours a caller can do anything
    /// about.
    public enum SaveFailure: Hashable, Sendable {
        /// The server refused a value. Carries the property names it named, so
        /// a screen can point at the control rather than at the screen.
        case refused(properties: [String])
        /// Somebody else changed the appearance first — another device, or the
        /// web UI in another tab. The fix is to re-read and let the user look
        /// again, never to retry the same patch with the check removed.
        case changedElsewhere
        /// The server could not be reached. Retryable, unlike the two above.
        case unreachable
    }

    private let client: JMAPClient
    private let logger = Logger(subsystem: "de.plmail", category: "appearance")

    public init(client: JMAPClient) {
        self.client = client
    }

    // MARK: - Reading

    /// Reads the Session hint, then the object itself.
    ///
    /// In that order and in one method because the two are one story: the hint
    /// is what the first frame paints and the read is what corrects it, and
    /// separating them into two entry points is how a caller ends up painting
    /// from the hint forever.
    public func load() async {
        defer { isLoading = false }

        let session: Session

        do {
            session = try await client.session()
        } catch {
            loadFailure = String(describing: error)
            logger.warning("Session unavailable, keeping local appearance")

            return
        }

        adopt(session)

        guard isSupported else { return }

        await refresh()
    }

    /// Takes the Session's hint and vocabularies without a request.
    ///
    /// Separate from ``load()`` so a caller that already holds a Session — the
    /// app's composition root does — can paint the first frame without waiting
    /// on anything.
    public func adopt(_ session: Session) {
        let capabilities = session.capabilities.appearance

        isSupported = capabilities != nil
        vocabulary = capabilities
        hint = capabilities?.appearance
    }

    /// Fetches the one object.
    ///
    /// There is no `Appearance/changes` and there never will be: `state` is a
    /// hash rather than a sequence, so the only correct response to a token
    /// that moved is this — one call for one object.
    public func refresh() async {
        guard isSupported else { return }

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(AppearanceGet())
            let results = try await client.send(builder)
            let result = try results.result(of: call)

            state = result.state
            appearance = result.appearance
            loadFailure = nil
        } catch {
            loadFailure = String(describing: error)
            logger.warning("Appearance/get failed, keeping the local palette")
        }
    }

    // MARK: - Writing

    /// Applies a patch, then adopts what the server actually stored.
    ///
    /// **The response is the truth, not the request.** Numerics are clamped
    /// rather than refused and a `layout` seeds four knobs the patch never
    /// named, so the value sent is routinely not the value held — and a client
    /// that assumes otherwise leaves its own controls sitting at numbers the
    /// server does not have. The patch is applied optimistically first so the
    /// UI does not wait a round trip to repaint, and the server's own
    /// `updated` map is merged over the top.
    ///
    /// - Returns: Whether the change stuck. Check ``saveFailure`` for why not.
    @discardableResult
    public func save(_ patch: AppearancePatch) async -> Bool {
        guard isSupported, patch.isEmpty == false else { return false }

        saveFailure = nil

        let previous = appearance
        appearance = (previous ?? Appearance()).applying(patch)

        do {
            var builder = RequestBuilder(session: try await client.session())
            let call = builder.add(AppearanceSet(patch, ifInState: state))
            let results = try await client.send(builder)
            let result = try results.result(of: call)

            if let failure = result.failure {
                appearance = previous
                saveFailure = .refused(properties: failure.properties ?? [])
                logger.warning(
                    "Appearance/set refused: \(failure.type.rawValue, privacy: .public)")

                return false
            }

            if let changes = result.serverSideChanges {
                appearance = appearance?.merging(changes)
            }

            state = result.newState

            return true
        } catch let error as JMAPError {
            appearance = previous
            saveFailure = Self.failure(for: error)

            // A mismatch means somebody else moved first. Re-reading is the
            // only correct response — retrying the same patch without the
            // guard is how one device silently overwrites another.
            if saveFailure == .changedElsewhere { await refresh() }

            return false
        } catch {
            appearance = previous
            saveFailure = .unreachable

            return false
        }
    }

    private static func failure(for error: JMAPError) -> SaveFailure {
        if case .methodFailed(let type, _, _) = error {
            switch type {
            case .stateMismatch: return .changedElsewhere
            case .invalidProperties: return .refused(properties: [])
            default: return .unreachable
            }
        }

        return .unreachable
    }
}
