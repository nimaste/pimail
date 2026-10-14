# Parity 04 — settings, accounts, appearance, notifications, push, diagnostics, onboarding

Scope: settings shell, accounts, appearance/theming, language, notifications, push (incl. the push
log), diagnostics, onboarding/pairing, credential storage, certificate trust, background refresh,
error/retry surfaces.

Sources read: `pl_mail_android/feature/settings/`, `feature/onboarding/`, `core/datastore/`,
`core/notifications/`, `core/data/Push*.kt`, `core/data/AppLanguages.kt`,
`core/designsystem/Tokens.kt`, `pl_mail_android/docs/{REMAINING,SERVER_REQUESTS}.md`;
`pl_mail_ios/Packages/PLMail/Sources/` (`PLMailUI/Settings/`, `PLMailUI/Onboarding/`,
`PLMailUI/Theme/`, `PLMailCore/{Auth,Onboarding,Push,Sync}/`, `JMAPKit/Client/ServerTrust.swift`,
`JMAPKit/Protocol/Capability.swift`, `JMAPKit/EventSource/`), `pl_mail_ios/App/`,
`pl_mail_ios/Widget/`, `pl_mail_ios/docs/{PUSH,WHATS-LEFT}.md`; server **`origin/main`** as below.

## Server version note

**The `pl_mail/` working tree in this workspace is checked out at a stale commit** (`71d5474`,
2026-07-31). The current server is **`origin/main` (`132c1bf`, "release: v0.1.9")**, which is what
the Android client is built against. Every server fact in this document was read from `origin/main`,
not from the working tree. An earlier draft of this file drew three wrong conclusions from the stale
tree (no `Appearance` API, no FCM, no sync capability); those are corrected here.

Read server files read-only, without checking anything out and without fetching:

```
git show origin/main:src/Jmap/Method/Settings/AppearanceSetMethod.php
git show origin/main:src/Jmap/Mapper/AppearanceMapper.php
git show origin/main:src/Jmap/Push/PushSenderRegistry.php
git show origin/main:src/Jmap/README.md
```

What is on `origin/main` and absent from the stale tree, all of it in this domain:

| Path | What it is |
|---|---|
| `src/Jmap/Method/Settings/AppearanceGetMethod.php`, `AppearanceSetMethod.php` | The theme singleton, over JMAP. |
| `src/Jmap/Mapper/AppearanceMapper.php` | The one place the wire vocabulary is defined. |
| `src/Jmap/Protocol/Capability.php:67` | `urn:plmail:params:jmap:sync`, plus `…:appearance`, `…:calendars`, `…:contacts`. |
| `src/Jmap/Push/{FcmSender,FcmSettings,FcmAccessTokenProvider,PushSenderRegistry,PushDeliveryRecorder}.php` | A **pluggable multi-transport** push sender side, and a delivery log. |

Never modify `pl_mail/` or `pl_mail_android/`.

## Summary

iOS is at rough parity on **onboarding, pairing, certificate trust, credential storage and
background refresh** — ahead of Android in several of those — and materially behind on
**notifications, appearance, push and account preferences**.

In priority order:

1. **P0 — an expired app password deletes the offline mailbox.**
   `MailSyncService.requestReauthentication()` → `AppModel.signOut()` (`App/AppModel.swift:99`),
   and `signOut()` deletes the Keychain item **and** runs `SyncStore.deleteEverything()`. A revoked,
   rotated or once-mistyped credential therefore destroys every cached message and every queued
   draft, and drops the user at onboarding with no explanation. Offline mail is this app's headline
   feature and a 401 is not consent to delete it. Android never destroys anything for this: the
   server publishes `attentionKind: "account_reconnect"` and the client draws it. Spec in
   [gap note 1](#1-p0-re-authentication-must-not-delete-the-mailbox).

2. **Zero local notifications, and nothing gates them.** Android has per-account channels,
   `MessagingStyle` conversation rows, group summaries with counts, inline reply via `RemoteInput`
   with sending/failure/retry states, archive/mark-read actions, dedupe, and a per-category/per-label
   preference screen with Gmail's defaults. iOS posts **no notification of any kind** — the only
   `UserNotifications` call in the tree is `UNUserNotificationCenter.requestAuthorization` at
   `App/PushDelegate.swift:108`. Local notifications need no APNs key, no App Group and no paid
   team. This is unimplemented work, not entitlement-blocked work.

3. **The server's theme API exists and iOS ignores it.** `Appearance/get` and `Appearance/set` are
   real on `origin/main`, behind `urn:plmail:params:jmap:appearance`, and the Session already carries
   a compact hint plus every closed vocabulary and numeric range. `PLMailUI/Theme/ThemeEnvironment.swift`
   still holds `ResolvedTheme` as an empty placeholder whose doc comment says it is waiting for
   "the server once it exposes `Appearance` over JMAP". It does. This moves from "deliberately
   reduced" to a real, buildable gap — see [gap note 3](#3-appearance-the-server-api-exists-now).

4. **Push: the sender side is pluggable, so the ask is small and concrete.**
   `PushSenderRegistry` is built from an *iterable of tagged senders* keyed by `transport()->value`;
   `PushDispatcher` resolves a sender per subscription row and never names one. Android is served by
   `FcmSender` and browsers/UnifiedPush by `WebPushSender` — two implementations of one interface,
   sharing nothing but the JSON. Adding APNs is one enum case, one class and one create-shape; the
   dispatcher, the delivery log and the verification handshake come for free. iOS's current client
   half is built but aims at an invented capability the server refuses. See
   [gap note 5](#5-push-the-precise-server-side-request) for the actionable request and the
   `using`-array bug it exposes.

5. **Two onboarding security holes.** No cleartext warning before an app password crosses an `http`
   connection (`ServerAddress.isCleartext` is consumed only by Diagnostics, i.e. after the secret
   has already gone), and `ServerAddress.parse` clears `query` and `fragment` but **not**
   `user`/`password`, so `https://me:hunter2@nas.local` is accepted and baked into every request's
   base URL. Android rejects the latter explicitly (`ParsedAddress.CredentialsInAddress`).

Where iOS is ahead: a confirmed, explained sign-out; a **Remote images** screen that can revoke a
per-sender permission Android can only ever grant; a **Sending addresses** editor;
`Copy diagnostics` producing a deliberately unlocalised paste-able report; server limits read live
from the Session; Keychain storage with `kSecAttrAccessibleAfterFirstUnlock` and
`kSecAttrSynchronizable = false`; and a `BGAppRefreshTask` whose earliest-begin date is pulled
forward by the outbox's next due send.

Server capabilities **neither** client uses: `Core/echo` (`JMAPKit/Methods/CoreMethods.swift` defines
`CoreEcho` and nothing calls it — the cheapest possible "is the server answering" probe for
diagnostics) and `eventSourceUrl?closeafter=state`, one StateChange then an immediate close, which
is the cheap resync a foreground or post-wake refresh wants instead of holding a PHP worker
(`EventSourceClient.swift:113` hard-codes `closeafter=no`). Used by Android and not by iOS:
`PushSubscription/get`, `Appearance/get|set`, and the `urn:plmail:params:jmap:sync` account
capability.

## Gaps

| Feature | Android source | iOS status | Blocked on entitlement? | Notes |
|---|---|---|---|---|
| Non-destructive re-authentication | server `attentionKind: account_reconnect`, `AccountsScreen.attentionSentence()` | **Broken — P0** | No | `App/AppModel.swift:99` wipes the Keychain *and* the store on any 401. |
| New-mail notifications at all | `core/notifications/MailNotifier.kt`, `ConversationNotification.kt` | **Missing** | No | Local `UNNotificationRequest`s need nothing paid. New `App/MailNotifications.swift`. |
| Notification grouping / summary counts | `MailNotifier.summary`, `SummaryContent.kt` | **Missing** | No | iOS answer is `threadIdentifier` + `summaryArgument`, not a hand-built summary. |
| Notification actions (archive, mark read) | `NotificationActions.kt` | **Missing** | No | `UNNotificationCategory` + non-`.foreground` `UNNotificationAction`. |
| Inline reply from the shade | `InlineReply.kt` (`ReplyNotifications`, retry, failure row) | **Missing** | No | `UNTextInputNotificationAction`, sent through the existing `Outbox`. |
| Per-account notification channels | `MailChannels.kt` | **N/A by platform** | — | iOS has no channels; mute is an in-app preference plus `interruptionLevel`. |
| Per-category / per-label notification switches | `NotificationsScreen.kt`, `core/datastore/NotificationPrefsStore.kt` | **Missing** | No | Needs a `NotificationsView` and a tri-state store (on / off / never said). |
| Per-account "notify me" mute | `AccountsScreen.kt`, `AccountPrefsStore.kt` | **Missing** | No | |
| Notification permission asked at a sensible moment | `MailNotifier.isPermitted()`, `PushDelegate.requestAuthorization` | **Partial** | No | Gated behind `push.isSupported()`, which is false everywhere today — so the prompt never fires at all. |
| Notification dedupe across resyncs | `core/datastore/NotifiedMessageStore.kt` | **Missing** | No | Without it, one cursor-less resync posts a hundred banners. |
| Appearance: read the account's theme | `core/jmap/methods/AppearanceMethods.kt`, `core/data/AppearanceRepository.kt` | **Missing** | No | `Appearance/get` exists on `origin/main`; `ThemeEnvironment.ResolvedTheme` is an empty stub. |
| Appearance: Session hint for first-frame paint | `AppearanceStore.remote` | **Missing** | No | Session's `…:appearance` capability carries `{theme, layout, accent, density}`. |
| Appearance: write back / "Match the web" switch | `AppearanceScreen.MatchTheWeb` | **Missing** | No | Android reads and deliberately no longer writes. Reading is the whole win. |
| Appearance: light/dark/system only | `AppearanceScreen.Themes` (6 client themes over 39 server themes) | **Present (reduced)** | No | Defensible today; becomes a mapping problem once the server value is read. |
| Appearance: density, layout, font family, font scale, preview lines, avatars, unread emphasis, pane alpha | `AppearanceScreen.kt` (~960 lines) | **Missing** | No | Several of these are Dynamic Type / system answers on iOS — see *The Apple way*. |
| Account ordering | `AccountsScreen.kt` arrows, `AccountPrefsStore.kt` | **Missing** | No | Drives which account the composer opens on and where a new label is created. |
| Cached-window facts per account | `AccountsScreen.AccountRow` | **Missing** | No | Countable from `SyncStore` today. |
| Server sync window / backfill state | Session `urn:plmail:params:jmap:sync` | **Missing** | No | Capability is real on `origin/main`; iOS's `Capability` enum has no case for it. |
| Account "needs attention" kinds | `SyncWindow.attentionSentence()` | **Missing** | No | Same capability. The token is the fix for the P0 above. |
| Push transport choice with per-option reasons | `PushScreen.kt`, `core/data/PushTransports.kt` | **N/A by platform** | — | iOS has one possible transport; the *reasons* pattern still applies to the one row. |
| APNs transport, server side | `FcmSender.php` is the precedent | **Missing (server)** | **Yes** + server work | Actionable request in gap note 5. |
| APNs client half | — | **Built, mis-aimed** | Yes | `PushRegistrar.swift` is complete but declares a capability the server refuses. |
| `using` array correctness | — | **Bug** | No | `Capability.supportedInUsing` contains `.apns`, absent from server `Capability::SUPPORTED` → `unknownCapability` refuses the whole request. |
| Push verification handshake | `PushTransportManager`, `PushRepository.deliver` | **Missing** | Partly | Mandatory for every transport, including a future APNs one. |
| Push registration state / last delivery / last error | `core/datastore/PushStateStore.kt` | **Missing** | Partly | `PushRegistrar` keeps its token in actor memory; nothing persists or displays. |
| Push log (what actually arrived, by route) | `PushLogScreen.kt`, `PushLogStore.kt` | **Missing** | **No** | Android's `stream` badge is EventSource — iOS already has `EventSourceClient`. |
| Diagnostics: address, limits, cursors | `DiagnosticsScreen.kt` | **Present, ahead** | No | iOS also shows six live `Core` limits and three state tokens per account. |
| Diagnostics: active "check now" | `DiagnosticsViewModel.checkNow` | **Partial** | No | `.refreshable` reloads accounts + Session only; no forced sync, no re-page report, no server-side subscription check. |
| Diagnostics: absolute timestamps | `feature/settings/Timestamps.kt` | **Partial** | No | On-screen values are `.relative(presentation: .named)`; the copied report is ISO-8601. |
| Language picker | `LanguageViewModel.kt`, `core/data/AppLanguages.kt` | **Missing in-app, present via system** | No | `App/Info.plist` declares `CFBundleLocalizations en, de`, so iOS shows its own per-app Language row. |
| Calendar launcher icon toggle | `CalendarLauncherViewModel.kt` | **N/A by platform** | — | |
| Onboarding: QR + manual, TOFU, confirm-before-save | `feature/onboarding/` | **Present** | No | `ServerSetupModel.swift` matches step for step. |
| Onboarding: cleartext warning before the secret is sent | `OnboardingState.warnsAboutCleartext` | **Missing** | No | Security hole. |
| Onboarding: reject `user:password@` in the address | `ParsedAddress.CredentialsInAddress` | **Missing** | No | Security hole. |
| Onboarding: address problems shown while typing | `OnboardingViewModel.addressChanged` | **Partial** | No | Secret shape is live; address is parsed only on Connect. |
| Credential storage | `core/datastore/{CredentialStore,SecretCipher}.kt` | **Present, ahead** | No | |
| Certificate trust (TOFU, SPKI pin, changed-key refusal) | onboarding trust dialog | **Present** | No | `JMAPKit/Client/ServerTrust.swift`. |
| View a pinned certificate after onboarding | neither client | **Missing (both)** | No | iOS is one line away; `KeyFingerprint.description` already prints openssl-comparable pairs. |
| Background refresh | Android WorkManager 15 min | **Present, ahead** | No | `App/BackgroundRefresh.swift`. |
| Retry / backoff / circuit breaking | Android sync layer | **Present, ahead** | No | `PLMailCore/Sync/RetryPolicy.swift`. |
| Widget data | — | **Built, gated** | **Yes** | `Widget/PLMailWidget.swift:81-86` says "Needs a paid developer account" rather than faking a zero. |
| Share extension | — | **Not built** | Yes, and unwritten | No extension target exists in the project. |

## Detailed gap notes

### 1. P0: re-authentication must not delete the mailbox

**Where:** `App/AppModel.swift:99` (`signOut`, and the `onReauthenticationNeeded` wiring in
`connect(to:)`), `PLMailCore/Sync/MailSyncService.swift` (`requestReauthentication()`,
`status = .unauthenticated`).

Today any `notAuthenticated` from any account calls `signOut()`, which deletes the Keychain item and
runs `SyncStore.deleteEverything()`. The cost of a revoked or rotated app password is therefore
every cached message, every queued outbox draft and every sync cursor — with the onboarding screen
as the only explanation offered.

Three things are wrong with that, in descending order:

- **A 401 is not consent to delete.** The credential is the only irreplaceable thing here, and it is
  precisely the thing that is *already* gone; the cache is the replaceable thing, and it is the one
  being destroyed. Offline mail is the app's headline feature.
- **A single degraded account takes down the whole app.** One connected mailbox whose upstream OAuth
  grant died can produce a 401 while every other account is healthy.
- **Nothing says why.** Android's server publishes the reason as a token — `attentionKind` in the
  Session's `urn:plmail:params:jmap:sync` account capability, with values including
  `account_reconnect`, `push_degraded`, `push_lapsed` and a severity beside it — precisely so a
  client can write its own sentence and send the user to the right place. `account_reconnect` ends
  in an OAuth browser flow, so the honest client behaviour is "say what is wrong and open the web
  UI".

Build:

1. Delete the `onReauthenticationNeeded = signOut` wiring. Keep `status = .unauthenticated`, which
   already exists and which `ServerDiagnosticsView` already renders as "App password rejected".
2. Stop syncing that account, keep the cache, and surface the state twice: a banner above the thread
   list, and a row in `SettingsView` → `AccountsView`.
3. Offer **Sign in again**, which presents `ServerSetupView` pre-filled with the stored address, and
   on success calls `CredentialStore.save(_:)` **without touching `SyncStore`**. The store is keyed
   the same way, so the cache is still valid for the same server.
4. Reserve `deleteEverything()` for the explicit, already-confirmed sign-out in `SettingsView`, and
   for a *deliberate* switch to a different server.
5. Once the sync capability is read (gap note 4), map `attentionKind` to a sentence with a
   **fallback branch** — an unknown kind still means the account has stopped working, and saying so
   vaguely beats saying nothing.

### 2. Local notifications for new mail

**Where:** new `App/MailNotifications.swift`, called from `AppModel.refreshInBackground()` and from
the sync's new-mail path.

Android decides *what is new* in the sync layer (`DeltaSync`) and hands a `List<NewMessage>` to
`MailNotifier.onNewMail`. iOS has the same information available in `DeltaSync` / `UnifiedFeed` and
nothing consumes it.

Minimum useful version:

- One request per **conversation**, not per message; identifier `"\(accountKey)#\(threadID)"` so a
  reply in an already-notified thread replaces the banner instead of stacking. Android keys on the
  thread for the same reason (`MailNotifier.notificationId`).
- `content.threadIdentifier = accountKey` for per-account grouping, and `summaryArgument` = the
  account's display name so the collapsed group reads "3 more messages from Personal".
- `title` = sender, `subtitle` = subject, `body` = preview; `interruptionLevel = .active`.
- **Deduplicate.** Android keeps `core/datastore/NotifiedMessageStore.kt` because a re-page or a
  cursor-less resync re-reports old mail as new; without an equivalent, one background wake after a
  long absence posts a hundred banners.
- Check `UNUserNotificationCenter.notificationSettings()` first and post nothing when denied.
  `MailNotifier.isPermitted()` exists because `NotificationManagerCompat` swallows the refusal, so a
  missing permission is indistinguishable from mail that never arrived.
- Recompute `setBadgeCount` from the real unread count after any post or action.

**Decouple the permission request from push.** `PushDelegate.requestAuthorization` is currently
reached only via `AppModel.requestPushIfUseful()` behind `push.isSupported()`, which is false on
every server today — so the prompt never appears and local notifications would be silently dropped.
Ask after the first successful sync, when there is mail on screen to justify it, and let the push
check govern only `registerForRemoteNotifications()`.

### 3. Appearance: the server API exists now

**Where:** `PLMailUI/Theme/ThemeEnvironment.swift` (`ResolvedTheme`, currently
`public struct ResolvedTheme: Equatable, Sendable { public static let placeholder = ResolvedTheme() }`),
plus a new `PLMailCore/Settings/AppearanceMethods.swift` and a resolver.
Server: `src/Jmap/Method/Settings/{AppearanceGetMethod,AppearanceSetMethod}.php`,
`src/Jmap/Mapper/AppearanceMapper.php`, `src/Jmap/Session/SessionBuilder.php::appearanceCapabilities()`.

`ResolvedTheme`'s own doc comment says views read the theme from the environment "so that swapping
the *source* of those values — local settings today, the server once it exposes `Appearance` over
JMAP — touches nothing but the resolver". That server API landed. The seam was built for this.

**Capability.** `urn:plmail:params:jmap:appearance`, and unlike `…:push` it **is** in
`Capability::SUPPORTED`, so it must be declared in `using` for the two methods. iOS's
`JMAPKit/Protocol/Capability.swift` has no case for it.

**`Appearance/get`.** A singleton modelled on RFC 8621's VacationResponse. **No `accountId`** — an
`accountId` sent anyway is refused with `invalidArguments`, not ignored. `ids: null` returns the one
object, whose `id` is the literal string `"singleton"`; any other id is `notFound`. `state` is a
**hash of the object**, not a change-log sequence, so **there is no `Appearance/changes` and never
will be** — a client that sees the token move re-fetches the one object, which is one call.

**`Appearance/set`.** Only `update: {"singleton": {…}}` does anything; `create` and `destroy` are
answered with the spec's `singleton` SetError. `ifInState` is honoured and mismatches raise
`stateMismatch`, so two devices editing the theme do not silently overwrite each other. The patch is
**validated whole before any of it is applied** — seventeen-plus properties on one embeddable, and a
half-applied patch would flush a theme the client was told was refused. Then:

- **Closed vocabularies are refused**, with `invalidProperties` naming what is accepted. Deliberately
  unlike the web pane, whose setters silently keep the old value — over the wire that would tell a
  phone it succeeded and then show the old theme forever.
- **Malformed colours are refused** (the setter's fallback is a value nobody asked for).
- **`id`, `backgroundFile` and `logoStyle` are read-only**: an *echo* of the current value is
  accepted, a *change* is refused. Echoing matters because get → edit one field → set is how a client
  is supposed to work. `logoStyle` is derived from `theme` + `logoLinked` + the stored colourway and
  an echo of it is additionally *dropped* before it can be written; change the theme to move the mark.
- **Numeric ranges are clamped, not refused**, and the clamp is reported back in the `updated` map
  (RFC 8620 §5.3: properties the server changed beyond what was asked). So a client that sends
  `paneAlpha: 1.4` is told it will get `1.0` rather than silently storing something else.

**The property vocabulary** (`AppearanceMapper::PROPERTIES`, the single source shared by get, set and
the Session so the three cannot disagree):

```
theme, layout, logoStyle*, accent, paneAlpha, paneBlur, radius, density, motion,
backgroundKind, backgroundPreset, backgroundFile*, backgroundSolid, scrimAlpha,
inkColor, inkMuted, inkFaint, mainTint, mainAlpha, accountCorner, listAvatars,
previewLines, unreadEmphasis, fontFamily, fontScale,
sidebarDensity, listDensity, readingDensity          (* = read-only)
```

`sidebarDensity`, `listDensity` and `readingDensity` are **nullable and null is a value**: it means
"this surface follows the global `density`", and it is the only way back from an override. A client
that writes `?? density` anywhere on that path breaks the control permanently — Android's
`DensityOverride` exists solely to carry an explicit JSON null.

**The Session hint.** `capabilities["urn:plmail:params:jmap:appearance"]` carries:

- `appearance` — the **compact** subset `{theme, layout, accent, density}`, enough to paint the
  chrome on the first frame instead of flashing the wrong palette. It is explicitly a *hint*: the
  Session's `state` is a hash of the user's account ids and does **not** move when a theme changes,
  so a cached Session holds a stale theme until `Appearance/get` corrects it. Never commit anything
  outside the app (an icon, a widget tint) to the hint.
- The vocabularies, which cannot go stale: `themes` (39 values), `logoStyles`, `layouts`,
  `densities`, `backgroundKinds`, `backgroundPresets`, `unreadEmphases`, `fontFamilies`.
- `layoutDefaults` — the knob preset each layout seeds, so a client's sliders sit where the web
  pane's do.
- `ranges` — read off the server's own clamp constants: `paneAlpha` 0.15–1.0, `paneBlur` 0–60,
  `radius` 0.0–2.0 (rem), `scrimAlpha` 0.0–0.7, `mainAlpha` 0.15–1.0, `previewLines` 0–2,
  `fontScale` 0.875–1.25.

**How Android's six themes map onto the server's thirty-nine**
(`core/designsystem/Tokens.kt:307`, `PlMailThemeChoice`):

| Client value | Wire | Dark? |
|---|---|---|
| `SYSTEM` | `system` | follows the OS |
| `LIGHT` | `light` | no |
| `DARK` | `dark` | yes |
| `NORD` | `nord` | yes |
| `DUSK` | `dusk` | yes |
| `SOLAR` | `solar` | no |

`fromWire` maps the server's default theme `paper` onto `LIGHT` — named as `PAPER_WIRE` precisely so
that a write cannot flatten it — and **anything else falls back to `SYSTEM`** rather than failing.
That fallback is the load-bearing part: the server ships 39 themes (`product-blue`, `ocean`,
`midnight-gold`, …) and will ship more, so a client that switches exhaustively over the enum breaks
on the next release. `layout` is `flat` | `boxed`; `density` is `comfortable` | `cosy` | `compact`.

**What iOS should build, in order.** The win is *reading*, not writing, so do it in that order:

1. Add `.appearance` to `Capability` (and to `supportedInUsing`).
2. Decode the Session's compact hint into `ResolvedTheme` at launch — light/dark resolution from
   `theme`, and `density` mapped onto the list row's spacing. That alone stops the app disagreeing
   with the browser on the first frame.
3. Call `Appearance/get` once after the first sync and after any `stateMismatch`, and replace the
   hint. There is no `/changes` to subscribe to; re-fetch when the token differs.
4. Map unknown themes to system, exactly as Android does, and **never write back a theme this client
   flattened** — a phone that read `ocean`, rendered it as system dark and then wrote `system` would
   destroy the user's choice in the browser.
5. Only then consider a writer, and only for values iOS can honour honestly.

Values iOS should deliberately **not** offer even after reading them: `fontScale` (Dynamic Type owns
this — see *The Apple way*), `paneBlur` (SwiftUI *can* do backdrop material, unlike Compose, so this
one is genuinely available if wanted), `backgroundFile` (unfetchable from JMAP), `logoStyle`
(read-only, and iOS has no alternate app icons shipped).

### 4. `urn:plmail:params:jmap:sync` — what it is, and yes, declare it

**Where:** `JMAPKit/Protocol/Capability.swift`, `JMAPKit/Protocol/Session.swift`,
`PLMailUI/Settings/AccountsView.swift`, `ServerDiagnosticsView.swift`.
Server: `src/Jmap/Protocol/Capability.php:67`, `SessionBuilder::syncAccountCapabilities()`,
`src/Jmap/README.md`.

**It has no methods.** It is published **per account**, inside each entry's `accountCapabilities`,
and it exists to answer a question a JMAP client otherwise cannot: *why is this mail not here?*

```json
"urn:plmail:params:jmap:sync": {
  "backfillTarget": 0,
  "backfillPending": false,
  "needsAttention": true,
  "attentionKind": "account_reconnect",
  "attentionSeverity": "error"
}
```

- `backfillTarget` — how far back a *completed* backfill actually reached: `0` for the whole
  mailbox, `null` when none has finished. A positive number is a leftover stopping point, i.e.
  unfinished rather than complete.
- `backfillPending` — whether anything is still owed. Explicitly **not** "a backfill is running right
  now"; nothing records that, and a client would read a running flag as progress.
- `needsAttention` / `attentionKind` / `attentionSeverity` — whether the account has stopped working
  and what kind of stopped. The server publishes the **token only**, never the rendered card: its own
  health cards are translated Twig with Symfony routes attached, which no native client can use.

Why iOS needs it: a dead OAuth grant is invisible over JMAP. The account stays in the Session, every
method keeps answering, and no mail ever arrives again — an inbox that has simply gone quiet, with
nothing to press. This is the same token that fixes the P0 in gap note 1, and it is also the honest
answer to "search cannot find my 2019 mail" (`backfillPending: true` means the server has not fetched
it yet; the opposite reaction from "the phone has not paged back that far").

**Declare it in `using`.** It is in `Capability::SUPPORTED` *despite having no methods*, specifically
so that a client listing a capability it depends on — the obvious thing to do — is not refused with
`unknownCapability`. So both are correct: reading it out of the Session without declaring it works,
and declaring it also works. Declare it, because that is what the server made possible on purpose.

Contrast `urn:plmail:params:jmap:push`, which is **not** in `SUPPORTED`: putting that one in `using`
is a hard 400. iOS's `Capability.swift` already gets that right and says so in a comment.

### 5. Push: the precise server-side request

**Where (client):** `PLMailCore/Push/PushRegistrar.swift`, `JMAPKit/Protocol/Capability.swift`,
`App/PushDelegate.swift`, `docs/PUSH.md`.
**Where (server):** `src/Jmap/Push/{PushSenderRegistry,PushDispatcher,WebPushSender,FcmSender,
PushDeliveryRecorder}.php`, `src/Domain/Interface/PushSenderInterface.php`,
`src/Domain/Enum/PushTransport.php`, `src/Entity/User/PushSubscription.php`,
`src/Jmap/Method/Core/PushSubscriptionSetMethod.php`.

#### Is the sender side pluggable? Yes — demonstrably, because Android already added one.

`PushSenderRegistry` is constructed from an `iterable<PushSenderInterface>` of tagged services and
keyed by `$sender->transport()->value`. Lookup is `for(PushSubscription)` / `of(PushTransport)`, and
the class comment states the design decision plainly: the transport is a *property of the
subscription row*, not an interpretation of it, so there is no `supports()` scan that two senders
could both win. `anyConfigured()` lets `PushDispatcher` do zero work per request on an install with
no transports at all. A transport with no registered sender is skipped, not thrown — a deployment
problem must not turn into an outage on the request that happened to flush a state change.

`PushDispatcher` names no sender. It drains `StateManager`'s dirty `(account, type)` pairs once per
request, groups by user, and for each deliverable subscription asks the registry for *that row's*
sender, filters to the types the row `wants()`, and calls `send()`. Its own comment: "A user with a
phone on FCM and a desktop browser on Web Push has both told, from the same drained set, in the same
pass."

`PushSenderInterface` is three methods — `transport()`, `isConfigured()`, `send($subscription,
$payload): bool` — and the contract is explicit that both the payload shape and the failure
vocabulary are the implementation's business, and that a sender which decides a subscription is
permanently dead **removes the row itself** rather than returning a distinguished value.

So `WebPushSender` (RFC 8030/8291/8292, covering browsers *and* UnifiedPush distributors *and*
Apple's gateway for an installed PWA) and `FcmSender` (HTTP v1, data messages only) are two
implementations sharing nothing but the JSON inside. **An APNs sender is a third.**

#### What `PushSubscription/set` actually accepts

No `accountId` — subscriptions are per authenticated user. Creates are validated against a per-transport
whitelist (`PushSubscriptionSetMethod::CREATE_PROPERTIES`):

| Transport | Create properties |
|---|---|
| `webpush` | `deviceClientId`, `url`, `keys`, `types`, `expires` |
| `fcm` | `deviceClientId`, `fcmToken`, `types`, `expires` |

The transport is **inferred from the shape and the shapes are exclusive** — a create carrying both
`url` and `fcmToken` is refused rather than resolved by precedence, because otherwise which device
gets woken depends on which check ran first. `deviceClientId` is stable per device+app and a
re-registration **replaces** the matching row, so a reinstall does not accumulate dead endpoints;
that is also why the correct way to switch transports is a plain create with the same device id
rather than destroy-then-create, which would open a window with no subscription at all.

`fcmToken` is the one address property an `update` may change, because Android reissues registration
tokens on its own schedule and refusing rotation would silence a device for doing something normal —
and rotating **re-arms the verification handshake** rather than dropping the safety property.

**The verification handshake is mandatory for every transport** (RFC 8620 §7.2.2). On create the
server immediately sends a `PushVerification` object to the address supplied — POSTed for Web Push,
a data message for FCM — and the subscription **receives nothing** until the client echoes the code
back via an update. Even plMail's own PWA is not exempt. `PushSubscription/get` deliberately never
returns `verificationCode`, so a client cannot ask whether it is verified: the only device that knows
the handshake completed is the one that completed it, which is why Android records `verifiedAt`
locally (`core/datastore/PushStateStore.kt`).

Delivery is logged server-side regardless of transport: every attempt writes a `push_delivery` row
(`PushDeliveryRecorder`) with the device, the payload `@type`, an outcome of
`accepted` / `failed` / `subscription-destroyed` / `skipped`, the status or error name, latency and
time — readable at `/admin/push` and per device in the user's own Settings → Notifications. An APNs
sender inherits that for free.

#### The ask, stated as a work item

The server's README currently says "APNs is still not an option, for the reason FCM used to share:
pushing through it needs *the client app's* credentials." That reason was **already solved once**,
for FCM: the credentials became the *instance's*, an admin pastes their own project key under
`/admin/push`, and the Session hands clients the public half so one Play Store build can initialise
against whichever install it is signed into. APNs is the same shape with a different key, with one
asymmetry to state honestly: an APNs key is bound to the **app's** bundle id and team, so unlike
Firebase the self-hoster cannot mint one — it has to come from whoever signs the iOS build, and be
pasted into their instance. That is the real blocker, and it is an entitlement blocker, not an
architecture one.

Concretely, on the server:

1. **`PushTransport::Apns = 'apns'`** in `src/Domain/Enum/PushTransport.php`, with
   `addressedByUrl(): false`.
2. **`ApnsSender implements PushSenderInterface`** in `src/Jmap/Push/`, modelled on `FcmSender`:
   - `transport()` → `PushTransport::Apns`; `isConfigured()` → key + keyId + teamId + topic present.
   - `send()` posts to `api.push.apple.com` or `api.sandbox.push.apple.com` **chosen by the row's
     stored environment, never guessed** — a sandbox token sent to production is rejected with an
     error that does not explain itself.
   - Payload: `{"aps":{"content-available":1}, "payload":"<the same JSON WebPushSender sends>"}`.
     Silent, content-available, no `alert` — same argument `FcmSender` makes for data-only messages:
     JMAP pushes no mail content, and turning a state token into a visible alert is the client's job
     because only the client knows what the user is looking at.
   - `apns-collapse-id` **per payload `@type`**, exactly as `FcmSender::COLLAPSE_KEYS` does. A single
     key would let an ordinary `StateChange` discard an undelivered `PushVerification`, and the
     subscription would then wait forever for a code that was collapsed away.
   - `apns-expiration` ≈ 24h, matching FCM's TTL and for the same reason.
   - Permanent failures — `410 Unregistered`, `BadDeviceToken` — **destroy the row**, FCM's
     `UNREGISTERED` / Web Push's 404/410 rule. `429`/`5xx`/`TooManyRequests` must **not** count
     toward the failure counter, exactly as `FcmSender` excludes `QUOTA_EXCEEDED` / `UNAVAILABLE`:
     an outage is not a broken endpoint, and counting it would retire ten good devices.
   - Record every exit through `PushDeliveryRecorder`.
3. **`PushSubscriptionSetMethod::CREATE_PROPERTIES['apns'] = ['deviceClientId', 'apnsToken',
   'environment', 'types', 'expires']`**, with the same exclusivity rule (a create carrying
   `apnsToken` alongside `url` or `fcmToken` is refused) and the same rotation allowance on update
   that `fcmToken` gets, re-arming verification.
4. **Session advertisement**, beside `vapidPublicKey` and `fcm` in
   `SessionBuilder::pushCapabilities()`: `"apns": true|false` — advertised **even when false**, for
   the reason the `fcm` flag is: a client must be able to tell "this server does not do APNs" from
   "this server is too old to know what APNs is", and the sensible reaction to each is the opposite
   one. Plus `apnsConfig: { topic }` **absent rather than null** when unconfigured, matching
   `fcmConfig`'s rule — absence cannot be dereferenced.
5. **Admin configuration** under `/admin/push` beside Firebase: `.p8`, key id, team id, topic,
   environment. Encrypted at rest like the FCM service account.

Then on the client, in the same change:

- **Fix the `using` bug first — it is independent of all of the above.**
  `Capability.supportedInUsing` in `JMAPKit/Protocol/Capability.swift` contains `.apns`, and
  `PushSubscriptionSet.capability = .apns`, so `RequestBuilder` puts
  `urn:de:plmail:params:jmap:apns` into `using`. That URN is not in the server's
  `Capability::SUPPORTED`, so the **entire request** is refused with `unknownCapability` — not just
  the push call. `PushSubscription/set` is a **Core** method; the correct declaration is
  `urn:ietf:params:jmap:core` and nothing else. This is why the current code cannot even fail
  usefully against a real server.
- Rename the vendor capability to whatever the server ends up advertising (recommend
  `urn:plmail:params:jmap:apns`, matching every other plMail URN — the current
  `urn:de:plmail:params:jmap:apns` matches nothing on the server).
- Send `apnsToken` rather than `deviceToken`, and keep the hand-written encoder that makes an
  unregister a literal `null`.
- **Implement the verification echo.** It is mandatory and iOS has no code for it. A
  `PushVerification` will arrive as a silent push carrying the same JSON envelope; read
  `verificationCode` and echo it back via `PushSubscription/set` update. Until that lands, an APNs
  subscription would register successfully and receive nothing — which is exactly the state
  Android's push screen draws as "waiting for confirmation" and warns is where a broken transport
  sits forever.
- Persist registration state (registered at, verified at, last delivery, last error) so gap note 6
  has something to show.

### 6. Push observability without an APNs key

**Where:** new `PLMailUI/Settings/PushLogView.swift` and a small store beside `AppearancePreference`;
push facts added to `ServerDiagnosticsView.pushSection`.

Most of Android's push diagnostics apply to iOS **today**, because Android's log records four
delivery routes and one of them is `stream` — the EventSource connection, which iOS already has
(`JMAPKit/EventSource/EventSourceClient.swift`, driven by `MailSyncService`). Android's own argument
for the badge: a user watching mail arrive instantly while the app is open and never while it is
closed is looking at a stream doing the work of a subscription that was never verified, and every
other view draws those two identically.

Buildable now, with zero entitlements:

- A bounded log of received state changes: absolute monospaced timestamp, route badge (`stream`
  today, `apns` later), and the `changed` map rendered as `accountId: Email, Mailbox`. No mail
  content — not merely because JMAP pushes none, but because a subject line here would be a copy of
  someone's mail sitting in a diagnostics list for the next two hundred messages.
- Not a SwiftData table. `PushLogStore`'s reasoning transfers exactly: every row in the mail cache is
  reconstructible from the server, which is what licenses the destructive-migration policy; this is
  the opposite — a record of events the server cannot replay — so a schema bump for an unrelated
  column would erase the evidence someone was collecting.
- Serialise the read-modify-write. Two deliveries a moment apart otherwise silently lose one entry.
- A **Clear** button. A log you cannot reset is a log you cannot use: the way anyone tests this is
  clear, send yourself a message, expect exactly one line.
- At the top, the registration the log is evidence *about*. Two hundred `stream` lines mean one thing
  beside a live registration and something else beside none.

Note the server keeps the sending half already (`push_delivery` rows at `/admin/push`), so a client
log is directly comparable line for line — which is the whole point of both existing.

### 7. Accounts screen: ordering, cached window, attention

**Where:** `PLMailUI/Settings/AccountsView.swift`.

- **Order.** Android uses up/down arrows rather than drag, as an accessibility decision — a
  long-press drag has no screen-reader equivalent unless a custom action is written, and the custom
  action *is* the two buttons. The order is not cosmetic: it decides which account the composer opens
  on and where a new label is created. Stored in DataStore, not on the account row, because the row
  is a cache dropped on any schema change and nothing on the server can reconstruct a user's
  ordering. iOS translation: `EditButton()` + `.onMove` (VoiceOver has a first-class reorder rotor,
  so the accessibility argument does not carry over), persisted in `UserDefaults` — **not** SwiftData,
  for the same disposability reason.
- **The device's window.** "412 messages, back to 3 March" as one sentence, because that is the shape
  of the answer someone wants when they cannot find an old mail; two labelled facts make them do the
  joining. Countable from `SyncStore` today.
- **The server's window.** From the sync capability (gap note 4). Android deliberately deleted a
  button that ran an `Email/query` per account to find the oldest message, because the answer it gave
  silently meant "oldest fetched so far" on exactly the accounts still backfilling — the ones people
  open the screen about.
- **Attention.** Per gap note 1.
- **Mute.** Per-account notification mute, with an explicit note when off — a muted account still
  syncs and still badges, so "notifications off" is otherwise indistinguishable from push being
  broken.

Keep iOS's footer explaining that mailboxes are connected on the server and that one app password
covers all of them, which is why there is no Add Account button. Android has no equivalent.

### 8. Notification actions, inline reply and per-scope preferences

**Where:** `App/MailNotifications.swift` (categories) + `App/PushDelegate.swift`
(`UNUserNotificationCenterDelegate.didReceive`), and a new
`PLMailUI/Settings/NotificationsView.swift`.

Android's rules worth copying:

- Archive and mark-read are broadcasts, not activity launches, so the phone stays in the pocket
  (`NotificationActions.kt`). iOS equivalent: `UNNotificationAction` **without** `.foreground`.
- The row is dismissed **first and unconditionally**, before the server call. A NAS on a domestic
  uplink makes an action that waits look broken and invites a second tap.
- Inline reply is `UNTextInputNotificationAction`. `ReplyNotifications` covers the states most
  implementations skip: while sending, the row becomes the conversation *with the reply in it*; on
  success it disappears; on failure it is replaced by a row that still holds the typed text and
  offers Try again. On iOS, route the send through the existing `Outbox` so a failure is already
  queued and retried.

Preferences have two layers on Android and the store is deliberately **tri-state** — `enabled` set,
`disabled` set, and *never said* — because a single "enabled" set cannot distinguish "the user
switched Primary off" from "the user has never opened this screen", and a label created later on the
web must default to off rather than inheriting anything. Labels are listed by **path**, not leaf
name. The category group is hidden entirely on a server that does not classify mail. Note the
deliberate asymmetry: a new *account* defaults to notifying (silence would read as breakage), a new
*label* defaults to not (noise nobody asked for).

### 9. Diagnostics: an active check, and absolute time

**Where:** `PLMailUI/Settings/ServerDiagnosticsView.swift`.

`.refreshable` currently re-reads accounts from the store and re-fetches the Session. Android's
"Check now" additionally runs a sync, reports which accounts had to **re-page** (drawn as INFO,
explicitly *not* as a failure — it is the answer to "why is this list stale"), reports the first
failure verbatim, and asks the server whether the push subscription still exists. That last is the
one failure a device cannot notice alone: a token the provider reports as gone destroys the row
server-side while the client goes on believing it is registered.

Android's standing rule is worth adopting verbatim: **never make requests just because the screen was
opened.** The first thing someone does when their server is struggling must not be to add traffic to
it. `Core/echo` is the right probe if a liveness check is wanted — it is already defined in
`JMAPKit/Methods/CoreMethods.swift` and called nowhere.

Timestamps: absolute on this screen, with the date. Relative time is right on a message list, where
recency is what matters; it is wrong here, where the job is *correlating* against a server log or the
moment someone restarted a container. "Yesterday" cannot be lined up against a log line and
"01/08/2026, 03:14" can. The copied report is already ISO-8601 and correct.

### 10. Onboarding: two security holes and one polish item

**Where:** `PLMailUI/Onboarding/ServerSetupView.swift`, `PLMailCore/Onboarding/ServerAddress.swift`,
`ServerSetupModel.swift`.

- **Cleartext, before the secret is sent.** `ServerAddress.isCleartext` exists and is consumed only
  by `ServerDiagnosticsView` — which is reachable only *after* the app password has already crossed
  the wire in the clear. Android shows a card under the address field as soon as the typed address
  parses to `http` (`OnboardingUiState.warnsAboutCleartext`). On iOS this is a section footer on the
  server section, shown before Connect can be pressed.
- **Credentials in the address.** `ServerAddress.parse` nils `query` and `fragment` — with a comment
  explaining that carrying them would attach whatever was pasted to every request — but leaves
  `user` and `password`, so `https://me:hunter2@nas.local` is accepted and preserved into `baseURL`
  and therefore into every request and into the Keychain metadata. Add a `ParseError` case and clear
  both components. Android rejects it explicitly.
- **Live address feedback.** Android parses on every keystroke and shows the specific problem under
  the field, keeping round-trip failures beside the button — two surfaces on purpose, so "can't reach
  nas.local" never appears under a text field as though the text were wrong. iOS already splits
  `secretLooksWrong` (live) from `phase == .failed` (below); extend the same treatment to the address.

Everything else here is at parity or better. `ServerSetupModel.attempt(pinning:)` runs the pairing
redemption *inside* the trust-retry loop, keeps the pairing code unburned until it is actually
exchanged, and saves nothing until the user has seen the username and mailbox list — the same three
properties `OnboardingViewModel` is built around.

### 11. Certificate pin, after onboarding

Neither client can show or clear a pin once accepted. iOS is one line from the better version:
`ServerDiagnosticsView` already knows `connection.pinnedFingerprint`, and
`KeyFingerprint.description` already prints openssl-comparable spaced pairs. Show it with
`.textSelection(.enabled)`. Clearing it should stay unavailable — both clients agree a changed key
must never degrade back into a prompt.

## The Apple way

Where the right iOS answer is not Android's:

- **Settings shape.** `SettingsView` is a `List` in a `NavigationStack` with grouped sections,
  `LabeledContent` value summaries and one subject per pushed screen. That is already right; do not
  rebuild it as Android's flat scrolling `Column`. New screens (Notifications, Push log) are `Form`s
  in the same stack. Keep the grouping by *whose* setting it is — "Mail" (the server's) vs "This
  device" — which is the distinction that matters on a self-hosted app.
- **Notifications.** Android's `MessagingStyle` maps to iOS **communication notifications**: donate
  an `INSendMessageIntent` with the sender as an `INPerson` and call `content.updating(from: intent)`.
  That yields the sender's name and avatar in the banner, Focus "allow from people" behaviour, and
  Announce Notifications reading it as a message. Grouping is `threadIdentifier` + `summaryArgument`
  — do **not** port `MailNotifier.summary` and its child-counting arithmetic, which exists only
  because Android's group rules require the app to post the summary itself.
- **No channels.** Android's per-account channels carry sound, importance and DND and are permanent
  by design. iOS has one app-level setting the user owns, plus `interruptionLevel` and
  `relevanceScore` per request. Per-account mute is an in-app preference here, never a system object.
- **Permission timing.** iOS's one-shot prompt is effectively permanent when denied, which is why
  `PushDelegate.requestAuthorization`'s comment is right to refuse to spend it at first launch. Ask
  after the first successful sync. Register for remote notifications separately — that needs no
  permission — exactly as `AppModel.requestPushIfUseful()` already separates the two.
- **Appearance.** Read the server's values; do not reproduce its controls. `fontScale` in particular
  is Dynamic Type's job on iOS — the system already publishes a user-chosen text size that every app
  is expected to honour, and a second in-app scale multiplied on top produces sizes neither the user
  nor the layout asked for. Honour `.dynamicTypeSize` and ignore the server's `fontScale` rather than
  fighting it. `motion` maps onto `@Environment(\.accessibilityReduceMotion)`, and the server's own
  comment says an OS-level reduce-motion request "overrules this without consulting it" — so the
  system wins on iOS too. `paneAlpha`/`paneBlur` *are* implementable in SwiftUI (`.background(.ultraThinMaterial)`),
  unlike Compose, which is one of the few places iOS can be more faithful to the web than Android is.
- **Background.** `BGAppRefreshTask` at 15 minutes is right and already implemented, including the
  two rules that matter: reschedule *before* doing the work, and honour the expiration handler by
  cancelling. A backfill needing longer is a separately registered `BGProcessingTask`, not a longer
  refresh.
- **Keychain.** Already correct, and worth stating so it is not "improved" later:
  `kSecClassInternetPassword` (a generic password's `kSecAttrService` is invalid here and returns
  `errSecNoSuchAttr`), `kSecAttrAccessibleAfterFirstUnlock` (a background refresh fires in a pocket;
  `WhenUnlocked` fails it opaquely), `kSecAttrSynchronizable = false` (an app password identifies one
  device, and the server's own last-used model assumes that). Android's Keystore-over-DataStore
  arrangement has no iOS analogue and needs none.
- **No `ASWebAuthenticationSession`.** plMail authenticates with an app password or a pairing code,
  not OAuth, and app-password creation is web-only. `ServerSetupView` already hands the user to the
  web UI via `SFSafariViewController`, which is right: nothing is redirected back, so a web-auth
  session's callback machinery would buy nothing. The one place an OAuth flow *does* appear is the
  server's `account_reconnect` repair — and the honest client behaviour there is still to open the
  web UI.
- **Language.** iOS has no equivalent of Android's in-app per-app-language picker and does not need
  one: because `App/Info.plist` declares `CFBundleLocalizations` (`en`, `de`), iOS shows a
  **Language** row in Settings → plMail automatically, and that is the system's per-app language and
  the only writer of it. The Apple answer to `LanguageViewModel` is *no picker*, optionally a row in
  Appearance opening `UIApplication.openSettingsURLString`. Android's read-on-resume dance exists
  only because it has two writers of one value; iOS has one. Note the trap recorded in
  `docs/WHATS-LEFT.md`: `String(localized:locale:)` does not choose the translation, the bundle does
  — hence `PLMailUI/Theme/Localization.swift`'s `.ui(_:)` helper, which exists because SwiftUI
  resolves keys against `Bundle.main` and would otherwise fall through to English silently.
- **`AppStorage` vs a shared observable.** `AppearancePreference` is a `@MainActor @Observable`
  singleton over `UserDefaults` rather than `@AppStorage`, because it is read at the app root and
  written several levels down. Keep that pattern for the new notification and account-order
  preferences: one namespaced key constant defined once, with an unreadable value falling back
  rather than throwing.
- **System Settings bundle:** do not add one. Everything here is per-connection state that only makes
  sense with a server attached, and a Settings bundle can read neither the Keychain item nor the
  account list.

## Do not regress

- `SettingsView`'s **confirmed** sign-out and its footer explaining what is deleted. It used to fire
  on the first tap. (And after gap note 1 lands, it must remain the *only* path that deletes the
  cache.)
- The grouping of `SettingsView` by owner ("Mail" / "This device"), and the mailbox-count and
  degraded-account summaries on the collapsed rows.
- `RemoteImagesView` — the only place in either client where a granted remote-image permission can be
  taken back. Android has no equivalent.
- `AppearanceView`'s footer explaining that message bodies stay on white in dark mode. Removing it
  turns a deliberate decision into a bug report.
- `CredentialStore`'s three Keychain attributes and the `Metadata` comment packing (one write, one
  delete, nothing that can disagree with itself).
- `PushSubscriptionSet.Subscription.encode(to:)`'s hand-written encoder. Swift's synthesised encoding
  omits nil optionals, which turned "forget this device" into "change nothing" — and in a JMAP `/set`
  patch absent and null genuinely differ.
- `PushDelegate`'s `@objc` completion-handler form of
  `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. The `async` variant is never
  called and `nonisolated` breaks it too. It must also answer `.noData` honestly when nothing is
  signed in, or iOS throttles the app.
- `AppModel.requestPushIfUseful()`'s separation of *registering* (free, always) from *prompting*
  (one-shot, only when the server can actually send) — while decoupling the local-notification prompt
  from it per gap note 2.
- `Capability.supportedInUsing` **excluding** `urn:plmail:params:jmap:push`. That URN in `using` is a
  hard 400. (The `.apns` entry beside it is the bug; the `push` exclusion is the correct part.)
- `ServerTrust`'s four-branch policy, especially branch 4: a changed key on a pinned server is refused
  permanently and never degrades back into a prompt.
- `ServerSetupModel`'s ordering: nothing reaches the Keychain until a session has come back and the
  user has confirmed the username and mailbox list; the pairing code is not burned until exchanged.
- `BackgroundRefresh.schedule(noLaterThan:)` being resubmitted at the end of a run and on
  backgrounding, and `register`'s reschedule-first-then-work order.
- `RetryPolicy`'s full jitter and the one-breaker-per-server rule, with `NWPathMonitor` as the only
  thing that reopens a tripped circuit — time passing is not evidence that a NAS came back.
- `ServerDiagnosticsView`'s limits read from the live Session rather than restated as constants, and
  the deliberately **unlocalised** copied report.
- The free-tier signing default (`App/Config/Signing.xcconfig.dist` → `plMail-free.entitlements`).
  Requesting APNs or an App Group under a personal team fails the build outright rather than
  degrading.
- `Widget/PLMailWidget.swift`'s "Needs a paid developer account" face. A fabricated zero would be
  worse than an honest blank.
