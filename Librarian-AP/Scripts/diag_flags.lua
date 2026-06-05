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

    -- beta6 Increment 3 / 5b: REVEAL-complete. Now a PRE-hook branch (the post-hook never fires
    -- in this UE4SS build, so the original post-hook version was dead code -> rev=0). When the
    -- game SHOWS an unwarded book, ensure the show is COMPLETE: restore the mesh visibility flags
    -- (SM_Book_1 bHiddenInGame / bVisible) that the game's show doesn't always restore, + enable
    -- collision -- so a "shown but invisible / un-grabbable" book (Bug 6) is corrected. Rides the
    -- game's own show call so it sticks (no churn). Requires BOOK_EVENT_HOOKS. Flip false to
    -- disable this direction (the warded-hide net BOOK_EVENT_ENFORCE stays).
    BOOK_EVENT_REVEAL  = true,

    -- beta6 Increment 4: GRAB-path observe + fix (symptom 2 = "pickable book invisible").
    -- REVEAL (on SetActorVisible) was confirmed NOT to catch this on a real beta6 repro
    -- (revealed=0), so we hook GrabFromPlayer: log the grabbed book's full visibility state
    -- (bHidden / mesh hidden / material) to pinpoint the cause, and conservatively restore an
    -- unwarded book that's hidden when grabbed. Requires BOOK_EVENT_HOOKS. Flip false to keep
    -- the GRAB logging but drop the restore.
    BOOK_EVENT_GRABFIX = true,

    -- beta6.2 Increment 5c: OPACITY restore. The reproducible book proved the "invisible when
    -- looked at, visible after dropping" glitch is NOT any visibility flag (bHidden/mesh all say
    -- visible) -- it's the per-book dynamic material's "Opacity" scalar stuck < 1. When the grab
    -- or look-at (show) paths see an unwarded book with Opacity < 1, set it back to 1 via the
    -- mesh material's MID (sm:GetMaterial(0) -- the reliable path; b.BookMatInst read as nil).
    -- This sets a scalar on the EXISTING actor MID (what the dormant material worker does), NOT
    -- creating a MID on the HISM (the documented crash). Requires BOOK_EVENT_GRABFIX / REVEAL to
    -- carry it. Flip false if forcing Opacity=1 interferes with a legit fade (then the read still
    -- logs the value for diagnosis).
    BOOK_OPACITY_FIX   = true,

    -- beta6.2 Increment 5d: REFRESH fix. The reproducible broken books have CORRECT identity
    -- (series name) but CORRUPT display -- out-of-range Tint colors (2.0 / 3.0 vs the normal 0-1)
    -- and invisible, while every visibility flag, scale, mesh position and pile read normal. The
    -- game's own BP_GrabbingBook RefreshInfo() re-derives a book's appearance from its BookInfo,
    -- so on grab of an unwarded book we call it to redraw a corrupted one. Flip false to disable.
    BOOK_REFRESH_FIX   = true,

    -- beta6.2 Increment 5e: PROACTIVE RefreshInfo sweep. Same fix as BOOK_REFRESH_FIX but applied
    -- on its own (no grab needed): chunks through every unwarded book (a few per SetActorVisible
    -- pre-hook call, game thread, no mass burst) calling RefreshInfo so a corrupt/invisible book
    -- self-heals as you walk past. Redraws healthy books too (a no-op redraw) since broken books
    -- can't be detected by value. This is the FIRST broad use of RefreshInfo -- if it causes a
    -- visible flicker on healthy books or any hitch, flip THIS false (BOOK_REFRESH_FIX grab-path
    -- still works) and report. Requires BOOK_EVENT_HOOKS.
    BOOK_REFRESH_SWEEP = true,

    -- v1.1.0 periodic ACTOR-STATE RECONCILE (the Bug 1 / Bug 2 fix). Every 5s, walk a budget
    -- of BP_GrabbingBook actors and, for each UNWARDED (received) book, assert the two flags the
    -- bugs leave stale -- collision ON (Bug 1: "visible but not grabbable") and, when the actor is
    -- in its shown form, SM_Book_1 mesh visible (Bug 2: "grabbable but invisible when looked at").
    -- Read-before-write: writes ONLY the books whose live value disagrees, so steady state is
    -- reads-only (no churn, no render-state crash risk). It never pins actor bHidden for unwarded
    -- books (that's the game's distance HISM<->actor swap), so it can't double-render a far book.
    -- Logs [reconcile] lines only when it corrects something. Flip false to A/B back to the old
    -- reactive-only behavior (Pass 1 on flush + the beta6 hooks) and confirm the bugs return.
    BOOK_ACTOR_RECONCILE = true,

    -- v1.1.0 PASSIVE invisible-book scanner (Bug 2 diagnostic / known-issue capture). Every 5s,
    -- walks a budget of book actors and flags any UNWARDED book that is in shown form (bHidden=
    -- false) yet WasRecentlyRendered=false across several consecutive scans -- the "visible in the
    -- pile, invisible when held" fault, which leaves no other trace. A SUSPECT is logged once with
    -- a full state dump ([invis-scan] *** SUSPECT *** + [book-hook] SCAN... lines); a per-sweep
    -- [invis-scan] census line reports scale (silent when nothing is amiss). Read-only diagnostic.
    -- Flip false to silence it (e.g. if the census shows bHidden is a poor "near" proxy and it's
    -- noisy on this build) -- it changes NO gameplay either way.
    BOOK_INVIS_SCAN = true,
}
