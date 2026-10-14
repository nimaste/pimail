# The parity plan

Written for whoever runs the implementation — likely a supervisor directing agents,
so it is ordered by **what can safely run at the same time**, not by what matters
most. The value ranking is in the audits; the scheduling is here.

Current state, measured rather than assumed: **337 tests green**, `xcodebuild`
clean for the iPhone simulator, working tree clean on `main`. iOS is 171 Swift
files / ~30k lines against Android's 357 Kotlin files / ~81k lines, and the whole
of Android's calendar has no iOS counterpart at all.

Read [00-HOUSE-STYLE.md](00-HOUSE-STYLE.md) before writing a line. The five audits
([01](01-mail-reader-sync.md), [02](02-compose-send.md), [03](03-calendar.md),
[04](04-settings-push-onboarding.md), [05](05-search-labels-design-ipad.md)) carry
the wire shapes, the edge cases and the per-gap designs; this file does not repeat
them and no wave below should be started without reading its own audit first.

---

## Ground rules for every agent

**`pl_mail/` and `pl_mail_android/` are read-only.** Never edit, fetch or check
anything out in either. Read the server with `git show origin/main:<path>` — and
`cd` into `pl_mail` first, because the shell's working directory resets between
calls and a bare `git show origin/main:…` will otherwise resolve against the wrong
repository and return plausible-looking output from the wrong tree. Notes and
requests about those projects go in `.md` files here.

**The `pl_mail` working tree is stale** — it sits at `71d5474` (2026-07-31) and has
no calendar code and an older filter compiler. The real server is `origin/main`
(`132c1bf`, v0.1.9). Four of five audit agents independently drew a wrong
conclusion from that tree, and two of those would have changed a design. Any claim
of the form "the server does not support X" must be re-checked against
`origin/main` before it is acted on.

**Definition of done, per wave:** `swift test --package-path Packages/PLMail`
green with new tests covering the new behaviour; `xcodebuild build` clean for
**both** an iPhone and an iPad destination; `swift format lint --strict --recursive
App Packages` silent; every new user-visible string in **both** `en.lproj` and
`de.lproj`; and `CatalogueCoverageTests` still passing.

**Parallel agents get git worktrees.** Waves below are grouped so that concurrent
agents do not share files. Where they must, the wave is serialised — noted
explicitly. The supervisor owns merges.

---

## The file-collision map, which is what forces the ordering

Four files are touched by many otherwise-unrelated gaps, and they are the reason
this is not simply "run twelve agents":

| File | Wanted by |
|---|---|
| `PLMailCore/Store/SchemaV1.swift` | action queue, label colour/nesting, categories, calendar cache |
| `PLMailCore/Store/SyncStore.swift` | action queue, feed projection, categories, calendar |
| `PLMailUI/MailView.swift` | iPad work, calendar shell, categories, compose placement |
| `PLMailCore/Compose/ComposeModel.swift` | draft autosave, scheduled send, signatures, recipients |

So: **all schema changes land once, first, in Wave 1**, and the two composer waves
are serialised against each other.

---

## Wave 1 — correctness, security, and every schema change (serial, one agent)

Small, unambiguous, and everything else waits on its schema half. Nothing here is
a feature; it is the set of things that are wrong today.

1. **An expired app password deletes the offline mailbox.** `MailSyncService.requestReauthentication()`
   → `AppModel.signOut()` (`App/AppModel.swift:99`), and `signOut()` deletes the
   Keychain item *and* runs `SyncStore.deleteEverything()`. A revoked or rotated
   credential destroys every cached message and every queued draft. Offline mail is
   this app's headline feature and a 401 is not consent to delete it. Build the
   non-destructive re-auth state specified in [04 gap 1](04-settings-push-onboarding.md).
2. **`ServerAddress.parse` preserves `user:password@`** into every request's base
   URL. Reject it, as Android does.
3. **No cleartext warning before the app password crosses `http`.** `isCleartext`
   is currently consumed only by Diagnostics — i.e. after the secret has gone.
4. **The APNs capability breaks every request if push is ever enabled.**
   `Capability.swift:20-23` puts `urn:de:plmail:params:jmap:apns` in
   `supportedInUsing`; the server refuses the whole request with `unknownCapability`.
   Latent only because entitlements gate it today.
5. **All schema additions, in one migration-free change** (the store is a
   disposable cache, so this is a delete-and-resync, not a migration): the pending
   mutation queue, `StoredMailbox.color` and `parentId`, thread category and
   `isNew`, and the calendar entities from [03 §3](03-calendar.md). Land the
   *shapes* now even where the feature lands later, so Wave 2+ never collide here
   again. Snapshot types alongside, since `@Model` never crosses an actor boundary.

**Exit:** regression tests that a 401 keeps the cache; that a credential-bearing
URL is refused; that `using` never carries an unsupported URN.

---

## Wave 2 — three agents in parallel, disjoint files

**2A · Offline durability.** The action queue ([01 gap 1](01-mail-reader-sync.md))
and feed projection ([01 gap 2](01-mail-reader-sync.md)). Today a change made with
the server unreachable is rolled back and silently lost, and only the *visible*
list's head is corrected, so mail archived in the browser stays on screen
everywhere else. Files: `PLMailCore/Sync/{MailActions,DeltaSync,MailSyncService}.swift`,
`Store/SyncStore.swift`. The largest core-correctness item in the audit.

**2B · Local notifications.** iOS posts none — the only `UserNotifications` call
in the tree is `requestAuthorization` at `App/PushDelegate.swift:108`. This needs
**no APNs key, no App Group and no paid account**; a background refresh that finds
new mail can post today. Per-thread grouping, archive/mark-read actions, and the
scope preferences from [04 gap 8](04-settings-push-onboarding.md). New
`PLMailCore/Notifications/`, plus `App/{PushDelegate,BackgroundRefresh}.swift`.
Do it with `UNNotificationContent` + communication notifications, not a port of
Android's channels.

**2C · Search and label correctness.** [05 A1–A13](05-search-labels-design-ipad.md):
the missing `cc:` and `label:` operators, the `in:` vocabulary wrong in both
directions, unknown values now falling back to free text, label colour (a closed
nine-token vocabulary the server both emits and accepts), nesting, and the
unbatched `SearchSnippet/get` that silently loses all highlighting past 500 ids.
Files: `PLMailCore/Search/*`, `PLMailUI/{Labels,Sidebar,Search}/`.

---

## Wave 3 — calendar (runs alongside everything from here on)

Almost entirely **new files**, which makes it the most parallelisable large piece
of work in the plan. Follow the six phases in [03](03-calendar.md) in order;
phase 0 proves the wire in JMAPKit with no UI, which is where the fixtures pay off.

The three rules that shape it, all confirmed against `origin/main`:

- **No `/changes`, no push, no timer.** `state` and `queryState` are the literal
  string `"fixed"` and `canCalculateChanges` is false. Refresh the visible window
  while somebody is looking, and never otherwise — this audience runs the server
  on a NAS.
- **The server expands recurrences**; the client never does, because a phone and
  the browser would disagree at a DST boundary.
- **Thirteen writable properties.** No participants, no RSVP, no alerts, no
  attachments — refusals are loud and name the property. Do not build an
  invitation card; that flow exists only behind HTTP controllers.

One consequence is a user-visible absence the interface has to explain rather than
hide: **an unaccepted invitation is invisible, not merely unanswerable.** RSVP is
what materialises occurrence rows, so an unanswered invite is absent from
`CalendarEvent/query` altogether. Left unexplained that reads as a sync bug. And
the server already *pushes* `CalendarAlert` reminders to a registered device while
offering no way to set an alert — so the client handles that payload and schedules
nothing of its own.

Take the iPad design from [03 §5.2](03-calendar.md) rather than porting Android's
month grid, whose dots-instead-of-chips compromise exists solely because a 411 dp
cell fits four characters.

---

## Wave 4 — composing (serialised internally: 4A, then 4B)

**4A · Drafts.** iOS never writes a draft to the server at all — the first
`Email/set` happens at delivery, and dismissing the composer silently discards
everything typed. This is the prerequisite for most of 4B, because scheduled send,
cancel and undo all address a submission by Email id. Also fixes reopening a draft
dropping Bcc and attachments, and the absent attachment ceiling (bytes are
currently held in memory, on disk, and again at upload). Mind the whole-value
attachments array: an accidental `[]` deletes the blobs, and one unresolvable blob
id fails the entire patch including the subject.

**4B · Sending, on the server's terms.** Scheduled send moves server-first with
the on-disk outbox as the offline fallback — the README's apology that a held
message "may be a little later" stops being true when `HOLDUNTIL` means it leaves
on time with the phone in a drawer. Undo-send re-spec'd on `undoStatus: "canceled"`
instead of blocking the composer for five seconds. Signatures (real, writable per
alias) and `Contact/autocomplete` — the latter with the privacy trade-off stated
in the UI, since today contacts never leave the device.

**4C · `mailto:` (independent, can run any time).** `App/Info.plist` registers
only `plmail://`, and `RootView.onOpenURL` discards URLs once signed in. The share
extension is a separate matter — see Blocked.

---

## Wave 5 — appearance, then iPad (serialised: 5A, then 5B)

**5A · Ground the palette and adopt `Appearance`.** There is no asset catalogue at
all, so `Color.accentColor` is system blue, and `ResolvedTheme` is a 19-line
placeholder whose own comment says it is waiting for a server API — which now
exists: `Appearance/get`/`Appearance/set` over `urn:plmail:params:jmap:appearance`,
a singleton with 28 properties, published vocabularies and ranges in the Session,
clamping rather than refusal on numerics. Largest single UI piece.

**5B · Make the iPad keyboard-drivable.** The layout is structurally sound — the
pane treatment is the best thing in the app and better than Android's — but there
is no `⌘` menu, no list keyboard navigation, no drag and drop between panes, no
pointer hover, no multi-window, and exactly one breakpoint doing four jobs. Today
an iPad running plMail is correctly proportioned and cannot be driven from a
keyboard and trackpad. Mostly additive on a sound structure. Priorities and effort
sizing are in [05 P1–P7](05-search-labels-design-ipad.md).

---

## Wave 6 — completeness

Reader gaps ([01 gaps 5–11](01-mail-reader-sync.md)): raw source, save-attachment
to a chosen location, per-message read marking, bulk snooze, undo accessibility
timeout, body prefetch for offline reading. Then inbox categories and the New
marker ([01 gaps 13–14](01-mail-reader-sync.md)) — note that failing to report
displays does not merely cost a badge here, it leaves the *user's other clients*
wrong, because only a client that draws a row can retire that row's marker.
Finally the accounts screen, diagnostics and the push log built on the existing
`EventSourceClient` ([04 gaps 6–9](04-settings-push-onboarding.md)).

---

## Blocked, and not to be started

- **Remote push.** Needs an APNs key (paid account) **and** unwritten server work.
  The good news from [04 gap 5](04-settings-push-onboarding.md): `PushSenderRegistry`
  is built from an iterable of tagged senders and `PushDispatcher` never names one,
  so an APNs sender is one enum case, one class and one create-shape — the
  dispatcher, delivery log and verification handshake come free.
- **Widget data and a share extension.** Both need an App Group.
- **Mac Catalyst.** [05](05-search-labels-design-ipad.md) recommends against it.

## To be written up for other projects, not fixed here

- **For plMail:** RSVP over JMAP is the **top** ask — not for completeness but
  because an unanswered invitation is invisible to every JMAP client, so the
  calendar is silently incomplete until it is answered somewhere else. Then an
  APNs sender, and the rest of the invitation flow, which today exists only behind
  `InviteController`/`InviteResponder`.
- **For plMail for Android:** `in:archive` — iOS is right and Android is not; and
  `Signatures.kt` documents a round-trip that cannot work, because the server's
  `MailBodySanitizer` strips every `data-` attribute from stored draft bodies, so
  the `data-pl-signature` marker is consumed and discarded at save time.

---

## What "parity" is being read to mean

Everything Android's users can do, done the Apple way — not a transcription of
Android's UI. Three consequences worth stating before anyone starts:

Android's own [REMAINING.md](../../../pl_mail_android/docs/REMAINING.md) lists real
defects (no accessibility sweep, an in-memory send queue that does not survive the
process). Those are **not** parity targets. iOS already solves the second one
properly with an on-disk outbox.

Where the audits found iOS ahead, each doc carries a **Do not regress** section.
Read it. `MailView`'s single `NavigationSplitView` across both idioms, configurable
swipe edges, per-sender remote-content trust, find-in-conversation, the confirmed
sign-out, EXIF/GPS stripping, and the deliberately unlocalised diagnostics report
are all things a careless port would take away.

And where a client is simply wrong against the server, parity sometimes means
Android moving. `in:archive` is the worked example.
