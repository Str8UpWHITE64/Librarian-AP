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

-- ---- keybinds (everything marshaled to the game thread; pcall-wrapped) ---------------------
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
