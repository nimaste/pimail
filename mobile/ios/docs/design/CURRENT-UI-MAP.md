# plMail iOS — Current UI Map (redesign hand-off)

All paths relative to `Packages/PLMail/Sources/PLMailUI/` unless noted. Line numbers as of 2026-08-24.

## 1. Token layer — `Theme/`

### `PanelStyle.swift`
- `cornerRadius = 20` (L17) — pane + message-card radius. Deliberately the "pane" radius, not the control radius.
- `inset = 10` (L21) — gap between panes and pane-to-window-edge.
- Surfaces: `surfaceLight/Dark` (L36-37), `windowLight/Dark` (L38-39) — warm cream paper, not systemGroupedBackground (rationale L25-33).
- `defaultAccent #7d6b4f` (L50), `defaultAccentDark #c2a67e` (L62) — server's `Appearance::DEFAULT_ACCENT`; must match `App/Assets.xcassets/AccentColor`.
- `hairline` (L72-75) — row separator, both ends stated.
- `Color(light:dark:)` helper (L84-93).
- `messageCard()` (L128-130) → `MessageCard` modifier (L159-174): clips + fills theme `surface` at `PanelStyle.cornerRadius` — **deliberately NOT** `theme.paneCornerRadius` (rationale L149-152: server radius reaches panes only).
- `mailPane(isSeparated:column:)` (L142-144) → `MailPane` modifier (L210-276): the three-column card treatment. Key mechanics:
  - Content padded by `PaneColumn` insets (L229-230).
  - `.toolbarBackgroundVisibility(.hidden, for: .navigationBar)` (L235) — nav bar is part of the pane.
  - Background ZStack: `palette.window` painted per-column edge-to-edge (L246, because a background on the split view itself never shows), then a `RoundedRectangle` filled `palette.surface` with `shadow(.black.opacity(0.10), radius: 8, y: 2)` (L253-263), padded vertically by `inset`, then `.ignoresSafeArea()` (L270) so the card reaches behind the bar.
  - Uses `theme.paneCornerRadius` (L254) — the one place the server's radius lands.
- `PaneColumn` (L195-208): `.leading/.middle/.trailing`; full `inset` against window edge, `inset/2` against another pane (facing margins sum to full gap).
- Readers of PanelStyle: MailView (panes), ThreadReaderView/MessageView via `messageCard()`, ThreadListView, previews.

### `Swatch.swift`
- `Swatch` (L15+): plain RGB triple with `relativeLuminance`/contrast math — exists so `PaletteContrastTests` can measure every colour. `hex:` init, `.color`.

### `ThemePalette.swift` — the slot set
- `ThemePalette` struct (L15). Slots (L19-85): `isDark`, surfaces `surface / window / raised / sunken / hover / line`, ink ladder `ink / inkSoft / inkMuted / inkFaint`, accent `accent / accentInk / accentSoft`, fields `field / fieldBorder`, status `danger / warning / success / info` — plus derived helpers `surfaces` (L89) and `worstSurface(for:)` (L94).
- **Derived, not tabulated** (L120 `derived(...)`): each theme states only surface + ink + accent (the server's `Theme::swatch()` trio); everything else computed under a 4.5:1 contrast floor. Adding a theme = two-line data entry.
- Five shipped palettes (L226-278): `.light` L226, `.dark` L243, `.nord` L254, `.dusk` L261, `.solar` L268; `allShipped` L278 (swept by `PaletteContrastTests`).

### `ThemeEnvironment.swift`
- `ResolvedTheme` (L30): `choice`, `themeWireValue`, per-user `accent` override (L51), `paneCornerRadius` (L55, default `PanelStyle.cornerRadius`), `paneOpacity` (L59), `motion` (L63), `previewLines` (L67), `showsAvatars` (L70), `unreadEmphasis` (L73). `palette(for: ColorScheme)` (L85). `.placeholder` (L35) — **unpopulated environment must look exactly like the shipped default**; every view outside the injected tree relies on this.
- `ThemeChoice` (L116): system/light/dark/nord/dusk/solar; wire parsing `from(wire:)` L143 (unknown values fall back — don't turn into a strict enum); `paperWireValue` L135; forced `colorScheme` per theme L152-157.
- `MotionLevel` (L173), `UnreadEmphasis` (L187, weight mapping L208-215: subtle=.medium, standard=.semibold, strong=.bold — read by ThreadRowView).
- Wire resolution + `paneRadius(fromRem:)` L278. Environment entries: `\.theme` (L286), `\.appearanceSettings` (L302).

### `ThemeAccent.swift`
- `ThemeAccent: ShapeStyle` (L22) + `.themeAccent` (L34) — replaces `Color.accentColor` everywhere; resolves theme × colorScheme at draw time so call sites can't forget one input. `ResolvedTheme.accentColor(in:)` (L47) for the few `Color`-typed sites (`.tint`, ternaries).

### `ActionTint.swift`
- Swipe-action colours (L29-33): `archive`, `readState`, `star`, `spam`, `destructive` — avatar hues darkened until white content clears 4.5:1; `destructive` deliberately keeps saturation (L17-20). `all` (L43) swept by contrast tests. Read by `List/SwipeActions.swift`.

### `AvatarPalette.swift`
- 12 named swatches (L39-58): terracotta, clay, mustard, sage, eucalyptus, dusty blue, periwinkle, heather, mauve, dusty rose, stone, taupe. `color(for seed:)` L61, `index(for:)` L76 (deterministic hash), `initials(name:address:)` L96. Read by `List/SenderAvatar.swift`, sidebar, reader headers.

### `Motion.swift`
- `Motion.standard/fast/slow` (L23-35): 0.2 / 0.15 / 0.25 snappy; reconciles server `MotionLevel` with Reduce Motion (Reduce Motion always wins, L18-20; nil = no animation, L37-40).
- Environment entries `\.standardAnimation / \.fastAnimation / \.slowAnimation` (L59-77); `resolvedMotion(_:reduced:)` (L95) sets all three — applied at app root **and** by MailView (L885) and re-injected into every sheet. Views never read `accessibilityReduceMotion` directly.

### `Localization.swift`
- `LocalizedStringResource.ui(_:)` (L18): resolves against `Bundle.module`, not `Bundle.main`. Every user-visible string in the package goes `Text(.ui("..."))`.

### `SplitSeparatorHider.swift`
- `SplitSeparatorHider: UIViewRepresentable` (L28): hunts the `UISplitViewController` and hides its 1px column hairlines (L126) — the vertical rule the pane layout exists to avoid.

## 2. Three-column shell — `MailView.swift` (1262 lines) + `Layout/MailLayout.swift`

- `MailLayout.resolve(width:isCompactSizeClass:)` (Layout/MailLayout.swift L77-90): compact size class ⇒ `.single`; width `< 500` (`dualThreshold` L38) ⇒ `.single`; `< 1000` (`tripleThreshold` L47) ⇒ `.dual`; else `.triple`. Unmeasured width (0) ⇒ `.triple` provisionally (L80). Derived flags: `isSeparated` (L97, = mode != .single — gates every `.mailPane`), `hidesColumnSeparator` (L106), `placesSearchResultsInSidebar` (L114), `usesFloatingCompose` (L129, single mode only), `preferredSplitBehavior` (L139-142: single=.automatic, dual=.doubleColumn, **triple=.all**).
- MailView layout resolution: `layout` computed var L397-399 from measured `containerWidth` (L61).
- Pane assignment:
  - Sidebar: `.mailPane(isSeparated: layout.mode == .triple, column: .leading)` **L606** — card **only** when the sidebar is a resident column; in `.dual` the system floats it as an overlay and carding it there looks wrong (comment L600-603). This is the overlay-vs-resident split.
  - List: `.mailPane(isSeparated: layout.isSeparated, column: .middle)` **L632**.
  - Reader: `.mailPane(isSeparated: layout.isSeparated, column: .trailing)` **L666**.
- Root nav title `"plMail"` L569 (sidebar column). Compact reader pushes via `navigationDestination(item: compactReader)` L620 (binding is `.constant(nil)` at regular width, L530-531).
- Floating compose button overlay `.overlay(alignment: .bottomTrailing)` L678 (single mode).
- Compose: sheet-vs-window decision L331-346 (window on ~13" iPad, P6); **compose sheet L843-866**: `.sheet(item: $composing) { ComposeView(...) }` with explicit `.environment(\.theme, theme)` L859 + `.resolvedMotion` L860. Settings sheet L868-876 does the same (L875-876). Shell-wide `.resolvedMotion` L885.
- Menu commands: `.focusedSceneValue(\.mailShellCommands, shellCommands)` L787; `MailShellCommands` L974, `MailMessageCommands` L1043; `FocusedValues` entries L1121; `MailCommands: Commands` L1140+ (menu bar table — titles must use `.ui`).

## 3. List — `List/ThreadListView.swift` (1668) + `ThreadRowView.swift` (569)

### ThreadListView
- Windowing: `windowSize = 150` (L58), `visibleCount` state L54, grow L69, rows built from `entries.prefix(visibleCount)` L1215. Never hand ForEach the full array (60k-message mailboxes).
- Top inset stack (order matters, L475-477): `listHeader` → `categoryStrip` → `offlineBanner`, all `safeAreaInset(edge: .top, spacing: 0)`.
- **`navigationTitle(.ui(""))` L488 — deliberately empty.** A bar with text paints an opaque band across the top of the card; the title is drawn *inside* the card by `listHeader` (L559-570: `.font(.headline)`, leading, 16pt horizontal padding; shows "N selected" while selecting). Same trick in the reader (ThreadReaderView L179). Do not "fix" by restoring a bar title.
- `categoryStrip` L574-578: `InboxCategoryPicker(isStrip: true)` only when `layout.isSeparated`; compact instead gets the picker as a toolbar menu L506-509 (`InboxCategoryPicker.menu`). Picker itself: `List/InboxCategoryPicker.swift`.
- `offlineBanner` L1384-1443: two distinct sentences — device offline vs server unreachable (rationale L1377-1381); queued-changes count L1411-1412, Retry button only when retryable L1422-1426; symbol logic L1476.
- `prefetchBar` L586-613: bottom `safeAreaInset` (L371, below `bulkBar` L370); determinate `ProgressView(value:)` width 90 once a figure exists, `.mini` spinner before.
- Degraded-search section L342. Swipe actions: `List/SwipeActions.swift` (reads `ActionTint`).

### ThreadRowView
- Anatomy (header comment L11-21): three columns — avatar | text block | trailing badge column. Row assembly ~L137-158; row-local separator inset tracks the avatar (L153-157).
- Avatar: `avatar` L192 (uses `SenderAvatar` / `AvatarPalette`); tap = bulk-select toggle (L57); hidden hole avoided when `showsAvatars` off (L137-140).
- Unread: weight from `theme.unreadEmphasis.weight(isUnread:)` L268, L294; unread dot is a green `Circle` in trailing column (L327-331 — green, not tint, so it's legible beside the amber star).
- Star: always drawn faintly when unstarred (L343-348) so it can be discovered; fixed *minimum* trailing width so starred and unstarred rows are equal width (L308).
- Focus/open stroke: `strokeBorder(ThemeAccent(), lineWidth: 2)` L176 — **a stroke, never a third fill opacity** (L52: selected fill = accent 0.16).
- Accessibility: `.accessibilityElement(children: .combine)` L180, label L181, `.isButton` L182, custom actions Star/Unstar L183 and Select/Deselect L186; decorative pieces `accessibilityHidden` (L205, L337, L360). Accessibility sizes restack columns (L93-97, L222).
- Label chips: `Labels/LabelChip.swift` (tint via `LabelTint.color(for:seed:)` L117).

## 4. Reader — `Reader/ThreadReaderView.swift` (870) + `MessageView.swift` (439)

- Structure: `ScrollViewReader` L125 → LazyVStack of message cards; thread `header` L309; each message `row(for:)` L259 gets `.messageCard()` **L282**.
- `.scrollContentBackground(.hidden)` L170 (card colour vs scroll background), `navigationTitle(.ui(""))` **L179** (same empty-title trick), `.toolbar` L181/429, top `safeAreaInset` L182 (find bar), bottom `safeAreaInset { replyBar }` L193.
- `replyBar` L361-405: floating glass (not a bar) with Reply / Reply-all capsules; icon-only at accessibility sizes (L28); Reply-all only when it reaches someone new (L206).
- Toolbar L429-460: archive/delete/etc.; Reply/Reply-all/Forward duplicated into a Section of the More menu L454-457; every action is a shared function called by both toolbar and menu (L527).
- `MessageView`: `header` L96 (avatar, sender, date, collapsed-row behaviour), expanded-only `Menu` L168, `showsDetails` toggle L228-238 → `MessageDetailsView`, body L300-325 via `MessageBodyView` (HTML: `MessageRenderStyle+CSS.swift` — CSS for the web view, re-skin target), attachments: `AttachmentGridView/AttachmentRow`.

## 5. Compose — `Compose/ComposeView.swift` (823)

- Presented by MailView `.sheet(item: $composing)` L843 (or its own window ≥13", MailView L331-346); **theme + motion injected explicitly at MailView L859-860** — see do-not-break list.
- `Form` L76-91: recipients section L449, subject `TextField` L576-579, body `RichTextEditor(text:selection:)` L583-596 with `FormattingBar(text:selection:)` L596 (bar itself: `Compose/FormattingBar.swift`), `quotedSection` L608, `attachmentsSection` L633.
- Bottom status strip L675-706 (`.background(.bar)` L694/L706/L751). Send-later sheet L168 (`SendLaterMenu.swift`). Toolbar L91-115.

## 6. Sidebar — `Sidebar/MailboxSidebarView.swift` (601)

- Sections in order: unified role mailboxes L93-101 (`Label` + `.badge(unreadCount(for:))`), `calendarRow` L108 → L226-241 (own `Section`, calendar SF symbol tinted `.themeAccent`, `listRowBackground(Color.clear)`; shown only when `openCalendar != nil && calendar availability`), outbox L115-127 (`.badge(outbox.pendingCount)`), `Section(.ui("Labels"))` L135-183: rows tinted `LabelTint.color(for: label.color, seed:)` L164-165, hierarchy from `LabelHierarchy(sync.mailboxes)` L90 (built once), spoken path a11y label L170, tag `FeedID.unifiedLabel` L171, Edit/Create label row L179-182. Per-account collapsed groups `accountGroup` L253+.
- Accent as `Color`: `theme.accentColor(in: colorScheme)` L83.

## 7. DO NOT BREAK

1. **Empty navigation titles.** `ThreadListView.swift:488` and `ThreadReaderView.swift:179` set `navigationTitle(.ui(""))` on purpose: a bar with text paints an opaque band over the pane card (MailPane hides the bar background at `PanelStyle.swift:235`). Titles live *inside* the card (`listHeader` ThreadListView:559). Restoring a bar title breaks the card illusion.
2. **Sheet theme injection.** Sheets do not inherit environment applied later in the chain. Compose (MailView:859-860) and Settings (MailView:875-876) each re-apply `.environment(\.theme, theme)` + `.resolvedMotion(...)`. Any new sheet must do the same or it renders in the placeholder theme.
3. **`MailShellCommands`/`MailMessageCommands` equability** (MailView:974-990, :1043). `==` compares only what the menu draws — never the closures. Closures never compare equal ⇒ `focusedSceneValue` republishes every body evaluation ⇒ iPadOS rebuilds the main menu per frame ⇒ main thread saturates, touches stop, spinners never resolve (measured on device; it froze the reader). Keep menu command structs Equatable on state.
4. **`visibleCount` window** (ThreadListView:54-69, 1215; `windowSize = 150`). Rows come from `entries.prefix(visibleCount)`. Never hand ForEach the unbounded entries array — mailboxes run to 60k.
5. **`AvatarPalette` slot order** (AvatarPalette.swift:39-58) is pinned by `Tests/PLMailUITests/AvatarPaletteTests.swift`: seeds hash to indices, so reordering renumbers every sender's colour. Values are also contrast-asserted (`PaletteContrastTests.swift`) — as are `ThemePalette.allShipped` and `ActionTint.all`. New colours must clear 4.5:1 or the suite fails.
6. **Message-card radius stays `PanelStyle.cornerRadius`**, not `theme.paneCornerRadius` (PanelStyle.swift:149-152): server radius reaches panes only; a 2.0rem theme radius would round collapsed rows into lozenges.
7. **Accessibility patterns.** ThreadRowView: combined element + custom actions (:180-186), decorative bits hidden; rows restack at accessibility sizes. Reader reply bar goes icon-only (ThreadReaderView:28). Keep these when reskinning rows/bars.
8. **Localisation.** Every string: `Text(.ui("..."))` (Theme/Localization.swift:18, resolves `Bundle.module`); plain `Text("...")` in the package resolves against `Bundle.main`, misses, and silently ships English. New keys go in **both** catalogues (package + app) where a string is drawn from both targets (menu bar lives in the package for exactly this reason, MailView:~1128 comment).
9. **Motion.** Never read `accessibilityReduceMotion` in a view; read `\.standardAnimation` / `\.fastAnimation` / `\.slowAnimation` (Motion.swift:59-77). `resolvedMotion` sets all three together — Reduce Motion wins over the server theme.
10. **Placeholder theme parity** (ThemeEnvironment.swift:35): `ResolvedTheme.placeholder` must keep drawing exactly the shipped default — previews and un-injected trees depend on it.
11. **`SplitSeparatorHider`** (Theme/SplitSeparatorHider.swift): removes UIKit's split-view hairline; the pane gutters depend on it plus per-column window painting (PanelStyle.swift:246 comment — a background on the split view itself never shows).
