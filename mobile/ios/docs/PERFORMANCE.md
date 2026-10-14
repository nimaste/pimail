# Performance against a large mailbox

Written after an evening of measuring plMail on a real iPad Pro (11-inch, iPadOS
26) against a **60,000-message** account. Everything here was measured with
Instruments on the device, not inferred from reading code — several plausible
theories died on contact with the profiler, and the ones that survived are below.

**Status: not fixed.** Two of the three problems are understood precisely. The
third is understood in shape but not in cause. Read this before you spend a day
on it, because most of the obvious suspects are already eliminated.

---

## What the symptoms are

- The conversation list scrolls badly.
- Opening a message locks the interface: touches do nothing, **but the loading
  spinner keeps turning**.
- It reproduces on `b93a77a` — the commit *before* any of the parity work — so
  it is **not a regression from that work**. The base build is slow in the list
  and does still open a message; the current build locks up instead.

## The measurement, and how to repeat it

```bash
xcrun devicectl list devices                     # get the identifier
xcrun devicectl device install app --device <id> <path>/plMail.app
xcrun xctrace record --device <udid> --template "Time Profiler" \
      --attach <pid> --time-limit 40s --output /tmp/p.trace
xcrun xctrace export --input /tmp/p.trace \
      --xpath '//table[@schema="time-profile"]' > /tmp/tp.xml
```

**Count frame *weight*, not frame names.** Instruments emits each frame once with
`name=` and thereafter by `ref=`, so grepping `name="…"` counts distinct inlined
variants and tells you nothing about time. Build an id→name map, then count every
`<frame ref=…>`. Doing it the wrong way made our own code look like the hotspot
at 67 "samples" when it was really 0.036% of the profile — and cost three
confident, useless fixes.

Also useful, and quicker than the full profile:

```bash
xcrun xctrace export --input /tmp/p.trace \
      --xpath '//table[@schema="potential-hangs"]'
```

## What the profile says

With the interface locked, on the main thread:

| Frames | Symbol |
|---|---|
| 47,963 | `-[UIView _wrappedProcessTraitChanges:withBehavior:]` |
| 34,120 | `CA::Layer::layout_and_display_if_needed` / `CA::Transaction::commit` |
| 675 | the largest frame belonging to **our** code |

About **85% of main-thread samples sit inside a Core Animation commit**, and our
own code is a rounding error. This is not a slow routine anyone can find by
reading; it is continuous re-layout of a large view hierarchy.

**The spinner is the tell.** A turning spinner with dead touch input means the
main thread is *saturated*, not blocked — the animation runs on the render
server. So: the spinner keeps a display-linked update running, each update costs
a full layout pass, the main thread never drains, and the `MainActor`
continuation that would *finish the load and stop the spinner* never gets to
run. It sustains itself.

---

## Fixed, and worth keeping

**The list built every row, every frame.** `ForEach` was handed an array built
from every entry in the feed. `List` is lazy about *drawing* rows; it is not lazy
about the array you give it. At 60,000 messages that is 60,000 tuples constructed
and 60,000 identities diffed per body evaluation. Now built 150 at a time,
widening as the reader nears the end (`ThreadListView.rows`, `visibleCount`).

**The join rebuilt a dictionary of every thread, every frame**, allocating an
interpolated `"account#thread"` key per thread. Now rebuilt only when the threads
change, keyed on a two-field struct that allocates nothing.

**`@Query var threads` was unfiltered**, materialising the whole table on the
main thread — and `StoredThread.emailIDs` is an archived binary plist, so each
row costs an `NSKeyedUnarchiver` pass. Now bounded to the newest 2,000.

**Snooze presets were recomputed per body.** `TimePreset.available` resolves each
preset through `Calendar.date(bySettingHour:)` — a forward search — and
`SnoozeMenu` ran it inside a `ForEach` that the reader mentions three times.
Cached to a minute's granularity (`SnoozeChoices`, `SnoozeMenuItems`).

**`SplitSeparatorHider` was an infinite loop.** `updateUIView` unconditionally
scheduled work that set `backgroundColor` on the split view, which invalidated
traits, which caused another update. It now applies only on an actual change.

None of these five made the lock-up go away. All five are real and none should be
reverted.

## Eliminated as causes of the lock-up

Each disabled on the device and re-tested; the lock-up survived every one.

- `SplitSeparatorHider`, removed from the view tree entirely
- The reader's `onScrollVisibilityChange` read-receipt tracking
- The **entire** theme environment injection (`\.theme` and `resolvedMotion`),
  falling back to `.placeholder`
- Spotlight indexing after each sync
- Body prefetch after each background refresh

## Where to look next

The remaining work is architectural, and the assumption to attack is that the
store can be queried freely from a view:

1. **`@Query var entries` still fetches all 60,000 rows** even though only 150
   are now built. Bounding the *array* was the cheap half; bounding the *query*
   needs a descriptor whose `fetchLimit` grows, which means the query has to live
   in a child view that is re-created as the window widens.
2. **`StoredThread.emailIDs` should not be an archived array** on a model the
   list materialises. A join table, or a denormalised count plus a separate
   fetch, would remove an unarchive per row.
3. **The feed entry should carry what the row draws**, so the list needs one
   query rather than a join across two.
4. **Find what re-lays-out continuously.** The trait cascade is the actual
   lock-up and none of the five suspects above explain it. A view-hierarchy
   capture while stuck is the next tool, not another profile.

## A note on method

The fastest progress all evening came from two things: asking whether the *old*
build was also slow (one worktree build, and it split the problem in two), and
the owner pointing out the mailbox had 60,000 messages in it. The slowest came
from reading code and forming theories. Bisect first.
