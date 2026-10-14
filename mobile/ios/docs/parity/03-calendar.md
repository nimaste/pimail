# Calendar — a feature specification for the iOS client

Reference client: `pl_mail_android` (Kotlin/Compose), `feature/calendar/` plus `core/jmap/`,
`core/data/` and `core/database/`. Target: `pl_mail_ios` (SwiftUI). Server: `pl_mail` (PHP/JMAP),
read at `origin/main` — see the version note immediately below.

This is not a gap list. **iOS has no calendar at all**: there is no `Calendar` or `CalendarEvent`
type in `JMAPKit`, no calendar table in `SchemaV1`, no view, and no `EventKit` import anywhere in
the repository. So this document is the whole feature — the server contract, the reference
implementation's behaviour, and a design for the iOS one — written for somebody who will implement
it without reading the Android tree.

Conventions are **not** restated here. Read
[`00-HOUSE-STYLE.md`](00-HOUSE-STYLE.md) first; every skeleton below assumes it.

---

## Server version note

**The `pl_mail/` working tree in this workspace is checked out at a stale commit** (`71d5474`,
2026-07-31). At that commit `docs/CLIENT_DEVELOPMENT.md` line 508 says, in as many words, "**No
JMAP Contacts or Calendars.** Mail only" — and it is wrong about the server you are building
against. The current server is `origin/main` (`132c1bf`, "release: v0.1.9"), which carries
`src/Jmap/Method/Calendar/` (four methods), `src/Jmap/Calendar/`, `src/Jmap/Mapper/CalendarMapper.php`,
`src/Jmap/Query/CalendarEventQueryRunner.php`, roughly two hundred calendar source files under
`src/Service/Calendar/`, and the PHP tests that pin all of it.

**Read server files with `git show origin/main:<path>`. Do not check out, fetch, or modify
`pl_mail/` in any way.**

```
git show origin/main:docs/CLIENT_DEVELOPMENT.md
git show origin/main:docs/internals/jmap.md
git show origin/main:src/Jmap/Protocol/Capability.php
git show origin/main:src/Jmap/Method/Calendar/CalendarEventQueryMethod.php
git show origin/main:src/Jmap/Calendar/JmapEventWriter.php
git show origin/main:src/Jmap/Mapper/CalendarEventMapper.php
```

Several agents have now concluded "the server has no calendar" from the working tree. It is the
single most expensive mistake available in this workspace, because it inverts the entire design:
you would go looking for a CalDAV client or an `.ics` parser for something that is four JMAP
methods. Check the commit you are reading before you write "the server does not support X".

`origin/main`'s own `CLIENT_DEVELOPMENT.md` §0 now uses this feature as its worked example of the
project's "ask, do not work around" rule — the calendar API exists *because* the Android client
asked for it, and `expandRecurrences` exists because it asked a second time.

---

## Corrections found while implementing §1

Phase 0 built this wire surface against `origin/main` and found three things in
the sections below to be wrong or unproven. They are corrected here rather than
in place, so the diff against what was originally written stays legible.

**§1.7's occurrence-id refusal is `invalidArguments`, not `invalidProperties`.**
`CalendarEventSetMethod.php:340` emits `invalidArguments`, and
`event-query-get-expanded.json` confirms it. §1.9 maps `invalidProperties` to
"the whole `/set` vocabulary and validation surface", which reads as though this
refusal is one of them. It is not — a client branching on `invalidProperties` to
find the offending field would miss this case entirely.

**Android's `CalendarEventFilter` docstring contradicts §1.5, and Android is
wrong.** It documents `after`/`before` as a JSCalendar LocalDateTime with no
offset and no trailing `Z`. `CalendarEventQueryRunner::utcDate()` parses with
`new DateTimeImmutable($value)` and converts to UTC, so a naive spelling is read
in the *server's* default zone. That is exactly the naive-local-window bug that
swept freshly created events out of Android's cache. iOS makes it unrepresentable
by typing both ends as `UTCDate`.

**§1.3's claim that `recurrenceIdTimeZone` is UTC for a floating series is
unproven.** Every captured occurrence is zoned (`Europe/Berlin`), so no fixture
exercises the floating path. Not known to be wrong — untested, and worth
capturing a fixture for next time someone has a live server to hand.

---

## Summary

plMail's calendar is a **real, first-class server feature** with a large surface: CalDAV, Google
Calendar and Microsoft Graph mirroring, `.ics` import/export/subscription, event extraction from
mail (flight confirmations, restaurant bookings, `.ics` attachments), iTIP invitations, alerts,
share links and booking pages.

**Almost none of that is reachable over JMAP.** What JMAP exposes is a deliberately narrow slice:

| | Over JMAP |
|---|---|
| Read calendars | `Calendar/get` |
| Find events in a date window | `CalendarEvent/query`, collapsed or expanded per occurrence |
| Read events | `CalendarEvent/get` |
| Create / edit / delete events | `CalendarEvent/set`, with a **thirteen-property** vocabulary |
| Participants, RSVP, alerts, privacy, links, attachments | **Not writable.** Readable only. |
| Invitations from mail, proposals, `.ics`, sharing, booking | **Not exposed at all.** HTTP routes only. |
| Delta sync, change tokens, push | **Do not exist.** `state` is the literal string `"fixed"`. |

Three consequences shape the whole iOS design and each is stated plainly in §1:

1. **There is no `/changes` and no push.** `Calendar/get`, `CalendarEvent/get`, `/query` and `/set`
   all return `"fixed"`, and `canCalculateChanges` is `false`. Freshness comes from re-running the
   visible window's query, and from nothing else. **No timer, no background poll, no SSE
   subscription** — refresh while somebody is looking at the screen and not otherwise.
2. **An event id is the series, not a dated occurrence** — except when a query was asked to expand
   recurrences, which mints a synthetic occurrence id the client must treat as opaque and cannot
   write through.
3. **The writable vocabulary is small and refusals are loud.** An unknown property is
   `invalidProperties` naming it, never a silent drop. Build the editor to the vocabulary; do not
   build an invitation card.

The Android client is a faithful, complete implementation of exactly that slice — five view modes,
a run-based lane algorithm for overlapping events, a UID-based duplicate collapse, an editor with
five recurrence choices on create only, and a cache reconciled window-by-window in place of a delta
feed. It is worth copying at the level of **rules**, and worth ignoring at the level of **layout**:
several of its compromises exist because a 411 dp phone cell fits four characters, and an iPad does
not have that problem.

---

# Part 1 — The server API surface

This is the part an iOS implementer cannot get anywhere else. Every claim below is cited to a file
on `origin/main`.

## 1.1 The capability, and how to find the calendar account

`src/Jmap/Protocol/Capability.php`:

```php
public const string CALENDARS = 'urn:plmail:params:jmap:calendars';

public const array SUPPORTED = [
    self::CORE, self::MAIL, self::SUBMISSION,
    self::CALENDARS, self::APPEARANCE, self::SYNC, self::CONTACTS,
];
```

**It is declarable in `using`** — unlike `urn:plmail:params:jmap:push`, which is Session-only.
This is the same shape `Capability.apns` already has in `JMAPKit/Protocol/Capability.swift`, so the
change is one case and one entry in `supportedInUsing`.

The URN is deliberately **not** `urn:ietf:params:jmap:calendars`. The capability's docblock argues
it at length: JMAP for Calendars is an unratified draft whose object shape has been renamed and
re-scoped between revisions, so advertising the IETF URN would promise a contract no client could
rely on. **Do not hard-code the draft's URN**, and do not treat the vendor one as interchangeable
with it.

**Calendars are served from exactly one account.** A plMail `Calendar` is user-scoped, like a
`Label` — but unlike a label it has no per-account binding, so there is nothing to translate and no
honest way to publish it three times. `src/Jmap/Account/CalendarAccountResolver.php` names one
account; every other `accountId` is refused with `accountNotSupportedByMethod` (RFC 8620's error
for precisely this), and an id the user does not own is `accountNotFound` first — so a stranger is
never told an id exists.

`SessionBuilder` publishes:

- **Top-level** `capabilities["urn:plmail:params:jmap:calendars"]` — an **empty object**. Its
  presence is the "this instance has calendars" signal.
- **Account-level** `accountCapabilities["urn:plmail:params:jmap:calendars"]` on **one account
  only**:

```json
{
  "maxEventsInGet": 100,
  "maxEventsInSet": 500,
  "mayCreateCalendar": false,
  "materialisedHorizon": { "past": "-1 year", "future": "+2 years" }
}
```

**The client rule: find the single account whose `accountCapabilities` contain the calendars URN.**
That is the only rule that cannot go wrong. The internals doc says the resolver picks "the account
the Session already lists in `primaryAccounts`, which is the user's first", and `primaryAccounts`
may well carry the URN too — but scanning `accountCapabilities` is what the methods themselves
check against, so it is the reading that cannot disagree with them.

Three properties and each exists because a client would otherwise learn it the hard way:

- **`maxEventsInGet: 100`**, *lower* than core's `maxObjectsInGet: 500`.
  `CalendarEventGetMethod::MAX_OBJECTS` is 100 and exceeding it is `requestTooLarge`. The reason is
  in the method's docblock: `CalendarEventRepository` offers only an ownership-scoped single-id
  lookup, so a get is one query per id. **Chunk at 100, not 500.**
- **`mayCreateCalendar: false`**, matching an absent `Calendar/set`. Calendars are provisioned by
  `CalendarProvisioner` or by the subscribe flow; there is no JMAP route to create one.
- **`materialisedHorizon`** — **opaque PHP relative-date expressions**, currently `-1 year` and
  `+2 years` from `RecurrenceMaterialiser::HORIZON_PAST` / `HORIZON_FUTURE`. **Display them, never
  parse them.** They are strings for `DateTimeImmutable::modify()`, not a client-side grammar.

**A user with no mail account has no calendar account, and the Session advertises none.** That is a
real state — a user can delete their last mailbox and keep a calendar — and it must degrade to
"this install has no calendar" rather than to an error.

## 1.2 The `Calendar` object

From `src/Jmap/Mapper/CalendarMapper.php`. Every property is published on every calendar; a
`properties` filter narrows it, and `id` is always returned regardless.

| Property | Type | Notes |
|---|---|---|
| `id` | `String` | The `calendar` row id. **This is what `inCalendar` consumes** — one id space, no translation. |
| `name` | `String` | |
| `color` | `String?` | **`#rrggbb` hex.** Explicitly *not* the Tailwind token `Mailbox.color` carries; the two are different vocabularies in the database and translating one into the other would invent a colour the user never picked. |
| `sortOrder` | `Int` | Sidebar order. |
| `isVisible` | `Bool` | **Published rather than acted on.** It is the web sidebar's tick. A JMAP client that filtered events by it would hide from a phone what its user chose to hide in a browser. See §5.4 for what iOS should do with it. |
| `isDefault` | `Bool` | Where a new event goes when nobody chose. |
| `timeZone` | `String?` | IANA name. The zone an event with no `timeZone` of its own is local to. |
| `role` | `String` | plMail extension: what the calendar is *for*. Drives where extracted events land. A client cannot derive it and a user cannot change it. |
| `isSynced` | `Bool` | plMail extension: whether there is a remote behind this. **Distinct from writability** — a calendar can mirror a remote and still accept writes. It is what tells a client that an event created here will leave the machine. |
| `myRights` | object | See below. |

```json
"myRights": {
  "mayReadItems": true,
  "mayAddItems": true,
  "mayUpdateAll": true,
  "mayRemoveItems": true,
  "mayDelete": true
}
```

Writability is published as `myRights` rather than an `isReadOnly` flag, following RFC 8621's
Mailbox — "two spellings of *may I write here?* is how one of them ends up not being consulted".
The first four are all the same gate (`isReadOnly == false`), so a read-only mirror refuses all
three writes and the client can grey the control out instead of discovering it by `SetError`.
`mayDelete` is about the *calendar*, not its events, and is advisory today because `Calendar/set`
does not exist.

## 1.3 The `CalendarEvent` object

From `src/Jmap/Mapper/CalendarEventMapper.php` and `src/Service/Calendar/CalendarEventWriter.php`.

**The published object *is* the stored canonical JSCalendar object plus an envelope.** Nothing is
re-derived from projected columns — `CalendarEventWriter` is the one place columns become
JSCalendar, and a second derivation in the mapper would be a second answer to what an event is. An
event whose stored `jscalendar` is empty is published nearly empty, which is honest: no writer made
that row.

### The envelope (always overwritten by the mapper)

| Property | Type | Notes |
|---|---|---|
| `@type` | `"Event"` | JSCalendar's discriminator. |
| `id` | `String` | **The series' `calendar_event` row id** — see §1.5. |
| `uid` | `String` | Stable across servers where the id is not. `<hex>@plmail` for events this product created. Kept verbatim when a client supplies one on create. |
| `calendarId` | `String?` | |
| `sequence` | `Int` | |
| `created` / `updated` | `String?` | **UTC instants**, `Y-m-d\TH:i:s\Z` — *unlike* `start`. |
| `isRecurring` | `Bool` | **Derived, and not the same claim as `recurrenceRules != []`.** A rule the server could not convert is stored verbatim and expands to a single occurrence. Read this; do not infer it. The two disagree exactly on the imported events a user is most likely to notice. |
| `kind` | `String?` | plMail extension: what this was extracted *from*. **`null` means "a person made it"** — that null-vs-set test is the server's own `isExtracted()`. Vocabulary below. |
| `source` | `String` | plMail extension: where the event came from. Vocabulary below. |

### The `kind` and `source` vocabularies

Both are real enums server-side, so a client can switch on them — but treat an unrecognised value
as "unknown" rather than crashing, since the server may add cases.

`ExtractionKind` (`src/Domain/Enum/Calendar/ExtractionKind.php`), with the server's own icons:

| Value | Meaning | Server icon |
|---|---|---|
| `meeting` | an invitation | users |
| `delivery` | a parcel or an order | box |
| `flight` | ✈ | plane |
| `train` | | train |
| `lodging` | a hotel stay | bed |
| `dining` | a restaurant booking | utensils |
| `rental` | a hire car | car |
| `ticket` | an event, a bus | ticket |
| `order` | *defined but nothing currently emits it* | bag-shopping |
| `call` | *defined but nothing currently emits it* | phone |

These map cleanly onto SF Symbols (`person.2`, `shippingbox`, `airplane`, `tram`, `bed.double`,
`fork.knife`, `car`, `ticket`) and are worth drawing — an extracted flight that looks like a typed
meeting throws away the one thing extraction bought.

`EventSource` (`src/Domain/Enum/Calendar/EventSource.php`) — note the **camelCase** values:
`manual`, `acceptedProposal`, `ics`, `structuredData`, `senderParser`, `llm`, `remoteSync`,
`booking`. Only `booking` carries a badge in the web UI. `llm` is the one source the server marks
untrusted.

Other enums a client will meet inside the JSCalendar body:

| Enum | Values |
|---|---|
| `EventStatus` (`status`) | `confirmed`, `tentative`, `cancelled` |
| `EventPrivacy` (`privacy`) | `public`, `private`, `secret` |
| `ParticipationStatus` (`participants[].participationStatus`) | `needs-action`, `accepted`, `declined`, `tentative` — **no `delegated`** |
| `AlertAction` (`alerts[].action`) | `display`, `email` |
| `CalendarRole` (`Calendar.role`) | `default`, `account`, `custom`, `remote` |

### The canonical body (what `CalendarEventWriter::toJsCalendar()` builds)

| Property | Type | Notes |
|---|---|---|
| `title` | `String` | |
| `start` | `String` | **JSCalendar `LocalDateTime`, RFC 8984 §4.1.2: `2026-08-03T10:00:00`. No offset, no trailing `Z`.** It means "10:00 in `timeZone`", or 10:00 wherever the reader is when `timeZone` is absent. Parsing this with anything that assumes UTC silently shifts every event by the reader's own offset. |
| `duration` | `String` | ISO 8601, e.g. `PT1H`, `PT15M`, `P1D`. |
| `status` | `String` | `EventStatus` value; `confirmed` is the default the writer applies. |
| `privacy` | `String` | Always published. **Not writable** (§1.7). |
| `timeZone` | `String?` | IANA name. **Emitted only when non-null.** Absent is the ordinary case, not an edge: an all-day event carries no zone at all. |
| `showWithoutTime` | `Bool` | **Emitted only when `true`.** All-day. |
| `description` | `String?` | Emitted only when non-empty. |
| `locations` | map | Emitted only when a location exists, as `{"1": {"@type": "Location", "name": "…"}}`. plMail stores a place as a **label**, not coordinates. |
| `recurrenceRules` | array | **At most one.** |
| `recurrenceOverrides` | map | Keyed by the occurrence's **original** start as a `LocalDateTime`. Values are arbitrary JSON patches — decode as raw JSON, not into a fixed shape, or you will silently drop what your version has not heard of. |
| `participants` | map | **Carried across every write and published — but not writable.** Present on anything that arrived by invitation, import or mirror. See §1.7 and §5.6. |
| `alerts` | map | Same: carried and published when non-empty, not writable. Shape is `{"@type": "Alert", "trigger": {…}, "action": "…"}`, the trigger being either `{"@type": "OffsetTrigger", "offset": "-PT15M", "relativeTo": "end"?}` or `{"@type": "AbsoluteTrigger", "when": "…Z"}`. |

`CalendarEvent/get` returns **exactly the properties asked for**, so a `properties` filter comes
back without `uid` or even `@type`. Model every property but `id` as optional.

**This is a subset of what the server stores.** Events carry arbitrary JSCalendar; an import can
bring links, virtual locations and anything else the format defines. **A round trip through a typed
Swift model is lossy and must never be written back wholesale** — send only the properties the user
actually changed, from the writable vocabulary.

### The occurrence form

When `CalendarEvent/get` is handed a synthetic occurrence id, `toJmapInstance()` returns the series
with its stored override merged over it, plus:

| Property | Value |
|---|---|
| `id` | the synthetic instance id |
| `seriesId` | **plMail extension.** The series' plain id — the id `CalendarEvent/set` accepts. |
| `recurrenceId` | the instance's **original** start, as a `LocalDateTime` |
| `recurrenceIdTimeZone` | the zone that `LocalDateTime` is in — **UTC for a floating series**, which is not the event's own zone |
| `start`, `duration` | where the instance **actually** is, read off the materialised occurrence row |
| `recurrenceRules`, `recurrenceOverrides` | **`null`** — the draft says MUST |
| `status` | overwritten to `cancelled` when the occurrence row is cancelled, which is *not* the series' status |

`seriesId` is load-bearing, not decorative: it is the only sanctioned route from an occurrence back
to something writable, and the only sanctioned way to learn which series an occurrence belongs to.

## 1.4 `Calendar/get`

```json
["Calendar/get", { "accountId": "7", "ids": null, "properties": null }, "c0"]
```

`ids: null` returns **every calendar the user owns, in sidebar order** — shaped like `Mailbox/get`,
because a user has a handful of calendars and there is nothing for a `/query` to page. There is no
`Calendar/query` and no `Calendar/set`.

```json
{ "accountId": "7", "state": "fixed", "list": [ … ], "notFound": [] }
```

Another user's calendar is `notFound`, never an error: "there is no calendar 41 for you" and
"calendar 41 is somebody else's" have to be the same sentence.

## 1.5 `CalendarEvent/query` — the method the whole feature turns on

```json
["CalendarEvent/query", {
  "accountId": "7",
  "filter": { "after": "2026-08-01T00:00:00Z", "before": "2026-09-01T00:00:00Z", "inCalendar": "3" },
  "position": 0,
  "limit": 100,
  "expandRecurrences": true
}, "q"]
```

```json
{
  "accountId": "7",
  "queryState": "fixed",
  "canCalculateChanges": false,
  "position": 0,
  "ids": ["41", "42_20260304T090000Z", "42_20260311T090000Z"],
  "total": 3,
  "limit": 100
}
```

**The refusals are the specification.** From `CalendarEventQueryRunner` and
`CalendarEventQueryMethod`:

| You send | You get |
|---|---|
| no `filter`, or `{}` | `unsupportedFilter` — "occurrences are materialised only to a horizon, so an unbounded query would look complete while stopping at it" |
| `filter.operator` (AND/OR/NOT) | `unsupportedFilter` — an OR of two windows is two queries a client can make |
| any condition other than `inCalendar`, `after`, `before` | `unsupportedFilter`, naming it |
| `sort` | `unsupportedSort` — there is one useful order for a calendar and it is the one the index returns |
| `anchor` | `unsupportedFilter` — use `position` |
| `position` not a non-negative `Int` | `invalidArguments` |
| `limit` > 500, or null | silently clamped to 500 |
| `expandRecurrences` not a `Bool` | `invalidArguments` |
| `timeZone` **together with** `expandRecurrences` | `invalidArguments` — the server does not convert, and a client told nothing would draw a whole month in the wrong zone with no way to notice |
| an expanded window reaching past the horizon | **`cannotCalculateOccurrences`**, naming the computed bounds |

`after` and `before` are `UTCDate` strings, parsed with `new DateTimeImmutable($value)` and
converted to UTC. `after` is **inclusive**, `before` **exclusive** — a half-open window. An
`inCalendar` naming a calendar the user does not own yields an **empty result, not an error**;
reporting `notFound` would confirm the id exists.

### `expandRecurrences` — one query per screen instead of thirty-one

Collapsed, the answer is one id per *series* — de-duplicated, ordered by the series' **first**
occurrence inside the window. That answers "which events touch this month" and says nothing about
which days they land on, so drawing a month meant one query per day. Clients are forbidden from
expanding rules themselves (the phone and the browser would disagree at DST boundaries and on
overridden instances), so the server does it.

`expandRecurrences: true` switches the unit to the occurrence: **one entry per instance, in
instance-start order, with `position`/`limit`/`total` counting instances.** It is a projection of a
read that already happened — `findInRange()` returns occurrence rows and the collapsed answer
throws the extras away — which is why it is cheap.

An instance is named by `App\Jmap\Calendar\OccurrenceId`:

```
42_20260304T090000Z
```

The event id, an underscore, and the instance's **original** start as a UTC instant in ISO 8601
basic format. Three properties of that spelling matter to you:

- **It is opaque.** Hand it to `CalendarEvent/get`; read `start` and `recurrenceId` off the
  returned object. **Do not split it.** A client that reassembled its own would be expanding
  recurrence rules by hand through the back door.
- The separator is `_`, **not** `;`, because RFC 8620 §1.2 restricts an Id to `A-Za-z0-9`, `-` and
  `_` — a conforming client library is entitled to reject a semicolon before your code ever sees
  the response.
- The timestamp is the **recurrence id, never the moved start**. Once an instance has been dragged,
  those are different values, and `recurrenceOverrides` is keyed by the first.

**A one-off event keeps its plain series id even in an expanded answer.** Its single occurrence *is*
the event, and the plain id is the one `/set` accepts back. So an account with nothing recurring in
the window answers an expanded query exactly as it answers a collapsed one, and with the argument
absent or `false` the response is byte-for-byte what it was before the feature existed.

Three behaviours worth knowing:

- A **moved** instance is drawn and ordered at its new time and still named by its old.
- An `{"excluded": true}` instance has **no occurrence row**: absent from the query, `notFound`
  from the getter. An id from a query run before the cancellation stops resolving afterwards, which
  is the correct answer to "is this instance still there?".
- A `status: cancelled` instance **keeps its row**, leaves the query, and still resolves — because
  the answer to "wasn't there something today?" is more useful than a gap.

## 1.6 `CalendarEvent/get`

```json
["CalendarEvent/get", {
  "accountId": "7",
  "#ids": { "resultOf": "q", "name": "CalendarEvent/query", "path": "/ids/*" },
  "properties": null
}, "g"]
```

- **`ids` is required.** `null` is `requestTooLarge`, not "return everything".
- **At most 100 ids** (`maxEventsInGet`), or `requestTooLarge`.
- **It resolves both kinds of id** — plain series ids and synthetic occurrence ids. This is what
  makes expansion usable at all: a client pairs `/query` with a `/get` on `#ids` in one request, and
  ids the getter refused would leave the feature a list of strings nothing accepts.
- The usual `#creationId` back-reference works.
- Returns `state: "fixed"`, `list` **in repository order, not requested order**, and `notFound`.

## 1.7 `CalendarEvent/set` — the writable vocabulary

`src/Jmap/Calendar/JmapEventWriter.php`. **Thirteen properties, and everything else is refused by
name:**

```php
private const array WRITABLE = [
    '@type', 'calendarId', 'uid', 'title', 'description',
    'start', 'duration', 'timeZone', 'showWithoutTime',
    'locations', 'status', 'recurrenceRules', 'recurrenceOverrides',
];
```

**What is deliberately absent, and why — quote this at anyone who proposes an invitation card:**

| Property | Why not |
|---|---|
| `participants` | "an RSVP is answered through the invite flow, which sends an iTIP reply; accepting an attendee list here would record answers nobody was told about" |
| `privacy` | there is no writer parameter for it, and writing the column directly is what this class must not do |
| `alerts`, `links` | nowhere to project them from — the writer rebuilds the canonical object from the columns on every write, so they would survive one save and vanish on the next |

They are **published and carried across writes**, so an event that arrived with participants keeps
them when you correct its title. They are simply not yours to set. **There is no attachment
support of any kind on a JMAP CalendarEvent.**

### Request shape

```json
["CalendarEvent/set", {
  "accountId": "7",
  "create": { "new1": { "calendarId": "3", "title": "Standup",
                        "start": "2026-08-03T09:00:00", "duration": "PT15M",
                        "recurrenceRules": [{ "@type": "RecurrenceRule", "frequency": "weekly" }] } },
  "update": { "41": { "title": "Standup (moved)" } },
  "destroy": ["44"]
}, "s"]
```

```json
{
  "accountId": "7",
  "oldState": "fixed", "newState": "fixed",
  "created": { "new1": { "id": "97", "uid": "…@plmail", "calendarId": "3",
                         "isRecurring": true, "sequence": 0 } },
  "notCreated": {}, "updated": { "41": null }, "notUpdated": {},
  "destroyed": ["44"], "notDestroyed": {}
}
```

Note `created` etc. are **`{}` when empty, never `[]`**, and `updated[id]` is `null` meaning "no
properties changed beyond what you asked for".

### Every refusal, and what it means

| Condition | Error |
|---|---|
| `ifInState` present and non-null | `invalidArguments` — "the calendar state is fixed, so it could only ever answer *nothing has changed*". **A guard that cannot fail is worse than no guard.** |
| a patch key containing `/` (JSON-pointer path) | `invalidPatch` — send the whole property |
| any property outside `WRITABLE` | `invalidProperties`, listing the offenders |
| `uid` in an **update** | `invalidProperties` — the uid is the event's identity |
| `start` not exactly `Y-m-d\TH:i:s` | `invalidProperties`. **`2026-06-02T09:00:00Z` is refused** — "it says UTC, the zone beside it says Europe/Berlin, and guessing which the client meant moves a meeting by hours in silence". A non-existent date like `2026-02-30T09:00:00` is refused too, by reformatting and comparing back. |
| `duration` not an ISO 8601 duration | `invalidProperties` |
| `timeZone` not an IANA name | `invalidProperties` |
| `title` empty or absent on create | `invalidProperties` — `string()` requires a non-empty string |
| `locations` with more than one entry | `invalidProperties` — "only one location is stored; send the one that matters" |
| a location key other than `@type` or `name` | `invalidProperties` — "would not survive the next save" |
| `recurrenceRules` with more than one rule | `invalidProperties` |
| `status` not an `EventStatus` value | `invalidProperties`, listing the legal values |
| `calendarId` missing or non-numeric | `invalidProperties` |
| `calendarId` naming somebody else's calendar | `notFound` — never `forbidden`, which would confirm the id exists |
| the target calendar `isReadOnly` | **`forbidden`** — "it mirrors somewhere that does not accept writes" |
| an **occurrence id** in `update` or `destroy` | refused **by name**, pointing at `seriesId`. Not `notFound`: this server minted the id, and a client told "no such event" would go looking for a bug in its own id handling. |

### Semantics you must build the editor around

- **Defaults.** Absent `duration` → `PT1H`, or `P1D` when `showWithoutTime` is true. Absent
  `status` → `confirmed`.
- **`timeZone` is three-state, and the three states are different events.**
  - **Absent** → "you decide", and the calendar's own zone is used.
  - **Explicit `null`** → JSCalendar **floating** time (RFC 8984 §4.1.2). This is what an all-day
    event is.
  - **A name** → that zone.
  Reading `?? null` collapses the first two and quietly zones every floating event you send. Model
  it as a three-case enum, not an optional string.
- **An update is a patch layered over the stored event**, re-read in wire shape by `stored()`.
  Properties you do not name are re-supplied from storage — so an absent `description` is "leave it
  alone", not "delete it". But `recurrenceOverrides`, when named, is **replaced whole**: the patch
  is the entire truth about which instances differ.
- **A write is marked for push.** `markLocallyChanged()` / `markLocallyCreated()` run, and a
  `SyncCalendarMessage` is dispatched per touched calendar immediately, because "fifteen minutes is
  the right cadence for noticing somebody else's change and the wrong one for watching your own
  arrive". An update also calls `markUserEdited()`, which stops the extraction reconciler
  overwriting the event from later mail about the same booking.
- **A destroy on a synced calendar does not delete the row.** It marks it and drops its
  occurrences — so the deletion looks immediate — and the row survives until the remote has been
  told.

## 1.8 State, changes and push — there are none

`src/Jmap/Calendar/CalendarState.php`:

```php
public const string FIXED = 'fixed';
```

Every calendar method returns it, and the class docblock is the argument in full. Mail's token is
trustworthy **because its log is complete**: every path that changes a JMAP-visible mail property
goes through `MailChangeRecorder`. Calendars have four writers — the sync engine pulling a remote,
extraction reading a message, the web editor, and `CalendarEvent/set` — and only the last is inside
`src/Jmap/`. **"A log that recorded a quarter of the writes would be worse than none": the token
would sit still while a pull replaced the whole day, and a client comparing states would conclude
nothing had changed and never refetch. A partial log is not a weaker version of a complete one, it
is a lie with a number on it.**

Therefore:

- There is **no `Calendar/changes`** and **no `CalendarEvent/changes`**.
- There is **no `CalendarEvent/queryChanges`**.
- `canCalculateChanges` is `false`.
- The `StateChange` push payload tracks `Mailbox`, `Email`, `Thread`, `EmailSubmission` — **not
  calendars**. Nothing will ever wake the app because an event changed.
- `ifInState` is refused, so there is no optimistic-concurrency story to build on.

**One exception, and it is not a change feed.** `PushAlertChannel` sends a
`{"@type": "CalendarAlert", …}` payload over the *same* push stack JMAP registers
(`PushSubscription/set` → Web Push or FCM, RFC 8291 encrypted). **Unlike a `StateChange` it carries
content** — title, body and a deep link to the occurrence's day — "because a notification saying
*something is happening* is not a reminder". So a device that registers for push **will receive
reminder notifications**. It is a *reminder delivery*, not a sync signal: it fires only for alerts
the user set, it says nothing about events that changed, and there is no JMAP method to list,
create or acknowledge one. Do not build a sync trigger on it.

The value is deliberately **not a number**: should calendars later join the change log, tokens
become sequences, and a client still holding `"fixed"` fails the `ctype_digit` check in
`changesSince()` and is told to resync. That is free, correct degradation — so **store the token
you were given and send it back when a `/changes` appears**, rather than special-casing the string.

**The client rule this produces, and it is the whole sync design: re-run the visible window's query
when somebody is looking, and at no other time.** No timer, no background task, no SSE
subscription. This is not a compromise; it is what §4 of `CLIENT_DEVELOPMENT.md` already demands
("never poll aggressively — this is someone's Raspberry Pi") and what `Email/query` already asks
for.

## 1.9 Error vocabulary, collected

| Error | Where it comes from |
|---|---|
| `accountNotFound` | an unknown or foreign `accountId` |
| `accountNotSupportedByMethod` | a real account of yours that is not *the* calendar account |
| `unsupportedFilter` | missing window, `FilterOperator`, unknown condition, `anchor` |
| `unsupportedSort` | any `sort` |
| `cannotCalculateOccurrences` | expanded query outside the materialised horizon |
| `invalidArguments` | bad `position`/`limit`/`expandRecurrences`, `timeZone` with expansion, `ifInState` |
| `requestTooLarge` | `ids: null` or > 100 on `CalendarEvent/get` |
| `invalidProperties` | the whole `/set` vocabulary and validation surface |
| `invalidPatch` | a JSON-pointer patch path |
| `notFound` | a foreign or missing event or calendar |
| `forbidden` | a read-only calendar |
| `serverFail` | an occurrence row with no times (a bug, not a state) |

`MethodErrorType` in `JMAPKit` already has an `.other(String)` escape hatch, so
`cannotCalculateOccurrences` will arrive as data rather than a crash. Add the ones the UI branches
on — `forbidden`, `cannotCalculateOccurrences` — as real cases.

---

# Part 2 — The Android feature inventory

28 files, ~5,800 lines of Kotlin under
`pl_mail_android/feature/calendar/src/main/kotlin/de/plmail/feature/calendar/`, plus
`core/data/CalendarRepository.kt` (1,520 lines), `core/jmap/calendar/`, `core/jmap/methods/`,
`core/datastore/CalendarPrefsStore.kt` and `feature/settings/CalendarLauncherViewModel.kt`.

## 2.1 View modes — `CalendarViewMode.kt`

Five modes. Four share wire names with the web UI, because "the two surfaces are one product and a
person who reads their week in a browser should find a week here under the same word". **The wire
names are persisted**, so they cannot be renamed without stranding somebody's preferences.

| Mode | Wire | Window from anchor | Step |
|---|---|---|---|
| `AGENDA` (default) | `agenda` | `anchor … anchor + 30d` | **none** — a rolling list, not a page |
| `DAY` | `day` | `anchor … anchor + 1d` | ±1 day |
| `WEEK` | `week` | `weekStart(anchor) … +7d` | ±1 week |
| `MONTH` | `month` | `monthGridStart(anchor) … +42d` | **±1 *month*** |
| `MONTH_AGENDA` | `month-agenda` | same as `MONTH` | ±1 month |

- **`MONTH_AGENDA` is the phone's own invention**, and the file says exactly why: "a month grid on
  a 411dp phone can carry two or three titled chips per cell before it starts counting the rest,
  which is enough to recognise a day and not enough to read one; the browser never had that problem
  because its cells are three times the size". A grid you scan above, a list you read below.
  **This is the compromise §5.2 tells you not to port to iPad.**
- The month window is **always six whole weeks (42 days)**, never five-or-six, so paging through
  the year does not change the grid's height under the finger. Leading and trailing part-weeks are
  real days with real events.
- The month **steps by a month, not by 42 days** — stepping a six-week grid by its own length skips
  a fortnight every time. `plusMonths` also lands correctly off the 31st.
- `fromWire` degrades anything unknown to the default, so neither surface can strand the other.
- **A window is one request.** Every mode answers with a `CalendarWindow`, because the discipline
  `expandRecurrences` bought is that a *visible span* costs one round trip whatever recurs in it.

**Headings** (`heading()`): agenda and day print the anchor as a medium date; both month views
print month-and-year; a week prints a **range** whose near end drops what the far end repeats — the
year when both share it, the month too when the week does not cross one. That is the web toolbar's
own rule, carried across so the two surfaces name the same week the same way.

**Date formats** (`CalendarFormats`, `CalendarFormatsAndroid.kt`) come from the platform's locale
data via `getBestDateTimePattern` with the skeletons `yMMMd`, `yMMMM`, `d`, `MMMd`, `EEE`, `EEEE`,
`j` — never hand-written patterns, which "read correctly in English and in German and are neither
the order nor the wording several other locales use". The hour axis uses a **bare hour** (`j`) and
not a short time, because "10:00 AM" needs ~70 dp and the gutter is 56.

## 2.2 The duplicate collapse — `EventCluster.kt`

**One meeting legitimately reaches plMail twice.** An invitation arrives by mail and is extracted
onto the account's calendar with the organiser's UID; a provider auto-adds the same meeting and the
mirror pulls it onto a connected calendar, same UID, its own remote id. Both rows are correct and
the server keeps both deliberately — each is a remote object with its own etag and sync state.
`docs/internals/calendar-model.md` lists **JMAP as the one reader deliberately left uncollapsed**,
because a protocol that merged them would hand a client ids it cannot then `get`.

So the collapse is the client's, and it is a rule-for-rule port of the web's
`App\Service\Calendar\EventClusterer`:

**Grouping key: `startKey | uid`.**
- Matching on title and time would collapse a weekly 1:1 held with two different people at the same
  hour into one row — "a meeting quietly disappearing from a calendar, the worst shape a calendar
  bug takes".
- Start is in the key because two occurrences of one series are the same *event* and not the same
  *meeting*.
- A row with **no uid** gets a key nothing can collide with (`"#\(index)"`), never the shared empty
  one.

**A group merges only while its members agree** on exactly five things a user would notice:
`startKey`, `endKey`, `title`, `isAllDay`, and `status == "cancelled"` — plus **one row per
calendar** (two rows on one calendar are two meetings by construction, since UID is unique within a
calendar). The moment they disagree the group **splits entirely into clusters of one**, not into a
majority sub-group: "a majority is a winner picked with extra steps", and a merged row that quietly
picked a winner would hide a real disagreement behind a tidier UI.

**Recurrence is deliberately not one of the five**: two copies where one repeats and the other does
not agree about the occurrence they share and nothing else, and the repeating copy draws its own
rows on later days with no partner — which is exactly the visible signal that they differ.

**`startKey` is the instant where a zone is published and the bare wall clock (`"floating/\(local)"`)
where none is.** Both are correct and deliberately not interchangeable: an all-day or floating event
has no instant at all, so resolving it against the device would make the same birthday compare
unequal to itself the day somebody travels. A zoned occurrence and a floating one therefore never
merge, which is right — they are two different claims about when the meeting is.

**Member order** is by numeric id, then string id, then event key. It has to be *decided* rather
than inherited: the web is stable because its SQL ends `ORDER BY startsAt, id`, and a local query
ordered only by start hands ties back in storage order — "a representative that moves between two
renders of the same data is a detail screen that opens on a different copy each time it is tapped".

A merged cluster exposes `colors` and `calendarNames` **as positional lists in member order**, so a
multi-slice dot and the calendar names in the description read in the same order. **Nulls are kept
rather than dropped** — a calendar not yet refreshed has no colour, and dropping it would give a
two-calendar meeting a one-colour dot, which says something untrue.

## 2.3 The day grid — `DayGridLayout.kt`

A port of `App\Service\Calendar\DayGridLayout`, rule for rule.

```kotlin
data class PlacedCluster(cluster, top: Float, height: Float,
                         lane: Int, lanes: Int,
                         continuesBefore: Bool, continuesAfter: Bool)
data class DayGrid(date, allDay: [EventCluster], timed: [PlacedCluster])
```

**Positions are fractions of the column, not points**, so the same numbers stay correct at whatever
height the column ends up with — phone, tablet, or a zoomed grid — and nothing recomputes when it
changes.

**Positions are wall-clock minutes since local midnight, never elapsed time.** The grid draws 24
labelled rows, so a block must land against the row whose label matches the clock the user reads.
Deriving the offset from a difference of instants would agree on every day except the two a year
that are not 24 hours long. The consequences are stated rather than hidden: on a spring-forward day
the 02:00 row is drawn although nothing can be in it, and on a fall-back day the two 02:00s draw
over each other as an overlap. Both are what every other calendar does.

**Clipping to the day** (`spanOf`):

```
dayEnd = date.plusDays(1).atStartOfDay()     // NOT plusMinutes(1440) — an hour apart on a DST day
before = starts < dayStart
from   = before ? 0 : starts.minuteOfDay()
to     = ends >= dayEnd ? 1440 : ends.minuteOfDay()      // >= on the value, > on the flag
to     = max(from, to)                                    // an end before its start is data to survive
after  = ends > dayEnd
```

The `>=`/`>` asymmetry is the bug the line exists for: an event finishing exactly at midnight is
not continuing into tomorrow, but its end reads as 00:00 and would give it a height running from
its start back up to the top of the column.

**Overlap is answered by lanes, in runs** (`assignLanes`):

1. Sort by `from` ascending, then by `to` **descending** — longest-first among equal starts, so the
   block that covers the others takes lane 0 and the short ones stack to its right. The reverse
   puts the long block in the rightmost lane with a column of stubs beside it that look like the
   main event.
2. Accumulate a **run**: spans are added while `span.from < runEnd`, where `runEnd` is the running
   maximum of `to`. The first span starting at or after `runEnd` closes the run.
3. Within a run, greedy first-fit: take the first lane whose previous occupant has ended
   (`laneEnds[i] <= span.from`), else open a new lane. Greedy is optimal for interval colouring on
   a start-sorted list, which is why the sort is not incidental.
4. **Every span in a run gets the run's total lane count**, so block edges line up down the whole
   run. Sizing each pair independently produces a two-wide block beside a three-wide one, which
   reads as a rendering fault rather than as information.

**Deliberately not done:** an event with free lanes to its right is **not** widened to fill them.
Google does that and it looks tidier, but it makes a block's width depend on events it does not
overlap — so adding an event at 3pm resizes one at 9am, and the width stops being readable as "this
many things are happening at once", which is the only thing the width is for. **Do not "improve"
this on iOS.**

All-day and multi-day clusters never enter the lane algorithm; they go to a band above the axis.

**Tap-to-create** (`slotAt`): a fraction down the column → minutes, clamped to `0..<1440`, then
snapped **down** to a 15-minute slot. Down rather than nearest, "because a tap just above the 10:00
line meaning *ten* is the same gesture as a tap just below it, and rounding up would put an event at
a time above where the finger was". Clamped rather than trusted, or a fling a pixel past the bottom
proposes 24:00.

## 2.4 Screens

Read the files for detail; what follows is the behavioural shape, and where I am inferring from
test and screenshot names rather than from the source I say so.

- **`CalendarScreen.kt` / `CalendarBoard.kt`** (217 + 658 lines) — the shell: heading, previous /
  today / next, the view menu, a create affordance, and the board that switches between agenda,
  time grid, month grid and month-agenda. Screenshot tests exist for `agenda`, `day`, `week`,
  `month`, `month-full`, `month-agenda`, `empty`, `offline`, `horizon` and `week-large-text`, each
  in light and dark — so an **offline state**, an **empty state**, a **horizon notice** and an
  **accessibility-text pass** are all first-class, drawn states rather than afterthoughts.
- **`CalendarViewModel.kt`** (370 lines) — anchor, mode, window derivation, refresh, and the
  `CalendarRefresh` outcome (§3).
- **`TimeGrid.kt`** (414) — the 24-row axis, the hour gutter, the all-day band, the now-line, and
  the placement of `PlacedCluster`s.
- **`MonthGrid.kt`** (610) — the six-week grid. `MonthIndicatorsTest` pins the dot rules; the cell
  degrades from titled chips to counted dots as space runs out.
- **`MonthAgenda.kt`** (244) — the grid-plus-list split described in §2.1.
- **`Agenda.kt`** (143) — the rolling 30-day list with day headers and a horizon footer.
- **`EventChip.kt`** (722) — the largest single file. Chip rendering, calendar colour, the merged
  multi-slice dot, and `BlockTextPlan` (its own test), which decides how much of a title and time
  fits the block it has been given. Accessibility labels are composed here.
- **`EventDetailScreen.kt`** (469) — one event: title, when, calendar, location, description,
  recurrence stated read-only, edit and delete. **No RSVP controls and no participant list are
  possible from JMAP**, since neither is writable (§1.7) — participants *are* readable, so a
  read-only attendee list is the most that could be shown.
- **`EventEditorScreen.kt`** (664) + **`EventForm.kt`** (191) + **`EventEditorViewModel.kt`** (172)
  — see §2.5.
- **`ViewMenu.kt`** (160) — the mode picker.

## 2.5 The editor and its rules — `EventForm.kt`

```kotlin
enum class Repeat(val frequency: String?) {
    NEVER(null), DAILY("daily"), WEEKLY("weekly"), MONTHLY("monthly"), YEARLY("yearly")
}
```

Five choices, matching the web dropdown exactly. **More elaborate rules — every second Tuesday,
weekdays only — are not written by this product on either surface**, and are carried faithfully
when they arrive from an invitation, an import or a connected calendar.

`EventFormState`: `title`, `startDate`, `startTime`, `endDate`, `endTime`, `isAllDay`,
`calendarKey`, `repeat`, `location`, `description`.

**Date and time are separate fields, not one `LocalDateTime`** — the two pickers are separate
controls and the all-day toggle uses only half of each, so a joined value would have to invent a
time and then remember to ignore it.

**Validation is two rules, not one:**

```kotlin
val endsBeforeStart: Boolean
    get() = if (isAllDay) endDate.isBefore(startDate) else !end.isAfter(start)
```

"After" means something different on each side of the toggle. A timed event must *end* after it
starts; an all-day event covers whole days, so start and end on the same day is one day long and
perfectly ordinary — comparing the two midnights would refuse the commonest all-day event there is.

**All-day duration is `daysBetween(start, end) + 1`**, both ends included. And on load, an all-day
event's `endDate` is drawn as `end - 1 day`, because the stored duration counts whole days from
midnight so the end lands on the midnight *after* the last day covered — drawing that date would
say a one-day event lasts two.

**Defaults.** A new event starts at the **next whole hour** and lasts one: "an editor opened at
14:07 that proposes 14:07 asks the user to correct a time nobody would ever choose". A new event
created by tapping a grid slot uses the slot **unrounded**, because `slotAt` already snapped it to
the quarter hour and rounding again would move a long-press on the 14:15 line to 15:00 — "the one
thing the gesture promises not to do".

**An empty title becomes the localised word *Untitled*, not a refusal.** JMAP refuses an empty
title outright and the web stores the word; matching it means an event created on a phone and one
created in a browser are the same event.

**`timeZone` is always sent as absent (the calendar's own).** The editor offers no zone control, so
sending the *device's* zone "would be recording a decision the user never made — and would make the
same event read differently on the two surfaces the first time somebody travels".

**`recurrenceRules` is sent on create only.** This is the single most important rule in the editor
and it is worth quoting: the cache stores *whether* a series recurs but not the rule it recurs by,
so an update built from the dropdown would flatten an elaborate imported rule to "every week"
because somebody corrected a typo — "or, worse, clear it entirely, because null on that property
means *stop recurring*". An existing recurring event shows a **read-only line** instead of the
dropdown.

**The editor is seeded from the series, never from the tapped occurrence.** An update sends whole
properties, so a form seeded from one occurrence of a weekly standup would send that Tuesday as the
series' start "and saving a corrected spelling would drag every other occurrence onto the week the
user happened to be looking at".

## 2.6 Write outcomes — `WriteOutcome.kt`

```kotlin
sealed interface WriteOutcome {
    data object Saved
    data object Deleted
    data class Refused(val reason: String, val isForbidden: Boolean)   // the server's own words
    data class Unreachable(val host: String?)
    data object NoCalendar        // the server stopped offering a calendar mid-edit
}
```

The distinction is load-bearing and the docblock says why: **"a refusal is an answer and is shown
in the server's own words, a transport failure is not and names the host. Neither is retried and
neither is queued"** — replaying a refusal produces a loop that terminates never, and this surface
has no `ifInState` on which to build a conflict story for a queue. Both have already been rolled
back off the cache by the time one arrives, **which is why the screens report rather than offer an
undo**.

`isForbidden` is read from the server's error *type* (`"forbidden"`), never guessed from
`myRights` — `myRights` greys the button out in advance; the error is what happened.

**Calendar writes are deliberately outside the mail outbox.** That is the correct call and iOS
should make it too (§5.7).

## 2.7 The launcher — `CalendarLauncherViewModel.kt`

Android ships a **second launcher icon** that opens a separate `CalendarActivity` directly, toggled
from settings by enabling/disabling a manifest component through `PackageManager`.

Two things generalise:

- **Nothing is stored.** `PackageManager` stays the authority throughout; a DataStore copy would be
  "a second answer rather than a faster one". The state is a plain value plus a `refresh()` the
  screen calls when it returns, because the system publishes no change signal.
- **The switch is only offered when there is a calendar**, from the same `isAvailable()` the
  navigation row uses. "An instance whose server publishes no calendar is a supported instance
  rather than a broken one, and offering it a second launcher icon for a calendar it does not have
  would be worse than the drawer row it already hides."

**iOS has no equivalent and should not invent one** — there is no supported way to add a second
home-screen icon for one app. §5.9 says what to do instead.

## 2.8 Preferences — `CalendarPrefsStore.kt`

Exactly one key: `calendar_view`, a string holding a `CalendarViewMode.wire`. Unknown values
degrade to the default rather than crashing. That is the whole persisted preference surface.

---

# Part 3 — The data and sync model

## 3.1 Availability — a two-source boolean

`CalendarRepository.isAvailable()` is `cachedCalendars.isEmpty == false || sessionPublishesCalendars`,
`distinctUntilChanged`, **emitting `false` first**.

Both sources are needed and either alone is wrong:

- The **session** is the authority — an instance that publishes no calendars capability has no
  calendar and must not be offered one — but asking it needs the network, so a cold launch on a
  train would hide a calendar the device is holding a month of.
- The **cache** answers that case and cannot answer the first: it is empty before the first
  refresh, so "a screen that could only appear after being opened could never be opened".

`false` comes first deliberately: "a probe that has to time out must not hold the answer, because
what is waiting on it is a navigation row that is either there or not".

**The bug worth inheriting the fix for**, dated in the source (2026-08-06): the probe was made once
per collection, before pairing had stored a credential, so it answered `false` with nothing to ask
and nothing ever asked again — the Calendar row appeared only after the process was killed. The fix
re-probes **on a change in the world, never on a timer**: the stored connection, and the account
rows. Both reduced to the parts the answer can depend on *before* de-duplication, "because a probe
per push timestamp is polling with extra steps".

## 3.2 The window

```kotlin
data class CalendarWindow(val from: LocalDate, val to: LocalDate)   // half-open
```

Half-open because the wire is: `after` is inclusive, `before` exclusive. "A window closed at both
ends would have to add and subtract a day at every boundary, which is the arithmetic that puts an
event on the wrong side of a month."

- **`MAX_DAYS = 366`** — a hard precondition. "Not a performance cap so much as an honesty one: an
  expanded query counts *occurrences*, so a daily standup over a decade is thousands of ids paged a
  hundred at a time against a machine that advertises four concurrent requests."
- **`GUARANTEED_DAYS = 365`** — the client's own conservative horizon line. The window is clamped
  to `today ± 365` before an expanded query is sent, **because `materialisedHorizon` is published
  as opaque PHP expressions nothing here may parse**. The server actually keeps `-1 year / +2
  years`, so a window in the second year is clamped and reported as *possibly incomplete* when it
  was in fact answerable: "saying *there may be more* about a full month is a smaller lie than a
  month that silently stops". If the clamp leaves nothing, the refresh reports that rather than
  querying.
- **The fetch bounds are a union, and this is subtle.** `fetchAfter` takes the **earlier** of
  `from`'s local midnight converted to UTC and `from`'s naive local midnight; `fetchBefore` takes
  the **later** of the two. An event the server holds as an instant is bounded by the first; one it
  holds as a wall clock — every all-day event, and anything imported with an explicit null zone —
  by the second. "A single query has to reach both, and the two disagree by the device's offset."
  The cost is at most a day's events at each edge, which placement drops; the alternative is a
  floating event at 23:00 on the window's last day never being asked for at all.

## 3.3 The refresh — one round trip for a month

`CalendarRepository.refresh(window)`, three steps:

1. **One request** carrying `Calendar/get` **and two windowed `CalendarEvent/query` calls**, each
   back-referenced into its own `CalendarEvent/get`:
   - the **collapsed** query answers the **series** a form is edited through;
   - the **expanded** query answers the **occurrences** a day view draws.
   Both are needed and they travel together — you cannot edit through an occurrence id, and you
   cannot place a series without expanding it.
2. **Further pages** of either while its reported `total` says there are more, chunked by
   **`maxEventsInGet` = 100** — not core's 500 — and counted in *occurrences* on the expanded side.
3. **One transaction**: replace the calendars, upsert the series, **replace the window's
   occurrences**, and sweep the series nothing places any more.

Outcome:

```kotlin
sealed interface CalendarRefresh {
    data class Refreshed(events: Int, occurrences: Int, requests: Int,
                         mayBeIncomplete: Bool, horizon: MaterialisedHorizon)
    data object NoCalendarAccount     // not paired, or this server publishes no calendar — a state, not an error
    data class Unreachable(host: String?)
    data class Rejected(reason: String)
}
```

`mayBeIncomplete` is the clamp reporting itself: "true does not mean anything is missing; it means
the client cannot promise nothing is, which is a different sentence and the only honest one
available".

`lastRefreshed` is held because **a write involving recurrence has to re-ask the server where the
occurrences landed** — reconstructing them locally from a rule is the one thing the client may not
do.

## 3.4 Offline

Everything drawn comes from the cache, so the calendar renders offline exactly as far back and
forward as it was last refreshed. The screens have a **drawn offline state** (there are screenshot
tests for it). Writes are **not queued**: a write that reaches nothing is rolled back off the cache
and reported as `Unreachable(host)`, naming the host because users self-host and the hostname is
actionable.

---

# Part 4 — What the server has that JMAP does not expose

**This is a server request, not an iOS gap.** Everything here exists, works, and is used by the web
UI — it simply has no JMAP surface, so no native client can reach it. Per
`CLIENT_DEVELOPMENT.md` §0, the right move is to **ask for the method, not to work around it** —
and the calendar API itself is the project's own worked example of that request being granted.

Do **not** build any of the following client-side.

| Feature | Where it lives on `origin/main` | Reachable over JMAP? |
|---|---|---|
| **Invitations from mail** (iTIP/iMIP: the card above a message, Accept/Decline/Tentative, sending the reply) | `src/Controller/Calendar/InviteController.php`, `Service/Calendar/InviteReader.php`, `InviteResponder.php`, `ItipReplyBuilder.php`, `InviteParticipationResolver.php` | **No.** HTTP controllers only. |
| **Event proposals** (dates detected in message text, offered as events) | `src/Controller/Calendar/ProposalController.php`, `Service/Calendar/Proposal/*` | **No.** |
| **Alerts / reminders** | `Service/Calendar/Alert/*`, `Command/Calendar/CalendarAlertsCommand.php`, email and push channels | **Readable** in `alerts`; **not writable** (§1.7); set only through the HTML editor. But **delivery already reaches a native client** as a `CalendarAlert` push (§1.8). |
| **`.ics` import / export / subscribe** | `src/Controller/Calendar/IcsController.php`, `Service/Calendar/Ics/*` | **No.** |
| **Sharing and booking pages** | `Controller/Sharing/SharedCalendarController.php`, `Service/Calendar/Sharing/*`, `Booking/*` | **No.** |
| **"Happening soon"** | `Controller/Calendar/HappeningSoonController.php`, `Service/Calendar/HappeningSoonReader.php`, `UpcomingEventIndicator.php` | **No** — though a client can compute its own from a windowed query. |
| **Extraction from mail** (flights, hotels, restaurant bookings, `.ics` attachments) | `Service/Calendar/Extraction/*` | **Indirectly.** You cannot trigger it, but its output is a normal event carrying `kind` and `source`, so you can *label* it. |
| **`Calendar/set`** | — | **No**, and deliberately (`mayCreateCalendar: false`). |
| **Calendar change tracking / push** | — | **No** (§1.8). |

### The exact routes, so nobody has to go looking

Every one of these answers **HTML or a Turbo Stream** (`Content-Type:
text/vnd.turbo-stream.html`), which is why they are unusable from a native client even before the
CSRF question — the outcome of an RSVP is only recoverable from a toast key inside a rendered
fragment.

| Action | Route | Body | Answers |
|---|---|---|---|
| RSVP | `POST /calendar/invite/{messageId}/respond` | `_token` (CSRF id `calendar_invite{id}`), `status` ∈ `accepted`/`tentative`/`declined` | Turbo Stream |
| Accept a prose-date proposal | `POST /calendar/proposal/{messageId}/accept` | `_token` (`calendar_proposal{id}`) | Turbo Stream |
| Dismiss a proposal | `POST /calendar/proposal/{messageId}/dismiss` | same | Turbo Stream |
| "Not an event" | `POST /calendar/event/{id}/dismiss` | | Turbo Stream |
| Set reminders | `POST /calendar/event/save` | the whole editor form | Turbo Stream |
| Happening soon | `GET /calendar/soon` | — | HTML |
| Export one event | `GET /calendar/ics/event/{id}` | — | `text/calendar` |
| Export a calendar | `GET /calendar/ics/calendar/{id}` | — | streamed `text/calendar` |
| Import `.ics` | `GET`/`POST /calendar/ics/import` | `calendarId`, `file` (≤ 4 MiB) | HTML / Turbo Stream |
| Subscribe to a feed | `GET`/`POST /calendar/ics/subscribe` | `url`, `name` | HTML / Turbo Stream |
| Share links, booking pages | `/settings/sharing/*`, public `/share/{token}` | | HTML |

Note the invite and proposal routes are keyed on the **Message** id, not the event id —
deliberately, because "one event can be described by several messages", and the id from the card is
itself proof the card was rendered for a message this user may read. Any JMAP replacement should
keep that shape.

**What an RSVP actually does**, since a request should describe the behaviour it wants preserved
(`InviteResponder::respond()` — four effects, in order):

1. writes `participationStatus` into the event's `jscalendar.participants`, matched **by address
   inside the entry**, never by map key, so an RSVP cannot create a duplicate participant;
2. sets the projected `myParticipation` column;
3. **re-materialises the occurrence rows** — this is literally how "Yes puts it on your calendar"
   and "No takes it off" work. **Accepting is what makes an invitation visible at all**; unanswered
   and declined invitations materialise nothing and are absent from every view, including
   `CalendarEvent/query`. Tentative counts as yes, "because a tentative meeting is one whose slot
   you still have to keep";
4. mails an iTIP `REPLY` through the account the invitation arrived on.

Steps 1–3 always happen; step 4 may fail, and when it does **nothing is rolled back** — the user is
told "your answer was saved here, but the reply could not be sent to the organiser". An RSVP
deliberately does *not* count as a user edit, because the organiser remains the authority on the
time. And `InviteParticipationResolver::merge()` refuses to downgrade an existing answer to
`needs-action`, because an organiser's re-`REQUEST` routinely carries a stale attendee list that
would otherwise empty an accepted meeting off the calendar.

**This is the third consequence for iOS, and it is easy to miss: an invitation the user has not
accepted is not merely un-RSVP-able from the phone, it is *invisible* on the phone.** It has no
occurrence rows, so no windowed query returns it. Until §4's first request lands, the honest thing
for the reader to say is that the invitation exists and must be answered in the browser.

**The three worth asking for, in priority order:**

1. **Invitation RSVP over JMAP.** This is the single biggest user-visible hole, and it is bigger
   than "no buttons": an unanswered invitation never materialises, so it does not appear in the
   calendar at all. plMail already detects the invitation, resolves the user's participation
   status, decides `canRespond` (refusing cancellations, `PUBLISH` feeds, and meetings you
   organised), and builds and sends the iTIP reply. A native client can display the mail and cannot
   answer it. A vendor method — say `CalendarEvent/respond` taking an event id and a
   `ParticipationStatus`, or a `MessageInvite` object with a `get` and a `set` — would be a thin
   wrapper over `InviteReader` / `InviteResponder`. Note that `JmapEventWriter` refuses
   `participants` **precisely because** the invite flow is the right seam: this request asks for
   that seam to be exposed, not to bypass it.
2. **Alerts over JMAP.** The asymmetry here is stark and worth naming in the request: plMail will
   already *deliver* a reminder to an iOS device, over the push subscription the client itself
   registered — but the client cannot **set** the reminder it will be woken by. The `alerts`
   property is already published, and `CalendarEventWriter::write()` already takes an `alerts`
   parameter that the web editor uses; the only block is that `JmapEventWriter` has nowhere to
   project them from on its path. Making that reachable looks small, and it closes the loop on a
   feature that is otherwise half-built for native clients.
3. **Calendar change tracking.** `CalendarState`'s docblock already sketches the fix
   (`CalendarChangeRecorder` beside `MailChangeRecorder`, called by all four writers) and confirms
   the degradation is free. Until then, §1.8's rule stands.

---

# Part 5 — The iOS design

Not a port. iPhone Calendar and iPadOS Calendar are the reference, and the constraints that shaped
Android's compromises mostly do not exist here.

## 5.1 iPhone

**Four modes, not five.** Drop `MONTH_AGENDA` as a separate mode and make it *what month means on a
compact width*: a month grid whose selected day expands into a list below it, which is what iOS
Calendar does and what users already know. Keep the persisted wire values compatible — write
`"month-agenda"` when compact month is what is showing, read either as month — so a user who set
their view in a browser finds it here.

- **Shell.** `NavigationStack` with a `.toolbar` carrying the date heading as a
  `ToolbarItem(placement: .principal)` menu (tap to jump), `Today`, and a `Menu` for the view
  picker. A `+` in `.topBarTrailing` opens the editor.
- **Agenda** — `List` with `Section` per day, pinned day headers, `.listStyle(.plain)`. This is the
  default and it is the right default on a phone.
- **Day / Week** — a `ScrollView` over a vertical hour axis. The 24 rows and the placed blocks are
  a `Canvas`-free composition: hour lines as a `ForEach` of `Divider`s in a `VStack`, blocks in an
  overlaid `GeometryReader` positioned from `PlacedCluster`'s fractions. Keep the fractions —
  they are exactly what makes the same layout correct at every height, and they survive Dynamic
  Type changing the hour row height.
- **Month** — a six-week `LazyVGrid` of seven columns, selected day expanding into a list.
- **Scroll to now.** Day and week open scrolled so the current hour is in view, with a now-line.
- **Tap-to-create** on the grid: port `slotAt` verbatim, including snapping **down**.
- **Long-press an event → context menu** (Edit, Delete, Copy title). Swipe-to-delete on agenda
  rows, with the same action reachable from the detail screen — never gesture-only.

## 5.2 iPad — genuinely first-class

**The one thing not to port.** Android degrades a month cell to coloured dots because a 411 dp cell
fits roughly four characters. A 13-inch iPad in landscape gives a month cell ~150 pt of width and
~110 pt of height at default Dynamic Type. That is room for **three or four full event chips with
titles and start times, plus a "+2 more" affordance** — so draw chips, and fall back to dots only
when the cell genuinely cannot carry one (accessibility text sizes, Slide Over, a narrow Stage
Manager window). Make the fallback a function of measured cell size, not of idiom.

```
┌──────────────┬────────────────────────────────────┬──────────────────┐
│ Calendars    │  ◀  August 2026  ▶      [D W M Y]  │  Inspector       │
│  ☑ Personal  ├────────────────────────────────────┤                  │
│  ☑ Work      │  Mon  Tue  Wed  Thu  Fri  Sat  Sun │  Standup         │
│  ☐ Birthdays │  ┌───┬───┬───┬───┬───┬───┬───┐     │  Mon 3 Aug       │
│              │  │ 27│ 28│ 29│ 30│ 31│ 1 │ 2 │     │  09:00 – 09:15   │
│  ─────────   │  │▪︎Standup   │▪︎1:1     │   │     │  Work · repeats  │
│  Today       │  │▪︎Review    │         │   │     │  weekly          │
│  Search      │  └───┴───┴───┴───┴───┴───┴───┘     │  [Edit] [Delete] │
└──────────────┴────────────────────────────────────┴──────────────────┘
```

- **`NavigationSplitView` with three columns**, matching `MailView.swift`'s existing shell so the
  two features feel like one app: **sidebar** = calendar list with visibility toggles, Today, and
  the search field; **content** = the grid or agenda; **detail** = the selected event as an
  inspector rather than a sheet. Sidebar takes
  `.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)` and each column closes with
  `.mailPane(isSeparated:)` exactly as mail's do.
- **The detail column is the payoff.** On iPhone tapping an event pushes; on iPad it fills a
  standing inspector, so scanning a week and reading an event are simultaneous rather than
  alternating. Selection is a real `Binding<EventRef?>` shared by every mode.
- **Week view gets the space it deserves.** Seven full columns with the lane algorithm running at
  its intended width, all-day band above, hour gutter using the *short time* format rather than the
  bare-hour compromise — the gutter constraint that forced `j` on Android ("10:00 AM needs ~70 dp
  and the gutter is 56") does not bind at iPad widths.
- **Add a Year view.** It is cheap — twelve month grids with density shading — it is what iPad
  Calendar has, and it is the one mode where a large canvas is the entire point. It needs no new
  server call beyond a wider windowed query, and the `GUARANTEED_DAYS` clamp already covers a year.
- **Keyboard and pointer are first-class**, per the house style's "hardware keyboards are
  first-class":

  | Key | Action |
  |---|---|
  | `⌘1`…`⌘4` | Day / Week / Month / Year |
  | `←` `→` | previous / next period |
  | `T` | today |
  | `⌘N` | new event |
  | `⌘F` | focus search |
  | `⌫` | delete selected event (with confirmation) |
  | `↑` `↓` | move selection within the day |
  | `Esc` | dismiss the editor |

  Every one also exists as a visible control, and the `⌘` variants go in a hidden `Button` in
  `.background` so both routes hit one action.
- **Pointer**: hover highlights the day cell and shows a `.help()` tooltip with the full title;
  the create affordance appears on hover over an empty grid slot.
- **Drag and drop**: dragging an event block to another day or time is the obvious iPad gesture and
  it maps cleanly onto a `/set` update of `start`. **Defer it past v1** and gate it hard — a drag
  on a *recurring series* would move every occurrence, which is exactly the failure §2.5 describes.
  When it lands, it must offer "this event / all events" and the former needs a
  `recurrenceOverrides` patch, so it is not a small feature.
- **Multi-window**: support a second scene showing the calendar alone, via the existing scene
  configuration. Cheap, and it is how people use a calendar beside their mail.

## 5.3 Dynamic Type, dark mode, VoiceOver

Per `00-HOUSE-STYLE.md`; the calendar-specific parts:

- **Dynamic Type.** Read `@Environment(\.dynamicTypeSize)` and branch on `isAccessibilitySize`. The
  grid modes are the hardest surface in the app for this. **At accessibility sizes, month and week
  should fall back to the agenda list rather than shrink text** — a week grid at `.accessibility5`
  is seven columns of hyphenated fragments, which is worse than the list it is replacing. Android
  has a `week-large-text` screenshot test; iOS should have the equivalent, and the honest answer at
  the top sizes is a different view. Hour-row height uses `@ScaledMetric(relativeTo: .caption2)`.
- **Dark mode.** Every colour through `PanelStyle` / `Color(light:dark:)`. The one new problem is
  **calendar colours, which arrive as `#rrggbb` chosen against a white web background**. Do not
  paint them raw on a dark surface. Use the calendar colour as a **saturated accent on a derived
  low-alpha fill**, and compute the label colour for contrast the way `ActionTint` already does
  ("walked down in lightness until white text clears 4.5:1"). A hairline in the full-strength colour
  plus a tinted fill reads correctly in both appearances.
- **VoiceOver.** A grid is the surface where "it technically works" is furthest from usable.
  - Every chip is `.accessibilityElement(children: .combine)` with an explicit label reading
    **"Standup, 9 to 9:15 in the morning, Work"** — title, time span, calendar. Never the raw
    layout.
  - `.accessibilityAddTraits(.isButton)`, and `[.isButton, .isSelected]` for the selected event.
  - **A merged cluster must say so**: "…, in 2 calendars, Work and Personal". The multi-slice dot
    is invisible to VoiceOver and it is the only signal that two rows were collapsed.
  - **A day cell** is one element labelled "Wednesday 5 August, 3 events", with the events as
    children — not 3 sibling elements the user must swipe past to reach the 6th.
  - **Custom actions, not gestures**: `.accessibilityAction(named: "Edit")`,
    `.accessibilityAction(named: "Delete")` on every chip, because the context menu and the swipe
    are both gestures.
  - **`.accessibilityRotor`** over the visible period's events is worth the twenty lines: it is the
    difference between "next event" and swiping through a grid.
  - Hour lines, the now-line and decorative dots are `.accessibilityHidden(true)`.
  - Announce a period change with `.accessibilityLabel` on the heading and an
    `AccessibilityNotification.PageScrolled` when stepping.

## 5.4 Controls to use, and what to say

- **`DatePicker`** for start and end. `.datePickerStyle(.graphical)` in the editor's expanded
  state; separate date and time components, mirroring Android's two-field decision for the same
  reason — an all-day toggle uses half of each.
- **`.searchable`** over the cached window, scoped to title, location and description. `Calendar`
  has no `text` filter on the wire (§1.5 refuses everything but `inCalendar`/`after`/`before`), so
  **search is local, over what is cached, and must say so** — an empty result reads "search covers
  the dates you have loaded", the same honesty `CLIENT_DEVELOPMENT.md` demands of the mail sync
  window. Do not invent a server search.
- **`.toolbar`** for heading, Today, view picker, create. `ToolbarItemGroup` on iPad so the mode
  picker is a segmented control rather than a menu.
- **Context menus** on chips and agenda rows.
- **`ContentUnavailableView`** for all three empty states, which are genuinely different and must
  read differently:
  - *no calendar on this server* — "This server does not have a calendar", with a link to the web
    UI. **A supported instance, not an error.**
  - *nothing in this period* — "Nothing on this week".
  - *offline* — "Can't reach `nas.local`", naming the host.
- **The horizon notice.** When `mayBeIncomplete` is true, a footer saying "There may be more beyond
  this range" — never a silent stop. Show the server's `materialisedHorizon` strings verbatim in
  diagnostics and nowhere else.
- **`isVisible`** is a *server-side* display preference. Honour it as the initial state of the
  sidebar toggles, keep the user's local override separate, and **never filter the query by it** —
  the server's docblock is explicit that a client filtering on it "would hide from a phone what its
  user had chosen to hide in a browser".
- **Copy.** Plain declaratives, British spelling, both `en.lproj` and `de.lproj`, German ~30%
  longer. Errors name the cause and the host.

## 5.5 EventKit — the recommendation

**Do not adopt EventKit in v1. Ship a self-contained calendar, and revisit write-only export
later — never a two-way bridge.**

The reasons, in the order they bind:

1. **The permission cost lands before the value does.** `EKEventStore` requires
   `NSCalendarsFullAccessUsageDescription` and a system prompt. A mail client asking for full
   calendar access at launch is the kind of request that gets denied and then poisons the feature
   for the life of the install. The app already carries a careful story about *not* asking for
   things it cannot justify (the widget "says so on its face rather than showing a zero it cannot
   justify"); a calendar prompt on day one is the opposite of that.
2. **Two-way sync would be a second sync engine with no conflict primitive.** `ifInState` is
   refused and the state is `"fixed"` (§1.8), so there is **no optimistic-concurrency mechanism at
   all** on the plMail side. Mirroring into EventKit means reconciling two stores that can both be
   edited, with change tracking on one side only. That is not a hard feature; it is an unsolvable
   one with this contract, and it would produce exactly the silent divergence `CalendarState`'s
   docblock spends forty lines warning about.
3. **plMail is already the aggregator.** Its whole calendar architecture is CalDAV, Google and
   Graph mirroring. Pushing plMail's events into iOS Calendar — which is very likely mirroring the
   same Google account — produces duplicates of exactly the kind `EventCluster` exists to collapse,
   except across two apps where no collapse is possible.
4. **The store rule forbids it anyway.** `SchemaV1`'s banner says everything is a cache,
   reconstructible from the server. An EventKit mirror is client-owned state that is *not*
   reconstructible, and adding it would break the invariant that licenses deleting and rebuilding
   the store on any migration failure.

**What to do instead, and it covers most of the real want:**

- **`EKEventEditViewController` "Add to Calendar" as an explicit, per-event action.** It presents
  the system editor with a prefilled `EKEvent` and — crucially — **needs no permission prompt of
  your own**; the user saves or cancels in Apple's own UI. One-way, user-initiated, no sync, no
  duplicates. This is the right shape and it should ship in v1 if it is cheap.
- **An `.ics` share sheet** for one event, generated locally from the JSCalendar object. Works with
  every calendar app, no entitlement.
- **Later, if asked for: a read-only `EKCalendar` export**, one-directional, plMail → iOS, behind an
  explicit settings toggle, with a plain warning that events edited in iOS Calendar will be
  overwritten. Only worth building once the server can tell the client what changed — otherwise
  every refresh rewrites the mirror wholesale.

## 5.6 Invitations in the reader

Mail is where a user meets an invitation, and it is worth being precise about what iOS *can* do
today.

- **Can do**: detect a `text/calendar` part on a message (attachments are already modelled in
  `StoredAttachment`), parse it locally for display only, and show a **read-only** card — who,
  when, where — with "Add to Calendar" (§5.5) and a link to the web UI to answer.
- **Cannot do**: RSVP. There is no JMAP route (§4), and `CalendarEvent/set` refuses `participants`
  by name specifically because the invite flow is the correct seam.
- **Must not do**: send an iTIP reply itself, or POST to `InviteController`'s HTML routes. Both are
  the "scrape or drive the Turbo routes" failure `CLIENT_DEVELOPMENT.md` §0 forbids outright.

**Say the consequence out loud in the UI.** An unaccepted invitation has no occurrence rows, so it
will not appear in the calendar however many times the user refreshes. A card reading "Answer this
in plMail to add it to your calendar", with a link, is the honest interface — silence would look
like a sync bug and would send people hunting for one.

An event fetched over JMAP **does** carry `participants`, so once an invitation *has* been accepted
its attendee list and everyone's `participationStatus` can be shown read-only on the detail screen.
`kind: "meeting"` plus a non-`manual` `source` is how you know an event came from mail at all.

## 5.7 Writes, offline, and undo

Copy Android's judgement exactly, because the reasoning is about the protocol and not the platform:

- **Apply optimistically to the store, then reconcile against the answer.**
- **Never queue a calendar write into the outbox.** A refusal replayed is a loop that never
  terminates, and there is no `ifInState` to build a conflict story on. The mail outbox exists for
  operations that are safe to replay; these are not.
- **On failure, roll back and report** — do not offer undo for something that never happened. A
  `Refused` shows the server's own words; an `Unreachable` names the host.
- **Grey out writes on a calendar whose `myRights` refuse them**, and still handle `forbidden`,
  because rights can change between the screen opening and the write.
- **After any write touching recurrence, re-run the last window's query.** Do not recompute
  occurrences locally — that is the one thing the server explicitly forbids.

## 5.8 Widgets

The existing widget "reads shared defaults, never the network and never the database", is
blocked on an App Group, and says so on its face. A calendar widget fits that pattern well and
should follow it exactly:

- **`.systemSmall`** — next event: title, time, calendar colour.
- **`.systemMedium`** — today's remaining events, up to four.
- **`.accessoryRectangular` / `.accessoryInline`** — next event on the Lock Screen, which is the
  best widget surface a calendar has.
- Timeline entries generated from **cached** events at real event boundaries (each start and end),
  not a fixed 15-minute cadence — a calendar widget knows exactly when its content changes, which
  most widgets do not.
- Written into `SharedMailState`'s neighbour (say `SharedCalendarState`) by the app, same as the
  unread count. **Blocked on the same App Group**, and it should say so on its face rather than
  showing an empty day it cannot justify.

## 5.9 Live Activities, App Intents, Spotlight

- **Live Activities: no.** A Live Activity is for something with a live, changing state over a
  bounded window — a delivery, a timer, a game. "The next meeting starts in 20 minutes" is a
  *notification and a Lock Screen widget*, both of which cost nothing and neither of which occupies
  the Dynamic Island for an hour. And no push exists that could update one: the only calendar push
  is a single fire-and-forget `CalendarAlert` (§1.8), not a stream of state. **Do not build one.**
- **Do not schedule local notifications from `alerts`.** The property is readable, so the client
  *could* build `UNCalendarNotificationTrigger`s from it — and it would **double every reminder**,
  because `app:calendar:alerts` already delivers each one over push or email, and the push arrives
  at this very device through the subscription `PushRegistrar` created. Handle the incoming
  `CalendarAlert` payload (it carries its own title, body and a deep link to the occurrence's day —
  route it to the right date) and schedule nothing yourself. If local scheduling is ever wanted, it
  needs a server answer about which channel owns delivery first; that is an "ask, do not work
  around" case, and it is open question 3 below.
- **App Intents**: follow `MailIntents.swift`'s rule that intents **open the app** rather than act
  silently. `ShowCalendarIntent(date:)` and `CreateEventIntent(title:date:)` — the latter opening a
  prefilled editor, never saving unattended.
- **Spotlight / `NSUserActivity`**: index cached events with `CSSearchableItem`, and donate a
  `viewEvent` activity so Handoff works between iPhone and iPad. Cheap, and it is where a calendar
  earns its place in the system.
- **In place of Android's second launcher icon** (§2.7): a **Calendar tab or sidebar row**, shown
  only when `isAvailable()` is true, plus the App Intents above and a `⌘`-shortcut on iPad. That
  is the platform-native answer to the same want.

---

# Part 6 — Proposed module layout

Matching `00-HOUSE-STYLE.md`: new files under `Packages/PLMail/Sources/PLMail{Core,UI}/Calendar/`,
nothing under `App/` except one intent and one widget.

```
Packages/PLMail/Sources/
  JMAPKit/
    Protocol/
      Capability.swift                 (edit: add .calendars, add to supportedInUsing)
      Identifier.swift                 (edit: CalendarNamespace, CalendarEventNamespace)
    Calendar/
      Calendar.swift                   Calendar, CalendarRights
      CalendarEvent.swift              CalendarEvent, EventLocation, RecurrenceRule, EventAlert,
                                       EventParticipant   — all decode-only
      EventTimeZone.swift              the three-state absent/floating/named encoder
      JSCalendarDate.swift             LocalDateTime and ISO-duration parsing/formatting
      MaterialisedHorizon.swift        opaque strings, Equatable, never parsed
    Methods/
      CalendarMethods.swift            CalendarGet, CalendarEventGet, CalendarEventQuery
      CalendarEventSet.swift           CalendarEventSet, NewCalendarEvent, CalendarEventPatch

  PLMailCore/
    Calendar/
      CalendarWindow.swift             half-open, MAX_DAYS, GUARANTEED_DAYS, the union fetch bounds
      CalendarRepository.swift         actor: refresh(window), the two-query round trip, paging
      CalendarAvailability.swift       the two-source boolean and its re-probe rule
      CalendarWriter.swift             create/update/delete → CalendarWriteResult
      EventDraft.swift                 whole-event draft; recurrenceRule create-only
      EventCluster.swift               clusterRows, the five-field agreement, startKey
      DayGridLayout.swift              placeDay, assignLanes, slotAt   — pure, no SwiftUI
      CalendarViewMode.swift           modes, windows, steps, headings
      CalendarPreferences.swift        the one persisted key
    Store/
      SchemaV1.swift                   (edit: + StoredCalendar, StoredCalendarEvent,
                                        StoredOccurrence)
      Snapshots.swift                  (edit: + CalendarSnapshot, EventSnapshot,
                                        OccurrenceSnapshot — Hashable, Sendable, Identifiable)
      SyncStore.swift                  (edit: the calendar write methods; still the only writer)

  PLMailUI/
    Calendar/
      CalendarView.swift               the shell: NavigationSplitView on iPad, stack on iPhone
      CalendarBoardView.swift          mode switch
      AgendaView.swift
      TimeGridView.swift               day and week
      MonthGridView.swift              chips on iPad, dots only when measured space forbids
      YearGridView.swift               iPad (and iPhone landscape, if it earns it)
      EventChipView.swift              + BlockTextPlan
      EventDetailView.swift            inspector on iPad, pushed on iPhone
      EventEditorView.swift
      EventFormState.swift             fields + the two validation rules
      CalendarSidebarView.swift        calendar list, visibility toggles
      CalendarTheme.swift              hex → Color, contrast-safe label colour, dark-mode fills

App/
  Intents/CalendarIntents.swift        ShowCalendarIntent, CreateEventIntent
Widget/
  PLMailCalendarWidget.swift           next event; blocked on the App Group, says so
```

Skeletons, to fix the shape:

```swift
/// `CalendarEvent/query`.
///
/// **The window is not optional.** An unbounded query is `unsupportedFilter`, because
/// occurrences are materialised only to a horizon and "everything" would come back
/// looking complete while stopping two years out — a truncation nothing reports and no
/// client can detect.
public struct CalendarEventQuery: JMAPMethod {
    public static let name = "CalendarEvent/query"
    public static let capability = Capability.calendars

    public struct Arguments: Encodable, Sendable {
        public var accountID: AccountID
        public var filter: Filter
        public var position: Int?
        /// Capped at 500 server-side; a larger value is silently clamped rather than refused.
        public var limit: Int?
        /// Switches the unit from the series to the occurrence. Ids become opaque
        /// `<eventId>_<recurrenceId>` strings that `CalendarEvent/set` will not accept —
        /// write through `seriesId` instead.
        public var expandRecurrences: Bool?

        private enum CodingKeys: String, CodingKey {
            case accountID = "accountId"
            case filter, position, limit, expandRecurrences
        }
    }

    /// The only three conditions the server compiles. Anything else — including a
    /// `FilterOperator` — is refused by name rather than ignored, because a filter
    /// quietly dropped returns too much and the client cannot tell.
    public struct Filter: Encodable, Sendable {
        public var after: Date
        public var before: Date
        public var inCalendar: CalendarID?
    }

    public struct Result: Decodable, Sendable {
        public var accountID: AccountID
        /// Always the literal `"fixed"`. There is no `/changes` to hand it back to.
        public var queryState: StateToken
        /// Always `false`. See `CalendarState` on the server: calendars are written from
        /// four places and only one is inside `src/Jmap/`, so a partial change log would
        /// be a lie with a number on it.
        public var canCalculateChanges: Bool
        public var position: Int
        public var ids: [CalendarEventID]
        public var total: Int
        public var limit: Int?
    }
}
```

```swift
/// How a start relates to a zone, which is three answers and not an optional.
///
/// Reading the wire's `timeZone` as `String?` collapses the first two cases and quietly
/// zones every floating event the client sends — turning a birthday into something that
/// moves when the user travels.
public enum EventTimeZone: Sendable, Equatable {
    /// The property is absent: the server uses the calendar's own zone.
    case unspecified
    /// The property is an explicit `null`: JSCalendar floating time (RFC 8984 §4.1.2).
    /// This is what an all-day event is.
    case floating
    /// An IANA name.
    case named(String)
}
```

---

# Part 7 — Phased build plan

Each phase ends at a checkpoint that is demonstrable and testable on its own. `swift test
--package-path Packages/PLMail` stays green throughout, and `xcodebuild` is run too — `PLMailUI`
is `#if os(iOS)` and compiles away on the host, so a green suite proves nothing about the views.

### Phase 0 — Prove the wire (JMAPKit only, no UI)

`Capability.calendars`; the identifier namespaces; `Calendar`, `CalendarEvent`, `EventTimeZone`,
`RecurrenceRule`; the four methods.

**Checkpoint:** `JMAPKitTests` decode captured fixtures for a collapsed query, an expanded query,
a series `get`, an occurrence `get`, a create, and each documented refusal. `swift test` green on
the host, no simulator.

> Get the fixtures from a real dev server (`docker compose up --build`, then the seeded calendar
> commands under `src/Command/Test/`). **Do not hand-write them** — hand-written fixtures are how a
> client ends up pinning its own misunderstanding.

### Phase 1 — Read-only agenda on iPhone

`StoredCalendar` / `StoredCalendarEvent` / `StoredOccurrence` + snapshots + `SyncStore` methods;
`CalendarWindow`; `CalendarRepository.refresh` with the single two-query round trip and paging at
100; `CalendarAvailability`; `AgendaView`; the sidebar/tab row gated on availability.

**Checkpoint:** a 30-day agenda renders from cache, refreshes on appear and on pull, renders
offline, shows all three empty states and the horizon notice, and the row is absent on a server
without the capability.

### Phase 2 — The grid

`EventCluster`, `DayGridLayout`, `EventChipView`, `TimeGridView` (day + week), `MonthGridView`,
`CalendarViewMode`, mode persistence, tap-to-create slot.

**Checkpoint:** overlapping events lane correctly; a multi-day event clips with the continues-before
/ continues-after affordances; a duplicated meeting collapses to one chip and says "2 calendars";
month steps by a month.

### Phase 3 — The editor

`EventFormState` with both validation rules, `EventDraft`, `CalendarWriter`, `CalendarWriteResult`,
`EventEditorView`, `EventDetailView`, delete with confirmation.

**Checkpoint:** create, edit and delete round-trip against a dev server; a read-only calendar's
controls are greyed and a `forbidden` is still handled; recurrence is offered on create and shown
read-only on edit; an all-day event's end date is drawn a day earlier than it is stored.

### Phase 4 — iPad

`NavigationSplitView` shell, the standing detail inspector, chips-not-dots in month cells,
`YearGridView`, the keyboard map, pointer hover, multi-window.

**Checkpoint:** rotation and Stage Manager resize keep the selection; every keyboard shortcut has a
visible equivalent; a month cell degrades to dots only when measured space actually forbids a chip.

### Phase 5 — System integration

`.searchable` over the cache, `ContentUnavailableView` polish, context menus, App Intents,
Spotlight/Handoff, `EKEventEditViewController` "Add to Calendar", `.ics` share, the widget (App
Group permitting), a full VoiceOver pass.

**Checkpoint:** the app is drivable end to end with the screen curtain on. Note that
`WHATS-LEFT.md` records **VoiceOver has never had a real pass** anywhere in this app — the calendar
is the worst possible surface on which to continue that, so this checkpoint is not optional.

### Not in scope for v1

Drag-to-move (needs a series/occurrence choice and a `recurrenceOverrides` patch), RSVP (no server
route), alerts (no server route, and a double-delivery risk), `.ics` subscription, sharing, booking
pages, Live Activities, any EventKit mirror.

---

# Part 8 — What to test

swift-testing suites, sentences about behaviour, per the house style.

**`JMAPKitTests`**
- A `LocalDateTime` with a trailing `Z` is refused on encode, not silently sent.
- `EventTimeZone.unspecified` omits the key entirely; `.floating` encodes an explicit `null`.
- An occurrence id decodes as a `String` and is never split.
- `expandRecurrences: false` and absent produce byte-identical requests.
- Each documented refusal decodes into the right `MethodErrorType`, and
  `cannotCalculateOccurrences` survives as data.
- A `properties`-filtered `get` decodes with `uid` and `@type` absent.

**`PLMailCoreTests`**
- `DayGridLayout`: the run boundary; the greedy first-fit lane; a whole run sharing one lane count;
  longest-first among equal starts; an event ending exactly at midnight is not `continuesAfter`;
  an end before its start clamps rather than inverting; a 23:30 event on a spring-forward day does
  not overflow its own day.
- `slotAt` snaps **down**, and clamps at both ends.
- `EventCluster`: two rows, same UID and start, different calendars → merged; the same but with
  different titles → **two** clusters, not a majority merge; three rows where one disagrees → three
  clusters; two rows on one calendar → never merged; a null UID never merges; a zoned and a
  floating copy never merge; `10:00 Europe/Berlin` and `09:00 Europe/London` do merge.
- Member order is stable across two runs over the same rows in different storage order.
- `CalendarViewMode`: the month window is always 42 days; month steps by a month off the 31st; the
  week heading drops the repeated year and the repeated month; an unknown wire value degrades.
- `CalendarWindow`: `MAX_DAYS` refused; the clamp reports `mayBeIncomplete`; a fully-clamped-out
  window does not query; the fetch bounds are the union, asserted against a device zone east **and**
  west of UTC.
- `EventFormState`: an all-day event starting and ending on the same day is valid; a timed one
  ending at its start is not; all-day duration is `daysBetween + 1`; loading an all-day event draws
  the end a day earlier; an update never carries `recurrenceRules`; a blank title becomes the
  localised *Untitled*; a new event starts at the next whole hour; a slot-created event is not
  rounded twice.
- `CalendarAvailability`: emits `false` first; the cache alone answers true; a probe that never
  answers does not block; **the regression test for 2026-08-06** — availability becomes true after
  a credential is stored, without a relaunch.
- Writes: a `Refused` rolls the optimistic change back and is never retried; an `Unreachable`
  carries the host; a write touching recurrence re-queries the last window.

**`PLMailUITests`**
- `CatalogueCoverageTests` keeps passing — every new key in both `en.lproj` and `de.lproj`.
- Chip accessibility labels include title, time span, calendar, and "in 2 calendars" when merged.

**UI / manual**
- Both appearances at every mode (Android's screenshot matrix is the checklist:
  agenda / day / week / month / month-agenda / month-full / empty / offline / horizon /
  large-text, light and dark).
- Accessibility text sizes on week — confirm the agenda fallback rather than a hyphenated grid.
- iPad: rotation, Stage Manager resize, every keyboard shortcut, VoiceOver rotor.

---

# Part 9 — Do not regress

- **`state` is `"fixed"`. There is no delta and no push.** Refresh while somebody is looking. No
  timer, no background task, no SSE type subscription for calendars. Store the token and hand it
  back when a `/changes` appears; do not special-case the string.
- **Never expand a recurrence rule client-side.** Ask for `expandRecurrences`. The phone and the
  browser will disagree at DST boundaries and on overridden instances, and the disagreement is
  invisible until somebody misses a meeting.
- **Never parse an occurrence id.** It is opaque by the draft's own word; read `start`,
  `recurrenceId` and `seriesId` off the object.
- **Never parse `materialisedHorizon`.** They are PHP relative-date strings. Clamp to your own
  conservative line and report `mayBeIncomplete`.
- **Chunk `CalendarEvent/get` at 100, not 500.** `maxEventsInGet` is lower than core's limit on
  purpose.
- **Do not send a `Z` on `start`.** JSCalendar `LocalDateTime` only.
- **Do not collapse `timeZone` to an optional.** Three states.
- **Do not send `recurrenceRules` on an update** unless the user edited the rule in a real
  recurrence editor that read the stored rule first.
- **Do not seed the editor from an occurrence.** Fetch the series.
- **Do not queue calendar writes.** No `ifInState`, no conflict story, and a replayed refusal loops
  forever.
- **Do not filter the query by `isVisible`.** It is a display preference, and the server says so.
- **Do not widen a block to fill free lanes.** Width means "this many things are happening at
  once".
- **Do not build an RSVP, an alert editor, an `.ics` import or a sharing UI.** No JMAP route
  exists; ask for one (Part 4).
- **Do not schedule local notifications from the readable `alerts`.** The server already delivers
  them, to this device, over the push subscription the app registered. You would double every one.
- **Do not treat a missing invitation as a sync bug.** An unaccepted invitation materialises no
  occurrences and is absent from every query by design. Say so in the reader.
- **Do not drive the HTML or Turbo routes** for any of the above.
- **Do not put anything irreplaceable in the store.** Every calendar row is reconstructible from a
  windowed query, which is what keeps `MailStack`'s delete-and-resync recovery legal.
- **Do not adopt EventKit as a two-way mirror.** §5.5.
- **Do not read the stale `pl_mail/` working tree.** `git show origin/main:<path>`.

---

## Open questions for the maintainer

1. Does `primaryAccounts` carry `urn:plmail:params:jmap:calendars`? The internals doc says the
   resolver picks the account already listed there, but I verified the resolver and the
   `accountCapabilities` placement rather than the `primaryAccounts` line itself. The recommended
   client rule (scan `accountCapabilities`) is correct either way, but a confirmed answer would let
   the client take the cheaper route.
2. Is `alerts` genuinely unreachable, given `CalendarEventWriter::write()` already accepts an
   `alerts` parameter that the web editor uses? If exposing it is as small as it looks, it is the
   cheapest large win available.
3. **Resolved, but worth confirming in writing:** alert delivery is the server's — `display` alerts
   go out as `CalendarAlert` pushes to every verified device, `email` alerts by mail, with no
   fallback between them. So the client schedules nothing and handles the payload. Confirm the
   payload's deep-link shape so the app routes to the right day, and confirm that an iOS APNs
   subscription (`urn:de:plmail:params:jmap:apns`) receives `CalendarAlert` on the same footing as
   Web Push and FCM — the alert channel reaches `PushSenderRegistry`, but I have not verified that
   the APNs sender is in that registry.
4. Is an RSVP method plausible for the next server milestone (Part 4, item 1)? It is the largest
   user-visible hole in a native client — invitations are *invisible* until accepted, not merely
   unanswerable — and the seam (`InviteReader` / `InviteResponder`) already exists.
5. Would a read-only `EventSourceLink` on the JMAP event (just the message id) be acceptable? It is
   one field, and it is what turns "why is this flight on my calendar?" into a tap through to the
   confirmation mail — the single best piece of mail↔calendar integration available without any
   new write path.

## Blocked on the server: the RSVP band

The Claude Design mock puts a second band above the day grid — **Needs an
answer**, one line naming the invitation, and Yes / Maybe / No. It cannot be
built against the API as it stands.

`src/JMAP/Mapper/CalendarEventMapper.php` publishes `kind` and `source` on a
`CalendarEvent` and no attendee data at all. `JmapEventWriter` says so
explicitly: *participants — an RSVP is answered through the invite flow
(`InviteResponder`)*, which is a web route, not a JMAP method. So the client
can neither read whether an invitation is outstanding nor write an answer to
one, and three buttons that cannot answer are worse than no band.

What the server would have to add, smallest first:

1. `myParticipation` on the `CalendarEvent` read vocabulary — the column
   already exists on `calendar_event`, so this is a mapper line, and it is
   enough on its own to draw the band read-only and deep-link the answer to
   the web UI.
2. A writable participation, or a `CalendarEvent/respond` method wrapping
   `InviteResponder`, so the answer can be given from the app.

Until (1) lands, the docked column draws the **Happening soon** band only,
which needs nothing the server does not already send.
