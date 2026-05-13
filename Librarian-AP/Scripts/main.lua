-- Librarian Archipelago Mod (UE4SS Lua)
-- Top-level wiring: AP client setup, save-slot redirection, title-screen
-- text + button gating, BP hooks (UpgradePlayer, FinishRow, OnLevelUp,
-- StartGame), F4/F12 keybinds, and the post-connect pre-apply loop.
-- World mutations live in AP/ItemApply.lua.

local MOD = "LibrarianAP"

local function log(msg)
    print(("[%s] %s\n"):format(MOD, tostring(msg)))
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
    else
        log("[title-buttons] not connected; both gameplay buttons disabled")
    end

    pcall(function() set_button_enabled(widget.Button_LoadGame, enable_continue) end)
    pcall(function() set_button_enabled(widget.Button_StartGame, enable_start) end)
end

-- ============================================================
-- Title-screen status text hijack
-- ============================================================
-- WBP_Title.Text_Version is the bottom-right version line. We overwrite
-- it with: <Game version> | LibAP vX.YY | AP: <state>. If GetProjectVersion
-- isn't in TESTED_GAME_VERSIONS, append "(UNTESTED)" so the player knows
-- compatibility isn't validated against their game build.

local MOD_VERSION = "1.0.1"
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
-- STATE PROBE: ran once per level after the player has spawned
-- ============================================================
local probed_levels = {}

local function probe_player(player)
    log("====== PLAYER STATE ======")
    log("Player: " .. safe_name(player))
    log("Class:  " .. safe_class(player))

    pcall(function() log(("EnableUpgradeNum (banked points): %d"):format(player.EnableUpgradeNum)) end)
    pcall(function() log(("DebugUpgradeNum:                  %d"):format(player.DebugUpgradeNum)) end)
    pcall(function() log(("MaxHP=%d  LeftHP=%d"):format(player.MaxHP, player.LeftHP)) end)

    -- XP curve: rows-finished thresholds for level-ups
    pcall(function()
        local arr = player.SkillLevelUpRowNum
        log("SkillLevelUpRowNum (XP curve, rows needed at each level): " .. dump_num_array(arr))
    end)

    -- Per-skill data via direct FindFirstOf on each known class.
    -- (TMap iteration on SkillInfo with enum keys was returning nothing.)
    do
        log("Skills (via class-name enumeration):")
        local skill_classes = {
            { idx = 0, ability = "Jump",              cls = "Skill_Jump_C" },
            { idx = 1, ability = "UpgradeBag",        cls = "Skill_UpgradeBag_C" },
            { idx = 2, ability = "UpgradeBag2",       cls = "Skill_UpgradeBag2_C" },
            { idx = 3, ability = "ShowMatchingShelf", cls = "Skill_ShowCorrentBookCase_C" },
            { idx = 4, ability = "Jogging",           cls = "Skill_Run_C" },
            { idx = 5, ability = "SortBooks",         cls = "Skill_SortBook_C" },
            { idx = 6, ability = "AutoShelve",        cls = "Skill_AutoShelve_C" },
            { idx = 7, ability = "ShowSameTypeBook",  cls = "Skill_ShowSameTypeBook_C" },
            { idx = 8, ability = "GrabSameTypeBook",  cls = "Skill_GrabSameTypeBook_C" },
        }
        for _, s in ipairs(skill_classes) do
            local skill = FindFirstOf(s.cls)
            if not skill or not skill:IsValid() then
                log(("  [%d %-20s] %s NOT FOUND"):format(s.idx, s.ability, s.cls))
            else
                local current, max = -1, -1
                pcall(function() current = skill.CurrentLevel end)
                pcall(function() max = skill:GetMaxSkillLevel() end)
                log(("  [%d %-20s] %s  current=%d  max=%d"):format(
                    s.idx, s.ability, s.cls, current, max))
                pcall(function()
                    local cd = skill.CoolDownTimePreLevel
                    if cd and #cd > 0 then
                        log("    CoolDownTimePreLevel: " .. dump_num_array(cd))
                    end
                end)
                pcall(function()
                    local at = skill.ActiveTimePreLevel
                    if at and #at > 0 then
                        log("    ActiveTimePreLevel:   " .. dump_num_array(at))
                    end
                end)
                pcall(function()
                    local gb = skill.GrabBookNumArray
                    if gb and #gb > 0 then
                        log("    GrabBookNumArray:     " .. dump_num_array(gb))
                    end
                end)
            end
        end

        -- Diagnostic: SkillInfo TMap stats (keep for visibility, in case it works for someone)
        pcall(function()
            local skillInfo = player.SkillInfo
            if skillInfo then
                local n = -1
                pcall(function() n = skillInfo:Num() end)
                log(("(diagnostic) player.SkillInfo:Num() = %s"):format(tostring(n)))
            end
        end)
    end

    -- Item bag: capacity table and current state
    pcall(function()
        local bag = player.ItemBagComponent
        if not bag or not bag:IsValid() then return end
        log("ItemBagComponent:")
        local lvl = -1
        pcall(function() lvl = bag:GetBagLevel() end)
        log("  current bag level: " .. tostring(lvl))
        pcall(function() log("  MaxBagItemLevel:   " .. dump_num_array(bag.MaxBagItemLevel)) end)
        pcall(function()
            local items = bag.Items
            if items then log("  current items in bag: " .. tostring(#items)) end
        end)
    end)
end

local function probe_game_instance()
    log("====== GAME INSTANCE ======")
    local gi = FindFirstOf("BP_LibrarianGameInstance_C")
    if not gi or not gi:IsValid() then
        gi = FindFirstOf("LibrarianGameInstanceBase")
    end
    if not gi or not gi:IsValid() then
        log("GameInstance not found")
        return
    end
    log("GameInstance: " .. safe_name(gi))
    pcall(function() log("SelectedLevel: " .. tostring(gi.SelectedLevel)) end)
    pcall(function()
        local s = "?"
        local ok = pcall(function() s = gi.SaveGameName:ToString() end)
        if not ok then pcall(function() s = tostring(gi.SaveGameName) end) end
        log("SaveGameName:  " .. tostring(s))
    end)

    -- LevelDataAssets pointer is null on the GI at boot; fall back to global search
    local lda
    pcall(function() lda = gi.LevelDataAssets end)
    if not lda or not lda:IsValid() then
        log("LevelDataAssets is null on GI; trying FindFirstOf('LevelDataAsset')...")
        lda = FindFirstOf("LevelDataAsset")
    end
    if lda and lda:IsValid() then
        log("LevelDataAsset: " .. safe_name(lda))
        pcall(function()
            local levels = lda.Levels
            if levels then
                local n = #levels
                log(("Levels (count=%d):"):format(n))
                for i = 1, n do
                    local info = levels[i]
                    local lname, dname, plname = "?", "?", "?"
                    pcall(function() lname = info.LevelName:ToString() end)
                    pcall(function() dname = info.DisplayName:ToString() end)
                    pcall(function() plname = info.PreviewLevelName:ToString() end)
                    log(("  [%d] LevelName=%s  Display=%s  Preview=%s"):format(i - 1, lname, dname, plname))
                end
            end
        end)
    else
        log("LevelDataAsset still not found globally (likely not yet loaded)")
    end

    pcall(function()
        local sublvls = gi.SubLevelSuffixsArray
        if sublvls and #sublvls > 0 then
            log(("SubLevelSuffixsArray (count=%d):"):format(#sublvls))
            for i = 1, #sublvls do
                log(("  [%d] %s"):format(i - 1, sublvls[i]:ToString()))
            end
        end
    end)
end

local function try_probe()
    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not player or not player:IsValid() then return false end
    probe_player(player)
    probe_game_instance()
    log("====== PROBE COMPLETE ======")
    return true
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
                    local idx
                    pcall(function() idx = b.ItemInfo.AssetIdx end)
                    if idx and idx > 0 and not sample[idx] then
                        sample[idx] = true
                        distinct = distinct + 1
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
            if IA._deferred_worker_running then
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
        pcall(function() IA.refresh_index_if_changed() end)
        -- Force re-apply (idempotent, cheap) for safety against any drift.
        pcall(function() IA._apply_bookcases_to_world() end)
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
        pcall(function() IA.sync_progress_state() end)
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
    log(("Activating gameplay (reason: %s)"):format(reason or "?"))
    local APClient = package.loaded["AP/APClient"]
    if APClient and APClient.set_in_game then APClient:set_in_game(true) end
    local IA = package.loaded["AP/ItemApply"]
    if IA and IA.set_gameplay_active then IA.set_gameplay_active(true) end
    start_gameplay_loops()
end

local function deactivate_gameplay(reason)
    log(("Deactivating gameplay (reason: %s)"):format(reason or "?"))
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

    if probed_levels[lvlname] then
        log("(level already probed)")
        return
    end

    local attempts = 0
    LoopAsync(500, function()
        attempts = attempts + 1
        if try_probe() then
            probed_levels[lvlname] = true
            return true
        end
        if attempts >= 30 then
            log("Probe gave up after 30 attempts (15s)")
            return true
        end
        return false
    end)
end)

-- ============================================================
-- HOOK: Upgrade flow
-- ============================================================
RegisterHook("/Script/Librarian.LibrarianCharacter:UpgradePlayer", function(self, ability)
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

-- ============================================================
-- HOOK: Notification UFunctions (read-only, observation only).
-- ============================================================
-- Active calls to these have been observed to freeze the game; we hook
-- the natives instead and log when the GAME calls them organically.
local function fext_to_str(p)
    if not p then return "<nil>" end
    local v
    pcall(function() v = p:get() end)
    if not v then return "<getfail>" end
    local s
    pcall(function() s = v:ToString() end)
    if s then return tostring(s) end
    return "<no-tostring>"
end

local function fnum_to_str(p)
    if not p then return "<nil>" end
    local v
    pcall(function() v = p:get() end)
    return tostring(v)
end

RegisterHook("/Script/Librarian.LibrarianGameMode:ShowNotification", function(self, text_param, duration_param)
    log(("[notif-probe] GameMode.ShowNotification text='%s' duration=%s"):format(
        fext_to_str(text_param), fnum_to_str(duration_param)))
end)

RegisterHook("/Script/Librarian.NotificationBoxWidget:AddNotification", function(self, text_param, duration_param)
    log(("[notif-probe] NotificationBox.AddNotification text='%s' duration=%s"):format(
        fext_to_str(text_param), fnum_to_str(duration_param)))
end)

RegisterHook("/Script/Librarian.NotificationBoxWidget:RemoveNotification", function(self, notify_param)
    log("[notif-probe] NotificationBox.RemoveNotification fired")
end)

RegisterHook("/Script/Librarian.NotificationWidget:ShowNotification", function(self, text_param, duration_param)
    log(("[notif-probe] NotificationWidget.ShowNotification text='%s' duration=%s"):format(
        fext_to_str(text_param), fnum_to_str(duration_param)))
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

local function on_level_up_native(self)
    local n = "?"
    pcall(function() n = tostring(self:get().EnableUpgradeNum) end)
    log((">> [C++] OnLevelUp        EnableUpgradeNum=%s"):format(n))
end

local function on_level_up_bp(self)
    local n = "?"
    pcall(function() n = tostring(self:get().EnableUpgradeNum) end)
    log((">> [BP]  OnLevelUp        EnableUpgradeNum=%s"):format(n))
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

local function on_show_skill_level_up_native(self) log(">> [C++] ShowSkillLevelUp") end
local function on_show_skill_level_up_bp(self)     log(">> [BP]  ShowSkillLevelUp") end

hook_safe("/Script/Librarian.LibrarianCharacter:OnLevelUp",
    "OnLevelUp (C++)", on_level_up_native)
hook_safe("/Script/Librarian.LibrarianCharacter:ShowSkillLevelUp",
    "ShowSkillLevelUp (C++)", on_show_skill_level_up_native)

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
    local ok2 = hook_safe("/Game/Librarian/Blueprints/Character/BP_LibrarianCharacter.BP_LibrarianCharacter_C:ShowSkillLevelUp",
        "ShowSkillLevelUp (BP)", on_show_skill_level_up_bp)
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

    -- HUD-update probes (read-only). We want to see how the game itself
    -- calls UpdateSkill / CheckLeftUpgradeNum / OnFinishNewRow_Event
    -- naturally, so we can replicate the call context for the missing
    -- ability icon after reconnect.
    hook_safe(
        "/Game/Librarian/UI/Game/WBP_PlayerInfo.WBP_PlayerInfo_C:UpdateSkill",
        "WBP_PlayerInfo.UpdateSkill", function(self, skill_p, level_p, left_p)
            local s, l, lf = "?", "?", "?"
            pcall(function() s = tostring(skill_p:get()) end)
            pcall(function() l = tostring(level_p:get()) end)
            pcall(function() lf = tostring(left_p:get()) end)
            log(("[hud-probe] WBP_PlayerInfo.UpdateSkill skill=%s level=%s left=%s"):format(s, l, lf))
        end)
    hook_safe(
        "/Game/Librarian/UI/Game/WBP_PlayerInfo.WBP_PlayerInfo_C:CheckLeftUpgradeNum",
        "WBP_PlayerInfo.CheckLeftUpgradeNum", function(self, row_p)
            local r = "?"
            pcall(function() r = tostring(row_p:get()) end)
            log(("[hud-probe] WBP_PlayerInfo.CheckLeftUpgradeNum rowNum=%s"):format(r))
        end)
    hook_safe(
        "/Game/Librarian/UI/Game/WBP_PlayerInfo.WBP_PlayerInfo_C:OnFinishNewRow_Event",
        "WBP_PlayerInfo.OnFinishNewRow_Event", function(self, num_p)
            local n = "?"
            pcall(function() n = tostring(num_p:get()) end)
            log(("[hud-probe] WBP_PlayerInfo.OnFinishNewRow_Event Num=%s"):format(n))
        end)
    hook_safe(
        "/Game/Librarian/UI/Game/WBP_PlayerInfo.WBP_PlayerInfo_C:Construct",
        "WBP_PlayerInfo.Construct", function(self)
            log("[hud-probe] WBP_PlayerInfo.Construct")
        end)

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

    if ok1 and ok2 then
        bp_hooks_registered = true
        log("BP hooks registered (OnLevelUp, ShowSkillLevelUp, WBP_Title buttons, HUD probes, ConnectMenu)")
    end
end

RegisterHook("/Script/Librarian.LibrarianCharacter:MajorSkillUsed", function(self)
    log(">> MajorSkillUsed")
end)

RegisterHook("/Script/Librarian.LibrarianCharacter:FinalSkillUsed", function(self)
    log(">> FinalSkillUsed")
end)

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
    local row
    pcall(function() row = finishedRow:get() end)
    log((">> FinishRow        row=%s"):format(tostring(row)))

    if row then announce_goal_progress(row) end

    -- Goal trigger by row count (for non-full goals). Full goal lets the
    -- game's natural EndGame fire when the player walks through the end
    -- door. Half / floor goals fire STATUS_GOAL as soon as their threshold
    -- row is finished.
    if not _goal_sent and row then
        local APClient_mod = package.loaded["AP/APClient"]
        local sd = APClient_mod and APClient_mod.slot_data
        if sd and sd.goal_row_threshold and sd.goal then
            local is_full = (sd.goal == 1)  -- option_full = 1
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
    if IA and IA.detect_completed_rows then
        local sent = 0
        pcall(function() sent = IA.detect_completed_rows() end)
        log(("[AP] row-detect: sent %d location check(s)"):format(sent or 0))
    end
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
    local n
    pcall(function() n = num:get() end)
    log((">> NewRowFinished   num=%s"):format(tostring(n)))
end)

RegisterHook("/Script/Librarian.LibrarianGameMode:EndGame", function(self)
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
    set_status = menu_set_status,
    set_fields = menu_set_fields,
    show       = menu_show,
    hide       = menu_hide,
    toggle     = menu_toggle,
}

RegisterKeyBind(Key.F4, function()
    log("[F4] toggle connection menu")
    menu_toggle()
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
