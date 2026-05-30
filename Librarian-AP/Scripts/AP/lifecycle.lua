-- lifecycle.lua — single source of truth for "what phase are we in".
--
-- Replaces the old scattered lifecycle: a never-reset global `m01_load_count`,
-- `_suppress_next_m01_load_count`, and ~6 booleans (`_gameplay_active`,
-- `_allow_pre_apply`, `_apply_safe`, ...) hand-copied as gates into a dozen
-- loops/hooks across main.lua + ItemApply.lua. That design had no single
-- authority, three redundant activation paths, and gated the dangerous work
-- (forced OpenLevel, actor enumeration) on fixed delays + book-count heuristics
-- instead of real signals — which is the root of the "crash at the main menu
-- during loading" failures.
--
-- This module is PURE LOGIC: it owns the state and the legal transitions, and
-- notifies a listener on every change. All side effects (starting/stopping
-- loops, calling BP functions, enabling the Continue button) live in the
-- listener that the integrator (main.lua) registers — so the state machine
-- itself touches no game state and cannot crash.
--
-- States:
--   BOOT        process just started; nothing loaded yet.
--   TITLE       at the title screen, not in a connected play session.
--   CONNECTING  AP slot connected; we are (re)loading PL_M01 for this seed.
--   PRE_APPLY   PL_M01 loaded behind the title menu; warding is being applied
--               in the background; Continue/Start stay disabled until done.
--   GAMEPLAY    player pressed Continue; actively playing.
--
-- The only path that mutates the world is GAMEPLAY (and the tail of PRE_APPLY
-- once the world is confirmed populated). Nothing enumerates or mutates actors
-- in BOOT/TITLE/CONNECTING, which is exactly the window the old code crashed in.

local L = {}

L.S = {
    BOOT       = "BOOT",
    TITLE      = "TITLE",
    CONNECTING = "CONNECTING",
    PRE_APPLY  = "PRE_APPLY",
    GAMEPLAY   = "GAMEPLAY",
}

-- Legal transitions. Anything not listed is rejected + logged (a rejected
-- transition is a bug signal, not a silent no-op).
local TRANSITIONS = {
    BOOT       = { TITLE = true },
    -- From the title we can connect, or (re)load straight into a session.
    TITLE      = { CONNECTING = true, TITLE = true },
    -- Connect → reload-behind-title → pre-apply. A dropped connection returns
    -- to TITLE; a re-connect mid-flow re-enters CONNECTING.
    CONNECTING = { PRE_APPLY = true, TITLE = true, CONNECTING = true },
    -- Pre-apply finishes and the player clicks Continue → gameplay. A drop or
    -- a re-connect can bounce us back.
    PRE_APPLY  = { GAMEPLAY = true, TITLE = true, CONNECTING = true },
    -- In gameplay we can return to the title, or reconnect (re-sync).
    GAMEPLAY   = { TITLE = true, CONNECTING = true, GAMEPLAY = true },
}

L._state = L.S.BOOT
L._listener = nil   -- function(new_state, old_state, reason)
L._log = function() end

--- Wire up the integrator. `listener(new, old, reason)` runs on every accepted
--- transition (after the state field is updated). `log(msg)` is optional.
function L.init(listener, log)
    L._listener = listener
    if log then L._log = log end
end

function L.current() return L._state end
function L.is(state) return L._state == state end

--- Returns true iff the world may be read/mutated right now. Single predicate
--- replacing the old `(_gameplay_active or _allow_pre_apply)` copies.
function L.world_active()
    return L._state == L.S.GAMEPLAY or L._state == L.S.PRE_APPLY
end

--- Returns true only in full gameplay (sends checks, applies items live).
function L.in_gameplay() return L._state == L.S.GAMEPLAY end

--- Attempt a transition. Returns true if accepted. Illegal transitions are
--- rejected (logged) so a mis-wired signal surfaces loudly instead of
--- corrupting state.
function L.to(new_state, reason)
    local old = L._state
    if new_state == old then
        return true  -- idempotent re-entry of the same state is fine
    end
    local allowed = TRANSITIONS[old]
    if not (allowed and allowed[new_state]) then
        L._log(("[lifecycle] REJECTED %s -> %s (%s)"):format(
            tostring(old), tostring(new_state), tostring(reason)))
        return false
    end
    L._state = new_state
    L._log(("[lifecycle] %s -> %s (%s)"):format(old, new_state, tostring(reason)))
    if L._listener then
        local ok, err = pcall(L._listener, new_state, old, reason)
        if not ok then
            L._log("[lifecycle] listener error: " .. tostring(err))
        end
    end
    return true
end

-- ── Semantic events ────────────────────────────────────────────────────────
-- Integrator (main.lua) translates raw engine signals into these. The mapping
-- of "what signal means what" lives in ONE place (here), not scattered as
-- m01_load_count arithmetic across hooks.

--- First time PL_M01 finishes loading (the title-screen preview). BOOT→TITLE.
function L.on_title_loaded()
    if L._state == L.S.BOOT then L.to(L.S.TITLE, "title PL_M01 loaded") end
end

--- AP slot connected (slot_data in hand). Begins a play session for this seed.
--- A reconnect mid-gameplay must NOT tear down the session — the server
--- re-sends items and we re-sync in place — so only a fresh connect (from the
--- title) advances into CONNECTING.
function L.on_slot_connected()
    if L._state == L.S.GAMEPLAY then return end
    L.to(L.S.CONNECTING, "slot connected")
end

--- The PL_M01 reload we trigger on connect has finished AND the world is
--- confirmed populated (real signal: books present / apply-gate passed) — NOT
--- a fixed delay. Only now is it safe to begin warding behind the title menu.
function L.on_world_ready()
    if L._state == L.S.CONNECTING then
        L.to(L.S.PRE_APPLY, "world ready (populated)")
    end
end

--- Background warding finished; Continue/Start may be enabled.
--- (Does not change state by itself — gameplay starts on the Continue press.)
L._pre_apply_done = false
function L.on_pre_apply_complete()
    L._pre_apply_done = (L._state == L.S.PRE_APPLY)
end
function L.pre_apply_complete() return L._pre_apply_done end

--- Player pressed Continue / the title menu hid. Enter gameplay. Guarded so a
--- stray button event before pre-apply finishes can't jump the gun.
function L.on_continue()
    if L._state == L.S.PRE_APPLY then
        L.to(L.S.GAMEPLAY, "continue pressed")
    elseif L._state == L.S.GAMEPLAY then
        -- already playing; ignore
    else
        L._log(("[lifecycle] continue ignored in state %s"):format(L._state))
    end
end

--- Returned to the title screen from gameplay (or the world tore down).
function L.on_returned_to_title()
    L._pre_apply_done = false
    if L._state ~= L.S.BOOT and L._state ~= L.S.TITLE then
        L.to(L.S.TITLE, "returned to title")
    end
end

--- AP disconnected. We stay wherever we are if mid-gameplay (the session is
--- still live, items just stop flowing) but reset the pre-apply latch.
function L.on_disconnected()
    L._pre_apply_done = false
    -- No forced transition: a disconnect during gameplay shouldn't tear down
    -- the play session. A subsequent reconnect re-enters CONNECTING for resync.
end

return L
