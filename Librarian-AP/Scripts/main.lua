-- Librarian Archipelago Mod (UE4SS Lua)
-- Top-level wiring: AP client, save-slot redirection, title gating, BP hooks,
-- F4/F12 keybinds, post-connect pre-apply loop. World mutations live in AP/ItemApply.lua.

local MOD = "LibrarianAP"

local function log(msg)
    print(("[%s] %s\n"):format(MOD, tostring(msg)))
end

-- ============================================================
-- Crash-hunt instrumentation (see AP/trace.lua, diag_flags.lua, CRASH_HANDOFF.md)
-- ============================================================
-- diag_flags: runtime bisection switches. Each defaults ON; unknown/missing flag -> ON.
local DIAG = (function()
    local ok, t = pcall(require, "diag_flags")
    return (ok and type(t) == "table") and t or {}
end)()
local function diag_on(flag)
    local v = DIAG[flag]
    if v == nil then return true end   -- unknown/missing flag -> current behavior
    return v and true or false
end
local function diag_flags_str()
    local order = { "BOOK_VISIBILITY", "HISM_SETMATERIAL", "BOOK_VIS_GAMETHREAD",
                    "CASE_WARDING", "RENDER_STATE_DIRTY", "BOOK_ACTOR_WARDING",
                    "BOOK_ACTOR_GAMETHREAD", "WARD_GROUND_TRUTH", "CASE_WARD_GAMETHREAD",
                    "NAMED_HOOKS", "BOOK_EVENT_HOOKS", "BOOK_EVENT_ENFORCE",
                    "BOOK_EVENT_REVEAL", "BOOK_EVENT_GRABFIX", "BOOK_OPACITY_FIX",
                    "BOOK_REFRESH_FIX", "BOOK_REFRESH_SWEEP",
                    "BOOK_ACTOR_RECONCILE", "BOOK_INVIS_SCAN" }
    local parts = {}
    for _, k in ipairs(order) do parts[#parts + 1] = k .. "=" .. tostring(diag_on(k)) end
    return table.concat(parts, ",")
end

-- trace: durable, flushed-on-every-write crash breadcrumb ledger. Stubbed to no-ops if absent.
local trace = (function()
    local ok, t = pcall(require, "AP/trace")
    if ok and type(t) == "table" and t.begin then return t end
    return { init = function() end, begin = function() end, finish = function() end,
             mark = function() end, recent = function() return {} end }
end)()
_G._librarian_trace = trace   -- reachable from hook callbacks if ever needed

-- on_game_thread(fn): marshal `fn` onto the game thread. CRITICAL: LoopAsync/ExecuteWithDelay
-- run on a separate async thread; off-thread HISM writes race the engine's render/cluster-tree
-- workers -> native crash (CRASH_HANDOFF.md). Gated BOOK_VIS_GAMETHREAD; falls back to inline if
-- ExecuteInGameThread is unavailable.
-- Cached once at load: single-thread (game-thread pawn tick) mode. When on, warding runs inline on
-- the caller (the pawn tick IS the game thread) instead of via the async pump; the async LoopAsync
-- loops are gated off and their work moves to the pawn-tick master scheduler (Stage 2 single-thread fix).
local POLL_GT = diag_on("POLL_ON_GAME_THREAD")

-- Published for modules that need the single-thread decision but do not read diag_flags
-- themselves (AP/HUD.lua). Set before any require below, so it is live by the time they load.
_G._librarian_poll_gt = POLL_GT

-- Stage-2 single-thread scheduler. When POLL_GT, periodic work that used to run on the async LoopAsync
-- thread is registered here and driven by the game-thread pawn tick (the ReceiveTick master scheduler)
-- at each step's own interval, via a DeltaSeconds accumulator. When off, gt_loop just starts a normal
-- LoopAsync (legacy, unchanged). A step that returns true is latched off (mirrors LoopAsync stop).
local _gt_steps = {}          -- name -> { fn, interval, accum, stopped }
local _gt_step_order = {}
local _gt_pending_activate = nil  -- reason string set by a title-button hook; consumed on the game thread by the scheduler
local _gt_pending_f12 = false     -- F12/F4 fire on the UE4SS input thread; the binds set a
local _gt_pending_f4  = false     -- boolean and the master tick runs the actual work
local _l3_resume = nil            -- L3 (book-pile HISM) chunk resume; the master scheduler advances it one chunk/frame
local _l3c_ep, _l3c_mgr, _l3c_mat, _l3c_ready   -- L3 setup scan cache (per world epoch): HISM mgr / mask material / ready flag
local _gt_last_epoch = -1         -- last world epoch the scheduler saw; a bump means the captured warding arrays are freed
local function gt_loop(name, interval_ms, fn)
    if POLL_GT then
        if not _gt_steps[name] then _gt_step_order[#_gt_step_order + 1] = name end
        _gt_steps[name] = { fn = fn, interval = interval_ms, accum = 0, stopped = false }
    else
        LoopAsync(interval_ms, fn)
    end
end
local function gt_run_steps(dt_ms)
    for i = 1, #_gt_step_order do
        local name = _gt_step_order[i]
        local st = _gt_steps[name]
        if st and not st.stopped then
            st.accum = st.accum + dt_ms
            if st.accum >= st.interval then
                st.accum = 0
                local ok, res = pcall(st.fn)
                if ok then
                    if res == true then st.stopped = true end
                else
                    -- A silently dropped step looks exactly like one that ran clean.
                    log(("[gt-step] %s error: %s"):format(tostring(name), tostring(res)))
                end
            end
        end
    end
end

-- Deferred one-shot work, run on the game thread once `delay_ms` of tick time has elapsed.
--
-- This replaces marshalling from the async thread. Marshalling looked safe -- the body ran on the
-- game thread -- but the ExecuteInGameThread CALL still happens off-thread, and crash stacks that
-- run engine-tick -> UE4SS -> Lua with NO ProcessEvent frame between them are exactly that queue
-- executing a body. Handing the work to the master tick keeps the async thread out of it entirely.
--
-- Nothing here needs to beat the pawn tick: it starts at the first M01 load, seconds before the
-- title is interactive. Anything queued earlier just runs on the first tick.
local _gt_deferred = {}
local _gt_clock_ms = 0
local function gt_defer(delay_ms, fn)
    if not POLL_GT then
        LoopAsync(delay_ms, function() fn() return true end)
        return
    end
    if delay_ms < 1 then delay_ms = 1 end   -- 0 would be due in the same pass it was queued
    _gt_deferred[#_gt_deferred + 1] = { due = _gt_clock_ms + delay_ms, fn = fn }
end

local function gt_run_deferred(dt_ms)
    _gt_clock_ms = _gt_clock_ms + dt_ms   -- advance even when idle, or a later due-time reads stale
    local i = 1
    while i <= #_gt_deferred do
        local d = _gt_deferred[i]
        if _gt_clock_ms >= d.due then
            table.remove(_gt_deferred, i)
            local ok, err = pcall(d.fn)
            if not ok then log(("[gt-defer] error: %s"):format(tostring(err))) end
        else
            i = i + 1
        end
    end
end

local function on_game_thread(fn)
    if POLL_GT then return fn() end   -- single-thread mode: already on the game thread; run inline
    if diag_on("BOOK_VIS_GAMETHREAD") and type(ExecuteInGameThread) == "function" then
        -- Route layer 3 through ItemApply's serialized ward pump so it shares the
        -- single in-flight gate with layers 1-2 (no overlapping marshals = no #1180).
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA._pump_enqueue then
            IA._pump_enqueue(fn)
        else
            ExecuteInGameThread(fn)   -- pump not loaded yet (rare): marshal directly
        end
    else
        fn()
    end
end


-- ============================================================================
-- Book-event hooks: enforce the warded set at the game's own book events
-- (SetActorVisible / SetBookInfo / CanBeGrab). See WARDING_SYNC_PLAN.md.
-- Gated BOOK_EVENT_HOOKS; registered once on the game thread (single one-shot
-- ExecuteInGameThread). Each callback re-checks its flag, so a flip = no-op.
-- ============================================================================
local BOOK_BP = "/Game/Librarian/Prop/GrabbingItem/BP_GrabbingBook.BP_GrabbingBook_C"
local _book_hooks_attempted = false
local _bh = { setvis = 0, setinfo = 0, canbegrab = 0, samples = 0, enforced = 0, enf_samples = 0,
              revealed = 0, rev_samples = 0, grabbed = 0, grab_samples = 0, grabfix = 0 }

local function _bh_series(book_obj)
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._book_valid_asset_idx and IA._asset_to_series) then return nil, nil end
    local aidx = IA._book_valid_asset_idx(book_obj)
    if aidx == nil then return nil, nil end
    return aidx, IA._asset_to_series[aidx]
end

local function _bh_sample(tag, book_obj, extra)
    if _bh.samples >= 15 then return end
    _bh.samples = _bh.samples + 1
    pcall(function()
        local aidx, series = _bh_series(book_obj)
        log(("[book-hook] %-15s aidx=%s series=%s%s"):format(
            tag, tostring(aidx), tostring(series), extra and (" " .. extra) or ""))
    end)
end

-- Read a named scalar param from a MID's OVERRIDDEN list (ScalarParameterValues). Must read the
-- array directly: GetScalarParameterValue returns nil here. nil = param not overridden on this MID.
local function _mid_scalar(mid, name)
    local out
    pcall(function()
        local arr = mid.ScalarParameterValues
        local n = 0; if arr then pcall(function() n = #arr end) end
        for i = 1, n do
            local e = arr[i]
            if e then
                local nm
                pcall(function() nm = e.ParameterInfo.Name:ToString() end)
                if not nm then pcall(function() nm = e.ParameterName:ToString() end) end
                if nm == name then pcall(function() out = e.ParameterValue end) break end
            end
        end
    end)
    return out
end

-- Dump all overridden scalar params as "name=value,..." for diagnostics.
local function _mid_dump(mid)
    local s = "?"
    pcall(function()
        local arr = mid.ScalarParameterValues
        local n = 0; if arr then pcall(function() n = #arr end) end
        local parts = {}
        for i = 1, math.min(n, 12) do
            local e = arr[i]
            if e then
                local nm, val = "?", "?"
                pcall(function() nm = e.ParameterInfo.Name:ToString() end)
                if nm == "?" or not nm then pcall(function() nm = e.ParameterName:ToString() end) end
                pcall(function() val = e.ParameterValue end)
                parts[#parts + 1] = tostring(nm) .. "=" .. tostring(val)
            end
        end
        s = "[" .. table.concat(parts, ",") .. "](" .. tostring(n) .. ")"
    end)
    return s
end

-- Same for VECTOR params (colors): opacity may live in a color's alpha. Logs name=(R,G,B,a=A).
local function _mid_dump_vec(mid)
    local s = "?"
    pcall(function()
        local arr = mid.VectorParameterValues
        local n = 0; if arr then pcall(function() n = #arr end) end
        local parts = {}
        for i = 1, math.min(n, 10) do
            local e = arr[i]
            if e then
                local nm = "?"
                pcall(function() nm = e.ParameterInfo.Name:ToString() end)
                if nm == "?" or not nm then pcall(function() nm = e.ParameterName:ToString() end) end
                local r, g, bl, a = "?", "?", "?", "?"
                pcall(function() local v = e.ParameterValue; r = v.R; g = v.G; bl = v.B; a = v.A end)
                parts[#parts + 1] = ("%s=(%s,%s,%s,a=%s)"):format(tostring(nm), tostring(r), tostring(g), tostring(bl), tostring(a))
            end
        end
        s = "[" .. table.concat(parts, ",") .. "](" .. tostring(n) .. ")"
    end)
    return s
end

-- Inspect a book's cosmetic pile HISM (what layer 3 wards; the GRAB hook reads the ACTOR and
-- can't see it). Reports whether we left the HISM hidden/masked/moved while series is unwarded.
-- hi = AssetIdx+1 (the layer-3 index mapping). Read-only; game thread (same as layer 3).
local function _inspect_pile(b)
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._book_valid_asset_idx) then return "no-IA" end
    local aidx = IA._book_valid_asset_idx(b)
    if aidx == nil then return "no-aidx" end
    local mgr = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr and mgr:IsValid()) then return "no-mgr" end
    local arr; pcall(function() arr = mgr.HISMArray end)
    local hn = 0; if arr then pcall(function() hn = #arr end) end
    local hi = aidx + 1
    if hi < 1 or hi > hn then return ("hi=%d out-of-range(%d)"):format(hi, hn) end
    local h; pcall(function() h = arr[hi] end)
    if not (h and h:IsValid()) then return "no-hism@" .. tostring(hi) end
    local cvis, chid, cmat = "?", "?", "?"
    pcall(function() cvis = h.bVisible end)
    pcall(function() chid = h.bHiddenInGame end)
    pcall(function() local m = h:GetMaterial(0); if m and m:IsValid() then cmat = m:GetFullName() end end)
    -- nearest instance to the book actor's X,Y, and its Z (hugely negative => moved off-screen)
    local bx, by
    pcall(function() local loc = b:K2_GetActorLocation(); if loc then bx = loc.X; by = loc.Y end end)
    local sm; pcall(function() sm = h.PerInstanceSMData end)
    local sn = 0; if sm then pcall(function() sn = #sm end) end
    local bd2, bz
    if bx and by then
        for j = 1, sn do
            local x, y, z
            pcall(function() local wp = sm[j].Transform.WPlane; x = wp.X; y = wp.Y; z = wp.Z end)
            if x and y then
                local dx, dy = x - bx, y - by
                local d2 = dx * dx + dy * dy
                if not bd2 or d2 < bd2 then bd2 = d2; bz = z end
            end
        end
    end
    return ("hi=%d compVis=%s compHidden=%s compMat=%s instN=%d nearDist=%s nearZ=%s"):format(
        hi, tostring(cvis), tostring(chid), tostring(cmat), sn,
        bd2 and tostring(math.floor(math.sqrt(bd2))) or "?", tostring(bz))
end

-- Proactive RefreshInfo sweep: redraw every unwarded book in chunks so a corrupt one (invisible
-- but correct identity) self-heals without a grab. Can't detect broken books by value, so redraw
-- all; RefreshInfo re-derives look from BookInfo (no-op for healthy, rebuild for corrupt) and is a
-- redraw the Tick won't revert (no churn). World-epoch guarded. Gated BOOK_REFRESH_SWEEP.
local _rsw_books, _rsw_n, _rsw_cursor, _rsw_epoch, _rsw_uw = nil, 0, 1, nil, nil
local RSWEEP_BUDGET = 12
local function _refresh_sweep_step()
    if not diag_on("BOOK_REFRESH_SWEEP") then return end
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._apply_safe and IA._book_valid_asset_idx and IA._asset_to_series
            and IA._compute_unwarded_set) then return end
    if _rsw_books and (IA._world_epoch or 0) ~= (_rsw_epoch or 0) then _rsw_books = nil end
    if not _rsw_books or _rsw_cursor > _rsw_n then
        _rsw_books = FindAllOf("BP_GrabbingBook_C")
        _rsw_n = 0; if _rsw_books then pcall(function() _rsw_n = #_rsw_books end) end
        _rsw_cursor = 1
        _rsw_epoch = IA._world_epoch
        -- GAME THREAD (rides SetActorVisible): cache the snapshot ref, never compute on this thread.
        _rsw_uw = IA._unwarded_snapshot
        if _rsw_n == 0 then return end
    end
    local uw = _rsw_uw
    if not uw then return end
    local last = math.min(_rsw_cursor + RSWEEP_BUDGET - 1, _rsw_n)
    for i = _rsw_cursor, last do
        local b = _rsw_books[i]
        if b and b:IsValid() then
            local aidx = IA._book_valid_asset_idx(b)
            local series = aidx and IA._asset_to_series[aidx]
            if series and uw[series] then
                pcall(function() b:RefreshInfo() end)
                _bh.rsweep = (_bh.rsweep or 0) + 1
            end
        end
    end
    _rsw_cursor = last + 1
end

-- Shared grab-path check, called from BOTH GrabFromPlayer and CanBeGrab (routing through both
-- hedges against GrabFromPlayer not firing). Logs the book's full visibility state, then restores
-- an unwarded book that's hidden. Logging gated BOOK_EVENT_HOOKS, restore gated BOOK_EVENT_GRABFIX.
-- Game thread; the setters used aren't hooked (no re-entrancy).
local function _bh_grab_check(b, tag)
    if not b then return end
    local _, series = _bh_series(b)
    local bhidden, mesh_hidden, mat = nil, nil, "?"
    local mesh_vis, opacity, scalex, midref, scalars_dump, vectors_dump = nil, nil, nil, nil, "?", "?"
    local actorz, meshz, meshname, cpd = "?", "?", "?", "?"
    pcall(function() bhidden = b.bHidden end)
    pcall(function() local s = b:GetActorScale3D(); if s then scalex = s.X end end)
    pcall(function() local al = b:K2_GetActorLocation(); if al then actorz = al.Z end end)
    local sm; pcall(function() sm = b.SM_Book_1 end)
    if sm and sm:IsValid() then
        pcall(function() mesh_hidden = sm.bHiddenInGame end)
        pcall(function() mesh_vis = sm.bVisible end)
        pcall(function()
            local m = sm:GetMaterial(0)
            if m and m:IsValid() then mat = m:GetFullName(); midref = m end
        end)
        if midref then
            opacity = _mid_scalar(midref, "Opacity")   -- value if "Opacity" is overridden, else nil
            scalars_dump = _mid_dump(midref)            -- DEFINITIVE: every overridden scalar param
            vectors_dump = _mid_dump_vec(midref)        -- and every overridden vector/color param
        end
        -- GEOMETRY check: is the MESH shoved to deep Z (our -1,000,000 hide pattern) while the
        -- ACTOR root sits at the hand? That = grab-able-but-invisible. Plus the mesh asset
        -- (null/wrong?) and CustomPrimitiveData (per-book floats a WPO/material may read).
        pcall(function() local ml = sm:K2_GetComponentLocation(); if ml then meshz = ml.Z end end)
        pcall(function() local msh = sm.StaticMesh; if msh and msh:IsValid() then meshname = msh:GetFullName() end end)
        pcall(function()
            local arr = sm.CustomPrimitiveData and sm.CustomPrimitiveData.Data
            local nn = 0; if arr then pcall(function() nn = #arr end) end
            local parts = {}
            for k = 1, math.min(nn, 12) do local v; pcall(function() v = arr[k] end); parts[#parts + 1] = tostring(v) end
            cpd = "[" .. table.concat(parts, ",") .. "](" .. tostring(nn) .. ")"
        end)
    end
    local IA = package.loaded["AP/ItemApply"]
    local unwarded_here
    if series and IA and IA._unwarded_snapshot then
        -- GAME THREAD (grab path): single snapshot lookup, no alloc/iterate. Calling
        -- _compute_unwarded_set here races _recompute_state -> the rc3 crash. See
        -- ItemApply._unwarded_snapshot.
        local uw = IA._unwarded_snapshot
        unwarded_here = uw and uw[series] or false
    end
    -- BROKEN = any signal that renders an unwarded book invisible/unpickable: meshZ far from
    -- actorZ (deep-Z hide), opacity<1 (stuck-transparent MID), scaleX~0, or the raw hide flags.
    local meshz_off = (type(meshz) == "number" and type(actorz) == "number") and math.abs(meshz - actorz) or 0
    local looks_broken = (bhidden == true) or (mesh_hidden == true) or (mesh_vis == false)
        or (type(opacity) == "number" and opacity < 1.0)
        or (type(scalex) == "number" and scalex < 0.01)
        or (meshz_off > 1000.0)
    -- Dump full state for the first 100 grabs (baseline) AND any broken-looking grab beyond that
    -- (bounded), so an intermittent invisible book is captured long after the baseline cap.
    local dump = (tag == "SCAN") or (_bh.grab_samples < 100) or (looks_broken and (_bh.broken_dumps or 0) < 60)
    if dump then
        if looks_broken then
            _bh.broken_dumps = (_bh.broken_dumps or 0) + 1
            log(("[book-hook] *** BROKEN-GRAB *** %s series=%s unwarded=%s bHidden=%s meshHidden=%s meshVis=%s opacity=%s scaleX=%s meshZoff=%.1f"):format(
                tostring(tag), tostring(series), tostring(unwarded_here), tostring(bhidden),
                tostring(mesh_hidden), tostring(mesh_vis), tostring(opacity), tostring(scalex), meshz_off))
        elseif tag ~= "SCAN" then
            _bh.grab_samples = _bh.grab_samples + 1
        end
        log(("[book-hook] %s series=%s unwarded=%s bHidden=%s meshHidden=%s meshVis=%s opacity=%s scaleX=%s mat=%s"):format(
            tostring(tag), tostring(series), tostring(unwarded_here), tostring(bhidden),
            tostring(mesh_hidden), tostring(mesh_vis), tostring(opacity), tostring(scalex), tostring(mat)))
        log(("[book-hook] %s-PARAMS series=%s scalars=%s"):format(tostring(tag), tostring(series), scalars_dump))
        log(("[book-hook] %s-VPARAMS series=%s vectors=%s"):format(tostring(tag), tostring(series), vectors_dump))
        log(("[book-hook] %s-PILE series=%s %s"):format(tostring(tag), tostring(series), _inspect_pile(b)))
        log(("[book-hook] %s-MESH series=%s actorZ=%s meshZ=%s cpd=%s mesh=%s"):format(
            tostring(tag), tostring(series), tostring(actorz), tostring(meshz), tostring(cpd), tostring(meshname)))
    end
    -- The deferred render-truth re-check that used to sit here is gone: it held an actor reference
    -- across a 600ms async delay and then read the actor off-thread, which is the shared-heap access
    -- the single-thread rule exists to remove. The fields it logged are diagnostics only.
    if diag_on("BOOK_EVENT_GRABFIX") and unwarded_here == true then
        local did = {}
        if bhidden == true then
            pcall(function() b:SetActorHiddenInGame(false) end)
            did[#did + 1] = "actorHidden"
        end
        if sm then
            if mesh_hidden == true then
                pcall(function() sm:SetHiddenInGame(false, false) end)
                did[#did + 1] = "meshHidden"
            end
            if mesh_vis == false then
                pcall(function() sm:SetVisibility(true, false) end)
                did[#did + 1] = "meshVisible"
            end
        end
        -- "all flags visible but invisible" = the per-book MID's "Opacity" stuck < 1. Restore via
        -- the mesh material's GetMaterial(0) MID (b.BookMatInst is nil). Gated BOOK_OPACITY_FIX.
        -- Setting a scalar on the EXISTING actor MID is safe; creating a MID on the HISM crashes.
        if diag_on("BOOK_OPACITY_FIX") and midref and type(opacity) == "number" and opacity < 1.0 then
            pcall(function() midref:SetScalarParameterValue("Opacity", 1.0) end)
            did[#did + 1] = "opacity(" .. tostring(opacity) .. ")"
        end
        pcall(function() b:SetActorEnableCollision(true) end)
        if #did > 0 then
            _bh.grabfix = _bh.grabfix + 1
            log("[book-hook] GRAB-FIX series=" .. tostring(series) .. " fixed=" .. table.concat(did, "+"))
        end
    end
    -- Some broken books have correct identity but corrupt display (out-of-range Tints + invisible)
    -- while every flag reads normal. RefreshInfo re-derives appearance from BookInfo; redraw on
    -- grab of an unwarded book. Gated BOOK_REFRESH_FIX.
    if diag_on("BOOK_REFRESH_FIX") and unwarded_here == true then
        local ok = pcall(function() b:RefreshInfo() end)
        _bh.refreshed = (_bh.refreshed or 0) + 1
        if (_bh.refresh_samples or 0) < 20 then
            _bh.refresh_samples = (_bh.refresh_samples or 0) + 1
            log(("[book-hook] REFRESH series=%s ok=%s"):format(tostring(series), tostring(ok)))
        end
    end
end

local function try_register_book_hooks()
    if _book_hooks_attempted then return end
    if not diag_on("BOOK_EVENT_HOOKS") then return end
    _book_hooks_attempted = true
    ExecuteInGameThread(function()
        local function reg(fn, cb, cb_post)
            local ok, err
            if cb_post then
                ok, err = pcall(function() RegisterHook(BOOK_BP .. ":" .. fn, cb, cb_post) end)
            else
                ok, err = pcall(function() RegisterHook(BOOK_BP .. ":" .. fn, cb) end)
            end
            log(("[book-hook] register %-16s %s"):format(
                fn, ok and (cb_post and "OK (pre+post)" or "OK") or ("FAILED: " .. tostring(err))))
        end
        reg("SetActorVisible", function(self, is_visible)
            if not diag_on("BOOK_EVENT_HOOKS") then return end
            _bh.setvis = _bh.setvis + 1
            pcall(_refresh_sweep_step)    -- proactive: redraw unwarded books in chunks (heal corrupt ones)
            -- Visibility is corrected by riding the game's OWN SetActorVisible call (ENFORCE +
            -- REVEAL-complete below) -- no separate timer-sweep, no post-hook.
            local b, v
            pcall(function() b = self:get() end)
            pcall(function() v = is_visible:get() end)
            _bh_sample("SetActorVisible", b, "vis=" .. tostring(v))
            -- ENFORCE: when the game tries to SHOW (v==true) a WARDED book, override the arg to
            -- false so its own call keeps it hidden -- no flicker, no re-entrancy. Unwarded books
            -- show normally (unlock takes effect on next show). Reads the LIVE unwarded set.
            if diag_on("BOOK_EVENT_ENFORCE") and v == true and b then
                local _, series = _bh_series(b)
                local IA = package.loaded["AP/ItemApply"]
                if series and IA and IA._unwarded_snapshot then
                    -- GAME THREAD: read the precomputed snapshot (single lookup, no alloc/iterate).
                    -- Calling _compute_unwarded_set here is the rc3 crash (races _recompute_state).
                    local unwarded = IA._unwarded_snapshot
                    -- stacks mode (_book_hide_mode==false): warded actor stays visible, just
                    -- non-grabbable (collision is layer 1's job) -- never force-hide it.
                    if IA._book_hide_mode ~= false and not (unwarded and unwarded[series]) then
                        local set_ok = pcall(function() is_visible:set(false) end)
                        _bh.enforced = _bh.enforced + 1
                        if _bh.enf_samples < 10 then
                            _bh.enf_samples = _bh.enf_samples + 1
                            log(("[book-hook] ENFORCE keep-hidden warded series=%s set_ok=%s"):format(
                                tostring(series), tostring(set_ok)))
                        end
                    end
                end
            end
            -- REVEAL-complete: when the game SHOWS an UNWARDED book it doesn't always restore the
            -- MESH -- a stuck SM_Book_1 bHiddenInGame/bVisible leaves it "shown" yet invisible.
            -- Clear the mesh hide flags + ensure collision. Rides the show call, so Tick keeps it.
            if diag_on("BOOK_EVENT_REVEAL") and v == true and b then
                local _, rseries = _bh_series(b)
                local IA = package.loaded["AP/ItemApply"]
                if rseries and IA and IA._unwarded_snapshot then
                    -- GAME THREAD: snapshot lookup only (see ENFORCE above / ItemApply._unwarded_snapshot).
                    local unwarded = IA._unwarded_snapshot
                    if unwarded and unwarded[rseries] then
                        local sm; pcall(function() sm = b.SM_Book_1 end)
                        if sm and sm:IsValid() then
                            local mh, vis, op, mid
                            pcall(function() mh = sm.bHiddenInGame end)
                            pcall(function() vis = sm.bVisible end)
                            pcall(function() mid = sm:GetMaterial(0) end)
                            if mid and mid:IsValid() then op = _mid_scalar(mid, "Opacity") end
                            -- op < 1 = stuck-transparent book; restore Opacity here too so just
                            -- LOOKING at it repairs it. Gated BOOK_OPACITY_FIX.
                            local op_bad = diag_on("BOOK_OPACITY_FIX") and type(op) == "number" and op < 1.0
                            if mh == true or vis == false or op_bad then
                                if mh == true then pcall(function() sm:SetHiddenInGame(false, false) end) end
                                if vis == false then pcall(function() sm:SetVisibility(true, false) end) end
                                if op_bad then pcall(function() mid:SetScalarParameterValue("Opacity", 1.0) end) end
                                pcall(function() b:SetActorEnableCollision(true) end)
                                _bh.revealed = _bh.revealed + 1
                                if _bh.rev_samples < 15 then
                                    _bh.rev_samples = _bh.rev_samples + 1
                                    log(("[book-hook] REVEAL-complete series=%s mh=%s vis=%s op=%s"):format(
                                        tostring(rseries), tostring(mh), tostring(vis), tostring(op)))
                                end
                            end
                        end
                    end
                end
            end
        end)
        reg("SetBookInfo", function(self)
            if not diag_on("BOOK_EVENT_HOOKS") then return end
            _bh.setinfo = _bh.setinfo + 1
            local b; pcall(function() b = self:get() end)
            _bh_sample("SetBookInfo", b)
        end)
        reg("CanBeGrab", function(self)
            if not diag_on("BOOK_EVENT_HOOKS") then return end
            _bh.canbegrab = _bh.canbegrab + 1
            local b; pcall(function() b = self:get() end)
            _bh_grab_check(b, "CANGRAB")
        end)
        -- GRAB-path observe + fix for "pickable book invisible" (which SetActorVisible/REVEAL
        -- never sees). _bh_grab_check runs from BOTH CanBeGrab (above) and GrabFromPlayer.
        reg("GrabFromPlayer", function(self)
            if not diag_on("BOOK_EVENT_HOOKS") then return end
            _bh.grabbed = _bh.grabbed + 1
            local b; pcall(function() b = self:get() end)
            _bh_grab_check(b, "GRAB")
        end)
        log("[book-hook] hooks registered (enforce/reveal/grabfix active per flags)")
    end)
end

local _bh_report_tick = 0
local function bh_report_periodic()
    if not diag_on("BOOK_EVENT_HOOKS") then return end
    _bh_report_tick = _bh_report_tick + 1
    if _bh_report_tick % 6 ~= 0 then return end   -- ~every 30s (6 ticks of the 5s loop)
    log(("[book-hook] counts: SetActorVisible=%d (enf=%d rev=%d) SetBookInfo=%d CanBeGrab=%d Grab=%d (grabfix=%d) refresh-sweep=%d"):format(
        _bh.setvis, _bh.enforced, _bh.revealed, _bh.setinfo, _bh.canbegrab, _bh.grabbed, _bh.grabfix, _bh.rsweep or 0))
end

-- ============================================================================
-- Passive invisible-book scanner. The "visible in pile, invisible when held" bug
-- leaves no flag/material/transform trace; only WasRecentlyRendered exposes it.
-- Every 5s, walk a budget of unwarded shown books; one NEAR + shown-but-not-drawn
-- across INVIS_STREAK scans is a SUSPECT, dumped once. Gated BOOK_INVIS_SCAN;
-- budgeted so it never starves the AP poll loop. See known_bugs.txt.
-- ============================================================================
local _invis_books, _invis_cursor, _invis_n, _invis_epoch, _invis_uw = nil, 1, 0, nil, nil
local _invis_streak, _invis_dumped = {}, {}
local _invis_sw_shown, _invis_sw_notdrawn, _invis_sw_nearnd, _invis_sw_suspects = 0, 0, 0, 0
local INVIS_BUDGET = 400
local INVIS_STREAK = 3        -- consecutive NEAR shown-but-not-drawn scans before we call it a suspect
local INVIS_NEAR   = 2000.0   -- "near the player" radius (UE cm). Beyond this, not-drawn = normal cull
local INVIS_NEAR2  = INVIS_NEAR * INVIS_NEAR

local function _invis_scan_step()
    if not diag_on("BOOK_INVIS_SCAN") then return end
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._apply_safe and IA._book_valid_asset_idx and IA._asset_to_series
            and IA._compute_unwarded_set) then return end
    if _invis_books and (IA._world_epoch or 0) ~= (_invis_epoch or 0) then
        _invis_books = nil; _invis_streak = {}; _invis_dumped = {}
    end
    if not _invis_books or _invis_cursor > _invis_n then
        -- Sweep boundary: report (only if something was not-drawn), then reset snapshot + counters.
        if (_invis_sw_notdrawn or 0) > 0 or (_invis_sw_suspects or 0) > 0 then
            log(("[invis-scan] census: shown(bHidden=false)=%d notDrawn=%d nearNotDrawn=%d newSuspects=%d (of %d actors)"):format(
                _invis_sw_shown, _invis_sw_notdrawn, _invis_sw_nearnd, _invis_sw_suspects, _invis_n or 0))
        end
        _invis_books = FindAllOf("BP_GrabbingBook_C")
        _invis_n = 0; if _invis_books then pcall(function() _invis_n = #_invis_books end) end
        _invis_cursor = 1
        _invis_epoch = IA._world_epoch
        _invis_sw_shown, _invis_sw_notdrawn, _invis_sw_nearnd, _invis_sw_suspects = 0, 0, 0, 0
        -- GAME THREAD: cache the snapshot ref, never compute on this thread.
        _invis_uw = IA._unwarded_snapshot
        if _invis_n == 0 then return end
    end
    local uw = _invis_uw
    if not uw then return end
    -- Player location (once per pass). Far + not-drawn = normal cull; only NEAR + not-drawn is a
    -- suspect. No player loc -> px nil -> nothing near -> no suspects (safe no-op).
    local px, py, pz = nil, nil, nil
    do
        local pawn = FindFirstOf("BP_LibrarianCharacter_C")
        if pawn and pawn:IsValid() then
            pcall(function() local loc = pawn:K2_GetActorLocation(); px, py, pz = loc.X, loc.Y, loc.Z end)
        end
    end
    local last = math.min(_invis_cursor + INVIS_BUDGET - 1, _invis_n)
    for i = _invis_cursor, last do
        local b = _invis_books[i]
        if b and b:IsValid() then
            local aidx = IA._book_valid_asset_idx(b)
            local series = aidx and IA._asset_to_series[aidx]
            if series and uw[series] then
                local hid; pcall(function() hid = b.bHidden end)
                if hid == false then
                    _invis_sw_shown = _invis_sw_shown + 1
                    local ar; pcall(function() ar = b:WasRecentlyRendered(0.5) end)
                    local key; pcall(function() key = b:GetFullName() end)
                    if ar == false then
                        _invis_sw_notdrawn = _invis_sw_notdrawn + 1
                        -- Proximity gate: far + not-drawn = normal cull (ignore). Only NEAR books count.
                        local near = false
                        if px then
                            local bl; pcall(function() bl = b:K2_GetActorLocation() end)
                            if bl then
                                local dx, dy, dz = (bl.X or 0) - px, (bl.Y or 0) - py, (bl.Z or 0) - pz
                                if (dx*dx + dy*dy + dz*dz) < INVIS_NEAR2 then near = true end
                            end
                        end
                        if near and key then
                            _invis_sw_nearnd = _invis_sw_nearnd + 1
                            _invis_streak[key] = (_invis_streak[key] or 0) + 1
                            if _invis_streak[key] >= INVIS_STREAK and not _invis_dumped[key] then
                                _invis_dumped[key] = true
                                _invis_sw_suspects = _invis_sw_suspects + 1
                                log(("[invis-scan] *** SUSPECT *** series=%s streak=%d -- NEAR player + SHOWN but NOT drawn across %d scans; full dump follows:"):format(
                                    tostring(series), _invis_streak[key], _invis_streak[key]))
                                pcall(function() _bh_grab_check(b, "SCAN") end)
                            end
                        elseif key then
                            _invis_streak[key] = nil   -- far / no player loc -> not a suspect, clear streak
                        end
                    elseif key then
                        _invis_streak[key] = nil   -- drawn this scan -> not stuck, clear streak
                    end
                end
            end
        end
    end
    _invis_cursor = last + 1
end


-- Layer 3: hide warded book-pile shelves (HISM) + REVEAL on unlock. Each HISM = one series (via
-- the index mapping); hide = SetVisibility/SetHiddenInGame false + swap to M_APBookMask (originals
-- recorded first), REVEAL restores them. Runs every pass; cheap when nothing drifted.
-- CRASH RULE: a MID on the book HISM crashes this game -- never reintroduce CreateDynamicMaterial*.
local _b2_state = {}        -- [hi] = { hidden = bool, ns = N, mats = {[s] = origMaterial} }
local _b2_last_sig = nil
local _b2_running = false
local _b2_load_requested = false
local _b2_mat_ref = nil
-- Spatial vote-accumulation classifier (used only by the disabled cross-check below).
local _b2_group = {}   -- [hi] = { tally={series:count}, total, leader, leadn, locked }
-- Spatial cross-check, DISABLED: the index mapping (series = _asset_to_series[hi-1]) proved
-- correct on fresh + resumed saves and drives visibility alone. Flip true to re-run the spatial
-- classifier as a ground-truth comparison (e.g. to re-confirm HISM<->data order after a patch).
local B2_SPATIAL_CROSSCHECK = false
local function apply_book_visibility()
    if not diag_on("BOOK_VISIBILITY") then return end
    if _b2_running then return end
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._compute_unwarded_set and IA._asset_to_series) then return end
    -- stacks mode: leave the pile visible (warding is layer-1 collision-off only); skip pile hiding.
    -- (==false so a nil mode before slot_data arrives still runs the hide path.)
    if IA._book_hide_mode == false then return end
    -- Snapshot the world epoch (bumped by reset_hism_state each LoadMap). The game-thread chunk
    -- re-checks it before touching the captured HISM array: if the world reloaded, the freed
    -- arr[hi] is a native AV pcall can't catch (the main-menu teardown crash).
    local epoch0 = IA._world_epoch
    -- Cache the world-stable scan targets per world epoch. Each FindFirstOf / StaticFindObject walks the
    -- whole (huge) GUObjectArray (~3-4ms); doing 3-4 of them every 5s was the L3 setup hitch. Re-scan only
    -- when the cached object was freed (streaming) or the world reloaded (epoch bump).
    if _l3c_ep ~= (epoch0 or 0) then _l3c_ep = epoch0 or 0; _l3c_mgr = nil; _l3c_mat = nil; _l3c_ready = false end
    local mgr = _l3c_mgr
    if not (mgr and mgr:IsValid()) then mgr = FindFirstOf("BP_HISM_Manager_C"); _l3c_mgr = mgr end
    if not (mgr and mgr:IsValid()) then return end
    local arr = nil; pcall(function() arr = mgr.HISMArray end)
    local hn = 0; if arr then pcall(function() hn = #arr end) end
    if hn == 0 then return end
    -- Ready-check (cached once true): only ONE book's ItemInfo matters. The full book list is only used
    -- by the DISABLED spatial cross-check, so fetch it lazily under that flag; otherwise a single probe.
    local books, bn = nil, 0
    if B2_SPATIAL_CROSSCHECK then
        books = FindAllOf("BP_GrabbingBook_C")
        if not books then return end
        pcall(function() bn = #books end)
        if bn == 0 then return end
    end
    if not _l3c_ready then
        local rb = (B2_SPATIAL_CROSSCHECK and books and books[1]) or FindFirstOf("BP_GrabbingBook_C")
        if not (rb and rb:IsValid()) then return end
        local rok = false
        pcall(function() local info = rb.ItemInfo; if info and info:IsValid() then rok = true end end)
        if not rok then return end
        _l3c_ready = true
    end
    -- Mask material (cached): M_APBookMask is unreferenced, so it must be hard-ref'd by ModActor's
    -- BookMaskMat var to load; read it there, fallback StaticFindObject. Scan only until found.
    local mat = _l3c_mat
    if not (mat and mat:IsValid()) then
        local ma = FindFirstOf("ModActor_C")
        if ma and ma:IsValid() then pcall(function() mat = ma.BookMaskMat end) end
        if not (mat and mat:IsValid()) then
            pcall(function() mat = StaticFindObject("/Game/Mods/LibrarianAPHUDFix/M_APBookMask.M_APBookMask") end)
        end
        if not (mat and mat:IsValid()) then
            if not _b2_load_requested then
                _b2_load_requested = true
                log("[b2] M_APBookMask not available yet (add ModActor Material var 'BookMaskMat' = M_APBookMask, recook); will retry")
            end
            return
        end
        _l3c_mat = mat
    end
    _b2_mat_ref = mat  -- pin against GC
    -- Re-classify on EVERY call, not just on unwarded-set change: the actor<->HISM swap can drift
    -- a group's classification, so an unwarded book's instance lands in a hidden group and vanishes;
    -- re-running self-corrects within a pass. Cheap at steady state (reads only). sig labels the log.
    local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
    local unwarded = IA._compute_unwarded_set(only_shelfable) or {}
    local skeys = {}
    for k in pairs(unwarded) do skeys[#skeys + 1] = k end
    table.sort(skeys)
    local sig = #skeys .. ":" .. table.concat(skeys, "|")
    local sig_changed = (sig ~= _b2_last_sig)
    _b2_last_sig = sig
    _b2_running = true
    -- 2D nearest-match (X,Y only): HISM instance transforms are component-LOCAL, so their Z doesn't
    -- match the actor's WORLD Z. Stacked books share X,Y (minor ambiguity) but all get classified.
    local CELL = 25.0
    local function gkey(ix, iy) return ix .. "_" .. iy end
    local grid = {}
    if B2_SPATIAL_CROSSCHECK then   -- only the cross-check needs the actor-position grid
    for i = 1, bn do
        local b = books[i]
        if b and b:IsValid() then
            local loc; pcall(function() loc = b:K2_GetActorLocation() end)
            local info; pcall(function() info = b.ItemInfo end)
            local ai; if info and info:IsValid() then pcall(function() ai = info.AssetIdx end) end
            local x, y
            if loc then pcall(function() x = loc.X end); pcall(function() y = loc.Y end) end
            if x and y and ai ~= nil then
                local ser = IA._asset_to_series[ai]
                local k = gkey(math.floor(x / CELL), math.floor(y / CELL))
                local cell = grid[k]; if not cell then cell = {}; grid[k] = cell end
                cell[#cell + 1] = { x = x, y = y, warded = not (ser and unwarded[ser]), series = ser }
            end
        end
    end
    end
    local function nearest_entry(px, py)
        local cx, cy = math.floor(px / CELL), math.floor(py / CELL)
        local best, bd2 = nil, CELL * CELL
        for dx = -1, 1 do for dy = -1, 1 do
            local cell = grid[gkey(cx + dx, cy + dy)]
            if cell then
                for _, e in ipairs(cell) do
                    local ex, ey = e.x - px, e.y - py
                    local d2 = ex * ex + ey * ey
                    if d2 <= bd2 then bd2 = d2; best = e end
                end
            end
        end end
        return best
    end
    -- ONE ExecuteInGameThread per pass (CHUNK = hn does all HISMs in one game-thread call). Many
    -- marshals/pass trip UE4SS #1180 (overlapping engine-tick actions -> abort). Cost: one ~400-HISM
    -- tick, a brief hitch on connect / set-change. Chunking only existed to pump the async poll loop.
    local cursor, CHUNK = 1, (POLL_GT and 40 or hn)  -- single-thread: 40 HISMs/frame (spread the ~400 over ~10 frames); legacy = one pass
    local newly_hidden, revealed, kept_hidden, kept_shown = 0, 0, 0, 0
    local n_new_hide, mismatch, leader_changed, n_locked = 0, 0, 0, 0
    -- run_chunk forward-declared so process_chunk can reschedule through it (upvalue must exist
    -- first). process_chunk = one chunk of HISM work; run_chunk = the game-thread driver.
    local run_chunk
    local function process_chunk()
        -- Teardown guard: if the world reloaded since this pass was scheduled (epoch changed), the
        -- captured arr/HISMs are freed and arr[hi] is a native AV pcall can't catch. Bail untouched.
        if (IA._world_epoch or 0) ~= (epoch0 or 0) then
            _b2_running = false; _l3_resume = nil
            trace.mark("b2-stale-world", nil,
                "epoch " .. tostring(epoch0) .. " -> " .. tostring(IA._world_epoch))
            return
        end
        -- Streaming backstop: the HISM manager can be freed by a sublevel unload MID-PASS (no LoadMap,
        -- so neither the epoch bump nor the LoadMap pre-hook fires). `arr` is bound to mgr.HISMArray, so
        -- a freed mgr makes arr[hi] a native AV the per-element IsValid can't prevent. Re-validate the
        -- captured mgr live each chunk before indexing, and re-read the current length so a shrunk array
        -- can't OOB. IsValid() checks the GUObjectArray slot+serial (UAF-safe); a freed mgr -> bail.
        if not (mgr and mgr:IsValid()) then
            _b2_running = false; _l3_resume = nil
            trace.mark("b2-mgr-gone", nil, "HISM manager freed mid-pass -> released layer-3 lock")
            return
        end
        local cur_hn = hn; pcall(function() cur_hn = #arr end)
        local last = math.min(cursor + CHUNK - 1, cur_hn)
        for hi = cursor, last do
            local h; pcall(function() h = arr[hi] end)
            if h and h:IsValid() then
                local sm; pcall(function() sm = h.PerInstanceSMData end)
                local sn = 0; if sm then pcall(function() sn = #sm end) end
                -- DRIVER: the index mapping. hi == the series' position in the data order, so the
                -- hi-th HISM's series is _asset_to_series[hi-1]. Deterministic, resume-safe, no warm-up.
                local idx_series = IA._asset_to_series[hi - 1]
                local should_hide_new
                if sn == 0 then should_hide_new = false
                elseif idx_series == nil then should_hide_new = true   -- mapping not populated yet -> assume warded
                else should_hide_new = (not unwarded[idx_series]) end
                if should_hide_new then n_new_hide = n_new_hide + 1 end

                -- SPATIAL CROSS-CHECK -- DISABLED. Per-instance nearest-actor vote + size-aware lock
                -- + index-vs-spatial mismatch log; flip the flag on to re-validate the data order.
                if B2_SPATIAL_CROSSCHECK then
                    local nw, nu = 0, 0
                    local votes = {}
                    for j = 1, sn do
                        local t; pcall(function() t = sm[j].Transform end)
                        local wp; if t then pcall(function() wp = t.WPlane end) end
                        local e
                        if wp then
                            local x, y; pcall(function() x = wp.X end); pcall(function() y = wp.Y end)
                            if x and y then e = nearest_entry(x, y) end
                        end
                        if e then
                            if e.warded then nw = nw + 1 else nu = nu + 1 end
                            if e.series then votes[e.series] = (votes[e.series] or 0) + 1 end
                        else
                            nw = nw + 1   -- no nearby actor -> treat as warded
                        end
                    end
                    local g = _b2_group[hi]
                    if not g then g = { tally = {}, total = 0, leader = nil, leadn = 0, locked = false, sn = sn }; _b2_group[hi] = g end
                    if not g.locked then
                        g.sn = sn
                        for s, c in pairs(votes) do g.tally[s] = (g.tally[s] or 0) + c; g.total = g.total + c end
                        local leader, leadn = nil, 0
                        for s, c in pairs(g.tally) do if c > leadn then leader = s; leadn = c end end
                        if leader ~= g.leader and g.leader ~= nil then leader_changed = leader_changed + 1 end
                        g.leader = leader; g.leadn = leadn
                        -- size-aware lock: ~3 passes' worth of votes for ANY size.
                        if leadn >= 3 * sn and leadn * 10 >= g.total * 7 then
                            g.locked = true; n_locked = n_locked + 1
                        end
                    end
                    local hser = g.leader
                    if idx_series ~= nil and hser ~= nil and idx_series ~= hser then
                        mismatch = mismatch + 1
                        if mismatch <= 20 then
                            log(("[b2-cmp] MISMATCH hi=%d index=%s spatial=%s (leader %d/%d)"):format(
                                hi, tostring(idx_series), tostring(hser), g.leadn, g.total))
                        end
                    end
                end

                local should_hide = should_hide_new
                local st = _b2_state[hi]; if not st then st = { hidden = false }; _b2_state[hi] = st end
                if should_hide and not st.hidden then
                    trace.begin("b2-hide", h)
                    local ns = 1; pcall(function() ns = h:GetNumMaterials() end)
                    st.ns = ns; st.mats = {}
                    for s = 0, (ns or 1) - 1 do local m; pcall(function() m = h:GetMaterial(s) end); st.mats[s] = m end
                    pcall(function() h:SetVisibility(false, false) end)
                    pcall(function() h:SetHiddenInGame(true, false) end)
                    if diag_on("HISM_SETMATERIAL") then
                        for s = 0, (ns or 1) - 1 do pcall(function() h:SetMaterial(s, mat) end) end
                    end
                    -- Do NOT touch PerInstanceCustomData: index 0 carries the game's per-book
                    -- color; overwriting corrupts books on reveal. SetVisibility does the hiding.
                    trace.finish("b2-hide", h)
                    st.hidden = true; newly_hidden = newly_hidden + 1
                elseif (not should_hide) and st.hidden then
                    trace.begin("b2-reveal", h)
                    pcall(function() h:SetVisibility(true, false) end)
                    pcall(function() h:SetHiddenInGame(false, false) end)
                    if st.mats and diag_on("HISM_SETMATERIAL") then
                        for s = 0, (st.ns or 1) - 1 do
                            local m = st.mats[s]; if m then pcall(function() h:SetMaterial(s, m) end) end
                        end
                    end
                    trace.finish("b2-reveal", h)
                    st.hidden = false; revealed = revealed + 1
                elseif st.hidden then
                    kept_hidden = kept_hidden + 1
                else
                    kept_shown = kept_shown + 1
                end
            end
        end
        cursor = last + 1
        if cursor <= cur_hn then
            -- Single-thread: process ONE small chunk per pawn-tick frame (the master scheduler calls
            -- _l3_resume) so the ~400-HISM pass spreads over frames instead of hitching one. Legacy
            -- path keeps the LoopAsync chunk pacing.
            if POLL_GT then _l3_resume = run_chunk else LoopAsync(50, function() run_chunk() return true end) end
        else
            _l3_resume = nil
            _b2_running = false
            -- Log only when something changed or the cross-check disagrees.
            if sig_changed or (newly_hidden + revealed) > 0 or mismatch > 0 or leader_changed > 0 or n_locked > 0 then
                log(("[b2] applied: newly_hidden=%d revealed=%d kept_hidden=%d kept_shown=%d / %d HISMs"):format(
                    newly_hidden, revealed, kept_hidden, kept_shown, hn))
                if B2_SPATIAL_CROSSCHECK then
                    local cached, locked, clean_unlocked = 0, 0, 0
                    local splits = {}
                    for hi2, g in pairs(_b2_group) do
                        if g.leader ~= nil then cached = cached + 1 end
                        if g.locked then locked = locked + 1
                        elseif g.total and g.total > 0 and g.leadn * 10 < g.total * 7 then splits[#splits + 1] = { hi = hi2, g = g }
                        else clean_unlocked = clean_unlocked + 1 end
                    end
                    log(("[b2-cmp] index-driver hides=%d | index-vs-spatial mismatches=%d | spatial cached=%d locked=%d/%d (corrections=%d newly-locked=%d)"):format(
                        n_new_hide, mismatch, cached, locked, hn, leader_changed, n_locked))
                    -- Split unlocked groups into SPLIT (leader <70% = conflated, leak risk) vs clean
                    -- (just under-sampled); list the split ones.
                    if #splits > 0 then
                        log(("[b2-cmp] unlocked breakdown: split/conflated=%d clean=%d -- listing split (residual-risk groups):"):format(#splits, clean_unlocked))
                        for i = 1, math.min(#splits, 12) do
                            local e = splits[i]; local gg = e.g
                            log(("[b2-cmp]   SPLIT hi=%d size=%s leader=%s %d%% (%d/%d votes)"):format(
                                e.hi, tostring(gg.sn), tostring(gg.leader), math.floor(gg.leadn * 100 / gg.total), gg.leadn, gg.total))
                        end
                    else
                        log(("[b2-cmp] unlocked breakdown: split/conflated=0 clean=%d (all benign, just under-sampled)"):format(clean_unlocked))
                    end
                end
            end
        end
    end
    -- Driver: run process_chunk's HISM work on the game thread. Reschedules via LoopAsync so we
    -- never nest ExecuteInGameThread calls (UE4SS #1180). MUST clear _b2_running on error -- a
    -- stuck flag wedges layer 3 permanently (every later pass early-returns on it).
    run_chunk = function()
        on_game_thread(function()
            local ok, err = pcall(process_chunk)
            if not ok then
                _b2_running = false
                _l3_resume = nil
                trace.mark("b2-chunk-error", nil, tostring(err))
                log("[b2] chunk error -> cleared _b2_running: " .. tostring(err))
            end
        end)
    end
    if sig_changed then
        log("[b2] unwarded-set change -> re-evaluate (NEW drives off cached series, OLD logged for comparison)")
    end
    -- Single-thread: defer even the FIRST chunk to the master scheduler so the maintenance frame does
    -- only L3 setup (the 40-HISM chunk was ~8ms of the 5s hitch); all chunks then spread across frames.
    if POLL_GT then _l3_resume = run_chunk else run_chunk() end
end


-- Emit a lifecycle state-machine event. No-op until the SM module loads.
-- Observational only: drives [lifecycle] logging, gates nothing yet.
local function lc_event(name)
    pcall(function()
        local L = package.loaded["AP/lifecycle"]
        if L and L[name] then L[name]() end
    end)
end

log("Loading Librarian-AP")

-- Native level-up grants a free skill point; invalid for AP (skills come via AP items),
-- so zero EnableUpgradeNum on each OnLevelUp.
local suppress_levelup = true

-- ============================================================
-- AP integration state
-- ============================================================

-- Set true around AP-delivered UpgradePlayer calls so the UpgradePlayer hook
-- doesn't echo the call back as a "key pickup" location check.
local _ap_grant = false

-- AP location ID layout (mirrors apworld/librarian/Locations.py). main.lua only needs the
-- chest-opening IDs (ItemApply owns row/level/milestone); the UpgradePlayer hook lives here.
local AP_BASE = 1910000
local AP_LOC_CHEST_CRIMSON = AP_BASE + 620
local AP_LOC_CHEST_EMERALD = AP_BASE + 621
local AP_LOC_CHEST_AZURE   = AP_BASE + 622
local AP_LOC_CHEST_GOLDEN  = AP_BASE + 623

-- ability index -> chest-opening location id
local AP_CHEST_LOC_BY_ABILITY = {
    [0] = AP_LOC_CHEST_CRIMSON,  -- Jump        (Crimson Octagon chest)
    [4] = AP_LOC_CHEST_EMERALD,  -- Jogging     (Emerald Club chest)
    [1] = AP_LOC_CHEST_AZURE,    -- UpgradeBag  (Azure Star chest)
    [2] = AP_LOC_CHEST_GOLDEN,   -- UpgradeBag2 (Golden Diamond chest)
}

-- ============================================================
-- Save slot redirection
-- ============================================================
-- GameInstance.SaveGameName is the SaveGameToSlot/LoadGameFromSlot slot (default "Sav").
-- For AP runs we point it at "Sav_AP_<seed>_<slot>" so each seed has its own save file.

local DEFAULT_SAVE_SLOT = "Sav"
local _original_save_slot = nil  -- captured the first time we redirect

-- Sanitize for use in a filename: keep alphanum + _, replace others with _.
local function sanitize_slot(s)
    s = tostring(s or "")
    return (s:gsub("[^%w_]", "_"))
end

local function find_game_instance()
    local gi = FindFirstOf("BP_LibrarianGameInstance_C")
    if gi and gi:IsValid() then return gi end
    gi = FindFirstOf("LibrarianGameInstanceBase")
    if gi and gi:IsValid() then return gi end
    return nil
end

local function read_save_slot()
    local gi = find_game_instance()
    if not gi then return nil end
    local s
    pcall(function() s = gi.SaveGameName:ToString() end)
    return s
end

local function set_save_slot(name)
    local gi = find_game_instance()
    if not gi then
        log("[AP][save] cannot set slot — GameInstance not found")
        return false
    end
    local before = read_save_slot()
    if _original_save_slot == nil then
        _original_save_slot = before or DEFAULT_SAVE_SLOT
    end
    local ok, err = pcall(function() gi.SaveGameName = name end)
    if not ok then
        log(("[AP][save] FAILED to set SaveGameName: %s"):format(tostring(err)))
        return false
    end
    local after = read_save_slot()
    log(("[AP][save] SaveGameName: %s -> %s (read-back: %s)"):format(
        tostring(before), tostring(name), tostring(after)))
    return true
end

local function restore_save_slot()
    local target = _original_save_slot or DEFAULT_SAVE_SLOT
    set_save_slot(target)
end

-- Fingerprint the in-memory GameSaveData (rows/books/bgm) to confirm a forced reload swapped it.
local function snapshot_save_data()
    local gi = find_game_instance()
    if not gi then return "<no-gameinstance>" end
    local sg
    pcall(function() sg = gi.GameSaveData end)
    if not sg then return "<no-savegamedata>" end
    local valid = false
    pcall(function() valid = sg:IsValid() end)
    if not valid then return "<invalid>" end
    local rows, books, bgm = "?", "?", "?"
    pcall(function() rows  = tostring(sg.GameProgressData.CurrentFinishedRowNum) end)
    pcall(function() books = tostring(sg.GameProgressData.InsertedBookNum) end)
    pcall(function() bgm   = tostring(sg.BGMIdx) end)
    return ("valid: rows=%s books=%s bgm=%s"):format(rows, books, bgm)
end

-- ============================================================
-- Title-screen button gating
-- ============================================================
-- Disable Start Game / Continue while not AP-connected. After connect:
--   - Continue enabled iff Sav_AP_<seed>_<slot>.sav exists.
--   - Start Game enabled iff that save does NOT exist (fresh AP run).
-- Other title buttons are left alone.

local function ap_save_exists(slot_name)
    if not slot_name or slot_name == "" then return false end
    local appdata = os.getenv("LOCALAPPDATA")
    if not appdata or appdata == "" then return false end
    local path = appdata .. "\\Librarian\\Saved\\SaveGames\\" .. slot_name .. ".sav"
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function find_title_widget()
    local widgets = FindAllOf("WBP_Title_C")
    if not widgets then return nil end
    local n = 0
    pcall(function() n = #widgets end)
    for i = 1, n do
        local w = widgets[i]
        if w and w:IsValid() then return w end
    end
    return nil
end

local function set_button_enabled(btn, enabled)
    if not btn then return end
    local valid = false
    pcall(function() valid = btn:IsValid() end)
    if not valid then return end
    pcall(function() btn:SetIsEnabled(enabled) end)
end

-- Vanilla latch: set when the player clicks Close on the AP window. Restores the real
-- Continue/New Game buttons and gates off every gameplay mod (fully passive). One-way:
-- only relaunching re-enables connecting.
local _vanilla_mode = false

local function update_title_buttons()
    local widget = find_title_widget()
    if not widget then return end  -- not at title screen

    local APClient = package.loaded["AP/APClient"]
    local connected = APClient and APClient._slot_connected

    local enable_continue, enable_start = false, false

    if connected then
        local IA = package.loaded["AP/ItemApply"]
        -- Keep Continue/New Game disabled until the world is fully READY: items pre-applied
        -- (_pre_apply_complete) AND the bookcases finished streaming + warding (_ward_settled). Entering
        -- before the shelves are warded shows an un-warded world for a beat; gating the buttons on both
        -- means the player only enters a world that's already warded (lights then come on right after).
        local not_ready = IA and IA._allow_pre_apply and (not IA._pre_apply_complete or not IA._ward_settled)
        if not_ready then
            log(("[title-buttons] connected; not ready (pre_apply=%s ward_settled=%s) → buttons disabled"):format(
                tostring(IA and IA._pre_apply_complete), tostring(IA and IA._ward_settled)))
        else
            local current_slot = read_save_slot()
            local has_save = ap_save_exists(current_slot)
            enable_continue = has_save
            enable_start = not has_save
            log(("[title-buttons] connected; slot='%s' save_exists=%s → continue=%s start=%s"):format(
                tostring(current_slot), tostring(has_save),
                tostring(enable_continue), tostring(enable_start)))
        end
    elseif _vanilla_mode then
        -- Vanilla (Close clicked): restore base-game button behavior -- Continue if
        -- the player's (non-AP) save exists, New Game always. Mod stays passive.
        local vanilla_slot = read_save_slot()
        enable_continue = ap_save_exists(vanilla_slot)
        enable_start = true
        log(("[title-buttons] vanilla — continue=%s start=true (slot='%s')"):format(
            tostring(enable_continue), tostring(vanilla_slot)))
    else
        log("[title-buttons] not connected; both gameplay buttons disabled")
    end

    pcall(function() set_button_enabled(widget.Button_LoadGame, enable_continue) end)
    pcall(function() set_button_enabled(widget.Button_StartGame, enable_start) end)
end

-- Latch Vanilla mode. Called from the BroadcastCloseRequest hook via the global
-- _librarian_menu table (hook callbacks can't see this file's locals).
local function enter_vanilla_mode()
    if _vanilla_mode then return end
    _vanilla_mode = true
    log("[menu] Close clicked — VANILLA mode latched; mod passive until relaunch")
    if _G._librarian_menu and _G._librarian_menu.hide then
        pcall(function() _G._librarian_menu.hide() end)
    end
    pcall(function() update_title_buttons() end)
end

-- ============================================================
-- Title-screen status text hijack
-- ============================================================
-- WBP_Title.Text_Version (bottom-right) becomes "<Game v> | LibAP vX.YY | AP: <state>".
-- Append "(UNTESTED)" when the game version isn't in TESTED_GAME_VERSIONS.

local MOD_VERSION = "1.1.0"
local TESTED_GAME_VERSIONS = { "1.0.8", "1.0.9", "1.0.11" }

local function get_game_version()
    local gi = find_game_instance()
    if not gi then return nil end
    local v
    pcall(function() v = gi:GetProjectVersion():ToString() end)
    return v
end

local function is_tested_version(v)
    if not v or v == "" then return false end
    for _, t in ipairs(TESTED_GAME_VERSIONS) do
        if v == t then return true end
    end
    return false
end

local function compose_title_status_text()
    local game_v = get_game_version() or "?"
    local tested = is_tested_version(game_v)
    local game_part = "Game v" .. game_v .. (tested and "" or " (UNTESTED)")

    local APClient = package.loaded["AP/APClient"]
    local IA = package.loaded["AP/ItemApply"]
    local ap_part
    if APClient and APClient._slot_connected then
        if IA and IA._allow_pre_apply and not IA._pre_apply_complete then
            ap_part = "AP: preparing world..."
        else
            ap_part = "AP: connected as " .. tostring(APClient.slot or "?")
        end
    else
        ap_part = "AP: not connected"
    end

    return string.format("%s | LibAP v%s | %s", game_part, MOD_VERSION, ap_part)
end

-- Logging-only: tv:SetText(luaString) crashes (UE wants an FText UE4SS Lua won't auto-wrap).
-- Composing + reading is safe; a real overwrite needs a companion UMG widget BP.
local function update_title_status_text()
    local widget = find_title_widget()
    if not widget then return end
    local tv
    pcall(function() tv = widget.Text_Version end)
    if not tv then return end
    local valid = false
    pcall(function() valid = tv:IsValid() end)
    if not valid then return end
    local text = compose_title_status_text()
    -- Read existing for diagnostics; show what we'd write.
    local current
    pcall(function() current = tv.Text:ToString() end)
    log(("[title-text] would set Text_Version: '%s' (currently: '%s')"):format(
        text, tostring(current)))
end

-- Via package.loaded so callable before the require() at the bottom resolves (hooks fire later).
local function ap_send_check(loc_id)
    local c = package.loaded["AP/APClient"]
    if c and c.send_check then c:send_check(loc_id) end
end

local function ap_send_goal()
    local c = package.loaded["AP/APClient"]
    if c and c.set_status and c.STATUS_GOAL then
        c:set_status(c.STATUS_GOAL)
    end
end

-- EUpgradeAbility (from CXXHeaderDump/Librarian_enums.hpp)
local EUpgradeAbility = {
    [0] = "Jump",
    [1] = "UpgradeBag",
    [2] = "UpgradeBag2",
    [3] = "ShowMatchingShelf",
    [4] = "Jogging",
    [5] = "SortBooks",
    [6] = "AutoShelve",
    [7] = "ShowSameTypeBook",
    [8] = "GrabSameTypeBook",
}

local function ability_name(idx)
    return EUpgradeAbility[idx] or ("?" .. tostring(idx))
end

local function safe_name(obj)
    if not obj then return "<nil>" end
    local ok, valid = pcall(function() return obj:IsValid() end)
    if not ok or not valid then return "<invalid>" end
    local ok2, name = pcall(function() return obj:GetFullName() end)
    return ok2 and name or "<err>"
end

local function safe_class(obj)
    if not obj then return "?" end
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and name or "?"
end

local function dump_num_array(arr)
    if not arr then return "<nil>" end
    local n = 0
    pcall(function() n = #arr end)
    if n == 0 then return "[]" end
    local parts = {}
    for i = 1, n do parts[i] = tostring(arr[i]) end
    return "[" .. table.concat(parts, ", ") .. "]"
end


-- ============================================================
-- HOOK: LoadMap → poll until player exists, then probe once
-- ============================================================
local register_bp_hooks_once  -- forward declaration; defined below

-- M01 LoadMap counter. Title loads M01 once (background); New Game forces a 2nd load -> 2nd+
-- M01 load = gameplay. Continue reuses the title's M01 (no 2nd load), so the SelectedLevel
-- watcher below catches that path too. activate_gameplay is idempotent, so both can converge.
local m01_load_count = 0
-- Set just before our forced OpenLevel(PL_M01) on connect; cleared by the next M01 LoadMap.
-- Tells the handler NOT to count that load as gameplay (user is still at the title).
local _suppress_next_m01_load_count = false
local _gameplay_loops_started = false
local _pre_apply_settle_state = nil  -- {empty_ticks, reapplies_done} during pre-apply settle
local _reconnect_settle_state = nil  -- {last_item_tick, quiet_ticks, total_ticks} during mid-game reconnect

local function start_gameplay_loops()
    if _gameplay_loops_started then return end
    _gameplay_loops_started = true

    -- Fast world-ready poller (gates the Continue/New Game buttons ONLY -- never warding, which is now
    -- mid-stream-safe). Poll the live BookCase count at 1s; once it holds steady (streaming done) or a
    -- hard cap (soft-lock guard), latch M._ward_settled, force one full bookcase-ward pass so the shelves
    -- are done, then re-enable the title buttons. Runs behind the title menu, so by the time the buttons
    -- light up the world is fully streamed + warded. Stops once latched. (This poller drove a CRASH when
    -- it gated WARDING; now warding is safe regardless of timing, so it only affects button enablement.)
    gt_loop("ward_ready_fast", 1000, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        if IA._ward_settled then return true end                 -- already ready -> stop
        if not (IA._gameplay_active or IA._allow_pre_apply) then return false end
        IA._fast_total = (IA._fast_total or 0) + 1
        local live = FindAllOf("BookCaseBase")
        local n = 0; if live then pcall(function() n = #live end) end
        if n > 0 and n == (IA._fast_prev_case_n or -1) then
            IA._fast_stable = (IA._fast_stable or 0) + 1
        else
            IA._fast_stable = 0
        end
        IA._fast_prev_case_n = n
        if (n > 0 and (IA._fast_stable or 0) >= 3) or (IA._fast_total or 0) >= 30 then
            IA._ward_settled = true
            IA._ward_ground_truth_due = true                      -- force a full ward pass so shelves are done...
            pcall(function() IA._apply_bookcases_to_world() end)  -- ...before the buttons enable
            log(("[ward-ready] %d bookcases stable -> world warded, enabling Continue/New Game"):format(n))
            pcall(function() update_title_buttons() end)
            return true                                           -- stop the poller
        end
        return false
    end)

    -- Apply-gate retry loop: wait for books to fully populate before mutating
    -- the world. Cheap once gate passes (returns true immediately).
    local APPLY_MIN_TICKS    = 10   -- 5s of grace before mutating
    local APPLY_MIN_BOOKS    = 1000
    local APPLY_SAMPLE_SIZE  = 50
    local APPLY_MIN_DISTINCT = 5
    local APPLY_GIVEUP_TICKS = 40   -- 20s

    local apply_attempts = 0
    gt_loop("apply_gate", 500, function()
        apply_attempts = apply_attempts + 1
        local books = FindAllOf("BP_GrabbingBook_C")
        local n = 0
        pcall(function() n = #books end)

        local enough_books = n >= APPLY_MIN_BOOKS

        local distinct = 0
        if enough_books then
            local sample = {}
            for i = 1, math.min(APPLY_SAMPLE_SIZE, n) do
                local b = books[i]
                if b and b:IsValid() then
                    -- Split the ItemInfo access: a chained b.ItemInfo.AssetIdx hands a stale
                    -- sub-UObject to UE4SS and crashes before pcall can catch it.
                    local item_info
                    pcall(function() item_info = b.ItemInfo end)
                    if item_info and item_info:IsValid() then
                        local idx
                        pcall(function() idx = item_info.AssetIdx end)
                        if idx and idx > 0 and not sample[idx] then
                            sample[idx] = true
                            distinct = distinct + 1
                        end
                    end
                end
            end
        end

        local enough_ticks    = apply_attempts >= APPLY_MIN_TICKS
        local enough_distinct = distinct >= APPLY_MIN_DISTINCT
        local ready = enough_books and enough_distinct and enough_ticks

        if not ready then
            if apply_attempts >= APPLY_GIVEUP_TICKS then
                log(("LoadMap apply-gate → giving up after %d attempts (books=%d distinct=%d ticks_ok=%s) — marking apply-safe anyway so pre-apply completes")
                    :format(apply_attempts, n, distinct, tostring(enough_ticks)))
                -- Unblock the downstream pipeline exactly like the PASS path below: preapply_settle waits
                -- on _apply_safe, and the Continue/New Game buttons gate on _pre_apply_complete (which only
                -- latches after that). Silently dropping the pipeline here would leave the menu
                -- unenterable forever (the apply-gate/settle giveup contracts were inconsistent).
                local IA = package.loaded["AP/ItemApply"]
                if IA and IA.set_apply_safe then
                    pcall(function() IA.set_apply_safe(true) end)
                    lc_event("on_world_ready")
                    if IA._gameplay_active then pcall(function() IA.flush_apply() end) end
                end
                return true
            end
            if apply_attempts % 4 == 0 then
                log(("LoadMap apply-gate waiting: books=%d/%d distinct=%d/%d ticks=%d/%d")
                    :format(n, APPLY_MIN_BOOKS, distinct, APPLY_MIN_DISTINCT,
                            apply_attempts, APPLY_MIN_TICKS))
            end
            return false
        end

        local IA = package.loaded["AP/ItemApply"]
        if IA and IA.set_apply_safe then
            log(("LoadMap apply-gate PASSED (books=%d distinct=%d ticks=%d) → set_apply_safe (flush deferred to settle loop)")
                :format(n, distinct, apply_attempts))
            pcall(function() IA.set_apply_safe(true) end)
            lc_event("on_world_ready")  -- world populated → CONNECTING→PRE_APPLY
            -- Pre-apply path defers flush to the settle loop below; gameplay-active flushes now.
            if IA._gameplay_active then
                pcall(function() IA.flush_apply() end)
            end
        end
        return true
    end)

    -- Pre-apply settle loop. Runs only during the post-connect title phase.
    -- Three phases:
    --   1. Wait for the starting-item dump to quiet down (_last_item_apply_tick
    --      stable for ~1s) AND apply_safe to be true.
    --   2. Fire ONE flush_apply with final state (single warding pass).
    --   3. Wait for the deferred tree-walk queue to drain + a short settle.
    --      Then mark _pre_apply_complete and re-enable Continue/Start.
    gt_loop("preapply_settle", 500, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        if not IA._allow_pre_apply then return true end
        if IA._pre_apply_complete then return true end
        if not IA._apply_safe then return false end

        if not _pre_apply_settle_state then
            _pre_apply_settle_state = {
                phase = "wait_items",   -- → "draining" → done
                last_item_tick = -1,
                quiet_ticks = 0,
                total_ticks = 0,
            }
        end
        local s = _pre_apply_settle_state

        if s.phase == "wait_items" then
            s.total_ticks = s.total_ticks + 1
            local cur = IA._last_item_apply_tick or 0
            if cur ~= s.last_item_tick then
                s.last_item_tick = cur
                s.quiet_ticks = 0
                return false
            end
            s.quiet_ticks = s.quiet_ticks + 1
            -- Proceed once items quiet for ≥2 ticks (1s) OR we've waited
            -- 10 ticks total (5s) — safety net so a slot with zero
            -- starting items doesn't deadlock the loop.
            if s.quiet_ticks >= 2 or s.total_ticks >= 10 then
                log(("[pre-apply] items quiet (%d items applied, %d ticks waited); firing single flush_apply"):format(
                    cur, s.total_ticks))
                pcall(function() IA.flush_apply() end)
                s.phase = "draining"
                s.quiet_ticks = 0
            end
            return false
        end

        if s.phase == "draining" then
            -- Hold the draining phase while the chunked Pass-1 flush is still running
            -- OR the ward pump still has queued/in-flight units — both are async, so the
            -- world isn't truly settled until each idles. The drain_ticks cap is a safety
            -- net: a wedged pump must not permanently soft-lock the title menu.
            s.drain_ticks = (s.drain_ticks or 0) + 1
            local pump_idle = (not IA._pump_idle) or IA._pump_idle()
            if (IA._flush_in_progress or not pump_idle) and s.drain_ticks < 30 then
                s.quiet_ticks = 0
                return false
            end
            s.quiet_ticks = s.quiet_ticks + 1
            -- 4 ticks × 500ms = 2s of empty queue → world settled.
            if s.quiet_ticks < 4 then return false end
            IA._pre_apply_complete = true
            _pre_apply_settle_state = nil
            log("[pre-apply] complete — enabling Continue/Start buttons")
            pcall(function() update_title_buttons() end)
            pcall(function() update_title_status_text() end)
            if _G._librarian_menu and _G._librarian_menu.set_status then
                _G._librarian_menu.set_status("World ready — click Continue", "ok")
            end
            local hud = package.loaded["AP/HUD"]
            if hud and hud.notify then
                hud.notify("AP: World ready — click Continue", 10.0)
            end
            return true
        end
        return false
    end)

    -- Reconnect-settle watcher. On a mid-gameplay reconnect (_reconnect_settle_active) the server
    -- re-sends every item one at a time; apply them all THEN flush once, else bookcases flicker as
    -- shelves_open[X] rebuilds from zero. Fires the single flush once the item storm quiets.
    gt_loop("reconnect_settle", 500, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        -- Die when we leave gameplay (same context check the 5s loop uses) so the next entry respawns it.
        if not (IA._gameplay_active or IA._allow_pre_apply) then
            _reconnect_settle_state = nil
            return true
        end

        if not IA._reconnect_settle_active then
            -- Idle: no reconnect storm in progress. Reset settle state
            -- so the NEXT reconnect starts the wait from scratch.
            _reconnect_settle_state = nil
            return false
        end

        if not _reconnect_settle_state then
            _reconnect_settle_state = {
                last_item_tick = -1,
                quiet_ticks = 0,
                total_ticks = 0,
            }
        end
        local s = _reconnect_settle_state
        s.total_ticks = s.total_ticks + 1

        local cur = IA._last_item_apply_tick or 0
        if cur ~= s.last_item_tick then
            s.last_item_tick = cur
            s.quiet_ticks = 0
            return false
        end
        s.quiet_ticks = s.quiet_ticks + 1

        -- Fire after items quiet ≥2 ticks (1s), or 10 ticks (5s) as a safety net; then clear the
        -- flag so apply_item resumes the per-item path.
        if s.quiet_ticks >= 2 or s.total_ticks >= 10 then
            log(("[reconnect-settle] items quiet (%d total apply ticks, %d settle ticks); firing single flush_apply"):format(
                cur, s.total_ticks))
            IA._reconnect_settle_active = false
            pcall(function() IA.flush_apply() end)
            _reconnect_settle_state = nil
        end
        return false
    end)

    -- Periodic re-index + force re-apply every 5s. The re-index catches
    -- bookcases that may have lazy-spawned. The force re-apply is a safety
    -- net for any visibility drift (rare but observed). Both are cheap.
    gt_loop("warding_maint", 5000, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        -- Keep running during the post-connect pre-apply window too, so
        -- bookcase drift is corrected in the background.
        if not (IA._gameplay_active or IA._allow_pre_apply) then
            _gameplay_loops_started = false   -- allow restart on next entry
            return true
        end
        if not IA._apply_safe then return false end
        -- Not during a flush: registering the book hooks installs SetActorVisible / SetBookInfo /
        -- CanBeGrab callbacks that _apply_one_book's own visibility and collision writes would then
        -- re-enter, nesting Lua inside the flush. It missed this window by timing rather than design.
        if not IA._flush_in_progress then
            pcall(try_register_book_hooks)   -- register the book hooks (one-shot, game thread)
        end
        pcall(bh_report_periodic)        -- ~30s [book-hook] count report
        pcall(function() IA.refresh_index_if_changed() end)   -- catch lazy-spawned bookcases
        pcall(function() IA._apply_bookcases_to_world() end)  -- Layer 2 bookcase ward
        pcall(apply_book_visibility)                          -- Layer 3 HISM pile mask
        -- Actor-state reconcile: Layer 3's continuous counterpart for the BP_GrabbingBook ACTOR.
        -- Re-asserts collision + SM_Book_1 mesh on unwarded books whose flags drifted (heals
        -- visible-not-grabbable + grabbable-invisible). Read-before-write, gated BOOK_ACTOR_RECONCILE.
        pcall(function() IA.reconcile_book_actors() end)
        pcall(_invis_scan_step)   -- passive invisible-book detector (off by default)
        return false
    end)

    -- Periodic milestone / level sync (3s). Book-placement milestones key off InsertedBookNum,
    -- which grows without finishing rows; the FinishRow hook would miss those until the next row.
    -- Level-ups are event-driven (OnLevelUp), so this poll is mostly milestones.
    gt_loop("sync", 3000, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        -- Stop only when fully out of gameplay/pre-apply (returning true ENDS the loop). Don't
        -- early-exit on _gameplay_active alone -- that kills the loop before gameplay starts.
        if not (IA._gameplay_active or IA._allow_pre_apply) then
            _gameplay_loops_started = false   -- allow restart on next entry
            return true
        end
        -- During pre-apply (title menu), keep the loop alive but skip the
        -- sync — InsertedBookNum / level data aren't meaningful yet.
        if not IA._gameplay_active then return false end
        if not IA._apply_safe then return false end
        if not IA._slot_data then return false end
        -- Drain OnLevelUp events deferred off the game thread (see the OnLevelUp hook). Run them on
        -- THIS mod thread before the sync so M._levels_reached is current.
        local _lvls = IA._pending_level_ups or 0
        if _lvls > 0 then
            IA._pending_level_ups = 0
            for _ = 1, _lvls do pcall(function() IA.on_level_up_event() end) end
        end
        pcall(function() IA.sync_progress_state() end)
        -- Re-run row-completion detection: FinishRow only fires when the row count INCREASES, so a
        -- swap (remove a completed series, refill the slot with another) goes undetected. Idempotent.
        pcall(function() IA.detect_completed_rows() end)
        -- Row-threshold catch-up: re-fire any "Complete N Rows" threshold the save shows reached
        -- (catches a run_baseline_sync that ran with stale GameSaveData). Idempotent.
        pcall(function()
            local rf = 0
            local gi = FindFirstOf("BP_LibrarianGameInstance_C")
                or FindFirstOf("LibrarianGameInstanceBase")
            if gi and gi:IsValid() then
                local sg = gi.GameSaveData
                if sg and sg:IsValid() then
                    rf = tonumber(sg.GameProgressData.CurrentFinishedRowNum) or 0
                end
            end
            if rf > 0 then IA.fire_row_completion_checks(rf) end
        end)
        -- Section-completion: a swap above may have closed out a section without a FinishRow. Idempotent.
        pcall(function() IA.fire_section_completions() end)
        -- Floor-completion: same, one granularity coarser. Idempotent.
        pcall(function() IA.fire_floor_completions() end)
        -- Skill resync: if save-side level lags received item count (a dropped UpgradePlayer),
        -- retry the missing applies. Never over-grants past received counts.
        pcall(function() IA.resync_skill_state() end)
        return false
    end)

    -- First-movement detection. At the title the previous save is still loaded, so GameSaveData
    -- reads stale (spurious milestone/level checks on a fresh New Game). Movement only becomes
    -- possible once the new save takes over in memory, so use it as the baseline-sync trigger.
    local title_pos = nil
    gt_loop("first_move", 500, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        if not IA._gameplay_active then return true end          -- exit on title return
        if IA._baseline_sync_done then return true end           -- already triggered
        if not IA._apply_safe then return false end              -- wait for world apply

        local player = FindFirstOf("BP_LibrarianCharacter_C")
        if not player or not player:IsValid() then return false end

        local pos
        pcall(function()
            local v = player:K2_GetActorLocation()
            pos = { x = v.X, y = v.Y, z = v.Z }
        end)
        if not pos then return false end

        if not title_pos then
            title_pos = pos
            log(("[gameplay] Snapshot title-state position (%.0f, %.0f, %.0f); waiting for first move"):format(
                pos.x, pos.y, pos.z))
            return false
        end

        local dx = pos.x - title_pos.x
        local dy = pos.y - title_pos.y
        local dz = pos.z - title_pos.z
        local dist2 = dx*dx + dy*dy + dz*dz
        if dist2 > 100 then  -- ~10 unreal units of movement (sqrt 100)
            log(("[gameplay] First movement detected (Δ=%.1f units) → running baseline sync"):format(
                math.sqrt(dist2)))
            pcall(function() IA.run_baseline_sync() end)
            return true  -- one-shot, exit loop
        end
        return false
    end)
end

local function activate_gameplay(reason)
    -- Only activate when AP-connected; otherwise (vanilla / not connected) stay fully passive.
    -- The single gate every activation path (button / SelectedLevel / LoadMap) funnels through.
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient._slot_connected) then
        log(("activate_gameplay skipped — not connected (reason: %s)"):format(reason or "?"))
        return
    end
    log(("Activating gameplay (reason: %s)"):format(reason or "?"))
    lc_event("on_continue")  -- PRE_APPLY→GAMEPLAY
    if APClient.set_in_game then APClient:set_in_game(true) end
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.set_gameplay_active then IA.set_gameplay_active(true) end
    start_gameplay_loops()
end

local function deactivate_gameplay(reason)
    log(("Deactivating gameplay (reason: %s)"):format(reason or "?"))
    lc_event("on_returned_to_title")  -- → TITLE
    local APClient = package.loaded["AP/APClient"]
    if APClient and APClient.set_in_game then APClient:set_in_game(false) end
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.set_gameplay_active then IA.set_gameplay_active(false) end
    -- Reset the apply-gate guard so the next gameplay entry re-runs the gate. Without this, a
    -- second Continue skips set_apply_safe(true) and books never re-ward ("books visible, cases hidden").
    _gameplay_loops_started = false
end

-- HUD notification drain, on the game thread. Lives here rather than in AP/HUD.lua because
-- _gt_step_order is order-sensitive for warding and must stay auditable in one file; module-scope
-- steps always register before the start_gameplay_loops ones, so this cannot perturb that order.
if POLL_GT then gt_loop("hud_drain", 300, function()
    local H = package.loaded["AP/HUD"]
    if H and H._drain_one then H._drain_one() end
    return false
end) end   -- with the flag off, AP/HUD.lua keeps its own async drain; registering both halves DRAIN_MS

-- SelectedLevel watcher (handles "Continue" path where no LoadMap fires).
-- BP_LibrarianGameInstance_C.SelectedLevel is -1 at title and >= 0 once the
-- player has picked a save. We poll once per second and activate/deactivate
-- on transitions.
local _prev_selected_level = -1
gt_loop("selected_level", 1000, function()
    local gi = FindFirstOf("BP_LibrarianGameInstance_C")
    if not gi or not gi:IsValid() then return false end
    local selected = -1
    pcall(function() selected = gi.SelectedLevel or -1 end)
    if selected ~= _prev_selected_level then
        if _prev_selected_level < 0 and selected >= 0 then
            log(("SelectedLevel transition: -1 → %d (Continue or save load)"):format(selected))
            activate_gameplay("SelectedLevel >= 0")
        elseif _prev_selected_level >= 0 and selected < 0 then
            log(("SelectedLevel transition: %d → -1 (returned to title)"):format(_prev_selected_level))
            deactivate_gameplay("SelectedLevel = -1")
        end
        _prev_selected_level = selected
    end
    return false
end)

-- LoadMap PRE-hook: fires as UEngine::LoadMap begins, BEFORE the old world is torn down -- the only
-- signal that LEADS the world-free on every transition (New Game, Continue, quit-to-title, and the
-- forced connect-time reload). Disarm the cross-frame warding resumes here: an L1 (book-flush) or L3
-- (book-pile HISM) resume closure captured the OLD world's actor/HISM arrays, and firing it after the
-- free is a native access violation pcall can't catch. The epoch guard and the 1Hz SelectedLevel
-- watcher both LAG the free (the epoch only bumps on M01 ENTRY via reset_hism_state; apply_safe drops
-- ~1s later on the watcher), so those guards miss the leave side -- this closes it. Runs on the game
-- thread (LoadMap is game-thread), so clearing these here is not a cross-thread write.
RegisterLoadMapPreHook(function()
    _l3_resume = nil
    _b2_running = false
    local IA = package.loaded["AP/ItemApply"]
    if IA then
        IA._l1_resume = nil
        pcall(function() IA.set_apply_safe(false) end)
    end
end)

RegisterLoadMapPostHook(function(Engine, World)
    local lvlname = "<unknown>"
    pcall(function() lvlname = World:get():GetFullName() end)
    log("LoadMap post: " .. lvlname)

    -- Determine in_gameplay. GameSaveData/LibrarianGameMode are non-null even at the title, so
    -- the reliable signal is the 2nd+ M01 LoadMap; SelectedLevel >= 0 is a secondary positive.
    local in_gameplay = false
    if lvlname:find("PL_M01", 1, true) then
        -- Our forced OpenLevel (on connect) leaves the user at the title -- don't count it toward
        -- the gameplay threshold; the HideTitleMenu hook activates gameplay when they click Continue.
        local is_our_forced_reload = _suppress_next_m01_load_count or false
        _suppress_next_m01_load_count = false

        if not is_our_forced_reload then
            m01_load_count = m01_load_count + 1
        end
        local gi = FindFirstOf("BP_LibrarianGameInstance_C")
        local selected = -1
        if gi and gi:IsValid() then
            pcall(function() selected = gi.SelectedLevel or -1 end)
        end
        if (selected and selected >= 0) or m01_load_count >= 2 then
            in_gameplay = true
        end
        log(("(M01 LoadMap #%d, SelectedLevel=%s → in_gameplay=%s%s)"):format(
            m01_load_count, tostring(selected), tostring(in_gameplay),
            is_our_forced_reload and " [forced reload, count suppressed]" or ""))

        -- Fresh world -> reset HISM mapping state (captured transforms refer to the old world).
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA.reset_hism_state then IA.reset_hism_state() end

        -- Layer-3 state is per-world (fresh HISMs start visible; the series cache is tied to the
        -- old world's actors). Clear it so this world re-snapshots and re-hides from scratch.
        _b2_state = {}
        _b2_last_sig = nil
        _b2_group = {}

        -- Re-arm the apply-gate for this fresh world. Menu->Continue reloads M01 but never calls
        -- deactivate_gameplay, so without this reset the gate never re-runs and warding indexes 0
        -- bookcases ("books visible, cases hidden"). Mirrors deactivate_gameplay.
        if IA and IA.set_apply_safe then pcall(function() IA.set_apply_safe(false) end) end
        _gameplay_loops_started = false

        -- Tell the connection-menu LoopAsync that M01 is loaded — its
        -- initial show should now fire on the M01 ModActor.
        _G._librarian_menu_m01_loaded = true
    end

    -- Defer-register BP-path hooks now that the BP class is (probably) loaded.
    if register_bp_hooks_once then register_bp_hooks_once() end

    -- New Game / save-reload path: explicit LoadMap fired the gameplay
    -- transition. Activate via the shared function (idempotent with the
    -- SelectedLevel watcher above).
    if in_gameplay then
        activate_gameplay("LoadMap → in_gameplay")
    else
        -- Post-connect title path: the OpenLevel triggered by connect
        -- brings us here with the M01 world fresh-loaded but the player
        -- still at the title menu. Kick off the apply-gate retry loop so
        -- warding runs while the player waits — Continue / Start stay
        -- disabled (see update_title_buttons) until _pre_apply_complete.
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA._allow_pre_apply and lvlname:find("PL_M01", 1, true) then
            log("LoadMap (post-connect title) → start pre-apply loops")
            start_gameplay_loops()
        end
    end

end)

-- ============================================================
-- HOOK: Upgrade flow
-- ============================================================
RegisterHook("/Script/Librarian.LibrarianCharacter:UpgradePlayer", function(self, ability)
    if not diag_on("NAMED_HOOKS") then return end
    local idx
    pcall(function() idx = ability:get() end)
    log((">> UpgradePlayer    ability=%s (%s)"):format(tostring(idx), ability_name(idx or -1)))

    -- Don't echo AP-delivered grants back as location checks (ItemApply._ap_grant is set
    -- true around AP-driven UpgradePlayer calls).
    do
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA._ap_grant then return end
    end
    if _ap_grant then return end

    -- Minor Magic chest openings (idx 0/1/2/4) -> AP chest location check; native grant proceeds.
    -- Major Magic point-spends (idx 3/5/6/7/8) fall through the table miss.
    local loc = AP_CHEST_LOC_BY_ABILITY[idx]
    if loc then
        log(("[AP] queueing chest-open check id=%d (ability=%d %s)"):format(
            loc, idx, ability_name(idx)))
        ap_send_check(loc)
    end
end)

RegisterHook("/Script/Librarian.LibrarianCharacter:UpgradePlayerBP", function(self, ability, levelNum)
    local idx, lvl
    pcall(function() idx = ability:get() end)
    pcall(function() lvl = levelNum:get() end)
    log((">> UpgradePlayerBP  ability=%s (%s)  level=%s"):format(
        tostring(idx), ability_name(idx or -1), tostring(lvl)))
end)

-- ============================================================
-- HOOK: Save/Load probes (verify SaveGameName redirect lands)
-- ============================================================
-- Read-only diagnostics. UE4SS hook callbacks always get `self` first (even static UFunctions),
-- then params; param accessors return wrappers, FString needs :ToString().
local function fstring_to_str(p)
    if not p then return "<nil>" end
    local v
    pcall(function() v = p:get() end)
    if not v then return "<getfail>" end
    local s
    pcall(function() s = v:ToString() end)
    if not s then pcall(function() s = tostring(v) end) end
    return tostring(s or "<?>")
end

-- /Script/Engine.GameplayStatics:SaveGameToSlot(SaveGameObject, SlotName, UserIndex)
RegisterHook("/Script/Engine.GameplayStatics:SaveGameToSlot", function(self, _save, slot_param, _user)
    log(("[AP][save-probe] GameplayStatics.SaveGameToSlot SlotName='%s'"):format(fstring_to_str(slot_param)))
end)

-- /Script/Engine.GameplayStatics:LoadGameFromSlot(SlotName, UserIndex) → USaveGame*
RegisterHook("/Script/Engine.GameplayStatics:LoadGameFromSlot", function(self, slot_param, _user)
    log(("[AP][save-probe] GameplayStatics.LoadGameFromSlot SlotName='%s'"):format(fstring_to_str(slot_param)))
end)

-- /Script/Engine.GameplayStatics:DoesSaveGameExist(SlotName, UserIndex) → bool
RegisterHook("/Script/Engine.GameplayStatics:DoesSaveGameExist", function(self, slot_param, _user)
    log(("[AP][save-probe] GameplayStatics.DoesSaveGameExist SlotName='%s'"):format(fstring_to_str(slot_param)))
end)

-- /Script/Librarian.LibrarianGameInstanceBase:SaveGameData(saveSlotNum)
RegisterHook("/Script/Librarian.LibrarianGameInstanceBase:SaveGameData", function(self, slot_num_param)
    local n = "?"
    pcall(function() n = tostring(slot_num_param:get()) end)
    log(("[AP][save-probe] GI.SaveGameData(slot=%s) — current SaveGameName='%s'")
        :format(n, tostring(read_save_slot())))
    -- After save, InsertedBookNum is fresh -> re-run the progress sync so book milestones catch
    -- up (safety net if a BP-hook counter missed an event).
    -- Post-save resync used to call IA.sync_progress_state() here, but SaveGameData fires on the GAME
    -- thread and sync_progress_state mutates the shared _milestones_sent / _levels_reached tables the
    -- 3s mod-thread loop also writes -> cross-thread Lua-heap race. The 3s loop already resyncs; no
    -- game-thread mutation needed.
end)

-- /Script/Librarian.LibrarianGameInstanceBase:LoadGameData(loadSlotNum) → bool
RegisterHook("/Script/Librarian.LibrarianGameInstanceBase:LoadGameData", function(self, slot_num_param)
    local n = "?"
    pcall(function() n = tostring(slot_num_param:get()) end)
    log(("[AP][save-probe] GI.LoadGameData(slot=%s) — current SaveGameName='%s'")
        :format(n, tostring(read_save_slot())))
end)

-- /Script/Librarian.LibrarianGameInstanceBase:LoadGameDataBP() (BP override)
RegisterHook("/Script/Librarian.LibrarianGameInstanceBase:LoadGameDataBP", function(self)
    log(("[AP][save-probe] GI.LoadGameDataBP — current SaveGameName='%s'")
        :format(tostring(read_save_slot())))
end)

-- OnLevelUp is redeclared on BP_LibrarianCharacter, so runtime dispatches to the BP version;
-- the BP-path hook must register after the BP class loads (hence hook_safe's deferred retry).
local function hook_safe(path, label, handler)
    local ok, err = pcall(function() RegisterHook(path, handler) end)
    if not ok then
        log(("(hook deferred) %s — %s"):format(label, tostring(err)))
        return false
    end
    return true
end

local function on_level_up_bp(self)
    if not diag_on("NAMED_HOOKS") then return end
    local n = "?"
    pcall(function() n = tostring(self:get().EnableUpgradeNum) end)
    log((">> [BP]  OnLevelUp        EnableUpgradeNum=%s"):format(n))
    -- Vanilla / not connected: leave the base game's level-up alone (no skill-point
    -- suppression, no AP level tracking).
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient._slot_connected) then return end
    if suppress_levelup then
        pcall(function()
            local p = self:get()
            p.EnableUpgradeNum = 0
            log("   [SUPPRESS] EnableUpgradeNum forced to 0")
        end)
    end

    -- Event-based increment: CurrentFinishedRowNum isn't committed yet when OnLevelUp fires, so
    -- count one per event instead of reading it.
    -- on_level_up_event() mutates the shared M._levels_reached table + sends a check; OnLevelUp fires
    -- on the GAME thread, so doing that here races the 3s mod-thread sync_progress_state (rc3 crash
    -- class). Defer: record the event as a scalar count the mod-thread 3s loop drains. (The skill-
    -- point suppression above stays inline -- it writes a BP property, not a Lua table.)
    local IA = package.loaded["AP/ItemApply"]
    if IA then
        IA._pending_level_ups = (IA._pending_level_ups or 0) + 1
    end
end

-- Title-widget button handlers. Continue doesn't always fire LoadMap (when M01 is pre-loaded
-- behind the title it just hides + unpauses), so hook the button press to force activate_gameplay.
local function on_title_load_game_pressed(self)
    log(">> [WBP_Title] Continue/LoadGame button pressed")
    log(("    SaveGameName='%s'  GameSaveData: %s"):format(
        tostring(read_save_slot()), snapshot_save_data()))

    -- Do NOT reload the save here (gi:LoadGameData): the world is already AP-loaded from the
    -- connect-time OpenLevel, and a reload re-applies bag-skill increments past the bag cap.

    -- Force gameplay activation next tick in case LoadMap never fires. Delay so the widget's own
    -- handler (level transition / UI hide) runs first.
    if POLL_GT then
        _gt_pending_activate = "WBP_Title.LoadGame button → forced"   -- single-thread: activate on the pawn tick
    else
        LoopAsync(100, function()
            local IA = package.loaded["AP/ItemApply"]
            if APClient and APClient._slot_connected and IA and not IA._gameplay_active then
                activate_gameplay("WBP_Title.LoadGame button → forced")
            end
            return true  -- one-shot
        end)
    end
end

local function on_title_start_game_pressed(self)
    log(">> [WBP_Title] StartGame button pressed")
end

local function on_title_hide_menu(self)
    log(">> [WBP_Title] HideTitleMenu")
    log(("    SaveGameName='%s'  GameSaveData: %s"):format(
        tostring(read_save_slot()), snapshot_save_data()))
    -- Belt-and-suspenders: also activate on HideTitleMenu (covers both
    -- Continue and StartGame paths). activate_gameplay is idempotent.
    if POLL_GT then
        _gt_pending_activate = "WBP_Title.HideTitleMenu → forced"   -- single-thread: activate on the pawn tick
    else
        LoopAsync(150, function()
            local APClient = package.loaded["AP/APClient"]
            if APClient and APClient._slot_connected then
                local IA = package.loaded["AP/ItemApply"]
                if IA and not IA._gameplay_active then
                    activate_gameplay("WBP_Title.HideTitleMenu → forced")
                end
            end
            return true
        end)
    end
end

-- Once per session: a 12s title-screen notification with mod/game version + compatibility marker.
local _compat_notified = false
local function notify_version_compat()
    if _compat_notified then return end
    _compat_notified = true
    local game_v = get_game_version() or "?"
    local msg
    if is_tested_version(game_v) then
        msg = ("LibAP v%s — Game v%s (verified compatible)"):format(MOD_VERSION, game_v)
    else
        msg = ("LibAP v%s — Game v%s UNTESTED, may have issues"):format(MOD_VERSION, game_v)
    end
    local HUD = package.loaded["AP/HUD"]
    if HUD and HUD.notify then HUD.notify(msg, 12.0) end
end

-- Title-refresh bodies. All three touch widgets and read the save system, so they run on the
-- game thread via gt_defer.
local function _title_refresh()
    update_title_buttons()
    update_title_status_text()
end

local function _title_refresh_compat()
    update_title_buttons()
    update_title_status_text()
    notify_version_compat()
end

local function _title_status_only()
    update_title_status_text()
end

local function on_title_construct(self)
    log(">> [WBP_Title] Construct")
    -- Defer so the widget's own Construct (button bindings, styles) runs first, then apply gating
    -- state + the Text_Version status line.
    gt_defer(50, _title_refresh_compat)
end

-- Stage-2 master game-thread scheduler body. Runs in main.lua scope (sees all module locals) and is
-- published to _G so the ReceiveTick hook callback can reach it regardless of hook-state visibility.
-- Every frame: poll+apply the AP client, drain a deferred title activation + a deferred L1 re-flush,
-- then drive all the throttled periodic steps (apply-gate / settle / warding / sync / SelectedLevel).
_G._librarian_gt_master_tick = function(dt_ms)
    local c = package.loaded["AP/APClient"]
    if not (c and c._poll_on_game_thread) then return end
    c._gt_tick_count = (c._gt_tick_count or 0) + 1
    pcall(function() c:_tick_once() end)                 -- create + poll + outgoing + item-apply
    -- Both reached at runtime, not through the file-locals: `APClient` and `menu_toggle` are
    -- declared further down the file, so a closure built here would only see nil globals.
    if _gt_pending_f12 then                              -- F12 pressed on the input thread
        _gt_pending_f12 = false
        if not c._slot_connected then
            log("[F12] connecting to AP...")
            pcall(function() c:connect() end)
        else
            log("[F12] already connected")
        end
    end
    if _gt_pending_f4 then                               -- F4 pressed on the input thread
        _gt_pending_f4 = false
        log("[F4] toggle connection menu")
        local m = _G._librarian_menu
        if m and m.toggle then pcall(m.toggle) end
    end
    if _gt_pending_activate then                         -- title-button activation, on the game thread
        local reason = _gt_pending_activate; _gt_pending_activate = nil
        pcall(function() activate_gameplay(reason) end)
    end
    local IA = package.loaded["AP/ItemApply"]
    if IA then
        -- World-reload safety for the cross-frame warding resumes (L1 book actors, L3 book-pile HISMs).
        -- Each resume closure captured the OLD world's actor/HISM arrays; firing it across a LoadMap is a
        -- use-after-free the epoch guard alone can't catch in time (the async pump used to drop stale
        -- marshals; inline per-frame drive lost that net). So: (1) drop both resumes + release L3's pass
        -- lock the instant the world epoch bumps, and (2) only drive them while the world is confirmed
        -- stable (apply_safe) -- during a LoadMap sublevels are still streaming/freeing, exactly when the
        -- captured arrays go dangling and apply_safe is false.
        local ep = IA._world_epoch or 0
        if ep ~= _gt_last_epoch then
            _gt_last_epoch = ep
            _l3_resume = nil
            _b2_running = false
            IA._l1_resume = nil
        end
        if IA._apply_safe then
            if IA._l1_resume then pcall(IA._l1_resume) end   -- one L1 warding chunk / frame
            if _l3_resume then pcall(_l3_resume) end          -- one L3 book-pile HISM chunk / frame
        end
        if IA._flush_reflush_pending then                    -- L1 finalizer re-fire (no marshal to nest now)
            IA._flush_reflush_pending = false
            pcall(function() IA.flush_apply() end)
        end
    end
    gt_run_deferred(dt_ms)                                   -- one-shot deferred work (title/HUD refreshes)
    gt_run_steps(dt_ms)                                      -- apply-gate / settle / warding / sync / etc.
    if (c._gt_tick_count % 600) == 0 then
        -- Name the registered steps, not just the count: a bare number says little when a dozen
        -- registrations exist. Printing the array contents next to the key count of _gt_steps makes
        -- damage visible -- array N with keys N-1 is a stray array entry that never registered.
        local names, keyn = {}, 0
        for i = 1, #_gt_step_order do names[i] = tostring(_gt_step_order[i]) end
        for _ in pairs(_gt_steps) do keyn = keyn + 1 end
        log(("[gt-tick] master driver (ticks=%d, steps=%d, keys=%d) order=[%s]"):format(
            c._gt_tick_count, #_gt_step_order, keyn, table.concat(names, ",")))
    end
end

-- BP-path hooks: defer to first LoadMap so the BP class is loaded.
-- (register_bp_hooks_once was forward-declared above near the LoadMap hook.)
local bp_hooks_registered = false
register_bp_hooks_once = function()
    if bp_hooks_registered then return end
    local ok1 = hook_safe("/Game/Librarian/Blueprints/Character/BP_LibrarianCharacter.BP_LibrarianCharacter_C:OnLevelUp",
        "OnLevelUp (BP)", on_level_up_bp)

    -- Single-thread crash-fix driver (Stage 1, gated POLL_ON_GAME_THREAD). Registered ONLY when the
    -- flag is on, so the default build gains ZERO per-frame overhead. A per-frame GAME-THREAD pawn
    -- tick drives the AP client (create + poll + apply) so it no longer races the async LoopAsync --
    -- that concurrency (two threads in one lua_State) is what corrupts the VM. Fetch APClient via
    -- package.loaded each fire; hook callbacks can't see main.lua's local APClient.
    if POLL_GT then
        hook_safe(
            "/Game/Librarian/Blueprints/Character/BP_LibrarianCharacter.BP_LibrarianCharacter_C:ReceiveTick",
            "BP_LibrarianCharacter.ReceiveTick (master driver)",
            function(self, DeltaSeconds)
                local dt = 16
                pcall(function()
                    local d = DeltaSeconds and DeltaSeconds:get()
                    if d and d > 0 then dt = d * 1000 end
                end)
                local f = _G._librarian_gt_master_tick
                if f then f(dt) end
            end)
    end

    -- Title-widget hooks. Use hook_safe since the BP class may not be loaded
    -- yet on first attempt; we'll retry on subsequent LoadMaps.
    hook_safe(
        "/Game/Librarian/UI/Title/WBP_Title.WBP_Title_C:BndEvt__WBP_Title_Button_LoadGame_K2Node_ComponentBoundEvent_3_OnButtonPressedEvent__DelegateSignature",
        "WBP_Title.LoadGame pressed", on_title_load_game_pressed)
    hook_safe(
        "/Game/Librarian/UI/Title/WBP_Title.WBP_Title_C:BndEvt__TitleUMG_Button_StartGame_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
        "WBP_Title.StartGame pressed", on_title_start_game_pressed)
    hook_safe(
        "/Game/Librarian/UI/Title/WBP_Title.WBP_Title_C:HideTitleMenu",
        "WBP_Title.HideTitleMenu", on_title_hide_menu)
    hook_safe(
        "/Game/Librarian/UI/Title/WBP_Title.WBP_Title_C:Construct",
        "WBP_Title.Construct", on_title_construct)

    -- Connect button calls ModActor.BroadcastConnectRequest(server, slot, password); read them
    -- into APClient and connect.
    hook_safe(
        "/Game/Mods/LibrarianAPHUDFix/ModActor.ModActor_C:BroadcastConnectRequest",
        "ModActor.BroadcastConnectRequest",
        function(self, server_p, slot_p, password_p)
            local server, slot, password = "", "", ""
            pcall(function() server   = server_p:get():ToString() end)
            pcall(function() slot     = slot_p:get():ToString() end)
            pcall(function() password = password_p:get():ToString() end)
            log(("[menu] Connect requested — server=%s slot=%s pw=%d chars"):format(
                server, slot, #password))
            -- UE4SS hook callbacks run in a separate Lua state that can't see
            -- main.lua's local APClient. Fetch via package.loaded each fire.
            local c = package.loaded["AP/APClient"]
            if not c then
                log("[menu] APClient module not loaded; cannot connect")
                return
            end
            if c._slot_connected then
                log("[menu] already connected — ignoring Connect (use F12 or restart to switch slots)")
                if _G._librarian_menu and _G._librarian_menu.set_status then
                    _G._librarian_menu.set_status("Already connected", "warn")
                end
                return
            end
            c.server   = server
            c.slot     = slot
            c.password = password
            if _G._librarian_menu and _G._librarian_menu.set_status then
                _G._librarian_menu.set_status("Connecting...", "warn")
            end
            c:connect()
        end)

    -- Close button -> latch Vanilla mode. Needs the pak's ModActor to wire a BroadcastCloseRequest
    -- event to Btn_Close.OnClicked; until then this hook defers harmlessly. Reached via _G menu table.
    hook_safe(
        "/Game/Mods/LibrarianAPHUDFix/ModActor.ModActor_C:BroadcastCloseRequest",
        "ModActor.BroadcastCloseRequest",
        function(self)
            if _G._librarian_menu and _G._librarian_menu.enter_vanilla then
                pcall(function() _G._librarian_menu.enter_vanilla() end)
            end
        end)

    if ok1 then
        bp_hooks_registered = true
        log("BP hooks registered (OnLevelUp, WBP_Title buttons, ConnectMenu)")
    end
end

-- ============================================================
-- HOOK: Row / level completion
-- ============================================================
-- FinishRow gives a global Nth-row counter but not which (section, series); ItemApply resolves
-- that by diffing its per-bookcase RowStatus snapshot. `row` is logged for diagnostics only.
-- Goal latch: set on the first STATUS_GOAL so a re-fire doesn't double-send. Reset on connect/disconnect.
local _goal_sent = false

-- Goal-progress milestones at 25/50/75%, each at most once per connection; cleared with _goal_sent.
local _progress_milestones_fired = {}

local function announce_goal_progress(row)
    local APClient_mod = package.loaded["AP/APClient"]
    local sd = APClient_mod and APClient_mod.slot_data
    if not (sd and sd.goal_row_threshold) then return end
    local threshold = tonumber(sd.goal_row_threshold) or 0
    if threshold <= 0 then return end
    local HUD_mod = package.loaded["AP/HUD"]
    if not (HUD_mod and HUD_mod.notify) then return end
    for _, pct in ipairs({25, 50, 75}) do
        local mark = math.floor((threshold * pct) / 100)
        if mark > 0 and row >= mark and not _progress_milestones_fired[pct] then
            _progress_milestones_fired[pct] = true
            HUD_mod.notify(
                ("Goal progress: %d / %d rows (%d%%)"):format(row, threshold, pct),
                6.0)
        end
    end
end

RegisterHook("/Script/Librarian.LibrarianCharacter:FinishRow", function(self, finishedRow)
    if not diag_on("NAMED_HOOKS") then return end
    local row
    pcall(function() row = finishedRow:get() end)
    log((">> FinishRow        row=%s"):format(tostring(row)))

    if row then announce_goal_progress(row) end

    -- Row-count goal trigger for non-full goals (full goal waits for the game's EndGame at the end
    -- door). option_full=0 in Options.py -- compare goal against 0, not 1, or custom goals never fire.
    if not _goal_sent and row then
        local APClient_mod = package.loaded["AP/APClient"]
        local sd = APClient_mod and APClient_mod.slot_data
        if sd and sd.goal_row_threshold and sd.goal ~= nil then
            local is_full = (sd.goal == 0)  -- option_full = 0
            local threshold = tonumber(sd.goal_row_threshold) or 400
            if not is_full and row >= threshold then
                _goal_sent = true
                log(("[AP] reached %d rows — sending STATUS_GOAL (goal=%s)"):format(
                    threshold, tostring(sd.goal)))
                local HUD_mod = package.loaded["AP/HUD"]
                if HUD_mod and HUD_mod.notify then
                    HUD_mod.notify(("Goal complete! (%d rows)"):format(threshold), 10.0)
                end
                ap_send_goal()
            end
        end
    end

    -- Completion checks + progress sync used to run INLINE here, but FinishRow fires on the GAME
    -- thread, and fire_row_completion_checks / fire_section_completions / fire_floor_completions /
    -- sync_progress_state mutate the shared _sent_* / _milestones_sent / _levels_reached de-dup
    -- tables that the 3s mod-thread loop ALSO writes -> cross-thread Lua-heap race (the rc3 crash
    -- class). The 3s loop already runs every one of these each tick (plus detect_completed_rows), so
    -- they are covered there on the mod thread (<=3s latency). Nothing to do on the game thread here.
end)

RegisterHook("/Script/Librarian.LibrarianGameMode:NewRowFinished", function(self, num)
    if not diag_on("NAMED_HOOKS") then return end
    local n
    pcall(function() n = num:get() end)
    log((">> NewRowFinished   num=%s"):format(tostring(n)))
end)

RegisterHook("/Script/Librarian.LibrarianGameMode:EndGame", function(self)
    if not diag_on("NAMED_HOOKS") then return end
    log(">> EndGame  (GAME COMPLETE)")
    if _goal_sent then
        log("[AP] STATUS_GOAL already sent (threshold reached earlier); skipping")
        return
    end
    _goal_sent = true
    log("[AP] sending STATUS_GOAL")
    ap_send_goal()
end)



-- ============================================================
-- Keybinds
-- ============================================================
-- F12 = connect to the Archipelago server (or trigger a reconnect).


-- ============================================================
-- Archipelago client
-- ============================================================

local APClient = require("AP/APClient")
local ItemApply = require("AP/ItemApply")
local APConfig = require("AP/APConfig")
local HUD = require("AP/HUD")

-- Open the crash breadcrumb ledger now, before any world mutation can fire. Re-opened
-- with the seed on slot connect (header then carries it for triage). See AP/trace.lua.
trace.init({ version = MOD_VERSION, flags = diag_flags_str() })
trace.mark("boot")

-- The 1 Hz crash-ledger heartbeat that used to run here is gone. It did string.format, os.date, a
-- shared ring write and flushed I/O on the async thread every second for the whole session, racing
-- trace.init's own close/reopen. The BEG/END markers already distinguish a synchronous-in-op crash
-- from an idle one.

-- Lifecycle state machine, driven by the lc_event(...) calls below. Observational only: logs
-- [lifecycle] transitions, gates nothing yet. pcall'd require so it can't break mod loading.
do
    local ok, Lifecycle = pcall(require, "AP/lifecycle")
    if ok and Lifecycle then
        Lifecycle.init(nil, log)
        Lifecycle.on_title_loaded()  -- mod loads at the title screen → BOOT→TITLE
        log("[lifecycle] event-driven observer started")
    end
end

local AP_CONFIG_PATH = "Mods/Librarian-AP/Scripts/ap_config.json"
local AP_GAME_NAME = "Librarian Tidy Up the Arcane Library"

-- Load static asset data (AssetIdx -> series_name / section_id).
ItemApply.load_asset_data()

APClient.on_item = function(it, item_name)
    log(("[AP] received item: %s (id=%d) from player=%s loc=%s flags=%d"):format(
        tostring(item_name or "?"),
        tonumber(it.item) or 0,
        tostring(it.player),
        tostring(it.location),
        tonumber(it.flags) or 0))

    -- HUD: classify by sender. player=0 = server (starting items / connect re-dump) -- logged but
    -- no popup (the dump floods the BP notifier); player=us = self-check echo; else = another player.
    local sender = tonumber(it.player) or -1
    local me = APClient.slot_number or -1
    local color, prefix = HUD.COL_RECEIVED, "← "
    local show_popup = true
    if sender == 0 then
        color, prefix = HUD.COL_RECEIVED_S, "★ "
        show_popup = false  -- bulk-dump silencer
    elseif sender ~= me and sender > 0 then
        color, prefix = HUD.COL_RECEIVED_X, "← "
    end
    -- During pre-apply, silence all item toasts (self re-deliveries crowd out "Preparing world...").
    -- Items still log + apply; only the toast is suppressed.
    do
        local IA_mod = package.loaded["AP/ItemApply"]
        if IA_mod and IA_mod._allow_pre_apply and not IA_mod._gameplay_active then
            show_popup = false
        end
    end
    local label = prefix .. tostring(item_name or ("item " .. tostring(it.item)))
    if sender ~= me and sender > 0 then
        local alias = APClient:get_alias(sender)
        if alias and alias ~= "" then
            label = label .. " (from " .. alias .. ")"
        else
            label = label .. " (from player " .. sender .. ")"
        end
    end
    HUD.push_log(label, color, show_popup)

    if item_name then
        ItemApply.apply_item(item_name)
    end
end

-- Outgoing location check -> "You sent ITEM to PLAYER (LOCATION)". Reads the scout cache (filled
-- by the location_info handler); falls back to "→ loc N" if the scout response hasn't returned.
APClient.on_check_sent = function(loc_id)
    local entry = APClient._scout_cache and APClient._scout_cache[loc_id]
    if not entry or not entry.item_name or entry.item_name == "" then
        HUD.push_log("→ loc " .. tostring(loc_id), HUD.COL_SENT)
        return
    end

    local me = APClient.slot_number or -1
    local recipient
    if entry.player == me then
        recipient = "yourself"
    elseif entry.player_name and entry.player_name ~= "" then
        recipient = entry.player_name
    else
        recipient = "player " .. tostring(entry.player)
    end

    local loc_name = (entry.location_name and entry.location_name ~= "")
        and entry.location_name
        or ("loc " .. tostring(loc_id))

    local msg = ("You sent %s to %s (%s)"):format(entry.item_name, recipient, loc_name)
    HUD.push_log(msg, HUD.COL_SENT)
end

APClient.on_slot_connected = function(slot_data)
    lc_event("on_slot_connected")  -- TITLE→CONNECTING (no-op if reconnect in GAMEPLAY)
    log("[AP] slot_connected — slot data summary:")
    pcall(function()
        if slot_data.starting_section then
            log("  starting_section: " .. tostring(slot_data.starting_section))
        end
        if slot_data.starting_series and #slot_data.starting_series > 0 then
            log(("  starting_series: %d entries (first 3: %s)"):format(
                #slot_data.starting_series,
                table.concat({slot_data.starting_series[1] or "",
                              slot_data.starting_series[2] or "",
                              slot_data.starting_series[3] or ""}, " | ")))
        end
        if slot_data.series_order then
            log(("  series_order: %d entries"):format(#slot_data.series_order))
        end
        if slot_data.bookcase_counts then
            local total = 0
            for _, c in pairs(slot_data.bookcase_counts) do total = total + c end
            log(("  bookcase_counts: %d sections, %d bookcases total"):format(
                (function() local n = 0; for _ in pairs(slot_data.bookcase_counts) do n = n + 1 end; return n end)(),
                total))
        end
        if slot_data.seed then
            log("  seed: " .. tostring(slot_data.seed))
        end
    end)

    -- Redirect save slot to a per-seed name so AP runs don't clobber the
    -- player's normal Sav.sav.
    local seed = sanitize_slot(slot_data and slot_data.seed or "unknown")
    -- Re-open the crash ledger now that we know the seed (header carries it for triage).
    pcall(function() trace.init({ version = MOD_VERSION, seed = seed, flags = diag_flags_str() }) end)
    local slot_num = tostring(APClient.slot_number or -1)
    local ap_slot_name = ("Sav_AP_%s_%s"):format(seed, sanitize_slot(slot_num))
    set_save_slot(ap_slot_name)

    -- Force a fresh world reload now SaveGameName points at the AP slot -- the boot world used
    -- default 'Sav', so without this the books/HISM stay stale ("default orientation until you look").
    -- Only when still at title (a mid-gameplay reconnect would be disruptive). Defer 200ms to settle.
    gt_defer(200, function()
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA._gameplay_active then
            log("[AP][save] mid-gameplay reconnect — skipping forced level reload")
            return
        end
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local gi = find_game_instance()
        if statics and statics:IsValid() and gi then
            log("[AP][save] forcing OpenLevel(PL_M01) — fresh world with AP save")
            -- Signal the LoadMap hook to not count this load (we're
            -- staying at title; user will click Continue normally).
            _suppress_next_m01_load_count = true
            local ok, err = pcall(function()
                statics:OpenLevel(gi, FName("PL_M01"), true, "")
            end)
            if not ok then
                log(("[AP][save] OpenLevel FAILED: %s"):format(tostring(err)))
                _suppress_next_m01_load_count = false
            end
        else
            log("[AP][save] OpenLevel skipped — GameplayStatics or GameInstance missing")
        end
    end)

    -- Update title-screen buttons + Text_Version line. Deferred onto the game thread: this used to
    -- be a raw 50ms async timer, and it was the proven crash ignition -- FindAllOf, save-existence
    -- probes and UMG writes off-thread, landing inside the item dump's unyielding game-thread burst.
    gt_defer(50, _title_refresh)

    -- HUD: status line + clear stale log entries from prior connect.
    HUD.set_status(("AP: connected as %s (slot #%s)"):format(
        tostring(APClient.slot or "?"),
        tostring(APClient.slot_number or -1)),
        HUD.COL_STATUS_OK)
    HUD.clear_log()
    -- Connect menu: status + auto-hide on success (pre-apply status then surfaces on Text_Version).
    if _G._librarian_menu then
        _G._librarian_menu.set_status(
            ("Connected as %s — preparing world..."):format(
                tostring(APClient.slot or "?")),
            "ok")
        _G._librarian_menu.hide()
    end
    -- Reset goal latch so this fresh connection can fire STATUS_GOAL again.
    _goal_sent = false
    _progress_milestones_fired = {}

    -- Persist working connection info so next launch auto-fills.
    pcall(function()
        APConfig.save(AP_CONFIG_PATH, APClient.server, APClient.slot, APClient.password)
        log("[AP] saved working connection info to ap_config.json")
    end)

    -- Hand slot data to ItemApply; it will flush any queued items.
    ItemApply.set_slot_data(slot_data)

    -- Let the starting-item dump flow during pre-apply: items update derived state but their
    -- per-item flush is suppressed (ItemApply.apply_item), so the settle loop wards once with final
    -- state instead of ward-then-unwarding the starting series on every item.
    APClient:set_in_game(true)

    -- Warn the player: pre-apply takes ~10-20s. Long toast to span the window.
    if HUD and HUD.notify then
        HUD.notify("AP: Preparing world — Continue will enable when ready...", 30.0)
    end
end

APClient.on_disconnected = function()
    log("[AP] disconnected")
    restore_save_slot()
    _goal_sent = false
    _progress_milestones_fired = {}
    -- Clear pre-apply state so a reconnect starts fresh (else buttons enable early / settle thinks
    -- it's done).
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.clear_pre_apply then IA.clear_pre_apply() end
    _pre_apply_settle_state = nil
    -- Disconnected: both gameplay buttons return to disabled-by-default.
    gt_defer(50, _title_refresh)
    HUD.set_status("AP: disconnected — F4 for menu, F12 to reconnect", HUD.COL_STATUS_BAD)
    -- Connect menu: re-show + status. Repopulate fields from current
    -- APClient values so the player can edit and retry.
    if _G._librarian_menu then
        _G._librarian_menu.set_fields(APClient.server, APClient.slot, APClient.password)
        _G._librarian_menu.set_status("Disconnected", "bad")
        _G._librarian_menu.show()
    end
end

APClient.on_slot_refused = function(reason)
    log("[AP] slot refused: " .. tostring(reason))
    HUD.set_status("AP: slot refused — " .. tostring(reason), HUD.COL_STATUS_BAD)
    gt_defer(50, _title_status_only)
    -- Connect menu: leave open (already up from the Connect click) and
    -- surface the refusal reason. Don't call show() — if the user closed
    -- it between click and refused, respect that.
    if _G._librarian_menu then
        _G._librarian_menu.set_status("Refused: " .. tostring(reason), "bad")
    end
end

-- Initialize the client (loads config + starts LoopAsync poll thread).
-- Connection is NOT triggered automatically — press F12 to connect.
APClient:init(AP_CONFIG_PATH)
-- Stage 1 single-thread fix: when POLL_ON_GAME_THREAD is on, the game-thread pawn tick (registered in
-- register_bp_hooks_once) owns AP client create+poll+apply; the async loop stays idle while it fires.
-- Both consult APClient._poll_on_game_thread.
APClient._poll_on_game_thread = diag_on("POLL_ON_GAME_THREAD")
if APClient._poll_on_game_thread then
    log("[single-thread] POLL_ON_GAME_THREAD ON -- AP client will poll on the BP_LibrarianCharacter game-thread tick")
end

-- Initial HUD status. Wait briefly so the world exists for PrintString's WorldContextObject.
-- On the game thread: set_status enqueues into the same _notif_queue the HUD drain now reads
-- from the game thread, and a cross-thread write to that table is the rc3 crash class.
local function _initial_hud_status()
    -- The delay is tick time now, so this can land after a fast connect; don't overwrite it.
    if APClient._slot_connected then return end
    HUD.set_status(
        ("AP: not connected (server=%s, slot=%s) — F4 for menu, F12 to connect"):format(
            tostring(APClient.server or "?"),
            tostring(APClient.slot or "?")),
        HUD.COL_STATUS_WARN)
end
gt_defer(2000, _initial_hud_status)

-- F12: connect to Archipelago (or trigger a reconnect if the socket dropped).
-- UE4SS dispatches keybinds on the input thread, so the bind only sets a flag; the master tick
-- does the work. Entering the VM from a third thread is the same corruption as the async timers.
RegisterKeyBind(Key.F12, function() _gt_pending_f12 = true end)

log("Press F12 to connect to Archipelago.")

-- ============================================================
-- Connection menu (F4 toggle, default on)
-- ModActor (LibrarianAPHUDFix.pak) hosts a UMG widget (Server/Slot/Password + Connect). The
-- menu_* helpers below drive it; status callbacks show Connecting/Connected/Refused in-widget.
-- ============================================================
local _menu_initial_shown = false
-- Gate the initial show on M01: the Intro level also spawns a ModActor, but its widget dies when
-- Intro unloads, so wait until we know we're on M01.
_G._librarian_menu_m01_loaded = _G._librarian_menu_m01_loaded or false

local function _get_mod_actor()
    local a = FindFirstOf("ModActor_C")
    if a and a:IsValid() then return a end
    return nil
end

local function _menu_color(status)
    if status == "ok"   then return 0.4,  0.85, 0.4  end
    if status == "warn" then return 0.95, 0.85, 0.3  end
    if status == "bad"  then return 0.85, 0.3,  0.3  end
    return 0.85, 0.85, 0.85
end

local function menu_set_status(text, status)
    local ma = _get_mod_actor()
    if not ma then log("[menu] set_status: no ModActor_C"); return end
    local r, g, b = _menu_color(status or "neutral")
    local ok, err = pcall(function() ma:SetConnectStatus(text, r, g, b) end)
    if not ok then log("[menu] set_status FAILED: " .. tostring(err)) end
end

local function menu_set_fields(server, slot, password)
    local ma = _get_mod_actor()
    if not ma then log("[menu] set_fields: no ModActor_C"); return end
    local ok, err = pcall(function() ma:SetConnectFields(server or "", slot or "", password or "") end)
    if not ok then log("[menu] set_fields FAILED: " .. tostring(err)) end
end

local function menu_show()
    local ma = _get_mod_actor()
    if not ma then log("[menu] show: no ModActor_C"); return end
    local path = "?"
    pcall(function() path = ma:GetFullName() end)
    log("[menu] show: calling ShowConnectMenu on " .. path)
    local ok, err = pcall(function() ma:ShowConnectMenu() end)
    if not ok then log("[menu] show FAILED: " .. tostring(err)); return end
    -- Probe: did the BP actually create + store the widget?
    local ref_status = "unset"
    pcall(function()
        local ref = ma.ConnectMenuRef
        if ref then
            local valid = false
            pcall(function() valid = ref:IsValid() end)
            if valid then
                local rpath = "?"
                pcall(function() rpath = ref:GetFullName() end)
                ref_status = "VALID widget = " .. rpath
            else
                ref_status = "INVALID widget reference"
            end
        else
            ref_status = "null (BP did not create widget)"
        end
    end)
    log("[menu] post-show: ConnectMenuRef = " .. ref_status)
end

local function menu_hide()
    local ma = _get_mod_actor()
    if not ma then log("[menu] hide: no ModActor_C"); return end
    log("[menu] hide: calling HideConnectMenu")
    local ok, err = pcall(function() ma:HideConnectMenu() end)
    if not ok then log("[menu] hide FAILED: " .. tostring(err)) end
end

local function menu_toggle()
    local ma = _get_mod_actor()
    if not ma then log("[menu] toggle: no ModActor_C"); return end
    local path = "?"
    pcall(function() path = ma:GetFullName() end)
    log("[menu] toggle: calling ToggleConnectMenu on " .. path)
    local ok, err = pcall(function() ma:ToggleConnectMenu() end)
    if not ok then log("[menu] toggle FAILED: " .. tostring(err)) end
end

-- Expose to other modules (used by on_slot_connected / on_disconnected /
-- on_slot_refused handlers above, which were defined before this section).
_G._librarian_menu = {
    set_status    = menu_set_status,
    set_fields    = menu_set_fields,
    show          = menu_show,
    hide          = menu_hide,
    toggle        = menu_toggle,
    enter_vanilla = enter_vanilla_mode,
}

-- Input thread again: set the flag, let the master tick construct the widget. See the F12 bind.
RegisterKeyBind(Key.F4, function() _gt_pending_f4 = true end)

-- Poll for ModActor on startup and show the menu once. Subsequent shows
-- are user-driven via F4 — auto-show on disconnect is handled in the
-- on_disconnected handler. On the game-thread scheduler: the body does
-- FindFirstOf plus UMG construction, which must not run off-thread.
gt_loop("menu_show", 500, function()
    if _menu_initial_shown then return true end
    if APClient._slot_connected then
        _menu_initial_shown = true
        log("[menu] initial-show suppressed (already connected)")
        return true
    end
    if not _G._librarian_menu_m01_loaded then
        return false  -- still on Intro / not yet at title screen
    end
    local ma = _get_mod_actor()
    if not ma then return false end  -- ModActor not spawned yet, keep polling
    -- Make sure FindFirstOf returned an M01-level ModActor, not a stale
    -- Intro one. Intro-level actors persist briefly after LoadMap post.
    local path = "?"
    pcall(function() path = ma:GetFullName() end)
    if not path:find("PL_M01", 1, true) then
        log("[menu] initial-show: skipping stale ModActor (" .. path .. ")")
        return false
    end
    _menu_initial_shown = true
    log("[menu] ModActor found on M01; running initial show + prefill")
    menu_show()
    menu_set_fields(APClient.server, APClient.slot, APClient.password)
    menu_set_status("Disconnected — enter details and Connect", "warn")
    return true
end)

log("Press F4 to toggle the connection menu.")
