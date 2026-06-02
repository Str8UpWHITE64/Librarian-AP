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

    -- Drive the per-pass bookcase ward decision off the case's ACTUAL collision (a cheap
    -- read of the placement mesh) instead of re-mutating every case every pass. This is
    -- what kills the ~10k/session render-state churn (the crash suspect) while still
    -- correcting drift within one pass. Set false to revert to the old cache-only
    -- apply-on-change (re-wards everything each re-index) if the read-based check ever
    -- misbehaves.
    WARD_GROUND_TRUTH  = true,

    -- Registration of the gameplay BP hooks (FinishRow / OnLevelUp / save-load / title /
    -- ModActor). Disabling stops the mod observing those events; use only to test the
    -- hook surface (note: AP progress tracking degrades while off).
    NAMED_HOOKS        = true,
}
