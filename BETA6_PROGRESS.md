# Librarian-AP — beta6 (warding sync) progress + rollback log

Tracks each beta6 increment so any change can be rolled back. Design: `WARDING_SYNC_PLAN.md`.
Built on the shipped, crash-free **beta5** (commit `440be38`, tag `1.1.0-beta5`).

## How to roll back (three independent levers)

1. **Diag flag (fastest, no code change).** Every increment is gated behind a flag in
   `Librarian-AP/Scripts/diag_flags.lua`. Set it `false`, relaunch — that increment's behaviour is
   off. (Callbacks re-check the flag, so even already-registered hooks become no-ops.)
2. **Git revert (per increment).** Each *validated* increment is its own commit on `v1.1.0-rewrite`.
   `git revert <commit>` undoes exactly that increment.
3. **Deployed `.bak` files.** Each sync to the game backs up the prior deployed file
   (`<file>.pre-<increment>.bak` in the game's `Mods/Librarian-AP/Scripts/`). Restore to revert the
   live copy without git.

Version is NOT bumped during dev (stays `1.1.0-beta5`); it bumps when beta6 is released. Dev builds are
identified in `crash_trace.log`'s header by the new flags.

---

## Increment 1 — OBSERVE-ONLY book-event hooks  ·  status: VALIDATED ✓ (2026-06-03), committed

**Flag:** `BOOK_EVENT_HOOKS` (default `true`).
**Files:** `Scripts/main.lua` (observe-hook block after `on_game_thread`; call in the 5s loop; flag added
to the trace-header list), `Scripts/diag_flags.lua` (flag).
**Behaviour change:** NONE. It registers hooks on the book's `SetActorVisible` / `SetBookInfo` /
`CanBeGrab` functions that only **log** (`[book-hook]` lines). No warding logic is changed.

**Why first:** the whole beta6 plan assumes (a) these Blueprint functions are hookable, (b)
`SetActorVisible` doesn't fire so often that hooking it is a perf problem, and (c) we can resolve a
book's series at hook time. All three are unvalidated. This increment confirms them safely before any
enforcement is built.

**What to look for (validation):** after relaunch + ~1 min of play, the UE4SS log should show:
- `[book-hook] register SetActorVisible OK` (and SetBookInfo / CanBeGrab OK) — confirms hookable.
- `[book-hook] SetActorVisible ... aidx=NN series=...` samples — confirms we can resolve the series.
- `[book-hook] counts so far: SetActorVisible=… …` every ~30s — shows fire frequency (this tells us
  whether enforcement-on-this-hook is cheap enough).
- **No crash, no stutter.**

**Rollback:** `BOOK_EVENT_HOOKS = false` (callbacks no-op) → or discard the uncommitted edits
(`git checkout -- Scripts/main.lua Scripts/diag_flags.lua`) → or restore the `.pre-inc1.bak` files.

**Commit:** held until validated (then committed as `beta6 inc1: observe-only book-event hooks`).

### Result (2026-06-03 — VALIDATED ✓)
- **Register OK** — all three; UE4SS confirms `Registered script hook (32/33/34) for
  BP_GrabbingBook_C:SetActorVisible / SetBookInfo / CanBeGrab`. BP-function hooking works.
- **Series resolves at hook time** — `SetActorVisible` samples show correct `aidx` + series name
  (aidx=26 → "The Countercurse Compendium…", aidx=155 → "Book of Spells: Space - Legendary -"), and
  the `vis=true/false` parameter reads fine. We know, per call, which series and show-vs-hide.
- **Frequency low** — `SetActorVisible` 4 → 29 over a 30 s window (~25/30 s, < 1/s) during active
  play. Cheap to hook and to enforce on.
- **Safe** — no crash, no stutter, no errors.
- **`SetBookInfo`=0, `CanBeGrab`=0 during play.** `SetBookInfo` only fires at world load (before our
  hook binds) — not needed. `CanBeGrab` did **not** fire → increment 2 will **not** depend on it;
  grab-blocking stays on the existing collision-off (already works), visibility is fixed via
  `SetActorVisible`.
- **Decision: PROCEED to increment 2.**

---

## Increment 2 — enforce warding in the SetActorVisible hook  ·  status: AWAITING VALIDATION

**Flag:** `BOOK_EVENT_ENFORCE` (default `true`; requires `BOOK_EVENT_HOOKS=true`).
**Files:** `Scripts/main.lua` (enforcement branch in the SetActorVisible callback; enforced-count in the
report; flag in the trace-header list), `Scripts/diag_flags.lua` (flag).
**Behaviour:** in the SetActorVisible pre-hook, when the game tries to SHOW (`v==true`) a book whose
series is WARDED (not in the live `_compute_unwarded_set`), override the argument via
`is_visible:set(false)` so the game's own call keeps it hidden. Unwarded books are untouched.
Grab-blocking is unchanged (existing collision-off).

**The thing to validate:** that a PRE-hook `is_visible:set(false)` actually takes effect in this UE4SS
version. If `:set()` is a no-op, warded books still leak (NO regression) and `set_ok` logs the failure —
then we fall back to a post-hook re-hide.

**What to look for:**
- `[book-hook] ENFORCE keep-hidden warded series=… set_ok=true` lines (enforcement firing).
- `enforced-hidden=N` rising in the count report.
- In-game: warded books **no longer flash visible** when you look at them (fixes symptom 1); unwarded
  books **show normally** when looked at / picked up (fixes symptom 2). No crash, stutter, or flicker.

**Rollback:** `BOOK_EVENT_ENFORCE = false` (back to observe-only) → or `git revert <commit>` → or
restore `.pre-inc2.bak`.

**Commit:** held until validated.

### Result (fill in after the test run)
- set_ok=true? ____   warded stop leaking? ____   unwarded show OK? ____   flicker/crash? ____
- Decision: ____

### Possible follow-ups
- Cache the unwarded set (recompute on state change) instead of per-call, if call frequency ever rises.
- Consolidate: drive layer 1 (actor) + layer 3 (pile) + this hook off one shared snapshot, and retire
  the redundant per-flush actor walk once the hook proves sufficient.

---

## Increment 3 — REVEAL net (second direction)  ·  status: VALIDATED non-breaking ✓ (2026-06-03), shipped in beta6

**Flag:** `BOOK_EVENT_REVEAL` (default `true`; requires `BOOK_EVENT_HOOKS=true`).
**Files:** `Scripts/main.lua` (POST-hook on SetActorVisible; `reg()` now takes an optional post
callback; revealed-count in the report; flag in the trace-header list), `Scripts/diag_flags.lua` (flag).
**Behaviour:** a POST-hook on SetActorVisible (runs AFTER the game's call). If the game tried to SHOW
(`v==true`) an UNWARDED book but it is STILL hidden (`bHidden==true`) afterward, clear the stale hide
(`SetActorHiddenInGame(false)`). Targets the "vanishing unlocked book" glitch (symptom 2). Fires only on
the actual edge case, so `revealed=N` in the count report = how often it was caught.

**To validate:** (a) that the POST-hook fires at all in this UE4SS version (new mechanism — watch for
`register SetActorVisible OK (pre+post)`), and (b) whether `revealed` ever climbs over a full
playthrough. If `revealed` stays 0, symptom 2 isn't a stale `bHidden` and we look elsewhere; if it
climbs and the tester reports no more vanishing books, it's fixed. In-game: unlocked books should not
vanish when looked at / picked up.

**Rollback:** `BOOK_EVENT_REVEAL = false` (disables just this direction; the warded-hide net stays) →
`git revert <commit>` → `.pre-inc3.bak`.

**Commit:** held until a test run confirms it's non-breaking.

### Result (2026-06-03 — VALIDATED non-breaking ✓)
- **Post-hook registered** — `register SetActorVisible OK (pre+post)`; the post-hook mechanism works in
  this UE4SS version. No RegisterHook errors, no crash.
- **enforced-hidden=0, revealed=0** in the short test — EXPECTED for a ~3/3072-over-hours glitch, not a
  failure. Effectiveness is field-validated by a full playthrough (watch the counts + tester report).
- **Reload burst observed:** on a world (re)load the game calls SetBookInfo on all 3072 books and
  SetActorVisible on ~all of them (SetActorVisible 9 → 3100, SetBookInfo 0 → 3072 across one reload).
  Hooks handled it with no crash. Each enforce/reveal call computes `_compute_unwarded_set` per call, so
  a reload does ~3072 cheap set-builds — negligible here (~70 unlocked series each), but it's why the
  "cache the unwarded set" follow-up matters if a reload hitch ever shows.
- **Decision: shipped in beta6** for full-playthrough field validation.

### Field result (2026-06-03, Bug Report 5 — genuine beta6): REVEAL is INEFFECTIVE for symptom 2
A beta6 player hit the "pickable book invisible" glitch, yet `revealed=0` across ~19 min / 4599
SetActorVisible calls. (ENFORCE worked: `enforced-hidden=3`, `set_ok=true`.) So symptom 2 does NOT
manifest as "unwarded book still bHidden after SetActorVisible" — it bypasses that path entirely and
lives on the **grab/hold path** (`CanBeGrab` fired 10×). REVEAL stays in (harmless; the ENFORCE side is
genuinely valuable) but does not fix symptom 2. The reporter also saw it in 1.0.4 → long-standing rare
one-off, not a regression. → Increment 4.

---

## Increment 4 — GRAB-path observe + conservative fix  ·  status: AWAITING VALIDATION

**Flag:** `BOOK_EVENT_GRABFIX` (default `true`; requires `BOOK_EVENT_HOOKS=true`).
**Files:** `Scripts/main.lua` (GrabFromPlayer hook in `try_register_book_hooks`; Grab/grabfix counts;
flag in the trace-header list), `Scripts/diag_flags.lua` (flag).
**Behaviour:** hook `BP_GrabbingBook_C:GrabFromPlayer` AND `CanBeGrab` via a shared check (CanBeGrab is
proven to fire on grab attempts — Bug Report 5 — so it captures data even if GrabFromPlayer doesn't). LOG the book's full visibility state —
series, unwarded?, actor `bHidden`, `SM_Book_1` mesh hidden flag, and its material name (to catch the
mask material wrongly on the actor). Then conservatively RESTORE: if the book is unwarded but hidden
(actor or mesh), clear that flag. The next grab of the invisible book reveals the cause; common
bHidden/mesh cases get fixed outright.

**To validate (needs a beta6 run):**
- Does GrabFromPlayer and/or CanBeGrab fire? Watch `Grab=N` + the `[book-hook] CANGRAB` lines (CanBeGrab
  is proven to fire). If neither fires, try `Interact` (base `BP_GrabbingItem_C`) next.
- When the glitch recurs, the `[book-hook] GRAB ...` line shows what's hidden (bHidden / meshHidden /
  mat=<mask?>) — that pinpoints the real mechanism.
- Does `grabfix` climb, and do players stop seeing invisible held books?

**Rollback:** `BOOK_EVENT_GRABFIX = false` (keeps GRAB logging, drops the restore) → `BOOK_EVENT_HOOKS
= false` (drops the hook) → `git revert <commit>` → `.pre-inc4.bak`.

**Commit:** held until a test run confirms non-breaking.

### Result (fill in after a beta6 run)
- Grab fires? ____   invisible-book GRAB state (bHidden/mesh/mat)? ____   grabfix climbs? ____   still invisible? ____
