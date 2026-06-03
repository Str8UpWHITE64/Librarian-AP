# Librarian-AP — Stage 1: move pile-hiding (layer 3) onto the game thread

Date: 2026-06-02. Applies to: `Librarian-AP/Scripts/main.lua` + `Scripts/diag_flags.lua`.
Read alongside `CRASH_HANDOFF.md` and `BOOK_WARDING_HANDOFF.md`.

**STATUS (2026-06-03): CONFIRMED.** Shipped in v1.1.0-beta5; a full **1–4 h crash-free playthrough**
confirmed the fix (the crash previously hit within minutes–tens of minutes). Stage 1 (layer 3 → game
thread) + the teardown world-epoch guard are live; layers 1 & 2 stay off-thread to dodge UE4SS #1180
(the "pump" below is the path to bring them on). v1.1.0-beta6 then added the event-hook warding sync
(see `WARDING_SYNC_PLAN.md` / `BETA6_PROGRESS.md`).

---

## TL;DR

The recurring crash is (lead hypothesis, now sharpened) caused by the mod mutating live
game render state **from the wrong thread**, not merely "mid-frame." Stage 1 moves the
**layer-3 pile-hiding** HISM reads/writes onto the **game thread** and adds a wedge guard.
It is gated behind a new diag flag so it can be A/B-tested against the old behavior.

This is the smallest change that targets the **confirmed** beta4 trigger (the `b2-hide`
burst), and it doubles as the cleanest experiment to **prove or disprove** the threading
hypothesis.

---

## The correction that motivated this (important)

Both handoffs state that the mod's `LoopAsync` callbacks run **on the game thread**, and
framed the crash as a main-thread write landing *mid-frame*. **That premise is wrong.**

In UE4SS:

- **`RegisterHook` / `NotifyOnNewObject`** callbacks run on the **game thread**.
- **`LoopAsync` / `ExecuteWithDelay` / `ExecuteAsync`** callbacks run on a **separate
  UE4SS async thread** — *not* the game thread. (`ExecuteInGameThread` exists precisely to
  marshal work back onto the game thread via the engine-tick action queue. The mod's own
  comments already call it "the LoopAsync thread" and serialize DLL access onto it.)

Every world mutation in all three warding layers fires from inside a `LoopAsync` callback,
and the mod never once calls `ExecuteInGameThread` (verified: 0 occurrences). So the HISM
`SetVisibility` / `SetMaterial` / `SetHiddenInGame` writes (and layer 1/2's actor/collision
writes) were running **off the game thread**, with zero synchronization against the engine's
own game-thread and render/instance/cluster-tree workers that read those same components.

That single fact unifies the whole crash catalog: game-code faults at varying sites, varying
target addresses, read **and** write AVs, worker-thread faults with **no mod frames** (the
off-thread Lua write already returned; the engine's parallel job trips over the half-updated
buffer later), `READ 0xFFFFFFFFFFFFFFFF` (= `INDEX_NONE`, a torn HISM instance-index read),
"only with the mod installed," and "predates all v1.1.0 features" (the `LoopAsync`
architecture is original v1.0.x). It also explains why beta4's `WARD_GROUND_TRUTH` — which
turned layer 2's write-heavy passes into read-heavy ones — *reduced* crashes without
eliminating them: fewer off-thread writes = fewer races, but each remaining write is still a
race. (If the cause were a dangling cached ref instead, the per-pass *reads* of that same
cached mesh would crash too; they don't. The crashes track write frequency → race, not
stale-ref.)

---

## What changed (Stage 1 — layer 3 only)

`main.lua` `apply_book_visibility`:

1. **New helper `on_game_thread(fn)`** — runs `fn` via `ExecuteInGameThread` when
   `BOOK_VIS_GAMETHREAD` is on (falls back to inline if the flag is off or the global is
   unavailable, so it can never break mod loading).
2. **`do_chunk` was split** into:
   - `process_chunk()` — one chunk of HISM work (all the `arr[hi]` / `PerInstanceSMData` /
     `Get`/`SetMaterial` / `SetVisibility` / `SetHiddenInGame` reads+writes). Now runs on
     the **game thread**.
   - `run_chunk()` — the driver: runs `process_chunk` via `on_game_thread`, then reschedules
     the next chunk via `LoopAsync` → `run_chunk` (bouncing back to the async thread between
     chunks, so we never nest `ExecuteInGameThread` calls — avoids UE4SS issue #1180).
3. **Wedge guard** — `process_chunk` is `pcall`-wrapped and **always clears `_b2_running`**
   on error. Previously a throwing chunk left `_b2_running = true` forever, and every later
   pass early-returns on it → the pile would stop hiding/revealing for the rest of the
   session. This is a strong candidate for the field report where the pile **stopped
   re-revealing after the unwarded set grew** (`b2-reveal` stuck at 0).

`diag_flags.lua`: new flag **`BOOK_VIS_GAMETHREAD`** (default `true` = fix active).

No warding *logic* changed — same index mapping, same unwarded set, same hide/reveal
mechanics. Only *which thread* the HISM calls run on.

---

## The A/B experiment (for the tester)

The build ships with `BOOK_VIS_GAMETHREAD = true` (game-thread, the fix). To prove the
threading was the cause, run the layer-3 repro **both ways**:

| `diag_flags.lua` setting | Expected | Means |
|---|---|---|
| `BOOK_VIS_GAMETHREAD = true` (default) | **No crash** in the layer-3 repro | Fix works |
| `BOOK_VIS_GAMETHREAD = false` | Crash returns (old off-thread behavior) | Confirms threading was the cause |

Layer-3 repro (drives a hide/reveal burst): play connected to a point with several series
warded, then receive a series/shelf unlock that grows the unwarded set (forces a reveal
pass), and/or do Menu→Continue book-visibility churn. CR1 (a series unlock ~1 min before
the crash) and the beta4 `b2-hide` crash both live here.

Recommended: bump the mod version string before shipping so each `crash_trace.log` names the
build it came from.

---

## How to read the result

- **`crash_trace.log` header line** records the live flags, e.g.
  `flags=...,BOOK_VIS_GAMETHREAD=true,...` — every report is self-describing.
- **No crash with the flag on, crash with it off** ⇒ threading confirmed; proceed to Stage 2
  (apply the same `on_game_thread` wrap to layer 2 `_apply_bookcases_to_world` / `_ward_collision`
  and layer 1 `_apply_one_book`, in `ItemApply.lua`).
- **Still crashes with the flag on** ⇒ layer 3's *writes* are exonerated; the remaining
  layer-3 off-thread reads (the `FindFirstOf`/`FindAllOf`/`mat` lookups at the top of
  `apply_book_visibility`, still on the async thread in Stage 1) or layers 1/2 are next.
  Look at the trace tail: a `BEG b2-hide` with no `END` = still racing inside the write; an
  `END` + heartbeats = decoupled (a different op / a stale buffer from elsewhere).
- A new marker **`MRK b2-chunk-error`** in the log means a chunk threw and the wedge guard
  cleared the running flag (so the freeze can't happen) — capture the message.

---

## Scope / not yet done

- **Layer 2** (case-collision warding) — **DONE (Stage 2):** marshaled onto the game thread via
  `_on_game_thread` + `CASE_WARD_GAMETHREAD`, wrapping both callers; one `ExecuteInGameThread`/pass.
- **Layer 1** (book-actor warding) — code is in (`BOOK_ACTOR_GAMETHREAD`, `_book_run_chunk`, plus a
  pcall/wedge guard and the `_flush_pending` re-fire bounce) but **defaults OFF (off-thread)** — see
  the #1180 finding below. It needs the pump, not a per-chunk marshal.

### ⚠️ Finding (2026-06-02): the `ExecuteInGameThread` volume ceiling (UE4SS #1180)

`ExecuteInGameThread` is NOT free: each call pushes to UE4SS's engine-tick action queue, and v3.0.1
doesn't lock it against concurrent pushes from the async thread. Too many overlapping calls →
`process_simple_actions` aborts (`SIGABRT` / "Abort signal received" / CrashType=Assert — distinct
from an access violation). Stage 1 (layer 3, ~10 calls/5s) was under the threshold; Stage 2 added
layer 1's ~10-chunk burst at connect + layer 2 and **hit the abort right after connecting**
(artifacts: `crash reports/connect-abort 2026-06-02 2138 (post-stage2, ExecuteInGameThread-1180)/`).

Fixes applied this round:
- **Layer 3 collapsed to ONE `ExecuteInGameThread`/pass** (`CHUNK = hn` in `apply_book_visibility`).
  The per-chunk reschedule only ever existed to keep the async poll loop pumping — moot now the work
  is on the game thread.
- **Layer 1 marshal defaulted OFF.** A single-call layer-1 pass would freeze the game thread ~0.5–1s
  on every item burst (3000 actors), so collapse isn't viable for it; it needs the pump.

Current marshal budget: layer 2 (1/5s) + layer 3 (1/pass) ≈ **2 `ExecuteInGameThread`/5s**, well under
the Stage-1 level that ran fine. **Rule of thumb: one marshal per pass, keep the per-pass call count tiny.**

### The pump (the robust end state — real fix for layer 1)

One persistent game-thread drain: a single `RegisterHook` on a per-frame game function that empties a
plain Lua work-queue N items/frame. The async layers just push to the queue — **zero per-pass
`ExecuteInGameThread`**, work spread across frames (no hitch), all on the game thread (no race). This
is what lets layer 1 (and any larger future work) run on the game thread without either #1180 or a freeze.
- The early object lookups in `apply_book_visibility` (`FindFirstOf`/`FindAllOf`, material
  resolve) still run on the async thread; they're reads, not the confirmed write trigger, so
  they're deferred. **Stage 2/3.**
- A single unified per-tick `unwarded` snapshot driving all three layers, and collapsing the
  disabled/legacy code (spatial classifier, Pass-2, covers, v1.0.2 path) — **Stage 3.**
