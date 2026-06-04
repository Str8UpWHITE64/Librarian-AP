# Changelog

Versions are git tags on `v1.1.0-rewrite` (e.g. `1.1.0-beta1`). Newest first.

## 1.1.0-beta6.2 — 2026-06-04 (released)

Candidate fix for the rare **"unlocked book renders invisible (but still grabbable)"** glitch (symptom 2).
A 3-adjacent-books diagnosis (middle one broken) pinned the shape: the invisible book has the CORRECT
identity but a CORRUPT display (out-of-range material Tint colors), while every visibility flag, scale,
mesh position, and pile state read normal — and broken books share no single wrong value, so they can't be
detected by inspection. The cause is a scrambled appearance over intact data, so the fix is to **redraw**.

- **Proactive RefreshInfo sweep.** A chunked, game-thread sweep (`BOOK_REFRESH_SWEEP`) walks every unlocked
  book and calls the game's own `RefreshInfo()` (which rebuilds a book's appearance from its BookInfo), so
  a corrupt/invisible book **self-heals as you move past it — no grab required**. Redrawing a healthy book
  is a no-op. Confirmed executing (the `SetBookInfo` count tracks `refresh-sweep` 1:1) + safe (no
  flicker/stutter/crash); chunked so there's no hitch and **zero `ExecuteInGameThread`** (can't hit #1180).
  Also applied on grab (`BOOK_REFRESH_FIX`).
- **Honest status:** the bug is intermittent and invisible to every readable value, so effectiveness is
  validated in the field, not locally — report if you still see an invisible-but-grabbable book. Rich grab
  diagnostics are retained so any remaining case is captured in the log.
- Earlier dead-end approaches (a `bHidden` timer-sweep that churned, a never-firing post-hook,
  opacity/desaturation guesses) are gated off; see `BETA6_PROGRESS.md`.
- **Also:** section signs now glow RED (no cases open) / YELLOW (some) / OFF (all open) for clearer unlock
  progress, replacing the old RED/locked-only cue.
- Crash fixes + beta5/beta6 warding are unchanged.

## 1.1.0-beta6.1 — 2026-06-03 (released)

A small follow-up to beta6 targeting the **"pickable book turns invisible"** glitch (symptom 2). beta6's
REVEAL net (a post-hook on `SetActorVisible`) was confirmed in the field NOT to catch it — a genuine
beta6 repro logged `revealed=0` while the player hit the glitch — because it bypasses the show path
entirely and lives on the **grab/hold path**. This build adds a grab-path hook to (a) capture exactly
what's hiding the book and (b) conservatively fix the common cases.

- **Grab-path instrumentation + conservative fix.** A shared check runs from both
  `BP_GrabbingBook_C:GrabFromPlayer` and `CanBeGrab` (the latter is proven to fire on grab attempts, so
  data is captured regardless of which path the game uses). It logs the grabbed book's full visibility
  state — actor `bHidden`, the `SM_Book_1` mesh hidden flag, and its material name (to catch the mask
  material wrongly on the actor) — and, if an UNWARDED book is found hidden, clears that flag. Gated
  `BOOK_EVENT_GRABFIX`. The `[book-hook] GRAB` / `CANGRAB` log lines pinpoint the mechanism for the next
  occurrence, so a precise fix can follow if the conservative one doesn't fully cover it.
- **Version strings tidied.** The `slot_data` "version" (stale at beta3 since beta3 — harmless, since
  the client parses only the numeric `1.1.0`) and a README example now read the current version.
- Crash fixes and the warding base are unchanged; beta6's ENFORCE net (warded-hide) is unchanged and
  confirmed working in the field.

## 1.1.0-beta6 — 2026-06-03 (released)

Built on beta5 (which fixed the recurring crash — confirmed by a full crash-free playthrough). This is a
**book-visibility edge-case fix**: the rare (~3 of 3072 books over a long run) cases where a book's two
representations — the cosmetic pile and the grabbable actor — briefly disagree about whether its series
is warded, producing a book that is "visible but not grabbable" or that "vanishes when looked at /
picked up."

Root cause: the two warding systems re-evaluate on different triggers (the pile every ~5s; the actor
only on item receipt), and the game toggles the book actor's visibility view-dependently — so an actor
can lag the true locked-set after an unlock until the next item arrives.

Fix: hook the game's own `BP_GrabbingBook_C` events **on the game thread** (validated: hookable, cheap
— SetActorVisible fires <1/s in normal play — and the book's series is resolvable at hook time) and
enforce the single, live locked-set at the moment the game shows a book:
- **SetActorVisible pre-hook** (`BOOK_EVENT_ENFORCE`) — if the game tries to SHOW a book whose series is
  warded, override the call so the game's own function keeps it hidden. Fixes the visible-but-not-
  grabbable direction.
- **SetActorVisible post-hook** (`BOOK_EVENT_REVEAL`) — if the game showed an unwarded book but it
  stayed hidden, clear the stale hide so it actually shows. Fixes the vanishing-book direction.
- Grab-blocking is unchanged (existing collision-off). New default-on diag flags `BOOK_EVENT_HOOKS` /
  `BOOK_EVENT_ENFORCE` / `BOOK_EVENT_REVEAL`, each independently toggleable; every catch is logged
  (`[book-hook]`) so the fix is observable in the field.

The common case (warded books fully hidden, unlocked books shown + grabbable) was already correct and is
unchanged. Because the targeted cases are rare, effectiveness is validated over a full playthrough via
the `[book-hook]` counts + player reports. Crash fixes from beta5 are carried forward unchanged.

## 1.1.0-beta5 — 2026-06-02 (released)

Built on beta4. Two more **crash fixes** for the warding system's interaction with the game's render
thread and with world reloads, plus diagnostic groundwork (default-off) for finishing the job.

- **Crash fix — book-pile hiding moved onto the game thread.** beta4 cut the *shelf*-warding churn;
  this addresses the remaining confirmed trigger on the **book pile** (the 400
  HierarchicalInstancedStaticMesh components). The mod hid/revealed warded series by writing their
  visibility + material (`SetVisibility` / `SetMaterial`) from a UE4SS `LoopAsync` callback — which,
  contrary to a long-standing assumption in our notes, runs on a **separate thread, not the game
  thread** (only `RegisterHook` / `NotifyOnNewObject` callbacks are on the game thread). Those
  off-thread writes raced the engine's parallel render / cluster-tree workers reading the same data —
  the `READ 0xFFFFFFFF…` (INDEX_NONE) member of the recurring `0x1e8a88f` access-violation family. Fix
  (`apply_book_visibility`, `main.lua`): marshal the whole pile-hiding pass onto the game thread via
  `ExecuteInGameThread` (one call per pass). Behind the `BOOK_VIS_GAMETHREAD` flag.

- **Crash fix — returning to the main menu (world-reload use-after-free).** Going to the main menu
  forces a world reload; a pile-hiding pass already scheduled for the game thread could then run
  against the **freed** old-world HISM array — a *native* access violation that Lua `pcall` cannot
  catch. Fix: a **world-epoch counter** bumped on every reload (`reset_hism_state`); the deferred pass
  snapshots it and **bails without touching any captured reference** if the world changed underneath
  it. Confirmed catching the race in the field (a `b2-stale-world` ledger marker) with no crash.

- **Stability — shelf + book-actor warding kept off the game-thread marshal (for now).** Marshaling
  those layers too overloaded UE4SS's game-thread action queue and hit a separate abort (UE4SS issue
  \#1180), so they stay on the proven off-thread path (with beta4's churn reduction). New default-off
  flags `BOOK_ACTOR_GAMETHREAD` / `CASE_WARD_GAMETHREAD` stage them for a follow-up that moves them via
  a single per-frame game-thread "pump" instead of per-pass marshaling.

## 1.1.0-beta4 — 2026-06-02 (released)

Built on beta3. A targeted **crash fix** and a **stuck-shelf fix**, plus a durable crash-logging
system that replaces beta2's `[crumb]` breadcrumbs so any remaining crash is finally actionable.

- **Crash fix — the recurring render-state-churn race (candidate fix).** Diagnosis: beta3 re-applied
  the collision/visibility warding to *every* bookcase every ~5 seconds (~10,000 redundant mesh writes
  per session), because the change-tracker was wiped on each periodic re-index. Those constant
  main-thread render-state writes raced the game's parallel render/instance worker on the book pile —
  the signature of the recurring `0x1e8a88f` access violation, which surfaced both inline on the game
  thread (hash `BAE1A5E0`) and on a worker the game thread was blocked waiting on (hash `423B7BBD`) —
  the *same* operation, not two bugs. The fix (`_apply_bookcases_to_world`, `AP/ItemApply.lua`) now
  decides whether to re-ward a case by **reading the case's actual collision** instead of re-writing
  blindly, so an already-correct shelf is a no-op. Per-session ward writes dropped from ~10,000 to a
  few dozen, removing the race window; drift is still corrected within one pass. We believe this fixes
  the crash but can't confirm without field time — please report any crash with the new log (below).
  Toggleable via the `WARD_GROUND_TRUTH` flag.

- **Fixed shelves stuck un-placeable until reload (e.g. 1M / 1N).** A bookcase that should be unlocked
  could stay un-placeable — visible, but you couldn't place books on it — until you reloaded from the
  menu. Cause: the unlock restore relied on the per-mesh collision *captured* at first-ward, and a
  capture taken while the shelf was still streaming (e.g. during a burst of shelf unlocks from a
  force-release) recorded a bad value the restore then skipped. The fix (`_ward_collision`) now forces
  the placement shelf solid + placeable **unconditionally** on unlock, independent of the capture, and
  identifies the placement mesh robustly (covers the 4x5 / 5-volume cases too). A new `[ward-unlock]`
  log line records the decision so any future stuck shelf names the exact case.

- **New durable crash logging (replaces the `[crumb]` breadcrumbs).** A flushed-to-disk ledger at
  `Mods/Librarian-AP/crash_trace.log` records the mod's book/shelf operations as they happen, so the
  lines right before a crash always survive to disk. **If the game crashes, please send
  `crash_trace.log` alongside the crash dump** (and `UE4SS.log`). Also ships runtime diagnostic
  switches (`Mods/Librarian-AP/Scripts/diag_flags.lua`, all default-on = normal behavior) we may ask
  you to flip to isolate an issue.

## 1.1.0-beta3 — 2026-06-02 (released)

Built on beta2. Two new features plus a reworked warded-book classifier (a *potential* fix —
see the note). The temporary `[crumb]` breadcrumbs from beta2 are still in for the open crash.

- **Items you send to other players now show their real names (were "Unknown").** The
  location-scout (`LocationInfo`) handler labelled every scouted item with the *local* game's name
  table, so any item belonging to another game resolved to "Unknown". It now resolves each item's
  name through the *receiving* player's game — `get_player_game(player)` → `get_item_name(id, that_game)`
  in `APClient.lua`. Incoming-item naming was already correct; only the outgoing/scout display was wrong.

- **Vanilla mode — play the base game without disconnecting or uninstalling.** The title-screen
  Continue / New Game buttons stayed disabled unless you connected to a server, so having the mod
  installed forced you into Archipelago. The connection window's close button is now labelled
  **Vanilla**; clicking it enables the normal Continue / New Game buttons and the mod makes **no**
  changes — no warding, no hiding, no tracking. The BP `Btn_Close` fires `BroadcastCloseRequest` →
  `enter_vanilla_mode()` (`main.lua`) to un-gate the buttons, and `activate_gameplay` + the
  level-up / row tracking are now no-ops unless a slot is actually connected. One-way for the
  session — restart the game to return to Archipelago. (Requires the updated `LibrarianAPHUDFix.pak`.)

- **Reworked warded-book hiding — a POTENTIAL fix for warded covers appearing in the pile (NOT
  confirmed resolved).** The old classifier inferred each pile-group's series from the nearest book
  *actor* by position. Once a series is shelved the game moves that series' book actors onto the
  shelf, stranding its pile instances next to *other* series' books — so the position guess could
  latch onto the wrong series and a warded cover could show (or the wrong group reveal as series
  unlocked). The classifier now reads each group's series **directly from its fixed index**
  (`series = _asset_to_series[hi-1]` in `apply_book_visibility`) rather than guessing from positions:
  deterministic, unaffected by shelving or where you're standing, and correct immediately on a
  resumed save. In our testing the warded-cover glitch did not reappear, but we can't yet call it
  resolved — **please keep reporting any warded series whose cover shows in the pile.** The old
  position-based classifier is retained but disabled behind a flag (`B2_SPATIAL_CROSSCHECK`) as a
  fallback / ground-truth cross-check.

## 1.1.0-beta2 — 2026-06-01 (released)

Built on beta1. Bundles the fixes below, plus a temporary set of diagnostic breadcrumbs that
log which periodic operation is active — to help pinpoint a rare, still-open crash (see the
final note).

- **Removed gameplay diagnostic hooks (crash investigation / stability).** beta1 still carried
  several investigation-era hooks that fired during skill use, level-ups, and HUD updates —
  `MajorSkillUsed` / `FinalSkillUsed`, the native + BP `OnLevelUp` / `ShowSkillLevelUp` probes,
  four notification probes, and four HUD probes (99 lines total in `main.lua`). These ran during
  the exact skill-burst moments that correlated with the in-game crashes, so they're removed to
  test whether the mod's own hook footprint is the trigger. Only production hooks remain: BP
  `OnLevelUp` (level/row tracking), `FinishRow` / `NewRowFinished` / `EndGame`, save/load, and the
  title-menu + connect wiring. The book-hiding feature is unchanged.

- **Shelves and cabinets un-placeable after unlock (1F, 1N, 1H).** The unlock restore
  depended on the per-mesh collision *captured* at first-ward. If that capture was read before
  the bookcase finished initializing, the placement channel was recorded as Ignore, and
  restoring it left the shelf un-placeable forever (sign off, but no placement). A first attempt
  added a "is any trace channel still blocked?" validity check with a block-all fallback, but it
  missed multi-channel cases — when some *other* trace channel (e.g. Visibility) was blocked, the
  check passed yet the placement channel stayed Ignore. Root fix in `_ward_collision`
  (`AP/ItemApply.lua`): on unlock, the placement-target mesh — the component literally named
  **`StaticMesh`**, which is the shelf surface in both single-mesh standard shelves AND the inner
  shelf of multi-mesh cabinets — is forced to **block-all**, so placement always works regardless
  of capture quality. The structural meshes (cabinet body `SM_M01_BookCabinet_03` + wall
  `SM_M01_CabinetWall_02`) still restore their captured original so the placement trace passes
  *through* them to the inner shelf (block-all-ing them was the original cabinet bug). This is
  capture-independent for the placement target and supersedes the capture-validity attempt. A
  periodic reconciliation (drop the ward cache every ~30 passes → clean re-assert from
  `_shelves_open`, gameplay+apply_safe-gated) backs it up; books were already self-healing.

- **Unwarded books occasionally going invisible until the next unlock.** The cosmetic
  pile-hiding (`apply_book_visibility` in `main.lua`, which hides the static HISM pile-groups
  for warded series) ran every ~5s but short-circuited unless the *unwarded set* changed. The
  actor↔HISM swap triggered by looking at / moving past a series reshuffles which books are
  static instances, so a group classified correctly earlier could drift and hide an unwarded
  book — and, since that's not an unwarded-set change, it stayed hidden until the next series
  unlock. Fix: the classifier now re-runs on every ~5s pass with fresh book positions, so a
  wrongly-hidden group self-corrects within one pass. Cheap in steady state (when nothing has
  drifted it only reads HISM data — no visibility/material mutations); logging is suppressed
  unless a real change occurs.
    - Follow-up (warding is a startup-only operation): the warded set only ever shrinks during
      a session, so any mid-game *hide* is a swap artifact, not a real state change. The
      classifier now **freezes hiding** once the initial warding converges (a pass that hides
      nothing new while groups are already hidden; safety cap at 6 passes) and only ever
      *reveals* afterward — eliminating the jarring "place a book and it flickers invisible"
      effect. The freeze + the hidden-state cache reset on Menu→Continue / reload so each fresh
      world re-wards from scratch.

- **Label-glow efficiency cleanup (NOT a crash fix — see note).** `refresh_index_if_changed()`
  re-indexes the bookcases every 5s *unconditionally*, and `_index_bookcases()` cleared the
  sign-glow caches every time — so `_apply_label_glow()` re-mapped and re-touched all 31
  CabinetLabel SpotLights on every pass, and spammed `[label-glow] mapped 31 sections` to the
  log. The CabinetLabel actors + SpotLights live in the **persistent level**, so their glow
  caches don't need clearing on a bookcase re-index — that coupling is removed from
  `_index_bookcases`. The caches still reset on a genuine world reload (`reset_hism_state` /
  leaving gameplay / ward-canary drift), so signs stay correct across Continue; the glow now
  only touches a sign when its section's lock state actually changes. This eliminates wasted
  per-cycle work and the log spam (which also makes future crash logs readable).

  > Note: this was first (wrongly) blamed for the recurring `BAE1A5E0` write-AV crash because
  > the glow log was the last line before a crash. That was a base-rate error — the most
  > frequent logger is always the last logger. The `BAE1A5E0` call stack is **byte-identical**
  > between a 2026-05-08 crash and a 2026-06-01 crash (every game + UE4SS frame matches), and
  > the sign glow didn't ship until 2026-05-30 — so the glow is provably **not** in that crash
  > path. `BAE1A5E0` remains an OPEN, long-standing use-after-free (faulting address varies
  > between 0x0 and live heap addresses = writing through a freed pointer), unrelated to this
  > change. Tracked separately; see investigation notes.

- **Diagnostic breadcrumbs for the open `BAE1A5E0` crash (temporary).** A rare write-AV
  (~once per long session, movement-correlated, and predating every v1.1.0 feature) is still
  open and can't be symbolicated (the Shipping build ships no PDBs). To catch it, each periodic
  operation now logs a `[crumb]` line as it runs; the last one before a crash names the
  operation that was active (or `idle:*` = none of ours → the game's own tick). If you crash,
  your `UE4SS.log` — read before relaunching, since it resets on launch — carries the
  breadcrumb. These will be removed once the culprit is found.

## 1.1.0-beta1 — 2026-05-31 (released)

- Shelf unwarding fixed — unlocking a section faithfully reverses the ward so its bookcases
  accept books again.
- Invisible warded books in the central pile — spatial whole-group classifier with a
  conservative rule (an unwarded series never vanishes when it shares a pile-group with
  warded ones).
- Removed temporary investigation diagnostics.
- Version bumped to 1.1.0-beta1 (apworld + Lua + manifest).
