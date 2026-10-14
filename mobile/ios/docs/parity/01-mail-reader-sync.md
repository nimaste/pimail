# Parity audit 01 — mail list, thread reader, sync engine, offline/caching, undo, swipe actions, snooze, list-state notifications

Reference client: `pl_mail_android` (Kotlin/Compose). Target: `pl_mail_ios` (SwiftUI).
Server: `pl_mail` (PHP/JMAP), read at `origin/main` — see the version note immediately below.

## Server version note

**The `pl_mail/` working tree in this workspace is checked out at a stale commit** (`71d5474`,
2026-07-31). The current server is `origin/main` (`132c1bf`, "release: v0.1.9"), which is what
the Android client is built against. The stale tree is missing, among other things, the whole
calendar layer, `Contact/autocomplete`, `Appearance/get`/`set`, and the `threadCategory` /
`isNew` extensions this document depends on.

**Read server files with `git show origin/main:<path>`. Do not check out, fetch, or modify
`pl_mail/` in any way.**

```
git show origin/main:src/Jmap/README.md
git show origin/main:src/Jmap/Method/Mail/ThreadSetMethod.php
git show origin/main:src/Jmap/Query/EmailFilterCompiler.php
git show origin/main:docs/CLIENT_DEVELOPMENT.md
```

An earlier revision of this document concluded from the working tree that inbox categories and
the New marker were "server-blocked". That was wrong — it was reading a month-old checkout.
Every server claim below has since been re-verified against `origin/main`. If you find yourself
about to write "the server does not support X", check the commit you are reading first.

## Summary

iOS is structurally close to Android in the parts that matter most: both keep a materialised
feed table on disk, both page a k-way client-side merge across accounts with the same
inclusive-boundary cursor design, both run `Email/changes` delta sync with the same 256/100
chunking, both apply actions locally-first and offer undo. In several places iOS is
*better* — user-configurable swipe edges, server-side "mark all as read", find-in-conversation,
per-sender remote-content trust, three-state empty views, `SearchSnippet/get` highlighting,
and a live `EventSource` stream that Android only opens as a fallback.

The gaps cluster in four areas. **(1) Offline durability**: iOS has no outbox for mail
*actions* — a change made with the server unreachable is rolled back and lost, where Android
queues it, shows a pending count, and flushes it under a network constraint. **(2) Feed
projection**: iOS only corrects the feed rows of the *visible* list, and only its head, so a
conversation archived in the browser stays on screen in every other cached list. **(3) Local
notifications**: iOS has no user-visible new-mail notification at all — only a silent push that
triggers a sync — where Android has per-account channels, per-conversation `MessagingStyle`
notifications, group summaries, archive/mark-read actions and inline reply. **(4) Reader
completeness**: no raw-source view, no per-message read marking, no attachment save-to-Files,
no per-message overflow.

A fifth area is **inbox categories and the New marker**: `CategoryBundleRow.kt` and
`ShownThreads.kt` have no iOS counterpart, and both are fully supported on the server today
(`Email/query` `threadCategory`, `Thread.category`, `Thread.isNew`, `Thread/set` `isNew:
false`). Not reporting displays is not merely a missing badge on iOS — it leaves the *user's
other clients wrong*, because only a client that draws a row can retire that row's marker.

---

## Gaps

| Feature | Android source | iOS status | Notes |
|---|---|---|---|
| Offline action queue (outbox for archive/star/label/snooze/read) | `core/data/Outbox.kt`, `MailActions.kt:267 queued()`, `SyncWorker.kt requestFlush` | **missing** | iOS `MailActions.apply` reverts the optimistic change on any send failure. Nothing is retried, ever. |
| "N changes waiting" / offline banner with pending count | `feature/mail/MailViewModel.kt OfflineState`, `MailScreen.kt:296` | **partial** | iOS shows `sync.bannerMessage` only, and only when the list is non-empty. No pending count, no device-vs-server distinction. |
| Device-offline vs server-unreachable distinction | `core/data/Connectivity.kt` (`NET_CAPABILITY_VALIDATED`) | **missing** | iOS has `NWPathMonitor` in `App/AppModel.swift` but only uses it to reset the circuit breaker; the UI never says "you are offline". |
| Per-account "could not reach X" banner with Retry | `MailScreen.kt:338-380`, `FeedRepository.answered()` | **partial** | iOS `ThreadListView.degradedSection` names the account but offers no retry button and does not distinguish whole-server failure. |
| Feed projection — sync writes conversations into/out of *every* live list | `core/data/FeedProjection.kt` | **missing** | iOS `DeltaSync` updates objects only; `MailSyncService.handle` refreshes the head of the visible feed alone. |
| Row removal for mail archived/moved elsewhere | `FeedProjection.project()` `clearThread` | **partial** | iOS only via `spliceFeedHead` (rows at/above the fresh head boundary) and `removeEmails` on destroy. |
| Local new-mail notifications | `core/notifications/` (8 files), `core/data/NewMail.kt` | **missing** | iOS `App/PushDelegate.swift` handles silent pushes only; nothing is ever posted to `UNUserNotificationCenter`. |
| Notification actions (Archive / Mark read) | `core/notifications/NotificationActions.kt` | **missing** | — |
| Inline reply from a notification | `core/notifications/InlineReply.kt` (497 lines) | **missing** | Includes send-failure notification that preserves the typed text. |
| Notification grouping + per-account channels | `MailChannels.kt`, `MailNotifier.kt`, `SummaryContent.kt` | **missing** | — |
| Notification scope preferences (per label / per category) | `core/data/NotificationScopes.kt`, `NotificationSettings.kt` | **missing** | — |
| App icon badge / unread surfacing | `MailChannels.setShowBadge` + platform child count | **partial** | iOS writes `SharedMailState` for the widget (`Store`/`Shared/SharedMailState.swift`) but never sets `UNUserNotificationCenter.setBadgeCount`. |
| View raw message source (`m-<id>` blob) | `feature/mail/reader/MessageSourceSheet.kt`, `ReaderViewModel.showSource` | **missing** | No equivalent anywhere in `PLMailUI/Reader/`. |
| Share message source | `ReaderScreen.kt shareText()` | **missing** | — |
| Save attachment to a user-chosen location | `ReaderViewModel.saveAttachment`, `ReaderScreen.kt savePicker` | **missing** | iOS `AttachmentRow.swift` + `.quickLookPreview` can only preview. |
| Per-attachment busy state + typed failure messages | `ReaderViewModel.busyAttachments`, `ReaderFailure`/`FailedAt` | **partial** | iOS has no download-failure surface for attachments. |
| Per-message overflow menu in the reader | `ReaderScreen.kt MessageMenu` | **partial** | iOS `MessageView.swift:150` has a per-message menu but only Reply/Reply-all/Forward. |
| Mark read per message, on expansion | `ReaderScreen.kt:550 onDisplayed`, `ReaderViewModel.markRead(uid)` | **partial** | iOS `ThreadLoader.markRead()` marks **every** unread message in the thread once the thread is shown. |
| "Show original" for colour-transformed messages | `reader/MessageColorProfile.kt` + `ReaderScreen.kt:654` | **partial** | iOS ports `MessageColorProfile` to `PLMailCore/Reader/` but `MessageView` offers no original/adapted toggle. |
| Snooze presets: "Tomorrow evening" absent from snooze | `feature/mail/Snooze.kt` (4 presets) | **present (better)** | iOS `TimePreset` shares presets with send-later and drops colliding entries. |
| Unsnooze ("Wake now") from a list row | `MailScreen.kt SelectionBar isSnoozed` | **present** | iOS `SnoozeMenu(isSnoozed:)` in the row context menu and the reader. |
| Snooze in bulk (selection) | `MailScreen.kt SelectionBar onSnooze` | **missing** | iOS `MailActions.BulkAction` has no `snooze` case; the bulk bar offers Archive/Labels/Read/Star/Trash only. |
| Exact per-conversation undo of a bulk snooze | `core/data/MailAction.kt wayBackFrom`, `MailActions.wayBack` | **missing** | iOS `MailActions.snooze` always undoes to `nil` (wake), losing a previous snooze time. |
| Undo window extended for accessibility timeout | `feature/mail/ActionUndo.kt` (`calculateRecommendedTimeoutMillis`) | **missing** | iOS `MailActions.undoWindow` is a flat 6 s. |
| Undo of an undo | `MailActions.undo()` rebuilding `steps` | **missing** | iOS `pending` is cleared by `undo()`; there is no way back from the way back. |
| Undo survives leaving the screen it was started on | `feature/mail/MailPane.kt` hosts the snackbar above both panes | **present** | iOS `MailActions` is app-scoped; `.undoOverlay` is applied in both list and reader. |
| Queued-vs-applied-vs-rejected outcome wording | `core/data/MailAction.kt ActionOutcome` | **partial** | iOS has Applied and Rejected (`MailActions.failure`); no Queued, because there is no queue. |
| Inbox categories as feeds (Gmail tabs) | `core/data/Categories.kt`, `FeedRepository.category()` | **missing** | Server-side filter `threadCategory` exists. `FeedID` has no category case. |
| New-mail bundle rows above Primary | `feature/mail/CategoryBundleRow.kt`, `core/data/CategoryDigest.kt` | **missing** | Depends on categories + `Thread.isNew`. |
| "New" badge on a list row | `MailViewModel.badgedNew`, `core/ui` `ThreadRow(isNew:)` | **missing** | `Thread/get` returns `isNew` today; iOS never requests or stores it. |
| Reporting displays to the server (retiring the New marker) | `core/data/ShownThreads.kt` | **missing** | `Thread/set` `isNew: false`. Not doing this leaves the *web UI* wrong. |
| Label chips on a list row | `core/data/Labels.kt rowLabels`, `core/ui` `RowChip`, `MailScreen.kt:653` | **missing** | iOS `ThreadRowView` shows account tag + snooze badge only. The reader header does show label chips. |
| Adaptive three-pane shell | `feature/mail/MailShell.kt` + `MailPane.kt` | **present (better)** | iOS `MailView.swift` uses `NavigationSplitView` with one selection binding for both idioms. |
| End-of-list footer ("that's everything on this device") | `MailScreen.kt EndOfList` | **missing** | iOS list simply stops. |
| Append spinner while paging | `MailScreen.kt:693` | **missing** | `ThreadListView.loadMoreIfNeeded` shows nothing. |
| Empty state that distinguishes loading / never-synced / empty | `MailScreen.kt hasNothingToShow` | **present (better)** | iOS `ThreadListView.emptyState` has four cases including `unauthenticated`. |
| Cold-launch scroll reset (open at the top once per destination) | `MailViewModel.claimStartAtTop` | **missing** | Not obviously needed on iOS; `List` does not restore an offset the way `LazyColumn` does. Verify before implementing. |
| Body prefetch for offline reading | `core/data/BodyPrefetcher.kt` (budget 50/account, 60-day eviction) | **missing** | iOS fetches bodies only when a thread is opened (`ThreadLoader.fetch`). |
| Periodic background sync | `core/data/SyncWorker.kt` (15 min, `NetworkType.CONNECTED`, exponential backoff) | **present** | iOS `App/BackgroundRefresh.swift` `BGAppRefreshTask`, 15 min, plus an earlier request when the outbox is due. |
| Flush-on-network-return | `SyncWorker.requestFlush` under a network constraint | **partial** | iOS drains the *compose* outbox on `NWPathMonitor` and on foreground; there is no action outbox to flush. |
| Blob/body cache retention policy | `BodyPrefetcher.prune()` 60 days | **missing** | iOS `Store/BlobCache.swift` — check its eviction; no body eviction exists in `SyncStore`. |
| Live updates (SSE) lifecycle | `core/data/LiveUpdates.kt` (only when push is silent) | **present (better)** | iOS `MailSyncService.beginLiveUpdates/endLiveUpdates` bound to scene phase and to the visible feed. |
| Duplicate-sync suppression on a chatty stream | `core/data/StateChangeApplier.kt` (skip when the Email token is unchanged) | **missing** | iOS `MailSyncService.handle` runs a full `delta.pull` for every `StateChange`. |
| Re-page signal to an on-screen list | `core/data/RepageSignal.kt` + `FeedMediator.needsRepage` | **present (different)** | iOS `SyncStore.clearCursors` deletes the account's `StoredFeedEntry` rows; `@Query` re-renders. Simpler and correct. |
| Pull-to-refresh covering both the re-page and the delta sync | `MailScreen.kt PullToRefreshBox`, `MailViewModel.isSyncing` | **present** | iOS `.refreshable { await sync.refresh(feed:) }` does structure + delta + first page. |

---

## Detailed gap notes

### 1. Offline action queue (outbox for mail actions)

**What Android does.** `core/data/Outbox.kt` persists a JSON queue of `PendingMutation`
(`ARCHIVE, MOVE_TO_INBOX, TRASH, STAR, MARK_READ, SPAM, LABEL, SNOOZE` × targets ×
`queuedAt` × payload). `core/data/MailActions.kt` applies every action to the local cache
first, then sends. `IOException` or an unreachable-host error does **not** roll back: it calls
`queued()`, which enqueues the mutation and asks WorkManager for a flush under a
`NetworkType.CONNECTED` constraint, and returns `ActionOutcome.Queued(undoable, host)`. A
*server rejection* (a 200 with `notUpdated`, or any other exception) is the opposite case and
is **not** queued — replaying a refusal loops forever — it becomes
`ActionOutcome.Rejected`. `Outbox.drain` stops at the first transport failure and leaves the
failing item at the head, preserving order (star-then-unstar is not commutative). A `LABEL`
mutation whose label key no longer resolves is dropped and counted as sent, so the queue can
always empty. `Outbox.pendingTargets()` is read by `FeedProjection` before it rewrites a feed,
so a sync cannot resurrect a conversation the user archived offline.

**What iOS does.** `Sync/MailActions.swift:515` — on a failed `send`, it calls `dismissUndo()`,
`store.restoreFeedRows(removedRows)` and `refetch(target)`. The change is discarded. The user
archived a conversation on a train, watched the row leave, and it comes back with a "Couldn't
reach the server" toast. Nothing is retried when the network returns.

**Data/API needed.** No new server API. The wire calls are the ones `MailActions` already
builds (`EmailSet` variants in `JMAPKit/Methods/EmailSet.swift`, `ThreadSet` for snooze). What
is needed is a persisted queue and a re-resolution step for label ids: an iOS
`ActionTarget` carries concrete `EmailID`s and an `AccountID`, both stable, but
`setLabel` carries a per-account `MailboxID` that must be re-resolved from the user-scoped
`LabelID` at drain time — the same reason Android stores `labelKey` rather than a binding id.

**UX.** The undo toast must gain a third phrasing. Android's three sentences are deliberate:
"Archived" (the server knows), "Archived — waiting for nas.local" (this device is right and
the server has not caught up), "Couldn't archive: <reason>" (the server refused and the row
has been put back). The list gains a banner counting queued changes.

**Edge cases.**
- Distinguish transport failure from refusal. `JMAPError.unreachable`, `URLError`, and a
  request that never got a response are queue-worthy; `notUpdated`/`notDestroyed`, `forbidden`,
  `accountReadOnly`, `invalidProperties` are not.
- Order within an account must be preserved and the drain must stop at the first failure.
- An action queued for an account that is later disconnected must be dropped, not retried.
- The queue must be consulted before any code path re-writes feed rows from the server
  (see gap 2), or the sync will undo the user's offline gesture on screen.
- Persist alongside `Compose/Outbox.swift` (which already does exactly this for *sending*
  mail, scoped by `serverID`) — reuse its shape rather than inventing a second one.

### 2. Feed projection — keeping every list correct, not just the visible one

**What Android does.** `core/data/FeedProjection.kt` runs immediately after every
`storeEmails` on the sync path. For each changed conversation it reads the thread row (which
already carries `labelKeys` and `category`, written moments earlier), computes
`targetFeeds()`, and then, for every *live* feed the account has paged
(`feed().feedsPagedBy(accountKey)`, excluding search): deletes the row where the conversation
no longer belongs, and inserts it where it does — but only if it falls inside the window that
feed has actually paged (`isWithinWindow`: newer than the cursor's `lastSortDate`, or the
cursor is exhausted). A conversation from 2019 dragged back by a read receipt is not spliced
in under last week's mail. It is symmetric by construction: archiving in the browser removes
the row here.

**What iOS does.** `Sync/DeltaSync.swift` hydrates objects into `StoredEmail`/`StoredThread`
and stops. `Store/SyncStore.swift:793 removeEmails` deletes feed rows only when a thread loses
its last message. `MailSyncService.handle(_:)` calls `merge.refreshHead()` for
`visibleFeed` only, and `SyncStore.spliceFeedHead` replaces only rows with
`sortDate >= boundary` — the boundary being the oldest row of the freshly fetched first page.

**Consequences.** A conversation archived on the web sixty rows down the iOS inbox stays
there until that account's feed is reset. A conversation labelled `Work` on the web does not
appear in the iOS `Work` list until that list is opened and its head refetched. Every list
other than the one on screen drifts.

**What to build.** A `FeedProjection` equivalent in `PLMailCore/Sync/`, called from
`DeltaSync.hydrate` after `store.upsert`. It needs, per account: the set of feed ids that have
a `StoredFeedCursor` (`SyncStore` has `cursor(feedID:accountKey:)` but no "which feeds exist"
query — add one), the inbox `MailboxID`, and for each changed thread its current
`mailboxIDs`. `SyncStore.mailboxIDs(threadID:accountKey:)` already exists (line 739). Feed
membership on iOS is expressed by `FeedID` (`Sync/FeedID.swift`): `.unified(role)`,
`.unifiedLabel(labelID)`, `.mailbox(accountKey, mailboxID)`. Map a thread's mailbox set to
those three shapes and reconcile.

**Edge cases.**
- Never project a thread whose id is in the pending action queue (gap 1).
- Never project into `.searchResults` feeds — those rows answer a question, not a state.
- Respect the paged window, or old mail appears above rows newer than it.
- One transaction per batch; `SyncStore` is `@ModelActor`, so batch the `modelContext.save()`.

### 3. Local new-mail notifications

**What Android does.** `core/data/DeltaSync.kt` computes `newArrivals()` *before* the write —
"new" means "this device has never held it", not "the server called it created", which is what
stops a re-indexed message from ringing the phone at 3 a.m. It filters on `!isSeen`, on the
notification scope preferences, and finally through `NotifiedMessageStore.claim()`, a
serialised DataStore edit that guarantees exactly one of two concurrent syncs announces a
message. Then `core/notifications/MailNotifier.kt` posts one `MessagingStyle` notification per
*conversation* (id `"$accountKey#$threadId".hashCode()` so a reply replaces rather than
stacks) plus one `InboxStyle` group summary per account, in a per-account channel
(`MailChannels.kt`). Each conversation notification carries three actions: Archive, Mark read,
and an inline Reply with a `RemoteInput`. `NotificationActions.kt` cancels the notification
first and does the server work on the application scope afterwards. `InlineReply.kt` posts a
separate, non-auto-cancelling failure notification that preserves the typed text and offers
"Try again" only when the failure was transport-level.

**What iOS does.** Nothing user-visible. `App/PushDelegate.swift` receives silent pushes and
calls `AppModel.refreshInBackground()`. `PushRegistrar` registers a token; the payload
deliberately carries no mail content (documented in `PushDelegate`'s header, and correct — see
Do not regress).

**What to build.** A local-notification layer that runs after `DeltaSync.hydrate` (and after
`refreshInBackground`) and posts `UNNotificationRequest`s for genuinely new, unseen messages.

**Data/API needed.** Everything is already in `EmailGet.listRowProperties`: sender, subject,
preview, `receivedAt`, `threadId`. The "has this device seen it" test needs a pre-write
`existing(StoredEmail.self, uid:)` check in `SyncStore.upsert` — the current `upsert` does not
report which ids were new. Add a return value or a companion query.

**UX.**
- `UNNotificationRequest.identifier` = `"\(accountKey)#\(threadID)"`, so a reply to a thread
  replaces its banner.
- `threadIdentifier` = the same, and `UNNotificationContent.categoryIdentifier` per account so
  actions attach. iOS groups by `threadIdentifier` automatically; there is no summary
  notification to build by hand.
- `UNNotificationAction`s: Archive (`.destructive` is wrong here — Archive is reversible),
  Mark as read, and a `UNTextInputNotificationAction` for Reply.
- Tapping opens the conversation. `PLMailCore/Shared/IntentRouter.swift` is the existing seam
  for "something outside the view hierarchy chose a destination" — route the deep link through
  it rather than adding a second mechanism.

**Edge cases.**
- Cancel a posted notification when the message is later read elsewhere. Android does **not**
  do this (confirmed gap on their side) — iOS should, via
  `removeDeliveredNotifications(withIdentifiers:)` after a delta pull observes `isSeen`.
- Do not announce mail already read on another client: filter on `isSeen` before posting.
- Do not announce during the first sync of a new account — every message is "new to this
  device". Gate on the account having a non-nil `emailState` before the pull.
- Notification permission: `AppModel.requestPushIfUseful()` already separates *registering*
  (free, silent) from *prompting* (a one-shot). Local notifications need the alert
  authorization, so the same gate applies — but a local notification works on a server with no
  APNs sender, so the prompt condition should widen accordingly.
- Ask for the badge count too: `UNUserNotificationCenter.current().setBadgeCount(_:)` with the
  unread total already computed in `MailSyncService.publishSharedState()`.

### 4. Notification scope preferences

**What Android does.** `core/data/NotificationScopes.kt` defines `NotifyScope.Category` and
`NotifyScope.Labelled`, keyed `"category:<wire>"` / `"label:<labelKey>"`. `NotificationPrefs`
is three-state: an explicit disable wins, then an explicit enable, then the default — which is
on only for Primary. `notifyScopeKeys()` derives a message's scopes from its mailbox bindings
(and its conversation's category), with a hard exclusion list
`NEVER_NOTIFIABLE_ROLES = sent, drafts, trash, junk, archive, all, snoozed`. A message under
three enabled labels produces one notification, not three.

**What iOS needs.** Once notifications exist (gap 3), a settings screen listing role mailboxes
and custom labels with per-label toggles, backed by `UserDefaults` (this is a client
preference the server neither knows nor can re-derive — the same argument
`List/SwipeActions.swift` makes for `SwipeActionPreference`). Without the category extension,
drop the category half entirely and offer only labels. Keep the never-notifiable role list.

### 5. Raw message source (`MessageSourceSheet`)

**What Android does.** Each expanded message with a non-null `blobId` gets a per-message
overflow (`ReaderScreen.kt MessageMenu`) with one item, "Show source".
`ReaderViewModel.showSource` opens the sheet immediately with no text and fills it in from
`blobs.text(accountKey:, blobId:, name: "message.eml", type: "message/rfc822")` — the name and
type are template variables the server echoes into `Content-Disposition` and `Content-Type`,
so asking for the wrong type gets the right bytes labelled wrong. The result is dropped if the
sheet has since been closed or moved to another message. The sheet
(`reader/MessageSourceSheet.kt`) is a full-screen dialog, monospace, **no soft wrap**, with
both horizontal and vertical scroll — folding a `Received:` chain at the device width destroys
the one thing anyone opens this view for — plus a Share action that appears only once the text
has arrived.

**What iOS needs.** `MessageSnapshot` must expose the message's own `blobId` (check
`Store/Snapshots.swift`; `EmailGet.readerProperties` must request `blobId`). Fetch through the
existing `DownloadContext.file(for:blobs:)` path — `BlobCache.file` already takes
`name`/`type`, so pass `message.eml` / `message/rfc822`.

**Edge cases.** A blob that has been evicted server-side; a message with no `blobId`
(hide the item rather than showing a dead one); a very large source (cap the fetch, and say so
rather than hanging).

### 6. Save an attachment to a location the user chooses

**What Android does.** `ReaderViewModel.saveAttachment(attachment, destination: Uri)` downloads
if needed, then copies through the content resolver into whatever the system picker returned —
a copy, not a move, so opening the attachment again does not go back to the server. The
download runs on the ViewModel scope so backing out of the reader mid-transfer does not throw
away fifteen megabytes. Per-attachment busy state (`busyAttachments: Set<String>`) means a
second tap on a spinning row is ignored rather than starting a second download, and failures
are announced with the server's own message appended after a translated sentence.

**What iOS does.** `Reader/AttachmentRow.swift` + `ThreadReaderView`'s
`.quickLookPreview($previewedAttachment)`. Preview only; nothing writes the file anywhere the
user chose, and a failed download surfaces nothing.

### 7. Mark read per message rather than per thread

**What Android does.** `ReaderScreen.kt:550` fires `onDisplayed` keyed on
`(message.uid, message.isExpanded)` — so only messages the user actually expanded are marked
read, and only when they are on screen. `ReaderViewModel.markRead(accountKey, uid)` patches
that one message.

**What iOS does.** `ThreadLoader.markRead()` collects every message in the thread with
`isSeen == false` and marks the lot, once, from `ThreadReaderView`'s `.task`. Opening a
40-message thread to read the newest reply clears the unread state of 39 messages the user
never saw. `ThreadReaderView.expandNewest()` already expands the newest *plus everything
unread*, which softens this in the common case but not in the case of a long thread where
`collapsedRange` folds the middle away.

**What to change.** Move the write to the message card: mark a message read when it is
expanded and visible, matching Android and matching the server guide's own rule
(`pl_mail/docs/CLIENT_DEVELOPMENT.md`: "Reading a thread marks it read, but only after it has
actually been shown — not on prefetch"). `SyncStore.setSeen(_:emailIDs:accountKey:)` already
takes a list, so this is a change of *when* and *which*, not of the write path.

### 8. Bulk snooze, and exact snooze undo

**What Android does.** The selection bar offers Snooze/Unsnooze over the whole selection
(`MailScreen.kt SelectionBar`). Crucially, `MailActions.wayBack()` reads each conversation's
existing `snoozedUntil` out of the cache *before* the write, and `wayBackFrom()` groups the
targets by that value into several `UndoStep`s — so undoing a bulk snooze restores each
conversation to the different time it was previously sleeping until, and the toast says "put
back" rather than naming one of them and being wrong about the rest. `UndoableAction.action`
is nullable precisely to express "it took more than one action to say".

**What iOS does.** `MailActions.snooze` builds one undo closure that always sends
`.snooze(threadID, until: nil)` — a re-snooze undone restores "awake", not the previous time.
`BulkAction` has no snooze case at all.

**What to build.** Add `case snooze(Date?)` to `MailActions.BulkAction`; read
`SyncStore.snoozedUntil(threadID:accountKey:)` for every target before writing; build the undo
as a list of per-time groups. The wire side is already there (`ThreadSet.snooze`, and the
server's `Thread/set` accepts up to 500 objects per call — `pl_mail/src/Jmap/Method/Mail/ThreadSetMethod.php`
`MAX_OBJECTS`), so a bulk snooze can be one request per account.

### 9. Undo: accessibility timeout, and undoing an undo

**What Android does.** `feature/mail/ActionUndo.kt` asks
`AccessibilityManager.calculateRecommendedTimeoutMillis(originalTimeoutMillis = 6_000, containsControls = true)`
and uses whatever the system returns — this is the one control in the app with a deadline, so
a fixed timeout silently excludes exactly the users who need the extra seconds. It also uses
`SnackbarDuration.Indefinite` plus an explicit `withTimeoutOrNull`, because Material's `Short`
is four seconds and four is not enough to watch a row leave and reach a button. And
`MailActions.undo()` builds the undone action's own `steps` from what each sub-apply worked
out, so an undo is itself undoable.

**What iOS does.** `MailActions.undoWindow` is `.seconds(6)`, flat. `undo()` sets
`pending = nil` and does not offer a way back.

### 10. Body prefetch for offline reading

**What Android does.** `core/data/BodyPrefetcher.kt` runs on background paths only — the
periodic worker and the push handler, explicitly **not** foreground sync or pull-to-refresh.
Budget 50 messages per account per run, chunked 20 per `Email/get` (against 100 for delta sync,
because bodies are large and the server is often a Raspberry Pi). Messages that genuinely have
no body get an empty `EmailBodyEntity` written so they stop consuming budget forever. `prune()`
evicts bodies older than 60 days, keeping the message rows.

**What iOS does.** Bodies are fetched only by `ThreadLoader.fetch()` when a thread is opened.
On a train, any conversation not previously opened shows nothing.

**What to build.** A prefetcher called from `AppModel.refreshInBackground()` after
`sync.refreshInBackground()`. `SyncStore.storeReaderContent(_:accountKey:)` is the existing
write path. Needs a "messages with no stored body, newest first, limited" query. Respect the
`BGAppRefreshTask` expiration handler — the work must be cancellable.

### 11. Duplicate-sync suppression on the live stream

**What Android does.** `core/data/StateChangeApplier.kt` compares the announced `Email` state
token against the account's stored `emailState` and *skips the sync entirely* when they match.
One bulk label edit in the browser produces dozens of `StateChange` events; without this,
each one costs an `Email/changes` round trip against someone's NAS.

**What iOS does.** `MailSyncService.handle(_:)` ignores the payload's token map and runs a full
`delta.pull(accounts:)` for every event, followed by a `refreshHead()` on the visible feed —
which is itself a fresh `Email/query` per account.

**What to build.** `JMAPKit/EventSource/EventSourceClient.swift` already parses `StateChange`.
Compare `change.changed[accountID]?["Email"]` against the stored `emailState` per account and
pull only the accounts that moved. This directly serves the server guide's rule: "Never poll
aggressively."

### 12. Per-account retry, whole-server failure, offline banner

**What Android does.** Three distinct sentences, chosen deliberately
(`MailViewModel.OfflineState`, `MailScreen.kt:296-380`):
(a) the device has no validated network — say so, and suppress the per-account banners because
every account is failing for the same reason; (b) this device has a network and *nothing*
answered (`SourceFailure.isWholeServer`) — name the host, and do not claim "the other accounts
are still up to date"; (c) one account failed — name it and the host, keep the others
refreshing, and offer Retry. `FeedRepository.answered(accountKey)` withdraws a banner the
moment that account answers anything, rather than waiting for a page load that may never come
on a list that fits the screen.

**What iOS does.** `MailSyncService.bannerMessage` collapses everything into one string from
`status`, shown only when `entries.isEmpty == false`.
`ThreadListView.degradedSection` lists degraded accounts at the *bottom of the list*, with no
retry. `degradedAccounts` is cleared wholesale on `refresh` and re-set from
`merge.failures`, so there is no per-account withdrawal.

**What to build.** Use the `NWPathMonitor` already in `AppModel` to publish a device-offline
flag; add a `Retry` button per degraded account calling `sync.refresh(feed:)` (or, better, a
per-account refresh); suppress the per-account rows while device-offline.

### 13. Inbox categories (Gmail tabs)

**Server support** (verified on `origin/main`). plMail classifies inbox mail into
`primary, social, promotions, updates, forums` — the five cases of
`src/Domain/Enum/Mail/MessageCategory.php` — and stores it twice:

- `Email.category` — the **raw per-message** signal. Emitted read-only by
  `src/Jmap/Mapper/EmailMapper.php`; deliberately **not** accepted as an `Email/query`
  condition.
- `Thread.category` — the **resolved conversation** value, most-recent-wins. Returned by
  `src/Jmap/Method/Mail/ThreadGetMethod.php` as `category`. This is the only one a tab may be
  drawn from.
- `Email/query`'s `threadCategory` condition — `src/Jmap/Query/EmailFilterCompiler.php`
  `threadCategory()`, compiling to
  `EXISTS (SELECT 1 FROM message_thread mt WHERE mt.id = m.thread_id AND mt.category = :x)`.
  A token outside the vocabulary is refused with `invalidArguments` **naming the valid set**
  (not `unsupportedFilter`).

`src/Jmap/README.md` and `docs/CLIENT_DEVELOPMENT.md` both spell out why the filter is
thread-scoped and server-side: a newsletter somebody replied to has messages in two
categories, so filtering the per-message column would put one conversation in two tabs; and
`Email/query` windows by position and limit, so a client that fetched a page and sieved it
locally would draw a nearly-empty Promotions tab under a list that had already reached its end.

**`null` category is not Primary.** A thread that was never classified (mail predating the
classifier, a locally-composed draft) matches no tab, exactly as the web's own
`MessageThreadRepository::findForUnifiedInbox` does. Folding it into Primary would put mail on
the phone's Primary tab that the browser's does not have.

**What Android does.** `core/data/Categories.kt` defines `MailCategory` with a `wire` value and
a `feedId`; `FeedRepository.category()` builds the pager filter as
`And([InMailbox(inbox), ThreadCategory(wire)])` — the inbox binding is part of the filter
because categories are an inbox idea and a conversation moved to Trash keeps its category.
`FeedProjection.targetFeeds()` places a synced conversation into its category feed by the same
rule, so the rows the pager fetches and the rows the sync projects are one list.

**The one deliberate exception.** On a server that classifies nothing,
`FeedRepository.category()` drops the condition for Primary only and pages the whole inbox.
That is what lets Primary be a constant start destination rather than something the app must
wait on a query to decide (`MailView.START`). The other four are simply not offered, because
`observeHasCategories()` is false and the sidebar draws none of them.

**What iOS needs.** `PLMailCore/Sync/FeedID.swift` has `.unified(role)`,
`.unifiedLabel(labelID)`, `.mailbox(accountKey, mailboxID)`, `.searchResults(raw)` — add a
category case. `MailSyncService.pager(for:account:)` builds the filter; add the
`.and([.inMailbox(inbox), .threadCategory(wire)])` arm. `JMAPKit/Mail/EmailFilter.swift` needs
a `threadCategory` case, and `Store/SchemaV1.swift`'s `StoredThread` needs a `category` column
fed from `ThreadGet`'s new property so the sidebar/digest can read it without a query.

**Edge cases.**
- Include the inbox binding in the filter, or the tab shows the bin's promotions.
- Never fold `null` into Primary.
- Detect "this server classifies nothing" once (any stored thread with a non-null category) and
  hide the tabs entirely rather than showing five empty ones.
- Category membership hangs off the inbox binding, so any action that removes that binding must
  remove the row from the category feed too — Android's `MailActions.clearFromInbox()` clears
  the unified inbox *and* the category feed for exactly this reason. Whatever iOS builds for
  gap 2 must do the same.

### 14. The New marker: `Thread.isNew`, and reporting displays back

**Server support** (verified on `origin/main`; documented at `docs/CLIENT_DEVELOPMENT.md`
§"The New marker: `Thread.isNew`").

> new = never displayed to this user **AND** arrived inside `MessageThread::NEW_WINDOW`
> (`PT24H`)

- **Reading.** `Thread/get` returns `isNew` (boolean) on every thread, always present.
  `ThreadGetMethod::handle` takes **one clock reading per response** so two threads in one
  answer cannot straddle the boundary. The window is applied server-side —
  `MessageThread::isNewAt()` — and the guide is explicit: do not re-implement the 24 hours
  client-side.
- **Retiring.** `Thread/set` accepts `isNew: false` and nothing else; `true` is refused with
  `invalidProperties` ("the marker is evidence, not a preference"). Up to 500 objects per call
  (`ThreadSetMethod::MAX_OBJECTS`). It is **idempotent** — `markListed()` carries its own
  `listedAt IS NULL` guard, so a repeat does not move the timestamp and the record keeps saying
  when the row was *first* shown. The guide says outright: "you may safely send it for every
  row on every draw."
- Retirement is deliberately **not** a `Thread` state change, so it does not push a state
  change to the user's other devices; the next ordinary `Thread/get` carries the new value.
- `Thread/set` may carry `isNew: false` and `Thread/get` in the *same* request — the method
  calls `entityManager->refresh()` on every retired thread precisely so the read-back in one
  POST is correct.

**New is not unread, and they are allowed to disagree.** A conversation read on a laptop is
still new to a client that has never drawn its row, and retiring the marker marks nothing read.

**What Android does.** `core/data/ShownThreads.kt` is the write half. Only the list calls
`report()`, and only for rows Compose actually composed — paging, a notification and the body
prefetcher all put conversations on the device without anybody seeing them, and none of those
is a display. Reports are collected into a `pending` map and flushed behind a `Mutex`, so a
scroll producing one call per row several times a second becomes a small number of requests
against what is frequently a Raspberry Pi; a flush already in flight simply takes the newer ids
with it, and nothing waits on the result. The local `isNew` column is cleared in the same
breath rather than waiting for the next `Email/changes`. On the read side,
`MailViewModel.badgedNew` holds the badge in memory for as long as the list is on screen —
because reporting the display is what *spends* the marker, and a badge bound to the column
would appear and vanish within a second while somebody was looking at it. The set is cleared
when the destination changes (a badge means "new since I last looked at *this list*"), spent
for one row by `threadOpened()`, and never persisted.

**What iOS needs.**
- Request `isNew` in the `ThreadGet` used by `UnifiedFeed.refreshHead`/`loadMore` and
  `DeltaSync.hydrate`; store it on `StoredThread`.
- An actor in `PLMailCore/Sync/` mirroring `ShownThreads`: batch thread ids, debounce, send
  `ThreadSet` with `isNew: false` grouped per account, clear the local column optimistically,
  never block the UI on the result, never retry aggressively.
- A `@State` badge set on `ThreadListView` keyed by feed, populated on first draw and held
  until the feed changes — not read live off `StoredThread.isNew`, for the flicker reason above.

**Edge cases.**
- Report only genuine displays. `.onAppear` on a row is a display; a `LazyVStack` prefetch, a
  background sync and a notification are not.
- Cap the batch at 500 per `Thread/set`.
- Clear the badge for a conversation the moment it is opened, or coming back from a message you
  just read to a row still shouting "New" reads as the app not noticing what you did.
- Do not persist the badge set: after a relaunch the server has already been told, so there is
  nothing new left, and restoring it would be the phone badging mail on its own memory rather
  than on the marker.
- Failure is cheap — the row will be drawn again.

---

## The Apple way

For each gap above, where the right iOS answer is not a port of the Android one.

**Offline action queue.** Do not port `SyncWorker.requestFlush`. iOS has no equivalent of a
constrained background work request. Use the mechanism `Compose/Outbox.swift` and
`App/BackgroundRefresh.swift` already use: persist the queue, drain on
`ScenePhase.active`, drain on `NWPathMonitor` reporting `.satisfied`, and pass
`outbox.nextDueAt` into `BGAppRefreshTask`'s `earliestBeginDate` — which `AppModel` does today
for scheduled sends. One queue mechanism for both mail and actions, not two.

**Undo.** Do not adopt `UndoManager` here despite the name. `UndoManager` is for a text-editing
undo stack scoped to a responder, and its `undoActionName`/`registerUndo` semantics do not
match "a network write that may be refused". Keep the current `MailActions.pending` +
`.undoOverlay` model — it is already the platform-correct shape (a transient bottom bar, glass,
self-dismissing). Two changes: read the accessibility timeout from
`UIAccessibility.isVoiceOverRunning` / `UIAccessibility.isReduceMotionEnabled`-style signals —
concretely, honour `UIAccessibility` guidance by extending the window when VoiceOver or Switch
Control is on, since iOS has no direct `calculateRecommendedTimeoutMillis` equivalent. And make
the undo re-arm after undoing, rather than clearing `pending`.

**Notifications.** Do not build a group summary notification. Android needs one because the
shade collapses a group without it; iOS groups automatically on `threadIdentifier`, and a
hand-built summary would appear as an extra banner. Use `UNNotificationCategory` +
`UNTextInputNotificationAction` for the inline reply rather than Android's `RemoteInput`
plumbing, and register categories once at launch. Use
`removeDeliveredNotifications(withIdentifiers:)` — Android has no equivalent and consequently
leaves stale banners for mail read elsewhere; iOS should not copy that limitation. Set the app
badge with `UNUserNotificationCenter.setBadgeCount(_:)`, not by counting delivered
notifications.

**Notification preferences.** Android needs a channel per account because channels *are* the
Android preference surface. iOS has one notification permission and one Settings pane. Do not
create per-account "channels"; put the per-label toggles in the app's own
`Settings/SettingsView.swift` as a `Form` of `Toggle`s, and link out to
`UIApplication.openSettingsURLString` for the system-level permission.

**Raw source.** Android uses a full-screen `Dialog` with `softWrap = false` and two scroll
axes. On iOS present it as a sheet with `.presentationDetents([.large])` from the message's
existing `Menu`, containing a `ScrollView([.horizontal, .vertical])` with
`Text(...).font(.system(.footnote, design: .monospaced))` and `.textSelection(.enabled)`.
Sharing is a `ShareLink(item:)` in the sheet's toolbar — not a hand-rolled
`UIActivityViewController`, and not Android's `Intent.ACTION_SEND` shape. Because the source
arrives as a file in `BlobCache`, `ShareLink(item: url)` with a `.eml` extension is better than
sharing the string: iOS previews it and the receiving app gets a real message file.

**Save attachment.** Android launches `ActivityResultContracts.CreateDocument` and copies
through a content resolver. On iOS, the destination picker is
`.fileExporter(isPresented:document:contentType:defaultFilename:)` — or, simpler and more
idiomatic, add `ShareLink(item: fileURL)` next to the existing Quick Look preview, since "Save
to Files" is one of the entries in the standard share sheet. Prefer `ShareLink`: it also gives
AirDrop, Mail and Messages for free, which `CreateDocument` does not.

**Attachment preview.** Already correct — `.quickLookPreview` is the system Quick Look, which
is better than Android's `ACTION_VIEW` chooser. Do not replace it.

**Per-message overflow.** Android uses a `DropdownMenu` off an icon button. iOS already has
`Menu` in `MessageView.swift:150`; add "View source" and "Show original" as items there rather
than adding a second control.

**Bulk snooze.** Android puts it behind a `DropdownMenu` in the selection `TopAppBar`. On iOS
add it to the existing `bulkBar` as a `Menu` wrapping `SnoozeMenu`, which is already the shared
component used by the row context menu and the reader — one snooze surface, three call sites.

**Category bundles.** Do not draw Android's sunken tile. The iOS equivalent of "mail is over
there" above a list is a `Section` at the top of the same `List` with
`.listRowBackground(Color.clear)` and rows that are `NavigationLink`s — the chevron comes free
and means the same thing. Better still on iPad: category feeds belong in the
`NavigationSplitView` sidebar as siblings of the role mailboxes, where iOS users expect
destinations to live, with the digest reduced to a `.badge()` on those sidebar rows. Android
needs the bundles *inside* the list because its sidebar is a drawer behind a hamburger; iOS's
sidebar is on screen on iPad and one swipe away on iPhone, so the tiles are solving a problem
iOS does not have. Consider shipping the sidebar rows first and the in-list bundles only if
iPhone users miss them.

**"New" badge.** Android holds the badge in the ViewModel because recomposition would flicker
it away. SwiftUI has the same hazard — `@Query` republishes the moment the column is cleared.
Hold it in a `@State` set on `ThreadListView` keyed by the feed, cleared on feed change. Report
displays from `.onAppear` on the row, debounced through an `actor`, exactly as `ShownThreads`
does with its `Mutex`. Use `.badge()` or a small capsule rather than porting Material's badge
styling. Do **not** reach for `SwiftData`'s change tracking to drive the report — the trigger
is "this row was drawn", which is a view-layer fact the store cannot see.

**Adaptive layout.** Nothing to do. `MailShell.kt` + `MailPane.kt` exist because Compose has no
built-in three-region adaptive container that also owns back behaviour; `NavigationSplitView`
does, and `MailView.swift` already uses it correctly with one selection binding across both
idioms. Do not introduce a `MailShell` equivalent.

**Empty and loading states.** `ContentUnavailableView` is already the right answer and is
richer than Android's. Keep it. If an end-of-list footer is added, make it a plain `Text` in
the list's last row rather than porting Android's `EndOfList` styling.

**Swipe actions.** Already `.swipeActions(edge:allowsFullSwipe:)` with a user preference —
strictly better than Android's fixed `SwipeToDismissBox`. Do not regress it to two hard-coded
edges.

---

## Do not regress

Things iOS already does better than the reference client. None of these should be traded away
while closing the gaps above.

1. **User-configurable swipe edges.** `PLMailUI/List/SwipeActions.swift` — six actions per
   edge including "Nothing", persisted in `UserDefaults` under namespaced keys, with a picker
   reachable from the list's own menu. Android hard-codes archive/trash in
   `SwipeableThreadRow.kt`. Every swipe action is also in the row's context menu, so turning an
   edge off removes the shortcut and never the action.
2. **Server-side "Mark all as read".** `MailSyncService.unreadTargets(in:)` queries the server
   for every unread message matching the feed's own filter, one `Email/query` + `Email/get` per
   account in a single POST, honours `maxObjectsInSet` (500) and *tells the user* how many were
   left over (`remainingBeyondLimit`, and the "Not everything fitted" alert). Android has no
   whole-list action at all.
3. **Find in conversation.** `PLMailCore/Reader/ThreadFind.swift` + `ThreadFindBar.swift`,
   including expanding a collapsed message that holds a match and scrolling the web view to the
   match's own fraction down the body. Android has nothing equivalent.
4. **Per-sender remote-content trust.** `PLMailCore/Reader/RemoteContentPolicy.swift` persists
   the decision by sender. Android's `ReaderViewModel.allowRemoteImages` is per message and per
   session — the decision is lost the moment you leave the reader.
5. **Three-plus-state empty view.** `ThreadListView.emptyState` distinguishes syncing,
   unauthenticated (with a Sign out action, and explicitly *not* a "try again"),
   failed-with-retry, never-synced, and genuinely empty. Android has two.
6. **`SearchSnippet/get` highlighting.** `MailSyncService.loadSnippets(for:)` runs after the
   rows are on screen and fails silently, so results appear at query speed and sharpen. Android
   does not use the method.
7. **Live updates scoped to the visible feed and the scene phase.**
   `MailSyncService.beginLiveUpdates(feed:)` / `endLiveUpdates()`, torn down on
   `.inactive`/`.background` in `AppModel.scenePhaseChanged`. Directly honours the server
   guide's "Don't hold an SSE connection in the background."
8. **Circuit breaker.** `Sync/RetryPolicy.swift` + `MailSyncService.refreshInBackground`, reset
   only by an `NWPathMonitor` path change rather than by time passing. Android retries on a
   fixed WorkManager backoff.
9. **Keyboard shortcuts.** `ThreadReaderView`'s toolbar carries Gmail's letters (e, r, a, f, l,
   u, s) plus platform-correct `⌘⌫` and `⌘F`; `MailView` binds `c` and `⌘N`. Android has none.
10. **Split-view selection survives rotation and Stage Manager.** One `ThreadRef?` binding
    drives both the iPad third column and the iPhone push (`MailView.swift`, `compactReader`).
11. **Reader header shows the conversation's labels and snooze state as chips**
    (`ThreadReaderView.header`) — Android shows labels only on list rows, not in the reader.
12. **Message details panel.** `Reader/MessageDetailsView.swift` shows every address in full,
    names above addresses, never truncated, specifically as an anti-phishing affordance.
    Android has no equivalent.
13. **`clearCursors` as the re-page mechanism.** `SyncStore.clearCursors(accountKey:)` deletes
    the account's feed entries and cursors in one transaction, and `@Query` re-renders. Android
    needs `RepageSignal` plus `FeedMediator.needsRepage` plus a `LaunchedEffect` in the screen
    to achieve the same thing.
14. **Accessibility-size row layout.** `ThreadRowView` stacks its columns at
    `dynamicTypeSize.isAccessibilitySize` rather than truncating the sender to fit a timestamp;
    `ThreadReaderView.compactActions` drops the reply bar's words at those sizes.
15. **Bulk verb resolved against the selection.** `ThreadListView.anyUnread` / `anyUnstarred` —
    ticking a read and an unread conversation and pressing Read leaves both read rather than
    flipping each.

---

## Server features neither client uses

All verified against `origin/main` (`git show origin/main:src/Jmap/…`), not the stale checkout:

- **`filename` and `listId` filter conditions** (`EmailFilterCompiler.php`) — neither client
  offers "has an attachment called…" or list-based filtering/search operators.
- **`hasLabel` / `notLabel`** — user-scoped label ids in a filter, so a single query can select
  a label across accounts without resolving per-account bindings. Both clients resolve bindings
  by hand instead (`FeedRepository.labelled`, `MailSyncService.pager(for:account:)`).
- **`inMailboxOtherThan`** — unused by both. Would express "everything except Trash and Spam"
  in one condition.
- **`minSize` / `maxSize`** — unused by both; iOS's `SearchQueryCompiler` does not emit them.
- **`Mailbox/changes` and `Thread/changes`** (`MailboxChangesMethod.php`,
  `ThreadChangesMethod.php`) — both clients re-fetch the whole mailbox list with
  `Mailbox/get` on every structure sync instead of asking what changed.
- **`Core/echo`** — a cheap liveness probe neither client uses for its reachability check.
- **`PushSubscription/get`** (`PushSubscriptionGetMethod.php`) — iOS registers via
  `PushRegistrar` but never reads back to verify. Android does verify
  (`LiveUpdates.pushIsSilent`), which is why it can decide whether to open an SSE stream at
  all; iOS opens the stream unconditionally while a list is visible.
- **`Email.category`** — the raw per-message classification, emitted read-only by
  `EmailMapper.php`. Neither client shows it. It is what explains a Primary-looking reply
  sitting in a Promotions conversation, so a reader could usefully surface it in the message
  details panel. It is deliberately *not* filterable — use `threadCategory` for lists.

*(Withdrawn: an earlier revision claimed `docs/CLIENT_DEVELOPMENT.md` was stale on snooze.
That was the stale checkout. On `origin/main` the doc is correct and current: it documents
`Thread/set` as accepting `snoozedUntil` and `isNew`, and notes that an older revision of
itself wrongly said snooze was not exposed.)*
