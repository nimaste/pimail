# House style, for whoever writes the next feature

Written for the agents bringing this app up to parity with plMail for Android.
Read this before you write a line of Swift here. It is a description of what the
codebase already does, not a proposal — matching it is cheaper than arguing with
it, and every convention below exists because departing from it broke something.

The server's `pl_mail/docs/CLIENT_DEVELOPMENT.md` is the specification this app
implements. `pl_mail/` and `pl_mail_android/` are **read-only**: never edit them.
Anything you want to say about them goes in a `.md` file in this directory.

---

## Where code goes

All real code lives in the SPM package. `App/` is deliberately thin — `@main`,
the shell, xcconfigs — and a new feature means new files under
`Packages/PLMail/Sources/PLMail{Core,UI}/<Feature>/`, **not** under `App/`.

| Path | What | Rule |
|---|---|---|
| `JMAPKit/` | Transport and codec | Foundation only. No SwiftUI, no SwiftData. |
| `PLMailCore/` | Persistence, sync, search, Keychain | Depends on JMAPKit. |
| `PLMailUI/` | Theme tokens and views | Depends on PLMailCore. |
| `JMAPTestSupport/` | `FakeMailServer`, `MockTransport` | Under `Sources/` only so two test targets can share it. Never links into the app. |

`Package.swift` is `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]`,
`platforms: [.iOS(.v26), .macOS(.v26)]`, `defaultLocalization: "en"`. macOS is
declared purely so `swift test` runs on the host without booting a simulator.

The manifest is heavily commented with rationale. That is itself the convention —
see the last section.

---

## JMAP methods

Every method is a struct conforming to `JMAPMethod`:

```swift
public protocol JMAPMethod: Sendable {
    associatedtype Arguments: Encodable & Sendable
    associatedtype Result: Decodable & Sendable
    static var name: String { get }        // "Email/query"
    static var capability: Capability { get }
    var arguments: Arguments { get }
}
```

Copy `JMAPKit/Methods/EmailMethods.swift` verbatim in shape: `public static let
name`, `public static let capability`, a nested `public struct Arguments:
Encodable, Sendable` whose `private enum CodingKeys` maps Swift `ID` casing onto
wire `Id` casing, a nested `Result` (or `public typealias Result =
GetResult<Email>` / `ChangesResult<EmailID>`), and a public `init` that fills
`arguments`.

An argument that can be a back-reference is `Argument<[EmailID]>` with a
hand-written `encode(to:)`, because `.reference` changes the JSON *key* to
`#ids`.

**There is no method registry.** `RequestBuilder.add(_:)` returns a typed
`CallHandle<Method>`, assigns call ids `c0, c1, …`, and unions
`Method.capability` into `using`. Results are decoded lazily through
`results.result(of: handle)` / `results.failure(of: handle)`.

**Identifiers are phantom-typed.** `Identifier<Namespace>` with
`public typealias EmailID = Identifier<EmailNamespace>`. `MailboxID` and
`LabelID` are deliberately not interchangeable. `StateToken` is its own type with
`static let initial = StateToken(rawValue: "0")`.

**Errors are one enum split by what the caller should do**, not by HTTP status:
`JMAPError.notAuthenticated`, `.requestFailed`, `.methodFailed`,
`.unexpectedStatus`, `.unreachable`, `.untrustedCertificate`,
`.malformedResponse`, `.noSuchCall`, plus computed `isRetryable`,
`requiresResync`, `isProgrammerError`. `MethodErrorType` keeps an `.other(String)`
escape hatch so an unknown server error is data, not a crash.

`JMAPClient` is an `actor`, not `@MainActor`. Session fetch is single-flighted
through a stored `Task`; `RequestGate` supplies concurrency permits read from the
live `Session`.

---

## The store

SwiftData. `PLMailCore/Store/`.

**The governing rule, in a banner comment at the top of `SchemaV1.swift`:
everything here is a cache.** Nothing may be stored that isn't reconstructible
from the server. That is what licenses `MailStack.migrationPlan` being `nil` and
any open failure deleting `default.store`, `-wal`, `-shm` and re-syncing. It is
only safe while it stays true, so the two irreplaceable things live elsewhere on
purpose: the credential in the Keychain, and unsent mail in Application Support
under `plmail-outbox/`. **Do not put anything irreplaceable in the store.**

- `SchemaV1: VersionedSchema`; `@Model public final class StoredX` with
  `#Unique<StoredX>([\.uid])` and defaulted stored properties.
- Composite keys via `enum StoreKey` — `account(server:account:)` → `"\(server)/\(account)"`,
  `object(accountKey:id:)` → `"\(accountKey)#\(id)"`.
- `@ModelActor public actor SyncStore` is **the only writer**. Saves are batched
  per sync unit; every mutating method is `public func … throws` ending in
  `try modelContext.save()`.
- **`@Model` classes never cross an actor boundary.** `Store/Snapshots.swift`
  defines `AccountSnapshot`, `MailboxSnapshot`, `FeedEntrySnapshot`,
  `MessageSnapshot`, `IdentitySnapshot` — all `Hashable, Sendable, Identifiable`
  with `public var id: String`. A new feature that stores anything needs a
  snapshot type too.

---

## Sync

Two halves, kept apart deliberately: **`UnifiedFeed` owns ordering, `DeltaSync`
owns objects.**

Cursors are per JMAP type on `StoredAccount` (`emailState`, `threadState`,
`mailboxState`). `"0"` is always answerable, so a fresh account starts at
`.initial` rather than nil. `DeltaSync.pull` loops `Email/changes`
(`maxChanges: 256`, `maxLoops = 40`) until `hasMoreChanges` clears, hydrating in
chunks of 100. `catch let error as JMAPError where error.requiresResync` →
`clearCursors` and re-page; that is the **only** path that drops a cursor.

**Paging is by date keyset, never by `position`.** `before: <lastReceivedAt>`,
`position: 0` always, with `boundaryIDs` tracked because `before` is strict `<`.
The server's `EmailQueryRunner` has no SQL `LIMIT` — it materialises every
matching row in PHP and slices, so `position: 5000` costs exactly what
`position: 0` costs: the whole mailbox, on somebody's NAS. The feed cursor
advances **on emit, not on fetch**.

Property sets live as statics on the method: `EmailGet.listRowProperties`,
`EmailGet.readerProperties`.

---

## Concurrency, observation, DI

- **`@Observable` everywhere.** There is no `ObservableObject` or `@Published` in
  this codebase and there should not be one. The pattern is
  `@MainActor @Observable public final class X`, state as
  `public private(set) var`, with a nested `public enum Status: Equatable, Sendable`.
- **Actors for I/O**: `actor JMAPClient`, `actor DeltaSync`, `actor UnifiedFeed`,
  `@ModelActor actor SyncStore`. UI-facing coordinators are `@MainActor @Observable`.
- **DI is plain initialiser injection.** No container, no property wrappers, no
  protocol-per-service — the one exception is `any JMAPTransport`, which exists so
  `MockTransport` can be swapped in. Views take collaborators as `let` init
  parameters and store them in `@State` via `_x = State(wrappedValue:)` in `init`.
  `AppModel` is the composition root. The handful of `.shared` singletons
  (`SharedMailStore`, `IntentRouter`, `AppearancePreference`, `RecentSearches`)
  each carry a comment justifying themselves; do not add one without the same.
- Logging: `private let logger = Logger(subsystem: "de.plmail", category: "…")`,
  existing categories `store`, `sync`, `delta`, `feed`, `shared`. Interpolations
  state `privacy:` explicitly.

---

## Design tokens — use these names, do not invent a parallel set

There is no asset catalogue and no numeric spacing-scale type. Tokens are Swift
enums of statics in `PLMailUI/Theme/`.

`PanelStyle` — `cornerRadius: CGFloat = 20`, `inset: CGFloat = 10`, and the
colours `surface`, `window`, `hairline`. Every dual-appearance token is built
with the helper `extension Color { init(light: Color, dark: Color) }`. View
modifiers: `messageCard()`, `mailPane(isSeparated:)`, `iconOnly(when:)`.

`ActionTint` — `archive`, `readState`, `star`, `spam`, `destructive`. Literal
RGB, walked down in lightness until white text clears 4.5:1.

`AvatarPalette` — a fixed 12-colour array (terracotta, clay, mustard, sage,
eucalyptus, dusty blue, periwinkle, heather, mauve, dusty rose, stone, taupe),
indexed by a hand-written FNV-1a hash of the lowercased address mod 12, because
Swift's `hashValue` is per-process seeded. **The order is unchanged and must stay
unchanged** — changing it repaints every avatar in the app.

`ResolvedTheme` is `Equatable, Sendable`, injected as
`extension EnvironmentValues { @Entry public var theme: ResolvedTheme = .placeholder }`.

**Typography is semantic system fonts only.** No custom scale. Sizes that must
scale use `@ScaledMetric(relativeTo: .caption2)`.

**Localisation: never `Text("literal")`.** Always `Text(.ui("…"))`, where
`Localization.ui(_:)` binds `bundle: .atURL(Bundle.module.bundleURL)` — SwiftUI
would otherwise resolve against `Bundle.main` and silently fall through to
English. Every new key goes in **both** `en.lproj` and `de.lproj` of the owning
module, or `CatalogueCoverageTests` fails.

---

## Accessibility is not a later pass

The existing code does all of this and new code is expected to match:

- `.accessibilityElement(children: .combine)` plus an explicit
  `.accessibilityLabel(…)` on every composed row.
- `.accessibilityAddTraits(.isButton)`, `[.isButton, .isSelected]` for toggles,
  `.accessibilityValue(…)` for tri-state.
- **Custom actions instead of hidden gestures.** A swipe or long-press that is
  the only route to an action is a bug: `ThreadRowView` exposes Star/Unstar and
  Select/Deselect as `.accessibilityAction(named:)`.
- Decorative things hidden — `SenderAvatar` is `.accessibilityHidden(true)`,
  because the initials carry nothing the row does not already say.
- Dynamic Type: read `@Environment(\.dynamicTypeSize)` and branch on
  `isAccessibilitySize`. Rows restack rather than truncate; the reply bar drops
  to icons via `iconOnly(when:)` rather than hyphenating a word inside a pill.
- Hardware keyboards are first-class: `.keyboardShortcut`, with a hidden `Button`
  in `.background` carrying the `⌘` variant so both routes hit one action.

---

## iPad

`PLMailUI/MailView.swift` is the single shell for both idioms: one
`NavigationSplitView(columnVisibility:) { sidebar } content: { list } detail: { reader }`.
`@Environment(\.horizontalSizeClass)`, `isSeparated = sizeClass != .compact`,
`.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)` on the sidebar,
`.mailPane(isSeparated:)` closing each column (a no-op on compact, by design).
Compact push is driven manually through a `Binding<ThreadRef?>` because rows are
`Button`s rather than `List(selection:)`.

A new top-level feature must decide where it sits in that shell before it is
written, not after.

---

## Tests

**swift-testing**, not XCTest — the only XCTest files are the two UITests.
`@Suite("Name") struct XTests`, `@Test("a sentence describing the guarantee")`,
`#expect`, `try #require` for unwrapping, `@testable import`. Test names are
sentences about behaviour, which is why the suite reads as documentation.

No snapshot tests. Fakes instead: `MockTransport` for canned bodies,
`FakeMailServer` for anything that must actually page. Store tests use
`MailStack.makeContainer(inMemory: true)`. JSON fixtures live in
`Tests/JMAPKitTests/Fixtures/`.

`.swift-format` in `Tests/` and `JMAPTestSupport/` relaxes `NeverForceUnwrap` and
`NeverUseForceTry`. **Shipping code forbids both.**

Baseline to keep green: `swift test --package-path Packages/PLMail`.

---

## Prose, in code and in docs

British spelling — catalogue, behaviour, colour. Plain declaratives. Say *why*
and *what it costs*, and name the failure mode a decision avoids.

**The single strongest convention: every type, every non-obvious property and
every constant carries a `///` comment explaining the failure it prevents, not
what it does.** The representative example:

> `/// **Always 0 in this client.** `EmailQueryRunner` has no SQL `LIMIT`: it
> materialises every matching row in PHP and slices, so `position: 5000` costs
> exactly what `position: 0` costs — the whole mailbox, on someone's NAS.`

`.swift-format` enforces `lineLength: 100`, 4 spaces, `NeverForceUnwrap`,
`NeverUseForceTry`, `NeverUseImplicitlyUnwrappedOptionals`, `OrderedImports`,
`UseTripleSlashForDocumentationComments`, `ValidateDocumentationComments`. Also
idiomatic here: `x.isEmpty == false` rather than `!x.isEmpty`, `// MARK: -`
dividers, `#if os(iOS)` around every UIKit-touching PLMailUI file so the macOS
test host still builds, and `public import PLMailCore` where a public API
re-exports it.

Docs in this repo follow `DEVELOPING.md` and `WHATS-LEFT.md`: an H1, a framing
sentence about who the document is for, hard numbers for current state, `---`
between sections, H2s that are claims rather than categories, **bolded lead-in
sentences** doing the work of H3s, tables for mappings, and sources cited as
relative links or bare backticked paths.

Run before you hand anything back:

```bash
swift format lint --strict --recursive App Packages
```
