-- probe.lua -- in-game feasibility probe harness.  DEV ONLY.
-- Loaded by main.lua only when diag_flags.PROBE_MODE == true (explicit true; missing diag flags
-- default ON, so main.lua gates on the raw value, not diag_on()). Strip this file + its flag + the
-- main.lua require before release.
--
-- Crash discipline (mirrors the shipping mod):
--   * every reflection touch is pcall-wrapped; IsValid at point of use; array counts capped.
--   * NO os.clock (os.date only).  Render/light refs looked up on demand, never cached.
--   * The WHOLE probe body runs on the GAME thread via ExecuteInGameThread. Keybind callbacks
--     fire on the UE4SS async thread; running probe Lua there could race the mod's game-thread
--     Lua and corrupt the shared lua_State. Marshaling serializes it.
--
-- Output: Mods/Librarian-AP/probe.log (append, flushed per line) + [PROBE] lines in the UE4SS console.

local TAG = "PROBE"

local function clog(msg)
    print(("[%s] %s\n"):format(TAG, tostring(msg)))
end

-- ---- dedicated flushed log file (append; survives a hard native crash) --------------------
local LOG_PATH = "Mods/Librarian-AP/probe.log"
local _f, _open_ok
pcall(function() _f = io.open(LOG_PATH, "a"); _open_ok = (_f ~= nil) end)

local function _hms()
    local ok, s = pcall(function() return os.date("%H:%M:%S") end)
    return (ok and s) or "??:??:??"
end

-- P = the probe's log line: console + flushed file.
local function P(msg)
    clog(msg)
    if _open_ok and _f then
        local ok = pcall(function()
            _f:write(("%s %s"):format(_hms(), tostring(msg))); _f:write("\n"); _f:flush()
        end)
        if not ok then _open_ok = false end
    end
end

-- Run a probe body on the GAME thread (see header). Falls back to inline if the marshaler
-- is unavailable (older UE4SS) -- then it runs on the keybind thread, so we warn.
local function on_gt(fn)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(fn)
    else
        P("WARN: ExecuteInGameThread unavailable -- running on keybind thread (less safe)")
        fn()
    end
end

-- ---- small reflection helpers -------------------------------------------------------------
local function safe_len(arr)
    local n = 0
    if arr then pcall(function() n = #arr end) end
    return n
end

local function class_name(obj)
    local s = "?"
    pcall(function() s = obj:GetClass():GetFName():ToString() end)
    return s
end

local function full_name(obj)
    local s = "?"
    pcall(function() s = obj:GetFullName() end)
    return s
end

local function IA() return package.loaded["AP/ItemApply"] end

-- Read a book's ItemInfo sub-object safely: split access, IsValid the sub-UObject (a stale
-- ItemInfo AVs natively on the next field read -- a chained book.ItemInfo.AssetIdx crashes).
local function book_info(book)
    if not (book and book:IsValid()) then return nil end
    local info
    pcall(function() info = book.ItemInfo end)
    if not (info and info:IsValid()) then return nil end
    return info
end

-- ---- F5: book identity / Chapter (the BookSanity decider) ---------------------------------
local _dumped_fields = false
local _last_ids = nil   -- { [fullname] = {aidx=, chap=} } from the previous press, for a stability diff

-- One-time: enumerate every property name/type on the ItemInfo struct + its supers, to find
-- Chapter (and any other per-volume field).
local function dump_iteminfo_fields(info)
    P("--- ItemInfo field dump (one-time; find any per-volume field) ---")
    local ok = pcall(function()
        local cls = info:GetClass()
        local guard = 0
        while cls and cls:IsValid() and guard < 12 do
            guard = guard + 1
            local cn = "?"; pcall(function() cn = cls:GetFName():ToString() end)
            P(("  [struct %s]"):format(cn))
            cls:ForEachProperty(function(Prop)
                local pn, pt = "?", "?"
                pcall(function() pn = Prop:GetFName():ToString() end)
                pcall(function() pt = Prop:GetClass():GetFName():ToString() end)
                P(("    %-30s %s"):format(pn, pt))
            end)
            local super
            pcall(function() super = cls:GetSuperStruct() end)
            cls = super
        end
    end)
    if not ok then P("  (field dump failed)") end
end

local function probe_book_identity()
    P("=== [F5] BOOK IDENTITY / Chapter probe ===")
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then P("no BP_GrabbingBook_C found (load a save + walk to the shelves first)"); return end
    local n = safe_len(books)
    if n == 0 then P("0 books loaded (load a save + walk to the shelves first)"); return end
    P(("live books loaded: %d"):format(n))

    local ia = IA()
    local a2s = (ia and ia._asset_to_series) or {}
    local a2v = (ia and ia._asset_to_volumes) or {}
    if not ia then P("(ItemApply not loaded -- reporting raw AssetIdx/Chapter without series names)") end

    -- one-time: dump all ItemInfo field names from the first valid book
    if not _dumped_fields then
        for i = 1, math.min(n, 40) do
            local info = book_info(books[i])
            if info then dump_iteminfo_fields(info); _dumped_fields = true; break end
        end
    end

    -- sample densely: need multiple books per series to confirm volume coverage/uniqueness.
    -- Iterate all loaded books (bounded); invalid orphans skipped. n can be ~2x the volume count
    -- (two world instances, or two actors per volume) -- we report the multiplicity.
    local MAXIT = 8000
    local limit = math.min(n, MAXIT)
    local per = {}          -- [aidx] = { chapters={set}, count, cmin, cmax, chap_nil, dups }
    local snap = {}         -- [fullname] = { aidx, chap } for the stability diff
    local sampled, with_chapter, chapter_nonzero = 0, 0, 0

    for i = 1, limit do
        local book = books[i]
        local info = book_info(book)
        if info then
            local aidx, chap, mesh_ok
            pcall(function() aidx = info.AssetIdx end)
            pcall(function() chap = info.Chapter end)
            pcall(function() local m = info.Mesh; mesh_ok = (m and m:IsValid()) or false end)
            -- valid book: aidx>0, or aidx==0 with a real mesh (0 is section 1A's first series)
            if aidx ~= nil and (aidx > 0 or (aidx == 0 and mesh_ok)) then
                sampled = sampled + 1
                local rec = per[aidx]
                if not rec then
                    rec = { chapters = {}, count = 0, cmin = math.huge, cmax = -math.huge, chap_nil = 0, dups = false }
                    per[aidx] = rec
                end
                rec.count = rec.count + 1
                local c = tonumber(chap)
                if chap == nil then
                    rec.chap_nil = rec.chap_nil + 1
                else
                    with_chapter = with_chapter + 1
                    if c and c ~= 0 then chapter_nonzero = chapter_nonzero + 1 end
                    if c then
                        if rec.chapters[c] then rec.dups = true else rec.chapters[c] = true end
                        if c < rec.cmin then rec.cmin = c end
                        if c > rec.cmax then rec.cmax = c end
                    end
                end
                -- record every sampled valid book (chap may be nil) so the stability diff also
                -- catches Chapter flakiness, not just value changes.
                snap[full_name(book)] = { aidx = aidx, chap = c }
            end
        end
    end

    P(("sampled %d valid books of %d loaded; %d had a readable Chapter, %d non-zero"):format(
        sampled, limit, with_chapter, chapter_nonzero))

    -- per-series coverage analysis. The game may keep >1 actor per (series,volume), so a repeated
    -- Chapter is expected, not a failure. Chapter is the volume index if a series' distinct chapters
    -- fit its volume range and ideally cover it (distinct == volumes). Failures: a chapter out of
    -- range, more distinct chapters than the series has volumes, or a nil read.
    local aids = {}
    for aidx in pairs(per) do aids[#aids + 1] = aidx end
    table.sort(aids)
    local fails, examples = {}, {}
    local full_cov, subset, base0, base1 = 0, 0, 0, 0
    local tot_count, tot_distinct = 0, 0
    for _, aidx in ipairs(aids) do
        local rec = per[aidx]
        local distinct = 0
        for _ in pairs(rec.chapters) do distinct = distinct + 1 end
        tot_count = tot_count + rec.count
        tot_distinct = tot_distinct + distinct
        local vols = a2v[aidx]
        if vols and distinct > 0 then
            local fits0 = (rec.cmin >= 0 and rec.cmax <= vols - 1)
            local fits1 = (rec.cmin >= 1 and rec.cmax <= vols)
            if fits0 and not fits1 then base0 = base0 + 1 end
            if fits1 and not fits0 then base1 = base1 + 1 end
            local over = distinct > vols
            if over or (not fits0 and not fits1) or rec.chap_nil > 0 then
                fails[#fails + 1] = { aidx = aidx, series = a2s[aidx], vols = vols,
                    distinct = distinct, cmin = rec.cmin, cmax = rec.cmax, nils = rec.chap_nil, over = over }
            elseif distinct == vols then
                full_cov = full_cov + 1
                if #examples < 8 then examples[#examples + 1] = { aidx = aidx, series = a2s[aidx],
                    vols = vols, cmin = rec.cmin, cmax = rec.cmax, count = rec.count } end
            else
                subset = subset + 1
            end
        end
    end

    P(("SUMMARY: %d series sampled | full coverage (distinct==volumes): %d | partial (streaming): %d | FAILURES: %d"):format(
        #aids, full_cov, subset, #fails))
    P(("         base-fit votes -> 0-indexed(0..v-1): %d   1-indexed(1..v): %d"):format(base0, base1))
    if tot_distinct > 0 then
        P(("         actor multiplicity: %d book-actors / %d distinct (series,volume) = %.2fx per volume"):format(
            tot_count, tot_distinct, tot_count / tot_distinct))
    end
    P("  -- full-coverage examples (saw every volume of the series) --")
    for _, e in ipairs(examples) do
        P(("     aidx %3d %-32s vols=%d chapters=%d..%d actors=%d"):format(
            e.aidx, tostring(e.series):sub(1, 32), e.vols, e.cmin, e.cmax, e.count))
    end
    if #fails > 0 then
        P(("  -- FAILURES (%d shown, up to 20) --"):format(math.min(#fails, 20)))
        for i = 1, math.min(#fails, 20) do
            local ff = fails[i]
            P(("     aidx %3d %-30s vols=%d distinct=%d range=%d..%d nil=%d %s"):format(
                ff.aidx, tostring(ff.series):sub(1, 30), ff.vols, ff.distinct, ff.cmin, ff.cmax, ff.nils,
                ff.over and "DISTINCT>VOLS" or "OUT-OF-RANGE"))
        end
    end

    -- verdict
    if with_chapter == 0 then
        P("VERDICT: ItemInfo.Chapter is NOT readable -> per-volume identity via Chapter FAILS.")
    elseif chapter_nonzero == 0 then
        P("VERDICT: Chapter is always 0 across all samples -> NOT a per-volume index.")
    elseif #fails > 0 then
        P(("VERDICT: Chapter has %d PROBLEM series (out-of-range, or more distinct chapters than volumes) -> NOT a clean per-volume id. Inspect the failures above."):format(#fails))
    else
        local base = (base0 >= base1) and 0 or 1
        P(("VERDICT: Chapter IS a clean per-volume id. Every sampled series fits its volume range; %d showed FULL coverage. Inferred base = %d."):format(full_cov, base))
        P(("         -> per-volume BookSanity is FEASIBLE. Map volume_number = Chapter%s in the apworld."):format(base == 0 and " + 1" or ""))
    end

    -- stability diff vs previous press (move a book / reload, then press again)
    if _last_ids then
        local reseen, changed = 0, 0
        for fn, cur in pairs(snap) do
            local prev = _last_ids[fn]
            if prev then
                reseen = reseen + 1
                if prev.chap ~= cur.chap or prev.aidx ~= cur.aidx then
                    changed = changed + 1
                    if changed <= 10 then
                        P(("  STABILITY CHANGE ...%s  aidx %s->%s  chap %s->%s"):format(
                            fn:sub(-34), tostring(prev.aidx), tostring(cur.aidx), tostring(prev.chap), tostring(cur.chap)))
                    end
                end
            end
        end
        P(("STABILITY: %d/%d re-seen books changed identity since last press (0 = stable)."):format(changed, reseen))
    end
    _last_ids = snap
    P("=== [F5] done ===")
end

-- ---- F1: hide / un-hide one book (BookSanity gameplay-loop test) ---------------------------
-- Toggle: first press hides one valid book (actor-level, reversible); press again to restore.
-- Re-finds the book by full name each time (never caches the ref across frames).
local _hidden_fullname = nil

local function probe_hide_toggle()
    local books = FindAllOf("BP_GrabbingBook_C")
    local n = safe_len(books)
    if n == 0 then P("[F1] no books loaded"); return end

    if _hidden_fullname then
        local done = false
        for i = 1, n do
            local b = books[i]
            if b and b:IsValid() and full_name(b) == _hidden_fullname then
                pcall(function() b:SetActorHiddenInGame(false) end)
                pcall(function() b:SetActorEnableCollision(true) end)
                done = true
                break
            end
        end
        P(("[F1] UN-HID ...%s (%s)"):format(_hidden_fullname:sub(-40), done and "ok" or "not re-found"))
        _hidden_fullname = nil
        return
    end

    -- hide one valid, initialized book
    for i = 1, n do
        local b = books[i]
        local info = book_info(b)
        if info then
            local aidx, mesh_ok
            pcall(function() aidx = info.AssetIdx end)
            pcall(function() local m = info.Mesh; mesh_ok = (m and m:IsValid()) or false end)
            if aidx and (aidx > 0 or mesh_ok) then
                local fn = full_name(b)
                pcall(function() b:SetActorHiddenInGame(true) end)
                pcall(function() b:SetActorEnableCollision(false) end)
                _hidden_fullname = fn
                local ia = IA()
                local series = ia and ia._asset_to_series and ia._asset_to_series[aidx]
                P(("[F1] HID one book: aidx=%s series=%s  ...%s"):format(
                    tostring(aidx), tostring(series or "?"), fn:sub(-40)))
                P("     Now try to shelve/complete that book's row with it hidden. Press F1 again to restore.")
                P("     NOTE: collision is OFF too, so you can't grab this copy. Watch whether the row still")
                P("     auto-validates from the already-placed (now invisible) book vs. needing a fresh grab --")
                P("     that distinguishes 'row completes with a volume absent' from 'invisible but still placed'.")
                return
            end
        end
    end
    P("[F1] no valid book found to hide")
end

-- ---- F2: control-surface scan (Traps effects, Deathlink receive, revoke-magic) -------------
local LIGHT_CLASSES = {
    "DirectionalLight", "PointLight", "SpotLight", "SkyLight", "SkyAtmosphere",
    "PostProcessVolume", "ExponentialHeightFog", "SkyAtmosphereComponent",
    "DirectionalLightComponent", "PointLightComponent",
}

local function fn_exists(obj, name)
    local exists = false
    pcall(function() exists = (obj[name] ~= nil) end)
    return exists
end

local function probe_control_surface()
    P("=== [F2] control-surface scan ===")
    P("-- lights / sky (Traps 'lights out / night'): --")
    for _, cls in ipairs(LIGHT_CLASSES) do
        local arr = FindAllOf(cls)
        local cnt = safe_len(arr)
        local eg = ""
        if cnt > 0 and arr[1] and arr[1]:IsValid() then eg = "e.g. " .. class_name(arr[1]) end
        P(("   %-28s = %d  %s"):format(cls, cnt, eg))
    end

    P("-- player pawn + skill fns (revoke-magic trap): --")
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if player and player:IsValid() then
        P("   player pawn: found")
        for _, fn in ipairs({ "UpgradePlayer", "DowngradePlayer", "SetAbilityLevel", "RemoveAbility", "ResetAbility" }) do
            P(("     fn %-18s : %s"):format(fn, fn_exists(player, fn) and "EXISTS" or "-"))
        end
    else
        P("   player pawn: NOT found (enter gameplay first)")
    end

    P("-- bookcase effect fns (Deathlink scatter / return): --")
    local cases = FindAllOf("BookCaseBase")
    if safe_len(cases) == 0 then cases = FindAllOf("BP_BookCase_C") end
    local cn = safe_len(cases)
    if cn > 8 then cn = 8 end
    local checked = false
    for i = 1, cn do   -- check a few cases so a variant lacking a fn doesn't give a false "-"
        local c = cases[i]
        if c and c:IsValid() then
            P(("   sample case[%d]: %s"):format(i, class_name(c)))
            for _, fn in ipairs({ "BackToCorrectPlace", "ReturnBookToCase", "SetPlacingBookInfo", "ScatterBooks" }) do
                P(("     fn %-18s : %s"):format(fn, fn_exists(c, fn) and "EXISTS" or "-"))
            end
            checked = true
            break
        end
    end
    if not checked then P("   no bookcase found") end
    P("=== [F2] done ===")
end

-- ---- F3: placement watch on the nearest case (BookSanity check side + Deathlink detection) --
-- Finds the case nearest the player, then diffs its slots vs the previous press -- so placing one
-- book shows up as "slot X: PLACED series/volume". Reports per-shelf RowStatus (the game's per-shelf
-- correct+ordered signal) and, for grid cases, the volumes on each complete shelf. Verifies we can
-- detect + identify a per-book placement and read its correctness.
local _watch_snap = {}   -- [case_fullname] = { slots = {[slot]={aidx,chap}}, rows = {[shelf]=bool} }

local function actor_loc(a)
    local x, y, z
    pcall(function() local v = a:K2_GetActorLocation(); x, y, z = v.X, v.Y, v.Z end)
    return x, y, z
end

local function nearest_case()
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not (player and player:IsValid()) then return nil, nil, "no player pawn" end
    local px, py, pz = actor_loc(player)
    if not px then return nil, nil, "player location unreadable" end
    local cases = FindAllOf("BookCaseBase")
    if safe_len(cases) == 0 then cases = FindAllOf("BP_BookCase_C") end
    local n = safe_len(cases); if n > 400 then n = 400 end
    local best, bestd = nil, math.huge
    for i = 1, n do
        local c = cases[i]
        if c and c:IsValid() then
            local cx, cy, cz = actor_loc(c)
            if cx then
                local dx, dy, dz = cx - px, cy - py, cz - pz
                local d = dx * dx + dy * dy + dz * dz
                if d < bestd then best, bestd = c, d end
            end
        end
    end
    if not best then return nil, nil, "no case locations readable" end
    return best, math.sqrt(bestd), nil
end

local function slot_book(pbi, slot)
    local info = book_info(pbi and pbi[slot])
    if not info then return nil end
    local aidx, chap
    pcall(function() aidx = tonumber(info.AssetIdx) end)
    pcall(function() chap = tonumber(info.Chapter) end)
    if aidx == nil then return nil end
    return { aidx = aidx, chap = chap }
end

local function probe_placement_watch()
    P("=== [F3] placement watch (nearest case) ===")
    local ia = IA()
    local a2s = (ia and ia._asset_to_series) or {}
    local a2sec = (ia and ia._asset_to_section) or {}

    local case, dist, err = nearest_case()
    if not case then P("no nearest case: " .. tostring(err) .. " -- stand facing a bookcase in gameplay"); return end
    local fn = full_name(case)
    P(("nearest case: %s  dist=%s"):format(class_name(case), dist and ("%.0f"):format(dist) or "?"))

    local rs = nil; pcall(function() rs = case.RowStatus end)
    local rs_n = safe_len(rs)
    local pbi = nil; pcall(function() pbi = case.PlacingBookInfo end)
    local pbi_n = safe_len(pbi); if pbi_n > 256 then pbi_n = 256 end

    local cur_slots, cur_rows = {}, {}
    for slot = 1, pbi_n do cur_slots[slot] = slot_book(pbi, slot) end
    for s = 1, rs_n do local d = false; pcall(function() local v = rs[s]; d = (v == true or v == 1) end); cur_rows[s] = d end

    local prev = _watch_snap[fn]
    if prev then
        local changes = 0
        for slot = 1, pbi_n do
            local a, b = prev.slots[slot], cur_slots[slot]
            local ak = a and (a.aidx .. ":" .. tostring(a.chap)) or "-"
            local bk = b and (b.aidx .. ":" .. tostring(b.chap)) or "-"
            if ak ~= bk then
                changes = changes + 1
                if b then
                    P(("   slot %d: PLACED aidx=%d chap=%s -> %s vol %s (home section %s)"):format(
                        slot, b.aidx, tostring(b.chap), tostring(a2s[b.aidx] or "?"),
                        tostring((b.chap or -1) + 1), tostring(a2sec[b.aidx])))
                else
                    P(("   slot %d: REMOVED (was aidx=%d chap=%s)"):format(slot, a.aidx, tostring(a.chap)))
                end
            end
        end
        for s = 1, rs_n do
            if prev.rows[s] ~= cur_rows[s] then
                P(("   shelf %d RowStatus %s -> %s"):format(s, tostring(prev.rows[s]), tostring(cur_rows[s])))
            end
        end
        P(("   %d slot change(s) since last press"):format(changes))
    else
        P("   baseline captured -- place (or remove) a book on this case, then press F3 again to see the change.")
    end

    local occ = 0; for slot = 1, pbi_n do if cur_slots[slot] then occ = occ + 1 end end
    local done = 0; for s = 1, rs_n do if cur_rows[s] then done = done + 1 end end
    P(("   occupancy %d/%d slots | shelves complete %d/%d (RowStatus = the game's per-shelf correct+ordered signal)"):format(
        occ, pbi_n, done, rs_n))

    local per_row = (rs_n > 0 and pbi_n > 0 and pbi_n % rs_n == 0) and math.floor(pbi_n / rs_n) or 0
    if done > 0 and per_row > 0 then
        for s = 1, rs_n do
            if cur_rows[s] then
                local vols = {}
                for slot = (s - 1) * per_row + 1, s * per_row do
                    local b = cur_slots[slot]
                    if b then vols[#vols + 1] = ("%d:v%s"):format(b.aidx, tostring((b.chap or -1) + 1)) end
                end
                P(("   COMPLETE shelf %d volumes: %s"):format(s, table.concat(vols, " ")))
            end
        end
    elseif done > 0 then
        P("   (complete shelves present but PBI is non-grid here -- slot->shelf mapping not derivable; per-book still readable per slot above)")
    end

    _watch_snap[fn] = { slots = cur_slots, rows = cur_rows }
    P("=== [F3] done ===")
end

-- ---- F7: correctness scan -- the game stores per-book correctness in a "Is Abs Correct" bool ----
-- (note the spaces in the property name). Scan every book, count/list those with Is Abs Correct ==
-- true, and diff vs the last press -- so placing one book correctly (gold) shows "+CORRECT <series>
-- vol N". This is the BookSanity check signal: fire a (series, volume) check for each book that
-- becomes Is Abs Correct. No slot geometry, no mixed-cabinet problem -- the game's own per-book verdict.
local _last_correct = nil
local function probe_correctness_scan()
    P("=== [F7] correctness scan (Is Abs Correct) ===")
    local ia = IA()
    local a2s = (ia and ia._asset_to_series) or {}
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then P("no books loaded"); return end
    local n = safe_len(books); if n > 8000 then n = 8000 end

    local cur, count, need_fx = {}, 0, 0
    for i = 1, n do
        local b = books[i]
        if b and b:IsValid() then
            local ok_correct, nfx
            pcall(function() ok_correct = b["Is Abs Correct"] end)
            pcall(function() nfx = b.NeedPlayCorrectEffect end)
            if nfx == true then need_fx = need_fx + 1 end
            if ok_correct == true then
                count = count + 1
                local aidx, chap
                local info = book_info(b)
                if info then
                    pcall(function() aidx = tonumber(info.AssetIdx) end)
                    pcall(function() chap = tonumber(info.Chapter) end)
                end
                cur[full_name(b)] = { aidx = aidx, chap = chap }
            end
        end
    end
    P(("books=%d | Is Abs Correct==true: %d | NeedPlayCorrectEffect==true: %d"):format(n, count, need_fx))

    if _last_correct then
        local added, removed = 0, 0
        for fn, e in pairs(cur) do
            if not _last_correct[fn] then
                added = added + 1
                if added <= 25 then
                    P(("   +CORRECT %s vol %s (aidx=%s chap=%s)"):format(
                        tostring(a2s[e.aidx] or "?"), tostring((e.chap or -1) + 1), tostring(e.aidx), tostring(e.chap)))
                end
            end
        end
        for fn in pairs(_last_correct) do if not cur[fn] then removed = removed + 1 end end
        P(("   change since last press: +%d correct, -%d no-longer-correct"):format(added, removed))
    else
        P("   baseline captured -- now place a book CORRECTLY (gold) and press F7 again to see '+CORRECT'.")
    end
    _last_correct = cur
    P("If a correct placement shows '+CORRECT series vol N', BookSanity's CHECK side is proven: poll books, fire that volume's check when 'Is Abs Correct' flips true.")
    P("=== [F7] done ===")
end

-- ---- F8: per-instance HISM teleport feasibility (read-only). Hiding whole piles removes the
-- backfill the game's actor<->pile toggle relies on, so unlocked books flicker; instead keep piles
-- visible and teleport only locked books' pile instances to deep Z. Each book actor should expose
-- HISMController (its HISM component) + MovingIndex (its instance index) -- a direct book->instance
-- map. This confirms that map + dumps the UpdateInstanceTransform / GetInstanceTransform signatures
-- so the teleport is written against the real API. Pure reflection reads + one const read, no mutation.
-- Dump a UFunction's parameter list. Walks the superclass chain -- native funcs like
-- UpdateInstanceTransform live on a parent (UInstancedStaticMeshComponent), not the leaf class.
local function dump_fn_sig(obj, fname)
    if not (obj and obj:IsValid()) then P(("  (no object to dump %s)"):format(fname)); return end
    local cls; pcall(function() cls = obj:GetClass() end)
    local found, guard = false, 0
    while cls and cls:IsValid() and not found and guard < 12 do
        guard = guard + 1
        pcall(function()
            cls:ForEachFunction(function(fn)
                local nm = "?"; pcall(function() nm = fn:GetFName():ToString() end)
                if nm == fname then
                    found = true
                    P(("  === %s(...) params ==="):format(fname))
                    pcall(function()
                        fn:ForEachProperty(function(prop)
                            local pn, pt = "?", "?"
                            pcall(function() pn = prop:GetFName():ToString() end)
                            pcall(function() pt = prop:GetClass():GetFName():ToString() end)
                            P(("      %-28s %s"):format(pn, pt))
                            return 0
                        end)
                    end)
                end
                return 0
            end)
        end)
        local super; pcall(function() super = cls:GetSuperStruct() end)
        cls = super
    end
    if not found then P(("  %s: NOT FOUND on %s (or supers)"):format(fname, class_name(obj))) end
end

local function probe_hism_teleport_feasibility()
    P("=== [F8] HISM teleport API + instance structure (read-only) ===")
    local ia = IA()
    local a2v = (ia and ia._asset_to_volumes) or {}
    local mgr = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr and mgr:IsValid()) then P("no HISM manager -- enter gameplay first"); return end
    local arr = nil; pcall(function() arr = mgr.HISMArray end)
    local hn = safe_len(arr)
    P(("HISMArray=%d components"):format(hn))

    -- (1) MANAGER route: it routes by BookInfo. List its UFunctions + dump the promising ones.
    P("-- manager (BP_HISM_Manager_C) UFunctions --")
    local mcls; pcall(function() mcls = mgr:GetClass() end)
    local mfns = {}
    if mcls then
        pcall(function()
            mcls:ForEachFunction(function(fn)
                local nm = "?"; pcall(function() nm = fn:GetFName():ToString() end)
                mfns[#mfns + 1] = nm
                return 0
            end)
        end)
    end
    P("   " .. (table.concat(mfns, ", ")):sub(1, 700))
    dump_fn_sig(mgr, "UpdateInstance")
    dump_fn_sig(mgr, "HideBook")
    dump_fn_sig(mgr, "SetVisibility")

    -- (2) COMPONENT route: HISMArray[i] is the real HISM. Index-based UE API lives here.
    local comp; pcall(function() comp = arr[1] end)
    if comp and comp:IsValid() then
        P(("-- HISM component[1] = %s --"):format(class_name(comp)))
        local ic = "?"; pcall(function() ic = tostring(comp:GetInstanceCount()) end)
        P(("   GetInstanceCount=%s"):format(ic))
        dump_fn_sig(comp, "UpdateInstanceTransform")
        dump_fn_sig(comp, "GetInstanceTransform")
        -- Read instance 0's transform -- learn how UE4SS returns the OUT FTransform. Try several
        -- forms (out-param passed as nil / table / real struct). Each pcall'd + logged.
        P("   -- GetInstanceTransform(0) read attempts (nail the out-param form) --")
        local function dumpT(tag, ...)
            local rets = { ... }
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = type(rets[i]) .. ":" .. tostring(rets[i]) end
            P(("     %s => %s"):format(tag, table.concat(parts, " | ")))
            for i = 1, select("#", ...) do
                local o = rets[i]
                if o ~= nil and type(o) ~= "boolean" then
                    local x, y, z
                    pcall(function() x = o.Translation.X; y = o.Translation.Y; z = o.Translation.Z end)
                    if z ~= nil then P(("        ret[%d].Translation=(%s,%s,%s)"):format(i, tostring(x), tostring(y), tostring(z))) end
                end
            end
        end
        pcall(function() dumpT("(idx,nil,ws)", comp:GetInstanceTransform(0, nil, true)) end)
        pcall(function() dumpT("(idx,{},ws)", comp:GetInstanceTransform(0, {}, true)) end)
        pcall(function() dumpT("(idx,ws)", comp:GetInstanceTransform(0, true)) end)

        -- Book actor transform: an alternative transform SOURCE (actors are co-located with their
        -- pile instance). Confirms K2_GetActorTransform shape + whether Translation is readable.
        local books = FindAllOf("BP_GrabbingBook_C")
        local b = books and books[1]
        if b and b:IsValid() then
            pcall(function()
                local t = b:K2_GetActorTransform()
                P(("   book K2_GetActorTransform => %s"):format(tostring(t)))
                if t ~= nil then
                    local x, y, z
                    pcall(function() x = t.Translation.X; y = t.Translation.Y; z = t.Translation.Z end)
                    P(("      actor T.Translation=(%s,%s,%s)"):format(tostring(x), tostring(y), tostring(z)))
                end
            end)
            pcall(function()
                local l = b:K2_GetActorLocation()
                P(("   book K2_GetActorLocation => (%s,%s,%s)"):format(tostring(l.X), tostring(l.Y), tostring(l.Z)))
            end)
        end
    else
        P("   HISMArray[1] not valid")
    end

    -- (3) Mapping sanity: per-series HISM instance count vs the series' volume count. If instances
    -- == volumes, an instance index likely == chapter (index-route mapping); if not, we use the
    -- manager BookInfo route instead.
    P("-- per-series HISM instance counts vs volumes --")
    for _, aidx in ipairs({ 0, 14, 66, 176, 246 }) do
        local c; pcall(function() c = arr[aidx + 1] end)
        local ic = "?"; if c and c:IsValid() then pcall(function() ic = tostring(c:GetInstanceCount()) end) end
        P(("   aidx=%3d volumes=%s -> HISMArray[%d].instances=%s"):format(
            aidx, tostring(a2v[aidx]), aidx + 1, ic))
    end
    P("=== [F8] done -- NO mutation. Signatures above decide manager-route vs component-route + transform build. ===")
end

-- ---- F9: teleport one book's pile instance to deep Z (the real mutation test) --------------
-- Confirms (1) UpdateInstanceTransform is crash-safe on the book HISMs, (2) instance index ==
-- chapter (the nearest book should vanish), (3) UE4SS marshals a Lua-table FTransform. Toggle:
-- first press hides the nearest book's instance; press again to restore. Transform built from the
-- actor's world location (K2_GetActorLocation works; K2_GetActorTransform throws in this build) with
-- bWorldSpace=true. Restore uses identity rotation/scale -- the real feature would capture the
-- original transform if GetInstanceTransform can fill a table.
local _tp = nil   -- { comp, idx, restoreT }

local function nearest_book()
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not (player and player:IsValid()) then return nil end
    local px, py, pz = actor_loc(player)
    if not px then return nil end
    local books = FindAllOf("BP_GrabbingBook_C")
    local n = safe_len(books)
    local best, bestd = nil, math.huge
    for i = 1, n do
        local b = books[i]
        if b and b:IsValid() then
            local info = book_info(b)
            if info then
                local aidx; pcall(function() aidx = tonumber(info.AssetIdx) end)
                if aidx ~= nil then
                    local bx, by, bz = actor_loc(b)
                    if bx then
                        local dx, dy, dz = bx - px, by - py, bz - pz
                        local d = dx * dx + dy * dy + dz * dz
                        if d < bestd then best, bestd = b, d end
                    end
                end
            end
        end
    end
    return best, (best and math.sqrt(bestd) or nil)
end

local function probe_teleport_one()
    local mgr = FindFirstOf("BP_HISM_Manager_C")
    local arr; if mgr and mgr:IsValid() then pcall(function() arr = mgr.HISMArray end) end
    if not arr then P("[F9] no HISM manager -- enter gameplay first"); return end

    if _tp then
        local ok = pcall(function() _tp.comp:UpdateInstanceTransform(_tp.idx, _tp.restoreT, true, true, true) end)
        P(("[F9] RESTORE idx=%d ok=%s"):format(_tp.idx, tostring(ok)))
        _tp = nil
        return
    end

    local b, dist = nearest_book()
    if not b then P("[F9] no nearest book"); return end
    local info = book_info(b)
    local aidx, chap
    pcall(function() aidx = tonumber(info.AssetIdx) end)
    pcall(function() chap = tonumber(info.Chapter) end)
    local ia = IA(); local series = ia and ia._asset_to_series and ia._asset_to_series[aidx]
    local lx, ly, lz = actor_loc(b)
    P(("[F9] nearest book: aidx=%s chap=%s series=%s dist=%s loc=(%s,%s,%s)"):format(
        tostring(aidx), tostring(chap), tostring(series):sub(1, 28),
        dist and ("%.0f"):format(dist) or "?", tostring(lx), tostring(ly), tostring(lz)))
    if aidx == nil or chap == nil or lx == nil then P("[F9] book missing aidx/chap/loc"); return end

    local comp; pcall(function() comp = arr[aidx + 1] end)
    if not (comp and comp:IsValid()) then P("[F9] no HISM component for aidx"); return end

    -- Probe whether GetInstanceTransform fills a passed table (for the future clean-capture restore).
    local cap = {}
    pcall(function()
        local r = comp:GetInstanceTransform(chap, cap, true)
        P(("[F9] GetInstanceTransform(%d) ret=%s cap.Translation=%s cap keys: T=%s R=%s S=%s"):format(
            chap, tostring(r), tostring(cap.Translation),
            tostring(cap.Translation), tostring(cap.Rotation), tostring(cap.Scale3D)))
    end)

    -- Build hide (deep Z) + restore transforms from the actor's world location.
    local restoreT = { Translation = { X = lx, Y = ly, Z = lz },
                       Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                       Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local hideT    = { Translation = { X = lx, Y = ly, Z = lz - 1000000.0 },
                       Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                       Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local ok = pcall(function() comp:UpdateInstanceTransform(chap, hideT, true, true, true) end)
    P(("[F9] TELEPORT aidx=%d chap=%d ok=%s"):format(aidx, chap, tostring(ok)))
    P("     WATCH: did the book right in front of you vanish (correct index), a DIFFERENT book vanish")
    P("     (index != chapter), or nothing/crash? Press F9 again to restore it.")
    _tp = { comp = comp, idx = chap, restoreT = restoreT }
end

-- ---- helpers for the item/trap probes -----------------------------------------------------
local function dump_num_array(obj, field, cap)
    local arr; pcall(function() arr = obj[field] end)
    local n = safe_len(arr)
    local vals = {}
    for k = 1, math.min(n, cap or 12) do local v; pcall(function() v = arr[k] end); vals[#vals + 1] = tostring(v) end
    return n, table.concat(vals, ", ")
end

-- ---- F4: skill timers (useful items: cooldown / active-time / assemble reach) ---------------
-- Read-only structure discovery + one careful write. If the skill objects' CoolDownTimePreLevel[] /
-- ActiveTimePreLevel[] arrays are writable and read live, a "Progressive Attunement" item can cut
-- cooldown / extend active-time per copy.
local function probe_skill_timers()
    P("=== [F4] skill timers (cooldown / active-time / assemble reach) ===")
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not (player and player:IsValid()) then P("no player pawn -- enter gameplay first"); return end

    -- 1. Find skill-related properties on the pawn (discover the container name).
    P("-- pawn skill-ish properties --")
    local cls; pcall(function() cls = player:GetClass() end)
    if cls then
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pn, pt = "?", "?"
                pcall(function() pn = prop:GetFName():ToString() end)
                pcall(function() pt = prop:GetClass():GetFName():ToString() end)
                local low = pn:lower()
                if low:find("skill") or low:find("ability") or low:find("upgrade") then
                    P(("   %-28s %s"):format(pn, pt))
                end
                return 0
            end)
        end)
    end

    -- 2. player.SkillInfo is a TMap<enum, value> -- iterate it (integer indexing gives the map
    -- itself, not an entry). Dump each value's type + its CoolDown/ActiveTime arrays.
    local si; pcall(function() si = player.SkillInfo end)
    P(("player.SkillInfo = %s  len=%d (TMap)"):format(tostring(si), safe_len(si)))
    local first_val, first_key = nil, nil
    local first_so = nil
    if si then
        local shown = 0
        pcall(function()
            si:ForEach(function(k, v)
                if shown >= 12 then return end
                shown = shown + 1
                local key = "?"; pcall(function() key = tostring(k:get()) end)
                local val = v; pcall(function() val = v:get() end)
                if not first_val then first_val = val; first_key = key end
                -- The timer arrays live one level deeper: value.SkillObject.<array>.
                local so; pcall(function() so = val.SkillObject end)
                if so and so:IsValid() and not first_so then first_so = so end
                local cd_n, cd = dump_num_array(so or val, "CoolDownTimePreLevel")
                local at_n, at = dump_num_array(so or val, "ActiveTimePreLevel")
                P(("  key=%-6s SkillObject=%s  CoolDown(n=%d)=[%s]  Active(n=%d)=[%s]"):format(
                    key, (so and so:IsValid()) and class_name(so) or "nil", cd_n, cd, at_n, at))
            end)
        end)
    end
    -- Dump the SkillObject's property names (a UObject -> GetClass works) to find the real
    -- timer-array field names, then dump every float-array field we find.
    if first_so and first_so:IsValid() then
        P(("  -- SkillObject (%s) fields --"):format(class_name(first_so)))
        pcall(function()
            local vc = first_so:GetClass()
            vc:ForEachProperty(function(prop)
                local pn, pt = "?", "?"
                pcall(function() pn = prop:GetFName():ToString() end)
                pcall(function() pt = prop:GetClass():GetFName():ToString() end)
                local extra = ""
                if pt == "ArrayProperty" or pt == "FloatProperty" or pt == "IntProperty" then
                    local n, vals = dump_num_array(first_so, pn, 12)
                    if n > 0 then extra = ("  = [%s]"):format(vals)
                    else local sv; pcall(function() sv = first_so[pn] end); extra = "  = " .. tostring(sv) end
                end
                P(("      %-26s %-14s%s"):format(pn, pt, extra))
                return 0
            end)
        end)
    end

    -- 3. Read-only attunement/fatigue diagnostic. Dumps the live tuning state and each skill's
    --    current cooldown/active arrays -- no faking, so it's safe to press on a real connection.
    --    Load a seed with Attunement/Fatigue items (or start_inventory) to exercise the real path.
    local ia = IA()
    if ia then
        P(("[F12] gate: gameplay=%s apply_safe=%s attune=%s"):format(
            tostring(ia._gameplay_active), tostring(ia._apply_safe),
            tostring(ia._slot_data and ia._slot_data.attunement)))
        local rc = ia._received_counts or {}
        local ac = ia._applied_skill_counts or {}
        local fa = ia._fatigue_active or {}
        for _, cls in ipairs({
            { "Sort",          "Skill_SortBook_C",            "Progressive Sort" },
            { "Shelf Guide",   "Skill_ShowCorrentBookCase_C", "Progressive Shelf Guide" },
            { "Insight",       "Skill_ShowSameTypeBook_C",    "Progressive Insight" },
            { "Auto-Shelving", "Skill_AutoShelve_C",          "Progressive Auto-Shelving" },
            { "Assemble",      "Skill_GrabSameTypeBook_C",    "Progressive Assemble" },
        }) do
            local name, klass, prog = cls[1], cls[2], cls[3]
            P(("[F12] %s: level=%s mastery=%s fatigue=%s left=%ss"):format(
                name, tostring(ac[prog] or 0), tostring(rc[name .. " Mastery"] or 0),
                tostring(rc["Fatigue: " .. name] or 0), tostring(math.floor(fa[name] or 0))))
            local sk = FindFirstOf(klass)
            if sk and sk:IsValid() then
                local _, cd = dump_num_array(sk, "CoolDownTimePreLevel")
                local _, at = dump_num_array(sk, "ActiveTimePreLevel")
                P(("       CoolDown=[%s]"):format(cd))
                P(("       Active  =[%s]"):format(at))
            end
        end
    else
        P("[F12] ItemApply not available")
    end
    P("=== [F12] done ===")
end

-- ---- F10: move speed (useful item: Fleet Foot) ---------------------------------------------
local _spd_orig = nil
local function probe_move_speed()
    P("=== [F10] move speed ===")
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not (player and player:IsValid()) then P("no player pawn"); return end
    local cm; pcall(function() cm = player.CharacterMovement end)
    if not (cm and cm:IsValid()) then pcall(function() cm = player:GetComponentByClass() end) end
    if not (cm and cm:IsValid()) then P("no CharacterMovement component"); return end
    local mws; pcall(function() mws = cm.MaxWalkSpeed end)
    P(("MaxWalkSpeed = %s"):format(tostring(mws)))
    -- A direct MaxWalkSpeed write may not stick -- the game re-derives speed from MoveInfos. Dump the
    -- first MoveInfo struct's fields to find the Speed field a real Fleet Foot item would write.
    local mi; pcall(function() mi = player.MoveInfos end)
    P(("player.MoveInfos count = %d"):format(safe_len(mi)))
    if mi and safe_len(mi) >= 1 then
        pcall(function()
            local m0 = mi[1]
            local mc = m0.GetClass and m0:GetClass() or nil
            if mc then
                P("   MoveInfos[1] fields:")
                mc:ForEachProperty(function(prop)
                    local pn, pt, val = "?", "?", "?"
                    pcall(function() pn = prop:GetFName():ToString() end)
                    pcall(function() pt = prop:GetClass():GetFName():ToString() end)
                    pcall(function() val = tostring(m0[pn]) end)
                    P(("      %-24s %-14s = %s"):format(pn, pt, val))
                    return 0
                end)
            else
                P("   (MoveInfos[1] has no readable class -- struct-by-value)")
            end
        end)
    end
    if _spd_orig then
        pcall(function() cm.MaxWalkSpeed = _spd_orig end)
        P(("[F10] RESTORED MaxWalkSpeed = %s"):format(tostring(_spd_orig)))
        _spd_orig = nil
    else
        _spd_orig = mws
        pcall(function() cm.MaxWalkSpeed = (tonumber(mws) or 600) * 1.6 end)
        P("[F10] boosted MaxWalkSpeed x1.6. WALK around, then toggle Run/Walk -- if it snaps back, the")
        P("     game re-derives speed from MoveInfos (Fleet Foot must write those or re-assert per tick).")
        P("     Press F10 again to restore.")
    end
    P("=== [F10] done ===")
end

-- ---- F6: lighting (trap C: color / off) ----------------------------------------------------
local _lights_saved = nil   -- { {comp=, intensity=, }, ... }
local function probe_lights()
    P("=== [F6] lighting (trap: dim / off / color) ===")
    if _lights_saved then
        local restored = 0
        for _, e in ipairs(_lights_saved) do
            if e.comp and e.comp:IsValid() then
                pcall(function() e.comp:SetIntensity(e.intensity) end)
                restored = restored + 1
            end
        end
        P(("[F6] RESTORED intensity on %d light(s)"):format(restored))
        _lights_saved = nil
        return
    end
    _lights_saved = {}
    -- Count both component and actor light classes (the game may use light actors, or bake them).
    -- Mutate every light component we can reach -- via a component class directly, or via a light
    -- actor's LightComponent.
    local function try_dim(c)
        if not (c and c:IsValid()) then return false end
        local inten; pcall(function() inten = c.Intensity end)
        if inten == nil then return false end
        _lights_saved[#_lights_saved + 1] = { comp = c, intensity = inten }
        pcall(function() c:SetIntensity((tonumber(inten) or 0) * 0.15) end)
        return true
    end
    local n_hit = 0
    for _, cls in ipairs({ "PointLightComponent", "SpotLightComponent", "RectLightComponent",
                           "SkyLightComponent", "DirectionalLightComponent" }) do
        local arr = FindAllOf(cls); local n = safe_len(arr)
        for i = 1, math.min(n, 80) do if try_dim(arr[i]) then n_hit = n_hit + 1 end end
        P(("   component %s: %d found"):format(cls, n))
    end
    for _, cls in ipairs({ "PointLight", "SpotLight", "RectLight", "SkyLight",
                           "DirectionalLight", "BP_Light_C", "BP_RoomLight_C" }) do
        local arr = FindAllOf(cls); local n = safe_len(arr)
        for i = 1, math.min(n, 80) do
            local a = arr[i]
            if a and a:IsValid() then
                for _, prop in ipairs({ "LightComponent", "PointLightComponent", "SpotLightComponent" }) do
                    local c; pcall(function() c = a[prop] end)
                    if c and c:IsValid() and try_dim(c) then n_hit = n_hit + 1; break end
                end
            end
        end
        if n > 0 then P(("   actor %s: %d found"):format(cls, n)) end
    end
    P(("[F6] dimmed %d light(s) to 15%%. Look around -- darker? flicker/revert? Press F6 again to restore."):format(n_hit))
    P("=== [F6] done ===")
end

-- ---- F11: book scatter / un-shelve / swap (traps A + B) ------------------------------------
-- Dump the game's own book-return functions (BackToCorrectPlace, ReturnBookToCase, ScatterBooks)
-- + test un-placing a correct book (makes it incorrect, so the player must re-fix it before goal).
-- Non-destructive intent: the book stays a valid game actor.
local function probe_scatter()
    P("=== [F8] book swap / un-shelve (trap A/B) ===")
    -- Operate on the case nearest the player. Correctness lives on the case (PlacingBookInfo +
    -- RowStatus), not the book actor.
    local case, dist = nearest_case()
    if not (case and case:IsValid()) then P("no nearest case -- stand facing a shelf in gameplay"); return end
    P(("nearest case: %s dist=%s"):format(class_name(case), dist and ("%.0f"):format(dist) or "?"))

    -- occupancy: how many slots are filled + how many rows correct (so we test on a shelf that has books)
    local pbi; pcall(function() pbi = case.PlacingBookInfo end)
    local occ = 0
    for slot = 1, math.min(safe_len(pbi), 256) do
        if slot_book(pbi, slot) then occ = occ + 1 end
    end
    local rs; pcall(function() rs = case.RowStatus end)
    local done = 0
    for s = 1, safe_len(rs) do local d; pcall(function() local v = rs[s]; d = (v == true or v == 1) end); if d then done = done + 1 end end
    P(("   occupancy=%d slots filled | %d shelf/row(s) complete"):format(occ, done))

    -- The real (reliable) functions -- dump signatures.
    for _, fn in ipairs({ "BackToCorrectPlace", "ReturnBookToCase", "SetPlacingBookInfo" }) do
        dump_fn_sig(case, fn)
    end

    -- Dump the occupied slots (idx -> aidx:chap) so we know what to swap/move for traps A/B.
    P("   occupied slots (idx -> aidx:chap):")
    local slots = {}
    for slot = 1, math.min(safe_len(pbi), 256) do
        local b = slot_book(pbi, slot)
        if b then slots[#slots + 1] = slot; if #slots <= 12 then P(("      [%d] %d:%s"):format(slot, b.aidx, tostring(b.chap))) end end
    end

    -- Read-only. SetPlacingBookInfo swaps corrupt shelf state (one-way move, blocked re-placement),
    -- so state-changing traps via these functions are unsafe. Kept as a slot/function dump only.
    P("   (read-only: state-changing swap abandoned -- SetPlacingBookInfo corrupts placement)")
    P("=== [F8] done ===")
end

-- ---- F7: book/bag capacity — hook SetHandingMaxNum to read the live carry max ---------------
-- The grant (+2/+3) works but touches neither GetBagLevel nor MaxBagItemLevel; the capacity is a
-- separate value the game pushes to the HUD via LibrarianPlayerInfo:SetHandingMaxNum(newMax) on
-- every change. Hooking that captures the live max with no field-hunting. If this reads your real
-- carry number and rises ~+2 on a grant, the client fix = apply grants until the captured max
-- hits the target, reading it back each grant (idempotent, can't climb past target on reload).
local _bag_hud_max = nil
local _bag_hook_ok = nil
local function _bag_register_hook()
    if _bag_hook_ok ~= nil then return end
    _bag_hook_ok = pcall(function()
        RegisterHook("/Script/Librarian.LibrarianPlayerInfo:SetHandingMaxNum", function(_, maxBookNum)
            pcall(function() _bag_hud_max = maxBookNum:get() end)
        end)
    end)
    P(("[bag] SetHandingMaxNum hook registered (ok=%s)"):format(tostring(_bag_hook_ok)))
end
local function probe_bag_capacity()
    P("=== [F7] bag capacity (SetHandingMaxNum hook) ===")
    _bag_register_hook()
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not player or not player:IsValid() then P("[bag] no player"); return end
    P(("[bag] BEFORE grant: captured max = %s"):format(tostring(_bag_hud_max)))
    local ia = IA(); if ia then ia._ap_grant = true end
    pcall(function() player:UpgradePlayer(1) end)
    if ia then ia._ap_grant = false end
    P(("[bag] AFTER grant [+2]: captured max = %s"):format(tostring(_bag_hud_max)))
    P("      Press F7 a second time -- BEFORE should now equal your real carry max. Report both lines.")
    P("=== [bag] done ===")
end

-- ---- F11: save-system schema -----------------------------------------------------------------
-- The game's manual save/load system numbers its slots and renamed the save file Sav -> GameData.
-- Our per-seed isolation rewrites GameInstance.SaveGameName, so the redirect only holds if that
-- property still names the file. This dumps what the redirect now lands in: whether SaveGameName
-- still exists and takes a write, the live save object's schema (which PlayerExtraData carries
-- SkillData), the SaveSubsystem surface, and every Save-named class the build exposes.
-- The live slot names come from the [AP][save-probe] hooks in main.lua (UE4SS.log), plus the
-- async hook below -- an async save path would leave those existing hooks silent.

-- Walk a UStruct's properties, then its supers. depth bounds the super walk (UObject has a lot);
-- filter is a lowercase substring, nil = every property.
local function dump_props(strct, label, depth, filter)
    P(("--- %s ---"):format(label))
    if not (strct and strct:IsValid()) then P("  (not found)"); return end
    local ok = pcall(function()
        local cls, guard = strct, 0
        while cls and cls:IsValid() and guard < (depth or 12) do
            guard = guard + 1
            local cn = "?"; pcall(function() cn = cls:GetFName():ToString() end)
            P(("  [%s]"):format(cn))
            cls:ForEachProperty(function(Prop)
                local pn, pt = "?", "?"
                pcall(function() pn = Prop:GetFName():ToString() end)
                pcall(function() pt = Prop:GetClass():GetFName():ToString() end)
                if (not filter) or pn:lower():find(filter, 1, true) then
                    P(("    %-34s %s"):format(pn, pt))
                end
            end)
            local super; pcall(function() super = cls:GetSuperStruct() end)
            cls = super
        end
    end)
    if not ok then P("  (property dump failed)") end
end

-- UFunctions on a class. Not every UE4SS build exposes ForEachFunction; absence is not a finding.
local function dump_funcs(cls, label, filter)
    P(("--- %s ---"):format(label))
    if not (cls and cls:IsValid()) then P("  (not found)"); return end
    local n = 0
    local ok = pcall(function()
        cls:ForEachFunction(function(Fn)
            local fn = "?"; pcall(function() fn = Fn:GetFName():ToString() end)
            if (not filter) or fn:lower():find(filter, 1, true) then P("    " .. fn); n = n + 1 end
        end)
    end)
    if not ok then P("  (ForEachFunction unavailable in this UE4SS build)")
    else P(("  (%d function(s))"):format(n)) end
end

local function find_class(path)
    local c; pcall(function() c = StaticFindObject(path) end)
    if c and c:IsValid() then return c end
    return nil
end

-- A UFunction's own properties ARE its parameters (ReturnParm flagged among them). GetSaveDataPath
-- is the candidate redirect point, so its exact signature decides whether we can rewrite the path.
local function dump_signature(fnpath, label)
    P(("--- signature: %s ---"):format(label))
    local fn = find_class(fnpath)
    if not fn then P("  (function object not found)"); return end
    local ok = pcall(function()
        fn:ForEachProperty(function(Prop)
            local pn, pt = "?", "?"
            pcall(function() pn = Prop:GetFName():ToString() end)
            pcall(function() pt = Prop:GetClass():GetFName():ToString() end)
            local ret = ""
            pcall(function() if Prop:IsA(0) then ret = "" end end)
            P(("    %-26s %s%s"):format(pn, pt, ret))
        end)
    end)
    if not ok then P("  (signature dump failed)") end
end

-- SLOT TRACKER.
-- The native save/load path is unreachable (it calls GetSaveDataPath directly in C++), so the mod
-- cannot force which slot loads. But the BP menu DOES dispatch GetSaveDataPath for the slot the
-- player is acting on, so we can OBSERVE it -- enough to bind seed<->slot and refuse checks when a
-- foreign save is loaded. This proves the observation is reliable: every slot-bearing call, tagged.
-- Post-hook arg order is empirical, NOT declaration order: arg1=ReturnValue(path), then
-- mapIdx, slotIdx, pathType, AutoSave.
local function argval(a)
    local v = "?"
    pcall(function()
        local g = a:get()
        v = (type(g) == "userdata") and tostring(g:ToString()) or tostring(g)
    end)
    return v
end

M_last_slot = nil   -- global on purpose: readable from the UE4SS console for spot checks

local _path_hook_ok = nil
local function register_path_hook()
    if _path_hook_ok ~= nil then return end
    _path_hook_ok = pcall(function()
        RegisterHook("/Script/Librarian.LibrarianGameInstanceBase:GetSaveDataPath",
            function() end,
            function(self, ...)
                local a = { ... }
                local path, mapIdx, slotIdx, pathType, auto =
                    argval(a[1]), argval(a[2]), argval(a[3]), argval(a[4]), argval(a[5])
                M_last_slot = slotIdx
                P(("[slot] GetSaveDataPath -> '%s'  mapIdx=%s slotIdx=%s pathType=%s autoSave=%s")
                    :format(path, mapIdx, slotIdx, pathType, auto))
            end)
    end)
    P(("[slot] GetSaveDataPath hook registered=%s"):format(tostring(_path_hook_ok)))

    -- SaveGameData(saveSlotNum, isAutoSave) -- 2 params on this build (was 1). This is the one
    -- write-side call we can still see, and the only candidate for forcing a slot.
    local ok2 = pcall(function()
        RegisterHook("/Script/Librarian.LibrarianGameInstanceBase:SaveGameData", function(self, slot, auto)
            P(("[slot] SaveGameData(saveSlotNum=%s, isAutoSave=%s)"):format(argval(slot), argval(auto)))
        end)
    end)
    P(("[slot] SaveGameData hook registered=%s"):format(tostring(ok2)))

    -- LoadGameData(levelIdx, loadSlotNum, isAutoSave) -- 3 params now (was 1). Has never fired;
    -- logging all three confirms whether that stays true rather than assuming it.
    local ok3 = pcall(function()
        RegisterHook("/Script/Librarian.LibrarianGameInstanceBase:LoadGameData", function(self, lvl, slot, auto)
            P(("[slot] LoadGameData(levelIdx=%s, loadSlotNum=%s, isAutoSave=%s)  <-- FIRED")
                :format(argval(lvl), argval(slot), argval(auto)))
        end)
    end)
    P(("[slot] LoadGameData hook registered=%s"):format(tostring(ok3)))
end

-- The slot path is built from the map + slot number (Map01/Save01/GameData.sav), and the write
-- never reaches GameplayStatics:SaveGameToSlot -- so the remaining candidates are the async
-- variant or a memory//custom serializer. Hook them at LOAD, not from the keybind: a hook
-- registered only when the probe runs can't observe the save that already happened.
local _save_hooks_ok = nil
local function register_save_write_hooks()
    if _save_hooks_ok ~= nil then return end
    local function slot_of(p)
        local v = "?"
        pcall(function() v = p:get():ToString() end)
        return tostring(v)
    end
    _save_hooks_ok = true
    for _, sig in ipairs({
        { "/Script/Engine.GameplayStatics:AsyncSaveGameToSlot", "AsyncSaveGameToSlot" },
        { "/Script/Engine.GameplayStatics:SaveGameToMemory",    "SaveGameToMemory" },
        { "/Script/Engine.GameplayStatics:LoadGameFromMemory",  "LoadGameFromMemory" },
        { "/Script/Engine.GameplayStatics:DeleteGameInSlot",    "DeleteGameInSlot" },
    }) do
        local ok = pcall(function()
            RegisterHook(sig[1], function(_, a, b)
                -- AsyncSaveGameToSlot(SaveGameObject, SlotName, UserIndex): slot is the 2nd param.
                -- The memory variants take no slot; log the call itself, which is the finding.
                P(("[save] %s slot='%s'"):format(sig[2], slot_of(b) ~= "?" and slot_of(b) or slot_of(a)))
            end)
        end)
        P(("[save] hook %-22s registered=%s"):format(sig[2], tostring(ok)))
    end
    -- AUTOSAVE ATTRIBUTION. Manual saves fire SaveGameData(slot, isAutoSave) and give us the slot
    -- outright; autosaves fire only StartSaveProgress, which carries no parameters. The two are
    -- disjoint -- verified across a full session, every autosave write had StartSaveProgress ~1s
    -- before it and no SaveGameData, and vice versa -- so together they cover every save.
    -- The slot comes from ScanAutoSaveSlots(): sample it at the hook (still the PREVIOUS newest)
    -- and again after the write lands, and the value that changed names the slot just written.
    -- State is captured at the hook, since that is what gets serialized a moment later.
    local ok = pcall(function()
        RegisterHook("/Script/Librarian.SaveSubsystem:StartSaveProgress", function()
            local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
            local before, rows, books = "?", "?", "?"
            if gi and gi:IsValid() then
                pcall(function()
                    local a = gi:ScanAutoSaveSlots()
                    if type(a) == "table" then before = tostring(a.NewestSlot) end
                end)
                pcall(function()
                    local sg = gi.GameSaveData
                    if sg and sg:IsValid() then
                        rows = tostring(sg.GameProgressData.CurrentFinishedRowNum)
                        books = tostring(sg.GameProgressData.InsertedBookNum)
                    end
                end)
            end
            P(("[autosave] StartSaveProgress -- newestAuto BEFORE=%s | state rows=%s books=%s")
                :format(before, rows, books))
            -- Re-sample once the write has landed; marshal back to the game thread to read UObjects.
            LoopAsync(2500, function()
                on_gt(function()
                    local gi2 = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
                    if not (gi2 and gi2:IsValid()) then return end
                    local after = "?"
                    pcall(function()
                        local a = gi2:ScanAutoSaveSlots()
                        if type(a) == "table" then after = tostring(a.NewestSlot) end
                    end)
                    P(("[autosave] ...after write: newestAuto=%s  (%s)"):format(
                        after, (after ~= before) and ("wrote AutoSave" .. after) or "UNCHANGED -- attribution failed"))
                end)
                return true
            end)
        end)
    end)
    P(("[save] hook %-22s registered=%s"):format("StartSaveProgress+attrib", tostring(ok)))
    local ok2 = pcall(function()
        RegisterHook("/Script/Librarian.SaveSubsystem:CheckAbleSave", function()
            P("[save] SaveSubsystem.CheckAbleSave")
        end)
    end)
    P(("[save] hook %-22s registered=%s"):format("CheckAbleSave", tostring(ok2)))
end

-- WHAT IS LOADED RIGHT NOW. The single line that answers "did the load land on the slot we asked
-- for" -- the schema dump lists property NAMES, which is useless for telling two saves apart.
-- Also reports the game's own idea of the newest slot, since that is what Continue resolves to.
local function report_live_state(tag)
    local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
    if not (gi and gi:IsValid()) then P(("[live] %s: no GameInstance"):format(tag)); return end
    local rows, books = "?", "?"
    pcall(function()
        local sg = gi.GameSaveData
        if sg and sg:IsValid() then
            rows  = tostring(sg.GameProgressData.CurrentFinishedRowNum)
            books = tostring(sg.GameProgressData.InsertedBookNum)
        end
    end)
    local newest, autonewest = "?", "?"
    pcall(function()
        local n = gi:GetNewestSaveSlot()
        if type(n) == "table" then
            newest = ("slot=%s auto=%s"):format(tostring(n.SlotNum), tostring(n.AutoSave))
        end
    end)
    pcall(function()
        local a = gi:ScanAutoSaveSlots()
        if type(a) == "table" then autonewest = tostring(a.NewestSlot) end
    end)
    P(("[live] %s: rows=%s books=%s | newest=%s | newestAuto=%s")
        :format(tag, rows, books, newest, autonewest))
end

local function probe_save_system()
    P("=== save-system schema ===")
    report_live_state("on Ctrl+F9")
    register_save_write_hooks()

    local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
    if not (gi and gi:IsValid()) then P("[save] no GameInstance -- load a save, or press Ctrl+F9 in-game"); return end
    P(("[save] GameInstance class = %s"):format(class_name(gi)))

    local ver = "<none>"
    pcall(function() ver = gi:GetProjectVersion():ToString() end)
    P(("[save] GetProjectVersion = %s"):format(tostring(ver)))

    -- Does the redirect target still exist, and does a write take? The write is restored
    -- immediately: a stray SaveGameName would point the next real save at a file of our invention.
    -- Only run it once the CURRENT name is known to be a string -- restoring a nil would strand the
    -- probe value. Whole probe is on the game thread, so no save can land inside the window.
    local slot_now
    pcall(function() slot_now = gi.SaveGameName:ToString() end)
    local have_slot = (type(slot_now) == "string")
    P(("[save] SaveGameName readable=%s value='%s'"):format(tostring(have_slot), tostring(slot_now)))
    if not have_slot then
        P("[save] !! SaveGameName is gone or unreadable -- the per-seed redirect cannot work as built")
    else
        local probe_val, readback = "Sav_AP_probe_readback", nil
        local wrote = pcall(function() gi.SaveGameName = probe_val end)
        pcall(function() readback = gi.SaveGameName:ToString() end)
        local restored
        pcall(function() gi.SaveGameName = slot_now end)
        pcall(function() restored = gi.SaveGameName:ToString() end)
        P(("[save] write test: wrote=%s readback='%s' sticks=%s"):format(
            tostring(wrote), tostring(readback), tostring(readback == probe_val)))
        if restored == slot_now then
            P(("[save] restored to '%s'"):format(tostring(restored)))
        else
            P(("[save] !! RESTORE FAILED: SaveGameName is now '%s', expected '%s' -- do NOT save; "
               .. "restart the game before playing"):format(tostring(restored), tostring(slot_now)))
        end
    end

    local sg
    pcall(function() sg = gi.GameSaveData end)
    local got_schema = false
    if sg and sg:IsValid() then
        P(("[save] GameSaveData class = %s"):format(class_name(sg)))
        local scls; pcall(function() scls = sg:GetClass() end)
        dump_props(scls, "GameSaveData schema (which PlayerExtraData holds SkillData?)", 3, nil)
        got_schema = true
    else
        P("[save] GameSaveData is nil/invalid -- schema pending; retrying on later triggers")
    end

    -- Every property on the LIVE GameInstance class, unfiltered, including the Blueprint subclass.
    -- The native loader takes its slot from somewhere; a name filter, or dumping only the C++ base,
    -- would hide it. Values too -- the name alone cannot say which slot is currently selected.
    local live_cls; pcall(function() live_cls = gi:GetClass() end)
    P("--- LIVE GameInstance: all properties + values (hunting the slot the loader reads) ---")
    local shown_any = false
    pcall(function()
        local cls, guard = live_cls, 0
        while cls and cls:IsValid() and guard < 4 do
            guard = guard + 1
            local cn = "?"; pcall(function() cn = cls:GetFName():ToString() end)
            P(("  [%s]"):format(cn))
            cls:ForEachProperty(function(Prop)
                local pn, pt = "?", "?"
                pcall(function() pn = Prop:GetFName():ToString() end)
                pcall(function() pt = Prop:GetClass():GetFName():ToString() end)
                -- Only scalars carry a readable slot; skip arrays/maps/objects to keep this short.
                if pt == "IntProperty" or pt == "BoolProperty" or pt == "StrProperty"
                        or pt == "NameProperty" or pt == "ByteProperty" or pt == "EnumProperty" then
                    local v = "?"
                    pcall(function()
                        local raw = gi[pn]
                        v = (type(raw) == "userdata") and tostring(raw:ToString()) or tostring(raw)
                    end)
                    P(("    %-32s %-14s = %s"):format(pn, pt, v))
                    shown_any = true
                end
            end)
            local super; pcall(function() super = cls:GetSuperStruct() end)
            cls = super
        end
    end)
    if not shown_any then P("  (no scalar properties readable)") end

    -- Same for the subsystem that drives saving.
    local ss = FindFirstOf("SaveSubsystem")
    if ss and ss:IsValid() then
        P("--- LIVE SaveSubsystem: scalar properties ---")
        pcall(function()
            local c; pcall(function() c = ss:GetClass() end)
            if c and c:IsValid() then
                c:ForEachProperty(function(Prop)
                    local pn, pt = "?", "?"
                    pcall(function() pn = Prop:GetFName():ToString() end)
                    pcall(function() pt = Prop:GetClass():GetFName():ToString() end)
                    local v = "?"
                    pcall(function() v = tostring(ss[pn]) end)
                    P(("    %-32s %-14s = %s"):format(pn, pt, v))
                end)
            end
        end)
    end
    dump_funcs(find_class("/Script/Librarian.LibrarianGameInstanceBase"),
        "GameInstance save/load functions", "ave")
    dump_funcs(find_class("/Script/Librarian.LibrarianGameInstanceBase"),
        "GameInstance load functions", "oad")

    -- Slot budget: a per-seed slot scheme has to fit inside these.
    local mx, mxa = "?", "?"
    pcall(function() mx = tostring(gi.MaxSaveSlots) end)
    pcall(function() mxa = tostring(gi.MaxAutoSaveSlots) end)
    P(("[save] MaxSaveSlots=%s MaxAutoSaveSlots=%s"):format(mx, mxa))

    -- The path builder and the slot helpers -- the redirect surface.
    local GIB = "/Script/Librarian.LibrarianGameInstanceBase:"
    dump_signature(GIB .. "GetSaveDataPath", "GetSaveDataPath")
    dump_signature(GIB .. "SaveGameData", "SaveGameData")
    dump_signature(GIB .. "LoadGameData", "LoadGameData")
    dump_signature(GIB .. "GetNewestSaveSlot", "GetNewestSaveSlot")
    dump_signature(GIB .. "ScanAutoSaveSlots", "ScanAutoSaveSlots")


    local subsys = FindFirstOf("SaveSubsystem")
    P(("[save] SaveSubsystem instance = %s"):format(subsys and class_name(subsys) or "<not found>"))
    dump_props(find_class("/Script/Librarian.SaveSubsystem"), "SaveSubsystem properties", 1, nil)
    dump_funcs(find_class("/Script/Librarian.SaveSubsystem"), "SaveSubsystem functions", nil)

    -- LibrarianSlotSaveGame is the slot metadata the load menu lists (MetaData: RowMaxNum,
    -- BookMaxNum, SaveTime, PlayTime) -- a per-seed slot has to carry one or it stays invisible.
    dump_props(find_class("/Script/Librarian.LibrarianSlotSaveGame"), "LibrarianSlotSaveGame", 2, nil)
    dump_props(find_class("/Script/Librarian.LibrarianSaveMetadata"), "LibrarianSaveMetadata", 2, nil)

    -- Live USaveGame objects: names the classes actually in use, including any the manual save
    -- system added that we have no path for.
    P("--- live USaveGame instances ---")
    local found = 0
    for _, short in ipairs({ "LibrarianSaveGame", "LibrarianSlotSaveGame", "SystemSaveGame", "SaveGame" }) do
        local objs; pcall(function() objs = FindAllOf(short) end)
        local n = safe_len(objs)
        if n > 0 then
            found = found + n
            P(("  FindAllOf(%q): %d"):format(short, n))
            for i = 1, math.min(n, 8) do
                local o = objs[i]
                if o and o:IsValid() then P(("    %s  =  %s"):format(class_name(o), full_name(o))) end
            end
        end
    end
    if found == 0 then P("  (none live)") end

    P(("=== save-system schema done (schema captured=%s) -- send probe.log ==="):format(tostring(got_schema)))
    return got_schema
end

-- Auto-dump: the schema read needs a loaded GameSaveData, which only exists once a save is in.
-- Firing off the game's own save/load means the dump lands at exactly the right moment and needs
-- no keypress -- F11 never reached UE4SS, so a keybind alone is not a reliable trigger. Once per
-- session; these hooks are on the game thread already, so the body runs inline.
-- Latch only once the schema is actually captured: DoesSaveGameExist also fires at the title,
-- where GameSaveData is nil, and latching there would spend the one-shot before a save is in.
-- ATTEMPT_CAP keeps a title-screen menu (which probes every slot) from dumping on a loop.
local _auto_dumped, _auto_attempts = false, 0
local ATTEMPT_CAP = 8
local function auto_dump_on(sig, label)
    local ok = pcall(function()
        RegisterHook(sig, function()
            if _auto_dumped or _auto_attempts >= ATTEMPT_CAP then return end
            _auto_attempts = _auto_attempts + 1
            P(("[save] auto-dump triggered by %s (attempt %d/%d)"):format(label, _auto_attempts, ATTEMPT_CAP))
            local ok2, got = pcall(probe_save_system)
            if ok2 and got then
                _auto_dumped = true
                P("[save] schema captured -- auto-dump latched, no further attempts")
            elseif _auto_attempts >= ATTEMPT_CAP then
                P("[save] attempt cap reached without a loaded save -- use Ctrl+F9 in-game to re-dump")
            end
        end)
    end)
    P(("[save] auto-dump hook %-28s registered=%s"):format(label, tostring(ok)))
end

register_save_write_hooks()
register_path_hook()

-- Auto-report after EVERY level load. A world rebuild destroys whatever ran before it, so a probe
-- that asks the player to press a key after the load screen is asking them to do the measurement by
-- hand -- and the interesting number (did the rebuilt world keep the slot we chose?) is gone by then.
-- Delay lets GameSaveData settle, then marshal back to the game thread for the UObject reads.
pcall(function()
    RegisterLoadMapPostHook(function()
        LoopAsync(2500, function()
            on_gt(function() pcall(report_live_state, "after level load") end)
            return true   -- one-shot
        end)
    end)
end)
-- StartSaveProgress is the one confirmed to fire on this build: loading a save calls neither
-- GI.LoadGameData nor LoadGameFromSlot (the subsystem reads natively, below UFunction dispatch),
-- so a load-side trigger never lands. The rest stay as cheap extra chances to catch the dump.
auto_dump_on("/Script/Librarian.SaveSubsystem:StartSaveProgress", "SaveSubsystem.StartSaveProgress")
auto_dump_on("/Script/Librarian.SaveSubsystem:CheckAbleSave", "SaveSubsystem.CheckAbleSave")
auto_dump_on("/Script/Librarian.LibrarianGameInstanceBase:SaveGameData", "GI.SaveGameData")
auto_dump_on("/Script/Librarian.LibrarianGameInstanceBase:LoadGameData", "GI.LoadGameData")
auto_dump_on("/Script/Librarian.LibrarianGameInstanceBase:LoadGameDataBP", "GI.LoadGameDataBP")
-- DoesSaveGameExist is how the menu enumerates slots (Map01/<Slot>/SlotData), so it fires on any
-- visit to the load screen -- a trigger that needs no save at all.
auto_dump_on("/Script/Engine.GameplayStatics:DoesSaveGameExist", "DoesSaveGameExist")

-- ---- CAN WE DRIVE THE SAVE SYSTEM? -----------------------------------------------------------
-- Hooking the native save path fails (it calls GetSaveDataPath below UFunction dispatch), but
-- CALLING a UFunction is a different mechanism and the mod already does it elsewhere
-- (UpgradePlayer, ScatterBooks, UpdateInstanceTransform). If SaveGameData/LoadGameData are
-- callable, the mod can FORCE the right slot instead of only detecting the wrong one -- which
-- decides whether isolation can be automatic or has to be a warning.
--
-- Ctrl+F10 = save-side only, and deliberately writes to an EMPTY high slot so nothing existing is
-- touched (additive; delete Map01/Save<N> to undo). Load-side is NOT bound: driving a load discards
-- unsaved progress, so it stays manual until the save side is proven.
local PROBE_WRITE_SLOT = 20   -- well clear of hand-made saves; MaxSaveSlots=30

local function probe_drive_save()
    P("=== [Ctrl+F10] can the mod DRIVE the save system? ===")
    local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
    if not (gi and gi:IsValid()) then P("[drive] no GameInstance -- run this in-game"); return end

    local ver = "?"; pcall(function() ver = gi:GetProjectVersion():ToString() end)
    P(("[drive] game v%s  target slot=%d (expected EMPTY)"):format(tostring(ver), PROBE_WRITE_SLOT))

    -- Confirm the target is empty first, so a pass/fail can't be confused with clobbering a save.
    local exists = "?"
    pcall(function()
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if gs then exists = tostring(gs:DoesSaveGameExist(
            ("Map01/Save%02d/SlotData"):format(PROBE_WRITE_SLOT), 0)) end
    end)
    P(("[drive] DoesSaveGameExist(Map01/Save%02d/SlotData) = %s (want false)")
        :format(PROBE_WRITE_SLOT, exists))

    -- SaveGameData(saveSlotNum, isAutoSave). If this returns ok and the slot dir appears, the mod
    -- can place a save in a chosen slot.
    local ok, err = pcall(function() gi:SaveGameData(PROBE_WRITE_SLOT, false) end)
    P(("[drive] SaveGameData(%d, false) ok=%s%s"):format(
        PROBE_WRITE_SLOT, tostring(ok), ok and "" or (" err=" .. tostring(err))))

    -- GetNewestSaveSlot / ScanAutoSaveSlots return structs -- if these carry slot identity they
    -- close the autosave hole, since autosave WRITES are invisible to every hook.
    -- They come back as Lua tables here, not userdata, so walk them generically.
    local function show(v, depth)
        depth = depth or 0
        if type(v) == "table" then
            if depth > 2 then return "{...}" end
            local parts = {}
            for k, sub in pairs(v) do
                parts[#parts + 1] = ("%s=%s"):format(tostring(k), show(sub, depth + 1))
            end
            table.sort(parts)
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        if type(v) == "userdata" then
            local parts = {}
            for _, f in ipairs({ "SlotIndex", "MapIndex", "SaveType", "PlayTime",
                                "CompleteRowNum", "RowMaxNum", "InsertedBookNum", "BookMaxNum" }) do
                local got; pcall(function() got = v[f] end)
                if got ~= nil then parts[#parts + 1] = ("%s=%s"):format(f, tostring(got)) end
            end
            return (#parts > 0) and ("<" .. table.concat(parts, " ") .. ">") or tostring(v)
        end
        return tostring(v)
    end
    for _, fn in ipairs({ "GetNewestSaveSlot", "ScanAutoSaveSlots" }) do
        local okc, res = pcall(function() return gi[fn](gi) end)
        P(("[drive] %s() ok=%s -> %s"):format(fn, tostring(okc), show(res)))
    end

    P(("[drive] NOW CHECK: did Map01/Save%02d/ appear on disk? That is the real answer."):format(
        PROBE_WRITE_SLOT))
    P("=== [Ctrl+F10] done ===")
end

-- Ctrl+F8: can the mod DRIVE A LOAD? This is the piece that decides whether per-seed isolation can
-- be automatic (mod puts the player in the right slot) or has to be a prompt. Targets the slot the
-- save-side test wrote, so it only ever loads OUR OWN probe save -- never one of the player's.
-- Disruptive by nature: a load discards unsaved progress, hence its own keybind and its own warning.
local function probe_drive_load()
    P("=== [Ctrl+F8] can the mod DRIVE a load? ===")
    local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
    if not (gi and gi:IsValid()) then P("[drive] no GameInstance"); return end

    local exists = "?"
    pcall(function()
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if gs then exists = tostring(gs:DoesSaveGameExist(
            ("Map01/Save%02d/SlotData"):format(PROBE_WRITE_SLOT), 0)) end
    end)
    P(("[drive] target Map01/Save%02d exists=%s (run Ctrl+F10 first if false)")
        :format(PROBE_WRITE_SLOT, exists))
    if exists ~= "true" then P("[drive] aborting -- nothing to load"); return end

    -- Live state before, so the log shows whether the load actually swapped the world.
    local before = "?"
    pcall(function()
        local sg = gi.GameSaveData
        if sg and sg:IsValid() then
            before = ("rows=%s books=%s"):format(
                tostring(sg.GameProgressData.CurrentFinishedRowNum),
                tostring(sg.GameProgressData.InsertedBookNum))
        end
    end)
    P(("[drive] BEFORE load: %s"):format(before))

    -- LoadGameData(levelIdx, loadSlotNum, isAutoSave) -> bool. mapIdx was 1 in every observed
    -- GetSaveDataPath call, so levelIdx=1 is the matching guess for Map01.
    local ok, res = pcall(function() return gi:LoadGameData(1, PROBE_WRITE_SLOT, false) end)
    P(("[drive] LoadGameData(1, %d, false) ok=%s -> %s"):format(
        PROBE_WRITE_SLOT, tostring(ok), tostring(res)))

    local after = "?"
    pcall(function()
        local sg = gi.GameSaveData
        if sg and sg:IsValid() then
            after = ("rows=%s books=%s"):format(
                tostring(sg.GameProgressData.CurrentFinishedRowNum),
                tostring(sg.GameProgressData.InsertedBookNum))
        end
    end)
    P(("[drive] AFTER load: %s   (changed=%s)"):format(after, tostring(before ~= after)))
    P("[drive] ok=true alone is NOT proof -- the real test is whether the WORLD changed on screen.")
    P("=== [Ctrl+F8] done ===")
end

-- Ctrl+F7: the FULL load -- pick the slot, then rebuild the world.
-- LoadGameData alone deserializes onto the running world and leaves it visually corrupt (flashing
-- books, duplicates on the ground) because the actors are never rebuilt. The game's own Load Game
-- button does a full LoadMap of PL_M01, and the mod's connect path already forces the same thing
-- via OpenLevel. So the candidate sequence is LoadGameData (choose the save) THEN OpenLevel
-- (rebuild from it) -- which is the pre-1.0.12 flow with the dead SaveGameName write swapped out.
--
-- The open question this answers: does the rebuilt world reflect the slot WE chose, or does the
-- native path re-read whatever slot the game considers current and discard our choice?
local function probe_drive_full_load()
    P("=== [Ctrl+F7] full load: LoadGameData + OpenLevel ===")
    local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
    if not (gi and gi:IsValid()) then P("[drive] no GameInstance"); return end

    local function progress()
        local s = "?"
        pcall(function()
            local sg = gi.GameSaveData
            if sg and sg:IsValid() then
                s = ("rows=%s books=%s"):format(
                    tostring(sg.GameProgressData.CurrentFinishedRowNum),
                    tostring(sg.GameProgressData.InsertedBookNum))
            end
        end)
        return s
    end

    P(("[drive] BEFORE: %s"):format(progress()))
    local okl, res = pcall(function() return gi:LoadGameData(1, PROBE_WRITE_SLOT, false) end)
    P(("[drive] LoadGameData(1, %d, false) ok=%s -> %s   now: %s"):format(
        PROBE_WRITE_SLOT, tostring(okl), tostring(res), progress()))

    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not (statics and statics:IsValid()) then P("[drive] no GameplayStatics -- cannot OpenLevel"); return end
    P("[drive] OpenLevel(PL_M01) -- world rebuild; expect a load screen")
    local oko, err = pcall(function() statics:OpenLevel(gi, FName("PL_M01"), true, "") end)
    P(("[drive] OpenLevel ok=%s%s"):format(tostring(oko), oko and "" or (" err=" .. tostring(err))))
    P("[drive] The [live] line after the load screen reports whether the slot stuck.")
    P("=== [Ctrl+F7] done ===")
end

-- ---- Ctrl+F6: world fingerprint (does the random book scatter identify a playthrough?) --------
-- The game stores no seed -- checked GameInstance, GameMode, GameManager and the save structs --
-- so the per-game randomness lives directly in each book's saved Transform. That makes the LAYOUT
-- itself the identity: a different new game scatters books differently, and a save carries its
-- scatter with it. If this holds, a foreign save can be rejected on content rather than on which
-- slot it happens to occupy -- which is what slot numbers cannot do, since a player can overwrite
-- the AP slot with any save at all.
--
-- Keyed by book identity (aidx|chapter) and sorted, so the hash does not depend on actor iteration
-- order, which varies run to run. Positions rounded to whole units to absorb float jitter.
-- Hash EVERY book, not a sample. Sampling the lowest-numbered books after an id-sort was the first
-- attempt and it produced a constant hash across three separate new games: the spots are fixed and
-- only the ASSIGNMENT of book->spot is randomized, so a subset chosen by id can easily be one the
-- game fills identically every run. Whole-set is also just correct — partial coverage cannot prove
-- two worlds match.
local function world_fingerprint(verbose)
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return nil, 0, "no books (load a save first)" end
    local n = safe_len(books)
    if n == 0 then return nil, 0, "0 books loaded" end

    local entries, no_pos, no_info, at_origin = {}, 0, 0, 0
    local distinct_pos, distinct_aidx = {}, {}
    local correct_entries, scattered_entries, n_correct, n_attached = {}, {}, 0, 0
    local min_z, n_deep = math.huge, 0
    for i = 1, math.min(n, 8000) do
        local book = books[i]
        local info = book_info(book)
        if not info then
            no_info = no_info + 1
        else
            local aidx, chap
            pcall(function() aidx = info.AssetIdx end)
            pcall(function() chap = info.Chapter end)
            if aidx ~= nil and chap ~= nil then
                local x, y, z
                pcall(function()
                    local loc = book:K2_GetActorLocation()
                    x, y, z = loc.X, loc.Y, loc.Z
                end)
                -- "Is Abs Correct" is the WRONG split for identity. The game saves shelved books
                -- via FBookCaseSaveData, which stores no transform at all -- their position is
                -- rebuilt from (case, slot) geometry that is identical in every playthrough. That
                -- is true of a MIS-shelved book too: it sits on a fixed slot and carries just as
                -- little per-run identity as a correct one. So the predicate that matters is
                -- shelved-vs-loose, not correct-vs-incorrect. Only loose books persist a real
                -- FTransform, i.e. the randomized scatter.
                local correct, attached = false, false
                pcall(function() correct = book["Is Abs Correct"] and true or false end)
                pcall(function()
                    local parent = book:GetAttachParentActor()
                    attached = (parent and parent:IsValid()) and true or false
                end)
                if x then
                    local px, py, pz = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
                    -- Skip actors parked at the origin. During a level transition the incoming
                    -- world's books exist but are not placed yet, and they all read 0,0,0 -- a
                    -- measurement taken then sees ~2x the real actor count and hashes garbage.
                    if px == 0 and py == 0 and pz == 0 then
                        at_origin = at_origin + 1
                    else
                        if pz < min_z then min_z = pz end
                        if pz < -500000 then n_deep = n_deep + 1 end
                        local pos = ("%d,%d,%d"):format(px, py, pz)
                        distinct_pos[pos] = true
                        distinct_aidx[aidx] = true
                        -- Key by POSITION, value the book in it: the spots are fixed and only the
                        -- occupant is randomized, so position-major is the part that varies.
                        local e = ("%s=%d|%d"):format(pos, aidx, chap)
                        entries[#entries + 1] = e
                        -- Split by the game's own correct-placement verdict. A correctly shelved
                        -- book has been moved to where the PUZZLE says it goes, which is the same
                        -- destination in every playthrough -- so it carries no per-run identity and
                        -- would inflate the similarity between two unrelated late-game saves.
                        -- Only the still-misplaced books hold the randomized assignment.
                        if correct then n_correct = n_correct + 1 end
                        if attached then n_attached = n_attached + 1 end
                        -- AssetIdx 0 (Monsterology) is the one series the game never randomizes,
                        -- so it agrees for free between ANY two worlds -- excluding it keeps those
                        -- 10 books from manufacturing fake agreements.
                        if attached or aidx == 0 then
                            correct_entries[#correct_entries + 1] = e
                        else
                            scattered_entries[#scattered_entries + 1] = e
                        end
                    end
                else
                    no_pos = no_pos + 1
                end
            else
                no_info = no_info + 1
            end
        end
    end
    if #entries == 0 then return nil, 0, "no readable book positions" end
    table.sort(entries)

    local function djb2(list)
        local h = 5381
        for i = 1, #list do
            local s = list[i]
            for c = 1, #s do
                h = (h * 33 + s:byte(c)) % 4294967296
            end
        end
        return h
    end
    local h = djb2(entries)
    table.sort(scattered_entries)
    local h_scattered = djb2(scattered_entries)
    -- Shelved books hashed separately. A series may sit on ANY same-size shelf within its own
    -- bookcase (volumes in order), so the arrangement is real variation -- but it is chosen by the
    -- PLAYER, not rolled per run. Useless for telling two arbitrary saves apart (a methodical
    -- player repeats their own habits), yet ideal for matching a save against OUR OWN record of
    -- this run, where the choices being compared are the ones we watched them make.
    table.sort(correct_entries)
    local h_shelved = djb2(correct_entries)

    if verbose then
        local dp, da = 0, 0
        for _ in pairs(distinct_pos) do dp = dp + 1 end
        for _ in pairs(distinct_aidx) do da = da + 1 end
        P(("[fp]   actors=%d hashed=%d at_origin=%d no_pos=%d no_info=%d | distinct positions=%d distinct asset-idx=%d")
            :format(n, #entries, at_origin, no_pos, no_info, dp, da))
        if at_origin > 0 then
            P(("[fp]   WARNING: %d unplaced book(s) skipped -- world still streaming; re-press once settled")
                :format(at_origin))
        end
        P(("[fp]   shelved(attached)=%d  is-abs-correct=%d  LOOSE=%d  (%.1f%% shelved)")
            :format(n_attached, n_correct, #scattered_entries,
                    (#entries > 0) and (n_attached / #entries * 100) or 0))
        P(("[fp]   LOOSE-only fingerprint=%d  <- the only part that identifies a run"):format(h_scattered))
        P(("[fp]   SHELVED-only fingerprint=%d  <- shelf arrangement (player-chosen, still matchable)")
            :format(h_shelved))
        P(("[fp]   verification headroom: %d loose books (need >=16 to bootstrap)"):format(#scattered_entries))
        -- BookSanity moves HISM PILE INSTANCES to deep Z to hide locked books; it never moves the
        -- ACTORS (no SetActorLocation anywhere in the mod). The fingerprint reads actor positions
        -- for exactly that reason. If actors ever start getting teleported, the scatter signal
        -- silently becomes a record of our own hiding rather than of the save -- so flag it loudly
        -- instead of letting it pass as a legitimate layout change.
        if n_deep > 0 then
            P(("[fp]   !! %d book ACTOR(s) below Z=-500000 (min=%d) -- actors are being moved; the "
               .. "scatter fingerprint is NOT trustworthy in this state"):format(n_deep, min_z))
        end
        P("[fp]   sample entries (position=book):")
        for i = 1, math.min(3, #entries) do P(("[fp]     %s"):format(entries[i])) end
        if #correct_entries > 0 then
            P(("[fp]     [shelved]   %s"):format(correct_entries[1]))
        end
        if #scattered_entries > 0 then
            P(("[fp]     [scattered] %s"):format(scattered_entries[1]))
        end
    end
    return h, #entries, nil, h_scattered, n_correct, #scattered_entries
end

local _fp_last, _fp_last_scat = nil, nil
local function probe_world_fingerprint()
    P("=== [Ctrl+F6] world fingerprint ===")
    local fp, used, err, fp_scat, n_corr, n_scat = world_fingerprint(true)
    if not fp then P(("[fp] unavailable: %s"):format(tostring(err))); return end
    local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
    local rows, books_n = "?", "?"
    if gi and gi:IsValid() then
        pcall(function()
            local sg = gi.GameSaveData
            if sg and sg:IsValid() then
                rows = tostring(sg.GameProgressData.CurrentFinishedRowNum)
                books_n = tostring(sg.GameProgressData.InsertedBookNum)
            end
        end)
    end
    P(("[fp] fingerprint=%d  (from %d books)  rows=%s books=%s"):format(fp, used, rows, books_n))

    -- IMPOSSIBILITY CHECK. Locked series are warded, so a legitimate AP save can only ever contain
    -- books shelved from series this run actually granted. A shelved series we never unlocked is a
    -- contradiction, not a coincidence -- and unlike the scatter, this evidence GROWS as the player
    -- progresses, covering exactly the late game where loose books run out.
    local ia2 = IA()
    local unlocked = ia2 and ia2._series_unlocked
    local a2s2 = (ia2 and ia2._asset_to_series) or {}
    if type(unlocked) == "table" and next(unlocked) then
        local shelved_series, impossible, n_unlocked = {}, {}, 0
        for _ in pairs(unlocked) do n_unlocked = n_unlocked + 1 end
        local bl = FindAllOf("BP_GrabbingBook_C")
        for i = 1, math.min(safe_len(bl), 8000) do
            local b = bl[i]
            local info = book_info(b)
            if info then
                local aidx, att
                pcall(function() aidx = info.AssetIdx end)
                pcall(function()
                    local p2 = b:GetAttachParentActor(); att = (p2 and p2:IsValid()) and true or false
                end)
                if att and aidx ~= nil then
                    local sname = a2s2[aidx]
                    if sname then
                        shelved_series[sname] = true
                        if not unlocked[sname] then impossible[sname] = true end
                    end
                end
            end
        end
        local n_shelved, n_bad, first_bad = 0, 0, nil
        for _ in pairs(shelved_series) do n_shelved = n_shelved + 1 end
        for sname in pairs(impossible) do n_bad = n_bad + 1; first_bad = first_bad or sname end
        P(("[fp]   POSSIBILITY: %d series shelved, %d granted by AP, %d IMPOSSIBLE")
            :format(n_shelved, n_unlocked, n_bad))
        if n_bad > 0 then
            P(("[fp]   !! foreign save indicator -- e.g. %q is shelved but was never unlocked")
                :format(tostring(first_bad)))
        end
    else
        P("[fp]   POSSIBILITY: skipped (not connected to AP, or no series unlocked yet)")
    end

    -- Control: "Monsterology: An Introduction to Forbidden Beast" is the one series the game does
    -- NOT move between new games. Its position must stay constant while everything else varies --
    -- if it moves too, position reads are unreliable; if NOTHING moves, the scatter is not per-game.
    local ia = IA()
    local a2s = (ia and ia._asset_to_series) or {}
    local ctrl_aidx = nil
    for aidx, sname in pairs(a2s) do
        if type(sname) == "string" and sname:find("Monsterology", 1, true)
                and sname:find("Forbidden", 1, true) then
            ctrl_aidx = aidx; break
        end
    end
    if ctrl_aidx then
        -- Report by CHAPTER, lowest first. Actor iteration order varies per run, so printing "the
        -- first three found" compared chapter 0/1/2 against chapter 9/8/7 last time -- different
        -- books, so the control proved nothing. Keyed by chapter it is comparable run to run.
        local books2 = FindAllOf("BP_GrabbingBook_C")
        local by_chapter = {}
        for i = 1, math.min(safe_len(books2), 8000) do
            local b = books2[i]
            local info = book_info(b)
            local aidx
            if info then pcall(function() aidx = info.AssetIdx end) end
            if aidx == ctrl_aidx then
                local chap, x, y, z
                pcall(function() chap = info.Chapter end)
                pcall(function()
                    local loc = b:K2_GetActorLocation(); x, y, z = loc.X, loc.Y, loc.Z
                end)
                if chap and x and not (x == 0 and y == 0 and z == 0) then
                    by_chapter[chap] = ("%d,%d,%d"):format(
                        math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5))
                end
            end
        end
        local chaps = {}
        for c in pairs(by_chapter) do chaps[#chaps + 1] = c end
        table.sort(chaps)
        if #chaps == 0 then
            P(("[fp]   CONTROL Monsterology aidx=%d: no placed actors"):format(ctrl_aidx))
        else
            for i = 1, math.min(3, #chaps) do
                P(("[fp]   CONTROL Monsterology aidx=%d chapter=%d @ %s"):format(
                    ctrl_aidx, chaps[i], by_chapter[chaps[i]]))
            end
        end
    else
        P("[fp]   CONTROL Monsterology: series not in _asset_to_series (connect to AP to populate)")
    end
    if _fp_last ~= nil then
        P(("[fp] previous=%d -> %s | previous scattered=%s -> %s"):format(
            _fp_last, (fp == _fp_last) and "SAME" or "DIFFERENT",
            tostring(_fp_last_scat),
            (fp_scat == _fp_last_scat) and "SAME" or "DIFFERENT"))
    end
    _fp_last, _fp_last_scat = fp, fp_scat
    P("=== [Ctrl+F6] done ===")
end

-- ---- save/load MENU tracing (1.0.12+ slot picker) --------------------------------------------
-- Driving LoadGameData directly failed: the native loader rebuilds the world from its own notion of
-- the current slot and discards ours. But the menu's own load path obviously works, so hook it and
-- watch the real sequence instead of guessing at it. Whatever OnLoadSave does between the click and
-- the level load is the part we are missing.
-- UpdateSlotInfo is also the relabel point: it populates each row and carries the slot index.
-- Registration must be DEFERRED and RETRIED. A BP-path hook fails silently (registered=false) if the
-- Blueprint class is not loaded yet, and probe.lua runs long before the title UI exists -- which is
-- why an earlier attempt reported false for every hook. main.lua has the same problem and solves it
-- with register_bp_hooks_once, driven from the LoadMap post-hook. Retry until they take.
local _menu_hooks_ok = nil
local function register_menu_hooks()
    if _menu_hooks_ok then return true end

    local function slotinfo(p)
        local s = "?"
        pcall(function()
            local v = p:get()
            s = ("slot=%s auto=%s"):format(tostring(v.SlotNum), tostring(v.AutoSave))
        end)
        return s
    end

    -- The menu actions. Order of arrival across a real load is the finding.
    for _, sig in ipairs({
        { "/Game/Librarian/UI/Save/WBP_SaveMenu.WBP_SaveMenu_C:OnLoadSave",  "OnLoadSave" },
        { "/Game/Librarian/UI/Save/WBP_SaveMenu.WBP_SaveMenu_C:OnSaveGame",  "OnSaveGame" },
        { "/Game/Librarian/UI/Save/WBP_SaveMenu.WBP_SaveMenu_C:OnDeleteSave","OnDeleteSave" },
        { "/Game/Librarian/UI/Save/WBP_SaveMenu.WBP_SaveMenu_C:RefreshSlotList", "RefreshSlotList" },
    }) do
        local ok = pcall(function()
            RegisterHook(sig[1], function(self)
                local mode, ls = "?", "?"
                pcall(function() mode = tostring(self:get().SaveLoadMode) end)
                pcall(function()
                    local v = self:get().LoadSlotInfo
                    ls = ("slot=%s auto=%s"):format(tostring(v.SlotNum), tostring(v.AutoSave))
                end)
                P(("[menu] %s  mode=%s LoadSlotInfo=%s"):format(sig[2], mode, ls))
            end)
        end)
        P(("[menu] hook %-16s registered=%s"):format(sig[2], tostring(ok)))
    end

    -- Which slot the player clicked, with the auto flag -- the exact pair identity needs.
    local ok2 = pcall(function()
        RegisterHook("/Game/Librarian/UI/Save/WBP_SaveMenu.WBP_SaveMenu_C:SaveSlotPressed",
            function(self, widget, slot)
                P(("[menu] SaveSlotPressed  %s"):format(slotinfo(slot)))
            end)
    end)
    P(("[menu] hook %-16s registered=%s"):format("SaveSlotPressed", tostring(ok2)))

    -- Row population, and the relabel point. Must hook the BP path: the parent-class hook
    -- (/Script/Librarian.SaveSlotWidget:UpdateSlotInfo) registers but NEVER fires, because the BP
    -- subclass redeclares it and dispatch goes there instead.
    local ok3 = pcall(function()
        RegisterHook("/Game/Librarian/UI/Save/WBP_SaveSlot.WBP_SaveSlot_C:UpdateSlotInfo", function(self, slotIdx, _save)
            local idx, cur = "?", "?"
            pcall(function() idx = tostring(slotIdx:get()) end)
            pcall(function()
                local c = self:get().CurrentSlotIdx
                cur = ("slot=%s auto=%s"):format(tostring(c.SlotNum), tostring(c.AutoSave))
            end)
            P(("[menu] UpdateSlotInfo slotIdx=%s CurrentSlotIdx=%s  <- relabel point"):format(idx, cur))
        end)
    end)
    P(("[menu] hook %-16s registered=%s"):format("UpdateSlotInfo", tostring(ok3)))
    -- ok2/ok3 are the BP-path hooks: if the Blueprint class is resident they all take together,
    -- so they are a sufficient signal that the retry can stop.
    _menu_hooks_ok = (ok2 and ok3) or false
    return _menu_hooks_ok
end

-- Ctrl+F1: fully automated load -- open the menu the way a click does, then drive it.
-- Ctrl+F2 only worked once the player had opened the Load window by hand, so something the open
-- performs is a prerequisite. Two candidates, both handled here: SaveLoadMode must be LoadMode
-- (the working capture showed mode=1, and a menu that was never opened may still be in SaveMode),
-- and RefreshSlotList must have populated the slot widgets.
-- Pressing the title's Load button is the faithful way to get all of it, since that is exactly what
-- the player does; the menu is then driven on a later tick, once it has constructed.
local TITLE_LOAD_BTN =
    "BndEvt__WBP_Title_Button_Load_K2Node_ComponentBoundEvent_2_OnButtonPressedEvent__DelegateSignature"

local function _drive_menu_load(slot)
    local menu = FindFirstOf("WBP_SaveMenu_C")
    if not (menu and menu:IsValid()) then P("[auto] menu still absent"); return false end
    local mode = "?"
    pcall(function() mode = tostring(menu.SaveLoadMode) end)
    P(("[auto] menu found, SaveLoadMode=%s (1=Load)"):format(mode))
    pcall(function() menu.SaveLoadMode = 1 end)
    pcall(function() menu:RefreshSlotList() end)
    local set_ok = pcall(function()
        local ls = menu.LoadSlotInfo
        ls.SlotNum = slot
        ls.AutoSave = false
    end)
    P(("[auto] set LoadSlotInfo slot=%d ok=%s"):format(slot, tostring(set_ok)))
    local ok, err = pcall(function() menu:OnLoadSave() end)
    P(("[auto] OnLoadSave() ok=%s%s"):format(tostring(ok), ok and "" or (" err=" .. tostring(err))))
    return ok
end

local function probe_auto_load()
    P("=== [Ctrl+F1] automated load (open menu, then drive it) ===")
    local title = FindFirstOf("WBP_Title_C")
    if not (title and title:IsValid()) then
        P("[auto] no WBP_Title_C -- run this at the title screen")
        return
    end
    local opened = pcall(function() title[TITLE_LOAD_BTN](title) end)
    P(("[auto] pressed title Load button ok=%s"):format(tostring(opened)))
    -- Give the menu a beat to construct and populate before driving it.
    LoopAsync(1200, function()
        on_gt(function() pcall(_drive_menu_load, PROBE_WRITE_SLOT) end)
        return true
    end)
    P("=== [Ctrl+F1] issued -- watch for the load screen ===")
end

-- Ctrl+F2: force a LOAD by driving the menu's own path.
-- Calling LoadGameData directly failed -- the native loader rebuilt the world from its own slot and
-- discarded ours. But the menu's click path works, and the trace shows what it actually does:
--     SaveSlotPressed(slot=20, auto=false)   ->   OnLoadSave()  with LoadSlotInfo = that slot
-- So OnLoadSave reads LoadSlotInfo rather than taking an argument. Set it, then call OnLoadSave,
-- and the game should take exactly the path a click takes.
-- WBP_SaveMenu_C lives inside TitleUMG's widget tree, so it exists even with the menu closed.
local function probe_force_load()
    P("=== [Ctrl+F2] force load via the menu's own path ===")
    local menu = FindFirstOf("WBP_SaveMenu_C")
    if not (menu and menu:IsValid()) then
        P("[force] no WBP_SaveMenu_C -- open the save/load menu once so the widget exists")
        return
    end
    P(("[force] menu = %s"):format(full_name(menu)))

    local function show_ls(tag)
        pcall(function()
            local ls = menu.LoadSlotInfo
            P(("[force] %s LoadSlotInfo slot=%s auto=%s"):format(
                tag, tostring(ls.SlotNum), tostring(ls.AutoSave)))
        end)
    end
    show_ls("BEFORE")

    -- In-place member assignment first: UE4SS exposes struct properties as live references, so
    -- writing members is more reliable than replacing the whole struct with a table.
    local set_ok = pcall(function()
        local ls = menu.LoadSlotInfo
        ls.SlotNum = PROBE_WRITE_SLOT
        ls.AutoSave = false
    end)
    if not set_ok then
        set_ok = pcall(function()
            menu.LoadSlotInfo = { SlotNum = PROBE_WRITE_SLOT, AutoSave = false }
        end)
        P(("[force] in-place set failed; whole-struct assign ok=%s"):format(tostring(set_ok)))
    end
    show_ls("AFTER-SET")
    if not set_ok then P("[force] could not set LoadSlotInfo -- aborting"); return end

    local ok, err = pcall(function() menu:OnLoadSave() end)
    P(("[force] OnLoadSave() ok=%s%s"):format(tostring(ok), ok and "" or (" err=" .. tostring(err))))
    P(("[force] expect a load screen; the [live] line should report slot %d's contents")
        :format(PROBE_WRITE_SLOT))
    P("=== [Ctrl+F2] done ===")
end

-- Ctrl+F3: find the save menu's real Blueprint path.
-- The parent-class hooks (SaveLoadMenu:RefreshSlotList, SaveSlotWidget:UpdateSlotInfo) register but
-- never fire: the BP subclass redeclares them, so dispatch goes to the BP version and the parent
-- hook is bypassed -- the same thing already documented for OnLevelUp in main.lua. Hooking needs the
-- BP asset path, which cannot be read off the header dump, so read it from a live instance instead.
-- Run with the Load/Save menu OPEN.
local function probe_find_menu_path()
    P("=== [Ctrl+F3] locate the save-menu Blueprint ===")
    for _, cls in ipairs({ "WBP_SaveMenu_C", "WBP_SaveSlot_C", "SaveLoadMenu", "SaveSlotWidget",
                           "WBP_PauseMenu_C", "PauseMenu" }) do
        local objs; pcall(function() objs = FindAllOf(cls) end)
        local n = safe_len(objs)
        P(("[path] FindAllOf(%q) -> %d"):format(cls, n))
        for i = 1, math.min(n, 3) do
            local o = objs[i]
            if o and o:IsValid() then
                P(("[path]   obj   %s"):format(full_name(o)))
                -- The class's own full name is what a RegisterHook path is built from.
                pcall(function()
                    local c = o:GetClass()
                    if c and c:IsValid() then
                        P(("[path]   CLASS %s"):format(c:GetFullName()))
                    end
                end)
            end
        end
    end
    P("[path] hook path = the CLASS line's object path + ':' + FunctionName")
    P("=== [Ctrl+F3] done ===")
end

-- Ctrl+F5: can we start a New Game ourselves? WBP_Title:StartGame() is a callable UFunction, and
-- calling BP functions by reflection is the same mechanism that made SaveGameData work where the
-- hook-based approach did not. DESTRUCTIVE-ish: starts a new game, so unsaved progress is lost.
local function probe_force_new_game()
    P("=== [Ctrl+F5] force New Game via WBP_Title:StartGame() ===")
    local title = FindFirstOf("WBP_Title_C")
    if not (title and title:IsValid()) then
        P("[force] no WBP_Title_C live -- run this at the title screen")
        return
    end
    P(("[force] title widget = %s"):format(full_name(title)))
    local ok, err = pcall(function() title:StartGame() end)
    P(("[force] StartGame() ok=%s%s"):format(tostring(ok), ok and "" or (" err=" .. tostring(err))))
    P("[force] watch for a load screen; the [live] line after it reports what loaded")
    P("=== [Ctrl+F5] done ===")
end

-- Retry until the widget Blueprints are loaded. They come up with the title UI, well after this
-- script runs; without the retry every hook silently reports registered=false and the menu looks
-- like it never fires.
do
    local tries = 0
    LoopAsync(2000, function()
        tries = tries + 1
        local done = false
        on_gt(function() done = register_menu_hooks() end)
        if done then P(("[menu] hooks registered after %d attempt(s)"):format(tries)); return true end
        if tries >= 30 then P("[menu] giving up after 30 attempts -- open the save menu, then reload the mod"); return true end
        return false
    end)
end

-- ---- keybinds (everything marshaled to the game thread; pcall-wrapped) ---------------------
-- Ctrl+F9 for a manual re-dump. Plain F11 is registered too but the game or shell appears to eat
-- it -- the bind takes and the callback never fires -- so it is a fallback, not the trigger.
P(("[save] Key.F11=%s Key.F9=%s ModifierKey=%s"):format(
    tostring(Key and Key.F11), tostring(Key and Key.F9), tostring(ModifierKey ~= nil)))
pcall(function()
    RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F9] pressed"); on_gt(function() pcall(probe_save_system) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F10] pressed"); on_gt(function() pcall(probe_drive_save) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F8] pressed"); on_gt(function() pcall(probe_drive_load) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F7] pressed"); on_gt(function() pcall(probe_drive_full_load) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F6] pressed"); on_gt(function() pcall(probe_world_fingerprint) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F5] pressed"); on_gt(function() pcall(probe_force_new_game) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F3, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F3] pressed"); on_gt(function() pcall(probe_find_menu_path) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F2, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F2] pressed"); on_gt(function() pcall(probe_force_load) end)
    end)
end)
pcall(function()
    RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, function()
        P("[Ctrl+F1] pressed"); on_gt(function() pcall(probe_auto_load) end)
    end)
end)
RegisterKeyBind(Key.F11, function() P("[F11] pressed"); on_gt(function() pcall(probe_save_system) end) end)
RegisterKeyBind(Key.F12, function() P("[F12] pressed"); on_gt(function() pcall(probe_skill_timers) end) end)
RegisterKeyBind(Key.F10, function() P("[F10] pressed"); on_gt(function() pcall(probe_move_speed) end) end)
RegisterKeyBind(Key.F6,  function() P("[F6] pressed");  on_gt(function() pcall(probe_lights) end) end)
RegisterKeyBind(Key.F9, function() P("[F9] pressed"); on_gt(function() pcall(probe_teleport_one) end) end)
RegisterKeyBind(Key.F8, function() P("[F8] pressed"); on_gt(function() pcall(probe_scatter) end) end)
RegisterKeyBind(Key.F5, function() P("[F5] pressed"); on_gt(function() pcall(probe_book_identity) end) end)
RegisterKeyBind(Key.F1, function() P("[F1] pressed"); on_gt(function() pcall(probe_hide_toggle) end) end)
RegisterKeyBind(Key.F2, function() P("[F2] pressed"); on_gt(function() pcall(probe_control_surface) end) end)
RegisterKeyBind(Key.F3, function() P("[F3] pressed"); on_gt(function() pcall(probe_placement_watch) end) end)
RegisterKeyBind(Key.F7, function() P("[F7] pressed"); on_gt(function() pcall(probe_bag_capacity) end) end)

P("probe harness loaded.")
P("  BookSanity: F5=book identity  F1=hide book  F3=placement watch  F8=HISM API  F9=teleport instance")
P("  Filler/traps/items: F12=skill timers(cooldown/active/reach)  F10=move speed  F6=lighting(dim/off)  F7=bag capacity  F2=control surface")
P("  Save system: auto-dumps on first save/load; Ctrl+F9 = re-dump; Ctrl+F10 = drive-save (writes empty slot 20); Ctrl+F8 = load-only (corrupts world); Ctrl+F7 = FULL load; Ctrl+F6 = world fingerprint; Ctrl+F5 = force New Game; Ctrl+F3 = find save-menu BP path; Ctrl+F2 = force load slot 20; Ctrl+F1 = AUTOMATED load (opens menu itself) (SaveGameName, save object, SaveSubsystem, save classes)")
