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
