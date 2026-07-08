-- Runtime A/B switches for the book-warding subsystems. Each defaults to its shipping value;
-- flip one to false + relaunch to isolate a subsystem. pcall-loaded, so a bad file = all defaults.
-- Threading/crash rules referenced below: CRASH_HANDOFF.md.

return {
    -- Layer 3: hide/reveal warded shelves via the book HISM (visibility + material).
    BOOK_VISIBILITY    = true,

    -- Just the HISM SetMaterial calls (isolates the "material on a book HISM crashes" rule).
    HISM_SETMATERIAL   = true,

    -- Marshal Layer 3's HISM writes to the game thread. Off-thread = the Layer-3 crash.
    BOOK_VIS_GAMETHREAD = true,

    -- Layer 2: per-bookcase collision + visibility warding.
    CASE_WARDING       = true,

    -- All MarkRenderStateDirty() calls (the render-proxy recreate a parallel job can race).
    RENDER_STATE_DIRTY = true,

    -- Layer 1: BP_GrabbingBook actor warding (SetActorHiddenInGame + collision-off).
    BOOK_ACTOR_WARDING = true,

    -- Layer 1 -> the serialized ward pump (game thread). Was OFF because the raw
    -- connect-time marshal burst tripped UE4SS #1180; the pump serializes to 1 in-flight.
    BOOK_ACTOR_GAMETHREAD = true,

    -- Ward each bookcase from its live collision, not a cache (kills render-state churn).
    WARD_GROUND_TRUTH  = true,

    -- Layer 2 -> the serialized ward pump (game thread). Was OFF because two marshaled
    -- layers per pass tripped UE4SS #1180; the pump keeps the in-flight count at 1.
    CASE_WARD_GAMETHREAD = true,

    -- Register the gameplay BP hooks (FinishRow / OnLevelUp / save-load / title). Off = no AP tracking.
    NAMED_HOOKS        = true,

    -- Register the book SetActorVisible / SetBookInfo / CanBeGrab hooks (required by all BOOK_EVENT_* below).
    BOOK_EVENT_HOOKS   = true,

    -- Keep a warded book hidden when the game tries to show it (the core sync net).
    BOOK_EVENT_ENFORCE = true,

    -- When an unwarded book is shown, restore its mesh-visible flags + collision.
    BOOK_EVENT_REVEAL  = true,

    -- On grab, restore an unwarded book that's hidden (catches what REVEAL misses).
    BOOK_EVENT_GRABFIX = true,

    -- Reset a stuck Opacity < 1 on the actor MID (never on the HISM -- that crashes).
    BOOK_OPACITY_FIX   = true,

    -- On grab, RefreshInfo() to redraw a book with corrupt display (bad tint / invisible).
    BOOK_REFRESH_FIX   = true,

    -- Proactively RefreshInfo() unwarded books so corruption self-heals as you walk past.
    -- OFF: RefreshInfo on a cached book that's mid-destruction during heavy manipulation = a native
    -- AV. Grab-path BOOK_REFRESH_FIX still covers the targeted case. Set true to re-enable.
    BOOK_REFRESH_SWEEP = false,

    -- Every 5s, re-assert collision + mesh-visible on unwarded books (heals flag drift). Logs only on a fix.
    BOOK_ACTOR_RECONCILE = true,

    -- BookSanity: hide a locked book by teleporting its pile instance to deep Z (pile stays visible
    -- as the actor<->pile backfill). Restored on unlock. Off = actor ward alone gates grabbing.
    BOOK_PILE_TELEPORT = true,

    -- Passive invisible-book scanner. OFF: too noisy without a camera-FOV filter (see known_bugs.txt).
    BOOK_INVIS_SCAN = false,

    -- Single-thread mode. Drives AP client create + poll() + item-apply AND all warding on ONE thread
    -- (the BP_LibrarianCharacter pawn tick) instead of the async LoopAsync, so DLL + apply + warding +
    -- hooks share one Lua executor -- no cross-thread lua_State heap corruption. OFF = legacy async poll.
    POLL_ON_GAME_THREAD = true,

    -- DEV ONLY. true -> main.lua loads AP/probe.lua and its diagnostic keybinds. Ships OFF. Missing
    -- flags default ON here, so main.lua gates on the RAW value == true (not diag_on). Strip this flag
    -- + AP/probe.lua + the main.lua require before release.
    PROBE_MODE = true,
}
