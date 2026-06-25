-- AP/ItemApply.lua
-- Translates received AP items into game-state mutations.
--
-- Two warding axes:
--   • Per-book by SERIES: a book is unwarded iff its series is in _series_unlocked.
--     Ward = SetActorHiddenInGame(true) + collision-off (hide title, block pickup).
--   • Per-bookcase by SECTION: cases sorted, visible_count = _shelves_open[section].
--     Each Progressive Shelf Unlock (X) reveals one more case in section X.
-- Major Magic = UpgradePlayer(idx) (guarded by _ap_grant vs the main.lua hook echo).
-- Minor Magic abilities aren't items — earned from the in-world chest each key opens.
--
-- Derived state:
--   _series_unlocked = { [series] = true } from N unlocks × series_per_unlock into series_order.
--   _shelves_open    = { [section] = open_count }; section active iff >= 1, visible cases = count.

local M = {}

local LOG_PREFIX = "[ItemApply]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

-- Crash-hunt instrumentation (see CRASH_HANDOFF.md). trace = durable breadcrumb ledger;
-- _diag_on = bisection switches (default on). Both pcall-guarded so a missing module is safe.
local trace = (function()
    local ok, t = pcall(require, "AP/trace")
    if ok and type(t) == "table" and t.begin then return t end
    return { init = function() end, begin = function() end, finish = function() end, mark = function() end }
end)()
local _DIAG = (function()
    local ok, t = pcall(require, "diag_flags")
    return (ok and type(t) == "table") and t or {}
end)()
local function _diag_on(flag)
    local v = _DIAG[flag]
    if v == nil then return true end
    return v and true or false
end

-- Run fn on the GAME THREAD via ExecuteInGameThread. LoopAsync callbacks run on a
-- separate async thread, so warding writes from there race the engine's collision/render/
-- cluster-tree workers -> crash (CRASH_HANDOFF.md). `flag` gates the marshal for bisection;
-- falls back to inline when off or ExecuteInGameThread is missing, so loading never breaks.
local function _on_game_thread(fn, flag)
    if _diag_on(flag) and type(ExecuteInGameThread) == "function" then
        M._pump_enqueue(fn)
    else
        fn()
    end
end

-- ============================================================================
-- Ward pump: ONE serialized game-thread drain for every warding marshal.
-- ----------------------------------------------------------------------------
-- L1 (book actors), L2 (bookcases), L3 (HISM pile, from main.lua), and the
-- reconcile write pass all append a work unit to ONE FIFO; the pump drains it
-- ONE AT A TIME via ExecuteInGameThread, so at most one marshal is ever in
-- flight. That moves the writes onto the game thread (killing the off-thread
-- render race) while keeping the concurrent-marshal count at 1 -- structurally
-- under UE4SS #1180 regardless of burst size. Producers keep their own chunking,
-- LoopAsync reschedule, and re-entry guards verbatim; the ONLY change is that the
-- marshal point (_on_game_thread / main.lua on_game_thread) enqueues here instead
-- of calling ExecuteInGameThread directly. FIFO preserves the existing
-- L2-before-L1 order (flush_apply enqueues L2 first).
-- Threading: enqueue + pop run on the async (LoopAsync) thread; _pump_busy is set
-- async and cleared in the game-thread closure -- the same cross-thread flag
-- pattern the field-proven layer-3 _b2_running already relies on.
-- ============================================================================
local PUMP_MS   = 25     -- drain cadence (between the ~16ms frame and the 50ms chunk delay)
M._ward_q       = {}
M._ward_q_head  = 1
M._ward_q_tail  = 0
M._pump_busy    = false
M._pump_gen     = 0
M._pump_started = false

-- Append a game-thread work unit, stamped with the current world epoch. A reload
-- between enqueue and drain bumps the epoch; the pump drops the unit before it
-- marshals -- the L1 chunk worker has no epoch guard of its own, so this is it.
function M._pump_enqueue(fn)
    M._ward_q_tail = M._ward_q_tail + 1
    M._ward_q[M._ward_q_tail] = { run = fn, epoch = M._world_epoch or 0 }
end

-- True when nothing is queued and no marshal is in flight. The title-settle loop
-- gates Continue on this so the menu doesn't re-enable mid-drain.
function M._pump_idle()
    return (not M._pump_busy) and (M._ward_q_head > M._ward_q_tail)
end

local function _pump_tick()
    -- One marshal at a time. The busy gate clears only via the closure (gen-guarded
    -- below) or reset_hism_state. There is deliberately NO time-based watchdog: a
    -- closure that never runs means the game thread is stalled/dead, and the gate then
    -- correctly PAUSES the pump until the thread resumes (the queued closure clears it).
    -- Force-clearing during a stall would issue overlapping marshals -- the very #1180
    -- abort the pump exists to prevent. The title-settle drain cap (main.lua) keeps a
    -- stalled pump from soft-locking the menu on its own.
    if M._pump_busy then return false end
    if M._ward_q_head > M._ward_q_tail then return false end   -- queue empty
    local unit = M._ward_q[M._ward_q_head]
    M._ward_q[M._ward_q_head] = nil
    M._ward_q_head = M._ward_q_head + 1
    if not unit then return false end
    if (unit.epoch or 0) ~= (M._world_epoch or 0) then return false end   -- stale world -> drop
    if type(ExecuteInGameThread) ~= "function" then
        pcall(unit.run)   -- no marshal available (loading edge): run inline
        return false
    end
    M._pump_busy = true
    local gen = M._pump_gen
    if not M._pump_alive_logged then
        M._pump_alive_logged = true
        log("[ward-pump] alive: draining first unit on the game thread")
    end
    ExecuteInGameThread(function()
        -- Re-check the epoch INSIDE the closure (the world can reload between the
        -- async pop and this game-thread run). pcall so a throw still clears the gate.
        if (unit.epoch or 0) == (M._world_epoch or 0) then pcall(unit.run) end
        -- Unconditional, generation-guarded clear (finally-style). A reset mid-marshal
        -- bumped _pump_gen, so a stale closure leaves the new world's gate untouched.
        if gen == M._pump_gen then M._pump_busy = false end
    end)
    return false
end

-- Install the pump once. LoopAsync ticks in ALL phases (title + gameplay), so the
-- connect-time burst -- the worst crash window, behind the title menu -- is covered.
function M._ward_pump_start()
    if M._pump_started then return end
    if type(LoopAsync) ~= "function" then return end
    M._pump_started = true
    LoopAsync(PUMP_MS, _pump_tick)
end

-- ============================================================================
-- Constants (mirror apworld/librarian/data.py + Locations.py)
-- ============================================================================

-- AP location ID layout (mirrors apworld/librarian/Locations.py)
local AP_BASE              = 1910000
local AP_LOC_SECTION_FIRST = AP_BASE + 500   -- 31 entries: section completions
local AP_LOC_FLOOR_FIRST   = AP_BASE + 550   -- 2 entries: Floor 1, Floor 2
local AP_LOC_LEVEL_FIRST   = AP_BASE + 560   -- 45 entries: Level 1..45
local AP_LOC_MILESTONE_FIRST = AP_BASE + 640 -- 22 entries: aligned to MILESTONE_THRESHOLDS order
local AP_LOC_ROW_COMPLETION_FIRST = AP_BASE + 1000 -- 50 entries: aligned to ROW_COMPLETION_THRESHOLDS order
local AP_MAX_PLAYER_LEVEL  = 45

-- section_id → ordinal in data.SECTIONS. Fallback when slot_data lacks
-- section_location_map; "Section Complete: <id>" loc = AP_LOC_SECTION_FIRST + SECTION_IDX[id].
-- Keep in lockstep with the SECTIONS tuple ordering.
local SECTION_IDX = {
    ["1A"] =  0, ["1B"] =  1, ["1C"] =  2, ["1D"] =  3, ["1E"] =  4,
    ["1F"] =  5, ["1G"] =  6, ["1H"] =  7, ["1I"] =  8, ["1J"] =  9,
    ["1K"] = 10, ["1L"] = 11, ["1M"] = 12, ["1N"] = 13,
    ["2A"] = 14, ["2B"] = 15, ["2C"] = 16, ["2D"] = 17, ["2E"] = 18,
    ["2F"] = 19, ["2G"] = 20, ["2H"] = 21, ["2I"] = 22, ["2J"] = 23,
    ["2K"] = 24, ["2L"] = 25, ["2M"] = 26, ["2N"] = 27, ["2O"] = 28,
    ["2P"] = 29, ["2Q"] = 30,
}

-- floor number → ordinal offset within AP_LOC_FLOOR_FIRST. Fallback when
-- slot_data lacks floor_location_map. Floor 1 → loc 1910550, Floor 2 → 1910551.
local FLOOR_IDX = {
    [1] = 0,
    [2] = 1,
}

-- Cumulative XP curve (mirrors data.py:XP_CURVE). Fallback for run_baseline_sync's
-- level catch-up when player.SkillLevelUpRowNum isn't readable; live BP read is primary.
-- Keep in lockstep with data.py XP_CURVE.
local XP_CURVE = {
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 19, 22, 25, 29, 33, 37, 41,
    46, 50, 55, 61, 66, 72, 78, 84, 91, 98, 105, 112, 120, 127, 135,
    152, 161, 170, 179, 189, 200, 212, 225, 239, 254,
}

local UPGRADE = {
    JUMP                = 0,
    UPGRADE_BAG         = 1,
    UPGRADE_BAG_2       = 2,
    SHOW_MATCHING_SHELF = 3,
    JOGGING             = 4,
    SORT_BOOKS          = 5,
    AUTO_SHELVE         = 6,
    SHOW_SAME_TYPE_BOOK = 7,
    GRAB_SAME_TYPE_BOOK = 8,
}

-- AP item name → UpgradeAbility index. Progressive: each instance bumps level by 1.
local SKILL_ITEM_TO_ABILITY = {
    ["Progressive Sort"]          = UPGRADE.SORT_BOOKS,
    ["Progressive Shelf Guide"]   = UPGRADE.SHOW_MATCHING_SHELF,
    ["Progressive Insight"]       = UPGRADE.SHOW_SAME_TYPE_BOOK,
    ["Progressive Auto-Shelving"] = UPGRADE.AUTO_SHELVE,
    ["Progressive Assemble"]      = UPGRADE.GRAB_SAME_TYPE_BOOK,
}

-- ============================================================================
-- State
-- ============================================================================

-- Static lookups (loaded from asset_idx_to_series.json on init).
M._asset_to_series  = {}  -- { [asset_idx_int] = series_name_string }
M._asset_to_section = {}  -- { [asset_idx_int] = section_id_string }
M._asset_to_volumes = {}  -- { [asset_idx_int] = volume_count_int (3/5/10) }

-- AP-supplied per-seed data (set in set_slot_data()).
M._slot_data = nil

-- Per-session state.
M._received_counts   = {}  -- { [item_name] = count }
M._series_unlocked   = {}  -- { [series_name] = true }
M._shelves_open      = {}  -- { [section_id] = open_count }
-- Read-only {[series]=true} snapshot for the GAME-THREAD book hooks (ENFORCE/REVEAL/grab-check).
-- They must NOT call _compute_unwarded_set: it allocates a table and iterates _series_unlocked on
-- the game thread, racing _recompute_state's mod-thread rebuild -> Lua-heap corruption / UE4SS abort
-- (the rc3 crash). Published atomically by _recompute_state; hooks do a single lookup, no alloc.
M._unwarded_snapshot = {}
-- Count of OnLevelUp events deferred off the game thread; drained by the 3s mod-thread loop.
M._pending_level_ups = 0

-- True around AP-driven UpgradePlayer calls so the main.lua hook doesn't echo a check.
M._ap_grant = false

-- True once both slot_data + asset_data are loaded. Until then items only count.
M._initialized = false

-- True only during real gameplay (not title). Set by main.lua's LoadMap hook.
-- World mutations gate on this — touching actors at the title screen crashes.
M._gameplay_active = false

-- Pre-apply: warding runs behind the post-connect title screen so it completes
-- BEFORE Continue. main.lua keeps Continue disabled until _pre_apply_complete,
-- which the settle loop sets once the deferred tree-walk queue drains and stays empty.
M._allow_pre_apply = false
M._pre_apply_complete = false

-- Bumped every apply_item. The pre-apply settle loop watches it for "items quieted":
-- N idle ticks => fire one world-mutating flush_apply with the FINAL state, not N.
M._last_item_apply_tick = 0

-- Mid-gameplay reconnect: AP re-sends every received item one at a time. Without this,
-- each apply_item would flush_apply on partial state and flash every bookcase to hidden.
-- Set by set_slot_data() when it fires mid-gameplay; cleared by main.lua's reconnect-settle
-- watcher, which then fires ONE flush_apply with the fully rebuilt state.
M._reconnect_settle_active = false

-- Skill grants requested while not in gameplay; replayed on the gameplay-active transition.
M._pending_skill_grants = {}

-- Successful UpgradePlayer bumps per skill. Seeded from save's PlayerExtraData.SkillData
-- at apply-safe so already-applied levels don't re-trigger on reconnect.
M._applied_skill_counts = {}

-- Mutating book actors right after LoadMap crashes (sub-levels still streaming / actors
-- un-init), even with _gameplay_active. Set true only after a post-LoadMap delay + probe.
M._apply_safe = false

-- Bookcase index (section_id → array of unique case actors), built at apply-time.
-- Reset on leaving gameplay (cases torn down on level reload).
M._section_to_cases = {}
M._cases_indexed    = false

-- Reverse lookup: case actor key → section_id.
M._case_to_section  = {}

-- Last-logged bookcase summary; only re-log on change (the 5s re-apply spammed it).
M._last_apply_log_key = nil

-- Already-sent row location IDs this session (de-dupe defense).
M._sent_row_locations = {}

-- Already-fired row-completion thresholds this session (de-dupe), keyed by threshold value.
M._sent_row_completions = {}

-- Already-fired section completions this session (de-dupe, keyed by section_id).
-- Fires when every row location in the section is in _sent_row_locations.
M._sent_section_completions = {}

-- section_id → list of its row location IDs. Built once from slot_data.row_location_map.
M._section_to_row_locs = {}

-- Already-fired floor completions this session (de-dupe, keyed by floor int 1/2).
-- Fires when every row location across the floor's active sections is sent.
M._sent_floor_completions = {}

-- floor number → flat list of row location IDs in its active sections. Built from
-- _section_to_row_locs. Floor-goal seeds only have the active floor's entry.
M._floor_to_row_locs = {}

-- Highest level we've sent a "Reached Level N" check for. Synced to max of the XP curve
-- vs CurrentFinishedRowNum and APClient._sent_checks (max guards stale GameSaveData).
-- Subsequent level-ups arrive via on_level_up_event(), which catches up from _sent_checks
-- first (CurrentFinishedRowNum hasn't updated yet when OnLevelUp fires).
M._levels_reached = 0
M._level_baseline_done = false

-- Milestone thresholds already checked ({ [threshold] = true }).
M._milestones_sent = {}



-- BookCase actors not referenced by any CabinetLabel's CountBookCase — level-design
-- artifacts (cases tucked in walls). The placement system can still find them by aim
-- angle and accept an unreachable book = softlock, so they're kept permanently
-- hidden + collision-off by _apply_bookcases_to_world.
M._stray_cases = {}

-- One-shot: baseline sync runs only on first player movement after entering gameplay.
-- The title screen has the previous save loaded, so a GameSaveData read at apply-safe
-- can be stale; movement is a reliable "new save is live" signal.
M._baseline_sync_done = false

-- ============================================================================
-- Init
-- ============================================================================

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Load asset_idx_to_series.json from disk and populate the static lookups.
function M.load_asset_data(path)
    path = path or "Mods/Librarian-AP/Scripts/AP/asset_idx_to_series.json"
    local raw = read_file(path)
    if not raw then
        log("ERROR: asset data not found at " .. tostring(path))
        return false
    end
    local APConfig = require("AP/APConfig")
    if not APConfig.decode then
        log("ERROR: APConfig.decode not exposed; update APConfig.lua")
        return false
    end
    local ok, parsed = pcall(APConfig.decode, raw)
    if not ok or type(parsed) ~= "table" then
        log("ERROR: failed to parse asset data: " .. tostring(parsed))
        return false
    end

    local count = 0
    for idx_str, info in pairs(parsed) do
        local idx = tonumber(idx_str)
        if idx and type(info) == "table" then
            M._asset_to_series[idx] = info.name
            M._asset_to_section[idx] = info.section
            M._asset_to_volumes[idx] = tonumber(info.volumes) or 0
            count = count + 1
        end
    end
    log(("Loaded %d asset entries"):format(count))
    return true
end

--- Called by main.lua on slot-connect. Stores seed orderings and resets per-connection
--- state. AP re-sends all items on (re)connect, so reset _received_counts to avoid double-counts.
function M.set_slot_data(slot_data)
    M._slot_data = slot_data
    -- BookVisibility option. true = HIDE warded books (default); false = "stacks" = visible
    -- but non-grabbable. The three hide paths gate on this so stacks keeps only collision-off.
    -- "~= stacks" defaults any missing/unknown value to the safe hide.
    M._book_hide_mode = (slot_data and slot_data.book_visibility ~= "stacks")
    log(("[book-vis] mode=%s (slot_data.book_visibility=%s)"):format(
        M._book_hide_mode and "HIDDEN" or "stacks",
        tostring(slot_data and slot_data.book_visibility)))
    M._received_counts    = {}
    M._series_unlocked    = {}
    M._shelves_open       = {}
    M._unwarded_snapshot  = {}
    M._pending_level_ups  = 0
    M._pending_skill_grants = {}
    M._applied_skill_counts = {}
    M._sent_row_locations = {}
    M._sent_row_completions = {}
    M._sent_section_completions = {}
    M._section_to_row_locs = {}
    M._sent_floor_completions = {}
    M._floor_to_row_locs = {}
    M._last_applied_series_unlocked = {}
    M._levels_reached = 0
    M._level_baseline_done = false
    M._milestones_sent = {}
    M._baseline_sync_done = false
    M._books_placed_observed = 0
    M._books_placed_peak = 0
    M._initialized = next(M._asset_to_series) ~= nil
    if not M._initialized then
        log("WARNING: slot data set but asset data not loaded; init incomplete")
        return
    end

    log("slot_data version=" .. tostring(slot_data.version or "?"))

    -- Derived lookups (per-seed, built once) so the per-book warding decision is cheap:
    --   _series_to_section[name]     = section_id
    --   _series_to_asset_idx[name]   = numeric AssetIdx
    --   _section_bookcase_count[sid] = case count for that section
    M._series_to_section = {}
    M._series_to_asset_idx = {}
    for aidx, sname in pairs(M._asset_to_series) do
        M._series_to_section[sname] = M._asset_to_section[aidx]
        M._series_to_asset_idx[sname] = aidx
    end
    M._section_bookcase_count = {}
    if type(slot_data.bookcase_counts) == "table" then
        for sid, n in pairs(slot_data.bookcase_counts) do
            M._section_bookcase_count[sid] = tonumber(n) or 0
        end
    end

    -- Build section_id → list of row location IDs from row_location_map keys
    -- (for fire_section_completions). Skipped for seeds without row_location_map.
    M._section_to_row_locs = {}
    if type(slot_data.row_location_map) == "table" then
        for key, loc_id in pairs(slot_data.row_location_map) do
            local sid = type(key) == "string" and key:match("^([^|]+)|") or nil
            local lid = tonumber(loc_id)
            if sid and lid then
                local list = M._section_to_row_locs[sid]
                if not list then
                    list = {}
                    M._section_to_row_locs[sid] = list
                end
                list[#list + 1] = lid
            end
        end
    end

    -- Build floor_number → flat list of row location IDs by re-bucketing
    -- _section_to_row_locs. Section IDs are "<floor><letter>" so sid[1] is the floor.
    -- Floor-goal seeds only have the active floor's sections, so the other drops out.
    M._floor_to_row_locs = {}
    for sid, row_locs in pairs(M._section_to_row_locs) do
        local floor_n = tonumber(sid:sub(1, 1))
        if floor_n then
            local list = M._floor_to_row_locs[floor_n]
            if not list then
                list = {}
                M._floor_to_row_locs[floor_n] = list
            end
            for _, lid in ipairs(row_locs) do
                list[#list + 1] = lid
            end
        end
    end
    -- Allow pre-apply: main.lua's OpenLevel-on-connect triggers a fresh M01 LoadMap →
    -- apply-gate retry loop. Continue stays disabled until _pre_apply_complete.
    M._allow_pre_apply = true
    M._pre_apply_complete = false

    -- Mid-gameplay reconnect: AP is about to re-send every received item. Without this
    -- flag each apply_item would flush_apply on partial state and flicker cases to hidden.
    -- main.lua's reconnect-settle watcher fires ONE flush_apply once items quiet, then clears.
    if M._gameplay_active then
        M._reconnect_settle_active = true
        log("Slot data set; per-connection state reset; reconnect-settle window opened (mid-gameplay)")
    else
        M._reconnect_settle_active = false
        log("Slot data set; per-connection state reset; pre-apply enabled")
    end

    -- Goal-scope verification: log series_order's section/floor coverage. The apworld
    -- filters series_order to active sections, and _recompute_state only unlocks series
    -- in series_order, so this log is authoritative for "no off-floor series unlockable".
    do
        local goal = slot_data.goal
        local goal_name = ({ [0]="full", [1]="custom", [2]="floor_1", [3]="floor_2" })[goal] or ("?"..tostring(goal))
        local series_order = slot_data.series_order or {}
        local sections_seen = {}
        local floors_seen = {}
        for _, sname in ipairs(series_order) do
            local found_sid = nil
            for aidx, asname in pairs(M._asset_to_series) do
                if asname == sname then
                    found_sid = M._asset_to_section[aidx]
                    break
                end
            end
            if found_sid then
                sections_seen[found_sid] = (sections_seen[found_sid] or 0) + 1
                local floor = found_sid:sub(1, 1)
                floors_seen[floor] = (floors_seen[floor] or 0) + 1
            end
        end
        local section_list = {}
        for sid in pairs(sections_seen) do section_list[#section_list+1] = sid end
        table.sort(section_list)
        local floor_list = {}
        for f in pairs(floors_seen) do
            floor_list[#floor_list+1] = ("floor%s=%d"):format(f, floors_seen[f])
        end
        table.sort(floor_list)
        log(("[goal-scope] goal=%s, series_order has %d series across %d sections (%s)"):format(
            goal_name, #series_order, #section_list, table.concat(floor_list, ", ")))
        log(("[goal-scope]   sections: %s"):format(table.concat(section_list, ", ")))
        if goal == 2 and floors_seen["2"] then
            log(("[goal-scope] WARNING: goal=floor_1 but %d floor-2 series in series_order — Python filter broke!"):format(floors_seen["2"]))
        elseif goal == 3 and floors_seen["1"] then
            log(("[goal-scope] WARNING: goal=floor_2 but %d floor-1 series in series_order — Python filter broke!"):format(floors_seen["1"]))
        end
    end
end

--- Called by main.lua on disconnect. Clears pre-apply state so reconnect starts fresh.
function M.clear_pre_apply()
    M._allow_pre_apply = false
    M._pre_apply_complete = false
end

--- Called by main.lua's LoadMap hook. Toggles whether we're in gameplay. World apply does
--- NOT happen here — the LoadMap retry loop drives set_apply_safe + flush_apply later.
function M.set_gameplay_active(state)
    state = state and true or false
    if M._gameplay_active == state then return end
    M._gameplay_active = state
    log(("Gameplay-active: %s"):format(tostring(state)))

    if not state then
        -- Leaving gameplay: book + case actors are about to be torn down. Force the next
        -- entry to re-prove safety and re-index — actor pointers don't survive the reload.
        if M._apply_safe then
            log("Resetting _apply_safe (left gameplay)")
            M._apply_safe = false
        end
        M._baseline_sync_done = false
        if M._cases_indexed then
            log("Clearing bookcase index (left gameplay)")
            M._section_to_cases = {}
            M._case_to_section = {}
            M._stray_cases = {}
            M._last_apply_log_key = nil
            M._cases_indexed = false
            -- WardCover actors die with the old world; drop refs so the next apply re-spawns.
            M._case_covers = {}
        end
        -- Warding + sign-glow trackers are keyed to the old world's actors. Drop them so the
        -- next entry (Continue, which may not fully reload) re-wards/re-glows from scratch
        -- instead of apply-on-change skipping as "unchanged".
        M._case_ward_state = {}
        M._case_placement_mesh = {}   -- stale (old world's components)
        M._section_to_label = nil
        M._section_glow_state = {}
        M._section_glow_orig = {}
        -- Pending skill grants get re-queued on the next slot_connect's item re-dump.
        if #M._pending_skill_grants > 0 then
            log(("Clearing %d pending skill grants (left gameplay)"):format(#M._pending_skill_grants))
            M._pending_skill_grants = {}
        end
    end
    -- Entering gameplay: glow locked signs now instead of waiting for the periodic loop
    -- (no-op if not yet apply-safe; the loop is the backstop).
    M._maybe_glow_now()
end

--- Called by main.lua's LoadMap retry loop once book sub-levels have streamed in and
--- ItemInfo is populated. Until true, flush_apply recomputes state but touches no actors.
--- Also drains queued skill grants (UpgradePlayer no-ops before the world is fully wired).
function M.set_apply_safe(state)
    state = state and true or false
    if M._apply_safe == state then return end
    M._apply_safe = state
    log(("Apply-safe: %s"):format(tostring(state)))
    if state then
        -- Save is stable here — seed the applied counter from its skill levels BEFORE
        -- draining queued grants, so prior-session skills aren't re-bumped by the re-dump.
        M._init_applied_skill_counts_from_save()
        if #M._pending_skill_grants > 0 then
            local q = M._pending_skill_grants
            M._pending_skill_grants = {}
            log(("Apply-safe: replaying %d queued skill grants"):format(#q))
            for _, name in ipairs(q) do
                M._apply_skill(name)
            end
        end
    end
end

-- ============================================================================
-- Public: apply a single received AP item
-- ============================================================================

function M.apply_item(name)
    if not name then return end
    M._received_counts[name] = (M._received_counts[name] or 0) + 1
    M._last_item_apply_tick = M._last_item_apply_tick + 1

    -- Skill items: grant immediately (no slot_data / asset_data dependency).
    if SKILL_ITEM_TO_ABILITY[name] then
        M._apply_skill(name)
    end

    -- Section / Series / Shelf items: affect derived state. Require slot_data.
    if not M._initialized then
        log(("queued (not initialized): %s × %d"):format(name, M._received_counts[name]))
        return
    end
    -- Defer the world-apply during the two settle windows (pre-apply title burst,
    -- mid-gameplay reconnect re-dump): per-item flush is wasteful + flickers, so main.lua's
    -- settle watchers fire ONE flush with the FINAL state. recompute still runs to track counts.
    if (M._allow_pre_apply and not M._gameplay_active)
            or M._reconnect_settle_active then
        M._recompute_state()
        return
    end
    M.flush_apply()
end

--- Recompute derived state and apply to world. Idempotent. World mutations gate on
--- _gameplay_active (not title) AND _apply_safe (sub-levels streamed). State recompute
--- always runs so in-memory state is correct when apply does fire.
function M.flush_apply()
    if not M._initialized then return end
    M._recompute_state()
    if not (M._gameplay_active or M._allow_pre_apply) then
        log("(state recomputed; world apply skipped — not in gameplay and not connected)")
        return
    end
    if not M._apply_safe then
        log("(state recomputed; world apply skipped — not yet apply-safe)")
        return
    end
    if M._allow_pre_apply and not M._gameplay_active then
        log("(pre-apply: warding behind title menu)")
    end
    local first_index = not M._cases_indexed
    if first_index then
        M._index_bookcases()
    end
    -- Bookcases first (fast, immediate visual feedback); books drain in the background.
    M._apply_bookcases_to_world()
    M._apply_books_to_world()
    -- Baseline syncs run from run_baseline_sync (first-movement), not here: GameSaveData
    -- can be stale at apply-safe time since the title menu loads the prior save behind it.
end

-- Called by main.lua's movement-detection loop on first post-load movement, by which
-- point GameSaveData reflects the actually-loaded save, so the baseline read is safe.
function M.run_baseline_sync()
    if M._baseline_sync_done then return end
    M._baseline_sync_done = true

    local row_synced = 0
    pcall(function() row_synced = M.detect_completed_rows() end)
    if row_synced and row_synced > 0 then
        log(("Row baseline sync: sent %d check(s) for already-completed rows"):format(row_synced))
    end

    -- Hydrate _sent_row_locations from the server's checked locations so
    -- fire_section_completions can see prior-session-completed sections. Without this,
    -- detect_completed_rows skips already-checked rows (correct) but never marks them
    -- in _sent_row_locations this session, so the Section Complete check never fires.
    local prior_row_synced = 0
    pcall(function() prior_row_synced = M._sync_sent_row_locations_from_server() end)
    if prior_row_synced and prior_row_synced > 0 then
        log(("Row-location server sync: mirrored %d prior-session check(s) into _sent_row_locations"):format(
            prior_row_synced))
    end

    local sec_synced = 0
    pcall(function() sec_synced = M.fire_section_completions() end)
    if sec_synced and sec_synced > 0 then
        log(("Section-completion baseline sync: sent %d check(s) for already-complete sections"):format(
            sec_synced))
    end

    local floor_synced = 0
    pcall(function() floor_synced = M.fire_floor_completions() end)
    if floor_synced and floor_synced > 0 then
        log(("Floor-completion baseline sync: sent %d check(s) for already-complete floors"):format(
            floor_synced))
    end

    -- Fire any "Complete N Rows" thresholds the save already passed. Without this a
    -- mid-run save skips them (FinishRow only fires for NEW completions).
    local rows_finished = 0
    pcall(function()
        local gi = FindFirstOf("BP_LibrarianGameInstance_C")
            or FindFirstOf("LibrarianGameInstanceBase")
        if gi and gi:IsValid() then
            local sg = gi.GameSaveData
            if sg and sg:IsValid() then
                rows_finished = tonumber(sg.GameProgressData.CurrentFinishedRowNum) or 0
            end
        end
    end)
    local rc_synced = 0
    pcall(function() rc_synced = M.fire_row_completion_checks(rows_finished) end)
    if rc_synced and rc_synced > 0 then
        log(("Row-completion baseline sync: sent %d check(s) for thresholds <= %d rows"):format(
            rc_synced, rows_finished))
    end

    -- Level-up baseline. current_level = max(xp_level, sent_level):
    --   xp_level   — walk player.SkillLevelUpRowNum vs rows_finished (needs BP loaded).
    --   sent_level — highest level loc in APClient._sent_checks (works without GameSaveData).
    -- The _sent_checks floor stops _levels_reached resetting to 0 on reconnect (else every
    -- OnLevelUp re-queues an already-deduped level and the real one never sends).
    local xp_level = 0
    do
        local player = FindFirstOf("BP_LibrarianCharacter_C")
        if player and player:IsValid() then
            pcall(function()
                local arr = player.SkillLevelUpRowNum
                local n = 0; pcall(function() n = #arr end)
                for i = 1, math.min(n, AP_MAX_PLAYER_LEVEL) do
                    local needed = tonumber(arr[i]) or 0
                    if rows_finished >= needed then
                        xp_level = i
                    else
                        return  -- XP curve is monotonic; short-circuit
                    end
                end
            end)
        end
    end
    -- Static-curve fallback: if the BP read returned 0 (player BP not resolved / array
    -- read errored), recompute from XP_CURVE so offline-earned levels still get credited.
    if xp_level == 0 and rows_finished > 0 then
        local static_level = 0
        for i = 1, #XP_CURVE do
            if rows_finished >= XP_CURVE[i] then
                static_level = i
            else
                break
            end
        end
        if static_level > 0 then
            log(("Level-up baseline: BP read returned 0; static XP_CURVE fallback → Level %d at %d rows"):format(
                static_level, rows_finished))
            xp_level = static_level
        end
    end
    local sent_level = M._compute_sent_level_baseline()
    local current_level = math.max(xp_level, sent_level)
    log(("Level-up baseline sync: rows_finished=%d, xp_level=%d, sent_level=%d → current_level=%d"):format(
        rows_finished, xp_level, sent_level, current_level))
    if current_level > 0 then
        local APClient = package.loaded["AP/APClient"]
        if APClient and APClient.send_check then
            for level = 1, current_level do
                APClient:send_check(AP_LOC_LEVEL_FIRST + (level - 1))
            end
        end
    end
    M._levels_reached = current_level

    local lvl_sent, ms_sent = 0, 0
    pcall(function() lvl_sent, ms_sent = M.sync_progress_state() end)
    if (lvl_sent or 0) + (ms_sent or 0) > 0 then
        log(("Progress baseline sync: %d level-up(s), %d milestone(s)"):format(
            lvl_sent or 0, ms_sent or 0))
    end
end

-- ============================================================================
-- State derivation
-- ============================================================================

function M._recompute_state()
    if not M._slot_data then return end

    -- THREADING: the game-thread book hooks read M._series_unlocked / M._shelves_open / the unwarded
    -- snapshot concurrently with this mod-thread rebuild. Build into LOCALS and swap each M.* reference
    -- in ONE assignment -- never mutate a published table in place. A reader then observes the whole
    -- old table or the whole new one, never a half-built one mid-pairs() (which corrupts the Lua heap
    -- across threads -> the rc3 'next'/'compare' errors + UE4SS abort). See _unwarded_snapshot.

    -- Series: series_order[1..N*per_unlock]
    local series_unlocked = {}
    local series_count = M._received_counts["Progressive Series Unlock"] or 0
    local per_unlock = M._slot_data.series_per_unlock or 5
    local series_order = M._slot_data.series_order or {}
    local total_series = math.min(series_count * per_unlock, #series_order)
    for i = 1, total_series do
        series_unlocked[series_order[i]] = true
    end

    -- Shelf unlocks: per-section open_count = received count of that section's item.
    local shelves_open = {}
    for item_name, count in pairs(M._received_counts) do
        local section_id = item_name:match("^Progressive Shelf Unlock %((.+)%)$")
        if section_id then
            shelves_open[section_id] = count
        end
    end

    -- Publish atomically (single reference assignment each), tables first so the snapshot below is
    -- computed from the fresh state.
    M._series_unlocked = series_unlocked
    M._shelves_open    = shelves_open
    -- Precompute the read-only unwarded snapshot the game-thread hooks lookup against (no per-call
    -- alloc/iterate on the game thread). only_unward_shelfable_books is constant per session, so one
    -- snapshot in the active gating mode serves every hook. _compute_unwarded_set allocates here on
    -- the MOD thread (safe) and reads the just-published tables.
    M._unwarded_snapshot = M._compute_unwarded_set(
        M._slot_data.only_unward_shelfable_books == 1)
end

-- ============================================================================
-- Apply: Books
-- ============================================================================

--- BP_GrabbingBook_C's AssetIdx if initialized, else nil (orphan with default ItemInfo).
--- AssetIdx=0 is VALID (section 1A's first series), so we can't gate on >0; instead
--- disambiguate via ItemInfo.Mesh (real books have a mesh, OpenLevel-reload orphans leave nil).
local function _book_valid_asset_idx(book)
    if not book or not book:IsValid() then return nil end
    local info; pcall(function() info = book.ItemInfo end)
    -- IsValid the ItemInfo sub-UObject too: book:IsValid() alone isn't enough — a stale
    -- ItemInfo ref makes the next .AssetIdx read AV in IsA (a native crash pcall can't catch).
    if not info or not info:IsValid() then return nil end
    local aidx; pcall(function() aidx = info.AssetIdx end)
    if aidx == nil then return nil end
    if aidx > 0 then return aidx end
    if aidx == 0 then
        local mesh_valid = false
        pcall(function()
            local m = info.Mesh
            if m and m:IsValid() then mesh_valid = true end
        end)
        if mesh_valid then return 0 end
    end
    return nil
end
M._book_valid_asset_idx = _book_valid_asset_idx  -- expose for diagnostics

--- Recursively set visibility on a SceneComponent tree. bHiddenInGame alone doesn't
--- always refresh the render proxy in UE 5.5; MarkRenderStateDirty forces invalidation.
local function _walk_set_visibility(comp, visible)
    if not comp or not comp:IsValid() then return end
    pcall(function() comp:SetVisibility(visible, false) end)
    pcall(function() comp:SetHiddenInGame(not visible, false) end)
    if _diag_on("RENDER_STATE_DIRTY") then
        pcall(function() comp:MarkRenderStateDirty() end)
    end
    local children
    pcall(function() children = comp.AttachChildren end)
    if children then
        local n = 0
        pcall(function() n = #children end)
        for i = 1, n do
            local child = children[i]
            if child and child:IsValid() then
                _walk_set_visibility(child, visible)
            end
        end
    end
end

-- Ward a bookcase via its OWN StaticMesh collision (no runtime spawn = no world-leak crash).
-- LOCKED: each solid StaticMeshComponent → BLOCK object channels (Pawn=player,
-- PhysicsBody/WorldDynamic=thrown books), IGNORE trace channels (Visibility/Camera/Game) so
-- the placement line-trace misses → solid AND un-interactable. UNLOCKED: restore the captured
-- profile. Treats ALL meshes, not just one — large cases have multiple placement meshes and a
-- single-mesh approach left them placeable at angles hitting an unhandled mesh.
-- Risk: if placement ever traces an object channel instead of a trace channel, cases stay
-- placeable. See WARDING_SYNC_PLAN.md for the full refinement history.
local function _ward_collision(case, case_key, locked)
    if not (case and case:IsValid()) then return end
    -- Actor-level collision MUST be on or per-component settings are ignored.
    pcall(function() case:SetActorEnableCollision(true) end)

    local meshes = {}
    local seen, inventory = {}, {}
    local function consider(c)
        if not (c and c:IsValid()) then return end
        local fk; pcall(function() fk = c:GetFullName() end)
        if fk then if seen[fk] then return end seen[fk] = true end
        local nm, cls = "?", "?"
        pcall(function() nm = c:GetFName():ToString() end)
        pcall(function() cls = c:GetClass():GetFName():ToString() end)
        inventory[#inventory + 1] = nm .. ":" .. cls
        -- PreviewBookLocation is a non-blocking marker, not the placement target — skip it.
        if cls == "StaticMeshComponent" and nm ~= "PreviewBookLocation" then
            meshes[#meshes + 1] = c
        end
    end
    local root; pcall(function() root = case:K2_GetRootComponent() end)
    local function walk(c, depth)
        if not (c and c:IsValid()) or depth > 8 then return end
        consider(c)
        local kids; pcall(function() kids = c.AttachChildren end)
        if kids then
            local n = 0; pcall(function() n = #kids end)
            for i = 1, n do walk(kids[i], depth + 1) end
        end
    end
    if root then walk(root, 0) end
    local comps; pcall(function() comps = case.BlueprintCreatedComponents end)
    if comps then
        local n = 0; pcall(function() n = #comps end)
        for i = 1, n do consider(comps[i]) end
    end

    -- Capture each mesh's original collision once (enabled + profile) for restore.
    M._case_orig_collision = M._case_orig_collision or {}
    if case_key and M._case_orig_collision[case_key] == nil then
        local rec = {}
        for i = 1, #meshes do
            local en, pf = 3, "?"
            pcall(function() en = meshes[i]:GetCollisionEnabled() end)
            pcall(function() pf = meshes[i]:GetCollisionProfileName():ToString() end)
            -- Capture per-channel responses so UNLOCK restores the EXACT original, not a
            -- block-all (block-all makes a cabinet body/wall block the placement trace that
            -- originally passed THROUGH to the inner shelf → stays un-placeable when unwarded).
            local resp = {}
            for ch = 0, 31 do
                local v = 0
                pcall(function() v = meshes[i]:GetCollisionResponseToChannel(ch) end)
                resp[ch] = tonumber(v) or 0
            end
            rec[i] = { en = tonumber(en) or 3, pf = pf, resp = resp }
        end
        M._case_orig_collision[case_key] = rec
    end
    local rec = (case_key and M._case_orig_collision[case_key]) or {}

    -- Log the structure once per distinct static-mesh count (so large cases, if
    -- they have extra meshes, are visible).
    M._ward_logged_counts = M._ward_logged_counts or {}
    if not M._ward_logged_counts[#meshes] then
        M._ward_logged_counts[#meshes] = true
        log(("[ward-collision] %d static meshes: %s"):format(#meshes, table.concat(inventory, ", ")))
    end

    -- Object channels (player + thrown books) that must keep blocking:
    -- 0 WorldStatic, 1 WorldDynamic, 2 Pawn, 5 PhysicsBody, 6 Vehicle, 7 Destructible.
    local OBJ_CHANNELS = { 0, 1, 2, 5, 6, 7 }
    local OBJ_SET = { [0] = true, [1] = true, [2] = true, [5] = true, [6] = true, [7] = true }

    -- Identify the PLACEMENT mesh (shelf surface the placement line-trace must hit): the
    -- component named "StaticMesh", or the sole mesh of a single-mesh case (whose name may
    -- differ). Driven to a DETERMINISTIC state in BOTH directions OUTSIDE the captured-
    -- collision gate so a bad/partial capture can never strand it un-placeable.
    local placement_idx = nil
    for i = 1, #meshes do
        local nm = "?"; pcall(function() nm = meshes[i]:GetFName():ToString() end)
        if nm == "StaticMesh" then placement_idx = i; break end
    end
    if not placement_idx and #meshes == 1 then placement_idx = 1 end

    -- Stash the placement mesh so the periodic ward pass reads its ACTUAL collision as
    -- ground truth (Camera channel 4: Ignore=warded, Block=unwarded) instead of re-mutating.
    if case_key and placement_idx then
        M._case_placement_mesh = M._case_placement_mesh or {}
        M._case_placement_mesh[case_key] = meshes[placement_idx]
    end

    -- One-shot per case CLASS: log the unlock placement decision so a future stuck-shelf
    -- report names which mesh was used (and flags the un-disambiguatable multi-mesh/no-StaticMesh case).
    if not locked and case then
        local cls = "?"; pcall(function() cls = case:GetClass():GetFName():ToString() end)
        M._ward_unlock_logged = M._ward_unlock_logged or {}
        if not M._ward_unlock_logged[cls] then
            M._ward_unlock_logged[cls] = true
            if placement_idx then
                local pnm = "?"; pcall(function() pnm = meshes[placement_idx]:GetFName():ToString() end)
                local pen = rec[placement_idx] and rec[placement_idx].en
                log(("[ward-unlock] %s: %d mesh(es), placement='%s' (%s), captured en=%s -> force block-all"):format(
                    cls, #meshes, pnm, (pnm == "StaticMesh") and "by-name" or "sole-mesh", tostring(pen)))
            else
                log(("[ward-unlock] WARNING %s: %d meshes, no 'StaticMesh' + not single-mesh -> per-channel restore MAY stick; send this log"):format(
                    cls, #meshes))
            end
        end
    end

    for i = 1, #meshes do
        local r = rec[i] or { en = 3, pf = "?" }
        local is_placement = (i == placement_idx)
        -- Safe enabled value for the placement mesh: captured if real, else QueryAndPhysics
        -- (a captured NoCollision must not disable the shelf).
        local pen = (r.en and r.en ~= 0) and r.en or 3
        if locked then
            if is_placement then
                -- Ward the placement mesh deterministically (bypass the captured-en gate) so
                -- the ground-truth read + unlock stay reliable: ignore all, re-block objects.
                pcall(function() meshes[i]:SetCollisionEnabled(pen) end)
                pcall(function() meshes[i]:SetCollisionResponseToAllChannels(0) end)
                for _, ch in ipairs(OBJ_CHANNELS) do
                    pcall(function() meshes[i]:SetCollisionResponseToChannel(ch, 2) end)
                end
                M._ward_canary = meshes[i]
            elseif (r.en or 3) ~= 0 then
                -- Other meshes: same ward (ignore all so the placement trace misses, re-block
                -- object channels so player + books bounce).
                pcall(function() meshes[i]:SetCollisionEnabled(3) end)
                pcall(function() meshes[i]:SetCollisionResponseToAllChannels(0) end)
                for _, ch in ipairs(OBJ_CHANNELS) do
                    pcall(function() meshes[i]:SetCollisionResponseToChannel(ch, 2) end)
                end
                M._ward_canary = meshes[i]
            end
        else
            if is_placement then
                -- UNLOCK the placement mesh UNCONDITIONALLY (solid + block-all) so the trace
                -- always hits it regardless of capture quality.
                pcall(function() meshes[i]:SetCollisionEnabled(pen) end)
                pcall(function() meshes[i]:SetCollisionResponseToAllChannels(2) end)
            elseif (r.en or 3) ~= 0 then
                -- Structural meshes (cabinet body/wall): restore the capture so the placement
                -- trace passes THROUGH to the inner shelf (block-all-ing them was the cabinet bug).
                pcall(function() meshes[i]:SetCollisionEnabled(r.en or 3) end)
                if r.resp then
                    for ch = 0, 31 do
                        local orig = r.resp[ch] or 0
                        local warded_val = OBJ_SET[ch] and 2 or 0
                        if orig ~= warded_val then
                            pcall(function() meshes[i]:SetCollisionResponseToChannel(ch, orig) end)
                        end
                    end
                end
            end
        end
    end

end

--- Decompose UE FMatrix44f planes into a Lua FTransform table. UE FMatrix is row-major:
--- rows 0-2 are scaled basis vectors, row 3 is translation. Scale = basis magnitudes;
--- rotation via Shoemake matrix→quaternion.
local function _decompose_matrix(xp, yp, zp, wp)
    local sx = math.sqrt(xp.X*xp.X + xp.Y*xp.Y + xp.Z*xp.Z)
    local sy = math.sqrt(yp.X*yp.X + yp.Y*yp.Y + yp.Z*yp.Z)
    local sz = math.sqrt(zp.X*zp.X + zp.Y*zp.Y + zp.Z*zp.Z)
    if sx <= 1e-6 or sy <= 1e-6 or sz <= 1e-6 then return nil end

    -- Normalized rotation matrix (UE row-major: row i = basis vector i)
    local m00, m01, m02 = xp.X/sx, xp.Y/sx, xp.Z/sx
    local m10, m11, m12 = yp.X/sy, yp.Y/sy, yp.Z/sy
    local m20, m21, m22 = zp.X/sz, zp.Y/sz, zp.Z/sz

    -- Shoemake quaternion-from-matrix; sign conventions chosen to invert UE's FQuat→FMatrix.
    local trace = m00 + m11 + m22
    local qx, qy, qz, qw
    if trace > 0 then
        local s = math.sqrt(trace + 1.0) * 2
        qw = 0.25 * s
        qx = (m12 - m21) / s
        qy = (m20 - m02) / s
        qz = (m01 - m10) / s
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1.0 + m00 - m11 - m22) * 2
        qw = (m12 - m21) / s
        qx = 0.25 * s
        qy = (m10 + m01) / s
        qz = (m20 + m02) / s
    elseif m11 > m22 then
        local s = math.sqrt(1.0 + m11 - m00 - m22) * 2
        qw = (m20 - m02) / s
        qx = (m10 + m01) / s
        qy = 0.25 * s
        qz = (m21 + m12) / s
    else
        local s = math.sqrt(1.0 + m22 - m00 - m11) * 2
        qw = (m01 - m10) / s
        qx = (m20 + m02) / s
        qy = (m21 + m12) / s
        qz = 0.25 * s
    end

    return {
        Rotation    = {X = qx, Y = qy, Z = qz, W = qw},
        Translation = {X = wp.X, Y = wp.Y, Z = wp.Z},
        Scale3D     = {X = sx, Y = sy, Z = sz},
    }
end

-- Pass 1 actor-warding tracker: key → true once a book has bHidden + collision-off applied.
-- Read by the warding/unward passes and the unlocked-state dump.
M._books_warded = {}

-- Drift probe: per case (keyed by GetFullName), the bHidden we last wrote. Compared before
-- the next write to log [bookcase-drift] if the game's BP tick reverted our flag.
M._case_last_applied_hidden = {}

-- Per-case WardCover actor (BP_WardCover chain-link overlay), keyed by GetFullName. The
-- cover is the durable visual ward — its tick is disabled at the class level so the game
-- can't revert it; the legacy SetActorHiddenInGame on the case is kept as a harmless backup.
-- If the pak lacks SpawnWardCover the pcall fails silently → legacy bHidden path alone.
M._case_covers = {}

-- Per-case captured original component collision (keyed by GetFullName). Cleared on reload.
M._case_orig_collision = {}

-- Apply-on-change tracker: last visible (lock) state applied per case (by GetFullName), so
-- warding only re-touches on change — perf + avoids racing world teardown on quit.
M._case_ward_state = {}

-- Per-case placement-mesh ref stashed by _ward_collision. The periodic ward pass reads its
-- Camera-channel collision as GROUND TRUTH so an already-correct case is a no-op (no render-
-- state churn = the crash suspect), still catching drift within one pass. Dropped only on reload.
M._case_placement_mesh = {}

-- One-shot diagnostic flags for v1.1.0 pak functions (first-success / first-failure logging).
M._diag_spawnwardcover_ok    = false
M._diag_spawnwardcover_err   = false
M._diag_pak_probed           = false
M._diag_no_modactor_logged   = false
M._diag_spawnwardcover_table_dumped = false
M._diag_geometry_dumped             = false

-- Books with no HISM canonical (AddInstance failed). Their mesh renders via the actor's own
-- component at its RootComponent position — which can be inside a wall if the level placed
-- the actor at a trigger, so they appear "stuck" when unwarded. Captured for diagnostics.
M._unmapped_warded_books = {}  -- key → { asset_idx, series, section, x, y, z }

-- Snapshot of _series_unlocked from the last apply, to diff + log newly-unlocked series.
M._last_applied_series_unlocked = {}

-- Chunked Pass-1 flush state. _apply_books_to_world walks ~3000 actors; doing it in one tick
-- blocks LoopAsync long enough that AP times out on big bursts, so it's chunked via LoopAsync.
-- _flush_in_progress held start→finalizer; _flush_pending makes the finalizer self-re-fire if
-- a flush was requested mid-run.
M._flush_in_progress = false
M._flush_pending     = false

--- Reset per-world state on every LoadMap into M01 — a fresh world means all captured
--- actor/HISM/glow refs are stale. Bumps the world-epoch so deferred game-thread closures
--- that captured the old world bail (see below).
function M.reset_hism_state()
    -- World epoch, bumped on every reset. Any DEFERRED game-thread closure that captured
    -- the OLD world's refs (notably layer 3's HISM array) re-checks this and bails instead
    -- of dereferencing freed memory — the LoadMap-teardown use-after-free (a native AV).
    M._world_epoch = (M._world_epoch or 0) + 1
    -- Ward pump: invalidate the old world. Bump the generation (so an in-flight stale
    -- closure self-noops its gen-guarded busy-clear), free the gate, reset the alive
    -- log, and release the L1 flush lock. The queue is deliberately NOT rebound here --
    -- that would race the async pump's pop; the old-epoch units still in it are dropped
    -- harmlessly by the pump's epoch check as it drains.
    M._pump_gen = (M._pump_gen or 0) + 1
    M._pump_busy = false
    M._pump_alive_logged = false
    M._flush_in_progress = false
    M._flush_pending = false
    M._books_warded = {}
    M._unmapped_warded_books = {}
    M._last_applied_series_unlocked = {}
    M._case_last_applied_hidden = {}
    -- WardCover actors are destroyed on reload; drop dangling refs (next apply re-spawns).
    M._case_covers = {}
    M._case_orig_collision = {}
    M._case_ward_state = {}
    M._case_placement_mesh = {}
    M._section_to_label = nil
    M._section_glow_state = {}
    M._section_glow_orig = {}
    -- Bookcase index points at the OLD world's actors. Keeping it pins the old world (no GC)
    -- and makes the next pass ward stale cases, leaving the new ones un-warded after
    -- Menu→Continue (which doesn't fire set_gameplay_active(false)). Clear + force re-index.
    M._section_to_cases = {}
    M._case_to_section = {}
    M._stray_cases = {}
    M._cases_indexed = false
    M._ward_canary = nil
    log("[hism-reset] cleared HISM mapping state (will re-init on next apply-safe)")
end

--- Set of series that are unwarded (pickable) now, given item state + the
--- only_unward_shelfable_books mode. Returns {[series] = true}; recomputed each apply.
---   Off (default): every RECEIVED series is pickable, no shelf gating. (Row completion
---     still needs the home case open — separate bookcase warding — so this never makes
---     a check unreachable.)
---   On (strict): a series stays warded until its home case is open (cases_open >= shelf_req).
function M._compute_unwarded_set(only_shelfable)
    local unwarded = {}
    if not only_shelfable then
        -- Off (default): every RECEIVED series is pickable, no shelf gating.
        for series_name in pairs(M._series_unlocked) do
            unwarded[series_name] = true
        end
        return unwarded
    end
    -- On (strict): gate each received series on its home bookcase being open
    -- (cases_open >= shelf_req for its section).
    local shelf_req_map = (M._slot_data and M._slot_data.shelf_req_map) or {}
    for series_name in pairs(M._series_unlocked) do
        local section_id = M._series_to_section[series_name]
        if section_id then
            local cases_open = M._shelves_open[section_id] or 0
            local needed = shelf_req_map[series_name] or 1
            if cases_open >= needed then unwarded[series_name] = true end
        end
    end
    return unwarded
end

-- Chunked-flush tuning: books per tick, and the yield between chunks so the LoopAsync poll
-- thread can pump c:poll(). 50ms < the 100-150ms AP heartbeat, keeping the socket alive.
local BOOK_APPLY_CHUNK_SIZE     = 300
local BOOK_APPLY_CHUNK_DELAY_MS = 50

--- Ward/unward every BP_GrabbingBook_C by whether its series is in the unwarded set.
--- Section is NOT part of the per-book gate (that's bookcase visibility). Chunked so the
--- LoopAsync poll thread keeps the AP socket alive during big bursts; finalizer runs last.
--- Re-entry: a flush requested mid-run sets _flush_pending and the finalizer self-re-fires;
--- concurrent flushes aren't supported.
function M._apply_books_to_world()
    -- Re-entry guard: if a flush is running, mark a follow-up; the finalizer picks it up.
    if M._flush_in_progress then
        M._flush_pending = true
        return
    end

    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then
        log("(FindAllOf returned nil; no books to apply)")
        return
    end
    local n = 0
    pcall(function() n = #books end)
    if n == 0 then
        log("(no books in level)")
        return
    end

    -- Unwarded set computed once per apply (per-book code just does a table lookup). The
    -- snapshot stays consistent across this flush's chunks; mid-flight changes are caught
    -- by the _flush_pending re-fire.
    local only_shelfable = M._slot_data
        and M._slot_data.only_unward_shelfable_books == 1
    local unwarded_set = M._compute_unwarded_set(only_shelfable)

    -- MOD-thread snapshots of the Lua state tables the game-thread finalizer (_finalize_apply_books,
    -- which runs INSIDE the L1 pump closure) diffs against. The finalizer must never iterate the live
    -- M._series_unlocked / M._shelves_open / M._last_applied_series_unlocked that the mod thread
    -- (_recompute_state / reset_hism_state) rewrites concurrently -> the rc3 cross-thread Lua-heap
    -- race. Captured here on the mod thread (serialized with _recompute_state).
    local series_snap = {}
    for s in pairs(M._series_unlocked) do series_snap[s] = true end
    local shelves_snap = {}
    for sid, c in pairs(M._shelves_open) do shelves_snap[sid] = c end
    local last_applied_snap = M._last_applied_series_unlocked or {}

    -- Are book actors INITIALIZED yet? On first M01 load ItemInfo.AssetIdx is default 0
    -- until the game's population logic runs, and warding un-init actors crashes. Require
    -- >=2 distinct non-zero AssetIdx in the first 20 books before treating it as safe.
    do
        local sample = {}
        local distinct = 0
        for i = 1, math.min(20, n) do
            local b = books[i]
            if b and b:IsValid() then
                -- Split ItemInfo access — UE4SS reflection AV (see detect_completed_rows).
                local item_info
                pcall(function() item_info = b.ItemInfo end)
                if item_info and item_info:IsValid() then
                    local idx
                    pcall(function() idx = item_info.AssetIdx end)
                    if idx and idx > 0 and not sample[idx] then
                        sample[idx] = true
                        distinct = distinct + 1
                        if distinct >= 2 then break end
                    end
                end
            end
        end
        if distinct < 2 then
            log(("(books spawned but ItemInfo not populated: %d distinct AssetIdx in sample of %d; deferring)"):format(
                distinct, math.min(20, n)))
            return
        end
    end

    -- Committed to a flush: take the lock and start the chunked Pass-1 driver.
    M._flush_in_progress = true
    -- Capture the world epoch at flush start. The chunk worker closes over `books`
    -- (the old-world actor array); if the world reloads mid-flush, a pending LoopAsync
    -- reschedule would re-stamp its pump unit with the NEW epoch and pass the pump's
    -- guard, then iterate freed actors -> native AV. The per-flush epoch closes that
    -- gap (mirrors layer 3 + reconcile, which the chunk worker otherwise lacks).
    local flush_epoch = M._world_epoch
    -- The ~3000-actor walk is too high-volume to mark per book; timestamp the whole flush
    -- so a crash trace shows a flush was in flight. BOOK_ACTOR_WARDING is the bisection lever.
    trace.mark("books-flush", nil, "n=" .. tostring(n))
    local stats = { warded = 0, unwarded = 0, skipped = 0, gate_skipped_unwards = 0 }
    local cursor = 1

    -- Cache ModActor once per flush (vs FindFirstOf per book). nil if the pre-v1.1.0 pak is
    -- installed or load failed → legacy SetActorHiddenInGame is the only ward.
    local mod_actor = FindFirstOf("ModActor_C")
    if not (mod_actor and mod_actor:IsValid()) then mod_actor = nil end

    -- Cache BP_HISM_Manager for UpdateWPO: WPO displaces book vertices via material param,
    -- hiding at deep Z without touching bHidden (which the game toggles view-dependently).
    local mgr_for_wpo = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr_for_wpo and mgr_for_wpo:IsValid()) then mgr_for_wpo = nil end

    -- Cache any valid BP_BookCase_C as a MoveToBookCase attachment target (it needs a
    -- non-null AttchedActor; any case works).
    local any_case
    do
        local cases = FindAllOf("BP_BookCase_C")
        if cases then
            local n = 0; pcall(function() n = #cases end)
            for i = 1, n do
                local c = cases[i]
                if c and c:IsValid() then
                    any_case = c
                    break
                end
            end
        end
    end

    -- One-shot ModActor function probe: logs which expected BP functions exist, to tell
    -- "pak loaded but functions missing" from "pak not loaded" from "spawn fails at call time".
    if mod_actor and not M._diag_pak_probed then
        M._diag_pak_probed = true
        local found = {
            SpawnWardCover          = false,
            SpawnWardCover_Cabinet  = false,
            SpawnWardCover_Small    = false,
            SpawnWardCover_Smallest = false,
            DespawnWardCover        = false,
        }
        for fname, _ in pairs(found) do
            local probe_ok = pcall(function()
                local fn = mod_actor[fname]
                if fn ~= nil then found[fname] = true end
            end)
            if not probe_ok then
                found[fname] = false
            end
        end
        log(("[ward-diag] ModActor function probe: SpawnWardCover=%s SpawnWardCover_Cabinet=%s SpawnWardCover_Small=%s SpawnWardCover_Smallest=%s DespawnWardCover=%s"):format(
            tostring(found.SpawnWardCover),
            tostring(found.SpawnWardCover_Cabinet),
            tostring(found.SpawnWardCover_Small),
            tostring(found.SpawnWardCover_Smallest),
            tostring(found.DespawnWardCover)))
    elseif not mod_actor and not M._diag_no_modactor_logged then
        M._diag_no_modactor_logged = true
        log("[ward-diag] No ModActor_C found in world — cover features disabled. Pak missing or not yet loaded?")
    end

    --- Ward/unward one book. Extracted to keep the chunk loop readable.
    local function _apply_one_book(book)
        if not (book and book:IsValid()) then
            stats.skipped = stats.skipped + 1
            return
        end
        -- Skip uninitialized orphans (default BookInfo; warding them corrupts HISM state).
        -- _book_valid_asset_idx returns nil for orphans but 0 for the real 1A series.
        local asset_idx = _book_valid_asset_idx(book)
        if asset_idx == nil then
            stats.skipped = stats.skipped + 1
            return
        end
        local series_name = M._asset_to_series[asset_idx]
        local should_unward = series_name and unwarded_set[series_name]
        local key = book:GetFullName()
        local is_warded = M._books_warded[key] or false
        local ok = pcall(function()
            if should_unward then
                -- Unconditional unward (SetActorHiddenInGame/Collision are idempotent). An
                -- `if is_warded` gate stranded the last 1-2 of a series: a book first seen at
                -- AssetIdx=0, or respawned by streaming with a new key, had no tracker entry.
                -- gate_skipped_unwards counts those (high first flush, ~0 = real drift catches).
                if not is_warded then
                    stats.gate_skipped_unwards = stats.gate_skipped_unwards + 1
                end
                if _diag_on("BOOK_ACTOR_WARDING") then
                    book:SetActorHiddenInGame(false)
                    book:SetActorEnableCollision(true)
                end
                M._books_warded[key] = nil
            else
                if not is_warded then
                    if _diag_on("BOOK_ACTOR_WARDING") then
                        -- stacks mode (_book_hide_mode false): keep VISIBLE, only collision-off.
                        if M._book_hide_mode then book:SetActorHiddenInGame(true) end
                        book:SetActorEnableCollision(false)
                    end
                    M._books_warded[key] = true
                end
            end
        end)
        if ok then
            if should_unward then stats.unwarded = stats.unwarded + 1
            else stats.warded = stats.warded + 1 end
        else
            stats.skipped = stats.skipped + 1
        end
    end

    -- Finalizer after the last chunk: diff log, state summary, in-progress/pending bookkeeping.
    local function _finalize_apply()
        M._finalize_apply_books(books, n, stats, series_snap, shelves_snap, last_applied_snap)
        M._flush_in_progress = false

        if M._flush_pending then
            M._flush_pending = false
            -- Bounce to the ASYNC thread, not inline: this finalizer can run inside a
            -- game-thread closure, and flush_apply → ExecuteInGameThread would then NEST
            -- those calls (UE4SS #1180: scheduling a tick-action mid-iteration of the list).
            LoopAsync(10, function() M.flush_apply() return true end)
        end
    end

    --- Chunked Pass 1 on the game thread. Each chunk's writes run via _on_game_thread, then
    --- reschedule through LoopAsync so the next ExecuteInGameThread is issued from the async
    --- thread, never nested in a game-thread callback (UE4SS #1180). pcall-guarded so a
    --- throwing chunk releases the flush lock instead of wedging every future flush.
    local _book_run_chunk
    local function _book_process_one_chunk()
        local chunk_end = math.min(cursor + BOOK_APPLY_CHUNK_SIZE - 1, n)
        for i = cursor, chunk_end do
            _apply_one_book(books[i])
        end
        cursor = chunk_end + 1
    end
    _book_run_chunk = function()
        _on_game_thread(function()
            -- World reloaded mid-flush: `books`/cursor point at the freed old world.
            -- Abort without touching them, and without rescheduling or running the
            -- finalizer (which would clobber a new flush's lock -- reset_hism_state owns
            -- it now). The orphaned driver self-terminates here.
            if (M._world_epoch or 0) ~= flush_epoch then return end
            local ok, err = pcall(_book_process_one_chunk)
            if not ok then
                M._flush_in_progress = false
                trace.mark("books-chunk-error", nil, tostring(err))
                log("[apply] book chunk error -> released flush lock: " .. tostring(err))
                return
            end
            if cursor <= n then
                LoopAsync(BOOK_APPLY_CHUNK_DELAY_MS, function() _book_run_chunk() return true end)
            else
                _finalize_apply()
            end
        end, "BOOK_ACTOR_GAMETHREAD")
    end

    _book_run_chunk()
end

--- Pass-1 finalizer: diff log, state summary.
function M._finalize_apply_books(books, n, stats, series_snap, shelves_snap, last_applied_snap)
    -- series_snap / shelves_snap / last_applied_snap are MOD-thread snapshots passed by
    -- _apply_books_to_world. This runs on the GAME thread (L1 pump closure), so it must NOT iterate
    -- the live M._series_unlocked / M._shelves_open / M._last_applied_series_unlocked (the mod thread
    -- rewrites them) -> use the immutable snapshots. Fallback to live for any direct call.
    series_snap = series_snap or M._series_unlocked
    shelves_snap = shelves_snap or M._shelves_open
    last_applied_snap = last_applied_snap or M._last_applied_series_unlocked
    -- Diff series vs the last snapshot for newly-unwarded series; logs per-series
    -- counts and flags any unmapped books (may appear stuck at an internal trigger location).
    local newly_unlocked = {}
    for s in pairs(series_snap) do
        if not last_applied_snap[s] then
            newly_unlocked[#newly_unlocked+1] = s
        end
    end
    if #newly_unlocked > 0 then
        local newly_set = {}
        local per_series_total, per_series_stuck, per_series_section = {}, {}, {}
        for _, s in ipairs(newly_unlocked) do
            newly_set[s] = true
            per_series_total[s] = 0
            per_series_stuck[s] = 0
        end
        for i = 1, n do
            local book = books[i]
            if book and book:IsValid() then
                local aidx = _book_valid_asset_idx(book)
                if aidx ~= nil then
                    local sname = M._asset_to_series[aidx]
                    if sname and newly_set[sname] then
                        per_series_total[sname] = per_series_total[sname] + 1
                        if not per_series_section[sname] then
                            per_series_section[sname] = M._asset_to_section[aidx] or "?"
                        end
                        local k = book:GetFullName()
                        if M._unmapped_warded_books[k] then
                            per_series_stuck[sname] = per_series_stuck[sname] + 1
                        end
                    end
                end
            end
        end
        table.sort(newly_unlocked, function(a, b)
            local sa, sb = per_series_section[a] or "?", per_series_section[b] or "?"
            if sa ~= sb then return sa < sb end
            return a < b
        end)
        local total_stuck = 0
        for _, s in ipairs(newly_unlocked) do total_stuck = total_stuck + (per_series_stuck[s] or 0) end
        log(("[series-unlock] %d series newly unwarded (%d book(s) may be stuck):"):format(
            #newly_unlocked, total_stuck))
        for _, sname in ipairs(newly_unlocked) do
            local total = per_series_total[sname] or 0
            local stuck = per_series_stuck[sname] or 0
            local section = per_series_section[sname] or "?"
            if stuck > 0 then
                log(("  [%s] '%s': %d book(s) unwarded, %d POTENTIALLY STUCK"):format(
                    section, sname, total, stuck))
            else
                log(("  [%s] '%s': %d book(s) unwarded (clean)"):format(
                    section, sname, total))
            end
        end
    end
    -- Update snapshot for next diff (build local, swap the reference atomically).
    local new_last_applied = {}
    for s in pairs(series_snap) do new_last_applied[s] = true end
    M._last_applied_series_unlocked = new_last_applied

    local section_n = 0
    for _, c in pairs(shelves_snap) do
        if c > 0 then section_n = section_n + 1 end
    end
    local series_n = 0
    for _ in pairs(series_snap) do series_n = series_n + 1 end
    log(("State: sections-active=%d series=%d | applied: unwarded=%d warded=%d skipped=%d gate-skipped-unwards=%d"):format(
        section_n, series_n, stats.unwarded, stats.warded, stats.skipped, stats.gate_skipped_unwards))
end

-- ============================================================================
-- Periodic actor-state reconciliation
-- ============================================================================
-- Continuous counterpart to Layer 3 for the ACTOR (not the HISM pile). Pass 1's actor ward
-- is event-driven and the SetActorVisible/grab hooks miss cases, so when an unwarded book's
-- actor lazy-streams in or the game's distance swap leaves a flag stale, two bugs appear:
--   * collision left OFF -> visible but not grabbable.
--   * SM_Book_1 left hidden -> grabbable but invisible (the shown actor form renders nothing).
-- For each UNWARDED book, assert those two flags, writing ONLY when the live value disagrees
-- (read-before-write ground truth, like WARD_GROUND_TRUTH) so steady state = zero render-
-- state churn and can't reintroduce the layer-3 crash. Swap-safe: never touches actor bHidden
-- (the game's distance swap — pinning it would double-render a far book), and corrects
-- SM_Book_1 only when bHidden=false (the shown form). Rolling cursor + budget keeps the async
-- poll loop pumping; warded books are skipped (ENFORCE + Layer 3 keep them hidden).
local RECONCILE_BUDGET = 1000
function M.reconcile_book_actors()
    if not _diag_on("BOOK_ACTOR_RECONCILE") then return end
    if not M._apply_safe then return end
    if M._flush_in_progress then return end          -- don't race an active Pass-1 flush
    -- Drop the snapshot when the world reloaded (stale epoch).
    if M._recon_books and (M._world_epoch or 0) ~= (M._recon_epoch or 0) then
        M._recon_books = nil
    end
    if not M._recon_books or (M._recon_cursor or 1) > (M._recon_n or 0) then
        -- Sweep boundary: re-snapshot the book list + unwarded set.
        M._recon_books = FindAllOf("BP_GrabbingBook_C")
        M._recon_n = 0
        if M._recon_books then pcall(function() M._recon_n = #M._recon_books end) end
        M._recon_cursor = 1
        M._recon_epoch = M._world_epoch
        local only_shelfable = M._slot_data and M._slot_data.only_unward_shelfable_books == 1
        M._recon_uw = M._compute_unwarded_set(only_shelfable)
        if M._recon_n == 0 then return end
    end
    local books = M._recon_books
    local unwarded = M._recon_uw
    if not (books and unwarded) then return end
    local epoch0 = M._world_epoch
    local lo = M._recon_cursor
    local hi = math.min(lo + RECONCILE_BUDGET - 1, M._recon_n)
    -- READ pass (async thread): collect only the unwarded books whose live flags are wrong.
    local fixes = {}
    local checked_unwarded = 0
    for i = lo, hi do
        local b = books[i]
        if b and b:IsValid() then
            local aidx = _book_valid_asset_idx(b)
            local series = aidx ~= nil and M._asset_to_series[aidx] or nil
            if series and unwarded[series] then
                checked_unwarded = checked_unwarded + 1
                -- Collision must be ON for an unwarded book.
                local coll
                pcall(function() coll = b:GetActorEnableCollision() end)
                local fix_coll = (coll == false)
                -- SM_Book_1: only fix in the SHOWN form (bHidden=false); the far HISM form
                -- renders via the pile, leave it alone.
                local bhid
                pcall(function() bhid = b.bHidden end)
                local fix_mesh, sm = false, nil
                if bhid == false then
                    pcall(function() sm = b.SM_Book_1 end)
                    if sm and sm:IsValid() then
                        local mh, mv
                        pcall(function() mh = sm.bHiddenInGame end)
                        pcall(function() mv = sm.bVisible end)
                        if mh == true or mv == false then fix_mesh = true end
                    end
                end
                if fix_coll or fix_mesh then
                    fixes[#fixes + 1] = { book = b, coll = fix_coll, mesh = fix_mesh, sm = sm, series = series }
                end
            end
        end
    end
    M._recon_cursor = hi + 1
    if #fixes == 0 then return end
    -- WRITE pass (mismatched books only), game-thread-gated like Pass 1. Re-check the world
    -- epoch first — a reload between read and a marshaled write leaves `fixes` pointing at
    -- freed actors (a native AV pcall can't catch).
    _on_game_thread(function()
        if (M._world_epoch or 0) ~= (epoch0 or 0) then return end
        local c_coll, c_mesh = 0, 0
        for _, f in ipairs(fixes) do
            local b = f.book
            if b and b:IsValid() then
                if f.coll then
                    pcall(function() b:SetActorEnableCollision(true) end)
                    c_coll = c_coll + 1
                end
                if f.mesh and f.sm and f.sm:IsValid() then
                    pcall(function() f.sm:SetHiddenInGame(false, false) end)
                    pcall(function() f.sm:SetVisibility(true, false) end)
                    c_mesh = c_mesh + 1
                end
            end
        end
        log(("[reconcile] corrected %d book(s) (coll=%d mesh=%d) of %d examined"):format(
            #fixes, c_coll, c_mesh, checked_unwarded))
    end, "BOOK_ACTOR_GAMETHREAD")
end

-- ============================================================================
-- Apply: Bookcases (section-gated visibility)
-- ============================================================================

-- Each section has one BP_M01_CabinetLabel_01_C whose `Label Number` (int32) maps
-- ordinally: 1..14 → 1A..1N, 21..37 → 2A..2Q (gap 15-20 unused). This is the authoritative
-- section mapping — CDI[1]-based derivation is wrong for ~10 sections vs the in-game labels.
local function _label_num_to_section(n)
    if n == nil then return nil end
    n = tonumber(n)
    if not n then return nil end
    if n >= 1 and n <= 14 then
        return "1" .. string.char(string.byte("A") + n - 1)
    elseif n >= 21 and n <= 37 then
        return "2" .. string.char(string.byte("A") + n - 21)
    end
    return nil
end

function M._index_bookcases(silent)
    M._section_to_cases = {}
    M._case_to_section  = {}
    -- A (re)index means our view of the world changed (e.g. quit→Continue reuses actor
    -- paths). Drop the warding tracker so every case re-wards fresh.
    M._case_ward_state = {}
    -- Do NOT drop the sign-glow caches here. refresh_index_if_changed re-indexes on every
    -- streaming change, but CabinetLabels + their SpotLights live in the PERSISTENT level.
    -- Clearing the caches forced _apply_label_glow to re-touch all 31 SpotLights every
    -- re-index, and touching a SpotLight whose render state is mid-stream is a write-null
    -- crash. The caches ARE reset on a genuine reload (reset_hism_state / gameplay exit /
    -- canary drift), so glow stays correct across Continue while only touching on change.
    M._ward_canary = nil

    -- Step 1: build boi → BP_BookCase_C map. Wrappers (PillarCabinet, Cabinet_01) reference
    -- children via BookOrderIndex (== child's BookOrderIdx) — more reliable than
    -- ChildActorComponent:GetChildActor(), which returns nil for us.
    local boi_to_case = {}
    local cases = FindAllOf("BookCaseBase")
    if not cases or (function() local n = 0; pcall(function() n = #cases end); return n end)() == 0 then
        cases = FindAllOf("BP_BookCase_C")
    end
    if cases then
        local cn = 0
        pcall(function() cn = #cases end)
        for i = 1, cn do
            local c = cases[i]
            if c and c:IsValid() then
                local boi
                pcall(function() boi = c.BookOrderIdx end)
                if boi and boi >= 0 then boi_to_case[boi] = c end
            end
        end
    end

    -- Step 2: walk CabinetLabels. LabelNumber → section. CountBookCase entries are direct
    -- BookCases (add as-is) or wrappers whose BookOrderIndex resolves children via boi_to_case.
    local labels = FindAllOf("BP_M01_CabinetLabel_01_C")
    if not labels then
        log("(no CabinetLabels found; cannot index)")
        M._cases_indexed = true
        return
    end
    local n = 0
    pcall(function() n = #labels end)
    if n == 0 then
        log("(0 CabinetLabels in level)")
        M._cases_indexed = true
        return
    end

    local seen = {}
    local labels_ok, labels_skipped = 0, 0
    local resolved, unresolved = 0, 0

    -- De-dup by GetFullName, not tostring(case): UE4SS returns different Lua wrappers for the
    -- same UObject across fetch paths, but GetFullName is the stable UE path.
    local function _case_key(case)
        local name
        pcall(function() name = case:GetFullName() end)
        return name or tostring(case)
    end

    local function add_case(sid, case)
        if not case or not case:IsValid() then return end
        local key = _case_key(case)
        if seen[key] then return end
        seen[key] = true
        table.insert(M._section_to_cases[sid], case)
        M._case_to_section[key] = sid
        resolved = resolved + 1
    end

    for i = 1, n do
        local lbl = labels[i]
        if lbl and lbl:IsValid() then
            local num
            pcall(function() num = lbl["Label Number"] end)
            local sid = _label_num_to_section(num)
            if sid then
                M._section_to_cases[sid] = M._section_to_cases[sid] or {}
                pcall(function()
                    local cb = lbl.CountBookCase
                    if cb then
                        local cn = 0
                        pcall(function() cn = #cb end)
                        for j = 1, cn do
                            local actor = cb[j]
                            if actor and actor:IsValid() then
                                local cls
                                pcall(function() cls = actor:GetClass():GetFName():ToString() end)
                                if cls == "BP_M01_PillarCabinet_01_01_C" then
                                    -- BookOrderIndex array → child BookCases
                                    pcall(function()
                                        local arr = actor.BookOrderIndex
                                        if arr then
                                            local an = 0
                                            pcall(function() an = #arr end)
                                            for k = 1, an do
                                                local b = tonumber(arr[k])
                                                if b and b >= 0 and boi_to_case[b] then
                                                    add_case(sid, boi_to_case[b])
                                                else
                                                    unresolved = unresolved + 1
                                                end
                                            end
                                        end
                                    end)
                                elseif cls == "BP_M01_Cabinet_01_C" then
                                    -- Single scalar BookOrderIndex
                                    pcall(function()
                                        local b = tonumber(actor.BookOrderIndex)
                                        if b and b >= 0 and boi_to_case[b] then
                                            add_case(sid, boi_to_case[b])
                                        else
                                            unresolved = unresolved + 1
                                        end
                                    end)
                                else
                                    -- Direct BookCase actor (BP_BookCase_C and subclasses)
                                    add_case(sid, actor)
                                end
                            end
                        end
                    end
                end)
                labels_ok = labels_ok + 1
            else
                labels_skipped = labels_skipped + 1
            end
        end
    end

    -- Stray-case sweep: any BookCase not added via a CabinetLabel walk is a level-design
    -- artifact not in any section. Kept permanently hidden + collision-off (else placement
    -- can drop an unreachable book = softlock). Same _case_key so indexed cases aren't reclassified.
    M._stray_cases = {}
    local all_cases = FindAllOf("BookCaseBase")
    if not all_cases or (function() local nn = 0; pcall(function() nn = #all_cases end); return nn end)() == 0 then
        all_cases = FindAllOf("BP_BookCase_C")
    end
    if all_cases then
        local an = 0
        pcall(function() an = #all_cases end)
        for i = 1, an do
            local c = all_cases[i]
            if c and c:IsValid() then
                local key = _case_key(c)
                if not seen[key] then
                    seen[key] = true
                    M._stray_cases[#M._stray_cases + 1] = c
                end
            end
        end
    end

    M._cases_indexed = true
    if silent then return end

    local section_keys = {}
    for k in pairs(M._section_to_cases) do section_keys[#section_keys + 1] = k end
    table.sort(section_keys)
    log(("Indexed %d BookCases across %d sections (labels: %d ok, %d skipped, %d unresolved-boi), %d stray"):format(
        resolved, #section_keys, labels_ok, labels_skipped, unresolved, #M._stray_cases))
    log(("Sections with bookcases: %s"):format(table.concat(section_keys, ", ")))

    local missing = {}
    for sid, count in pairs(M._shelves_open) do
        if count > 0 and not M._section_to_cases[sid] then
            missing[#missing + 1] = sid
        end
    end
    if #missing > 0 then
        table.sort(missing)
        log(("WARNING: sections with shelf unlocks but no bookcases indexed: %s"):format(
            table.concat(missing, ", ")))
    end
end

--- Re-index and return true iff the index grew (new sections/cases). main.lua's refresh
--- loop uses this to catch lazily-streamed bookcases without re-applying when unchanged.
function M.refresh_index_if_changed()
    if not M._gameplay_active or not M._apply_safe then return false end

    local before_total = 0
    local before_sections = {}
    for sid, cases in pairs(M._section_to_cases) do
        before_total = before_total + #cases
        before_sections[sid] = #cases
    end

    -- Force re-index (silent). We blow away the old map; rebuild quietly,
    -- then log only if something changed.
    M._cases_indexed = false
    M._index_bookcases(true)

    local after_total = 0
    local new_sections = {}
    local grew_sections = 0
    for sid, cases in pairs(M._section_to_cases) do
        after_total = after_total + #cases
        if before_sections[sid] == nil then
            new_sections[#new_sections + 1] = sid
        elseif #cases > before_sections[sid] then
            grew_sections = grew_sections + 1
        end
    end

    if after_total ~= before_total or #new_sections > 0 then
        if #new_sections > 0 then
            table.sort(new_sections)
            log(("Re-index found new sections: %s"):format(table.concat(new_sections, ", ")))
        end
        log(("Bookcase index changed: %d → %d total cases (%d sections grew)"):format(
            before_total, after_total, grew_sections))
        return true
    end
    return false
end

-- Class-name → vol-capacity tier for ordering cases within a section (smaller unlocks
-- first, matching the apworld's shelf_req). tier 1 = 4x5 (5-vol), tier 2 = rest (10-vol).
local CASE_VOL_TIER = {
    BP_BookCase_4x5_C  = 1,
    BP_BookCase_C      = 2,
    BP_BookCase_4x16_C = 2,
    BP_BookCase_6x16_C = 2,
}

local function _case_tier(case)
    local cls
    pcall(function() cls = case:GetClass():GetFName():ToString() end)
    return CASE_VOL_TIER[cls] or 2
end

-- Flat list of AssetIdx a BookCase accepts.
--   Uniform (CDI[1] in the case's section): CDI[1..RowStatus length].
--   Mixed (4x16, 6x16): CDI is a decorator set; use BookArrayInfo.CorrectIdx groups, deduped.
local function _case_accepted_assets(case, sid)
    local out = {}
    if not case or not case:IsValid() then return out end

    local rs_len = 0
    pcall(function() rs_len = #case.RowStatus end)

    local cdi_first = nil
    pcall(function() cdi_first = tonumber(case.CorrectBookDataIndex[1]) end)
    local uniform = cdi_first and M._asset_to_section[cdi_first] == sid

    if uniform then
        pcall(function()
            local cdi = case.CorrectBookDataIndex
            for i = 1, rs_len do
                local v = tonumber(cdi[i])
                if v and v >= 0 then out[#out + 1] = v end
            end
        end)
    else
        pcall(function()
            local bai = case.BookArrayInfo
            local n = 0; pcall(function() n = #bai end)
            local seen = {}
            for k = 1, n do
                local entry = bai[k]
                if entry then
                    pcall(function()
                        local ci = entry.CorrectIdx
                        local cn = 0; pcall(function() cn = #ci end)
                        for j = 1, cn do
                            local v = tonumber(ci[j])
                            if v and v >= 0 and not seen[v] then
                                seen[v] = true
                                out[#out + 1] = v
                            end
                        end
                    end)
                end
            end
        end)
    end
    return out
end

-- Fence-cover variants (chain-link in front of each warded case), sized per case:
--   standard — BP_WardCover: 10-vol case / uniform section
--   cabinet  — BP_WardCover_Cabinet: tall alcove sections (wider collision so books
--              can't be thrown through the sides)
--   small    — BP_WardCover_Small: 5-vol case of a mixed section
--   smallest — BP_WardCover_Smallest: 2O outer cases (narrower than small)
-- FENCE_PER_CASE maps section → { [case_idx] = variant }; unlisted cases default to standard
-- unless the section is in FENCE_CABINET_SECTIONS. case_idx is CountBookCase order, which may
-- not match physical left-to-right layout — verify visually after changes.
local FENCE_CABINET_SECTIONS = {
    ["1C"] = true, ["1D"] = true, ["1G"] = true, ["1H"] = true,
    ["2C"] = true, ["2D"] = true, ["2G"] = true,
    ["2H"] = true, ["2K"] = true, ["2L"] = true,
}
local FENCE_PER_CASE = {
    ["1M"] = { [1] = "small",    [2] = "small" },               -- 5 cases: 1-2 small, 3-5 standard
    ["1N"] = { [1] = "small",    [2] = "small" },               -- 5 cases: 1-2 small, 3-5 standard
    ["2M"] = { [1] = "small" },                                 -- 2 cases: 1 small, 2 standard
    ["2N"] = { [1] = "small" },                                 -- 2 cases: 1 small, 2 standard
    ["2O"] = { [1] = "smallest", [2] = "smallest" },            -- 3 cases: 1-2 smallest (outer L+R), 3 standard (middle)
    ["2P"] = { [1] = "small" },                                 -- 2 cases: 1 small, 2 standard
    ["2Q"] = { [1] = "small" },                                 -- 2 cases: 1 small, 2 standard
}
local FENCE_BP_FUNC = {
    standard = "SpawnWardCover",
    cabinet  = "SpawnWardCover_Cabinet",
    small    = "SpawnWardCover_Small",
    smallest = "SpawnWardCover_Smallest",
}

local function _fence_variant_for_case(section_id, case_idx)
    if FENCE_CABINET_SECTIONS[section_id] then return "cabinet" end
    local per_case = FENCE_PER_CASE[section_id]
    if per_case and per_case[case_idx] then return per_case[case_idx] end
    return "standard"
end

-- Section-sign (CabinetLabel) glow. Each sign's SpotLight is driven as an unlock-progress
-- cue: RED = none of the section's cases unlocked, YELLOW = some, OFF = all (game's own
-- completion glow takes over). label→section map comes from the indexer. SAFE: gameplay-only
-- (never the streaming window that AV'd), apply-on-change, and we never persistently hold the
-- SpotLight (a render-tied ref held across teardown hung the game) — look it up on the rare
-- state-change and keep only primitives.

-- Bright value by ELightUnits (0 Unitless, 1 Candelas, 2 Lumens, 3 EV). Signs use Candelas.
local GLOW_INTENSITY = { [0] = 0.5, [1] = 0.5, [2] = 180.0, [3] = 1.0 }

-- Glow locked signs now (gameplay + apply-safe) instead of waiting for the 5s loop. Forces a
-- fresh map first (drops stale label refs from the prior world) so it's safe right after Continue.
function M._maybe_glow_now()
    if not (M._gameplay_active and M._apply_safe) then return end
    -- Request a glow remap on the GAME thread (the L2 pump impl honors it). Do NOT clear the glow
    -- tables or run _apply_label_glow here -- this runs on the MOD thread and would rebuild/iterate
    -- M._section_to_label concurrently with the game-thread _apply_label_glow (the L2 impl) -> the
    -- rc3 cross-thread Lua-heap race. The remap lands on the next L2 pass (<=5s; cosmetic).
    M._glow_remap_pending = true
end

function M._apply_label_glow(cases_snap)
    -- Map sections → CabinetLabel via `Label Number`, once per session in gameplay. Done here
    -- (not at index/load) so nothing touches these actors during the fragile streaming window.
    if not M._section_to_label then
        M._section_to_label = {}
        local labels = FindAllOf("BP_M01_CabinetLabel_01_C")
        local nl = 0; if labels then pcall(function() nl = #labels end) end
        for i = 1, nl do
            local lb = labels[i]
            if lb and lb:IsValid() then
                local num; pcall(function() num = lb["Label Number"] end)
                local sid = _label_num_to_section(num)
                if sid then M._section_to_label[sid] = lb end
            end
        end
        local c = 0; for _ in pairs(M._section_to_label) do c = c + 1 end
        log(("[label-glow] mapped %d sections to signs (gameplay)"):format(c))
    end
    M._section_glow_state = M._section_glow_state or {}
    M._section_glow_orig = M._section_glow_orig or {}
    for sid, lbl in pairs(M._section_to_label) do
        -- RED = none unlocked, YELLOW = some, OFF (game owns the light) = all, by
        -- shelves-open vs the section's total case count.
        local open = M._shelves_open[sid] or 0
        local total = (cases_snap and cases_snap[sid] and #cases_snap[sid]) or 0
        if total == 0 and M._section_bookcase_count then
            total = M._section_bookcase_count[sid] or 0
        end
        local state
        if total <= 0 then            state = "off"      -- unknown total -> leave it to the game
        elseif open <= 0 then         state = "red"
        elseif open >= total then     state = "off"
        else                          state = "yellow" end
        if M._section_glow_state[sid] ~= state then
            if lbl and lbl:IsValid() then
                -- Look the SpotLight up on-demand; never store the component.
                local spot
                local comps; pcall(function() comps = lbl.BlueprintCreatedComponents end)
                local cn = 0; if comps then pcall(function() cn = #comps end) end
                for j = 1, cn do
                    local c = comps[j]
                    if c then
                        local cls = ""; pcall(function() cls = c:GetClass():GetFName():ToString() end)
                        if cls == "SpotLightComponent" then spot = c; break end
                    end
                end
                if spot and spot:IsValid() then
                    if not M._section_glow_orig[sid] then
                        local oi, ov, ou
                        pcall(function() oi = spot.Intensity end)
                        pcall(function() ov = spot:IsVisible() end)
                        pcall(function() ou = spot.IntensityUnits end)
                        M._section_glow_orig[sid] = { int = oi, vis = ov, units = ou }
                    end
                    local o = M._section_glow_orig[sid] or {}
                    if state == "red" or state == "yellow" then
                        local col = (state == "red")
                            and { R = 1.0, G = 0.0, B = 0.0, A = 1.0 }   -- none unlocked
                            or  { R = 1.0, G = 1.0, B = 0.0, A = 1.0 }   -- some but not all
                        pcall(function() spot:SetLightColor(col, true) end)
                        local inten = GLOW_INTENSITY[o.units or 0] or 15.0
                        pcall(function() spot:SetIntensity(inten) end)
                        pcall(function() spot:SetVisibility(true, false) end)
                    else
                        -- All unlocked: restore original light state; the game owns the
                        -- real completion glow from here.
                        pcall(function() spot:SetIntensity(o.int or 0.0) end)
                        pcall(function() spot:SetVisibility(o.vis == true, false) end)
                        pcall(function() spot:SetLightColor({ R = 1.0, G = 1.0, B = 1.0, A = 1.0 }, true) end)
                    end
                end
            end
            M._section_glow_state[sid] = state
        end
    end
end

-- Layer-2 ward marshaled onto the GAME THREAD (gated CASE_WARD_GAMETHREAD) for both callers,
-- so its collision/visibility writes + reads can't race the engine's collision/render workers.
function M._apply_bookcases_to_world()
    if not M._cases_indexed then return end
    -- Snapshot the section->cases map + shelf counts on the MOD thread so the game-thread impl
    -- iterates an immutable copy, never the live M._section_to_cases that _index_bookcases rebuilds
    -- in place (the rc3 cross-thread Lua-heap race). Shallow copy: new outer + inner lists, same
    -- case UObjects (read on the game thread).
    local cases_snap = {}
    for sid, list in pairs(M._section_to_cases) do
        local ln = 0; pcall(function() ln = #list end)
        local copy = {}
        for i = 1, ln do copy[i] = list[i] end
        cases_snap[sid] = copy
    end
    local shelves_snap = {}
    for sid, c in pairs(M._shelves_open) do shelves_snap[sid] = c end
    -- Stray cases (no section) are warded by an index loop in the impl; snapshot them too so the
    -- game thread never reads M._stray_cases while _index_bookcases rebuilds it on the mod thread.
    local stray_snap = {}
    do local sn = 0; pcall(function() sn = #M._stray_cases end)
       for i = 1, sn do stray_snap[i] = M._stray_cases[i] end end
    _on_game_thread(function() M._apply_bookcases_impl(cases_snap, shelves_snap, stray_snap) end, "CASE_WARD_GAMETHREAD")
end

function M._apply_bookcases_impl(cases_snap, shelves_snap, stray_snap)
    if not M._cases_indexed then return end
    -- Iterate the MOD-thread snapshots, not live M._section_to_cases / M._shelves_open / M._stray_cases
    -- (the mod thread rewrites them). Fallback to live for a direct/legacy call.
    cases_snap = cases_snap or M._section_to_cases
    shelves_snap = shelves_snap or M._shelves_open
    stray_snap = stray_snap or M._stray_cases
    -- Section sign glow (gameplay-only, apply-on-change). ALL glow-table mutation happens HERE on
    -- the game thread; _maybe_glow_now (mod thread) only sets _glow_remap_pending so a Continue
    -- re-maps the labels without touching the glow tables off-thread.
    if M._gameplay_active and M._apply_safe then
        if M._glow_remap_pending then
            M._glow_remap_pending = false
            M._section_to_label = nil
            M._section_glow_state = {}
            M._section_glow_orig = {}
        end
        pcall(function() M._apply_label_glow(cases_snap) end)
    end
    -- Drift canary: the game silently resets case collision on some transitions (Menu→Continue)
    -- with NO mod event, so apply-on-change would skip the now-unwarded cases forever. If our
    -- sample warded mesh's Camera response is no longer Ignore, drop the trackers to re-apply all.
    if M._ward_canary then
        if M._ward_canary:IsValid() then
            local resp
            pcall(function() resp = M._ward_canary:GetCollisionResponseToChannel(4) end)
            if resp ~= nil and resp ~= 0 then
                log("[ward-canary] warding drift detected — re-warding + re-glowing")
                M._case_ward_state = {}
                M._section_to_label = nil
                M._section_glow_state = {}
                M._section_glow_orig = {}
                M._ward_canary = nil
            end
        else
            M._ward_canary = nil   -- stale (world reloaded); other paths re-ward
        end
    end

    -- Periodic ward reconciliation. Apply-on-change is cheap but can strand a case recorded
    -- as done in _case_ward_state while its real collision is wrong (an unlock restore that
    -- silently didn't take, or a reset the canary's single mesh missed). Every RECONCILE_EVERY
    -- passes, drop the ward cache to force a clean full re-assert from _shelves_open. Gated on
    -- gameplay+apply_safe so it never races teardown; cheap (~1-8 calls/mesh). Captures kept.
    local RECONCILE_EVERY = 30
    if M._gameplay_active and M._apply_safe then
        M._reconcile_tick = (M._reconcile_tick or 0) + 1
        if M._reconcile_tick >= RECONCILE_EVERY then
            M._reconcile_tick = 0
            if M._case_ward_state and next(M._case_ward_state) ~= nil then
                log("[ward-reconcile] periodic re-assert of all bookcase ward state")
                M._case_ward_state = {}
            end
        end
    end

    local shown, hidden, dead = 0, 0, 0
    for section_id, cases in pairs(cases_snap) do
        local shelves_open = shelves_snap[section_id] or 0
        local visible_count = math.min(shelves_open, #cases)

        -- Stable order: smaller-vol cases first, BookOrderIdx breaks ties.
        local sorted = {}
        for i, c in ipairs(cases) do sorted[i] = c end
        table.sort(sorted, function(a, b)
            local at, bt = _case_tier(a), _case_tier(b)
            if at ~= bt then return at < bt end
            local ai, bi = -2, -2
            pcall(function() ai = a.BookOrderIdx end)
            pcall(function() bi = b.BookOrderIdx end)
            return (ai or -2) < (bi or -2)
        end)

        for i, case in ipairs(sorted) do
            local visible = i <= visible_count
            if case and case:IsValid() then
                local case_key
                pcall(function() case_key = case:GetFullName() end)

                -- Apply-on-change gate: only mutate on a visible-state change. Warding sticks
                -- (the BP doesn't fight our collision), so steady-state passes are no-ops —
                -- perf, and it closes the window where a poll races world teardown on quit.
                M._case_ward_state = M._case_ward_state or {}
                -- Decide by reading the case's ACTUAL collision, not the cache: the placement
                -- mesh's Camera channel (4) reads Ignore(0)=warded, Block(2)=unwarded. A
                -- correctly-warded case is then a no-op (no render-state churn = the crash),
                -- while game-side drift is still caught within one pass. Falls back to the
                -- cache on a case's first pass or when the read is unavailable.
                local desired_warded = not visible
                local changed
                if _diag_on("WARD_GROUND_TRUTH") then
                    local actual_warded = nil
                    local pm = case_key and M._case_placement_mesh and M._case_placement_mesh[case_key]
                    if pm then
                        local pm_valid = false
                        pcall(function() pm_valid = pm:IsValid() end)
                        if pm_valid then
                            local ch4
                            pcall(function() ch4 = pm:GetCollisionResponseToChannel(4) end)
                            if ch4 ~= nil then actual_warded = (tonumber(ch4) == 0) end
                        end
                    end
                    if actual_warded == nil then
                        changed = (not case_key) or (M._case_ward_state[case_key] ~= visible)
                    else
                        changed = (actual_warded ~= desired_warded)
                    end
                else
                    changed = (not case_key) or (M._case_ward_state[case_key] ~= visible)
                end

                if changed and _diag_on("CASE_WARDING") then
                    trace.begin(visible and "ward-show" or "ward-hide", case)
                    local ok = pcall(function()
                        -- Collision warding via _ward_collision. The case actor itself stays
                        -- shown; warding is collision-only so the mesh remains a visible stack.
                        case:SetActorHiddenInGame(false)
                        _ward_collision(case, case_key, not visible)
                        -- Tree-walk children: BP_BookCase children don't always inherit the actor flag.
                        local root = case:K2_GetRootComponent()
                        if root and root:IsValid() then
                            _walk_set_visibility(root, true)
                        end
                        local comps
                        pcall(function() comps = case.BlueprintCreatedComponents end)
                        if comps then
                            local cn = 0; pcall(function() cn = #comps end)
                            for j = 1, cn do
                                local c = comps[j]
                                if c and c:IsValid() then
                                    pcall(function() c:SetVisibility(true, false) end)
                                    pcall(function() c:SetHiddenInGame(false, false) end)
                                    if _diag_on("RENDER_STATE_DIRTY") then
                                        pcall(function() c:MarkRenderStateDirty() end)
                                    end
                                end
                            end
                        end
                    end)
                    trace.finish(visible and "ward-show" or "ward-hide", case)
                    if ok then
                        if case_key then M._case_ward_state[case_key] = visible end
                        if visible then shown = shown + 1 else hidden = hidden + 1 end
                    else
                        dead = dead + 1
                    end
                end

                -- Cover-actor overlay (chain-link fence) per (section, case_idx) variant, all
                -- pcall-wrapped so an older pak falls back to standard SpawnWardCover.
                -- GATED OFF (M._covers_enabled nil/false): runtime cover actors are a
                -- connect/quit crash source, so warding is collision-only for now.
                if case_key and M._covers_enabled then
                    local mod_actor = FindFirstOf("ModActor_C")
                    if mod_actor and mod_actor:IsValid() then
                        if visible then
                            -- Visible: despawn cover if any.
                            local existing_cover = M._case_covers[case_key]
                            if existing_cover and existing_cover:IsValid() then
                                pcall(function()
                                    mod_actor:DespawnWardCover(existing_cover)
                                end)
                            end
                            M._case_covers[case_key] = nil
                        else
                            -- Warded: spawn cover if not present.
                            local existing_cover = M._case_covers[case_key]
                            if not existing_cover or not existing_cover:IsValid() then
                                local variant = _fence_variant_for_case(section_id, i)
                                local fn_name = FENCE_BP_FUNC[variant] or "SpawnWardCover"
                                -- One-shot per (section, case_idx): confirm the variant assignment.
                                M._diag_fence_dispatch_logged = M._diag_fence_dispatch_logged or {}
                                local diag_key = section_id .. "|" .. tostring(i)
                                if not M._diag_fence_dispatch_logged[diag_key] then
                                    M._diag_fence_dispatch_logged[diag_key] = true
                                    log(("[fence-dispatch] section=%s case_idx=%d variant=%s (%s)"):format(
                                        section_id, i, variant, fn_name))
                                end
                                local spawned
                                local out_table = {}
                                local pcall_ok, pcall_err = pcall(function()
                                    -- UE4SS BP out-params: pass an empty table UE4SS populates
                                    -- under the BP param name (nil fails "no table on the stack").
                                    local fn = mod_actor[fn_name]
                                    if fn ~= nil then
                                        fn(mod_actor, case, out_table)
                                    else
                                        -- Variant absent in this pak; fall back to standard.
                                        mod_actor:SpawnWardCover(case, out_table)
                                    end
                                end)
                                spawned = out_table.spawned_cover
                                    or out_table.SpawnedCover
                                    or out_table[1]
                                    or out_table.ReturnValue
                                -- One-shot: dump out_table keys to see what UE4SS populated.
                                if not M._diag_spawnwardcover_table_dumped then
                                    M._diag_spawnwardcover_table_dumped = true
                                    local keys = {}
                                    for k, v in pairs(out_table) do
                                        keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
                                    end
                                    log(("[ward-diag] SpawnWardCover out_table keys: {%s}"):format(
                                        table.concat(keys, ", ")))
                                end
                                -- One-shot geometry diagnostic via tostring() (the UE4SS
                                -- wrapper's; raw .X/.Y/.Z field access fails silently here).
                                if spawned and spawned:IsValid()
                                        and not M._diag_geometry_dumped then
                                    M._diag_geometry_dumped = true
                                    local ok_a, val_a = pcall(function()
                                        return tostring(case:K2_GetActorLocation())
                                    end)
                                    local ok_b, val_b = pcall(function()
                                        return tostring(spawned:K2_GetActorLocation())
                                    end)
                                    log(("[ward-diag] case_loc=%s cover_loc=%s (ok=%s/%s)"):format(
                                        tostring(val_a), tostring(val_b),
                                        tostring(ok_a), tostring(ok_b)))
                                end
                                if pcall_ok and spawned and spawned:IsValid() then
                                    M._case_covers[case_key] = spawned
                                    if not M._diag_spawnwardcover_ok then
                                        M._diag_spawnwardcover_ok = true
                                        local sname
                                        pcall(function() sname = spawned:GetFullName() end)
                                        log(("[ward-diag] SpawnWardCover SUCCEEDED for first time: section=%s case_idx=%d -> %s"):format(
                                            section_id, i, tostring(sname)))
                                    end
                                    -- BlockerBox saved values come through as Overlap(1) at
                                    -- runtime despite the editor showing Block, so force every
                                    -- channel to Block(2) on it directly. Idempotent.
                                    pcall(function()
                                        local force_comps = spawned.BlueprintCreatedComponents
                                        local fn = 0; pcall(function() fn = #force_comps end)
                                        for fj = 1, fn do
                                            local c = force_comps[fj]
                                            if c and c:IsValid() then
                                                local cname
                                                pcall(function() cname = c:GetFName():ToString() end)
                                                if cname == "BlockerBox" then
                                                    pcall(function() c:SetCollisionResponseToAllChannels(2) end)
                                                    if not M._diag_blocker_forced then
                                                        M._diag_blocker_forced = true
                                                        log("[ward-diag] BlockerBox responses force-set to Block on first spawned cover")
                                                    end
                                                end
                                            end
                                        end
                                    end)
                                else
                                    if not M._diag_spawnwardcover_err then
                                        M._diag_spawnwardcover_err = true
                                        local kind
                                        if not pcall_ok then
                                            kind = "pcall ERROR: " .. tostring(pcall_err)
                                        elseif spawned == nil then
                                            kind = "returned nil (function may not exist on ModActor)"
                                        elseif not spawned:IsValid() then
                                            kind = "returned invalid actor"
                                        else
                                            kind = "unknown failure"
                                        end
                                        log(("[ward-diag] SpawnWardCover FAILED on first attempt: section=%s case_idx=%d — %s"):format(
                                            section_id, i, kind))
                                    end
                                end
                            end
                        end
                    end
                end
            else
                dead = dead + 1
            end
        end
    end

    -- Stray cases (not tied to any section): keep permanently hidden + collision-off so
    -- placement can't drop books on them.
    local stray_disabled, stray_dead = 0, 0
    for i = 1, (_diag_on("CASE_WARDING") and #stray_snap or 0) do
        local case = stray_snap[i]
        if case and case:IsValid() then
            local ok = pcall(function()
                case:SetActorHiddenInGame(true)
                case:SetActorEnableCollision(false)
                local root = case:K2_GetRootComponent()
                if root and root:IsValid() then
                    _walk_set_visibility(root, false)
                end
                local comps
                pcall(function() comps = case.BlueprintCreatedComponents end)
                if comps then
                    local cn = 0; pcall(function() cn = #comps end)
                    for j = 1, cn do
                        local c = comps[j]
                        if c and c:IsValid() then
                            pcall(function() c:SetVisibility(false, false) end)
                            pcall(function() c:SetHiddenInGame(true, false) end)
                            if _diag_on("RENDER_STATE_DIRTY") then
                                pcall(function() c:MarkRenderStateDirty() end)
                            end
                        end
                    end
                end
            end)
            if ok then stray_disabled = stray_disabled + 1
            else stray_dead = stray_dead + 1 end
        else
            stray_dead = stray_dead + 1
        end
    end

    -- Only log on change vs the last apply (the 5s re-apply spammed identical lines).
    local _diag_total = 0
    for _, _cs in pairs(cases_snap) do _diag_total = _diag_total + #_cs end
    local key = string.format("%d/%d/%d/%d/%d", _diag_total, shown, hidden, dead, stray_disabled)
    if M._last_apply_log_key ~= key then
        log(("Bookcases: cases=%d shown=%d hidden=%d dead=%d stray=%d (gp=%s as=%s)"):format(
            _diag_total, shown, hidden, dead, stray_disabled,
            tostring(M._gameplay_active), tostring(M._apply_safe)))
        M._last_apply_log_key = key
    end

end

--- Per-section log of which series each VISIBLE case accepts vs which are UNLOCKED (* marker).
--- Useful when the player can't find a book that fits an open shelf.
function M.log_visible_case_series()
    if not M._cases_indexed then return end

    local active_sids = {}
    for sid, n in pairs(M._shelves_open) do
        if (n or 0) > 0 then active_sids[#active_sids + 1] = sid end
    end
    if #active_sids == 0 then
        log("(no sections with shelf unlocks; no visible cases to summarize)")
        return
    end
    table.sort(active_sids)

    log("--- Visible case → accepted series (* = unlocked, . = locked) ---")
    for _, section_id in ipairs(active_sids) do
        local cases = M._section_to_cases[section_id] or {}
        local shelves_open = M._shelves_open[section_id] or 0
        local visible_count = math.min(shelves_open, #cases)
        if visible_count == 0 then
            log(("Section %s: %d unlocks, but no indexed cases"):format(
                section_id, shelves_open))
        else
            local sorted = {}
            for i, c in ipairs(cases) do sorted[i] = c end
            table.sort(sorted, function(a, b)
                local at, bt = _case_tier(a), _case_tier(b)
                if at ~= bt then return at < bt end
                local ai, bi = -2, -2
                pcall(function() ai = a.BookOrderIdx end)
                pcall(function() bi = b.BookOrderIdx end)
                return (ai or -2) < (bi or -2)
            end)

            log(("Section %s: %d/%d cases visible"):format(
                section_id, visible_count, #cases))
            for i = 1, visible_count do
                local case = sorted[i]
                local cls = "?"
                pcall(function() cls = case:GetClass():GetFName():ToString() end)
                local accepted = _case_accepted_assets(case, section_id)
                local unlocked_count = 0
                for _, aidx in ipairs(accepted) do
                    local name = M._asset_to_series[aidx]
                    if name and M._series_unlocked[name] then
                        unlocked_count = unlocked_count + 1
                    end
                end
                log(("  case[%d] %s — %d accepted, %d unlocked:"):format(
                    i, cls, #accepted, unlocked_count))
                for _, aidx in ipairs(accepted) do
                    local name = M._asset_to_series[aidx] or "?"
                    local vols = M._asset_to_volumes[aidx] or 0
                    local marker = M._series_unlocked[name] and "*" or "."
                    log(("    %s [aidx=%d, %2d vol] %s"):format(
                        marker, aidx, vols, name))
                end
            end
        end
    end
end

-- ============================================================================
-- Row completion detection (FinishRow → AP location check)
-- ============================================================================

-- Fire the AP row-completion location for each genuinely-completed shelf. AUTHORITATIVE
-- signal: per-case RowStatus (TArray<bool>, ONE ENTRY PER SHELF); rs[i]==true ONLY when
-- shelf i's series is fully placed IN ORDER (the game validates order + section first).
-- Read the bool VALUES, never #RowStatus (that's the shelf count, not a completion count).
--   • Uniform case  -> completed shelf i maps to series CorrectBookDataIndex[i].
--   • Mixed cabinet -> "fully present in home section", capped by # completed shelves.
function M.detect_completed_rows()
    if not M._cases_indexed then return 0 end
    if not M._slot_data then return 0 end
    local row_loc_map = M._slot_data.row_location_map
    if type(row_loc_map) ~= "table" then return 0 end

    local sent_count = 0

    -- Send the row-completion location for one (section, series), de-duped via
    -- _sent_row_locations. Returns true if a NEW check was actually sent.
    local function fire_row(sid, series_name, dbg)
        if not series_name then return false end
        local loc_id = row_loc_map[sid .. "|" .. series_name]
        if not loc_id then
            log(("[row-detect] %s / %s -- no loc_id in row_location_map"):format(sid, series_name))
            return false
        end
        if M._sent_row_locations[loc_id] then return false end
        M._sent_row_locations[loc_id] = true
        log(("[row-detect] %s / %s -> loc %d %s"):format(sid, series_name, loc_id, dbg or ""))
        local APClient = package.loaded["AP/APClient"]
        if APClient and APClient.send_check then APClient:send_check(loc_id); return true end
        return false
    end

    for sid, cases in pairs(M._section_to_cases) do
        for _, case in ipairs(cases) do
            if case and case:IsValid() then
                -- RowStatus[i] (TArray<bool>, one per shelf) == true only when shelf i holds
                -- its series fully placed in order. Read the bool values, not the length.
                local rs = nil; pcall(function() rs = case.RowStatus end)
                local rs_n = 0; if rs then pcall(function() rs_n = #rs end) end
                local completed = {}   -- 1-based shelf indices with rs[i] == true
                for i = 1, rs_n do
                    local done = false
                    pcall(function() local v = rs[i]; done = (v == true or v == 1) end)
                    if done then completed[#completed + 1] = i end
                end

                if #completed > 0 then
                    -- Read the completed series from the books ACTUALLY on each row: under free
                    -- placement CorrectBookDataIndex is the section's answer-set, not a per-row
                    -- map, so cdi[i] fires the wrong series. PlacingBookInfo is a flat row-major
                    -- grid of rows*per_row slots, so row i's books are slots (i-1)*per_row+1..i*per_row.
                    -- Split ItemInfo access — a book sub-object can be transiently freed (native AV).
                    local pbi = nil; pcall(function() pbi = case.PlacingBookInfo end)
                    local pbi_n = 0; if pbi then pcall(function() pbi_n = #pbi end) end
                    local per_row = (rs_n > 0 and pbi_n > 0 and pbi_n % rs_n == 0)
                        and math.floor(pbi_n / rs_n) or 0

                    if pbi and per_row > 0 then
                        -- GRID: read each completed row's own slots and take the dominant AssetIdx
                        -- (dominant guards a transient partial read). No cdi[i], no section guessing.
                        for _, i in ipairs(completed) do
                            local counts = {}
                            for slot = (i - 1) * per_row + 1, i * per_row do
                                local book = pbi[slot]
                                if book and book:IsValid() then
                                    local item_info
                                    pcall(function() item_info = book.ItemInfo end)
                                    if item_info and item_info:IsValid() then
                                        local aidx
                                        pcall(function() aidx = tonumber(item_info.AssetIdx) end)
                                        if aidx and aidx >= 0 then
                                            counts[aidx] = (counts[aidx] or 0) + 1
                                        end
                                    end
                                end
                            end
                            local best_aidx, best_n = nil, 0
                            for aidx, c in pairs(counts) do
                                if c > best_n then best_aidx, best_n = aidx, c end
                            end
                            -- Fire ONLY when the row's series belongs to THIS case's section;
                            -- a foreign mapping (mis-index / cross-section / mis-read) is logged, not fired.
                            local best_sid = best_aidx and M._asset_to_section[best_aidx]
                            if best_aidx and best_sid == sid then
                                if fire_row(sid, M._asset_to_series[best_aidx],
                                        ("(row %d, AssetIdx %d, %d/%d slots)"):format(i, best_aidx, best_n, per_row)) then
                                    sent_count = sent_count + 1
                                end
                            elseif best_aidx then
                                log(("[row-detect] SKIP cross-section: row %d series=%s is section %s, not %s -- not firing"):format(
                                    i, tostring(M._asset_to_series[best_aidx]), tostring(best_sid), sid))
                            end
                        end
                    else
                        -- FALLBACK (non-grid PBI: slot count isn't rows*per_row): "fully present in
                        -- home section" scan capped by #completed. Less precise but never invents a
                        -- not-present series.
                        local current = {}
                        pcall(function()
                            if pbi then
                                for i = 1, pbi_n do
                                    local book = pbi[i]
                                    if book and book:IsValid() then
                                        local item_info
                                        pcall(function() item_info = book.ItemInfo end)
                                        if item_info and item_info:IsValid() then
                                            local aidx
                                            pcall(function() aidx = tonumber(item_info.AssetIdx) end)
                                            if aidx and aidx >= 0 then
                                                current[aidx] = (current[aidx] or 0) + 1
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                        local candidates = {}
                        local already_fired = 0
                        for aidx, count in pairs(current) do
                            local expected = M._asset_to_volumes[aidx] or 0
                            if expected > 0 and count >= expected
                                    and M._asset_to_section[aidx] == sid then
                                local series_name = M._asset_to_series[aidx]
                                local loc_id = series_name and row_loc_map[sid .. "|" .. series_name]
                                if loc_id then
                                    if M._sent_row_locations[loc_id] then
                                        already_fired = already_fired + 1
                                    else
                                        candidates[#candidates + 1] = { aidx = aidx, name = series_name }
                                    end
                                end
                            end
                        end
                        table.sort(candidates, function(a, b) return a.aidx < b.aidx end)
                        local cap = #completed - already_fired
                        if cap > 0 then
                            for k = 1, math.min(cap, #candidates) do
                                local c = candidates[k]
                                if fire_row(sid, c.name,
                                        ("(AssetIdx %d) [scan %d/%d rows]"):format(c.aidx, #completed, rs_n)) then
                                    sent_count = sent_count + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return sent_count
end

--- Mark every row location the server already knows checked (APClient._sent_checks) into
--- _sent_row_locations, so fire_section_completions sees prior-session-completed sections
--- without re-discovering each row. Returns the count newly marked.
function M._sync_sent_row_locations_from_server()
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient._sent_checks) then return 0 end
    if not M._slot_data then return 0 end
    local map = M._slot_data.row_location_map
    if type(map) ~= "table" then return 0 end
    local synced = 0
    for _, loc_id in pairs(map) do
        local lid = tonumber(loc_id)
        if lid and APClient._sent_checks[lid] and not M._sent_row_locations[lid] then
            M._sent_row_locations[lid] = true
            synced = synced + 1
        end
    end
    return synced
end

--- Fire "Section Complete: <id>" for any section whose every row location is marked sent
--- (de-duped via _sent_section_completions). Derived from _sent_row_locations since the
--- game emits no section-complete signal. Called from the FinishRow hook and run_baseline_sync.
function M.fire_section_completions()
    if not M._slot_data then return 0 end
    if not M._section_to_row_locs then return 0 end
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient.send_check) then return 0 end

    -- Prefer slot_data.section_location_map; fall back to AP_LOC_SECTION_FIRST + SECTION_IDX[sid]
    -- for legacy seeds (location ids are allocated identically apworld-side).
    local sec_loc_map = M._slot_data.section_location_map
    local use_slot_map = (type(sec_loc_map) == "table")

    local sent = 0
    for sid, row_locs in pairs(M._section_to_row_locs) do
        local complete_loc
        if use_slot_map then
            complete_loc = sec_loc_map[sid]
            complete_loc = complete_loc and tonumber(complete_loc) or nil
        else
            local idx = SECTION_IDX[sid]
            complete_loc = idx and (AP_LOC_SECTION_FIRST + idx) or nil
        end
        if complete_loc and not M._sent_section_completions[sid]
                and #row_locs > 0 then
            local all_done = true
            for _, loc_id in ipairs(row_locs) do
                if not M._sent_row_locations[loc_id] then
                    all_done = false
                    break
                end
            end
            if all_done then
                M._sent_section_completions[sid] = true
                log(("[section] All %d row(s) complete for section %s → loc %d%s"):format(
                    #row_locs, sid, complete_loc,
                    use_slot_map and "" or " (legacy fallback)"))
                APClient:send_check(complete_loc)
                sent = sent + 1
            end
        end
    end
    return sent
end

--- Fire "Floor N Complete" for any floor whose every active-section row location is sent.
--- Like fire_section_completions at floor granularity (loc 1910550/1910551). Called from
--- the FinishRow hook, the 3s detect_completed_rows poll, and run_baseline_sync.
function M.fire_floor_completions()
    if not M._slot_data then return 0 end
    if not M._floor_to_row_locs then return 0 end
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient.send_check) then return 0 end

    -- Prefer slot_data.floor_location_map; fall back to AP_LOC_FLOOR_FIRST + FLOOR_IDX[floor_n].
    -- Map keys are stringified ints; try the int key first defensively.
    local floor_loc_map = M._slot_data.floor_location_map
    local use_slot_map = (type(floor_loc_map) == "table")

    local sent = 0
    for floor_n, row_locs in pairs(M._floor_to_row_locs) do
        local complete_loc
        if use_slot_map then
            local v = floor_loc_map[floor_n] or floor_loc_map[tostring(floor_n)]
            complete_loc = v and tonumber(v) or nil
        else
            local idx = FLOOR_IDX[floor_n]
            complete_loc = idx and (AP_LOC_FLOOR_FIRST + idx) or nil
        end
        if complete_loc and not M._sent_floor_completions[floor_n]
                and #row_locs > 0 then
            local all_done = true
            for _, loc_id in ipairs(row_locs) do
                if not M._sent_row_locations[loc_id] then
                    all_done = false
                    break
                end
            end
            if all_done then
                M._sent_floor_completions[floor_n] = true
                log(("[floor] All %d row(s) complete for Floor %d -> loc %d%s"):format(
                    #row_locs, floor_n, complete_loc,
                    use_slot_map and "" or " (legacy fallback)"))
                APClient:send_check(complete_loc)
                sent = sent + 1
            end
        end
    end
    return sent
end

--- Fire "Complete N Rows" for any threshold <= total_rows (the game's correct-row counter
--- from FinishRow or CurrentFinishedRowNum). Returns the count sent.
function M.fire_row_completion_checks(total_rows)
    if not M._slot_data then return 0 end
    if not total_rows or total_rows <= 0 then return 0 end
    local thresholds = M._slot_data.row_completion_thresholds
    if type(thresholds) ~= "table" then return 0 end
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient.send_check) then return 0 end

    local sent = 0
    for i = 1, #thresholds do
        local t = tonumber(thresholds[i])
        if t and total_rows >= t and not M._sent_row_completions[t] then
            M._sent_row_completions[t] = true
            local loc_id = AP_LOC_ROW_COMPLETION_FIRST + (i - 1)
            log(("[row-completion] %d rows finished → loc %d ('Complete %d Rows')"):format(
                total_rows, loc_id, t))
            APClient:send_check(loc_id)
            sent = sent + 1
        end
    end
    return sent
end

-- ============================================================================
-- Progress sync (level-ups + milestones)
-- ============================================================================

-- Live book-placement counter from a BP hook. Dormant — no registered BP function fired;
-- the widget read below is the real source. Kept in case a pak-side per-book hook is added.
M._books_placed_observed = 0

-- Highest book count seen this session. The widget can DROP when books are removed, but
-- milestones never un-fire. Reset on slot-connect.
M._books_placed_peak = 0

-- Live "books placed" from the HUD widget. Multiple WBP_PlayerInfo_C exist; FindFirstOf
-- returns a stale title-screen one reading 0, so walk FindAllOf and take the max. nil if none.
function M._read_widget_book_count()
    local best = -1
    local infos = FindAllOf("WBP_PlayerInfo_C")
    if not infos then return nil end
    local n = 0
    pcall(function() n = #infos end)
    for i = 1, n do
        local info = infos[i]
        if info and info:IsValid() then
            pcall(function()
                local t = info.Text_CurrentBookNum
                if t and t:IsValid() then
                    local s = t:GetText():ToString()
                    local v = tonumber(s)
                    if v and v > best then best = v end
                end
            end)
        end
    end
    if best < 0 then return nil end
    return best
end

-- Highest level-up location in APClient._sent_checks (server-populated at slot_connect),
-- the cross-session truth for "what level has this slot reached", independent of GameSaveData.
-- Scans the full range (not contiguous-only) so prior-session gaps still give a correct bound.
function M._compute_sent_level_baseline()
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient._sent_checks) then return 0 end
    local max_sent = 0
    for level = 1, AP_MAX_PLAYER_LEVEL do
        if APClient._sent_checks[AP_LOC_LEVEL_FIRST + (level - 1)] then
            max_sent = level
        end
    end
    return max_sent
end

-- Bump _levels_reached and send the level-up check. Called from main.lua's OnLevelUp hook,
-- one per in-game level-up. Self-heals from _sent_checks BEFORE incrementing: else after a
-- reload (_levels_reached=0) every OnLevelUp re-queues an already-deduped level and lags forever.
function M.on_level_up_event()
    if not M._slot_data then return end
    -- Only fire in gameplay (guards a stale callback claiming a level during a title save flush).
    if not M._gameplay_active then return end
    if M._levels_reached >= AP_MAX_PLAYER_LEVEL then return end

    local sent_level = M._compute_sent_level_baseline()
    if sent_level > M._levels_reached then
        log(("[progress] level-up event: catch-up _levels_reached %d → %d (server's _sent_checks reflects prior-session levels)"):format(
            M._levels_reached, sent_level))
        M._levels_reached = sent_level
    end

    M._levels_reached = M._levels_reached + 1
    local loc = AP_LOC_LEVEL_FIRST + (M._levels_reached - 1)

    -- Calibration diagnostic: log row count + XP-curve prediction at level-up time to check
    -- whether XP_CURVE matches the game's actual level-up rows. CurrentFinishedRowNum may lag 1.
    pcall(function()
        local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
        if not (gi and gi:IsValid()) then return end
        local sg = gi.GameSaveData
        if not (sg and sg:IsValid()) then return end
        local rf = tonumber(sg.GameProgressData.CurrentFinishedRowNum) or -1
        local xp_pred = 0
        local player = FindFirstOf("BP_LibrarianCharacter_C")
        if player and player:IsValid() then
            pcall(function()
                local arr = player.SkillLevelUpRowNum
                local n = 0; pcall(function() n = #arr end)
                for i = 1, math.min(n, AP_MAX_PLAYER_LEVEL) do
                    local needed = tonumber(arr[i]) or 0
                    if rf >= needed then xp_pred = i else return end
                end
            end)
        end
        log(("[calibration] OnLevelUp fired: _levels_reached=%d (just incremented), rows_finished=%d (may lag 1), xp_curve predicts Level %d"):format(
            M._levels_reached, rf, xp_pred))
    end)

    log(("[progress] level-up event: Reached Level %d → loc %d"):format(
        M._levels_reached, loc))
    local APClient = package.loaded["AP/APClient"]
    if APClient and APClient.send_check then
        APClient:send_check(loc)
    end
end

-- Reads GameSaveData + the player's XP curve to: (one-time at baseline) catch up
-- _levels_reached to the saved level; (every call) sync milestone checks from book count.
function M.sync_progress_state()
    if not M._slot_data then return 0, 0 end

    -- Never sync outside gameplay: a bad-timing fire mid-transition to title can read the
    -- WRONG save slot and flood milestone checks.
    if not M._gameplay_active then return 0, 0 end
    if not M._apply_safe then return 0, 0 end

    -- Book count source: HUD widget Text_CurrentBookNum (InsertedBookNum is the fallback).
    -- Track peak — a crossed threshold stays crossed even if books are later removed.
    -- Save-slot guard: only read GameSaveData when SaveGameName is our AP slot (Sav_AP_*);
    -- mid-transition to title it can revert to the default "Sav", which may already have
    -- books=3072 and blow past every milestone.
    -- Split the chained property reads into validated steps: an autosave can reallocate
    -- GameProgressData while sg:IsValid() still passes, AVing the chained read.
    local current_slot = nil
    pcall(function()
        local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
        if gi and gi:IsValid() then
            local sgn
            pcall(function() sgn = gi.SaveGameName end)
            if sgn then
                pcall(function() current_slot = sgn:ToString() end)
            end
        end
    end)
    local is_ap_slot = current_slot and current_slot:find("^Sav_AP_") ~= nil

    local rows_finished = 0
    local books_placed_save = 0
    if is_ap_slot then
        pcall(function()
            local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
            if gi and gi:IsValid() then
                local sg
                pcall(function() sg = gi.GameSaveData end)
                if sg and sg:IsValid() then
                    -- Capture GameProgressData once and verify before reading fields (a
                    -- concurrent autosave reallocating it would AV the chained read).
                    local gpd
                    pcall(function() gpd = sg.GameProgressData end)
                    if gpd then
                        pcall(function() rows_finished     = tonumber(gpd.CurrentFinishedRowNum) or 0 end)
                        pcall(function() books_placed_save = tonumber(gpd.InsertedBookNum) or 0 end)
                    end
                end
            end
        end)
    else
        -- Log once per distinct non-AP slot (no spam); don't trust GameSaveData here.
        if M._last_skipped_save_slot ~= current_slot then
            M._last_skipped_save_slot = current_slot
            log(("[progress] skipping GameSaveData read — current slot %q is not our AP slot"):format(
                tostring(current_slot)))
        end
    end
    local books_placed_widget = M._read_widget_book_count() or 0
    local books_placed_current = math.max(books_placed_save, books_placed_widget,
                                          M._books_placed_observed or 0)
    if books_placed_current > (M._books_placed_peak or 0) then
        M._books_placed_peak = books_placed_current
    end
    local books_placed = M._books_placed_peak or 0

    -- Current level from the player's XP curve. SkillLevelUpRowNum values are CUMULATIVE
    -- thresholds: Level N at rows >= arr[N] (Level 45 = 254 rows; a sum interpretation
    -- gives an unreachable 3500+).
    local current_level = 0
    do
        local player = FindFirstOf("BP_LibrarianCharacter_C")
        if player and player:IsValid() then
            -- Split the array fetch from iteration (a reallocation between would AV arr[i]).
            local arr
            pcall(function() arr = player.SkillLevelUpRowNum end)
            if arr then
                pcall(function()
                    local n = 0; pcall(function() n = #arr end)
                    for i = 1, math.min(n, AP_MAX_PLAYER_LEVEL) do
                        local needed
                        pcall(function() needed = tonumber(arr[i]) or 0 end)
                        if needed == nil then break end
                        if rows_finished >= needed then
                            current_level = i
                        else
                            return
                        end
                    end
                end)
            end
        end
    end

    -- Level-up baseline lives in run_baseline_sync; here just raise _levels_reached back up
    -- if it ever regresses below the XP-curve level or the server's sent floor.
    local levels_sent = 0
    if not M._level_baseline_done then
        log(("[progress] baseline rows=%d current_level=%d (sync delegated to run_baseline_sync)"):format(
            rows_finished, current_level))
        M._level_baseline_done = true
    end
    local sent_level_floor = M._compute_sent_level_baseline()
    local floor_level = math.max(current_level, sent_level_floor)
    if floor_level > M._levels_reached then
        local prev_levels_reached = M._levels_reached
        log(("[progress] sync catch-up: _levels_reached %d → %d (xp=%d sent=%d) — firing send_check for missed levels"):format(
            prev_levels_reached, floor_level, current_level, sent_level_floor))
        M._levels_reached = floor_level
        -- Fire send_check for every level in the catch-up range, else the counter advances
        -- but skipped levels never transmit (send_check dedupes, so re-firing is a no-op).
        local APClient = package.loaded["AP/APClient"]
        if APClient and APClient.send_check then
            for level = 1, floor_level do
                APClient:send_check(AP_LOC_LEVEL_FIRST + (level - 1))
            end
            levels_sent = floor_level - prev_levels_reached
        end
    end

    -- Send milestone checks for crossed thresholds (ordinal-indexed book counts from slot_data).
    local milestones_sent = 0
    local thresholds = M._slot_data.milestone_thresholds or {}
    for i, threshold in ipairs(thresholds) do
        if books_placed >= threshold and not M._milestones_sent[threshold] then
            M._milestones_sent[threshold] = true
            local loc = AP_LOC_MILESTONE_FIRST + (i - 1)
            log(("[progress] milestone: %d books placed (have %d) → loc %d"):format(
                threshold, books_placed, loc))
            local APClient = package.loaded["AP/APClient"]
            if APClient and APClient.send_check then
                APClient:send_check(loc)
                milestones_sent = milestones_sent + 1
            end
        end
    end

    return levels_sent, milestones_sent
end

-- ============================================================================
-- Apply: Skills
-- ============================================================================

-- EUpgradeAbility index → AP item name, to baseline the applied counter from saved levels.
local SKILL_ITEM_BY_ABILITY_IDX = {
    [3] = "Progressive Shelf Guide",     -- ShowMatchingShelf
    [5] = "Progressive Sort",            -- SortBooks
    [6] = "Progressive Auto-Shelving",   -- AutoShelve
    [7] = "Progressive Insight",         -- ShowSameTypeBook
    [8] = "Progressive Assemble",        -- GrabSameTypeBook
}

-- Return the save's SkillData TArray + which field it came from + entry count, preferring
-- whichever V-version has data. The game migrated to PlayerExtraDataV1; legacy PlayerExtraData
-- reads EMPTY on current builds, which zeroed the baseline and re-applied skills every load.
function M._read_save_skill_data(sg)
    if not (sg and sg:IsValid()) then return nil, nil, 0 end
    local v1; pcall(function() v1 = sg.PlayerExtraDataV1.SkillData end)
    local c1 = 0; if v1 then pcall(function() c1 = #v1 end) end
    local v0; pcall(function() v0 = sg.PlayerExtraData.SkillData end)
    local c0 = 0; if v0 then pcall(function() c0 = #v0 end) end
    if not M._skill_src_logged then
        M._skill_src_logged = true
        log(("[skill-baseline] SkillData counts: PlayerExtraDataV1=%d PlayerExtraData(legacy)=%d"):format(c1, c0))
    end
    if c1 > 0 then return v1, "PlayerExtraDataV1", c1 end
    if c0 > 0 then return v0, "PlayerExtraData", c0 end
    if v1 then return v1, "PlayerExtraDataV1", 0 end
    if v0 then return v0, "PlayerExtraData", 0 end
    return nil, nil, 0
end

--- Seed _applied_skill_counts from the save's SkillData (each CurrentLevel = applied count)
--- so AP's reconnect re-dump doesn't re-bump skills already at level. Also refreshes the HUD.
function M._init_applied_skill_counts_from_save()
    M._applied_skill_counts = {}
    local gi = FindFirstOf("BP_LibrarianGameInstance_C")
        or FindFirstOf("LibrarianGameInstanceBase")
    if not gi or not gi:IsValid() then
        log("[skill-baseline] no GameInstance — skipping init")
        return
    end
    local sg
    pcall(function() sg = gi.GameSaveData end)
    if not sg or not sg:IsValid() then
        log("[skill-baseline] no GameSaveData — skipping init")
        return
    end
    local skill_data, src, n = M._read_save_skill_data(sg)
    if not skill_data then
        log("[skill-baseline] no SkillData (PlayerExtraDataV1 or legacy) — skipping init")
        return
    end
    log(("[skill-baseline] using %s.SkillData (%d entries)"):format(tostring(src), n))
    for i = 1, n do
        local entry
        pcall(function() entry = skill_data[i] end)
        if entry then
            local lvl = 0
            pcall(function() lvl = tonumber(entry.CurrentLevel) or 0 end)
            local ability_idx = i - 1  -- 1-based array → 0-based enum
            local item_name = SKILL_ITEM_BY_ABILITY_IDX[ability_idx]
            if item_name and lvl > 0 then
                M._applied_skill_counts[item_name] = lvl
                log(("[skill-baseline] %s = level %d (idx=%d)"):format(item_name, lvl, ability_idx))
            end
        end
    end

    -- HUD refresh via our BP (ModActor_C): direct UpdateSkill from Lua AVs (the BP graph
    -- derefs SkillObject internals Lua leaves inconsistent); the BP event keeps it in engine context.
    M._refresh_hud_from_save()
end

--- Refresh HUD ability icons from save-side levels via our BP's RefreshSkillIcon (every
--- skill at level > 0, including non-AP ones). Requires LibrarianAPHUDFix.pak; no-ops with
--- a warning if the BP isn't loaded (only the on-screen icon row is missing).
function M._refresh_hud_from_save()
    local mod_actor = FindFirstOf("ModActor_C")
    if not mod_actor or not mod_actor:IsValid() then
        log("[hud-refresh] no ModActor_C — LibrarianAPHUDFix.pak not loaded")
        return
    end

    local player_info = FindFirstOf("WBP_PlayerInfo_C")
    if not player_info or not player_info:IsValid() then
        log("[hud-refresh] no WBP_PlayerInfo_C — HUD not yet built")
        return
    end

    local gi = FindFirstOf("BP_LibrarianGameInstance_C")
        or FindFirstOf("LibrarianGameInstanceBase")
    if not gi or not gi:IsValid() then return end
    local sg
    pcall(function() sg = gi.GameSaveData end)
    if not sg or not sg:IsValid() then return end
    local skill_data = M._read_save_skill_data(sg)
    if not skill_data then return end

    local n = 0
    pcall(function() n = #skill_data end)

    local refreshed, failed = 0, 0
    -- Refresh all icons EXCEPT bags: UpgradeBag (1) / UpgradeBag2 (2) re-apply the bag-level
    -- increment via RefreshSkillIcon's BP graph, double-bumping capacity on reload (15→20).
    -- Bags restore naturally from save; other icons are refreshed here or stay empty until use.
    local SKIP_INDICES = { [1]=true, [2]=true }
    for i = 1, n do
        local entry
        pcall(function() entry = skill_data[i] end)
        if entry then
            local lvl = 0
            pcall(function() lvl = tonumber(entry.CurrentLevel) or 0 end)
            local ability_idx = i - 1  -- 1-based array → 0-based enum
            if lvl > 0 and ability_idx >= 0 and ability_idx <= 8 and not SKIP_INDICES[ability_idx] then
                -- left=-1, not 0: 0 crashes the UpdateSkill BP path; -1 = "no banked points
                -- credited" (correct for a load refresh), 0 = "0 just spent" → desync.
                local ok, err = pcall(function()
                    mod_actor:RefreshSkillIcon(player_info, ability_idx, lvl, -1)
                end)
                if ok then
                    refreshed = refreshed + 1
                else
                    failed = failed + 1
                    log(("[hud-refresh] FAILED idx=%d lvl=%d: %s"):format(
                        ability_idx, lvl, tostring(err)))
                end
            end
        end
    end
    log(("[hud-refresh] refreshed %d icons (%d failed)"):format(refreshed, failed))
end

function M._apply_skill(name)
    local idx = SKILL_ITEM_TO_ABILITY[name]
    if not idx then return end

    -- Gate on apply_safe: right after Continue, UpgradePlayer can land before the world is
    -- wired and the BP silently drops it. Queue until set_apply_safe drains us.
    if not M._gameplay_active or not M._apply_safe then
        log(("queued (not yet apply-safe): %s"):format(name))
        M._pending_skill_grants[#M._pending_skill_grants + 1] = name
        return
    end

    -- Counter-based skip: only bump if applied < received. The counter is seeded from save
    -- at apply-safe, so the reconnect re-dump doesn't double-bump skills already at level.
    local target  = M._received_counts[name] or 0
    local applied = M._applied_skill_counts[name] or 0
    if applied >= target then
        log(("Skill %s already applied %d/%d — skipping bump"):format(name, applied, target))
        return
    end

    local player = FindFirstOf("BP_LibrarianCharacter_C")
    if not player or not player:IsValid() then
        log(("requeuing %s — no player yet"):format(name))
        M._pending_skill_grants[#M._pending_skill_grants + 1] = name
        return
    end

    M._ap_grant = true
    local ok, err = pcall(function() player:UpgradePlayer(idx) end)
    M._ap_grant = false
    if ok then
        M._applied_skill_counts[name] = applied + 1
        log(("Granted skill: %s (UpgradeAbility=%d, applied %d/%d)"):format(
            name, idx, M._applied_skill_counts[name], target))
    else
        log(("Skill grant FAILED: %s — %s"):format(name, tostring(err)))
    end
end

--- Periodic skill resync: if _applied_skill_counts lags _received_counts, retry the missing
--- levels via _apply_skill. Trusts _applied_skill_counts, NOT save's SkillData (which reads 0
--- between save events — comparing against it once over-granted every skill to level 10).
--- Conservative: only ever applies up to the received count.
function M.resync_skill_state()
    if not M._gameplay_active or not M._apply_safe then return 0 end
    if not M._slot_data then return 0 end

    local retried_total = 0
    for item_name, ability_idx in pairs(SKILL_ITEM_TO_ABILITY) do
        local target = M._received_counts[item_name] or 0
        local applied = M._applied_skill_counts[item_name] or 0
        if target > applied then
            local missing = target - applied
            log(("[skill-resync] %s (ability=%d): applied=%d received=%d → re-applying %d"):format(
                item_name, ability_idx, applied, target, missing))
            for _ = 1, missing do
                M._apply_skill(item_name)
            end
            retried_total = retried_total + missing
        end
    end
    return retried_total
end

-- ============================================================================
-- Diagnostic
-- ============================================================================

--- Print the current derived state. For ad-hoc debugging from a UE4SS console.
function M.dump()
    local series, shelves = {}, {}
    for sn in pairs(M._series_unlocked) do series[#series + 1] = sn end
    for sid, c in pairs(M._shelves_open) do shelves[#shelves + 1] = sid .. "=" .. tostring(c) end
    table.sort(series); table.sort(shelves)
    log(("DUMP series  (%d): first 5 = %s"):format(
        #series, table.concat({series[1] or "", series[2] or "", series[3] or "",
                                series[4] or "", series[5] or ""}, " | ")))
    log(("DUMP shelves (%d): %s"):format(#shelves, table.concat(shelves, ", ")))
    log(("DUMP received counts:"))
    for k, v in pairs(M._received_counts) do
        log(("  %s × %d"):format(k, v))
    end
end

--- Report actor-level state (bHidden, collision, _books_warded) for every unlocked-series
--- book. A still-hidden / collision-off book means Pass 1 failed to unward it. Logs each
--- problem book; all-correct series are summarized "OK".
function M.dump_unlocked_books_state()
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then log("DUMP unlocked-state: no books in level"); return end
    local bn = 0; pcall(function() bn = #books end)
    if bn == 0 then log("DUMP unlocked-state: 0 books"); return end

    local by_series = {}
    for i = 1, bn do
        local book = books[i]
        if book and book:IsValid() then
            local aidx = _book_valid_asset_idx(book)
            if aidx ~= nil then
                local sname = M._asset_to_series[aidx]
                if sname and M._series_unlocked[sname] then
                    local section = M._asset_to_section[aidx] or "?"
                    by_series[sname] = by_series[sname] or {
                        total=0, problems={}, section=section,
                    }
                    by_series[sname].total = by_series[sname].total + 1
                    local hidden, coll
                    pcall(function() hidden = book.bHidden end)
                    pcall(function() coll = book:GetActorEnableCollision() end)
                    local key = book:GetFullName()
                    if hidden == true or coll == false then
                        local x, y, z = 0, 0, 0
                        pcall(function()
                            local loc = book:K2_GetActorLocation()
                            if loc then x, y, z = loc.X or 0, loc.Y or 0, loc.Z or 0 end
                        end)
                        table.insert(by_series[sname].problems, {
                            aidx = aidx,
                            hidden = hidden,
                            coll = coll,
                            warded_tracked = M._books_warded[key] and true or false,
                            is_unmapped = M._unmapped_warded_books[key] and true or false,
                            x = x, y = y, z = z,
                        })
                    end
                end
            end
        end
    end

    local names = {}
    for s in pairs(by_series) do names[#names+1] = s end
    table.sort(names, function(a, b)
        local sa, sb = by_series[a].section, by_series[b].section
        if sa ~= sb then return sa < sb end
        return a < b
    end)

    local total_problems = 0
    for _, b in pairs(by_series) do total_problems = total_problems + #b.problems end
    log(("DUMP unlocked-state: %d unlocked series with books in level, %d UNPICKABLE book(s)"):format(
        #names, total_problems))
    for _, sname in ipairs(names) do
        local b = by_series[sname]
        if #b.problems > 0 then
            log(("  [%s] '%s' UNPICKABLE: %d / %d"):format(
                b.section, sname, #b.problems, b.total))
            for _, p in ipairs(b.problems) do
                log(("      aidx=%d hidden=%s coll=%s _warded=%s unmapped=%s @ (%.0f, %.0f, %.0f)"):format(
                    p.aidx,
                    tostring(p.hidden), tostring(p.coll),
                    tostring(p.warded_tracked), tostring(p.is_unmapped),
                    p.x, p.y, p.z))
            end
        else
            log(("  [%s] '%s' OK: %d book(s) pickable"):format(b.section, sname, b.total))
        end
    end
end

--- Print every book with no HISM canonical (renders at its actor position, possibly inside
--- a wall). Verifies the stuck set is the same across runs. Coords in cm; 'unlocked' = unwarded now.
function M.dump_unmapped_books()
    local entries = {}
    for _, ud in pairs(M._unmapped_warded_books) do entries[#entries + 1] = ud end
    if #entries == 0 then
        log("DUMP unmapped: 0 books (all warded books have HISM canonicals — nothing should appear stuck)")
        return
    end
    table.sort(entries, function(a, b)
        if a.section ~= b.section then return (a.section or "?") < (b.section or "?") end
        if a.series  ~= b.series  then return (a.series  or "?") < (b.series  or "?") end
        return (a.asset_idx or 0) < (b.asset_idx or 0)
    end)
    log(("DUMP unmapped: %d book(s) with no HISM canonical (may appear stuck when unwarded):"):format(#entries))
    for _, ud in ipairs(entries) do
        local unlocked = M._series_unlocked[ud.series] and "UNLOCKED" or "warded"
        log(("  [%s] '%s' aidx=%d @ (%.0f, %.0f, %.0f) [%s]"):format(
            ud.section or "?", ud.series or "?", ud.asset_idx or 0,
            ud.x or 0, ud.y or 0, ud.z or 0, unlocked))
    end
end

-- ============================================================================
-- Debug console commands
-- ============================================================================
-- Force-unward every book whose series name contains a substring (case-insensitive),
-- bypassing slot_data / _series_unlocked. Clears the tracker so a normal apply won't re-ward
-- this session; leaves _shelves_open / case covers alone (for testing fence-collision grabs).
--   Usage: ap_unward_series Seduction Magic
function M.force_unward_series(pattern)
    if type(pattern) ~= "string" or pattern == "" then
        log("[ap_unward] usage: ap_unward_series <series-name-substring>")
        return 0
    end
    local pat_lower = pattern:lower()
    local matched_aidx = {}
    for aidx, sname in pairs(M._asset_to_series) do
        if sname:lower():find(pat_lower, 1, true) then
            matched_aidx[aidx] = sname
        end
    end
    if not next(matched_aidx) then
        log(("[ap_unward] no series matching '%s'"):format(pattern))
        return 0
    end
    for aidx, sname in pairs(matched_aidx) do
        log(("[ap_unward] matched: '%s' (aidx=%d)"):format(sname, aidx))
    end
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return 0 end
    local n = 0; pcall(function() n = #books end)
    local count = 0
    for i = 1, n do
        local book = books[i]
        if book and book:IsValid() then
            local aidx = _book_valid_asset_idx(book)
            if aidx and matched_aidx[aidx] then
                pcall(function()
                    book:SetActorHiddenInGame(false)
                    book:SetActorEnableCollision(true)
                end)
                M._books_warded[book:GetFullName()] = nil
                count = count + 1
            end
        end
    end
    log(("[ap_unward] force-unwarded %d book(s) across %d series"):format(
        count, (function() local k = 0; for _ in pairs(matched_aidx) do k = k + 1 end; return k end)()))
    return count
end

RegisterConsoleCommandHandler("ap_unward_series", function(_, params)
    -- UE4SS passes params as space-split tokens; rejoin for multi-word series names.
    local pattern = ""
    if type(params) == "table" then
        pattern = table.concat(params, " ")
    elseif type(params) == "string" then
        pattern = params
    end
    pcall(function() M.force_unward_series(pattern) end)
    return true
end)

-- Start the serialized ward pump (drains every game-thread warding marshal one at a
-- time; see _on_game_thread above). Safe at module load -- it ticks idle until warding
-- begins, and covers the connect-time burst at the title before gameplay.
M._ward_pump_start()

return M
