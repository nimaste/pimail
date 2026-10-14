# Search, labels, design system, and the iPad

Audit of `pl_mail_ios` against `pl_mail_android` and against the server's actual
behaviour in `pl_mail`. Everything here was read from source; paths are absolute
from the workspace root and line numbers are as of this audit.

Effort sizing: **S** ≤ half a day, **M** 1–2 days, **L** 3–5 days, **XL** more
than a week.

---

## Server version note

**The `pl_mail/` working tree is stale. Do not audit against it.** It is behind
`origin/main` by enough to invert conclusions, not merely to soften them. Three
examples found while writing this document:

- The stale tree's `SearchQueryParser` has no `cc:` and no `label:` operator;
  `origin/main` has both, and `label:` is a real filter rather than dead code.
- The stale tree compiles `in:archive` to a `NOT EXISTS` over the Inbox label;
  `origin/main` compiles it to a plain `lbl.role = 'archive'` match. **This
  reverses which client is correct** — see [A2](#a2--inarchive-ios-is-right-android-is-not).
- The stale tree exposes no label `color` over JMAP and no Appearance methods at
  all; `origin/main` has both, fully specified. A plan written against the stale
  tree would have declared the entire design-system effort blocked on a server
  change that already shipped.

Read everything through git, without checking anything out:

```
git -C pl_mail show origin/main:src/Service/Search/SearchQueryParser.php
git -C pl_mail show origin/main:src/Jmap/Query/EmailFilterCompiler.php
git -C pl_mail show origin/main:src/Jmap/Mapper/MailboxMapper.php
git -C pl_mail show origin/main:src/Jmap/Mapper/AppearanceMapper.php
git -C pl_mail show origin/main:src/Jmap/Method/Settings/AppearanceGetMethod.php
git -C pl_mail show origin/main:src/Jmap/Method/Settings/AppearanceSetMethod.php
git -C pl_mail show origin/main:src/Jmap/Session/SessionBuilder.php
git -C pl_mail show origin/main:docs/CLIENT_DEVELOPMENT.md
git -C pl_mail ls-tree -r --name-only origin/main -- src/Jmap/Method
```

One caveat that applies throughout section A: **`CLIENT_DEVELOPMENT.md`'s own
search-operator table is itself stale on `origin/main`** (§"The web UI's search
syntax", ~line 793). It omits `cc:` and `label:`, and its `in:` list omits four
aliases the parser accepts. `SearchQueryParser.php` is the authority; the doc is
a summary that has drifted. Where they disagree below, the parser wins.

The Android findings come from that repository's working tree. Where an Android
claim asserts something about the *server*, treat it as needing the same
re-verification this note describes — Android may have been written against an
older server too. Claims about Android's own UI are direct reads and stand.

---

## Summary

**Search (A).** iOS is the *best* of the three clients on search, not the worst.
It is the only client with operator autocomplete, the only one with sender
suggestions, and the only one whose filter chips actually edit the query.
Android's identically-shaped chips have an empty `onClick` despite KDoc claiming
otherwise. But `origin/main`'s parser has moved and iOS has not followed it:
two operators are missing entirely (`cc:`, `label:`), the `in:` vocabulary is
wrong in both directions, and the server's *unknown-value* behaviour inverted —
it now falls back to free text where iOS still drops silently, and iOS's source
comments document the old behaviour as deliberate.

**Labels (A).** The real gaps, and they are no longer blocked on anything:

- **Label colour is ignored.** `origin/main`'s `MailboxMapper` emits `color` and
  `MailboxSetMethod` accepts it — a closed nine-token vocabulary. iOS hashes the
  label id through `AvatarPalette` instead, so a label the user coloured red in
  the web UI shows up as, say, mauve on the phone.
- **Nesting is invisible.** Unlimited depth server-side, leaf `name` + `parentId`
  on the wire; iOS renders bare leaf names, so two labels nested under different
  parents are indistinguishable.
- **Rows carry no label chips.** Android's do.
- **`SearchSnippet/get` is unbatched** against a hard 500-id cap, so a deep
  search silently loses all highlighting.

**Design system (B).** iOS has no design system in the sense the server means.
`Theme/ThemeEnvironment.swift` is a 19-line placeholder whose own comment says
it awaits a server API — **that API now exists**, fully specified, as
`Appearance/get` / `Appearance/set` over `urn:plmail:params:jmap:appearance`:
28 properties, a singleton object, published vocabularies and ranges in the
Session, clamping rather than refusal on numerics. Meanwhile iOS has three
unrelated hardcoded palettes and **no asset catalogue at all**, so
`Color.accentColor` resolves to system blue. This is now a buildable feature
rather than a stub, and it is the largest single piece of work here.

**iPad (B).** The layout is structurally right and the pane treatment is the
best thing in the app — better than anything Android has. But almost everything
*beyond* layout is missing: no `⌘` menu, no list keyboard navigation, no drag
and drop, no pointer hover, no multi-window, no Handoff, no Spotlight, no
haptics, and exactly one breakpoint (`sizeClass != .compact`) doing four jobs.
Today an iPad running plMail is a correctly-proportioned three-column app that a
keyboard-and-trackpad user cannot drive. That is the gap worth closing, and it
is mostly additive work on a sound structure.

**Nothing in Android's UI layer should be ported shape-for-shape.** See
[The Apple way](#the-apple-way).

---

## A. Search & labels — gaps

| # | Area | iOS today | `origin/main` server | Sev | Effort |
|---|---|---|---|---|---|
| A1 | `cc:` operator | Not recognised → free text | Real operator, `cc_addresses ILIKE` | High | S |
| A2 | `label:` operator | Not recognised → free text | Real operator, exact leaf name, non-role | High | M |
| A3 | Unknown operator *values* | Dropped silently | Fall back to **free text** | High | S |
| A4 | `in:` vocabulary | Misses `draft`,`deleted`,`bin`,`spam`,`archived`; invents `flagged`,`important`,`all` | 12 aliases → 8 roles | High | S |
| A5 | Label colour | Hashed from label id | `color` on the wire, read *and* write | High | M |
| A6 | Label nesting | Leaf names only, flat | Unlimited depth, `parentId` | High | M |
| A7 | `SearchSnippet/get` batching | All paged-in ids in one call | Hard cap 500 → `requestTooLarge` | High | S |
| A8 | Label chips on rows | Absent | — (client-side) | Med | M |
| A9 | Subject-match snippets | Highlighted subject drawn in *snippet* slot | Returns subject and preview separately | Med | S |
| A10 | `is:read`+`is:unread` | Empty result, no explanation | Contradiction; returns nothing | Med | S |
| A11 | Skipped-account reporting | Silent | — (client-side) | Med | S |
| A12 | `threadCategory` filter | Unused | Supported; `MessageCategory` 5 values | Med | M |
| A13 | Date grammar | `today`/`yesterday` + 4 formats | Anything `DateTimeImmutable` parses | Low | S |
| A14 | `in:archive` | **Correct** | `lbl.role = 'archive'` | — | — |
| A15 | Server `sortOrder` | Fetched, stored, discarded by sidebar | Always `0` for custom labels | — | — |
| A16 | Saved searches | Absent | Absent — no such concept anywhere | — | — |

### A1 — `cc:` is missing

`origin/main`'s parser lists `cc` in `SearchQueryParser::OPERATORS` and assigns
`$filters->cc = $value`; the SQL is
`m.cc_addresses::text ILIKE :ccAddr` with `%value%` bounds. The JMAP filter
vocabulary has the matching condition — `EmailFilterCompiler::property()` maps
`'cc' => jsonAddressLike('m.cc_addresses', …)`, and `'bcc'` beside it.

iOS `SearchQuery.parse`
(`pl_mail_ios/Packages/PLMail/Sources/PLMailCore/Search/SearchQuery.swift:80-92`)
has no `case "cc"`, so `cc:alice` falls to `remainder` and is searched as the
literal string `cc:alice` — which matches nothing, because the tsvector has no
such token. The user gets an empty result set for a valid query.

Fix: a `cc` field on `ParsedSearchQuery`, a case in the switch, an
`EmailFilter.cc` in `JMAPKit`, and a condition in
`SearchQueryCompiler.conditions`. Add `cc:` to `SearchOperator.all` and to
`SearchTokensView.tokens`. Android has the same hole. **(S)**

`bcc:` is *not* a parser operator even though the JMAP compiler supports the
condition — do not add it to the search box; it would work over JMAP and fail on
the web, which is the divergence this whole exercise exists to prevent.

### A2 — `label:` is a real operator and iOS does not have it

`origin/main` parses `label:receipts` into `$filters->label` and compiles it to:

```sql
LOWER(lbl.name) = :labelName AND lbl.role IS NULL
```

Three things follow from that exact SQL, and all three matter for the client:

1. **Exact match on the leaf name, not a prefix or substring.** `label:rec` does
   not find "Receipts".
2. **Case-insensitive**, via `LOWER()` on both sides.
3. **Not hierarchy-aware.** It matches `Label::$name`, which is the *leaf*.
   `label:invoices` matches every label named "Invoices" regardless of parent,
   and `label:work/invoices` matches nothing at all, because no leaf name
   contains a slash — `MailboxSetMethod::requireName` rejects slashes outright.
   Do not "helpfully" resolve paths; matching the server means matching this.
4. **Role labels are excluded**, so `label:inbox` finds nothing. `in:inbox` is
   the operator for that, and the two are genuinely different.

The client-side mapping is the interesting part. `EmailFilterCompiler` *does*
have `hasLabel`/`notLabel` taking user-scoped Label ids — and
`CLIENT_DEVELOPMENT.md` explicitly says **not** to use them: "They are not part
of the client-facing filter vocabulary — use `inMailbox`." So `label:` must be
resolved client-side, name → the per-account binding id, then emitted as
`inMailbox`. iOS already has exactly the machinery for this: `sync.mailboxes`
carries `name`, `role` and `labelID`, and `SearchQueryCompiler.mailboxID(for:)`
already does the per-account resolution dance for `in:`.

Note the multi-account subtlety, which is why this is M and not S: a label is
user-scoped but a Mailbox is a per-account binding, so `label:receipts` must
resolve to a *different* mailbox id in each account, and an account with no
binding for that name must be skipped exactly as `canSearch` skips an account
missing a role. That is the same rule, applied to a second dimension.

Android lacks this operator too. **(M)**

### A3 — Unknown operator values now become free text, not nothing

This is the behaviour change most likely to be "fixed" backwards by someone
reading iOS's comments, because those comments are emphatic and were correct
when written.

`SearchQuery.swift:56-60` states as deliberate policy:

> **A bad value for `has:`, `is:`, `after:` or `before:` is dropped silently**,
> not turned into free text. `is:bogus` narrows nothing and searches for nothing.

`origin/main` does the opposite, and explains why in its own docblock:

> An operator that cannot be honoured — `is:important`, `in:nowhere`, a date
> that is not a date — falls back to free text rather than being dropped. A
> dropped operator is a filter the user asked for and did not get, and the
> result is a page of everything that looks like the search was ignored; as free
> text it finds little or nothing, which is at least the truth.

Mechanically: `applyHas`, `applyIs` and `applyIn` return `bool`, `parse()`
collects that into `$applied`, and `false === $applied` pushes the **whole
original token** onto `$remainder`. Same for a `parseDate` that returns null.

So today, `is:bogus`:
- on the web, searches for the literal text `is:bogus` → near-certainly empty;
- on iOS, narrows nothing and searches for nothing → **the entire mailbox**.

That is the exact failure mode the server comment names, and iOS is the client
producing it. The server's reasoning is better; adopt it.

There is one exception to preserve, and iOS effectively already has it. An
*empty* value on a **known** operator is skipped entirely rather than becoming
free text — `from:` mid-typing must not search for the word "from" — but an
empty value on an **unknown** operator does become free text, so that `Re:`
stays searchable as a word somebody typed. iOS reaches the same outcome by a
different route: `from:` sets `from = ""` and
`SearchQueryCompiler.conditions:31-35` skips empty values, while `Re:` is an
unknown name and already falls to `remainder`. Keep both behaviours when
implementing the free-text fallback; the change is only for *non-empty
unrecognised* values.

Rewrite `applyHas`/`applyIs` to return `Bool`, add the same for `in:` and the
two date cases, and append the original token to `remainder` on false. Update
the doc comment at `:56-60`, which will otherwise remain a confident statement of
the wrong rule. **(S)**

### A4 — `in:` accepts words the server doesn't, and rejects words it does

`SearchQueryCompiler.canSearch` / `mailboxID`
(`Search/SearchQueryCompiler.swift:79-96`) matches `query.mailboxRole` against
`MailboxSnapshot.role?.rawValue`, and the role enum
(`Packages/PLMail/Sources/JMAPKit/Mail/Mailbox.swift:61-91`) includes `snoozed`,
`flagged`, `important` and `all`.

`origin/main`'s `SearchQueryParser::ROLES` is a closed twelve-entry alias table
resolving to eight roles:

```
inbox→inbox   sent→sent    drafts→drafts   draft→drafts
trash→trash   deleted→trash   bin→trash
junk→spam     spam→spam
archive→archive   archived→archive
snoozed→snoozed
```

Divergences, both directions:

- **iOS rejects valid input.** `in:draft`, `in:deleted`, `in:bin`, `in:spam`,
  `in:archived` all work on the web. On iOS `canSearch` returns false for every
  account and the search yields nothing. `in:spam` is the sharp one — iOS's role
  is spelled `junk`, so the *other* alias works and this one does not.
- **iOS invents input.** `in:flagged`, `in:important`, `in:all` narrow on iOS.
  On the web they are unrecognised, so under A3 they become free text.

Fix by giving `SearchQuery.parse` the server's alias table explicitly rather
than passing `value.lowercased()` straight through to `mailboxRole`, and mapping
the resolved role onto the iOS `MailboxRole` (`spam` → `.junk`). Unrecognised
values then fall to free text via A3, which is one code path for both fixes.

Keeping `in:flagged` as a documented iOS extension is defensible — Starred is a
real list in the sidebar. Doing it by accident, while `in:spam` fails, is not.
Android encodes the alias table correctly. **(S)**

### A2/A14 — `in:archive`: iOS is right, Android is not

Recorded prominently because the stale tree says the opposite and someone will
find it.

`origin/main`'s search SQL treats archive as an ordinary role:
`$where[] = 'lbl.role = :labelRole'` with `labelRole = 'archive'`, reached
through the same `ROLES` table as every other mailbox. There is no special case.

- iOS compiles `in:archive` to `.inMailbox(archiveID)`
  (`SearchQueryCompiler.swift:46`). **Correct.**
- Android compiles it to `Not(InMailbox(inbox))`. That matched the *older*
  server and no longer matches this one.

The wrinkle worth carrying forward: `CLIENT_DEVELOPMENT.md` still says elsewhere
that "'archived' in plMail's domain model means *carries no Inbox label*", and
that the Archive label is "IMAP location bookkeeping for plain-IMAP accounts,
and is hidden by default". Both statements remain true of the *domain model* and
of the archive *action* — to archive, you remove the Inbox mailbox id. They are
simply no longer true of the `in:archive` *search operator*, which now means the
literal label. Do not let the two collapse into each other: iOS's archive action
and iOS's `in:archive` search are correctly different, and should stay that way.

Because Archive is created unsubscribed, `canSearch` will skip accounts lacking
an Archive binding — which is right, and is why A11 matters.

### A5 — Label colour is thrown away, and no longer needs a server change

`origin/main` puts colour on the wire in both directions.

**Read** — `MailboxMapper::toJmap` emits it, with a comment naming exactly this
problem:

> plMail extension, like labelId above. RFC 8621 gives Mailbox no colour, but
> the label has one and every client draws chips with it — without this the
> phone can only draw them grey while the web draws them coloured, which reads
> as two different label systems.
>
> A Tailwind token, not hex: see LabelColor. Null is a label with no colour
> chosen, which is distinct from one coloured grey.

**Write** — `MailboxSetMethod` takes `color` on both create (`:134`, `:152`) and
update (`:286-295`), through `requireColor()` (`:421-437`), which accepts a
`LabelColor` case or an explicit `null`, and refuses anything else with
`invalidProperties` naming the whole vocabulary in the message.

The vocabulary is nine closed tokens, in `App\Domain\Enum\Mail\LabelColor`:

```
gray  red  orange  amber  green  teal  blue  violet  pink
```

Not hex. Not free-form. And **null is a distinct third state** — "no colour
chosen" is not the same as "grey".

iOS ignores all of it and colours every label by hashing the label id:
`MailboxSidebarView.swift:93`, `LabelPickerView.swift:164`,
`BulkLabelPickerView.swift:99`, `LabelManagerView.swift:126`. Stable and
handsome — but not the colour the user chose, and different from the web on
every label.

`MailboxSnapshot` (`PLMailCore/Store/Snapshots.swift:54-79`) has no `color`
field, and `JMAPKit`'s `MailboxSet.Creation` / `Patch`
(`Packages/PLMail/Sources/JMAPKit/Methods/MailboxSet.swift:54-131`) carry only
`name`, `parentID`, `isSubscribed`, `sortOrder`. Note that `Patch` already has
the double-optional `parentID??` trick with a hand-written `encode(to:)` to
distinguish absent from null — **`color` needs exactly the same treatment**, for
exactly the same reason, since clearing a colour is a real operation.

Work: a `LabelColor` enum mirroring the nine wire tokens plus `nil`; `color` on
the snapshot and through `SyncStore`; `color` on `Creation` and `Patch` with the
double-optional encoding; a swatch row in `LabelNameSheet`; and resolution
through the token layer from [P1](#p1--ground-the-palette-and-adopt-appearance-l).
`AvatarPalette` becomes the fallback for labels with `color == nil`, which is
the correct meaning of that third state. Treat an unrecognised token as "no
colour" rather than an error — the set can grow. **(M)**

### A6 — Nesting is invisible

`maxMailboxDepth` is `null` in the Session (`SessionBuilder.php:184`) — unlimited
depth. The wire carries leaf `name` plus `parentId`, expressed in binding-id
space (`MailboxMapper::parentId`).

`MailboxSnapshot.parentID` exists (`Store/Snapshots.swift:62`) and is used in
exactly one place: `LabelActions.nameIsTaken`. The sidebar's `mailboxes(for:)`
(`MailboxSidebarView.swift:194-217`) and the unified `labels` list (`:266-279`)
are flat alphabetical lists of leaf names. Two labels named `Q1` under `Work` and
`Personal` are two identical rows, and `LabelPickerView` offers two identical
checkboxes.

Android walks `parentId` with an 8-deep cycle guard, joins with `/`, and renders
flat-with-paths using `MiddleEllipsis` so both ends survive.
`CLIENT_DEVELOPMENT.md` blesses flat-with-paths explicitly.

Do that first on iOS — a `path` computed property plus `.truncationMode(.middle)`
— because it removes the ambiguity for a fraction of the cost of a tree. A real
`DisclosureGroup` hierarchy in the sidebar is a later refinement; the machinery
already exists there in `accountGroup(for:)`.

Then wire a parent picker into `LabelNameSheet` and pass it to the `parentID:`
parameter `LabelActions.create` has always accepted
(`Sync/LabelActions.swift:68`) and no caller has ever used. Re-parenting is also
available (`MailboxSetMethod` `case 'parentId'`), and the refusal iOS already
translates — `mailboxHasChild`, "Delete the labels nested inside this one first"
(`LabelActions.swift:258-260`) — is the delete-side counterpart. **(M)**

### A7 — Snippet requests exceed the server's hard cap

`MailSyncService.loadSnippets` (`PLMailCore/Sync/MailSyncService.swift:510-554`)
collects every stored feed row for an account and sends all of them in one
`SearchSnippet/get`.

`SearchSnippetGetMethod` caps at `MAX_OBJECTS = 500` and throws
`requestTooLarge` above it. iOS's catch at `:551` logs at `.debug` and moves on,
so a search paged past 500 results loses **all** highlighting, for every account,
silently.

Chunk the ids at 500 and merge. While there: the server's highlight options are
`StartSel=<mark>, StopSel=</mark>, MaxWords=24, MinWords=8`, which is worth
knowing when sizing the snippet line — snippets are bounded and short, so the
row does not need defensive truncation beyond its existing `lineLimit`. **(S)**

### A8 — Rows carry no label chips

`ThreadRowView.badges` (`List/ThreadRowView.swift:319-342`) renders a snooze
badge and an account tag, and nothing else.

Android's `ThreadRow` renders up to two label chips against a measured budget:
96dp per chip, 160dp per cluster, a 104dp floor reserved for the preview, and a
slot count that drops to one below a 400dp **pane** width. That last distinction
is the part worth copying — it is keyed on the pane, not the size class, and on
iOS the list column is 396–540pt (`MailView.swift:352`), so a size-class test
would return the same answer at both ends and do nothing.

On iOS this is a `ViewThatFits` or a small custom `Layout`. It depends on A5
(chips need the real colour, and a grey chip for every label is worse than none)
and reads better after A6 (chips should show the leaf, tooltip/accessibility the
path). **(M)**

### A9 — A subject match is drawn in the snippet slot

`loadSnippets` stores `snippet.preview ?? snippet.subject`
(`MailSyncService.swift:546`) under one key, and `ThreadRowView.snippetLine`
(`:279-291`) draws whatever that is in the preview position. Searching for a word
that appears only in the subject therefore shows the subject twice: once plain on
the subject line, once highlighted below it.

The server returns the two fields separately and nulls whichever did not match.
Keep them apart: highlight the *subject line* when `snippet.subject` is non-nil,
and use `snippet.preview` for the snippet line. `SnippetText.runs(from:)` already
produces exactly the runs both need.

Android conflates them the same way, so this is a chance for iOS to be better
rather than a gap to close. **(S)**

### A10 — `is:read is:unread` returns nothing with no explanation

Both `SearchQuery.applyIs` (`Search/SearchQuery.swift:143-150`) and
`SearchQueryCompiler.conditions` (`:42-43`) treat the two as independent flags,
reproducing the server exactly — which is right, and the comment explaining why
is right. But the user sees an empty list with two lit tokens and no reason.

`SearchQueryEditor.toggling` already drops a conflicting `is:read` when the
*chip* is used (`SearchQueryEditor.swift:114-118`); typing both by hand gets
silence. This belongs in the empty-result `ContentUnavailableView`: a description
naming the contradiction and a button that strips one of the two. **(S)**

### A11 — A skipped account is silent

`ThreadListView.degradedSection` (`List/ThreadListView.swift:762-786`) names
accounts that failed to *sync*, and it is good. But
`SearchQueryCompiler.canSearch` returning false — an account with no binding for
the requested role, which for Archive is the default — drops that account from
the merge with no indication at all. The user sees fewer results and no reason.

The rule itself is correct and must survive the A4 fix: including an account that
cannot honour `in:archive` would return that account's entire mailbox, which is
the "search was ignored" failure the server's own comment warns about. What is
missing is only the reporting. Android surfaces this as a one-line note.

A5's `label:` work adds a second source of the same condition — an account with
no binding for the named label — so build the reporting once, for both. **(S)**

### A12 — `threadCategory` is unused

`origin/main`'s `EmailFilterCompiler` supports `threadCategory`
(`property()` → `threadCategory()`), matching `message_thread.category` against
`App\Domain\Enum\Mail\MessageCategory`:

```
primary  social  promotions  updates  forums
```

An unknown value is refused with `invalidArguments` — deliberately not
`unsupportedFilter` — and the error message carries the whole vocabulary,
because, in the compiler's own words, "a closed set the caller cannot discover is
only marginally better than no set, which is the lesson Mailbox.color paid for."

iOS uses none of it: no `threadCategory` in `EmailFilter`, no category in
`FeedID`, no tabs. This is Gmail's Primary/Social/Promotions tab model, and the
server maintains the column. Whether iOS should grow inbox tabs is a product
question that belongs in whichever parity document owns the list — flagged here
because it is *reachable from search*, and a `category:promotions` operator would
be a natural addition to the search box.

Two cautions if anyone builds it. It is **not** a `SearchQueryParser` operator,
so adding `category:` to the iOS search box would create an operator the web does
not have — the exact divergence this document keeps arguing against. Ask for it
server-side first. And the compiler's own comment notes that threads backfilled
before categorisation may have a null category, filled by `app:backfill
category`, so a category filter can under-report on an old install. **(M, and
gated on a server-side parser addition)**

### A13 — Date grammar is narrower than the server's

`SearchQuery.parseDate` (`Search/SearchQuery.swift:168-192`) accepts `today`,
`yesterday`, `yyyy-MM-dd`, `yyyy/MM/dd`, `dd.MM.yyyy`, `yyyy-MM-dd HH:mm:ss` and
ISO 8601. The server hands the value to PHP's `DateTimeImmutable`, which takes
relative phrases and `@`-epoch.

Largely theoretical, since the tokeniser splits on spaces and `after:-7 days`
could never have been one token. But under A3 the consequence changes: an
unparseable date now becomes **free text** rather than nothing, so
`after:whenever` should search for the literal string. Make sure the A3 rewrite
covers the two date cases and not just `has:`/`is:`/`in:`.

Worth recording as an iOS advantage: dates are anchored at *local* midnight, with
a written explanation of why the server's own timezone handling is ambiguous
(`:163-167`). The web does not do this. **(S)**

### A15/A16 — non-gaps, recorded so they are not re-investigated

- **`sortOrder`** is stored (`SyncStore.swift:103`) and used for one store fetch
  (`:1096`), but `MailboxSnapshot` does not carry it to the UI and the sidebar
  re-sorts by role-then-name. That is fine: `MailboxMapper` emits
  `$label->sortOrder ?? 0`, and it is `0` for every custom label. Android ignores
  it too, deliberately. Recorded so nobody "fixes" the sidebar to honour a field
  that is always zero.
- **Saved searches do not exist anywhere.** No type, table, method, endpoint or
  storage in any of the three repositories. The web UI's "recents" are eight
  entries in `localStorage`. If saved searches are wanted, that is a server
  feature request, not a client gap.
- **Search scoping** is unified-across-accounts on both clients, compiled per
  account and interleaved by date. There is no per-mailbox scope UI on either, by
  design; `in:` is the mechanism.

### Where iOS is already ahead

Worth protecting, because a naive "match Android" pass would remove all of it.

- **Operator autocomplete.** `SearchOperator.all` + `SearchSuggestions.suggest`
  offer the operators with plain-English captions while typing, matched on both
  the whole token and the part after the colon so `unr` finds `is:unread`.
  **Neither the web UI nor Android has any autocomplete at all.** The reasoning
  at `SearchOperator.swift:3-13` — that the operators are the most valuable and
  least discoverable thing about the field — is the best idea in this feature.
  A1 and A2 should extend this list, not bypass it.
- **Sender suggestions** reusing the composer's ranking rather than
  reimplementing it (`SearchSuggestions.swift:199-235`), and teaching the
  operator by completing a bare fragment to `from:ada@example.com`.
- **Chips that actually edit the query.** `SearchQueryEditor` rewrites the text
  so field, tokens and results cannot disagree (`SearchQueryEditor.swift:77-88`).
  Android's identically-shaped `FilterChip`s have an empty `onClick`; its own
  KDoc claims they remove the operator. They do not. Do not port that.
- **A date-preset menu** resolved against a calendar so "past month" is the same
  day last month, not thirty days. Android has no date picker in search at all.
- **Recents cap 10** vs 8 elsewhere, case-insensitive move-to-front, and a
  written reason for living in `UserDefaults` rather than the store
  (`Search/RecentSearches.swift:3-11`).
- **Bulk label tri-state with counts** — "3 of 40" beside a partial label
  (`BulkLabelPickerView.swift:106-118`). Android has the tri-state, not the count.
- **Label deletion copy that says what survives**
  (`LabelManagerView.swift:109-112`), and correct JMAP semantics: destroy is
  per-account and leaves other accounts alone. Note the web UI's
  `POST /labels/{id}/delete` is *not* equivalent — it cascades to children and
  removes the label everywhere. iOS's copy is right for the API iOS uses.
- **`LabelActions.describe`** maps every plMail refusal type —
  `invalidProperties`, `mailboxHasChild`, `forbidden`, `notFound`,
  `stateMismatch` — to a localised sentence naming the rule
  (`Sync/LabelActions.swift:250-272`). Android surfaces raw server strings.
  A5 adds one more case: `requireColor`'s refusal is `invalidProperties` too, so
  the existing mapping to "There's already a label with that name here" would be
  wrong for it. Distinguish on the message, or ask the server for a distinct type.
- **`SnippetText`** — split on `<mark>` first, unescape second, six entities,
  `&amp;` last. Correct, and matches the server's `htmlspecialchars` output
  exactly. Android's `Highlight.kt` is the same algorithm. Do not touch either.
- **Not-optimistic, not-undoable label CRUD**, with the reasoning written down
  (`LabelActions.swift:8-24`).

---

## B. Design system & adaptive layout — current state

### There is no token layer, and the server API it was waiting for has shipped

`Packages/PLMail/Sources/PLMailUI/Theme/ThemeEnvironment.swift` is 19 lines:

```swift
public struct ResolvedTheme: Equatable, Sendable {
    public static let placeholder = ResolvedTheme()
    public init() {}
}
```

Its doc comment states the intent and the dependency — Theme separated from
Layout, user knobs on top, "local settings today, the server once it exposes
`Appearance` over JMAP", and "a client that hardcodes its palette is explicitly
wrong". Nothing in the app reads it.

**The server exposes it now.** See [the Appearance API](#the-appearance-api-wire-shape)
below for the full wire shape; the headline is that this is no longer a
speculative abstraction to be designed, it is an API to be implemented against.

Every colour in the app is meanwhile a literal in one of three unrelated files:

- **`Theme/PanelStyle.swift`** — `surface`, `window`, `hairline` as
  `Color(light:dark:)` pairs, plus `cornerRadius: 20` and `inset: 10`. Three
  colours. The reasoning — warm paper rather than the system's cool grey; dark
  kept cold because warming it reads as a colour cast — is sound.
- **`Theme/ActionTint.swift`** — five swipe colours, hand-walked down in
  lightness until white content clears 4.5:1, with `destructive` deliberately
  left saturated.
- **`Theme/AvatarPalette.swift`** — twelve earthy hues, FNV-1a hashed (written
  out because Swift seeds `Hashable` per process), with an explicit warning that
  the array's order and count must never change.

There is no `ink`/`inkSoft`/`inkMuted`/`inkFaint` ladder, no `raised`/`sunken`,
no `danger`/`warning`/`success`/`info` family, no `accent` family. Views reach
for `.primary`, `.secondary`, `.tertiary`, `.quaternary`, `.bar`, `.orange` and
`Color.accentColor` directly, across essentially every file in `PLMailUI/`.

**There is no asset catalogue.** A search for `*.xcassets`, `*.colorset` or
`Assets*` across the repository returns nothing, while
`plMail.xcodeproj/project.pbxproj:349` sets
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor` and
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Both point at nothing. So every
`Color.accentColor` in the app — the sidebar's Inbox tint, the selected-row fill,
the snooze badge, the label checkmarks, the search chips, the bulk-picker
checkmarks — resolves to **system blue `#007AFF`**.

Android, by contrast, ships six schemes × 27 semantic slots, a spacing scale, a
three-step density ladder with per-surface overrides, motion tokens with a
reduced variant, and `PaletteContrastTest.kt`, which sweeps all six schemes
asserting ink ≥7:1, muted ink ≥4.5:1, and every avatar and label colour ≥4.5:1
on both surface and sunken. Whether Android *reads* those values from
`Appearance/get` was not verified and should not be assumed — its palette file is
a hardcoded table, and it predates parts of this API.

### The Appearance API, wire shape

`urn:plmail:params:jmap:appearance`, two methods, registered on `origin/main` as
`src/Jmap/Method/Settings/AppearanceGetMethod.php` and `AppearanceSetMethod.php`.

**Shape.** A singleton, modelled on RFC 8621's `VacationResponse`: one object,
id `"singleton"`. **No `accountId`** — appearance hangs off the `User`, not a
mail account, and an `accountId` sent anyway is *refused* with `invalidArguments`
rather than ignored. A user with three accounts has one theme.

**The 28 properties**, from `AppearanceMapper::PROPERTIES`:

```
theme  layout  logoStyle  accent  paneAlpha  paneBlur  radius  density  motion
backgroundKind  backgroundPreset  backgroundFile  backgroundSolid  scrimAlpha
inkColor  inkMuted  inkFaint  mainTint  mainAlpha
accountCorner  listAvatars  previewLines  unreadEmphasis  fontFamily  fontScale
sidebarDensity  listDensity  readingDensity
```

**Vocabularies**, published in the Session capability so a client never has to
discover them by being refused:

| Field | Values |
|---|---|
| `theme` | `system light paper dark nord dusk solar product-blue ink slate forest burgundy deep-violet postal bronze-ink petrol-copper midnight-gold navy-sky forest-lime …` — 19+ and growing |
| `layout` | `flat` `boxed` |
| `density`, and the three per-surface overrides | `comfortable` `cosy` `compact` |
| `unreadEmphasis` | `subtle` `standard` `strong` |
| `fontFamily` | `system` `grotesk` `serif` `monospace` |
| `logoStyle` | 30+ colourways, **read-only** |

Also published: `backgroundKinds`, `backgroundPresets`, `layoutDefaults` (the
knob preset each layout seeds, so a client's sliders sit where the web's do), and
`ranges` for `paneAlpha`, `paneBlur`, `radius`, `scrimAlpha`, `mainAlpha`,
`previewLines`, `fontScale`.

**The Session carries a compact hint.** `AppearanceMapper::COMPACT_PROPERTIES` is
`['theme', 'layout', 'accent', 'density']`, published in the Session's top-level
capabilities so a client can paint chrome on the first frame instead of flashing
the wrong palette. It is explicitly a *hint*: the Session's `state` is a hash of
the user's account ids and does **not** move when a theme changes, so a cached
Session holds a stale theme until `Appearance/get` corrects it. Treat it as a
splash-screen colour, not as truth.

**Six rules that will otherwise be learned the hard way:**

1. **Three properties are read-only**: `id`, `backgroundFile`, `logoStyle`.
   Changing one is refused; *echoing* one back unchanged is tolerated and
   dropped. So a naive read-modify-write of the whole object works — which is
   clearly the intent.
2. **Closed vocabularies are refused** with `invalidProperties`, and the error
   message names the whole vocabulary.
3. **Numeric ranges are clamped, not refused.** A `paneAlpha` of 1.4 is stored at
   the nearest end and **reported back in `updated`**. So the response to
   `Appearance/set` must be applied to local state; assuming the value you sent
   is the value that stuck will desync the UI from the server.
4. **Booleans are strict.** `"1"` and `"0"` are refused rather than coerced.
5. **The three per-surface densities take an explicit JSON `null`** to mean
   "follow the global density". That is a different instruction from omitting the
   key, and it is the only way back from an override. This needs the same
   double-optional encoding trick `MailboxSet.Patch` already uses for `parentID`
   (`JMAPKit/Methods/MailboxSet.swift:83-131`) — that pattern is already in the
   codebase and should be lifted into something reusable while doing A5's `color`.
6. **`state` is a hash, not a sequence.** `AppearanceMapper::state()` is
   `xxh128` of the object, truncated to 16 chars. It is not monotonic, there is
   no `Appearance/changes`, and there never will be. A client that sees the token
   move re-fetches the one object — a single call. `ifInState` **is** honoured on
   `set` and yields `stateMismatch`.

**`logoStyle` deserves its own note**, because it is subtle and the server
documents it at length. It is read-only, it is *derived* (from the theme, from
whether the user unlinked the mark from the theme, and only then from the stored
column), and it is the colourway the mark is **actually wearing** — deliberately
not the stored field, so a client drawing a mark agrees with the web. It is
excluded from the compact Session hint on purpose: the other four cost one frame
of the wrong palette if stale, whereas a launcher icon is committed to outside
the app where a correction is visible churn. If iOS ever ships alternate app
icons, drive them from `Appearance/get`, never from the Session. Treat an
unrecognised value as the default rather than an error; the set grows.

### Typography, spacing, motion

No scale for any of the three.

Fonts are system semantic styles used ad hoc: `.subheadline` for both sender and
subject, `.caption2` for date, badges and account tag, `.footnote` for snippets
and secondary buttons. The server has `fontFamily` (four values) and `fontScale`
(a clamped range) and iOS honours neither.

Spacing is literals at every call site — `spacing: 12`,
`.padding(.vertical, 10)`, `.padding(.horizontal, 12)` in `ThreadRowView.body`
alone. The server has a three-step `density` plus three per-surface overrides;
iOS has none.

Motion is `.snappy(duration: 0.2)` written out in roughly ten places
(`MailView.swift:172`, `MailboxSidebarView.swift:165`,
`Reader/MessageView.swift:196,331`,
`Reader/ThreadReaderView.swift:460,468,490,507,533`, `UndoToast.swift:76-77`,
`List/SenderAvatar.swift:40`) with a `0.15` and a `0.25` mixed in. The server has
a `motion` property. **`accessibilityReduceMotion` is never consulted anywhere in
the codebase.**

### What the iPad layout actually does today

`Packages/PLMail/Sources/PLMailUI/MailView.swift` (456 lines) is the entire
adaptive story, and structurally it is right:

- A three-column `NavigationSplitView`, `columnVisibility: $columns` defaulting
  to `.all` (`:22`, `:289`), `.balanced` style (`:368`).
- Column widths stated: sidebar `min 220 / ideal 260 / max 320` (`:323`), list
  `min 396 / ideal 440 / max 540` (`:352`), with a correct note that the
  *minimum* is what matters, because a squeezed column gets its minimum and a
  generous ideal alone changes nothing.
- The detail column is its own `NavigationStack` (`:357`), so the reader can push
  an attachment preview without disturbing the columns to its left.
- One `selectedThread` drives both idioms. On compact,
  `.navigationDestination(item: compactReader)` (`:338`) performs the push a
  collapsed split view would do automatically for a `List(selection:)` but does
  not do for button rows. The comment at `:326-337` explains why, and is right.
- Search placement is size-class aware for a stated reason: the field can only
  live in the sidebar, so on compact the results *replace* the sidebar
  (`sidebarContent`, `:238-247`), and on regular they fill the middle column
  (`listContent`, `:251-271`).

**The pane treatment is the best thing in the app.** `PanelStyle.mailPane`
(`Theme/PanelStyle.swift:115-158`) turns each column into an inset rounded
surface over a window-coloured gutter, hides the toolbar background so the
navigation bar belongs to the card rather than floating above it, and halves the
leading inset so facing margins do not double the gutter.
`Theme/SplitSeparatorHider.swift` reaches through to `UISplitViewController` to
hide the column separator — matched on geometry rather than class name, and
written to fail harmlessly if a future release stops producing such a view.
Android has no equivalent, and neither does stock SwiftUI.
`ThreadListView` correctly lays down `PanelStyle.surface` itself when compact,
where there is no pane behind it (`ThreadListView.swift:159`).

### Where it is a stretched phone today, per file

Everything that is not layout.

1. **No `⌘` menu bar.** `App/plMailApp.swift:16-24` declares a bare
   `WindowGroup` with no `.commands { }`. Holding ⌘ on an iPad shows only the
   system's own items. The shortcuts that exist are `.keyboardShortcut` on
   individual controls and are therefore invisible and context-dependent: `c` and
   ⌘N for compose (`MailView.swift:180-185`); in the reader `e`, ⌘⌫, `r`, `a`,
   `f`, `l`, ⌘F, `u`, `s` (`Reader/ThreadReaderView.swift:357-436`); ⌘↩ and
   Escape in the composer (`Compose/ComposeView.swift:72,81`). Nothing in the
   list, nothing in the sidebar, nothing global.
2. **The list cannot be driven from the keyboard at all.** No `j`/`k`, no arrow
   keys, no ⌘1…⌘9 for mailboxes, no Return-to-open, no Tab between columns.
   `ThreadListView` rows are `Button`s in a plain `List` with no `.focusable`,
   no `@FocusState`, no `focusedValue`, no `.onKeyPress`. On a Magic Keyboard the
   only way to change the selected conversation is to reach up and touch the
   screen.
3. **No pointer support.** No `.hoverEffect`, no `.onHover`, no
   `.contentShape(.hoverEffect, …)` anywhere. With a trackpad the cursor does not
   morph over rows, sidebar items, the compose button, or anything else.
4. **No drag and drop.** No `.draggable`, `.dropDestination`, `onDrag` or
   `onDrop`. Dragging a conversation onto a sidebar label is the single most
   obvious three-column-iPad gesture and it does nothing.
5. **Multi-window is unconfigured and untested.** One `WindowGroup`, no
   `handlesExternalEvents`, no scene-activation handling, no `NSUserActivity`.
   `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`
   (`project.pbxproj:349`) means the manifest is synthesised, so whatever the
   multi-scene default is, it is not a decision anyone made. Two windows would
   each build their own `MailActions`, `LabelActions` and `BlobCache`
   (`MailView.swift:58-85`).
6. **The compose FAB.** A 56×56 `.glassProminent` circle pinned bottom-trailing
   over the *whole split view* (`MailView.swift:151-186`, `:378-390`). On iPhone
   this is right and thumb-reachable. On a 13-inch iPad it is a floating circle
   in the corner of the **reader**, nowhere near the list it creates mail for and
   nowhere near the toolbar every other iPad mail app uses — and it is
   sufficiently in the way that `ThreadReaderView.swift:324` already insets the
   reader's trailing edge by 96pt to dodge it, and `isReadingOnPhone`
   (`MailView.swift:275-277`) already hides it in one case. This is the one piece
   of the layout that is a phone pattern stretched.
7. **Exactly one breakpoint.** `isSeparated = sizeClass != .compact`
   (`MailView.swift:191`) is the app's only adaptive test, and it drives the pane
   treatment, the separator hider, the reader inset, and the search placement. A
   Stage Manager window at 700pt gets the full three-column inset-pane treatment
   with a 220pt sidebar plus a 396pt minimum list column plus gutters, leaving
   the reader almost nothing. A Slide Over panel at 320pt gets the compact
   layout, which is correct, but has evidently never been looked at — the 56pt
   compose button with a 20pt trailing inset is a large fraction of that width.
8. **Reader text runs the full column width.** At 13-inch width the detail column
   is ~700pt and message text uses all of it. No measure cap.
9. **No Handoff, no Spotlight.** No `NSUserActivity`, no `CoreSpotlight`. App
   Intents exist (`App/Intents/MailIntents.swift` — compose, search, unread
   count, with a correct "open the app rather than act silently" rule) but they
   are not `IndexedEntity`s and donate nothing.
10. **No haptics.** No `.sensoryFeedback` anywhere, including on swipe-action
    commit, undo, and send.

### What is already right

- Five distinct `ContentUnavailableView` states in the list — syncing /
  unauthenticated / failed / never-reached / genuinely empty — each with the
  right action and copy (`ThreadListView.swift:697-757`). Android has two.
- `.contextMenu` on every list row, with the rule that every swipe action is also
  in the menu (`:135-151`): a gesture is never the only route to an action.
- User-configurable swipe edges including a "Nothing" option
  (`List/SwipeActions.swift`), and `ActionTint`'s contrast-tuned fills.
- `.refreshable` on the list, accounts, identities and diagnostics.
- Dynamic Type at accessibility sizes handled deliberately in three places:
  `ThreadRowView` moves the date to its own line and lets the sender wrap
  (`:151-170`) and gives the subject a second line (`:199`);
  `Reader/MessageView.swift:237`; `Reader/ThreadReaderView.swift:26` collapses
  the action bar.
- VoiceOver on rows: `.accessibilityElement(children: .combine)` with a composed
  description and two custom actions, Star and Select
  (`ThreadRowView.swift:116-124`).
- The separator inset derived from layout via
  `.alignmentGuide(.listRowSeparatorLeading)` (`:101`) rather than a hardcoded
  number, so it tracks the avatar automatically.
- `LocalizedStringResource.ui(_:)` (`Theme/Localization.swift`) working around
  SwiftUI resolving `LocalizedStringKey` against `Bundle.main` inside a package,
  plus the matching `CFBundleLocalizations` entry in `App/Info.plist`. Two real,
  silent, identical-looking bugs, correctly fixed.
- A three-way appearance preference applied at the **root**
  (`App/RootView.swift:38`) so the sign-in screen behind a sign-out does not flip
  appearance.

---

## B. iPad plan

Priority order. Each item is independently shippable, and each states what it
unblocks.

### P1 — Ground the palette and adopt Appearance (L)

Nothing below should be built while `Color.accentColor` means system blue.

**P1.1 — Add an asset catalogue. (S)**
`App/Assets.xcassets` with an `AccentColor` colourset and an `AppIcon`. Both
build settings already name them. This single change re-tints roughly forty call
sites at once. Seed the value from the server's own accent default rather than
inventing one; it is the fallback for the first frame before `Appearance/get`
lands, and it should not disagree with the web.

**P1.2 — `Appearance/get` in `JMAPKit`, and a real `ResolvedTheme`. (L)**
This is the item the placeholder was written for. Concretely:

- A `JMAPKit` `Appearance` type over the 28 properties, plus `AppearanceGet` and
  `AppearanceSet` methods. No `accountId` — the server refuses one, so the
  request builder must not add it out of habit.
- Read the Session's compact hint (`theme`, `layout`, `accent`, `density`) at
  connect time to paint the first frame, then issue `Appearance/get` for truth.
  Do not cache the Session's copy as authoritative; its `state` does not move
  when the theme does.
- Fill in `Theme/ThemeEnvironment.swift` with the semantic set — `surface`,
  `raised`, `sunken`, `hover`, `line`, the four-step `ink` ladder, the `accent`
  family, `field`/`fieldBorder`, and `danger`/`warning`/`success`/`info` each
  with a soft variant — resolved from `theme` × `layout` and then overridden by
  the knobs (`accent`, `inkColor`/`inkMuted`/`inkFaint`, `paneAlpha`, `paneBlur`,
  `radius`, `mainTint`/`mainAlpha`).
- Fold in what exists rather than replacing it. `PanelStyle.surface` becomes
  `theme.surface`; `PanelStyle.window` becomes the app background;
  `PanelStyle.hairline` becomes `line`; `ActionTint`'s five hand-tuned values
  become the action family's fills. **Keep the doc comments** — they are the
  record of why each value is what it is, and that reasoning survives the move.
- Honour `radius` on **panes only**. `PanelStyle` already makes this distinction
  correctly (panes 20, controls fixed) and it is the thing
  `CLIENT_DEVELOPMENT.md` calls deliberate and easy to get wrong. Do not let a
  `radius` of 2.0rem reach a button.
- `AppearanceSet` must apply the **response**, not the request, because numerics
  are clamped and reported back in `updated`. And the per-surface densities need
  the explicit-null encoding — lift `MailboxSet.Patch`'s double-optional pattern
  (`JMAPKit/Methods/MailboxSet.swift:83-131`) into something shared while doing
  A5's `color`.

Ship a subset of themes at first — `system`/`light`/`dark`/`paper` — and treat an
unrecognised `theme` value as `system`. The set grows server-side and a client
that errors on a new one is a client that breaks on a server upgrade. What
matters is the *shape*: once the resolver exists, adding `nord` is a data entry.

**P1.3 — Contrast test. (S)**
Port Android's `PaletteContrastTest` assertions into `PLMailUITests`: ink ≥7:1 on
surface/raised/sunken, inkSoft/inkMuted ≥4.5, inkFaint ≥3.0, accent ≥4.5 both
ways, every avatar ≥4.5 against its own ink, and all nine label colours ≥4.5 on
surface and sunken. This is what makes a palette maintainable by someone who did
not tune it, and it becomes essential the moment themes are server-driven and the
combinations multiply.

**P1.4 — Spacing, type and motion scales. (M)**
A spacing scale matching Android's steps so the two clients measure the same. A
`Motion` enum replacing the ten hand-written `.snappy(duration:)` calls, reading
the server's `motion` property and collapsing to zero under
`accessibilityReduceMotion` — which is how Reduce Motion gets honoured in one
place instead of ten. Map `fontScale` onto a `dynamicTypeSize` clamp and
`fontFamily` onto a font resolver; both are single points of application if done
now and a hundred call sites if done later.

**Deliberately not adopted:** `density`. See
[The Apple way](#the-apple-way), item 10.

### P2 — Make the iPad keyboard-drivable (L)

The largest experience gap. An iPad in a Magic Keyboard is the machine this app
should be best on, and today it is the machine it is worst on.

**P2.1 — Publish focused values. (M)**
The prerequisite, and the part that is real work. Menu commands live outside the
view tree and need to reach the current selection. `@FocusedValue` is the
mechanism: `ThreadListView` publishes the focused `ActionTarget` and a
`MailActions` handle; `ThreadReaderView` publishes its own; command builders read
them and disable themselves when nil. Get this right and the rest of P2 and much
of P3 is mechanical.

**P2.2 — A `⌘` menu bar. (M)**
`.commands { }` on the `WindowGroup`. Held ⌘ should show a complete, discoverable
set:

| Menu | Items |
|---|---|
| File | New Message ⌘N · New Window ⌘⇧N · Close Window ⌘W |
| Edit | Find in Message ⌘F *(exists — promote it)* · Search Mail ⌘⌥F |
| Message | Reply ⌘R · Reply All ⌘⇧R · Forward ⌘⇧F · Archive ⌘⇧A · Delete ⌘⌫ · Mark Read/Unread ⌘⇧U · Star ⌘⇧S · Snooze ⌘⇧Z · Label… ⌘⇧L |
| View | Toggle Sidebar ⌘⌃S · Next/Previous Conversation ⌘↓ / ⌘↑ · Mailboxes ⌘1…⌘9 |

The existing bare-letter Gmail bindings (`c`, `e`, `r`, `a`, `f`, `l`, `u`, `s`)
should **stay**. They are right for someone arriving from Gmail, and
`MailView.swift:174-185` already demonstrates the correct double-binding
pattern — a visible control takes the bare letter, a hidden background `Button`
takes the ⌘ form so it appears in the shortcut overlay. Generalise that trick
into a `ViewModifier` instead of repeating it nine times.

**P2.3 — List keyboard navigation. (M)**
`j`/`k` and ↑/↓ to move `selectedThread` through `rows`, Return to open, Escape
to clear, `x` to toggle bulk selection, Space to page. On iPad the reader is
already a column, so moving the selection *is* reading — this is what turns the
app into something usable without lifting a hand off the keyboard.

The obstacle is real and must be named for whoever picks this up: rows are
`Button`s rather than `List(selection:)`, for the documented reason at
`ThreadListView.swift:106-113` — the system's selected appearance is an
unrestylable blue fill that also recolours the row's text, which on a mail list
erases the unread and starred state the row's own colours carry. **Do not undo
that.** Add `.focusable()` to the row content with `@FocusState` tracking
`ThreadRef?`, drive selection from focus, and handle keys with `.onKeyPress` on
the `List` rather than per row.

**P2.4 — Focus ring and pointer hover. (S)**
Once rows are focusable they need a focus treatment distinct from *open*.
`ThreadRowView.swift:110-115` currently draws accent at 0.16 opacity for open and
0.10 for selected; focus should be a **stroke**, not a third fill opacity, or the
three states become indistinguishable. Add `.hoverEffect(.highlight)` to rows and
sidebar items, and `.hoverEffect(.lift)` to the compose button.

### P3 — Drag and drop between panes (M)

The gesture a three-column layout exists for, and the clearest single signal that
an iPad app was designed rather than ported.

- **Thread → sidebar label** applies the label. `.draggable` on the row producing
  a lightweight `Transferable` (`accountKey` + `threadID` — ids, not the entity),
  `.dropDestination` on `MailboxSidebarView`'s label rows calling the same
  `MailActions.setLabel` path `LabelPickerView` uses, so it is undoable through
  the existing toast for free.
- **Thread → Archive / Trash / Junk rows** as move actions, through the same
  `MailActions` verbs the swipe actions use.
- **Multi-select drag**: when `checked` is non-empty, dragging any checked row
  carries the whole set. `BulkLabelPickerView.checkedTargets` already computes
  it.
- **Attachment out of the reader** into Files or another app: `.draggable` on
  `AttachmentRow` with a `FileRepresentation` backed by `BlobCache`. Respect the
  deliberate no-eager-download rule — resolve the bytes on drop, not on drag
  start.
- **Files / Photos → composer** as an attachment drop. Note the server contract:
  `Email/set` treats `attachments` as a **whole value** on update, so a drop must
  send the complete list, re-listing kept parts by their `p-` blobIds. A blobId
  that will not resolve fails the entire patch.

Drop targets need a visible highlight — use P1's `accentSoft` rather than a
hand-mixed opacity.

### P4 — Adaptive behaviour below "regular" (M)

`isSeparated = sizeClass != .compact` is one boolean doing four jobs, and Stage
Manager produces every width continuously rather than the two the size class
reports.

- **Measure, don't classify.** Derive the layout from the actual container width
  rather than the size class: below ~500pt one pane; ~500–800pt two panes with
  the sidebar as an overlay; above ~800pt three panes. Today a 700pt Stage
  Manager window gets 220 + 396 + gutters before the reader gets anything.
- **`columnVisibility` should follow width** rather than staying pinned at `.all`
  (`MailView.swift:22`). At medium widths it should be `.doubleColumn`, with the
  sidebar reachable from a toolbar toggle (and ⌘⌃S from P2.2).
- **Separate the four jobs.** The pane treatment, the separator hider, the reader
  inset and the search placement should each read the width threshold they
  actually care about, not share one boolean. The search placement in particular
  is about *whether there is a second column to put results in*, which is a
  different question from *whether panes get gutters*.
- **Slide Over (320pt)** already takes the compact path, which is right. What it
  needs is a look: at that width the 56pt compose button plus a 20pt inset is a
  large fraction of the screen. Fall back to a toolbar button below ~400pt — the
  same change P5 makes at the top end, from the other direction.
- **Reader measure cap.** Cap the message text column around 680pt and centre it.
  One modifier, and it is the difference between reading a document and reading a
  wall. This is also where `previewLines` and `readingDensity` from P1.2 land.

### P5 — Compose button placement (S)

Move New Message into the **list column's** toolbar (`.topBarTrailing`, beside
the existing More menu) when the layout is separated, keeping the floating glass
button only on compact. Keep both ⌘N and `c` bound to it.

This removes the last stretched-phone element from the iPad layout, reclaims the
96pt trailing inset `ThreadReaderView.swift:324` currently reserves, and puts the
create action in the column it creates into. Small change, disproportionate
effect.

### P6 — Multi-window and scenes (M)

Two mailboxes side by side, or a composer in its own window, is what a large
screen is *for*.

- **Audit the singleton assumptions first.** `AppModel` is created once
  (`plMailApp.swift:6`); `MailView.init` builds `MailActions`, `LabelActions` and
  a `BlobCache` per instance (`MailView.swift:58-85`). Two scenes would get two
  `MailActions` and therefore two independent undo stacks — arguably fine, but it
  must be a decision rather than a discovery.
  `AppearancePreference.shared`, `IntentRouter.shared`,
  `SwipeActionPreference.shared` and `RecentSearches` are all `UserDefaults`-
  backed and safe. `BlobCache` is scoped to the server host and safe to share.
- **A `WindowGroup(for: ThreadRef.self)`** giving a conversation its own window,
  opened from the row context menu ("Open in New Window") and by ⌘-tap.
  `ThreadRef` is already `Hashable` and carries only ids, which is exactly the
  right payload for a scene.
- **A `WindowGroup(for: ComposeModel.Kind.self)`** so a long message is not
  trapped in a modal sheet on a 13-inch screen. This is also the single worst
  thing about composing on iPad today.
- **State restoration** via `SceneStorage` for `selectedFeed`. `selectedThread`
  should **not** be restored blindly — a thread can be deleted between launches,
  and the existing "This mailbox is no longer connected"
  `ContentUnavailableView` (`MailView.swift:110-114`) is the right precedent for
  how to fail.

### P7 — Spotlight and Handoff (M)

- **`CoreSpotlight`.** Index synced conversations as `CSSearchableItem`s —
  subject, participants, snippet, date — from `SyncStore` after each delta. The
  store already holds everything and the mapping is mechanical. Treat deletion as
  the correctness requirement, not a nicety: items must be removed on thread
  deletion and **on sign-out**, or a stale index leaks mail metadata into system
  search after the account is gone.
- **App Intents → `IndexedEntity`.** Promote `SearchMailIntent` so Spotlight can
  run a plMail search directly. The existing "open the app, do not act silently"
  rule (`MailIntents.swift:6-12`) must survive this.
- **Handoff.** An `NSUserActivity` for "reading this conversation" and one for
  "running this search", both `isEligibleForHandoff`. iPad → Mac is where this
  pays off, and it is two `userActivity(_:element:_:)` modifiers on
  `ThreadReaderView` and `SearchResultsView`.

### P8 — Blocked on an App Group (S each, do not start)

Both need the paid account `docs/WHATS-LEFT.md` already flags. Recorded so they
are not re-planned:

- The widget renders but cannot read the app's numbers.
- **Focus filters** (`SetFocusFilterIntent`) — "show only the Work label during
  Work Focus" — is a genuinely good fit for a label-based mail client, and cheap
  once the group exists.

### Mac Catalyst — do not do it

`App/Config/Shared.xcconfig` sets `SUPPORTED_PLATFORMS = iphoneos
iphonesimulator` and `TARGETED_DEVICE_FAMILY = 1,2`, with
`IPHONEOS_DEPLOYMENT_TARGET = 26.0`.

**Catalyst is not worth it.** It means a second set of layout rules, a second
menu implementation, real `NSToolbar` work, and `#if targetEnvironment(macCatalyst)`
spreading through `PLMailUI` — for an audience that already has the web UI on the
desktop.

**Do let "Designed for iPad" work on Apple silicon.** It costs nothing (an App
Store availability setting, not code), and everything in P2 — the ⌘ menu,
keyboard navigation, pointer hover — is precisely what makes an iPad app
tolerable in that mode. Use "does this feel right running on a Mac" as the
acceptance test for P2 rather than as separate work.

---

## B. iPhone & cross-cutting polish

### iPhone

The compact layout is in good shape and mostly needs leaving alone.

- The back stack is real: the collapsed split view plus
  `.navigationDestination(item: compactReader)` gives a genuine push, and the
  comment at `MailView.swift:326-337` explains why the manual destination is
  needed. Correct as written.
- One-handed reach: compose sits bottom-trailing and steps up 64pt only while the
  undo bar is showing (`:171-172`), rather than reserving that space permanently.
  Right trade.
- **Worth adding:** there is no way to move to the next conversation from inside
  the reader without going back. A chevron pair in the reader toolbar shares its
  plumbing with P2.3's next/previous and P2.1's focused values. **(S after P2)**
- **Worth checking:** returning from a search result on compact should restore
  the sidebar's scroll position — `sidebarContent` swaps the whole view
  (`:238-247`), so this may already be lost. **(S)**

### Dynamic Type

Handled well where it is handled — `ThreadRowView` restructures rather than
truncating harder (`:151-170`, `:199`), `MessageView:237` and
`ThreadReaderView:26` both collapse.

Not handled: `SearchTokensView` and `SearchFilterChipsView` are fixed `.caption`
in a horizontal `ScrollView` with hardcoded 6/8/4pt padding. At accessibility
sizes these become an unreadable strip. Give them a `ViewThatFits` that wraps at
large sizes. `BulkLabelPickerView`'s "3 of 40" caption beside a label name will
collide the same way. **(S)**

### VoiceOver

Rows, attachments, message actions and the undo toast are labelled, and the row's
custom actions are the right pattern. Gaps, **(S)** each:

- `SearchTokensView` renders bare `Text` capsules with no grouping, so VoiceOver
  reads a run of disconnected fragments. Combine per token, and label the
  container ("Filters, 3 items").
- `SearchFilterChipsView` sets `.isSelected` on the toggles but the date `Menu`
  has no `accessibilityValue` for the current preset.
- The sidebar's `.badge(unreadCount)` reads as a bare number after the name; an
  `accessibilityValue` of "12 unread" is clearer.
- No `accessibilityRotor` for unread messages in a long list — a natural fit and
  cheap.
- After A5, label colour must not become the *only* carrier of meaning: the chip
  needs its name in the accessibility label regardless of colour.

### Everything else

- **Reduce Motion is not consulted at all.** Fold it into P1.4's `Motion` scale;
  that fixes all ten sites at once. **(S, rides on P1.4)**
- **Dark mode** is correct and thought-through: `Color(light:dark:)` throughout, a
  stated reason for not warming the dark background, and the preference applied at
  the root. The one thing to re-check after P1.2 is that the **mail sheet** still
  follows its own per-message strategy — restyle when the message brings no
  colours, `hue-rotate(180deg)` inversion with images inverted back when it does,
  hands off entirely when it declares `prefers-color-scheme`. That logic lives in
  `Reader/MessageRenderStyle+CSS.swift` and **must not start reading the app
  palette**; a themed reading pane is how mail ends up black-on-black.
- **`ContentUnavailableView`** is used in eleven places and used well. Two gaps:
  the search empty state should name the sync window when the query has a date
  bound — `ParsedSearchQuery.hasDateBound` exists for exactly this
  (`SearchQuery.swift:41-43`) — and A10's contradiction case. **(S)**
- **`.searchable`** is used correctly, including the deliberate choice of plain
  buttons over `.searchCompletion` because half the suggestions are unfinished
  (`SearchSuggestionsView.swift:14-17`). On iPad, add `.searchScopes` for
  All / Inbox / Unread — an iPad-native affordance the phone layout does not
  need. **(S)**
- **Context menus** are on list rows and outbox rows. Add them to sidebar label
  rows (Rename, Delete, Hide, and after A5 a colour submenu) so `LabelManagerView`
  is not the only route, and to attachments (Save, Share, Quick Look). **(S)**
- **Haptics: entirely absent.** `.sensoryFeedback` on swipe-action commit
  (`.success`), undo (`.impact`), send (`.success`), and a refused label
  operation (`.error`). Cheap, and their absence is felt without being
  identified. **(S)**

---

## The Apple way

Android patterns that must **not** be ported, with what to do instead.

1. **`ModalBottomSheet` for "Label as"**, with a 320dp height cap and a pinned
   "New label" row. iOS already solves this with
   `.presentationDetents([.medium, .large])` (`LabelPickerView.swift:91`). Keep
   iOS's; port only the *semantics* (mixed → fully applied), which iOS already has
   and does better, with counts.

2. **`TriStateCheckbox`.** No iOS equivalent and none wanted.
   `BulkLabelPickerView`'s `checkmark.circle.fill` / `minus.circle.fill` /
   `circle` with `.contentTransition(.symbolEffect(.replace))` is the right idiom
   and is already built.

3. **A `DropdownMenu` overflow (⋮) inside a selection bar**, hiding Star, Spam,
   Label and Snooze behind `MoreVert`. iOS has no such convention. The bottom bar
   shows the primary actions directly and puts the remainder behind a labelled
   `Menu` — and on iPad they all fit, so nothing should hide at all.

4. **The FAB.** On iPhone iOS's floating glass button is defensible and carefully
   placed. On iPad it becomes a toolbar item — see P5. Do not add a FAB anywhere
   else, and specifically not to the sidebar for "new label".

5. **A Material `FilterChip` with a nested `IconButton`** for recent searches — a
   tap target inside a tap target. iOS recents belong in the
   `.searchSuggestions` list as rows with swipe-to-delete.
   `RecentSearches.forget(_:)` exists for exactly this
   (`RecentSearches.swift:52-59`) and is currently **unused**. Wire it up. **(S)**

6. **Search as a full-screen destination with a `TextField` in the top bar.**
   iOS's `.searchable` in the sidebar is correct, and the reasoning for why the
   field can only live there (`MailView.swift:42-49`) should be preserved. Where
   iOS should go *further* than Android is `UISearchToken`: real deletable tokens
   in the field for parsed operators, rather than a read-only capsule row beneath
   it. That is the natural evolution of `SearchTokensView`, it has no Android
   counterpart, and A1/A2's new operators make it more valuable.

7. **`AlertDialog` used as a form** — an alert containing a text field, a
   nine-swatch grid, a spinner and a destructive button. iOS alerts cannot host
   that and should not. `LabelNameSheet` (`LabelManagerView.swift:212+`) is
   already the right shape: `NavigationStack` + `Form` in a `.medium` detent,
   validation in the footer while typing, Cancel/Confirm in the toolbar. A5's
   colour grid and A6's parent picker go **into that form**, not into an alert.

8. **A navigation drawer as primary navigation, with an in-place "Edit" pinning
   mode.** iOS has `NavigationSplitView` and `EditButton()`. If pinning is wanted
   later it is `.onMove` in an edit-mode `List`, not a bespoke mode where tapping
   means something different.

9. **Two-direction `SwipeToDismissBox` → Archive/Trash.** iOS's
   `.swipeActions(edge:)` with user-configurable actions per edge and a "Nothing"
   option (`List/SwipeActions.swift`) is strictly better. Keep it.

10. **Density tokens as a user-facing setting.** Android exposes the server's
    three-step `density` as a picker. On iOS the analogue is Dynamic Type, which
    the user already set system-wide, and a second competing knob is worse than
    none. **Read** `density` from `Appearance/get` and let it seed spacing so the
    two clients agree; do **not** ship a density picker in iOS Settings. Likewise
    Android's `touchTarget = 48dp` — iOS's floor is 44pt, and
    `ThreadRowView.swift:139` already sizes the avatar's target to exactly that.

11. **Hardcoded 72dp snippet insets and divider indents.** iOS derives its
    separator inset from layout via `.alignmentGuide(.listRowSeparatorLeading)`
    (`ThreadRowView.swift:101`), which tracks the avatar automatically. Better;
    keep it.

12. **`Modifier.marks` drawing an account corner triangle in `drawBehind`.** The
    *idea* — an account marker costing no layout — is good, and iOS's coloured-dot
    account tag (`ThreadRowView.swift:355-366`) achieves the same restraint with a
    clearer rationale. Do not add a corner triangle. (Note `accountCorner` is a
    server Appearance property; reading it is fine, drawing Android's shape is
    not.)

**Worth taking from Android verbatim:** the `in:` alias table (A4); the nine
`LabelColor` tokens and their per-scheme contrast ramps (A5); path construction
with a cycle guard and middle-ellipsis truncation (A6); the chip width budget as
*numbers* — 96 per chip, 160 per cluster, 104 preview floor, 400 pane-width
threshold — and specifically the decision to key it on pane width rather than
size class (A8); and the contrast test (P1.3).

**Not worth taking from Android:** `in:archive` as `Not(InMailbox(inbox))`, which
is now wrong against `origin/main` (A2/A14).

---

## Do not regress

Correct, non-obvious, and plausibly "cleaned up" by someone who did not read the
comment above them.

**Search**

- `SearchQuery` reproduces `SearchQueryParser.php` including the parts that look
  like bugs: quotes kept inside tokens, split on **first** colon only, unknown
  operator falls through as literal text *including its colon*. All still true on
  `origin/main`. Do not "fix" any of them unilaterally.
  **One exception, and only one:** the unknown-*value* rule inverted server-side
  and iOS must follow it — see [A3](#a3--unknown-operator-values-now-become-free-text-not-nothing).
  That change requires editing the doc comment at `SearchQuery.swift:56-60`,
  which currently states the old rule as deliberate policy.
- `freeText` keeps quote characters because the string reaches Postgres's
  `websearch_to_tsquery`, where a quoted run is a phrase. Stripping them turns a
  phrase into a bag of words. As a consequence `-term` negation and `OR` **do**
  work — via Postgres, on the free-text remainder only, not via the parser. Do
  not add parser-level negation.
- The full-text config string is `'english'` on both the generated column and the
  query. A mismatch silently returns nothing, because the stemmed tokens never
  line up. Do not route around it.
- `is:read` is accepted but deliberately not offered in the suggestion list
  (`SearchOperator.swift:39-43`), because offering it beside `is:unread` invites
  tapping both.
- Chips write into the query text rather than filtering behind it
  (`SearchQueryEditor.swift:77-88`). This is the entire design of the feature.
- The 350ms search debounce (`MailView.swift:396-413`), and recents recorded on
  submit rather than per settled keystroke (`:314`) so the history does not fill
  with "inv", "invo", "invoi".
- `FeedID.search(_:)` trims and lower-cases so the same search reuses its rows
  (`SearchQueryCompiler.swift:99-106`), and `discardSearch` cleans up, so one
  materialised feed per query ever typed does not accumulate.
- `SnippetText`: split on `<mark>` **first**, unescape **second**. Reversing the
  order is an injection — a subject literally containing `<mark>` arrives as
  `&lt;mark&gt;` and would become a real tag. `&amp;` unescaped last, and only
  the six entities `htmlspecialchars` produces.
- `SearchQueryCompiler.canSearch` skipping an account it cannot serve, rather
  than searching it unfiltered. A4 changes the vocabulary; it must not change
  this rule. A11 adds reporting on top of it, not instead of it.
- Dates anchored at local midnight, with the timezone reasoning at
  `SearchQuery.swift:163-167`.

**Labels**

- Label CRUD is deliberately **not optimistic and not undoable**, with the reason
  written down (`LabelActions.swift:8-24`): a locally-invented id would be
  attached to messages, and undoing a delete cannot restore attachments the
  server no longer remembers.
- `LabelActions.send` treats an empty `created`/`updated`/`destroyed` bucket in a
  200 response as failure (`:156-157`, `:171-172`, `:227-231`). A 200 with
  nothing done is not success.
- `nameIsTaken` is case-insensitive, which is *stricter* than the server's exact
  match, deliberately (`:118-119`).
- Slash rejection in `complaint(about:)` mirrors
  `MailboxSetMethod::requireName`, and the wording points at the fix ("Use a
  parent label to nest it") rather than the violation. A6 makes that sentence
  actionable for the first time.
- The sidebar collapses labels across accounts by the user-scoped `labelID`
  (`MailboxSidebarView.swift:262-279`), never by name — the plMail `labelId`
  extension exists for exactly this. `LabelManagerView` deliberately does **not**
  collapse, because renaming and deleting act on a per-account binding
  (`LabelManagerView.swift:10-19`).
- Unsubscribed mailboxes hidden but reachable, because plMail creates Archive
  unsubscribed (`MailboxSidebarView.swift:24-27`). A4's `in:archive` interacts
  with this — an account with no Archive binding is skipped, by design.
- `LabelPickerView` excludes role mailboxes (`:204-207`): Inbox, Trash and Sent
  are reached by archiving, trashing and sending, and offering them as checkboxes
  would be two ways to do one thing that behave differently.

**Layout and theme**

- `PanelStyle`'s pane-radius vs control-radius distinction. P1.2 must preserve it
  when `radius` becomes server-driven.
- The halved leading inset in `mailPane` (`PanelStyle.swift:152`) — a gutter is
  the sum of two facing margins.
- The window colour painted **per column** rather than on the split view, because
  each column draws its own opaque fill over a container background (`:128-135`).
- `SplitSeparatorHider` matching on geometry rather than a private class name,
  and failing harmlessly. Do not replace with a hardcoded string.
- `.navigationBarTitleDisplayMode(.inline)` on the list, because a large title
  silently fails to render when the split view **restores** a column rather than
  pushing it — exactly the cold-launch path
  (`ThreadListView.swift:263-266`, `MailView.swift:257-260`).
- List rows are `Button`s, not `List(selection:)`, so a tap can mean "add to
  selection" and so the system's unrestylable blue fill does not erase the row's
  unread/starred colouring (`ThreadListView.swift:106-113`). **P2.3 must work
  around this, not undo it.**
- `.listRowBackground(Color.clear)` everywhere: hiding the *scroll* background is
  not enough, rows paint their own on top (`:137`).
- `ThreadListView` laying down `PanelStyle.surface` itself when compact, because
  there is no pane behind it (`:159`).
- `AvatarPalette`'s array order and count — a sender's colour is their FNV-1a
  hash modulo the count, so reordering or resizing renumbers everybody
  (`AvatarPalette.swift:33-35`). A5 demotes it to a fallback; it must not
  reorder it.
- FNV-1a rather than `hashValue`, because Swift seeds `Hashable` per process.
- "Mark all as read" asks the **server** for targets rather than using loaded
  rows, and reports what one write could not reach
  (`ThreadListView.swift:317-345`); `maxObjectsInSet` is 500.
- `LocalizedStringResource.ui(_:)` and the `CFBundleLocalizations` entry in
  `App/Info.plist`.
- App Intents open the app rather than acting silently
  (`App/Intents/MailIntents.swift:6-12`) — the recipient list is the one thing
  that cannot be taken back. **This rule must survive P7.**

## Not visually verified: 834 points

`MailLayout.usesSidebarRail` is covered by `MailLayoutTests.sidebarRail`, and
the 13-inch iPad (1032pt, triple) and the iPhone (compact) have both been driven
on a simulator against the real server. The **dual** band — an 11-inch iPad
upright, an iPad mini, Split View, a Stage Manager window between 500 and 1000
points — has only been reasoned about and unit-tested. Attaching an 11-inch
simulator needs a device-access grant that only the person at the keyboard can
give.

What to look at when one is attached, in order:

1. The sidebar is the 56pt rail, not the 224pt named column.
2. The list is 320 wide and the reader has the rest — over 400 points.
3. The rail's selected feed still tracks the list (tap Travel on the rail, the
   list follows).
4. The docked calendar at this width: rail + list + calendar leaves the list
   around 320, which is the narrowest a three-line row has been asked to be.
