# Librarian-AP — Warding Sync Plan (beta6)

Status: design, not yet implemented. Written 2026-06-02, after beta5 shipped crash-free.
Companion to `STAGE1_GAMETHREAD_NOTE.md` (the crash work) and `BOOK_WARDING_HANDOFF.md` (the system).

---

## 1. Plain-English version (read this first)

**Every book exists as two copies:**
- a **display copy** in the big pile (just decoration — you can't grab it), and
- a **grabbable copy** (the real book you pick up and shelve).

The game shows you one or the other depending on whether you're looking at / reaching for it. As you
look around, it constantly swaps which copy is shown.

**The mod has two separate "lock" systems**, one per copy:
- one hides the **display copy** (the pile),
- one disables the **grabbable copy**.

**The bug:** those two systems run on **different schedules and don't talk to each other**, so they can
briefly disagree about whether a book is locked. When they disagree you get exactly what the tester saw:
- **Visible but can't grab it** — the display copy says "unlocked, show it," but the grabbable copy is
  still locked.
- **Vanishes when you look at / pick it up, comes back when you drop it** — the grabbable copy is
  locked (hidden) but the display copy is unlocked, so it reappears the moment the display copy is
  shown again.

There's also a second twist: the game **re-shows the grabbable copy whenever you look at it**, and that
**overrides the mod's "hide."** So even a correctly-locked book can flash into view when you look right
at it (you still can't grab it — that part holds).

**The fix, in one sentence:** keep **one list** of which book series are locked, and apply it at the
exact moment the game shows or hands you a book — using the game's own built-in signals — instead of
two separate systems each guessing on their own timer.

The good news from digging through the game's code: the game gives us those signals. It literally has a
"show/hide this book" function and a "can the player grab this book?" function we can listen to. So we
can lock a book the instant it appears, from the one shared list — and the two systems can't disagree
anymore because there's only one list and one moment of truth.

---

## 2. The model (slightly more detail)

| Copy | What it is | Mod system today | Mechanism today |
|---|---|---|---|
| **Pile instance** (HISM) | cosmetic heap | Layer 3 (`apply_book_visibility`, main.lua) | hide/show the HISM component (now on the game thread, beta5) |
| **Grabbable actor** (`BP_GrabbingBook_C`) | the interactable book | Layer 1 (`_apply_one_book`, ItemApply.lua) | `SetActorHiddenInGame` + `SetActorEnableCollision` |

There are ~3072 grabbable actors **and** ~400 HISM components, all persistent. The game swaps **which
representation is shown** per book based on look/proximity (it does *not* spawn/destroy actors).

---

## 3. Why the two systems drift apart (root causes)

1. **Different triggers / cadence.** Layer 3 re-runs **every ~5 s** (periodic loop) → self-healing.
   Layer 1 runs **only on item receipt** (`flush_apply`) and is **not** in the periodic loop → it lags.
   After an unlock, the pile updates within 5 s but the actors keep their last-flushed state until the
   next item arrives. *(This is the main driver of the desync.)*
2. **The game fights layer 1's hide.** The game toggles the grabbable actor's visibility
   **view-dependently** (`ItemApply.lua:2618` comment; confirmed by the game's `SetActorVisible`
   function). So layer 1's `SetActorHiddenInGame(true)` does **not** hold when you look at a warded
   book — the game re-shows it. Collision-off still blocks grabbing → **"visible but not grabbable."**
3. **Nothing re-checks a book at the swap.** No hook fires when the game shows / refreshes / hands over
   a book, so neither system re-evaluates at that instant → whichever copy is stale gets shown
   (the **"vanishes when you look at it"** dynamic).
4. **Separate state + separate classification.** Layer 1 tracks `_books_warded` (by actor name) and
   classifies by `actor.ItemInfo.AssetIdx`; Layer 3 tracks `_b2_state` (by HISM index) and classifies
   by `hi-1`. Both read the same `asset_idx_to_series.json`, so they agree **only if** `hi-1 == AssetIdx`
   holds everywhere (validated index-vs-spatial, **not** validated index-vs-layer-1). Separate caches
   can also diverge across a world reset.

---

## 4. The lever: the game's own book functions (from the header dumps)

Book class path: **`/Game/Librarian/Prop/GrabbingItem/BP_GrabbingBook.BP_GrabbingBook_C`**
(base class `ABP_GrabbingItem_C`). All of these run on the **game thread** (hook via `RegisterHook`),
so they're free of the UE4SS #1180 `ExecuteInGameThread` hazard from the crash work.

| Function (confirmed UFunction) | What it does | How we use it |
|---|---|---|
| `SetActorVisible(bool)` | the game shows/hides a book actor (the "view-dependent" toggle that fights us) | **the key hook** — when the game shows a warded book, enforce hidden; ride this instead of fighting it |
| `CanBeGrab()` → bool | the game asks "can the player grab this?" | hook to **return false for warded books** — a clean grab gate, no collision-fighting |
| `SetBookInfo(FLibraryBookInfo)` | a book's identity is (re)assigned | apply correct warding the instant identity is known |
| `RefreshInfo()` | refreshes the book's display | another re-assert point |
| `GrabFromPlayer()` / `Interact()` | grab / interaction entry | optional extra gate |

Pile-manager (`BP_HISM_Manager_C`): `HISMArray`, `UpdateInstance(Info, Transform)`,
**`UpdateWPO(Info, Offset)`** (displaces a book's instance "invisible at deep Z" via material — hides
**without** touching the view-toggled visibility flag), `SetCustomData`. Each book also holds an
`HISMController` ref and its own `BookMatInst` material.

---

## 5. The plan

**North star:** one ground-truth "locked set," enforced at the game's own book events, on the game
thread. Replace "two systems on two timers" with "one list, checked when the game touches a book."

Concretely:

1. **One locked-set snapshot.** Compute the unwarded set once when state changes (any unlock) and store
   it. Every check below reads this one table. (Validate `hi-1 == AssetIdx` once so the actor side and
   pile side classify identically.)
2. **Hook the book's show/identity events** (`SetActorVisible`, `SetBookInfo`, `RefreshInfo`) via
   `RegisterHook`. In each callback (game thread, cheap): resolve the book's series → check the locked
   set → enforce its visibility. This closes the swap window (cause 3) and rides the game's visibility
   decision instead of fighting it (cause 2).
3. **Gate grabbing via `CanBeGrab`,** not collision: hook it to return false for locked series. Cleaner
   and immune to the view-toggle.
4. **Hide locked books with a method the game can't override:** the actor's `BookMatInst` (mask /
   opacity) and/or the manager's `UpdateWPO`, rather than `SetActorHiddenInGame`. Kills the
   "warded book flashes when you look at it" leak (cause 2).
5. **Keep the periodic game-thread pump (beta6) as the backstop.** Events catch the common case
   instantly; the pump re-asserts everything from the one snapshot on a steady cadence and also drives
   the pile (layer 3) and cases (layer 2). This is also what lets layer-1 actor warding come back onto
   the game thread safely (the reason it's off-thread today — see `STAGE1_GAMETHREAD_NOTE.md`).
6. **One reset path.** On world reload, reset/re-assert both copies together (reveal-then-clear), so
   neither is left stale (cause 4).

**Why this actually syncs them:** there's one list and one moment of truth (the game's own book event),
on one thread. The two systems can't be on different clocks because they're driven by the same events
off the same list.

---

## 6. Sequencing

- This is **beta6**, built on the **game-thread pump** already planned at the end of the crash work.
  The pump provides the shared game-thread cadence; this plan is *what it enforces* + the event hooks.
- **Possible quick win first** (optional, lower risk than it sounds because it's read-only-ish): make
  layer 1 re-assert whenever the locked-set signature changes (not only on item receipt). That alone
  removes most of the post-unlock lag (cause 1). But given how "quick" changes bit us during the crash
  hunt, prefer designing it properly on the pump + events and verifying.

---

## 7. Risks / things to validate before/while building

- **BP-function hookability + frequency.** Confirm `RegisterHook` works on these BP (`/Game/...`)
  functions (the mod currently hooks native `/Script/...` ones). Confirm `SetActorVisible` isn't called
  so often that the hook is a perf problem — log fire counts first.
- **Return-value override on `CanBeGrab`.** Confirm UE4SS can modify a BP function's bool return from a
  hook in this version; otherwise gate via collision at the same event.
- **Material-based hide on the actor.** The standing rule "a dynamic material on the book **HISM**
  crashes" is about the HISM, not the actor's own `BookMatInst` — but treat actor-material changes with
  the same caution and test in isolation (diag flag).
- **Classification:** validate `hi-1 == AssetIdx` against the actor side once (the handoff flagged this
  was never checked layer-1-vs-layer-3).
- **Keep it diag-flag gated** (like `BOOK_VIS_GAMETHREAD`) so each piece is independently A/B-testable.

---

## 8. File / function map

| What | Where |
|---|---|
| Pile hiding (layer 3) | `Librarian-AP/Scripts/main.lua` — `apply_book_visibility` |
| Actor warding (layer 1) | `Librarian-AP/Scripts/AP/ItemApply.lua` — `_apply_one_book` / `_apply_books_to_world` |
| Locked-set computation | `ItemApply.lua` — `_compute_unwarded_set` |
| Classification source | `Librarian-AP/Scripts/AP/asset_idx_to_series.json` (AssetIdx → series) |
| World reset | `ItemApply.lua` — `reset_hism_state` (+ the LoadMap hook in main.lua) |
| Game book class | `/Game/Librarian/Prop/GrabbingItem/BP_GrabbingBook.BP_GrabbingBook_C` |
| Game header dumps | `<Game>/Binaries/Win64/CXXHeaderDump/` (BP_GrabbingBook.hpp, BP_GrabbingItem.hpp, BP_HISM_Manager.hpp) |
