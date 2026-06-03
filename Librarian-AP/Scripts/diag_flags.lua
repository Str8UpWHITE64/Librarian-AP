-- diag_flags.lua  --  Crash-hunt bisection switches.
--
-- The recurring crash is (lead hypothesis) a race between the mod's main-thread writes
-- to the book pile's render state and the engine's parallel reads of that same data
-- (see CRASH_HANDOFF.md). To localize WHICH subsystem's writes trigger it, a tester
-- runs a build with one or more of these flags flipped to `false` and reports
-- crash / no-crash. Vanilla mode is the all-off endpoint; these fill the middle.
--
-- HOW TO USE (testers): edit a value below to false, relaunch the game, play the repro.
-- Every flag DEFAULTS to true = current shipping behaviour, so an unedited file changes
-- nothing. The live state of these flags is written into crash_trace.log's header on
-- every run, so each crash report says exactly which switches were on.
--
-- Highest-value single experiments (each removes ONE engine-side parallel trigger while
-- leaving the feature otherwise working):
--   * HISM_SETMATERIAL   = false   -- tests the "a material op on the book HISM crashes"
--   * RENDER_STATE_DIRTY = false   -- tests the render-proxy-recreation race directly
--   * CASE_WARDING       = false   -- tests the long-standing bookcase ward op
--
-- This file is loaded via pcall; if it's missing or malformed the mod treats every flag
-- as true (current behaviour), so it can never break mod loading.

return {
    -- main.lua apply_book_visibility: hides/reveals warded shelves by toggling the book
    -- HISM components' visibility + material. The newest hazard; matches CR1 (a series
    -- unlock arrived, then crash) where the unlock drives a HISM reveal pass.
    BOOK_VISIBILITY    = true,

    -- Just the h:SetMaterial() calls on the book HISMs inside apply_book_visibility,
    -- leaving SetVisibility on. Isolates the standing "MID/material on book HISM crashes
    -- this game" rule (main.lua:22) from the visibility toggle.
    HISM_SETMATERIAL   = true,

    -- main.lua apply_book_visibility: run the book-HISM reads/writes on the GAME
    -- THREAD (via ExecuteInGameThread) instead of inline on the LoopAsync async
    -- thread. LoopAsync callbacks do NOT run on the game thread (only RegisterHook /
    -- NotifyOnNewObject do), so the old inline SetVisibility/SetMaterial/
    -- SetHiddenInGame writes raced the engine's render / cluster-tree workers that
    -- read the same HISM data -- the lead suspect for the layer-3 crash (READ
    -- 0xFFFFFFFF... = a torn HISM instance-index read). Default true = marshal to the
    -- game thread (the fix). Set false to A/B back to the OLD off-thread behavior and
    -- confirm the crash returns -- the cleanest proof the threading was the cause.
    BOOK_VIS_GAMETHREAD = true,

    -- ItemApply _apply_bookcases_to_world: per-bookcase collision + visibility warding
    -- (the periodic "ward" op). Long-standing; CR2's log ends right after a `ward` pass.
    CASE_WARDING       = true,

    -- Every MarkRenderStateDirty() call (book/case component trees). This is what forces
    -- the engine to recreate a component's render proxy -- the specific operation a
    -- parallel render/instance job can race. Cheap, surgical bisection point.
    RENDER_STATE_DIRTY = true,

    -- BP_GrabbingBook actor warding: SetActorHiddenInGame / SetActorEnableCollision in
    -- _apply_books_to_world. The original v1.0.x warding mechanism.
    BOOK_ACTOR_WARDING = true,

    -- Layer-1 BP_GrabbingBook actor warding (SetActorHiddenInGame /
    -- SetActorEnableCollision in _apply_one_book) on the GAME THREAD.
    -- DEFAULT FALSE (off-thread) on purpose: marshaling ~3000 books meant ~10
    -- ExecuteInGameThread calls in a rapid burst at connect, which tripped UE4SS
    -- #1180 (overlapping engine-tick actions -> abort, "Abort signal received").
    -- A single-call alternative would freeze the game thread ~0.5-1s on every item
    -- burst. Layer 1 was never a CONFIRMED crash trigger (the field crashes were
    -- layer 2 case-ward + layer 3 HISM), so it stays off-thread until the planned
    -- game-thread "pump" (one persistent tick-drained queue, zero per-pass
    -- ExecuteInGameThread) can carry it without the burst or the hitch. Flip true
    -- only to A/B test the layer-1 marshal (expect the #1180 abort at connect).
    BOOK_ACTOR_GAMETHREAD = false,

    -- Drive the per-pass bookcase ward decision off the case's ACTUAL collision (a cheap
    -- read of the placement mesh) instead of re-mutating every case every pass. This is
    -- what kills the ~10k/session render-state churn (the crash suspect) while still
    -- correcting drift within one pass. Set false to revert to the old cache-only
    -- apply-on-change (re-wards everything each re-index) if the read-based check ever
    -- misbehaves.
    WARD_GROUND_TRUTH  = true,

    -- Layer-2 bookcase warding on the GAME THREAD. DEFAULT FALSE: keeping BOTH layer 2
    -- and layer 3 marshaled made the 5s loop issue TWO ExecuteInGameThread pushes
    -- back-to-back (layer 2 then layer 3); the second pushing while the game thread
    -- drains the first = UE4SS #1180 concurrent-queue abort (hit ~seconds after connect,
    -- twice). Stage 1 (layer 3 ALONE, single spaced pushes) ran 22 min clean, so we keep
    -- ONLY layer 3 marshaled for now (1 push/5s) and run layer 2 off-thread
    -- (WARD_GROUND_TRUTH already minimizes its write churn). Layers 1 AND 2 come back via
    -- the game-thread "pump" (zero per-pass ExecuteInGameThread). Flip true only to A/B
    -- the layer-2 marshal (expect the #1180 abort within a few 5s passes).
    CASE_WARD_GAMETHREAD = false,

    -- Registration of the gameplay BP hooks (FinishRow / OnLevelUp / save-load / title /
    -- ModActor). Disabling stops the mod observing those events; use only to test the
    -- hook surface (note: AP progress tracking degrades while off).
    NAMED_HOOKS        = true,

    -- beta6 (warding sync) Increment 1: register OBSERVE-ONLY hooks on the book's
    -- SetActorVisible / SetBookInfo / CanBeGrab functions to validate them (do they
    -- fire? how often? can we resolve the series?) BEFORE building enforcement on top.
    -- Logs only ([book-hook] lines); changes NO gameplay. Flip false to make the
    -- callbacks no-ops (the hooks stay registered but do nothing). Default true for the
    -- beta6 dev validation run; the actual enforcement will use a separate flag.
    BOOK_EVENT_HOOKS   = true,

    -- beta6 Increment 2: ENFORCE warding in the SetActorVisible hook. When the game
    -- tries to SHOW a book whose series is warded, override the call to keep it hidden
    -- (reads the live unwarded set, same one the pile uses). Requires BOOK_EVENT_HOOKS.
    -- This is the actual book-sync fix. Flip false to fall back to observe-only (the
    -- hooks still log but enforce nothing) without reverting code. Grab-blocking is
    -- unaffected (stays on the existing collision-off path).
    BOOK_EVENT_ENFORCE = true,

    -- beta6 Increment 3: REVEAL net (symptom 2 = the "vanishing" unlocked book). A POST-hook
    -- on SetActorVisible: if the game tried to SHOW an UNWARDED book but it stayed hidden,
    -- clear the stale hide so it actually shows. Requires BOOK_EVENT_HOOKS. Flip false to
    -- disable just this direction (the warded-hide net BOOK_EVENT_ENFORCE stays). Rare glitch,
    -- so this is field-validated over a full playthrough.
    BOOK_EVENT_REVEAL  = true,
}
