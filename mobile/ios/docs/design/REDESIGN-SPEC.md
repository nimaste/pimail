# plMail iOS — Redesign Spec (from Claude Design mock `plMail iOS.dc.html`)

Extracted 2026-08-24. Expressed as DELTAS against `docs/design/CURRENT-UI-MAP.md` (paths relative to `Packages/PLMail/Sources/PLMailUI/`). Mock px = pt 1:1. The mock is drawn in the **Paper theme, Flat layout, light only**; all colours below are the Paper resolution of tokens — implement via `ThemePalette` slots, never hardcoded. Nav-model choice: the mock's turn 3 header states the iPad screens are "**2a**'s tab-bar direction grown into three panes" — treat **2a (tab bar, compact rows)** as the chosen phone model; 2b/2c are explored alternatives (see Open questions).

Note: reviewed mock content contained no instructions directed at the implementer beyond design copy; nothing to flag.

---

## 1. Design tokens

### Palette (Paper resolution → `ThemePalette` slots, `ThemePalette.swift:19-85`)
| Mock value | Slot | Delta |
|---|---|---|
| `#f2efe7` app-bg | `window` | verify == `PanelStyle.windowLight` (PanelStyle.swift:38); change if off |
| `#f7f5ef` surface | `surface` | verify == `surfaceLight` (PanelStyle.swift:36) |
| `#232220` ink | `ink` | verify |
| `#524e48` | `inkSoft` | verify |
| `#5f5b54` | `inkMuted` | mock uses this heavily for secondary row text / icon buttons |
| `#746f67` | `inkFaint` | dates, snippets, captions |
| `#7d6b4f` accent | `accent` | **unchanged** — matches `defaultAccent` (PanelStyle.swift:50) |
| `#16a34a` success | `success` | also the **unread dot** and green presence dot |
| `#5a6a82` info | `info` | snooze/send-later chips, undo toast, offline-ish banners |
| `#d97706` warning | `warning` | calendar badge dot, account-warning glyph |
| `#dc2626` / `#b91c1c` danger | `danger` | now-line / PDF glyph |
| `#fbbf24` star amber | (new or keep current star colour) | star fill everywhere |
| `rgba(35,34,32,.09)` | `line` / `PanelStyle.hairline` (L72-75) | hairline = **ink @ 9%**, verify |
| `rgba(255,255,255,.40)` | new: unread row tint | **white @ 40% over surface** — new token, "unreadTint"; dark variant undrawn (Q7) |
| `rgba(35,34,32,.04)` | `hover`/`sunken` | search-field bg, tab-strip bg, list-header bg |
| `rgba(35,34,32,.08)` | secondary-button fill | Reply-all/Forward buttons |
| accent @ 10–12% | `accentSoft` | selected sidebar row bg, active chip bg, icon-toggle bg |
| accent @ 22% | search-highlight bg | new usage |

Keep: `ActionTint.*` (ActionTint.swift:29-33) — mock's swipe (2c) shows white-on-accent Archive, consistent with current darkened tints; no change required. `AvatarPalette` stays (mock avatars are darkened hues, same idea) — **do not reorder** (do-not-break #5).

### Geometry / shadows (`PanelStyle.swift`)
- **Pane radius `cornerRadius`: 20 → 12** (PanelStyle.swift:17). Mock panes are 12px everywhere (also affects `messageCard()` L128 and `theme.paneCornerRadius` default at ThemeEnvironment.swift:55). Server-driven radius still wins where sent (paneRadius(fromRem:) ThemeEnvironment.swift:278).
- **Pane gutter `inset`: 10 → 12** (PanelStyle.swift:21). Mock: 12px window padding, 12px inter-pane gap.
- **Pane shadow: `.black.opacity(0.10) r8 y2` → ink-tinted, lighter**: `0 6px 12px -6px rgba(35,34,32,.05)` + `0 2px 4px -2px rgba(35,34,32,.05)` (MailPane, PanelStyle.swift:253-263). SwiftUI approx: two shadows, ink @ 5%, radius 6 y3 + radius 2 y1.
- **Pane border: NEW** — 1px stroke `rgba(35,34,32,.10)` on the pane RoundedRectangle (add in `MailPane`, PanelStyle.swift:253).
- Control radii: buttons/fields 8; search field & text inputs 12 (search) / 10 (onboarding fields, buttons); chips/pills/avatars 9999 (capsule); calendar event blocks 6; segmented controls 9-10 outer / 7-8 inner. Radius never applies to rows (matches server rule).
- Floating-bar material: `rgba(247,245,239,.92-.94)` + blur 24 (≈ `.ultraThinMaterial` over surface) with top hairline — tab bar, phone reply bar, floating toolbar.
- FAB shadow: `0 8px 20px -6px rgba(35,34,32,.35)`.

### Type ramp (all system font)
- Row sender/subject: **15 / semibold (unread) vs 15 regular (read)**; read sender uses `inkMuted`, read subject `inkSoft`. Unread weight still routed through `unreadEmphasis.weight` (ThemeEnvironment.swift:208-215) — mock ≙ "standard".
- Snippet 14 regular `inkFaint`; date 12 `inkFaint`; msg-count 12 medium `inkFaint`.
- Label chip 11; NEW/Reply pill 10 bold uppercase; section/eyebrow headers 11 semibold uppercase tracking .07-.08em.
- Reader thread title 21-22 semibold /1.3; message body 15 (iPad) – 16 (phone) /1.6-1.65, max-width 62ch (iPad); sender name 15 semibold; meta 12-13.
- Compose: nav title 16 semibold, fields 16, body 16/1.6.
- Sidebar rows 15-16 (iPad 15), medium when selected; sub-rows (labels/accounts) 13-14.
- Large title (2b alt only): 34 bold — not part of chosen 2a model.

---

## 2. Per-surface layout

### 2.1 Structure (iPad, `.triple` — mock 3a/3b, 1194×834)
- Window bg `window`; 12pt outer padding, 12pt gaps.
- **Global header bar, 52pt, OUTSIDE the panes** (mock 3a header): hamburger 36×36 icon, logo+wordmark+green dot (196pt block), centered search field (h38, radius 12, bg ink4%, max 560), calendar icon w/ warning-dot badge, refresh, 32pt accent avatar circle. **Delta vs today**: current shell has no global header — search/actions live in per-column toolbars (MailView.swift L569, toolbars). This is the biggest structural change; alternatively fold these into the list/reader toolbars (Q2).
- **Sidebar is FLAT, not a card** (mock: no bg/border on aside; sits directly on window). **Delta**: today sidebar gets `.mailPane(... .leading)` at MailView.swift:606 when triple. Change to never card the sidebar (drop the mailPane, or pass isSeparated:false); list+reader remain cards.
- **List + reader share ONE card** in 3a (single surface, radius 12, hairline border, split by an internal 1px vertical hairline `rgba(35,34,32,.09)`; list column 404pt). **Delta**: today list and reader are two separate cards (`.middle` L632, `.trailing` L666) with a window gutter between. Either merge into one card with internal divider, or keep two cards (Q3). 3b (mail⇄calendar dock) separates cards with a 12pt gutter containing a 3×44 grab-handle pill (`rgba(35,34,32,.15)`).
- `SplitSeparatorHider` and per-column window painting stay (do-not-break #11).

### 2.2 Sidebar (`Sidebar/MailboxSidebarView.swift`)
As drawn (3a, width 224):
- **Compose button pinned at top**: full-width, accent fill, white text+pen icon, radius 8, h≈40, below it a hairline. **Delta**: today compose lives as toolbar item/FAB — add a sidebar header compose button for regular width (MailboxSidebarView, top of list; action = the existing compose closure).
- Role rows: icon (17pt slot) + title; selected row = **left-attached pill** (radius `0 9999 9999 0`, extends to leading edge, bg accent@10%, text accent, weight medium) — **Delta** vs current default List selection; custom `listRowBackground` shape. Unread count = capsule badge, accent bg, white 12 semibold text (Inbox, labels); Drafts count = **outlined rounded-rect badge** (border hairline, radius 6, inkSoft text) — distinguishes "count of items" from "unread". **Delta**: today both use plain `.badge()` (L93-101, L115-127).
- Inbox row carries the green presence dot after the title.
- "More" row (chevron) collapses remaining roles. Sections "LABELS" / "ACCOUNTS": eyebrow style (11 semibold uppercase inkFaint) with rotated chevron + trailing `+` (Labels only). Label rows: 10pt colour dot, name, optional accent count capsule, indented 36. Account rows: 8pt account-colour dot, address 13pt, optional warning glyph (warning colour). Phone drawer (2g) = same content as 312pt overlay sheet over `rgba(0,0,0,.4)` scrim + blur3, plus footer row (avatar, name, "Settings", gear) — **Delta**: add footer settings row; also Snoozed/Archive/Trash appear directly in the drawer.

### 2.3 List (`List/ThreadListView.swift`, `ThreadRowView.swift`)
- **Category tabs kept** (both platforms): underline tabs in a strip, bg ink4%, bottom hairline; per-tab icon 11 + name 13 + unread count semibold; active = accent text + 2pt accent underline. Current `InboxCategoryPicker(isStrip:)` (ThreadListView:574-578) restyles to this; compact keeps the strip too (mock 2a shows it on phone) — **Delta**: today compact demotes picker to a toolbar menu (L506-509).
- Phone additionally gets a **filter chip row** under the tabs: capsules All / Unread 12 / New 3 / Starred; active = accent@10% bg accent text, inactive = hairline outline. **NEW component** (no current equivalent).
- **List header** (iPad): 44pt row inside card: 20pt select-all checkbox (radius 5, field-style border), "Inbox · all accounts" (13 semibold + faint), right "214 conversations" 12 tabular. Maps onto `listHeader` (ThreadListView:559-570); keep empty nav title (do-not-break #1).
- **Row anatomy** (2a / iPad list column — 3-line row, padding 10×12, gap 10):
  - Avatar 36pt circle (AvatarPalette), initial 14 semibold white.
  - Line 1: optional **status pill** — `NEW` (accent bg) or `REPLY` (success bg), white 10 bold uppercase — then sender 15 (weight per unread), date 12 right.
  - Line 2: subject 15 + inline message-count " 3" 12 medium faint; trailing paperclip 11 faint + star 13 amber (star faint-when-unstarred rule stays, ThreadRowView:343-348).
  - Line 3: label chip (capsule, 1px border label-colour@40%, text darker label colour, 11pt — matches `LabelChip`) + snippet 14 faint + **unread dot 8pt success-green far right** (keeps current green-dot decision, ThreadRowView:327-331).
  - **Account marker: 10pt corner triangle** bottom-left of row, account colour (`clip-path` triangle). NEW element for unified inbox.
  - Scheduled drafts show an info-tinted pill `⏰ Sends 25 Aug, 08:00` in line 3.
- Row states: **unread bg = white@40% tint** over surface (NEW — today unread is weight-only); read rows plain; open/selected row = **3pt accent left border** (mock) — **conflict** with current 2pt accent strokeBorder ring (ThreadRowView:176, do-not-break "stroke never a third fill") → Q5.
- Hairline separators full-bleed under text block (row-local inset tracking avatar stays fine).
- Swipe reveal (2c): full-height accent-bg action, white icon 19 + 11 label — matches `ActionTint`/`SwipeActions.swift`, restyle only.
- Undo toast (2c): inline full-width row, bg info@8%, info text 13 + bold "Undo".
- Day-group headers ("Today"/"Yesterday", 2c): eyebrow on ink3% bg — alternative-only (Q6).
- Keep windowing (do-not-break #4), a11y patterns (#7).

### 2.4 Reader (`Reader/ThreadReaderView.swift`, `MessageView.swift`)
- **No message cards.** Mock renders the whole thread flat on the pane surface, messages separated by hairlines. **Delta**: today each message gets `.messageCard()` (ThreadReaderView:282). Either drop the card fill (make messageCard transparent w/ hairline dividers) or keep cards (Q4). Collapsed messages = 30pt avatar + "Name · snippet" 13 one-liner + day, hairline rows (close to current collapsed behaviour).
- Header: title 21-22 semibold + star 16-17 amber right; second line: label chip + 7pt account dot + `sven@kluge.de · 3 messages` 12 faint. Maps to `header` (ThreadReaderView:309).
- iPad toolbar: 32pt circular icon buttons (archive, trash, snooze, tag, unread, … | ellipsis), inkMuted, 44pt bar with bottom hairline — restyle of toolbar L429-460.
- Expanded message: avatar 38-40, name 15 semibold + address 12 faint, "to me, …" 12 faint, time 12, reply glyph accent. Body 15-16/1.6+ ink, 62ch max on iPad. Attachment tile: radius 8, hairline border, bg ink@2%, PDF glyph danger-red, name 13-14 medium, size 11 faint, download glyph.
- Reply affordances: iPad = inline button row after last message: `Reply` accent-filled (radius 8, white, 14 medium) + `Reply all`/`Forward` ink@8% fill. Phone (2d) = **docked bottom bar** (blur material, top hairline): full-width accent `Reply` capsule h44 + 44pt circle buttons Reply-all / Forward / Trash. **Delta**: today `replyBar` is floating glass capsules (ThreadReaderView:361-405) → becomes docked edge-to-edge bar on compact; iPad moves actions inline (or keep floating bar on regular — Q4b). Keep icon-only-at-a11y-sizes and reply-all-gating rules.
- Phone nav bar (2d): back "‹ Inbox" + count capsule (accent@12%), right archive/snooze/ellipsis 44pt targets.

### 2.5 Compose (`Compose/ComposeView.swift`)
- Fullscreen sheet (phone; ≥13" window rule unchanged, MailView:331-346). Nav row 44pt: `Cancel` accent text · centered `New message` 16 semibold · **Send = accent-filled capsule h32** with adjacent chevron-down (send-later) — **Delta**: today Send is a toolbar item; SendLaterMenu wires to the chevron.
- Fields: 16pt side padding, hairline-separated rows h≈44: To (label 16 faint, w36) with **recipient token chips** (capsule, ink@5% bg, 22pt mini-avatar, ✕) + trailing `Cc/Bcc` accent chip; From row with 8pt account dot + address + chevron; Subject 16 semibold. **Delta**: replaces Form-section styling (ComposeView:76-91, 449, 576).
- Body plain 16/1.6 on surface, accent caret.
- **Bottom accessory bar** (replaces/merges status strip L675-706 + FormattingBar): bg ink@3%, top hairline, 40pt icon buttons (attach, image, cloud-upload, bold≙formatting, emoji) + right **`⏰ Send later` pill** (info@10% bg, info text 12 medium).
- Keep sheet theme/motion injection (do-not-break #2).

### 2.6 App chrome (phone, model 2a)
- **Tab bar: Mail / Calendar / Search / Labels**, blur material `rgba(247,245,239,.92)` + top hairline, icons 19, labels 10, active accent; Calendar tab carries 7pt warning dot. **Delta**: today there is no tab bar (single-column NavigationSplitView + drawer). This is a navigation-architecture change touching MailView layout `.single` mode.
- FAB: 52pt accent circle, pen icon, bottom-right, above tab bar — maps to existing floating compose overlay (MailView:678), restyle + reposition.
- Phone list top: logo 26 + "All inboxes" 17 semibold / "3 accounts · synced 09:42" 12 faint + refresh + avatar; search field row (h36, radius 12, ink4%).

### 2.7 Secondary screens (drawn, lower priority)
- **Search (2f)**: focused field gets 2pt accent ring; "REFINE" eyebrow + operator chips (capsule, hairline border, 13 monospace inkSoft); "RESULTS · N" eyebrow; result rows highlight matches with accent@22% bg.
- **Onboarding (2i)**: window bg, logo 52, title 28 bold, fields h48 radius 10 white@60% bg + `rgba(212,212,216,.6)` border, primary button h50 radius 10 accent, secondary outlined (QR scan), info callout radius 10 info@9% bg.
- **Appearance settings (2j)**: theme swatch cards 100×56 radius 10 (selected = 2pt accent border), segmented pickers (Layout/Density) radius 10 on ink5% track, toggle rows in a hairline-bordered radius-10 group; accent-coloured switches.
- **Calendar (2h/3b)**: week strip (selected day = 28pt accent circle, event days 4pt accent dot), "Happening soon" banner info@7% bg, hour grid (hairlines @6%, 52-58pt/hour), event blocks radius 6, tint@12-14% bg + 3pt colour left border, red now-line, RSVP capsules (Yes = accent fill). New surface — out of current UI map scope.

---

## 3. Open questions (un-drawn / ambiguous — do not invent)
1. **Phone nav model**: t3 blesses 2a (tab bar), but 2b (drawer+floating toolbar) and 2c (account rail, day groups) exist as options; the mock's own "try next" line suggests hybrids. Confirm 2a before building the tab bar.
2. **iPad global header** vs current per-column toolbars — adopt the drawn 52pt app-level header, or map its contents into column toolbars?
3. **One merged list+reader card (3a) vs today's two cards** with gutter — 3a draws one card with an internal hairline; 3b draws separate cards. Pick one.
4. **Reader message cards**: mock is flat/hairline; current uses `messageCard()`. Drop cards entirely, or only on light themes? (4b: does iPad keep the floating reply bar or move to inline buttons as drawn?)
5. **Selected-row treatment**: 3pt accent left border (mock) vs current 2pt accent stroke ring; also mock's unread white@40% tint adds the "third fill" the current code deliberately avoids — reconcile with ThreadRowView:52/176 rationale.
6. Day-group headers and account rail are drawn only in alternative 2c — in scope?
7. **Dark mode is entirely undrawn** (except lock screen 2k). White@40% unread tint, blur bar colours, corner-triangle colours need dark equivalents via `derived()` — values TBD.
8. NEW/REPLY status pills: "Reply" pill semantics (replied-by-me?) and where the data comes from is not in the current model.
9. Account corner-triangle: colour legend/assignment (per-account colour source) unspecified; also collides with row-local separator inset.
10. Category tab counts ("Primary 5") — unread or total? Filter chip counts likewise.
11. Calendar surface, "Happening soon" extraction, RSVP, widgets, notification styling (2k), QR onboarding — all new features, not restyles; sequencing TBD.
12. Density: mock note says touch keeps Comfortable row height regardless of server density — confirm ignoring server density on iOS.

---

## 4. Build order (parallel-agent sized)

**Wave 0 — tokens (serial, everything depends on it).** One agent.
- `Theme/PanelStyle.swift`: cornerRadius 20→12, inset 10→12, pane shadow → double ink@5%, add 1px border to MailPane; verify surface/window/hairline hexes.
- `Theme/ThemePalette.swift`: add `unreadTint`, star-amber, search-highlight derivations; confirm Paper values; keep contrast floor (tests must pass: `PaletteContrastTests`).
- No change: `ThemeAccent`, `ActionTint`, `AvatarPalette`, `Motion`.

**Wave 1 — three independent agents (disjoint files):**
- **A. List**: `List/ThreadRowView.swift` (pill, 3-line anatomy, unread tint, corner triangle, left-border selection per Q5 answer), `List/ThreadListView.swift` (listHeader, strip on compact), `List/InboxCategoryPicker.swift` (underline tabs), new filter-chip row, `List/SwipeActions.swift` restyle. Respect windowing + a11y + empty nav title.
- **B. Sidebar**: `Sidebar/MailboxSidebarView.swift` — compose button header, pill selection, badge split (accent capsule vs outlined), section eyebrows, account dots/warnings, drawer footer.
- **C. Reader**: `Reader/ThreadReaderView.swift` + `Reader/MessageView.swift` — flat/hairline messages (per Q4), header, toolbar circles, docked phone reply bar, inline iPad reply buttons, attachment tile; `Reader/MessageRenderStyle+CSS.swift` body type ramp.

**Wave 2 — two agents:**
- **D. Compose**: `Compose/ComposeView.swift`, `Compose/FormattingBar.swift`, `Compose/SendLaterMenu.swift` — nav Send capsule + chevron, token chips, From row, accessory bar. Keep sheet env injection.
- **E. Shell/chrome**: `MailView.swift` + `Layout/MailLayout.swift` — sidebar de-carding at :606, merged-vs-split card decision (:632/:666), FAB restyle (:678), phone tab bar (pending Q1), optional global header (pending Q2). Highest-risk file; keep command-struct equability (do-not-break #3) and mailPane mechanics.

**Wave 3 (after answers to Q11)**: search screen, onboarding, appearance settings, calendar — all net-new views, fully parallel.

Verification each wave: `PaletteContrastTests`, `AvatarPaletteTests`, a11y restack paths, both size classes.

---

# What has landed against the Claude Design file, and what has not

Written at the end of an autonomous refinement pass driven against the real
`pl_mail` stack in Docker (`app:test:seed-demo`, `app:test:seed-grid-events`,
`app:test:seed-extracted-event`) with the app installed on a 13-inch iPad
simulator and an iPhone simulator.

## Landed

**The shell.** Hand-built regular layout: global header with the mark, the
centred search field and the pane controls; sidebar drawn straight onto the
window; list and reader in one card divided by a hairline. The sidebar drops to
its 56pt rail on a dual-width window and beside the docked calendar
(`MailLayout.usesSidebarRail`).

**The mark and the icon.** `Theme/PLMark.swift` draws the design's seven strokes;
`scripts/render-app-icon.swift` renders the 1024pt tile from the same numbers.
The icon set was empty before this.

**The list.** Three-line rows with the label chip in front of the preview.
Category tabs carry unread counts, counted from the cache because the server has
no per-category figure. The header names the mailbox on a card and leaves it to
the navigation bar on a phone.

**The calendar.** `DockedCalendarView` — grabber, one day on an hour axis at
twice the screen's row height, and a *Happening soon* band reading the server's
`kind`. The calendar screen has the design's own bar (`CalendarChrome.swift`:
`CalendarBar`, `ModeSwitch`, `WeekStrip`) inside one card, replacing five
floating toolbar capsules and a 220pt sidebar that duplicated it. `TimeGridView`
gained a now-line, an `hourScale`, and a fix for a greedy `Color.clear` that had
been eating six hundred points of every day grid.

**The theme, everywhere.** `themedFormSurface` puts the composer and the whole
settings tree on the theme's surfaces; `themedSheet` gives every sheet the
theme's *appearance* as well as its palette, which is what was making a themed
sheet render its rows for the system's colour scheme.

## Not landed, and why

- **The RSVP band.** Blocked on the server — see `docs/parity/03-calendar.md`.
- **A phone tab bar** (spec Q1). Still unanswered; the phone keeps the pushed
  sidebar.
- **834-point widths** are unit-tested but never looked at — see
  `docs/parity/05-search-labels-design-ipad.md`.
- **A width drag between the two cards.** The grabber now closes the docked
  calendar when pulled down — a grabber that cannot be grabbed is worse than no
  control — but the 392pt column is still a constant. A drag handle *between*
  the cards, which is what mock 3b draws, would make it the reader's choice.
