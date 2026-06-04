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

**ROOT CAUSE (found 2026-06-03 during inc5 bring-up):** the SetActorVisible **POST-hook never fires**
in this UE4SS version (the 2nd RegisterHook callback registers "OK (pre+post)" but its code never
executes). So REVEAL was **dead code**, not merely ineffective — `rev=0` always. The PRE-hook (ENFORCE)
fires fine. Any future post-hook logic must move to the pre-hook (as inc5's sweep driver did).

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

### Result (2026-06-03, beta6.1 + Bug Report 6): GrabFromPlayer fires; bHidden is NOT the full cause
- **GrabFromPlayer fires** (registered + `Grab=276` in one session) and **GRAB-FIX works**: it cleared
  `bHidden` on 8 unwarded books ("Prolegomena to Holy Magic Theory", grabbed via a skill).
- **But the book stayed invisible.** Clearing `bHidden` didn't reveal it; no "cleared mesh hidden" logs
  (so mesh `bHiddenInGame`=false); `mat=...MID_MI_G01_Book...` = the normal material (not the mask). So
  the residual invisibility is something grab-fix didn't read: mesh `bVisible` or `BookMatInst` Opacity.
  (The inc4 material-read fix `GetFullName` worked — material confirmed normal.)
- **Conclusion:** grab-time repair is also the wrong *place* — a book that's invisible AND un-grabbable
  can't be grabbed, so the repair can never reach it. Superseded by the proactive sweep (inc5). The grab
  hooks stay as a cheap secondary net + logging.

---

## Increment 5 — PROACTIVE SWEEP (self-healing)  ·  status: LIVE, AWAITING VALIDATION

> **Bring-up fix (2026-06-03):** first wiring drove the sweep from the SetActorVisible POST-hook, which
> produced ZERO output — that post-hook never fires in this UE4SS version (see inc3 root-cause above).
> Moved the `pcall(_sweep_step)` driver to the PRE-hook (provably fires, `setvis=751`). Re-test pending.

**Flags:** `BOOK_SWEEP` (master, default `true`) + `BOOK_SWEEP_FIX` (repair gate, default `true`). Both
require `BOOK_EVENT_HOOKS` (the sweep rides the SetActorVisible hook).
**Files:** `Scripts/main.lua` (sweep block before `try_register_book_hooks`; `pcall(_sweep_step)` in the
SetActorVisible post-hook; `swept`/`swept_samples`/`opacity_samples` in `_bh` + the count report; flags
in the trace-header list), `Scripts/diag_flags.lua` (flags).

**Behaviour:** walk ALL ~3072 BP_GrabbingBook actors, `SWEEP_BUDGET=16` per SetActorVisible call (full
cycle ~38s of play). For each UNWARDED book, ensure it's fully visible: clear actor `bHidden` (+ enable
collision), clear mesh `bHiddenInGame`, set mesh `bVisible=true`. Logs every repair (`[book-sweep] FIX
series=... signals=... opacity=...`). OBSERVES `BookMatInst` Opacity (logs ~20 normal-book samples + the
value on every fix) but does NOT write it yet (GetScalar on a param-less material returns 0 = a false
"invisible"; confirm the normal value first).

**Why this design:** proactive (no player action — fixes books the player can't reach or grab); driven by
the existing game-thread hook so ZERO new `ExecuteInGameThread` (can't hit #1180); chunked (no hitch);
world-epoch guarded (drops the cached actor list on reload to avoid a native AV on stale wrappers). Only
touches UNWARDED books (disjoint from ENFORCE's warded-hide → no fight). Re-enabling collision also
covers symptom 1 (an unwarded book left un-grabbable).

**To validate (field):**
- `[book-sweep] sample ... opacity=N (normal visible book)` — what is N for a healthy book? (1.0 = the
  Opacity param is real and stuck-at-0 is a candidate cause; 0.0 = param absent/unused → ignore opacity.)
- `[book-sweep] FIX series=... signals=...` — which signal(s) it repairs in the wild. If `meshVisible`
  appears, that was Bug 6's residual. `sweep-fixes=N` climbs in the periodic count report.
- Do players stop reporting stuck invisible / un-grabbable books? No hitch/stutter, no crash.

**Rollback:** `BOOK_SWEEP_FIX = false` (observe-only) → `BOOK_SWEEP = false` (off) → `git revert
<commit>` → `.pre-inc5.bak`.

**Commit:** held until a quick local test confirms non-breaking (no hitch/crash + `[book-sweep]` lines).

### Result (2026-06-03 test): RUNS but CHURNS → timer-sweep SHELVED
- Once moved to the pre-hook, the sweep ran: 20 opacity samples + 33 `[book-sweep] FIX` lines, no crash.
- `opacity=nil` on every read → the `BookMatInst:GetScalarParameterValue("Opacity")` path doesn't resolve
  (opacity unreadable as written; secondary hypothesis anyway).
- All 33 fixes were `signals=actorHidden`, REPEATED on the same few series across cycles (~30-60s apart)
  with NO visible change. Diagnosis: clearing `bHidden` from an external timer **churns** — the game's
  per-frame visibility Tick (documented in `ItemApply._set_book_mesh_visible`: "the BP Tick reverts it to
  the expected state every frame") re-sets it next frame, so the clear has no lasting effect. And "actor
  hidden" is the NORMAL state of any distant pile-mode book → mass false positives.
- **Conclusion:** an external timer-sweep cannot fix book visibility — at any instant a book is either one
  the game wants visible (already visible, nothing to do) or one it wants hidden (our write is reverted).
  The fix MUST ride the game's own visibility call (exactly why ENFORCE works). Timer-sweep SHELVED
  (`BOOK_SWEEP=false`; code kept for reference / possible proximity-gated revival). → Increment 5b.

---

## Increment 5b — RIDE-THE-GAME visibility repair  ·  status: LIVE, AWAITING VALIDATION

**Flags:** `BOOK_EVENT_REVEAL` (repurposed → pre-hook complete-the-show) + `BOOK_EVENT_GRABFIX` (enhanced).
Both require `BOOK_EVENT_HOOKS`.
**Files:** `Scripts/main.lua` (REVEAL-complete branch in the SetActorVisible PRE-hook; `_bh_grab_check`
fix enhanced with `bVisible` + collision; timer-sweep call removed), `Scripts/diag_flags.lua`
(`BOOK_SWEEP=false`; comments).

**Behaviour:** two non-churning repairs, both riding hooks PROVEN to fire (pre-hook `setvis=751`;
CanBeGrab/GrabFromPlayer fired):
1. **REVEAL-complete** — SetActorVisible PRE-hook, on `v=true` for an UNWARDED book (you looked at /
   approached it): ensure the show is COMPLETE. If `SM_Book_1.bHiddenInGame==true` or `bVisible==false`,
   restore them + enable collision. Logs `[book-hook] REVEAL-complete series=.. mh=.. vis=..`. Fires only
   on a genuinely-incomplete show (the Bug-6 "shown but invisible" case).
2. **GRAB-FIX enhanced** — added `bVisible` (the Bug-6 residual the bHidden-only fix missed) +
   `SetActorEnableCollision(true)`. Logs `[book-hook] GRAB-FIX series=.. fixed=..`.

**Why this works where the sweep didn't:** it augments the game's OWN show → the Tick keeps the result (no
churn); it fires exactly when the player interacts with the book (looked-at / aimed-at / grabbed) → no
distant-book false positives; the dead post-hook is avoided.

**To validate (normal play, no need to repro the full stuck-bug):** grab books + look along shelves, then
check the log — `GRAB-FIX ... fixed=...meshVisible...` or `REVEAL-complete ... vis=false` would CONFIRM the
mesh-visibility residual is real and now repaired. `revealed=N` / `grabfix=N` climb. No hitch/crash. If a
book stays invisible with NO mh/vis signal, the cause is the (currently unreadable) material Opacity →
next step is fixing that read.

**Rollback:** `BOOK_EVENT_REVEAL=false` / `BOOK_EVENT_GRABFIX=false` → `git revert` → `.pre-inc5.bak`.

### Result (2026-06-03, reproducible book): residual is OPACITY, not the mesh flags → inc5c
- A reproducible book ("Forbidden Alchemy: The Guide to Toxin Brewing and Disposal", BP_GrabbingBook_C_9179):
  grabbable, but invisible when looked at, visible again after dropping. GRAB log:
  `unwarded=true bHidden=false meshHidden=false mat=...MID_MI_G01_Book...` — EVERY visibility flag says
  visible. So inc5b's mesh-flag fixes can't apply to it; the invisibility is the per-book MID's
  transparency. (inc5b's bVisible/mesh fixes stay — valid for the flag-based cases — but this book needs
  opacity.) → Increment 5c.

---

## Increment 5c — OPACITY restore  ·  status: LIVE, AWAITING VALIDATION

**Flag:** `BOOK_OPACITY_FIX` (default `true`; carried by `BOOK_EVENT_GRABFIX` / `BOOK_EVENT_REVEAL`).
**Files:** `Scripts/main.lua` (`_bh_grab_check` + REVEAL-complete: read the MID Opacity via
`sm:GetMaterial(0)` — the reliable path; `b.BookMatInst` read `nil` — log it + actor `scaleX`; if an
unwarded book's Opacity < 1, set it to 1), `Scripts/diag_flags.lua` (flag).

**Behaviour:** on grab and on look-at (show), for an unwarded book, read
`sm:GetMaterial(0):GetScalarParameterValue("Opacity")`. If < 1 (stuck transparent),
`SetScalarParameterValue("Opacity", 1)`. Sets a scalar on the EXISTING actor MID (what the dormant
material worker does) — NOT a MID on the HISM (the documented crash). The GRAB log now also prints
`opacity=` + `scaleX=` for diagnosis.

**To validate:** reproduce the book — GRAB log should show `opacity=0` (or <1), confirming the cause;
`GRAB-FIX ... fixed=opacity(..)` / `REVEAL-complete ... op=0` should fire and the book should stay visible.
If `opacity=1` but still invisible, the logged `scaleX` is the next suspect. No crash.

**Rollback:** `BOOK_OPACITY_FIX=false` (keeps the opacity LOGGING for diagnosis, drops the write) →
`git revert` → `.pre-inc5.bak`.

### inc5c result + the real finding (2026-06-04): it's CORRUPT DISPLAY → fix = RefreshInfo (inc5d/5e)
The opacity reads (inc5c) returned nil/0 — wrong accessor AND not the cause. Widened the grab diagnostic
to dump the MID's full scalar + vector params, the pile (HISM) state, and the mesh world-Z. A controlled
3-adjacent-books test (middle broken) was decisive:
- NOT geometry (mesh Z == actor Z), NOT custom data (empty), NOT the pile mask (`compMat` normal,
  `compVis=true`), NOT scale (1.0), NOT any visibility flag (all read "visible").
- The broken book's IDENTITY is correct (right series) but its DISPLAY is corrupt — out-of-range Tint
  colors (`2.0` / `3.0` vs the normal `0–1`). And broken books DON'T share one wrong value (one had
  out-of-range tints, another normal; `DesatB<0.5` is 292/362 = common) → there is NO reliable
  value-marker to detect them by.
- **Conclusion:** scrambled DISPLAY over intact data. The game's own `RefreshInfo()` rebuilds a book's
  appearance from its BookInfo, so a REDRAW is the correction — no detection needed.

## Increment 5d — RefreshInfo on grab  ·  status: in beta6.2
**Flag:** `BOOK_REFRESH_FIX`. On grab of an unwarded book, call `b:RefreshInfo()` to redraw it.

## Increment 5e — PROACTIVE RefreshInfo sweep (SHIPPED in beta6.2)  ·  status: LIVE, FIELD-VALIDATING
**Flag:** `BOOK_REFRESH_SWEEP` (default `true`). Chunks through every unwarded book (`RSWEEP_BUDGET=12`
per SetActorVisible pre-hook call — game thread, no mass burst, no ExecuteInGameThread) calling
`RefreshInfo` so a corrupt/invisible book self-heals as the player moves — no grab needed. Redraws
healthy books too (a no-op redraw) since broken books can't be detected by value. World-epoch guarded.
**Confirmed:** RefreshInfo executes + redraws (the `SetBookInfo` count tracks `refresh-sweep` 1:1) and is
SAFE (~144 healthy redraws — no flicker / stutter / crash). EFFECTIVENESS (heals broken books) is
unconfirmable locally (the invisibility isn't in any readable value + the bug is intermittent), so it
ships as a **candidate fix for FIELD validation**. Grab-path fix + full grab diagnostics (`GRAB` /
`-PARAMS` / `-VPARAMS` / `-PILE` / `-MESH`) left in to capture any still-broken book.
**Rollback:** `BOOK_REFRESH_SWEEP=false` (keeps grab-path RefreshInfo) → `BOOK_REFRESH_FIX=false` (drops
both) → `git revert` → `.pre-inc5.bak`.

**Dead ends (kept in code, gated off / unused, for reference):** inc5a timer-sweep clearing `bHidden`
(`BOOK_SWEEP=false` — churned vs the game's per-frame Tick); the SetActorVisible POST-hook (never fires
in this UE4SS build → inc3 REVEAL was dead code; REVEAL-complete moved to the PRE-hook); the DesatB scan
(`_scan_desat`, call removed — DesatB isn't the marker); the opacity read/fix (inc5c — not the cause).
