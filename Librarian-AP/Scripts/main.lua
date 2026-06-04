-- Librarian Archipelago Mod (UE4SS Lua)
-- Top-level wiring: AP client setup, save-slot redirection, title-screen
-- text + button gating, BP hooks (UpgradePlayer, FinishRow, OnLevelUp,
-- StartGame), F4/F12 keybinds, and the post-connect pre-apply loop.
-- World mutations live in AP/ItemApply.lua.

local MOD = "LibrarianAP"

local function log(msg)
    print(("[%s] %s\n"):format(MOD, tostring(msg)))
end

-- ============================================================
-- Crash-hunt instrumentation (see AP/trace.lua, diag_flags.lua, CRASH_HANDOFF.md)
-- ============================================================
-- diag_flags: runtime bisection switches. Each flag DEFAULTS to ON (current behavior);
-- a tester flips one to false, relaunches, and reports crash/no-crash to localize the
-- subsystem. Loaded via pcall so a missing/broken file just means "all flags on".
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
                    "BOOK_REFRESH_FIX", "BOOK_REFRESH_SWEEP", "BOOK_SWEEP", "BOOK_SWEEP_FIX" }
    local parts = {}
    for _, k in ipairs(order) do parts[#parts + 1] = k .. "=" .. tostring(diag_on(k)) end
    return table.concat(parts, ",")
end

-- trace: durable, flushed-on-every-write crash breadcrumb ledger. Stubbed to no-ops if
-- the module is somehow absent, so call sites can never error.
local trace = (function()
    local ok, t = pcall(require, "AP/trace")
    if ok and type(t) == "table" and t.begin then return t end
    return { init = function() end, begin = function() end, finish = function() end,
             mark = function() end, recent = function() return {} end }
end)()
_G._librarian_trace = trace   -- reachable from hook callbacks if ever needed

-- on_game_thread(fn): run `fn` on the GAME THREAD. CRITICAL: UE4SS LoopAsync /
-- ExecuteWithDelay callbacks run on a SEPARATE async thread -- only RegisterHook
-- and NotifyOnNewObject callbacks run on the game thread. So any UObject mutation
-- fired from inside a LoopAsync callback (e.g. the book-pile HISM SetVisibility /
-- SetMaterial / SetHiddenInGame writes in apply_book_visibility below) races the
-- engine's own game/render/cluster-tree workers that read those same components.
-- That cross-thread race -- NOT merely a "mid-frame" write on the game thread, as
-- the handoffs assumed -- is the lead suspect for the recurring native crash (see
-- CRASH_HANDOFF.md). ExecuteInGameThread marshals the work onto the game thread
-- (drained on the engine tick), where it can no longer race them.
--
-- Gated by diag_on("BOOK_VIS_GAMETHREAD") for A/B bisection: flip that false to
-- restore the OLD off-thread behavior (fn runs inline here on the async thread) and
-- confirm the crash returns. Also falls back to inline if ExecuteInGameThread is
-- somehow unavailable, so a missing global can never break mod loading.
local function on_game_thread(fn)
    if diag_on("BOOK_VIS_GAMETHREAD") and type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(fn)
    else
        fn()
    end
end


-- ============================================================================
-- beta6 (warding sync) — Increment 1: OBSERVE-ONLY book-event hooks.
-- See WARDING_SYNC_PLAN.md + BETA6_PROGRESS.md. The plan: keep ONE locked-set and
-- enforce it at the game's own book events. Before relying on those events, this
-- increment only VALIDATES them — it hooks the book's SetActorVisible / SetBookInfo
-- / CanBeGrab UFunctions and LOGS ([book-hook] lines), changing NO behaviour. Goal:
-- confirm they're hookable, see how often SetActorVisible fires, and confirm we can
-- resolve a book's series at hook time. Enforcement is increment 2 (separate flag).
--
-- Gated by diag_on("BOOK_EVENT_HOOKS"). Registers ONCE, on the game thread (a single
-- one-shot ExecuteInGameThread — safe, not a #1180 storm), triggered from the 5s loop
-- after books are loaded. Each callback re-checks the flag, so flipping it false makes
-- them no-ops (rollback without a code revert).
-- ============================================================================
local BOOK_BP = "/Game/Librarian/Prop/GrabbingItem/BP_GrabbingBook.BP_GrabbingBook_C"
local _book_hooks_attempted = false
local _bh = { setvis = 0, setinfo = 0, canbegrab = 0, samples = 0, enforced = 0, enf_samples = 0,
              revealed = 0, rev_samples = 0, grabbed = 0, grab_samples = 0, grabfix = 0,
              swept = 0, swept_samples = 0, opacity_samples = 0 }

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

-- Read a named scalar param from a MID's OVERRIDDEN list (ScalarParameterValues). This is the
-- reliable path: plain GetScalarParameterValue read nil, and b.BookMatInst is nil. Returns a
-- number or nil (nil = that param isn't overridden on this MID).
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

-- Dump all overridden scalar params as "name=value,..." -- DEFINITIVE diagnosis of which
-- parameter the game animates (we've guessed the name twice; this shows what's actually set).
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

-- Same, for VECTOR params (colors) -- opacity could be a color's alpha, which the scalar dump
-- can't see. Logs name=(R,G,B,a=A).
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

-- Inspect the grabbed book's COSMETIC pile instance (the HISM that layer 3 wards) -- the one
-- thing we write that the GRAB hook (which reads the ACTOR) can't see. Reports whether WE left
-- this book's HISM component hidden / swapped to M_APBookMask, or its instance moved off-screen,
-- while the series is unwarded -- i.e. our warding not reversed. hi = AssetIdx+1 (the layer-3
-- index mapping). Read-only; pcall-guarded; game thread (same as layer 3).
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

-- One-time sweep of EVERY unwarded book's "1. Desaturation B" value -- so we find the rare
-- anomaly ourselves instead of asking the player to hunt intermittent broken books. If only a
-- few books read < 0.5, that rarity matches the bug (and we log their series to spot-check);
-- if hundreds do, DesatB=0 is just a normal cover value and the cause is elsewhere. Read-only.
local _desat_scanned = false
local function _scan_desat()
    if _desat_scanned then return end
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._apply_safe and IA._book_valid_asset_idx and IA._asset_to_series
            and IA._compute_unwarded_set) then return end
    local books = FindAllOf("BP_GrabbingBook_C")
    local n = 0; if books then pcall(function() n = #books end) end
    if n == 0 then return end
    _desat_scanned = true
    local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
    local uw = IA._compute_unwarded_set(only_shelfable) or {}
    local nlow, nhigh, nbad, nchk = 0, 0, 0, 0
    local lows = {}
    for i = 1, n do
        local b = books[i]
        if b and b:IsValid() then
            local aidx = IA._book_valid_asset_idx(b)
            local series = aidx and IA._asset_to_series[aidx]
            if series and uw[series] then
                local sm; pcall(function() sm = b.SM_Book_1 end)
                local mid; if sm and sm:IsValid() then pcall(function() mid = sm:GetMaterial(0) end) end
                if mid and mid:IsValid() then
                    local dv = _mid_scalar(mid, "1. Desaturation B")
                    nchk = nchk + 1
                    if type(dv) == "number" then
                        if dv < 0.5 then
                            nlow = nlow + 1
                            if #lows < 30 then lows[#lows + 1] = series end
                        else nhigh = nhigh + 1 end
                    else nbad = nbad + 1 end
                end
            end
        end
    end
    log(("[desat-scan] unwarded books: checked=%d  DesatB<0.5=%d  DesatB>=0.5=%d  unreadable=%d"):format(
        nchk, nlow, nhigh, nbad))
    if nlow > 0 then
        log("[desat-scan] DesatB<0.5 series (candidates for the invisible bug): " .. table.concat(lows, " | "))
    end
end

-- PROACTIVE RefreshInfo sweep (inc5e): redraw every unwarded book in small chunks so a corrupt
-- one (invisible, but with correct identity) self-heals WITHOUT the player grabbing it. We can't
-- DETECT broken books by value -- they don't share one (one had out-of-range Tints, another
-- normal) -- so we redraw ALL of them; RefreshInfo re-derives a book's look from its BookInfo, so
-- for a healthy book it just re-applies the SAME look (a no-op redraw), and for a corrupt one it
-- rebuilds it. Chunked across the (game-thread) SetActorVisible pre-hook -> no mass-update burst,
-- no new ExecuteInGameThread. RefreshInfo is a redraw (not a flag the game's Tick reverts), so it
-- does NOT churn like the shelved bHidden sweep. World-epoch guarded. Gated BOOK_REFRESH_SWEEP.
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
        local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
        _rsw_uw = IA._compute_unwarded_set(only_shelfable)
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

-- Shared grab-path check, called from BOTH GrabFromPlayer and CanBeGrab. (CanBeGrab is
-- proven to fire on grab attempts -- Bug Report 5, ~10/run -- so routing through it hedges
-- against GrabFromPlayer not firing.) Logs the book's full visibility state to pinpoint the
-- "pickable book invisible" cause (symptom 2, which SetActorVisible/REVEAL never sees), then
-- conservatively restores an UNWARDED book that's hidden. Logging gated by BOOK_EVENT_HOOKS
-- (the caller), restore by BOOK_EVENT_GRABFIX. Game thread; the setters used aren't hooked
-- (no re-entrancy) and align with "you grabbed it, it should be visible" (no fight).
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
    if series and IA and IA._compute_unwarded_set then
        local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
        local uw = IA._compute_unwarded_set(only_shelfable)
        unwarded_here = uw and uw[series] or false
    end
    if _bh.grab_samples < 30 then
        _bh.grab_samples = _bh.grab_samples + 1
        log(("[book-hook] %s series=%s unwarded=%s bHidden=%s meshHidden=%s meshVis=%s opacity=%s scaleX=%s mat=%s"):format(
            tostring(tag), tostring(series), tostring(unwarded_here), tostring(bhidden),
            tostring(mesh_hidden), tostring(mesh_vis), tostring(opacity), tostring(scalex), tostring(mat)))
        log(("[book-hook] %s-PARAMS series=%s scalars=%s"):format(tostring(tag), tostring(series), scalars_dump))
        log(("[book-hook] %s-VPARAMS series=%s vectors=%s"):format(tostring(tag), tostring(series), vectors_dump))
        log(("[book-hook] %s-PILE series=%s %s"):format(tostring(tag), tostring(series), _inspect_pile(b)))
        log(("[book-hook] %s-MESH series=%s actorZ=%s meshZ=%s cpd=%s mesh=%s"):format(
            tostring(tag), tostring(series), tostring(actorz), tostring(meshz), tostring(cpd), tostring(meshname)))
    end
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
        -- The cause for "all flags say visible but it's invisible" (the reproducible book):
        -- the per-book MID's "Opacity" is stuck < 1. Restore it via the mesh material -- the
        -- same GetMaterial(0) MID we logged at grab time (b.BookMatInst returned nil). Gated
        -- BOOK_OPACITY_FIX. Setting a scalar on the EXISTING actor MID is what the dormant
        -- material worker does -- NOT creating a MID on the HISM (the documented crash).
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
    -- inc5d: the broken book's IDENTITY (series) is correct but its DISPLAY is corrupt (out-of-
    -- range Tint colors like 2.0/3.0 + invisible, while every flag, scale, mesh position and pile
    -- read normal). The game's own RefreshInfo() re-derives a book's appearance from its BookInfo
    -- -- so on grab of an unwarded book, redraw it. Gated BOOK_REFRESH_FIX.
    if diag_on("BOOK_REFRESH_FIX") and unwarded_here == true then
        local ok = pcall(function() b:RefreshInfo() end)
        _bh.refreshed = (_bh.refreshed or 0) + 1
        if (_bh.refresh_samples or 0) < 20 then
            _bh.refresh_samples = (_bh.refresh_samples or 0) + 1
            log(("[book-hook] REFRESH series=%s ok=%s"):format(tostring(series), tostring(ok)))
        end
    end
end

-- ======================= PROACTIVE BOOK SWEEP (beta6.2, inc5) =======================
-- The grab-time fix (inc4) is reactive: a book that is BOTH invisible AND un-grabbable can
-- never be grabbed, so a grab-time repair never fires -> the player is stuck reloading. This
-- sweep instead walks ALL book actors on its own and repairs any UNWARDED book it finds in a
-- hidden state, with NO player action required.
--
-- Driver: the existing game-thread SetActorVisible POST-hook (fires constantly during play).
-- So the sweep needs ZERO ExecuteInGameThread of its own -> it CANNOT trip UE4SS #1180 (the
-- concurrent-tick-queue abort that bit layers 1/2), and its writes land on the game thread (no
-- render race). Work is chunked (SWEEP_BUDGET books per hook call) so there's no hitch; the
-- cursor wraps the full ~3072-book list every ~38s of normal play. If the player stands
-- perfectly still the sweep pauses -- benign, since no NEW desync forms while idle and it
-- resumes the moment they move.
--
-- Repairs the CERTAIN, safe signals: actor bHidden, the SM_Book_1 mesh hidden flag, and the
-- mesh VISIBILITY flag (bVisible -- distinct from bHiddenInGame; layer 1 only ever cleared the
-- actor flag, so a stuck mesh bVisible=false survives clearing bHidden, matching Bug 6). Also
-- re-enables collision so an unwarded book can't be left un-grabbable (covers symptom 1 too).
--
-- The book's BookMatInst "Opacity" is OBSERVED (logged) but NOT auto-written yet: GetScalar on a
-- material lacking the param returns 0, which would look like "every book invisible". We log the
-- normal value first; if stuck-at-0 proves to be a cause, the writer already exists
-- (M._start_material_worker uses SetScalarParameterValue("Opacity", v)) -- a one-line follow-up.
local SWEEP_BUDGET = 16
local _sweep_books, _sweep_n, _sweep_cursor, _sweep_epoch = nil, 0, 1, nil
local _sweep_unwarded = nil

local function _sweep_refresh()
    local IA = package.loaded["AP/ItemApply"]
    if not IA then return false end
    _sweep_books = FindAllOf("BP_GrabbingBook_C")
    _sweep_n = 0
    if _sweep_books then pcall(function() _sweep_n = #_sweep_books end) end
    _sweep_cursor = 1
    _sweep_epoch = IA._world_epoch
    if IA._compute_unwarded_set then
        local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
        _sweep_unwarded = IA._compute_unwarded_set(only_shelfable)
    else
        _sweep_unwarded = nil
    end
    return _sweep_n > 0
end

-- Inspect (and, if do_fix, repair) one unwarded book that should be fully visible.
local function _sweep_check_book(b, series, do_fix)
    local signals = {}
    local bhidden; pcall(function() bhidden = b.bHidden end)
    if bhidden == true then
        if do_fix then
            pcall(function() b:SetActorHiddenInGame(false) end)
            pcall(function() b:SetActorEnableCollision(true) end)
        end
        signals[#signals + 1] = "actorHidden"
    end
    local sm; pcall(function() sm = b.SM_Book_1 end)
    if sm and sm:IsValid() then
        local mh; pcall(function() mh = sm.bHiddenInGame end)
        if mh == true then
            if do_fix then pcall(function() sm:SetHiddenInGame(false, false) end) end
            signals[#signals + 1] = "meshHidden"
        end
        local vis; pcall(function() vis = sm.bVisible end)
        if vis == false then
            if do_fix then pcall(function() sm:SetVisibility(true, false) end) end
            signals[#signals + 1] = "meshVisible"
        end
    end
    local abnormal = #signals > 0
    -- read opacity when something's wrong (to diagnose) or to sample the normal value
    local want_op = abnormal or ((_bh.opacity_samples or 0) < 20)
    local opacity
    if want_op then
        pcall(function()
            local m = b.BookMatInst
            if m and m:IsValid() then opacity = m:GetScalarParameterValue("Opacity") end
        end)
    end
    if abnormal then
        _bh.swept = (_bh.swept or 0) + 1
        if (_bh.swept_samples or 0) < 40 then
            _bh.swept_samples = (_bh.swept_samples or 0) + 1
            log(("[book-sweep] %s series=%s signals=%s opacity=%s"):format(
                do_fix and "FIX" or "FOUND", tostring(series),
                table.concat(signals, "+"), tostring(opacity)))
        end
    elseif want_op then
        _bh.opacity_samples = (_bh.opacity_samples or 0) + 1
        log(("[book-sweep] sample series=%s opacity=%s (normal visible book)"):format(
            tostring(series), tostring(opacity)))
    end
end

-- One chunk of the proactive sweep. Called from the SetActorVisible post-hook (game thread).
local function _sweep_step()
    if not diag_on("BOOK_SWEEP") then return end
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._apply_safe and IA._book_valid_asset_idx and IA._asset_to_series) then return end
    -- world reloaded since we cached the list? drop it -- stale actor wrappers can native-AV.
    if _sweep_books and (IA._world_epoch or 0) ~= (_sweep_epoch or 0) then
        _sweep_books = nil
    end
    if not _sweep_books or _sweep_cursor > _sweep_n then
        if not _sweep_refresh() then return end
    end
    local uw = _sweep_unwarded
    if not uw then return end
    local do_fix = diag_on("BOOK_SWEEP_FIX")
    local last = math.min(_sweep_cursor + SWEEP_BUDGET - 1, _sweep_n)
    for i = _sweep_cursor, last do
        local b = _sweep_books[i]
        if b and b:IsValid() then
            local aidx = IA._book_valid_asset_idx(b)
            if aidx ~= nil then
                local series = IA._asset_to_series[aidx]
                if series and uw[series] then
                    pcall(_sweep_check_book, b, series, do_fix)
                end
            end
        end
    end
    _sweep_cursor = last + 1
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
            -- (inc5 timer-sweep SHELVED: it churned against the game's per-frame visibility
            -- Tick -- see the sweep block above + BOOK_SWEEP in diag_flags. Visibility is now
            -- corrected by riding the game's OWN SetActorVisible call: ENFORCE + REVEAL-complete
            -- below. The POST-hook -- 2nd RegisterHook cb -- never fires in this UE4SS build.)
            local b, v
            pcall(function() b = self:get() end)
            pcall(function() v = is_visible:get() end)
            _bh_sample("SetActorVisible", b, "vis=" .. tostring(v))
            -- Increment 2: ENFORCE. When the game tries to SHOW (v==true) a book whose
            -- series is WARDED, override the argument to false so the game's own
            -- SetActorVisible keeps it hidden -- no flicker, no re-entrancy (we change
            -- the argument, we don't re-call the function), no material-swap risk.
            -- Unwarded books are never touched (allowed to show), so an unlock takes
            -- effect the next time the game shows the book. Reads the LIVE unwarded set
            -- (same _compute_unwarded_set the pile uses), so it cannot lag behind it.
            if diag_on("BOOK_EVENT_ENFORCE") and v == true and b then
                local _, series = _bh_series(b)
                local IA = package.loaded["AP/ItemApply"]
                if series and IA and IA._compute_unwarded_set then
                    local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
                    local unwarded = IA._compute_unwarded_set(only_shelfable)
                    if not (unwarded and unwarded[series]) then
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
            -- REVEAL-complete (supersedes the dead post-hook REVEAL): when the game SHOWS an
            -- UNWARDED book (you looked at / approached it) it sets the actor visible but does
            -- NOT always restore the MESH -- a stuck SM_Book_1 bHiddenInGame / bVisible leaves
            -- the book "shown" yet invisible (Bug 6). Complete the show: clear the mesh hide
            -- flags + ensure collision (grabbable). Rides the game's own show call so the
            -- per-frame Tick keeps it -- no churn (unlike the shelved inc5 timer-sweep).
            if diag_on("BOOK_EVENT_REVEAL") and v == true and b then
                local _, rseries = _bh_series(b)
                local IA = package.loaded["AP/ItemApply"]
                if rseries and IA and IA._compute_unwarded_set then
                    local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
                    local unwarded = IA._compute_unwarded_set(only_shelfable)
                    if unwarded and unwarded[rseries] then
                        local sm; pcall(function() sm = b.SM_Book_1 end)
                        if sm and sm:IsValid() then
                            local mh, vis, op, mid
                            pcall(function() mh = sm.bHiddenInGame end)
                            pcall(function() vis = sm.bVisible end)
                            pcall(function() mid = sm:GetMaterial(0) end)
                            if mid and mid:IsValid() then op = _mid_scalar(mid, "Opacity") end
                            -- op < 1 = the stuck-transparent book (all flags say visible). Fix it
                            -- by restoring the MID's Opacity here too, so just LOOKING at the book
                            -- (the show that triggers the glitch) repairs it. Gated BOOK_OPACITY_FIX.
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
        end,
        -- Increment 3: REVEAL net (POST-hook; symptom 2 = the "vanishing" unlocked book).
        -- Runs AFTER the game's SetActorVisible. If the game tried to SHOW (v==true) an
        -- UNWARDED book but it is STILL hidden (bHidden==true) afterward -- the "fine after
        -- dropping, invisible when looked at / picked up" glitch -- clear the stale hide so
        -- it actually shows. Only fires on the real edge case, so the log's revealed=N is
        -- how often it was caught. SetActorHiddenInGame isn't hooked (no re-entrancy), and
        -- it's aligned with the game's own show intent (no fight). Gated BOOK_EVENT_REVEAL.
        function(self, is_visible)
            if not diag_on("BOOK_EVENT_HOOKS") then return end
            if not diag_on("BOOK_EVENT_REVEAL") then return end
            local b, v
            pcall(function() b = self:get() end)
            pcall(function() v = is_visible:get() end)
            if v ~= true or not b then return end
            local _, series = _bh_series(b)
            local IA = package.loaded["AP/ItemApply"]
            if not (series and IA and IA._compute_unwarded_set) then return end
            local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
            local unwarded = IA._compute_unwarded_set(only_shelfable)
            if not (unwarded and unwarded[series]) then return end   -- warded -> the pre-hook's job
            local still_hidden
            pcall(function() still_hidden = b.bHidden end)
            if still_hidden == true then
                pcall(function() b:SetActorHiddenInGame(false) end)
                _bh.revealed = _bh.revealed + 1
                if _bh.rev_samples < 10 then
                    _bh.rev_samples = _bh.rev_samples + 1
                    log(("[book-hook] REVEAL unwarded-but-hidden series=%s (cleared stale hide)"):format(
                        tostring(series)))
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
        -- Increment 4: GRAB-path observe + conservative fix (symptom 2 = "pickable book
        -- invisible", which SetActorVisible/REVEAL never sees). The shared _bh_grab_check
        -- runs from BOTH CanBeGrab (above; proven to fire) and GrabFromPlayer.
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


-- Runtime book visibility: hide warded shelves + REVEAL on unlock. Each book HISM is one cover
-- design = one series; classify its instances by a 2D spatial match to the nearest BP_GrabbingBook
-- actor -> series -> warded (via _compute_unwarded_set), majority-vote per shelf (robust to a few
-- mismatches). A warded shelf is hidden by turning the whole HISM component invisible
-- (SetVisibility/SetHiddenInGame false) -> it renders in NO pass, so no checker/depth/occlusion
-- residual; we also swap to M_APBookMask + clear custom data as a belt-and-suspenders, recording
-- the originals first. REVEAL: when a series unlocks (the unwarded set grows), the shelf is made
-- visible again and its ORIGINAL materials restored. Re-runs only when the unwarded set changes.
-- NOTE: a MID on the book HISM crashes this game (confirmed) -- never reintroduce CreateDynamicMaterial*.
local _b2_state = {}        -- [hi] = { hidden = bool, ns = N, mats = {[s] = origMaterial} }
local _b2_last_sig = nil
local _b2_running = false
local _b2_load_requested = false
local _b2_mat_ref = nil
-- v2 classifier (probe-confirmed: each pile-group / HISM is ONE series). Instead of
-- re-reading actor positions every pass (which drifts as books swap actor<->HISM and
-- can leak a warded cover), we ACCUMULATE each group's series votes across passes (its
-- instances' nearest actors) until a dominant, well-sampled leader locks in -- so an
-- occasional stacked-neighbor mis-vote averages out instead of deciding a small group
-- from one noisy pass. Hide/reveal is driven off that leader + the warded set:
-- deterministic, self-correcting, no flicker. The OLD spatial/conservative classifier
-- still runs each pass for COMPARISON logging ([b2-cmp]) only. Resets on world reload.
local _b2_group = {}   -- [hi] = { tally={series:count}, total, leader, leadn, locked }
-- Spatial cross-check (vote accumulation + index-vs-spatial mismatch logging) is
-- DISABLED. The index mapping (series = _asset_to_series[hi-1]) proved correct on both
-- fresh and resumed saves, so it drives book visibility alone. Flip this to true to
-- re-run the spatial classifier as a ground-truth comparison (e.g. to re-confirm the
-- HISM<->data order after a game patch). All the spatial code is kept, just gated.
local B2_SPATIAL_CROSSCHECK = false
local function apply_book_visibility()
    if not diag_on("BOOK_VISIBILITY") then return end
    if _b2_running then return end
    local IA = package.loaded["AP/ItemApply"]
    if not (IA and IA._compute_unwarded_set and IA._asset_to_series) then return end
    -- Snapshot the world epoch (bumped by reset_hism_state on every LoadMap). The
    -- game-thread chunk closure re-checks it before touching the captured HISM array;
    -- if the world reloaded between scheduling and running, it bails -- the captured
    -- arr/HISMs are freed, so arr[hi] would be a native AV that pcall can't catch
    -- (the main-menu teardown crash).
    local epoch0 = IA._world_epoch
    local mgr = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr and mgr:IsValid()) then return end
    local arr = nil; pcall(function() arr = mgr.HISMArray end)
    local hn = 0; if arr then pcall(function() hn = #arr end) end
    if hn == 0 then return end
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return end
    local bn = 0; pcall(function() bn = #books end)
    if bn == 0 then return end
    local ready = false
    pcall(function() local info = books[1].ItemInfo; if info and info:IsValid() then ready = true end end)
    if not ready then return end
    local mat = nil
    -- M_APBookMask is unreferenced, so LoadAsset can't pull it from the LogicMod pak.
    -- It must be hard-referenced by ModActor (a Material var named BookMaskMat) so it
    -- loads with the mod; read it from there. Fallback: StaticFindObject if already loaded.
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
    _b2_mat_ref = mat  -- pin against GC
    -- Periodic re-classification: run on EVERY call (every ~5s from the gameplay
    -- loop), NOT only when the unwarded set changes. The actor<->HISM swap fired
    -- by looking at / moving past a series reshuffles which books are static
    -- instances vs grabbable actors, so a pile-group classified correctly earlier
    -- can drift wrong -- an unwarded book's instance lands in a hidden group and
    -- vanishes. Re-running with fresh actor positions self-corrects that within
    -- one pass instead of waiting for the next unlock. Steady state is cheap: when
    -- nothing drifted, every group hits kept_hidden/kept_shown below (reads only,
    -- no HISM mutations). sig is kept only to label the log (set change vs drift).
    local only_shelfable = IA._slot_data and IA._slot_data.only_unward_shelfable_books == 1
    local unwarded = IA._compute_unwarded_set(only_shelfable) or {}
    local skeys = {}
    for k in pairs(unwarded) do skeys[#skeys + 1] = k end
    table.sort(skeys)
    local sig = #skeys .. ":" .. table.concat(skeys, "|")
    local sig_changed = (sig ~= _b2_last_sig)
    _b2_last_sig = sig
    _b2_running = true
    -- 2D nearest-match (X,Y only). HISM instance transforms are component-LOCAL, so
    -- their Z doesn't line up with the actor's WORLD Z -- including Z broke matching
    -- (113 -> 10 correct). X,Y line up, so match on those. Stacked books share X,Y
    -- (minor ambiguity, acceptable for now) but every instance gets classified.
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
    -- ONE ExecuteInGameThread per pass: CHUNK = hn processes ALL HISMs in a single
    -- game-thread call, so process_chunk never reschedules. The old per-chunk
    -- reschedule issued ~10 ExecuteInGameThread calls/pass; that churn (amplified by
    -- Stage 2's layer-1 burst) tripped UE4SS #1180 -- overlapping engine-tick actions
    -- -> abort() ("Abort signal received"). Chunking only ever existed to keep the
    -- ASYNC poll loop pumping, which is moot now the work runs on the game thread.
    -- One marshal/pass = minimal queue churn. (Cost: one ~400-HISM tick; a brief
    -- hitch on connect / unwarded-set change, acceptable vs an abort.)
    local cursor, CHUNK = 1, hn
    local newly_hidden, revealed, kept_hidden, kept_shown = 0, 0, 0, 0
    local n_new_hide, mismatch, leader_changed, n_locked = 0, 0, 0, 0
    -- run_chunk is forward-declared so process_chunk can reschedule through it
    -- (Lua binds the upvalue at process_chunk's definition, so the local must
    -- exist first). process_chunk = one chunk of HISM work (runs on the game
    -- thread); run_chunk = the game-thread driver that invokes it. See
    -- on_game_thread above.
    local run_chunk
    local function process_chunk()
        -- Teardown guard (runs on the game thread). If the world reloaded since this
        -- pass was scheduled (epoch changed), the captured `arr` + HISM components are
        -- from the freed old world; arr[hi] would be a native access violation that
        -- pcall CANNOT catch (the main-menu / LoadMap use-after-free). Bail without
        -- touching any captured ref -- the next pass re-resolves the new world fresh.
        if (IA._world_epoch or 0) ~= (epoch0 or 0) then
            _b2_running = false
            trace.mark("b2-stale-world", nil,
                "epoch " .. tostring(epoch0) .. " -> " .. tostring(IA._world_epoch))
            return
        end
        local last = math.min(cursor + CHUNK - 1, hn)
        for hi = cursor, last do
            local h; pcall(function() h = arr[hi] end)
            if h and h:IsValid() then
                local sm; pcall(function() sm = h.PerInstanceSMData end)
                local sn = 0; if sm then pcall(function() sn = #sm end) end
                -- DRIVER: the index mapping. hi == the series' position in the data
                -- order (hi==gi, confirmed on fresh + resumed saves), so the hi-th HISM's
                -- series is just _asset_to_series[hi-1] (AssetIdx hi-1). Deterministic,
                -- position- and shelving-independent, RESUME-SAFE, no warm-up: a row
                -- classifies correctly on the first pass regardless of save state.
                local idx_series = IA._asset_to_series[hi - 1]
                local should_hide_new
                if sn == 0 then should_hide_new = false
                elseif idx_series == nil then should_hide_new = true   -- mapping not populated yet -> assume warded
                else should_hide_new = (not unwarded[idx_series]) end
                if should_hide_new then n_new_hide = n_new_hide + 1 end

                -- SPATIAL CROSS-CHECK -- DISABLED (B2_SPATIAL_CROSSCHECK=false). Kept
                -- verbatim for reference / re-validation: the per-instance nearest-actor
                -- vote, the vote accumulation + size-aware lock, and the index-vs-spatial
                -- mismatch log that proved the index mapping correct. The index lookup
                -- above made all of this unnecessary; flip the flag on to re-run it as a
                -- ground-truth comparison (e.g. to re-confirm the data order after a patch).
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

                -- Apply the NEW verdict (no freeze -- the cache is stable, no flicker).
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
        if cursor <= hn then
            LoopAsync(50, function() run_chunk() return true end)
        else
            _b2_running = false
            -- Index mapping drives; spatial vote is the cross-check. Log when anything
            -- changed OR the two disagree, so we can watch the index correct conflated rows.
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
                    -- diagnostic: split the still-unlocked groups into SPLIT (leader <70% ->
                    -- conflated, the residual leak risk) vs clean (high-confidence, just not
                    -- yet vote-saturated). List the split ones so we see exactly what they are.
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
    -- Driver: run ONE chunk's HISM work on the GAME THREAD (on_game_thread).
    -- process_chunk does all the UObject reads/writes and, while chunks remain,
    -- reschedules via LoopAsync -> run_chunk -- which bounces back onto the async
    -- thread before the next ExecuteInGameThread, so we never nest
    -- ExecuteInGameThread calls (UE4SS issue #1180). The body is pcall-guarded and
    -- ALWAYS clears _b2_running on error: a throw that left the flag set would wedge
    -- layer 3 permanently (every later pass early-returns on _b2_running, so the
    -- pile would never hide or reveal again -- a likely cause of the field report
    -- where the pile stopped re-revealing after the unwarded set grew).
    run_chunk = function()
        on_game_thread(function()
            local ok, err = pcall(process_chunk)
            if not ok then
                _b2_running = false
                trace.mark("b2-chunk-error", nil, tostring(err))
                log("[b2] chunk error -> cleared _b2_running: " .. tostring(err))
            end
        end)
    end
    if sig_changed then
        log("[b2] unwarded-set change -> re-evaluate (NEW drives off cached series, OLD logged for comparison)")
    end
    run_chunk()
end


-- v1.1.0 (rewrite): emit a lifecycle state-machine event. No-op until the SM
-- module is loaded (see the require below). The SM is OBSERVATIONAL for now —
-- these events drive its state + [lifecycle] logging, but it gates nothing yet.
local function lc_event(name)
    pcall(function()
        local L = package.loaded["AP/lifecycle"]
        if L and L[name] then L[name]() end
    end)
end

log("Loading Librarian-AP")

-- Native level-up grants 1 free skill point. For AP play that's invalid
-- — skills are granted via AP items (Progressive Sort / Progressive
-- Auto-Shelving / etc.) so we zero out EnableUpgradeNum on each OnLevelUp.
local suppress_levelup = true

-- ============================================================
-- AP integration state
-- ============================================================

-- Set true around AP-delivered UpgradePlayer calls so the UpgradePlayer hook
-- doesn't echo the call back as a "key pickup" location check.
local _ap_grant = false

-- AP location ID layout (mirrors apworld/librarian/Locations.py).
-- (Row, level, and milestone IDs are owned by ItemApply for state-sync logic;
-- main.lua only needs the chest-opening IDs since the UpgradePlayer hook —
-- which fires when the chest grants its ability — lives here.)
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
-- The game uses GameInstance.SaveGameName as the slot name for
-- UGameplayStatics::SaveGameToSlot/LoadGameFromSlot. Default is "Sav"
-- (file: <UserDir>/Saved/SaveGames/Sav.sav). For AP runs we point this
-- at "Sav_AP_<seed>_<slot>" so each AP seed has its own save file and
-- doesn't clobber the player's normal save.

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

-- Read a fingerprint of the in-memory GameSaveData so we can tell whether
-- a forced reload actually swapped the contents. Returns "valid:<rows>r/<books>b/bgm=<n>"
-- or "<invalid>"/"<no-savegamedata>".
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
-- The other title buttons (Options / Quit / How to Play / etc.) are left
-- alone.

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

-- Vanilla latch: set true when the player clicks "Close" on the AP connection
-- window (ModActor.BroadcastCloseRequest). It enables the real Continue/New Game
-- buttons and makes EVERY gameplay modification gate off (warding, book-hiding,
-- level-up suppression, tracking) -- the mod becomes fully passive. One-way for
-- the session: only relaunching the game re-enables connecting.
local _vanilla_mode = false

local function update_title_buttons()
    local widget = find_title_widget()
    if not widget then return end  -- not at title screen

    local APClient = package.loaded["AP/APClient"]
    local connected = APClient and APClient._slot_connected

    local enable_continue, enable_start = false, false

    if connected then
        local IA = package.loaded["AP/ItemApply"]
        local pre_apply_pending = IA and IA._allow_pre_apply and not IA._pre_apply_complete
        if pre_apply_pending then
            log("[title-buttons] connected; pre-apply in progress → buttons disabled")
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
-- WBP_Title.Text_Version is the bottom-right version line. We overwrite
-- it with: <Game version> | LibAP vX.YY | AP: <state>. If GetProjectVersion
-- isn't in TESTED_GAME_VERSIONS, append "(UNTESTED)" so the player knows
-- compatibility isn't validated against their game build.

local MOD_VERSION = "1.1.0-beta6.1"
local TESTED_GAME_VERSIONS = { "1.0.8" }

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

-- Logging-only: tv:SetText(luaString) crashes (UE expects an FText that
-- UE4SS Lua doesn't auto-wrap from a Lua string). Composing the text and
-- reading the existing field is safe; an actual overwrite would need a
-- companion UMG widget BP that owns its own text element.
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

-- Lookup helper. Uses package.loaded so we can call it before main.lua's
-- `local APClient = require(...)` line at the bottom has resolved (the hooks
-- registered above run later, by which time package.loaded is populated).
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

-- M01 LoadMap counter. The title screen loads M01 as a background once;
-- the actual gameplay save-load loads it a second time. We use the counter
-- as the primary signal for whether the player is actually in gameplay
-- when the player picks "New Game" (which forces a fresh LoadMap).
--
-- The "Continue" path is different: M01 is already loaded from the title
-- screen, and the game just transitions UI state. There's no second
-- LoadMap. So we ALSO watch BP_LibrarianGameInstance.SelectedLevel for a
-- -1 → ≥0 transition (set when the player picks any save). The activation
-- function below is idempotent so both paths can converge safely.
local m01_load_count = 0
-- Set just before our forced OpenLevel(PL_M01) on AP connect. Cleared by
-- the next M01 LoadMap hook. Tells the LoadMap handler to NOT bump
-- m01_load_count for that load (and therefore not incorrectly infer
-- in_gameplay) — user is still at the title screen.
local _suppress_next_m01_load_count = false
local _gameplay_loops_started = false
local _pre_apply_settle_state = nil  -- {empty_ticks, reapplies_done} during pre-apply settle
local _reconnect_settle_state = nil  -- {last_item_tick, quiet_ticks, total_ticks} during mid-game reconnect

local function start_gameplay_loops()
    if _gameplay_loops_started then return end
    _gameplay_loops_started = true

    -- Apply-gate retry loop: wait for books to fully populate before mutating
    -- the world. Cheap once gate passes (returns true immediately).
    local APPLY_MIN_TICKS    = 10   -- 5s of grace before mutating
    local APPLY_MIN_BOOKS    = 1000
    local APPLY_SAMPLE_SIZE  = 50
    local APPLY_MIN_DISTINCT = 5
    local APPLY_GIVEUP_TICKS = 40   -- 20s

    local apply_attempts = 0
    LoopAsync(500, function()
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
                    -- Split ItemInfo access to defend against a UE4SS
                    -- reflection-layer AV (Failure.Hash e40fc030...).
                    -- Direct b.ItemInfo.AssetIdx hands a possibly-stale
                    -- sub-UObject ref to UE4SS, which crashes in IsA /
                    -- resolve_function_address before pcall can catch it.
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
                log(("LoadMap apply-gate → giving up after %d attempts (books=%d distinct=%d ticks_ok=%s)")
                    :format(apply_attempts, n, distinct, tostring(enough_ticks)))
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
            -- During pre-apply: the settle loop below fires flush_apply once
            -- items quiet down. Otherwise (gameplay-active path): trigger
            -- the flush now as before.
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
    LoopAsync(500, function()
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
            -- Hold the draining phase while either the chunked Pass-1
            -- flush is still running OR the hidden-mode deferred
            -- tree-walk worker is still draining. Both are async; the
            -- world isn't truly settled until both have idled.
            if IA._flush_in_progress or IA._deferred_worker_running then
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

    -- Reconnect-settle watcher. While ItemApply has its
    -- _reconnect_settle_active flag set (mid-gameplay slot_data refresh),
    -- the AP server is re-sending every received item one at a time. We
    -- want to apply them all THEN do one flush_apply with the fully
    -- rebuilt state — otherwise bookcases flicker hidden as
    -- shelves_open[X] grows back from zero per item. apply_item already
    -- defers flush_apply while the flag is set; this watcher fires the
    -- single flush_apply once the item storm has quieted and clears the
    -- flag. Mirrors the pre-apply settle loop but is gated on a
    -- different flag and runs alongside the rest of the gameplay loops.
    LoopAsync(500, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        -- Tie lifecycle to the same "are we still in gameplay context"
        -- check the 5-second loop uses — die when we leave gameplay so
        -- the next entry can spawn a fresh one.
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

        -- Fire once items have been quiet for ≥2 ticks (1s) OR we've
        -- waited 10 ticks (5s) total as a safety net. Either way, one
        -- flush_apply runs with the fully-rebuilt state and we clear
        -- the settle flag so subsequent apply_item calls go through
        -- the normal per-item path again.
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
    LoopAsync(5000, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        -- Keep running during the post-connect pre-apply window too, so
        -- bookcase drift is corrected in the background.
        if not (IA._gameplay_active or IA._allow_pre_apply) then
            _gameplay_loops_started = false   -- allow restart on next entry
            return true
        end
        if not IA._apply_safe then return false end
        pcall(try_register_book_hooks)   -- beta6 inc1: one-shot observe-hook register (game thread)
        pcall(bh_report_periodic)        -- beta6 inc1: ~30s [book-hook] count report
        -- [crumb] BAE1A5E0 crash-hunt (TEMP): the LAST "[crumb]" line in the log
        -- before a crash names the periodic op that was mid-flight. "idle:*" means
        -- none of ours was running -> the game's own tick (e.g. on an object the mod
        -- left in a bad state). Remove once the culprit is found.
        log("[crumb] idx");  pcall(function() IA.refresh_index_if_changed() end)
        log("[crumb] ward"); pcall(function() IA._apply_bookcases_to_world() end)
        log("[crumb] idle:5s")
        pcall(apply_book_visibility) -- async; postdates BAE1A5E0, so left uncrumbed
        return false
    end)

    -- Periodic milestone / level sync. Book-placement milestones fire from
    -- GameSaveData.GameProgressData.InsertedBookNum, which the game updates
    -- as the player places books. The FinishRow hook above only fires when
    -- a ROW completes — so a player who places many books without finishing
    -- rows (mid-sort, mis-shelving and recovering, etc.) wouldn't trigger
    -- their milestones until the next row completion. This 3-second poll
    -- closes that gap. Level-ups are event-driven via OnLevelUp, so this
    -- loop is mostly milestones in practice.
    LoopAsync(3000, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        -- Stop only when fully out of gameplay/pre-apply context (matches
        -- the 5-second loop's lifecycle above). Returning true here ENDS
        -- the loop permanently; the early-exit-on-gameplay-false bug we
        -- shipped originally killed the loop at startup before gameplay
        -- ever became active, so progress sync never ran.
        if not (IA._gameplay_active or IA._allow_pre_apply) then
            _gameplay_loops_started = false   -- allow restart on next entry
            return true
        end
        -- During pre-apply (title menu), keep the loop alive but skip the
        -- sync — InsertedBookNum / level data aren't meaningful yet.
        if not IA._gameplay_active then return false end
        if not IA._apply_safe then return false end
        if not IA._slot_data then return false end
        log("[crumb] sync")
        pcall(function() IA.sync_progress_state() end)
        -- Also re-run row-completion detection periodically. FinishRow
        -- only fires when the global row count INCREASES — so if the
        -- player removes a completed series and replaces it with a
        -- different one in the same row slot, the new completion goes
        -- undetected until the count grows again. Polling here catches
        -- those swap completions promptly. detect_completed_rows is
        -- idempotent (de-dup via _sent_row_locations), so re-running
        -- when nothing has changed is a no-op.
        log("[crumb] detect")
        pcall(function() IA.detect_completed_rows() end)
        log("[crumb] rowchecks")
        -- Row-completion threshold catch-up: read rows_finished from the
        -- save and re-fire any "Complete N Rows" threshold whose value
        -- the player has now reached. Belt-and-suspenders for cases
        -- where run_baseline_sync ran with stale GameSaveData and
        -- silently skipped thresholds; fire_row_completion_checks is
        -- idempotent (de-dup via _sent_row_completions) and send_check
        -- itself dedupes against the server's _sent_checks, so this is
        -- a safe periodic re-evaluation.
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
        -- Section-completion check: detect_completed_rows above may have
        -- just added the last row of a section to _sent_row_locations
        -- (swap-completion path that doesn't go through FinishRow).
        -- Re-run the section-completion sweep so its location fires
        -- without waiting for the next FinishRow event. Idempotent —
        -- _sent_section_completions guards against re-firing.
        pcall(function() IA.fire_section_completions() end)
        -- Floor-completion check: same reasoning at a coarser
        -- granularity. The section-sweep above may have just closed
        -- out the last section in a floor; re-run the floor sweep
        -- so its check fires this tick instead of waiting for the
        -- next FinishRow. Idempotent.
        pcall(function() IA.fire_floor_completions() end)
        -- Skill resync: if save-side level lags the received item count
        -- (e.g., a UpgradePlayer call dropped silently when the player
        -- was mid-transition), retry the missing applies. Idempotent
        -- and conservative — never over-grants past received counts.
        log("[crumb] resync")
        pcall(function() IA.resync_skill_state() end)
        log("[crumb] idle:3s")
        return false
    end)

    -- Periodic book straggler re-walk every 3 minutes (hidden mode only).
    -- The initial tree-walk can miss a component or two — e.g., a book
    -- whose mesh sub-components weren't fully streamed in when its
    -- tree-walk ran. Re-queueing the known-warded books catches these.
    -- Spread out enough that the queue drain (~10s of background work)
    -- doesn't constantly run.
    LoopAsync(180000, function()
        local IA = package.loaded["AP/ItemApply"]
        if not IA then return false end
        if not IA._gameplay_active then
            return true  -- stop; will restart on next gameplay activation
        end
        if not IA._apply_safe then return false end
        if not (IA._slot_data and IA._slot_data.book_visibility == "hidden") then
            return false  -- stacked mode doesn't use tree-walk
        end
        local queued = 0
        pcall(function() queued = IA.requeue_warded_books_for_treewalk() or 0 end)
        log(("[periodic-rewalk] re-queued %d warded books for tree-walk"):format(queued))
        return false
    end)

    -- First-movement detection. The title menu has the previous save loaded
    -- behind the scenes, so reading GameSaveData (rows finished, books
    -- placed) at apply-safe time can return stale values — we observed
    -- spurious "Reached Level 1" / "Milestone: 50 Books Placed" checks
    -- firing for fresh New Game saves that inherited the previous run's
    -- counters. Player movement only becomes possible once the new save's
    -- state has fully taken over in memory, so we use it as the trigger
    -- for baseline syncs (row catch-up + level/milestone catch-up).
    local title_pos = nil
    LoopAsync(500, function()
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
    -- Only activate the mod's gameplay processing when connected to AP. In Vanilla
    -- mode (or simply not connected) we stay fully passive: no warding, no
    -- book-hiding, no apply loops, no tracking. This is the single gate that covers
    -- every world mutation regardless of which path (button / SelectedLevel watcher
    -- / LoadMap) tried to activate.
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
    -- Reset the apply-gate guard so the next gameplay entry runs the
    -- LoopAsync again. Without this, returning to title and clicking
    -- Continue a second time skips set_apply_safe(true), which means
    -- books never re-ward (bookcases hide via a different path so the
    -- bug only manifests as "books visible, cases hidden").
    _gameplay_loops_started = false
end

-- SelectedLevel watcher (handles "Continue" path where no LoadMap fires).
-- BP_LibrarianGameInstance_C.SelectedLevel is -1 at title and >= 0 once the
-- player has picked a save. We poll once per second and activate/deactivate
-- on transitions.
local _prev_selected_level = -1
LoopAsync(1000, function()
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

RegisterLoadMapPostHook(function(Engine, World)
    local lvlname = "<unknown>"
    pcall(function() lvlname = World:get():GetFullName() end)
    log("LoadMap post: " .. lvlname)

    -- Determine in_gameplay.
    -- We tried using GameSaveData/LibrarianGameMode to differentiate title
    -- screen from real play; both are non-null at title. The most reliable
    -- signal in observed traces is "this is the 2nd+ M01 LoadMap" — first
    -- M01 LoadMap is title-screen preview, second is when player actually
    -- loaded their save. SelectedLevel is a secondary positive signal
    -- (>= 0 only after player picks a level).
    local in_gameplay = false
    if lvlname:find("PL_M01", 1, true) then
        -- If this LoadMap is from our forced OpenLevel (on AP connect),
        -- the user is still at the title screen — don't count it toward
        -- the gameplay-detection threshold. The user will click Continue
        -- afterward; HideTitleMenu hook will activate gameplay at the
        -- correct moment.
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

        -- Fresh world load → reset our HISM mapping state regardless of
        -- whether it's our forced reload or natural — previous captured
        -- transforms refer to the old world.
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA.reset_hism_state then IA.reset_hism_state() end

        -- Book-visibility (cosmetic pile-hiding) is per-world: the fresh world's HISM
        -- components start visible AND the per-group series snapshot is tied to the old
        -- world's actors, so clear both -- this world re-snapshots its series cache and
        -- re-hides from scratch. Without this a Menu->Continue keeps stale "already
        -- hidden" flags and a stale series cache.
        _b2_state = {}
        _b2_last_sig = nil
        _b2_group = {}

        -- Re-arm the apply-gate for this fresh world. Menu→Continue reloads M01 but
        -- never calls deactivate_gameplay, so _apply_safe stays true and the
        -- loop-started guard stays set → the apply-gate LoopAsync never re-runs, the
        -- "wait for the SL_M01_BG sublevel actors to stream" step is skipped, and
        -- the warding indexes 0 bookcases → cases stay un-warded (signs still light,
        -- since labels live in the persistent level). Reset both so the
        -- start_gameplay_loops() call below actually re-runs the gate: re-wait for
        -- the new world's actors, then re-index + re-ward. (Mirrors deactivate_gameplay.)
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

    -- Don't echo AP-delivered grants back as location checks.
    -- Check both legacy local flag (always false now) and ItemApply._ap_grant
    -- which is set true around AP-driven UpgradePlayer calls.
    do
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA._ap_grant then return end
    end
    if _ap_grant then return end

    -- Minor Magic chest openings (idx 0/1/2/4) → AP chest location check.
    -- UpgradePlayer fires when the chest grants its ability, so this hook
    -- catches the chest-opening event (not the earlier key pickup). The
    -- native ability grant (Jump/Run/Bag/Bag2) proceeds normally; AP just
    -- records the chest opening as a location check. Major Magic point
    -- spends (idx 3/5/6/7/8) are filtered by the table miss.
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
-- Read-only diagnostics. UE4SS hook callbacks always receive `self` as the
-- first argument (even for static UFunctions), then the function params.
-- Param accessors return wrapper objects; FString needs :ToString().
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
    -- After save, GameSaveData.InsertedBookNum is fresh — re-run the
    -- progress sync so book milestones catch up. This is a safety net for
    -- the in-between window where our own BP-hook counter might miss an
    -- event (or hasn't been wired correctly yet).
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.sync_progress_state and IA._gameplay_active
            and IA._apply_safe and IA._slot_data then
        pcall(function() IA.sync_progress_state() end)
    end
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

-- OnLevelUp / ShowSkillLevelUp are redeclared on BP_LibrarianCharacter, so the
-- runtime call dispatches to the BP version. Hook both paths and tag which one
-- fires; we only need the BP-path hook to register after the BP class is loaded.
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

    -- Use event-based level increment. Reading CurrentFinishedRowNum at this
    -- moment is unreliable (game hasn't yet committed the row update before
    -- firing OnLevelUp). One increment per fired event keeps us in sync.
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.on_level_up_event then
        pcall(function() IA.on_level_up_event() end)
    end
end

-- Title-widget button handlers. The title screen's Continue button does NOT
-- always fire LoadMap or LoadGameFromSlot — when the M01 level is already
-- pre-loaded behind the title, Continue just hides the title and unpauses.
-- We hook the button-press event itself to detect the title→gameplay
-- transition, then force activate_gameplay() so flush_apply runs.
local function on_title_load_game_pressed(self)
    log(">> [WBP_Title] Continue/LoadGame button pressed")
    log(("    SaveGameName='%s'  GameSaveData: %s"):format(
        tostring(read_save_slot()), snapshot_save_data()))

    -- (The earlier auto-reload via gi:LoadGameData(0) was removed: with
    -- the OpenLevel(PL_M01) we now trigger at slot-connect, the world
    -- and GameSaveData are already loaded from the AP slot by the time
    -- Continue fires. Re-loading the save here additionally re-applied
    -- bag-skill level increments through the game's load post-processing,
    -- bumping the bag capacity past its intended cap on every reload.)

    -- Force gameplay activation on the next tick so AP item application runs
    -- even if the game doesn't fire LoadMap. We delay slightly so the title
    -- widget's own handler runs first (level transition / UI hide).
    LoopAsync(100, function()
        local IA = package.loaded["AP/ItemApply"]
        if APClient and APClient._slot_connected and IA and not IA._gameplay_active then
            activate_gameplay("WBP_Title.LoadGame button → forced")
        end
        return true  -- one-shot
    end)
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

-- Fire once per game session: shows a 12s notification at the title
-- screen with mod + game version and a compatibility marker. Helps the
-- player notice if they're running an untested game version.
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
    -- Use an explicit notify call (no state mutation, custom 12s duration).
    local HUD = package.loaded["AP/HUD"]
    if HUD and HUD.notify then HUD.notify(msg, 12.0) end
end

local function on_title_construct(self)
    log(">> [WBP_Title] Construct")
    -- Defer slightly so the widget's own Construct logic runs first (button
    -- bindings, default styles). Then we apply the AP-gating state and
    -- overwrite Text_Version with our composite "Game v? | LibAP v? | AP: ?"
    -- status line.
    LoopAsync(50, function()
        update_title_buttons()
        update_title_status_text()
        notify_version_compat()
        return true
    end)
end

-- BP-path hooks: defer to first LoadMap so the BP class is loaded.
-- (register_bp_hooks_once was forward-declared above near the LoadMap hook.)
local bp_hooks_registered = false
register_bp_hooks_once = function()
    if bp_hooks_registered then return end
    local ok1 = hook_safe("/Game/Librarian/Blueprints/Character/BP_LibrarianCharacter.BP_LibrarianCharacter_C:OnLevelUp",
        "OnLevelUp (BP)", on_level_up_bp)
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

    -- Connection-menu signal: the Connect button calls
    -- ModActor.BroadcastConnectRequest with the three field strings. We
    -- read them, push them into APClient, and trigger the deferred
    -- connect.
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

    -- Close button on the AP window -> player declined to connect: latch Vanilla
    -- mode (mirrors the Connect path; the pak's ModActor needs a BroadcastCloseRequest
    -- custom event wired to Btn_Close.OnClicked). Until that pak event exists this
    -- hook just defers harmlessly. enter_vanilla() is reached via the global menu
    -- table because hook callbacks can't see this file's locals.
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
-- FinishRow gives a global running counter (Nth row completed) but doesn't
-- tell us which (section, series) was completed. To resolve that, we ask
-- ItemApply to compare its per-bookcase RowStatus snapshot against current
-- state and emit checks for any newly-completed rows. The ordinal `row`
-- parameter is logged for diagnostics only.
-- Goal-completion latch: set true the first time we send STATUS_GOAL so
-- a re-fire (e.g., row 200 → row 201 in half goal) doesn't double-send.
-- Reset on slot_connected / disconnected.
local _goal_sent = false

-- Goal-progress milestones: announce at 25/50/75% so the player has a
-- sense of pace through the goal. Each breakpoint fires at most once
-- per connection; cleared in lockstep with _goal_sent.
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

    -- Goal trigger by row count (for non-full goals). Full goal lets the
    -- game's natural EndGame fire when the player walks through the end
    -- door. Custom / floor_1 / floor_2 goals fire STATUS_GOAL as soon
    -- as their threshold row is finished.
    -- Options.py defines option_full=0 (the others are 1/2/3) — must
    -- compare goal against 0, not 1, or custom goals never fire.
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

    local IA = package.loaded["AP/ItemApply"]
    -- detect_completed_rows() is deliberately NOT called here. It walks
    -- PlacingBookInfo, and on the FinishRow frame the just-placed final book
    -- is mid-conversion (freed sub-object) → native EXCEPTION_ACCESS_VIOLATION
    -- that pcall cannot catch. This is THE row-completion crash. The 3s poll
    -- (start_gameplay_loops) runs detection at a stable time instead — the
    -- per-(section,series) checks fire within ~3s of completing a row, which is
    -- fine for AP. The calls below use the row counter + Lua state only (no
    -- book deref), so they stay here for immediacy.
    -- Fire any "Complete N Rows" milestone checks the player has now
    -- reached. `row` is the game's authoritative correct-row counter
    -- (FinishRow only fires when a row is actually completed in-game,
    -- so we trust this value).
    if IA and IA.fire_row_completion_checks and row then
        local rc_sent = 0
        pcall(function() rc_sent = IA.fire_row_completion_checks(row) end)
        if rc_sent > 0 then
            log(("[AP] row-completion: sent %d location check(s)"):format(rc_sent))
        end
    end
    -- Fire any "Section Complete: <id>" checks whose section just hit
    -- 100% row completion. detect_completed_rows above populates
    -- _sent_row_locations for the rows finished this tick, so checking
    -- whether the section is now fully shelved is cheap. The server's
    -- _sent_checks won't have the section loc yet (we never sent it
    -- without this hook), so APClient.send_check will actually transmit.
    if IA and IA.fire_section_completions then
        local sec_sent = 0
        pcall(function() sec_sent = IA.fire_section_completions() end)
        if sec_sent > 0 then
            log(("[AP] section-completion: sent %d location check(s)"):format(sec_sent))
        end
    end
    -- Fire "Floor N Complete" if this row closed out the last section
    -- on a floor. fire_floor_completions uses _sent_row_locations as
    -- the truth source so order-of-firing with section-complete above
    -- doesn't matter.
    if IA and IA.fire_floor_completions then
        local floor_sent = 0
        pcall(function() floor_sent = IA.fire_floor_completions() end)
        if floor_sent > 0 then
            log(("[AP] floor-completion: sent %d location check(s)"):format(floor_sent))
        end
    end
    -- Also sync milestones (book count) and any level-ups whose threshold
    -- was crossed during this row's completion.
    if IA and IA.sync_progress_state then
        local lvl_sent, ms_sent = 0, 0
        pcall(function() lvl_sent, ms_sent = IA.sync_progress_state() end)
        if (lvl_sent or 0) + (ms_sent or 0) > 0 then
            log(("[AP] progress: %d level(s), %d milestone(s)"):format(lvl_sent, ms_sent))
        end
    end
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

-- Crash-ledger heartbeat: a flushed 1 Hz marker so a post-crash read of crash_trace.log
-- reveals how long after the mod's last mutation the crash landed — i.e. whether the
-- fault was synchronous-in-op (tail = unmatched BEG) or decoupled/idle (tail = several
-- "hb" lines after the last END). CR1 ("crash ~1 min after a series unlock") would show
-- ~60 hb lines between the last b2-reveal and the crash.
LoopAsync(1000, function() trace.mark("hb"); return false end)

-- v1.1.0 (rewrite): the lifecycle state machine. Now driven by EVENTS at the
-- real signal points (lc_event(...) calls below) rather than a polling derive
-- loop. Still OBSERVATIONAL — it logs [lifecycle] transitions but gates nothing
-- yet; once the event-driven flow is confirmed across connect/play/reconnect we
-- cut the scattered gates over to it. The require is pcall'd so it can never
-- break mod loading.
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

    -- HUD: classify by sender. player=0 means server (starting items /
    -- the bulk re-dump on slot connect — we LOG these but skip the
    -- on-screen popup since the dump can flood the BP notification
    -- system. player=our_slot is a self-completed check echo, anything
    -- else is from another player in the multiworld.
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
    -- During pre-apply (post-connect title, before player clicks Continue),
    -- silence ALL item toasts. Self-sent re-deliveries (the player's own
    -- previously-completed checks) crowd out the "Preparing world..." status
    -- message. Items still get logged + applied; only the on-screen toast
    -- is suppressed.
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

-- Outgoing location check → "You sent ITEM to PLAYER (LOCATION)".
-- All native lookups (item_name / player_alias / location_name) happened
-- in the location_info handler when the scout response arrived; on_check_sent
-- just reads the cache. Falls back to "→ loc N" if the location isn't in
-- the cache (scout response not yet returned, or a non-AP location id).
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

    -- Force a fresh world reload now that SaveGameName points to the
    -- AP slot. The boot-time world was loaded with default 'Sav' state;
    -- without this, BP_GrabbingBook + HISM render data remains stale
    -- ("books in default-save orientation until you look at them").
    -- We trigger OpenLevel(PL_M01) only if we're still at title (not
    -- mid-gameplay, e.g. a reconnect during play would be disruptive).
    -- Defer 200ms so set_save_slot + slot-data store all settle first.
    LoopAsync(200, function()
        local IA = package.loaded["AP/ItemApply"]
        if IA and IA._gameplay_active then
            log("[AP][save] mid-gameplay reconnect — skipping forced level reload")
            return true
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
        return true  -- one-shot
    end)

    -- Update title-screen buttons + Text_Version line. Done via async tick
    -- so the redirected SaveGameName is the one we read.
    LoopAsync(50, function()
        update_title_buttons()
        update_title_status_text()
        return true
    end)

    -- HUD: status line + clear stale log entries from prior connect.
    HUD.set_status(("AP: connected as %s (slot #%s)"):format(
        tostring(APClient.slot or "?"),
        tostring(APClient.slot_number or -1)),
        HUD.COL_STATUS_OK)
    HUD.clear_log()
    -- Connect menu: status + auto-hide on success. The status message is
    -- short-lived — once the menu hides, the player sees the title screen
    -- with Continue disabled while pre-apply runs (status surfaces on
    -- Text_Version line below).
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

    -- Let the starting-item dump flow immediately during pre-apply: items
    -- update derived state (series_unlocked, sections, etc.) but the
    -- per-item flush is suppressed (see ItemApply.apply_item). The settle
    -- loop will fire ONE flush_apply once items quiet down — that way
    -- the world is warded exactly once with final state, instead of
    -- 14× wasteful flushes that ward-then-unward the starting series.
    APClient:set_in_game(true)

    -- Tell the player a wait is coming. Pre-apply takes ~10–20s depending
    -- on book count and book_visibility mode. Long duration so the toast
    -- stays visible across the whole window.
    if HUD and HUD.notify then
        HUD.notify("AP: Preparing world — Continue will enable when ready...", 30.0)
    end
end

APClient.on_disconnected = function()
    log("[AP] disconnected")
    restore_save_slot()
    _goal_sent = false
    _progress_milestones_fired = {}
    -- Clear pre-apply state so a reconnect starts the whole sequence
    -- fresh (otherwise the buttons could enable prematurely or the
    -- settle loop would think it's already done).
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.clear_pre_apply then IA.clear_pre_apply() end
    _pre_apply_settle_state = nil
    -- With AP no longer connected, both gameplay buttons return to the
    -- disabled-by-default state.
    LoopAsync(50, function()
        update_title_buttons()
        update_title_status_text()
        return true
    end)
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
    LoopAsync(50, function()
        update_title_status_text()
        return true
    end)
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

-- Initial HUD status. Wait briefly so the world / player exists for the
-- WorldContextObject argument to PrintString.
LoopAsync(2000, function()
    HUD.set_status(
        ("AP: not connected (server=%s, slot=%s) — F4 for menu, F12 to connect"):format(
            tostring(APClient.server or "?"),
            tostring(APClient.slot or "?")),
        HUD.COL_STATUS_WARN)
    return true  -- one-shot
end)

-- F12: connect to Archipelago (or trigger a reconnect if the socket dropped).
RegisterKeyBind(Key.F12, function()
    if not APClient._slot_connected then
        log("[F12] connecting to AP...")
        APClient:connect()
    else
        log("[F12] already connected")
    end
end)

log("Press F12 to connect to Archipelago.")

-- ============================================================
-- Connection menu (F4 toggle, default on)
--
-- ModActor (in LibrarianAPHUDFix.pak) hosts a UMG widget with
-- Server / Slot / Password fields plus a Connect button. The
-- Connect button calls ModActor.BroadcastConnectRequest with the
-- three strings; we hook that below and feed them into APClient.
-- Status callbacks drive the on-widget status line so the player
-- sees Connecting / Connected / Refused without alt-tabbing to
-- the UE4SS log.
-- ============================================================
local _menu_initial_shown = false
-- Gate the initial show on M01 being the loaded level. The Intro level
-- (game splash) also spawns a ModActor, but its widget gets destroyed
-- when Intro unloads — so we wait until we know we're on M01.
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

RegisterKeyBind(Key.F4, function()
    log("[F4] toggle connection menu")
    menu_toggle()
end)

-- TEMP custom-data probe (F6). Question: does any HISM PerInstanceCustomData float
-- encode the book's AssetIdx/series? If yes, we can hide warded books PER-INSTANCE
-- (accurate even for stacked books) instead of the spatial whole-group guess that
-- occasionally leaks a warded cover. Press F6 in-game while the pile is visible,
-- then send the UE4SS.log. Remove this once answered.
local function probe_customdata()
    log("[cd-probe] === START ===")
    local mgr = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr and mgr:IsValid()) then log("[cd-probe] no BP_HISM_Manager_C (load a save first)"); return end
    local arr; pcall(function() arr = mgr.HISMArray end)
    local hn = 0; if arr then pcall(function() hn = #arr end) end
    if hn == 0 then log("[cd-probe] HISMArray empty"); return end

    -- Ground truth: distinct AssetIdx values from book actors.
    local books = FindAllOf("BP_GrabbingBook_C")
    local bn = 0; if books then pcall(function() bn = #books end) end
    local aset, acount, amin, amax = {}, 0, math.huge, -math.huge
    for i = 1, bn do
        local b = books[i]
        if b and b:IsValid() then
            local ai
            pcall(function() local info = b.ItemInfo; if info and info:IsValid() then ai = info.AssetIdx end end)
            if ai and ai >= 0 then
                if not aset[ai] then aset[ai] = true; acount = acount + 1 end
                if ai < amin then amin = ai end
                if ai > amax then amax = ai end
            end
        end
    end
    log(("[cd-probe] %d book actors, %d distinct AssetIdx (range %s..%s)"):format(
        bn, acount, tostring(amin), tostring(amax)))

    -- Custom floats per instance = len(PerInstanceSMCustomData) / numInstances.
    local NUM = 0
    for hi = 1, hn do
        local h; pcall(function() h = arr[hi] end)
        if h and h:IsValid() then
            local sn = 0; pcall(function() sn = #h.PerInstanceSMData end)
            local cl = 0; pcall(function() cl = #h.PerInstanceSMCustomData end)
            if sn > 0 and cl > 0 then NUM = math.floor(cl / sn); break end
        end
    end
    if NUM == 0 then log("[cd-probe] no PerInstanceSMCustomData found"); return end
    log(("[cd-probe] %d custom floats per instance"):format(NUM))

    local dist, mn, mx, intlike, inA = {}, {}, {}, {}, {}
    for k = 0, NUM-1 do dist[k]={}; mn[k]=math.huge; mx[k]=-math.huge; intlike[k]=true; inA[k]=0 end
    local sampled, raw = 0, 0
    local step = math.max(1, math.floor(hn / 80))   -- ~80 HISMs spread across the pile
    for hi = 1, hn, step do
        local h; pcall(function() h = arr[hi] end)
        if h and h:IsValid() then
            local sn = 0; pcall(function() sn = #h.PerInstanceSMData end)
            local cd; pcall(function() cd = h.PerInstanceSMCustomData end)
            if cd and sn > 0 then
                for j = 0, sn-1 do
                    local row = {}
                    for k = 0, NUM-1 do
                        local v = 0; pcall(function() v = cd[j*NUM + k + 1] end)
                        v = tonumber(v) or 0
                        row[k] = v
                        dist[k][math.floor(v*100+0.5)/100] = true
                        if v < mn[k] then mn[k]=v end
                        if v > mx[k] then mx[k]=v end
                        if math.abs(v - math.floor(v+0.5)) > 0.01 then intlike[k]=false end
                        if aset[math.floor(v+0.5)] then inA[k]=inA[k]+1 end
                    end
                    sampled = sampled + 1
                    if raw < 6 then
                        raw = raw + 1
                        local p = {}; for k=0,NUM-1 do p[#p+1]=string.format("%.2f", row[k]) end
                        log(("[cd-probe] raw hi=%d j=%d: [%s]"):format(hi, j, table.concat(p, ",")))
                    end
                end
            end
        end
    end
    log(("[cd-probe] sampled %d instances"):format(sampled))
    for k = 0, NUM-1 do
        local dc = 0; for _ in pairs(dist[k]) do dc = dc + 1 end
        log(("[cd-probe] cd[%2d] distinct=%-4d min=%-9.2f max=%-9.2f int=%-5s in_assetidx=%d/%d"):format(
            k, dc, mn[k], mx[k], tostring(intlike[k]), inA[k], sampled))
    end
    log(("[cd-probe] === END (winner = a float with int=true, distinct~%d, in_assetidx~%d) ==="):format(acount, sampled))
end

RegisterKeyBind(Key.F6, function()
    log("[F6] running custom-data probe")
    pcall(probe_customdata)
end)

-- Poll for ModActor on startup and show the menu once. Subsequent shows
-- are user-driven via F4 — auto-show on disconnect is handled in the
-- on_disconnected handler.
LoopAsync(500, function()
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
