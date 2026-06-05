-- AP/ItemApply.lua
-- Translates received AP items into game-state mutations.
--
-- SCOPE:
--   • Books warded by SERIES. A book is unwarded iff its series is in
--     `_series_unlocked`. "Warding" = SetActorHiddenInGame(true) +
--     SetActorEnableCollision(false): title text disappears and pickup is
--     blocked, while the mesh remains as a visible "stack" on the shelf.
--   • Bookcase visibility per section: bookcases sorted by BookOrderIdx;
--     visible_count = _shelves_open[section]. Each Progressive Shelf
--     Unlock (X) reveals one more bookcase in section X.
--   • Major Magic level items are granted by calling UpgradePlayer(idx)
--     on the player. _ap_grant guards against the UpgradePlayer hook in
--     main.lua echoing the call back as a location check.
--   • Minor Magic abilities (Crimson/Emerald/Azure/Golden) are NOT items —
--     the player gets each ability natively from the in-world chest the
--     matching key opens. The chest opening is tracked as a location check.
--
-- DERIVED STATE shape:
--   _series_unlocked   = { [series_name] = true } from N Progressive Series
--                        Unlock items × series_per_unlock; indexes
--                        slot_data.series_order.
--   _shelves_open      = { [section_id] = open_count } from per-section
--                        Progressive Shelf Unlock items. A section is
--                        "active" iff _shelves_open[X] >= 1; visible bookcase
--                        count for X = _shelves_open[X].

local M = {}

local LOG_PREFIX = "[ItemApply]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

-- Crash-hunt instrumentation (see AP/trace.lua, diag_flags.lua, CRASH_HANDOFF.md).
-- trace = durable flushed breadcrumb ledger; _diag_on = bisection switches (default on).
-- Both pcall-guarded so a missing module never breaks ItemApply.
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

-- _on_game_thread(fn, flag): run fn on the GAME THREAD via ExecuteInGameThread.
-- UE4SS LoopAsync callbacks run on a SEPARATE async thread (only RegisterHook /
-- NotifyOnNewObject run on the game thread), so warding writes fired from there
-- race the engine's collision / render / cluster-tree workers that read the same
-- components -- the lead crash suspect (see CRASH_HANDOFF.md, main.lua on_game_thread).
-- `flag` gates the marshal for A/B bisection; falls back to inline (the OLD off-thread
-- behavior) when the flag is false or ExecuteInGameThread is unavailable, so a missing
-- global can never break mod loading.
local function _on_game_thread(fn, flag)
    if _diag_on(flag) and type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(fn)
    else
        fn()
    end
end

-- ============================================================================
-- Constants (mirrors apworld/librarian/data.py::UpgradeAbility)
-- ============================================================================

-- AP location ID layout (mirrors apworld/librarian/Locations.py)
local AP_BASE              = 1910000
local AP_LOC_SECTION_FIRST = AP_BASE + 500   -- 31 entries: section completions
local AP_LOC_FLOOR_FIRST   = AP_BASE + 550   -- 2 entries: Floor 1, Floor 2
local AP_LOC_LEVEL_FIRST   = AP_BASE + 560   -- 45 entries: Level 1..45
local AP_LOC_MILESTONE_FIRST = AP_BASE + 640 -- 22 entries: aligned to MILESTONE_THRESHOLDS order
local AP_LOC_ROW_COMPLETION_FIRST = AP_BASE + 1000 -- 50 entries: aligned to ROW_COMPLETION_THRESHOLDS order
local AP_MAX_PLAYER_LEVEL  = 45

-- section_id → ordinal position in data.SECTIONS (apworld/librarian/data.py).
-- Used as a fallback when slot_data doesn't ship section_location_map
-- (legacy 1.0.x seeds generated before the section-completion fix). The
-- AP location id for "Section Complete: <id>" is AP_LOC_SECTION_FIRST +
-- SECTION_IDX[id]. Keep in lockstep with the SECTIONS tuple ordering.
local SECTION_IDX = {
    ["1A"] =  0, ["1B"] =  1, ["1C"] =  2, ["1D"] =  3, ["1E"] =  4,
    ["1F"] =  5, ["1G"] =  6, ["1H"] =  7, ["1I"] =  8, ["1J"] =  9,
    ["1K"] = 10, ["1L"] = 11, ["1M"] = 12, ["1N"] = 13,
    ["2A"] = 14, ["2B"] = 15, ["2C"] = 16, ["2D"] = 17, ["2E"] = 18,
    ["2F"] = 19, ["2G"] = 20, ["2H"] = 21, ["2I"] = 22, ["2J"] = 23,
    ["2K"] = 24, ["2L"] = 25, ["2M"] = 26, ["2N"] = 27, ["2O"] = 28,
    ["2P"] = 29, ["2Q"] = 30,
}

-- floor number → ordinal offset within AP_LOC_FLOOR_FIRST. Used as a
-- fallback when slot_data doesn't ship floor_location_map (pre-1.0.4
-- seeds). Floor 1 → loc 1910550, Floor 2 → loc 1910551.
local FLOOR_IDX = {
    [1] = 0,
    [2] = 1,
}

-- Cumulative XP curve, mirrored from apworld/librarian/data.py:XP_CURVE.
-- Used as a fallback for run_baseline_sync's level-up catch-up when
-- player.SkillLevelUpRowNum isn't accessible at baseline time. The live
-- BP read remains the primary source — this is just so the baseline
-- doesn't silently compute xp_level=0 for a player who has 14 rows
-- finished offline. Keep in lockstep with data.py XP_CURVE.
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

-- AP item name → UpgradeAbility index. Major Magic items are progressive
-- (each instance bumps level by 1 via UpgradePlayer).
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

-- True around AP-driven UpgradePlayer calls so the UpgradePlayer hook in
-- main.lua doesn't echo the call back as a location check.
M._ap_grant = false

-- True once we have BOTH slot_data + asset_data and can apply items to world.
-- Until set, items still increment _received_counts but no game-state
-- mutation runs.
M._initialized = false

-- True only while the player is in actual gameplay (not title screen).
-- Set by main.lua's LoadMap hook via set_gameplay_active(). Mutations to
-- world (book ward / skill grant) are GATED on this — touching actors at
-- the title screen has been observed to crash the game.
M._gameplay_active = false

-- Pre-apply: when true, flush_apply is allowed at the post-connect title
-- screen so warding completes BEFORE the player clicks Continue. The
-- Continue/Start buttons in main.lua are kept disabled until
-- _pre_apply_complete flips true, which the settle loop sets after the
-- deferred tree-walk queue has drained and stayed empty.
M._allow_pre_apply = false
M._pre_apply_complete = false

-- Counter bumped every apply_item call. The pre-apply settle loop
-- watches this for "items have quieted down": once N ticks pass without
-- the counter advancing, the starting-item dump is considered complete
-- and the settle loop fires the single world-mutating flush_apply with
-- the FINAL state (instead of N wasteful per-item flushes).
M._last_item_apply_tick = 0

-- Mid-gameplay reconnect window. When the player disconnects then
-- reconnects WHILE PLAYING, the AP server re-sends every received item
-- one at a time. Without this flag, each apply_item would call
-- flush_apply on partial state (most shelves not yet re-unlocked),
-- causing every bookcase to flash to hidden and the placed books to
-- look stranded until the next 5-second re-apply rebuilds the world.
--
-- Set true by set_slot_data() when it fires mid-gameplay; cleared by
-- main.lua's reconnect-settle watcher once items quiet down. While
-- true, apply_item only recomputes state and skips flush_apply — the
-- watcher fires ONE flush_apply at the end with the fully rebuilt state.
M._reconnect_settle_active = false

-- Skill grants requested while not in gameplay queue here and replay on
-- the gameplay-active transition.
M._pending_skill_grants = {}

-- Tracks how many times we've successfully bumped each skill via
-- UpgradePlayer. Initialised from the save's PlayerExtraData.SkillData
-- when apply-safe fires (so already-applied levels don't re-trigger on
-- reconnect). Increments on each successful bump.
M._applied_skill_counts = {}

-- Even with _gameplay_active=true and books spawned, mutating book actors
-- immediately after LoadMap has crashed the game (book sub-levels still
-- streaming or actor init not finished). Independent flag set true ONLY
-- after a generous post-LoadMap delay + initialization sanity check.
M._apply_safe = false

-- Bookcase index built at apply-time. Maps section_id → array of unique
-- bookcase actors derived from BP_BookCase_C's CorrectBookDataIndex[1] →
-- AssetIdx → section. Reset whenever we leave gameplay (cases get torn
-- down on level reload).
M._section_to_cases = {}
M._cases_indexed    = false

-- Reverse lookup: bookcase actor key → section_id. Built alongside index.
M._case_to_section  = {}

-- Last-logged "Bookcases: shown=X hidden=Y dead=Z" string. We compare current
-- state against this and only log when it changes — the periodic re-apply
-- runs every 5s and was spamming the log with identical lines.
M._last_apply_log_key = nil

-- Already-sent row location IDs in this session (de-dupe defense).
M._sent_row_locations = {}

-- Already-fired row-completion thresholds in this session (de-dupe defense).
-- Keyed by threshold value (matches slot_data.row_completion_thresholds entries).
M._sent_row_completions = {}

-- Already-fired "Section Complete: <id>" sections this session (de-dupe
-- defense, keyed by section_id). Section completion fires when every
-- row location in that section is in _sent_row_locations.
M._sent_section_completions = {}

-- section_id → list of row location IDs in that section. Built once from
-- slot_data.row_location_map at slot-data setup so check_section_completions
-- can iterate cheaply.
M._section_to_row_locs = {}

-- Already-fired "Floor N Complete" floors this session (de-dupe defense,
-- keyed by integer floor number 1 or 2). Floor completion fires when
-- every row location across the floor's active sections is in
-- _sent_row_locations.
M._sent_floor_completions = {}

-- floor number (int) → list of row location IDs in that floor's active
-- sections. Built from _section_to_row_locs at slot-data setup. For
-- floor-goal seeds, only the active floor has an entry (the inactive
-- floor has no rows in row_location_map and so contributes nothing).
M._floor_to_row_locs = {}

-- Highest player level we've sent a "Reached Level N" check for. Synced
-- from max of: (a) XP curve vs GameSaveData.CurrentFinishedRowNum,
-- (b) APClient._sent_checks (server's view of prior sessions). Max
-- guards against stale GameSaveData at baseline time. Subsequent
-- level-ups arrive via the OnLevelUp BP hook → on_level_up_event(),
-- which catches up from _sent_checks before incrementing — self-heals
-- if baseline missed. (Reading CurrentFinishedRowNum at OnLevelUp time
-- is unreliable — the field hasn't updated yet when the event fires.)
M._levels_reached = 0
M._level_baseline_done = false

-- Milestone thresholds we've already sent checks for (set { [threshold] = true }).
M._milestones_sent = {}



-- "Stray" BookCase actors found in the level that aren't referenced by any
-- CabinetLabel's CountBookCase array. These appear to be level-design
-- artifacts — bookcases tucked into walls / corners that don't belong to
-- any section but are still real BookCase actors. They were never indexed
-- (and so never hidden/collision-disabled), and the game's placement system
-- can still find them by aim angle, causing a softlock when the player
-- places a book they can't retrieve. Collected once during _index_bookcases
-- and permanently kept hidden + collision-off by _apply_bookcases_to_world.
M._stray_cases = {}

-- One-shot guard: baseline sync (rows/levels/milestones) runs only on the
-- first detected player movement after entering gameplay. The title screen
-- has the previous save loaded behind the scenes; reading GameSaveData at
-- apply-safe time can return stale values. Movement is a reliable signal
-- that the new save state has fully taken over in-memory.
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

--- Called by main.lua's APClient.on_slot_connected. Stores the seed-specific
--- orderings and resets per-connection state. AP will re-send all received
--- items on (re)connect, so we reset _received_counts to avoid double-counts.
function M.set_slot_data(slot_data)
    M._slot_data = slot_data
    -- book_visibility mode (BookVisibility option). true = HIDE warded books ("hidden", the
    -- default); false = "stacks" = keep them VISIBLE but non-grabbable. The three live hide
    -- paths gate on this -- layer-1 actor ward (below), the SetActorVisible ENFORCE hook, and
    -- the HISM-pile apply_book_visibility -- so in stacks they skip hiding and only collision-off
    -- remains. "~= stacks" so any missing/unknown value defaults to the safe legacy hide.
    M._book_hide_mode = (slot_data and slot_data.book_visibility ~= "stacks")
    M._received_counts    = {}
    M._series_unlocked    = {}
    M._shelves_open       = {}
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

    -- (beta7: the v1.0.2/v1.0.3 warding-rule version gate was removed. Off now
    -- uniformly unwards every received series regardless of bookcase -- see
    -- M._compute_unwarded_set -- so the old shelf-req floor and the
    -- _use_v103_warding split no longer exist. On mode is unchanged across versions.)
    log("slot_data version=" .. tostring(slot_data.version or "?"))

    -- Derived lookups built from asset_idx_to_series.json + slot_data so
    -- the per-book warding decision is cheap. Built once on slot_connect
    -- since the underlying data is per-seed.
    --   _series_to_section[name] = section_id
    --   _series_to_asset_idx[name] = numeric AssetIdx (for any future
    --                                  asset-ordered tiebreaks)
    --   _section_bookcase_count[sid] = how many bookcases that section has
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

    -- Build section_id → list of row location IDs from row_location_map keys.
    -- Used by fire_section_completions() to determine when all rows of a
    -- section are complete. Skipped for seeds without row_location_map.
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
    -- _section_to_row_locs. Section IDs are encoded as "<floor><letter>"
    -- (e.g. "1A", "2Q"), so the first character is the floor number.
    -- Floor-goal seeds only have one floor's worth of sections in
    -- _section_to_row_locs, so the other floor naturally drops out (its
    -- "Floor N Complete" location isn't in the pool either, per
    -- create_regions's active_floor_locs filter).
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
    -- Allow pre-apply: the OpenLevel-on-connect that main.lua fires right
    -- after this will trigger a fresh M01 LoadMap → apply-gate retry loop.
    -- main.lua's title-button logic keeps Continue disabled until
    -- _pre_apply_complete flips true (after the deferred tree-walk drains).
    M._allow_pre_apply = true
    M._pre_apply_complete = false

    -- Mid-gameplay reconnect: AP server is about to re-send every item the
    -- player already received. Without this flag, each apply_item would
    -- call flush_apply with partial state (zero shelves open at first,
    -- then 1, then 2, ...), causing every bookcase to flicker to hidden.
    -- main.lua's reconnect-settle watcher fires ONE flush_apply once items
    -- quiet down and clears this flag.
    if M._gameplay_active then
        M._reconnect_settle_active = true
        log("Slot data set; per-connection state reset; reconnect-settle window opened (mid-gameplay)")
    else
        M._reconnect_settle_active = false
        log("Slot data set; per-connection state reset; pre-apply enabled")
    end

    -- Goal-scope verification: log series_order's section coverage so the
    -- player can confirm at-a-glance that no off-floor series can be
    -- unlocked. The Python apworld filters series_order to active sections,
    -- and _recompute_state() only ever sets _series_unlocked[s] for s in
    -- series_order — so this log is the authoritative truth.
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

--- Called by main.lua's APClient.on_disconnected. Clears pre-apply state
--- so a subsequent reconnect starts fresh.
function M.clear_pre_apply()
    M._allow_pre_apply = false
    M._pre_apply_complete = false
end

--- Called by main.lua's LoadMap hook. Toggles whether world mutations are
--- safe to perform. On the title→gameplay transition we replay any queued
--- skill grants. World apply does NOT happen here — main.lua's LoadMap
--- retry loop calls set_apply_safe(true) + flush_apply() only after the
--- book sub-levels have streamed in and ItemInfo is populated for many
--- distinct AssetIdx values. See _apply_safe comment.
function M.set_gameplay_active(state)
    state = state and true or false
    if M._gameplay_active == state then return end
    M._gameplay_active = state
    log(("Gameplay-active: %s"):format(tostring(state)))

    if not state then
        -- Leaving gameplay (title screen / level transition): book actors
        -- are about to be torn down or already gone. Force the next entry
        -- to re-prove safety before mutating again. Same goes for the
        -- bookcase index — actor pointers won't survive the level reload.
        if M._apply_safe then
            log("Resetting _apply_safe (left gameplay)")
            M._apply_safe = false
        end
        -- Reset baseline sync so the next gameplay entry waits for a fresh
        -- first-movement signal again.
        M._baseline_sync_done = false
        if M._cases_indexed then
            log("Clearing bookcase index (left gameplay)")
            M._section_to_cases = {}
            M._case_to_section = {}
            M._stray_cases = {}
            M._last_apply_log_key = nil
            M._cases_indexed = false
            -- WardCover actors (v1.1.0) are tied to the old world's case
            -- actors; both are destroyed when the world unloads. Just
            -- drop our refs so the next apply re-spawns fresh covers.
            M._case_covers = {}
        end
        -- Warding + sign-glow trackers are keyed to the old world's actors and to
        -- our last-applied state. Drop them so the next gameplay entry (Continue,
        -- which may not fully reload) re-wards every case and re-glows every sign
        -- from scratch instead of apply-on-change skipping them as "unchanged".
        M._case_ward_state = {}
        M._case_placement_mesh = {}   -- stale (old world's components)
        M._section_to_label = nil
        M._section_glow_state = {}
        M._section_glow_orig = {}
        -- Drop pending skill grants — they'll be re-queued on the next
        -- slot_connect via set_slot_data's reset + AP item re-dump.
        if #M._pending_skill_grants > 0 then
            log(("Clearing %d pending skill grants (left gameplay)"):format(#M._pending_skill_grants))
            M._pending_skill_grants = {}
        end
    end
    -- Entering gameplay: glow the locked signs promptly instead of waiting for the
    -- periodic loop (no-op if not yet apply-safe; the loop is the backstop).
    M._maybe_glow_now()
end

--- Called by main.lua's LoadMap retry loop after the book sub-levels have
--- streamed in and ItemInfo is populated for many distinct AssetIdx values.
--- Until this is true, flush_apply() recomputes derived state but doesn't
--- touch any actors.
---
--- Also drains any queued skill grants — UpgradePlayer silently no-ops
--- when called before the player+world are fully wired, so grants made
--- pre-apply-safe stay at level 0 even after retries.
function M.set_apply_safe(state)
    state = state and true or false
    if M._apply_safe == state then return end
    M._apply_safe = state
    log(("Apply-safe: %s"):format(tostring(state)))
    if state then
        -- Save is loaded and stable here — read its skill levels into the
        -- applied counter BEFORE draining queued grants, so already-applied
        -- skills (from a prior session) get a correct baseline and aren't
        -- re-bumped by AP's reconnect item dump.
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

    -- Skill items: grant via UpgradePlayer immediately. Doesn't depend on
    -- slot_data / asset_data being loaded.
    if SKILL_ITEM_TO_ABILITY[name] then
        M._apply_skill(name)
    end

    -- Section / Series / Shelf items: affect derived state. Require slot_data.
    if not M._initialized then
        log(("queued (not initialized): %s × %d"):format(name, M._received_counts[name]))
        return
    end
    -- Defer the world-apply during two settle windows:
    --   • Pre-apply (post-connect title): 14+ starting items; per-item
    --     flush is wasteful (each iterates all 3072 books) and visually
    --     flickers. main.lua's pre-apply settle loop fires ONE
    --     flush_apply once items quiet, with the FINAL state.
    --   • Reconnect settle (mid-gameplay): AP re-sends all received
    --     items on reconnect; per-item flush would hide every bookcase
    --     mid-rebuild. main.lua's reconnect-settle watcher fires ONE
    --     flush_apply once items quiet, clearing the flag.
    -- recompute_state() still runs so counters track during the defer.
    if (M._allow_pre_apply and not M._gameplay_active)
            or M._reconnect_settle_active then
        M._recompute_state()
        return
    end
    M.flush_apply()
end

--- Recompute derived state and apply to world. Idempotent.
--- World mutations are gated on _gameplay_active AND _apply_safe. The
--- former filters out the title screen; the latter is a stronger signal
--- that book sub-levels have actually finished streaming, set by main.lua
--- only after a delay + initialization probe. State recomputation always
--- runs so the in-memory state is correct when apply does fire.
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
    -- Bookcases first: SetActorHiddenInGame on ~71 actors is fast and gives
    -- the player immediate visual feedback that warding is happening. Books
    -- afterward — the per-book tree-walk hide queue drains in the background
    -- over several seconds, but locked sections are already out of sight.
    M._apply_bookcases_to_world()
    M._apply_books_to_world()
    -- NOTE: baseline syncs (rows, levels, milestones) are NOT done here.
    -- The title menu loads the previous save behind the scenes, so reading
    -- GameSaveData at apply-safe time can return stale values. Baseline
    -- syncs run via M.run_baseline_sync() which main.lua triggers on first
    -- detected player movement (a reliable "we're truly in gameplay" signal).
end

-- Called by main.lua's movement-detection loop after the player physically
-- moves for the first time post-load. By that point GameSaveData reflects
-- the actually-loaded save (Continue path) or the fresh state (New Game),
-- so the baseline read is safe.
function M.run_baseline_sync()
    if M._baseline_sync_done then return end
    M._baseline_sync_done = true

    local row_synced = 0
    pcall(function() row_synced = M.detect_completed_rows() end)
    if row_synced and row_synced > 0 then
        log(("Row baseline sync: sent %d check(s) for already-completed rows"):format(row_synced))
    end

    -- Hydrate _sent_row_locations from the server's view of checked
    -- locations so fire_section_completions() can recognize sections that
    -- were fully completed in a prior session. Without this, a player
    -- who finished a section in session A and reconnects in session B
    -- would never get the Section Complete check — detect_completed_rows
    -- correctly skips already-checked row locs (so they aren't resent),
    -- but they also never get added to _sent_row_locations in session B
    -- without a separate sync.
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

    -- Read the game's CurrentFinishedRowNum and fire any
    -- "Complete N Rows" thresholds the saved game has already passed.
    -- Without this, a save loaded mid-run would silently skip those
    -- milestones (FinishRow only fires for NEW row completions).
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

    -- Level-up baseline. Compute current level as max of:
    --   • xp_level   — walk player.SkillLevelUpRowNum vs rows_finished
    --     (correct when GameSaveData + player BP are loaded).
    --   • sent_level — highest level location already in
    --     APClient._sent_checks (server-populated at slot_connect,
    --     works even when GameSaveData isn't ready).
    --
    -- Without _sent_checks as a floor, _levels_reached resets to 0 on
    -- reconnect; the first OnLevelUp queues "Reached Level 1" which
    -- the server dedupes, and the actual new level never gets sent
    -- because every earlier attempt was deduped.
    --
    -- We also re-send checks for every level <= current_level (server
    -- dedupes; belt-and-suspenders for prior-session disconnects).
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
    -- Static-curve fallback: if the BP read returned 0 (player BP not
    -- fully resolved despite first-movement having fired, or the array
    -- read errored), recompute from the hardcoded XP_CURVE so we still
    -- credit every level the player has earned offline. Mirrors the
    -- runtime values verified against the in-game SkillLevelUpRowNum
    -- dump.
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

    -- Series: series_order[1..N*per_unlock]
    M._series_unlocked = {}
    local series_count = M._received_counts["Progressive Series Unlock"] or 0
    local per_unlock = M._slot_data.series_per_unlock or 5
    local series_order = M._slot_data.series_order or {}
    local total_series = math.min(series_count * per_unlock, #series_order)
    for i = 1, total_series do
        M._series_unlocked[series_order[i]] = true
    end

    -- Shelf unlocks (per-section open_count). One per bookcase received.
    M._shelves_open = {}
    for item_name, count in pairs(M._received_counts) do
        local section_id = item_name:match("^Progressive Shelf Unlock %((.+)%)$")
        if section_id then
            M._shelves_open[section_id] = count
        end
    end
end

-- ============================================================================
-- Apply: Books
-- ============================================================================

--- Return the BP_GrabbingBook_C actor's AssetIdx if initialized, or
--- nil if it's an orphan with default ItemInfo.
---
--- AssetIdx=0 is a VALID asset ("Monsterology: An Introduction to
--- Forbidden Beast", section 1A's first series). Gating on `AssetIdx > 0`
--- would leave its 10 books permanently un-warded. We disambiguate via
--- ItemInfo.Mesh: real books have a populated UStaticMesh*; orphans
--- from the OpenLevel-on-connect reload leave it nil. AssetIdx > 0 is
--- trusted directly — a default-constructed ItemInfo can't produce a
--- non-zero index.
local function _book_valid_asset_idx(book)
    if not book or not book:IsValid() then return nil end
    local info; pcall(function() info = book.ItemInfo end)
    -- Also IsValid the ItemInfo sub-UObject. Crash reports (Failure.Hash
    -- e40fc030...) faulted inside UE4SS reflection reading sub-UObject
    -- properties — book:IsValid() alone is not enough; ItemInfo can be
    -- a stale ref and the next .AssetIdx read crashes in IsA on garbage
    -- (pcall doesn't catch native AVs). Guards nine downstream call sites.
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

--- Recursively walk a SceneComponent tree and apply visibility to each
--- node. Setting bHiddenInGame alone doesn't always trigger a render-
--- proxy refresh in UE 5.5 — the property flips but the cached scene
--- proxy keeps drawing. MarkRenderStateDirty forces invalidation.
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

-- v1.1.0 Option 2c: ward via the bookcase's OWN StaticMesh collision — no runtime
-- spawn, so no `(async)` world-leak crash. Refinement history (2026-05-30):
--   2a  mesh OFF + `Box` set to block → FAILED: books + player passed through
--       (the `Box` doesn't cover the footprint).
--   2b  mesh PhysicsOnly → books bounce + un-interactable, BUT the player still
--       walks through: character movement is a QUERY sweep (Pawn channel), and
--       PhysicsOnly turns queries off. Placement is also a query, so we can't
--       just turn queries back on (that re-enables placement).
--   2c  InvisibleWall profile → FAILED: locked cases became placeable. Placement
--       does NOT trace on Visibility (InvisibleWall blocks every channel except
--       Visibility, yet placement came back). But the log resolved the real
--       structure: TWO StaticMeshComponents — "StaticMesh" (solid body) and
--       "PreviewBookLocation" (the named placement target).
--   2d  Toggle ONLY "PreviewBookLocation" off, body left solid → FAILED: still
--       placeable (preview_orig_enabled=1, so it WAS a collider, yet off didn't
--       gate placement). So the placement trace hits the BODY, not the preview
--       (2b body-query-off blocked placement; 2d body-query-on allowed it).
--   2e  Per-channel responses (probe-confirmed, camera-resp 2→0): each LOCKED
--       solid StaticMesh → QueryAndPhysics, BLOCK object channels (Pawn player +
--       PhysicsBody/WorldDynamic books), IGNORE trace channels (Visibility/Camera/
--       Game) so the placement line-trace misses → solid AND un-interactable.
--       UNLOCKED → restore the captured profile. WORKS on regular/small cases.
--       Large cases have MULTIPLE placement meshes, so treat ALL StaticMeshComponents
--       (single-mesh left large cases placeable at angles hitting an unhandled
--       mesh); `[ward-collision] N static meshes` logs each distinct structure.
--       RISK: if placement uses TraceByObjectType (an object channel) rather than
--       a trace channel, cases stay placeable → fall back to 2b PhysicsOnly.
local function _ward_collision(case, case_key, locked)
    if not (case and case:IsValid()) then return end
    -- Actor-level collision MUST be on or per-component settings are ignored.
    pcall(function() case:SetActorEnableCollision(true) end)

    -- 2e (multi-mesh): the placement trace + the player sweep hit the bookcase
    -- BODY, and the probe confirmed UE4SS can set per-channel responses. Large
    -- bookcases have MORE than one placement-relevant StaticMeshComponent, so we
    -- treat them ALL (the single-mesh version left large cases placeable at angles
    -- hitting an unhandled mesh). LOCKED: each solid mesh → QueryAndPhysics, BLOCK
    -- object channels (Pawn = player, PhysicsBody/WorldDynamic = thrown books),
    -- IGNORE trace channels (Visibility/Camera/Game) so the placement line-trace
    -- misses → solid yet un-interactable. UNLOCKED: restore each mesh's captured
    -- profile (placement works at every angle again). NoCollision meshes untouched.
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
        -- Skip the small PreviewBookLocation marker: it isn't the placement target
        -- and doesn't block, so warding it just wastes calls.
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
            -- Capture the per-channel responses too (cheap reads), so UNLOCK can
            -- restore the EXACT original instead of a blanket block-all. Block-all
            -- breaks multi-mesh cabinet cases: it makes the cabinet body/wall block
            -- the placement trace, which originally passed THROUGH them to the inner
            -- shelf -> the cabinet stays un-placeable even when "unwarded".
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

    -- Identify the PLACEMENT mesh: the shelf surface the placement line-trace must hit.
    -- Normally the component named "StaticMesh" (the inner shelf, present in standard
    -- shelves AND as the inner shelf of multi-mesh cabinets). For a SINGLE-mesh case the
    -- sole mesh IS the placement target even when it is NOT named "StaticMesh" -- that name
    -- assumption is exactly why 1M's 5-volume "second 5-book shelf" (a BP_BookCase_4x5_C
    -- whose mesh isn't named "StaticMesh") stuck un-placeable until reload: it fell to the
    -- per-channel restore of a stale capture instead of a block-all. We drive the placement
    -- mesh to a DETERMINISTIC state in BOTH directions, OUTSIDE the captured-collision gate,
    -- so a bad/partial capture can never strand it.
    local placement_idx = nil
    for i = 1, #meshes do
        local nm = "?"; pcall(function() nm = meshes[i]:GetFName():ToString() end)
        if nm == "StaticMesh" then placement_idx = i; break end
    end
    if not placement_idx and #meshes == 1 then placement_idx = 1 end

    -- Stash the placement mesh so the periodic ward pass can read its ACTUAL collision
    -- (Camera channel 4: Ignore=warded, Block=unwarded) as ground truth instead of
    -- re-mutating blindly. Cleared on real world reload (reset_hism_state).
    if case_key and placement_idx then
        M._case_placement_mesh = M._case_placement_mesh or {}
        M._case_placement_mesh[case_key] = meshes[placement_idx]
    end

    -- One-shot per case CLASS: log the unlock placement decision so any future stuck-shelf
    -- report names exactly which mesh/structure was used (and loudly flags the one case we
    -- cannot disambiguate: a multi-mesh case with no "StaticMesh").
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
        -- Safe enabled value for the placement mesh: the captured one if real, else
        -- QueryAndPhysics -- so a captured NoCollision (0) can't disable the shelf.
        local pen = (r.en and r.en ~= 0) and r.en or 3
        if locked then
            if is_placement then
                -- Always ward the placement mesh (deterministic Camera=Ignore), bypassing
                -- the captured-en gate so the ground-truth read + the unlock stay reliable.
                pcall(function() meshes[i]:SetCollisionEnabled(pen) end)
                pcall(function() meshes[i]:SetCollisionResponseToAllChannels(0) end)
                for _, ch in ipairs(OBJ_CHANNELS) do
                    pcall(function() meshes[i]:SetCollisionResponseToChannel(ch, 2) end)
                end
                M._ward_canary = meshes[i]
            elseif (r.en or 3) ~= 0 then
                -- Other meshes: same ~8-call ward (ignore all channels so the placement
                -- trace misses, then re-block the object channels so player + books bounce).
                pcall(function() meshes[i]:SetCollisionEnabled(3) end)
                pcall(function() meshes[i]:SetCollisionResponseToAllChannels(0) end)
                for _, ch in ipairs(OBJ_CHANNELS) do
                    pcall(function() meshes[i]:SetCollisionResponseToChannel(ch, 2) end)
                end
                M._ward_canary = meshes[i]
            end
        else
            if is_placement then
                -- UNLOCK the placement mesh UNCONDITIONALLY: solid + block-all so the
                -- placement trace always hits it, regardless of how good the capture was.
                -- (The old code only did this for a mesh literally named "StaticMesh", and
                -- only inside the captured-en gate -- the 1M stuck-shelf bug.)
                pcall(function() meshes[i]:SetCollisionEnabled(pen) end)
                pcall(function() meshes[i]:SetCollisionResponseToAllChannels(2) end)
            elseif (r.en or 3) ~= 0 then
                -- Structural meshes (cabinet body/wall): restore the captured original so
                -- the placement trace passes THROUGH them to the inner shelf -- block-all-ing
                -- them was the original cabinet bug.
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

--- Decompose UE FMatrix44f planes into a Lua FTransform table.
--- UE FMatrix is row-major; rows 0-2 are basis vectors (X/Y/Z axes
--- after rotation, scaled), row 3 is translation. We extract scale as
--- the magnitude of each basis vector, normalize, then convert the
--- 3x3 rotation matrix to a quaternion via Shoemake's algorithm.
local function _decompose_matrix(xp, yp, zp, wp)
    local sx = math.sqrt(xp.X*xp.X + xp.Y*xp.Y + xp.Z*xp.Z)
    local sy = math.sqrt(yp.X*yp.X + yp.Y*yp.Y + yp.Z*yp.Z)
    local sz = math.sqrt(zp.X*zp.X + zp.Y*zp.Y + zp.Z*zp.Z)
    if sx <= 1e-6 or sy <= 1e-6 or sz <= 1e-6 then return nil end

    -- Normalized rotation matrix (UE row-major: row i = basis vector i)
    local m00, m01, m02 = xp.X/sx, xp.Y/sx, xp.Z/sx
    local m10, m11, m12 = yp.X/sy, yp.Y/sy, yp.Z/sy
    local m20, m21, m22 = zp.X/sz, zp.Y/sz, zp.Z/sz

    -- Shoemake quaternion-from-matrix. Sign conventions chosen to
    -- produce a quat that, when passed back via FTransform, reproduces
    -- the original UE matrix. (Inverse of UE's FQuat→FMatrix path.)
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

--- Brute-force build per-book HISM mapping. The game's BookInfo →
--- (HISM, instance_idx) lookup table is internal to BP_HISM_Manager_C
--- and not exposed. We discover the mapping by:
---   1. Capture every HISM instance's current transform.
---   2. Mark each warded book by calling mgr.UpdateInstance(BookInfo, marker)
---      with a unique Z (-1000000 - book_idx) so each book ends up at
---      a distinct underground position we can identify by Z.
---   3. Scan all HISM instances; if transform.Z is in the marker range,
---      recover book_idx from Z and record book → original_transform.
---   4. For dupe-partner books (multiple BPs sharing a BookInfo), spawn
---      a fresh HISM instance via ModActor:AddHISMInstance so each loses
---      and gains an independent (HISM, idx) for hide/show.
---
--- After this runs, M._book_captured_transforms[book_full_name] holds
--- the natural HISM transform for every warded book. We use that for
--- showing previously-warded books (warded → unwarded transitions).
---
--- Only runs when slot_data.book_visibility == "hidden", the DEFAULT since beta7.
--- NOTE: this HISM-mapping pipeline is currently vestigial FOR HIDING -- Layer 3
--- (apply_book_visibility) + Pass 1 actor warding do the actual hiding, and its
--- refs now feed only init bookkeeping + the diagnostic dump. Kept pending a
--- gate-off verification before any wholesale removal (do NOT delete as "dormant").
M._hism_initialized = false
M._book_captured_transforms = {}         -- key → HISM original transform
M._books_we_have_hidden = {}             -- key → true if our hide moved this book
M._books_warded = {}                     -- key → true if actor.bHidden + collision-off applied

-- Diagnostic probe for B10 / B9. For each bookcase we touched on the
-- previous _apply_bookcases_to_world call, remember what we set
-- `bHidden` to. On the next apply, before writing, we compare the
-- case's current `bHidden` against this map and log `[bookcase-drift]`
-- if they disagree — gives us hard data on whether the game's BP tick
-- reverts our visibility flag.
--
-- Keyed by `case:GetFullName()`. Value is BOOLEAN bHidden (true =
-- hidden, false = visible).
M._case_last_applied_hidden = {}

-- v1.1.0 B10 fix: per-case WardCover actor reference. For each warded
-- bookcase, we spawn a BP_WardCover (chain-link fence overlay) via
-- ModActor:SpawnWardCover. Keyed by case:GetFullName(); value is the
-- spawned cover actor.
--
-- We KEEP the legacy SetActorHiddenInGame on the case itself (it can
-- stop working when the BP tick reverts, but doesn't hurt). The cover
-- is the durable visual ward — its tick is disabled at the
-- BP_WardCover class level so the game's BP can't revert it.
--
-- If the new pak isn't installed (no SpawnWardCover function), the
-- pcall fails silently and the case is managed by the legacy bHidden
-- path alone — degraded but functional.
M._case_covers = {}

-- Option 2 warding: per-case captured original component collision (keyed by
-- GetFullName). Cleared on world reload.
M._case_orig_collision = {}

-- Apply-on-change tracker: the last visible (lock) state we applied per case
-- (by GetFullName), so the warding only re-touches a case when its state
-- changes — perf + avoids racing the world teardown on quit. Cleared on reload.
M._case_ward_state = {}

-- Per-case placement-mesh ref (the shelf surface whose Camera-channel collision encodes
-- warded vs unwarded), stashed by _ward_collision. The periodic ward pass reads it as
-- GROUND TRUTH so an already-correct case is a no-op — no render-state churn (the crash
-- suspect) — while still catching drift within one pass. IsValid-guarded; dropped only on
-- a real world reload (refs go stale), NOT on the 5s re-index.
M._case_placement_mesh = {}

-- Diagnostic flags for v1.1.0 pak functions. Set true the first time we
-- successfully call into a new pak function so we don't spam the log.
-- The "_error" variants log the FIRST failure so we can diagnose
-- missing-function or argument-type-mismatch issues on the new pak.
M._diag_spawnwardcover_ok    = false
M._diag_spawnwardcover_err   = false
M._diag_pak_probed           = false
M._diag_no_modactor_logged   = false
M._diag_spawnwardcover_table_dumped = false
M._diag_geometry_dumped             = false

-- Books we couldn't HISM-map (no canonical and AddInstance failed). These
-- can't be hidden via HISM teleport — their mesh renders via the actor's
-- own mesh component at the actor's RootComponent world position. When
-- unwarded via SetActorHiddenInGame(false) + tree-walk visibility, they
-- become visible at that position, which can be inside walls/floors if
-- the level designer placed the actor at a trigger location (the visible
-- HISM instance is elsewhere on the shelf, but we lost the link to it).
-- Captured here so the user can verify which specific books are stuck
-- and confirm it's the same set across runs (deterministic level layout
-- → same stuck books every time).
M._unmapped_warded_books = {}  -- key → { asset_idx, series, section, x, y, z }

-- Snapshot of _series_unlocked from the last completed _apply_books_to_world.
-- Used to diff against the current state and log newly-unlocked series
-- when a Progressive Series Unlock is received.
M._last_applied_series_unlocked = {}

-- Deferred tree-walk queue. Tree-walking every warded book's component
-- tree synchronously costs ~24s for 3000 books (blocks main thread, AP
-- socket disconnects). Instead we enqueue books here and a LoopAsync
-- worker drains the queue ~50 books per tick. Books are first hidden
-- via actor.bHidden + HISM displacement (which catches most cases);
-- the deferred tree-walk catches the stragglers where actor.bHidden
-- doesn't propagate to a child component.
M._deferred_visibility_queue = {}  -- list of {book, visible}
M._deferred_worker_running = false

-- B7: chunked Pass-1 flush state.
--
-- _apply_books_to_world walks ~3000 book actors and toggles bHidden +
-- collision on each. Doing this in one tick blocks LoopAsync long
-- enough that AP times out on big item bursts (initial connect /
-- reconnect re-dump). We chunk the walk via LoopAsync so the poll
-- thread can pump c:poll() between chunks.
--
-- _flush_in_progress is set at chunk-1 start, cleared in the
-- post-Pass-1 finalizer. _flush_pending records "another flush was
-- requested while one was running" — the finalizer self-re-fires
-- if set so the newer state gets a fresh apply.
--
-- Pattern lifted from Crab Champions AP's _apply_pending_items /
-- FLUSH_BATCH chunking. See HANDOFF for design notes.
M._flush_in_progress = false
M._flush_pending     = false

local function _drain_visibility_queue()
    local q = M._deferred_visibility_queue
    local processed = 0
    -- Batch size tradeoff: bigger = faster total drain, but blocks the
    -- main thread longer per tick. 150 was measured at ~4ms/book × 150 =
    -- ~600ms per tick, which is still well under the AP socket-poll
    -- timeout (we observed disconnects only past ~3s blocking).
    while #q > 0 and processed < 150 do
        local entry = table.remove(q, 1)
        if entry and entry.book and entry.book:IsValid() then
            M._set_book_mesh_visible(entry.book, entry.visible)
        end
        processed = processed + 1
    end
    if #q == 0 then
        M._deferred_worker_running = false
        return true  -- stop loop
    end
    return false  -- keep draining
end

function M._queue_book_visibility(book, visible)
    M._deferred_visibility_queue[#M._deferred_visibility_queue + 1] = {
        book = book, visible = visible,
    }
    if not M._deferred_worker_running then
        M._deferred_worker_running = true
        LoopAsync(50, _drain_visibility_queue)
    end
end

--- Re-walk all known-warded books and re-queue them for tree-walk hide.
--- Catches drift cases: a component that wasn't fully streamed in at the
--- original apply time, or one that re-enabled itself somehow. Idempotent
--- — books already fully hidden just get their components re-set to
--- hidden (no-op at the engine level).
---
--- Only meaningful in "hidden" book_visibility mode; stacked mode doesn't
--- use tree-walk at all. Caller is expected to gate.
function M.requeue_warded_books_for_treewalk()
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return 0 end
    local n = 0
    pcall(function() n = #books end)
    local queued = 0
    for i = 1, n do
        local book = books[i]
        if book and book:IsValid() then
            local ok, key = pcall(function() return book:GetFullName() end)
            if ok and key and M._books_we_have_hidden[key] then
                M._queue_book_visibility(book, false)
                queued = queued + 1
            end
        end
    end
    return queued
end

--- Reset all HISM-mapping state. Called on every LoadMap into M01 —
--- a fresh world has fresh BP_GrabbingBook actors and fresh HISM
--- instances, so any captured transforms and book→hism mappings from
--- a previous world load are stale. The next apply-safe will re-run
--- _initialize_hism_book_mapping against the new world.
function M.reset_hism_state()
    -- World epoch: bumped on every world reset (this fires from the LoadMap hook on
    -- the game thread). Any DEFERRED game-thread closure that captured the OLD world's
    -- refs (notably layer 3's HISM array in apply_book_visibility) re-checks this and
    -- bails instead of dereferencing freed memory -- the main-menu / LoadMap teardown
    -- use-after-free (a NATIVE access violation, uncatchable by Lua pcall).
    M._world_epoch = (M._world_epoch or 0) + 1
    M._hism_initialized = false
    M._book_captured_transforms = {}
    M._books_we_have_hidden = {}
    M._books_warded = {}
    M._unmapped_warded_books = {}
    M._last_applied_series_unlocked = {}
    -- Bookcase drift tracking: also stale across world reloads since
    -- actor identities (UE GetFullName paths) change.
    M._case_last_applied_hidden = {}
    -- WardCover actors get destroyed by UE when the world reloads, so
    -- our references are dangling. Drop them. Next _apply_bookcases_to_world
    -- pass will re-spawn covers for warded sections.
    M._case_covers = {}
    -- Per-case captured component collision (Option 2 warding). Cases reload at
    -- their level-default collision and actor identities change, so drop the
    -- captures — the next apply pass recaptures and re-applies.
    M._case_orig_collision = {}
    M._case_ward_state = {}
    M._case_placement_mesh = {}
    -- Section-sign glow: re-built by the indexer each session; drop stale state so
    -- the new (post-reload) spotlights get re-glowed.
    M._section_to_label = nil
    M._section_glow_state = {}
    M._section_glow_orig = {}
    -- Bookcase index: the case refs point at the OLD world's actors. Keeping them
    -- both pins the old world (preventing GC) and makes the next warding pass
    -- operate on stale/invisible cases — so after Menu→Continue the visible new
    -- cases stay UN-warded. set_gameplay_active(false) clears these on a normal
    -- exit, but that path doesn't fire on the Menu→Continue LoadMap. Clear here too
    -- and force a fresh re-index against the new world.
    M._section_to_cases = {}
    M._case_to_section = {}
    M._stray_cases = {}
    M._cases_indexed = false
    M._ward_canary = nil
    log("[hism-reset] cleared HISM mapping state (will re-init on next apply-safe)")
end

function M._initialize_hism_book_mapping()
    if M._hism_initialized then return end

    local mgr = FindFirstOf("BP_HISM_Manager_C")
    if not mgr or not mgr:IsValid() then
        log("[hism-init] no BP_HISM_Manager_C — skipping")
        return
    end
    local hism_array
    pcall(function() hism_array = mgr.HISMArray end)
    if not hism_array then return end
    local hn = 0; pcall(function() hn = #hism_array end)
    if hn == 0 then return end

    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return end
    local bn = 0; pcall(function() bn = #books end)
    if bn == 0 then return end

    log(("[hism-init] brute-force mapping start: %d HISMs, %d books"):format(hn, bn))

    -- ONE-SHOT DIAGNOSTIC v2: enumerate class properties via reflection
    -- + probe BP_HISM_Manager. UE4SS exposes class->ForEachProperty so we
    -- can list every property name BP_GrabbingBook actually has, instead
    -- of guessing names that all return mystery UObject wrappers.
    if not M._diag_iteminfo_probed then
        M._diag_iteminfo_probed = true

        local sample_book = books[1]
        if sample_book and sample_book:IsValid() then
            -- 1. Control test: probe a clearly-bogus name. If it ALSO
            -- returns UObject:0x..., we know UE4SS returns wrappers for
            -- non-existent properties (and prior probe results were
            -- meaningless).
            local bogus
            pcall(function() bogus = sample_book.ThisDefinitelyDoesNotExist123 end)
            log(("[iteminfo-probe] CONTROL actor.ThisDefinitelyDoesNotExist123 = %s"):format(tostring(bogus)))

            -- 2. Enumerate the actor's class properties via reflection.
            local cls
            pcall(function() cls = sample_book:GetClass() end)
            if cls then
                local cls_name
                pcall(function() cls_name = cls:GetFullName() end)
                log(("[iteminfo-probe] actor class: %s"):format(tostring(cls_name)))
                -- ForEachProperty signature (UE4SS):
                --   class:ForEachProperty(function(prop) ... return LoopAction.Continue end)
                local prop_count = 0
                local ok_iter = pcall(function()
                    cls:ForEachProperty(function(prop)
                        local pn
                        pcall(function() pn = prop:GetFName():ToString() end)
                        if not pn then
                            pcall(function() pn = prop:GetName() end)
                        end
                        local cn
                        pcall(function() cn = prop:GetClass():GetFName():ToString() end)
                        log(("[iteminfo-probe]   actor-prop %s : %s"):format(
                            tostring(pn), tostring(cn)))
                        prop_count = prop_count + 1
                        return 0  -- LoopAction.Continue is typically 0
                    end)
                end)
                log(("[iteminfo-probe] actor properties iterated: ok=%s count=%d"):format(
                    tostring(ok_iter), prop_count))
            end

            -- 3. Same for ItemInfo struct.
            local info
            pcall(function() info = sample_book.ItemInfo end)
            if info then
                local icls
                pcall(function() icls = info:GetClass() end)
                if icls then
                    local icn
                    pcall(function() icn = icls:GetFullName() end)
                    log(("[iteminfo-probe] info class: %s"):format(tostring(icn)))
                    local ipc = 0
                    pcall(function()
                        icls:ForEachProperty(function(prop)
                            local pn
                            pcall(function() pn = prop:GetFName():ToString() end)
                            local cn
                            pcall(function() cn = prop:GetClass():GetFName():ToString() end)
                            log(("[iteminfo-probe]   info-prop %s : %s"):format(
                                tostring(pn), tostring(cn)))
                            ipc = ipc + 1
                            return 0
                        end)
                    end)
                end
            end
        end

        -- 4. Probe BP_HISM_Manager_C — find the BookInfo→(HISM,idx)
        -- lookup table that mgr:UpdateInstance(info, transform) uses.
        if mgr and mgr:IsValid() then
            local mcls
            pcall(function() mcls = mgr:GetClass() end)
            if mcls then
                local mcn
                pcall(function() mcn = mcls:GetFullName() end)
                log(("[iteminfo-probe] manager class: %s"):format(tostring(mcn)))
                local mpc = 0
                pcall(function()
                    mcls:ForEachProperty(function(prop)
                        local pn
                        pcall(function() pn = prop:GetFName():ToString() end)
                        local cn
                        pcall(function() cn = prop:GetClass():GetFName():ToString() end)
                        log(("[iteminfo-probe]   manager-prop %s : %s"):format(
                            tostring(pn), tostring(cn)))
                        mpc = mpc + 1
                        return 0
                    end)
                end)
                -- ALSO list manager FUNCTIONS (UFunctions). These are
                -- BP-callable methods. Maybe one is HideBook(info) or
                -- similar — would let us hide books without touching
                -- HISM instances directly.
                local mfc = 0
                pcall(function()
                    mcls:ForEachFunction(function(fn)
                        local fname
                        pcall(function() fname = fn:GetFName():ToString() end)
                        log(("[iteminfo-probe]   manager-fn %s"):format(tostring(fname)))
                        mfc = mfc + 1
                        return 0
                    end)
                end)
                log(("[iteminfo-probe] manager functions iterated: count=%d"):format(mfc))
            end
        end

        -- 5. Probe BP_GrabbingBook functions too.
        if sample_book and sample_book:IsValid() then
            local cls2
            pcall(function() cls2 = sample_book:GetClass() end)
            if cls2 then
                local afc = 0
                pcall(function()
                    cls2:ForEachFunction(function(fn)
                        local fname
                        pcall(function() fname = fn:GetFName():ToString() end)
                        log(("[iteminfo-probe]   actor-fn %s"):format(tostring(fname)))
                        afc = afc + 1
                        return 0
                    end)
                end)
                log(("[iteminfo-probe] actor functions iterated: count=%d"):format(afc))
            end
        end
    end

    -- Phase 1: capture every HISM instance's current transform. We'll
    -- need these to restore unwarded books later.
    local captured = {}  -- [hism_idx][instance_idx] = decomposed transform
    local cap_count = 0
    for i = 1, hn do
        local h = hism_array[i]
        if h and h:IsValid() then
            captured[i] = {}
            local sm_data; pcall(function() sm_data = h.PerInstanceSMData end)
            if sm_data then
                local sn = 0; pcall(function() sn = #sm_data end)
                for j = 1, sn do
                    local entry = sm_data[j]
                    if entry then
                        local t; pcall(function() t = entry.Transform end)
                        if t then
                            local xp, yp, zp, wp
                            pcall(function() xp = t.XPlane end)
                            pcall(function() yp = t.YPlane end)
                            pcall(function() zp = t.ZPlane end)
                            pcall(function() wp = t.WPlane end)
                            if xp and yp and zp and wp then
                                local d = _decompose_matrix(xp, yp, zp, wp)
                                if d then
                                    captured[i][j] = d
                                    cap_count = cap_count + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Phase 2: classify books as warded/unwarded/uninitialized. We only
    -- mark warded books (the ones we'll need to hide). Uses the same
    -- precomputed set as _apply_books_to_world so all warding decisions
    -- agree on the v1.0.3 rule (or fall back to v1.0.2 legacy via the
    -- version gate inside _compute_unwarded_set).
    local only_shelfable = M._slot_data
        and M._slot_data.only_unward_shelfable_books == 1
    local unwarded_set = M._compute_unwarded_set(only_shelfable)
    local is_warded_book = {}
    local warded_count, unwarded_count, uninit_count = 0, 0, 0
    for i = 1, bn do
        local b = books[i]
        if b and b:IsValid() then
            local asset_idx = _book_valid_asset_idx(b)
            if asset_idx ~= nil then
                local series = M._asset_to_series[asset_idx]
                local should_unward = series and unwarded_set[series]
                if should_unward then
                    unwarded_count = unwarded_count + 1
                else
                    is_warded_book[i] = true
                    warded_count = warded_count + 1
                end
            else
                uninit_count = uninit_count + 1
            end
        end
    end
    log(("[hism-init] classified: %d warded, %d unwarded, %d uninitialized"):format(
        warded_count, unwarded_count, uninit_count))

    -- Phase 3: mark warded books with a unique underground Z via
    -- mgr:UpdateInstance(BookInfo, marker). UpdateInstance moves the
    -- canonical instance for that BookInfo, so we can scan HISMs and
    -- recover (book, HISM, instance_idx) from the marker Z.
    local MARKER_BASE = -1000000.0
    local book_keys = {}  -- book_idx → book_full_name
    local marked_count = 0
    for i = 1, bn do
        if is_warded_book[i] then
            local b = books[i]
            if b and b:IsValid() then
                local info; pcall(function() info = b.ItemInfo end)
                if info then
                    book_keys[i] = b:GetFullName()
                    local marker = {
                        Rotation    = {X=0, Y=0, Z=0, W=1},
                        Translation = {X=0, Y=0, Z=MARKER_BASE - i},
                        Scale3D     = {X=1, Y=1, Z=1},
                    }
                    local ok = pcall(function() mgr:UpdateInstance(info, marker) end)
                    if ok then marked_count = marked_count + 1 end
                end
            end
        end
    end

    -- Phase 4: scan HISMs for marker Z values. Each match gives us a
    -- specific (HISM, instance_idx, original_transform) for one book.
    -- We also store the HISM ref so hide/show can use per-instance
    -- UpdateHISMInstance calls (avoids the canonical-only limitation of
    -- mgr:UpdateInstance).
    M._book_captured_transforms = {}
    M._book_hism_refs = {}
    -- Winner lookup by AssetIdx, built alongside the main scan. Used as a
    -- fallback in Phase 5 to AddInstance using a winner's known-good
    -- transform when mark-and-scan fails to relocate the canonical
    -- (empirically 100% of Phase 5 loser cases).
    local winner_by_aidx = {}
    local mapped = 0
    for hi = 1, hn do
        local h = hism_array[hi]
        if h and h:IsValid() then
            local sm_data; pcall(function() sm_data = h.PerInstanceSMData end)
            if sm_data then
                local sn = 0; pcall(function() sn = #sm_data end)
                for ji = 1, sn do
                    local entry = sm_data[ji]
                    if entry then
                        local t; pcall(function() t = entry.Transform end)
                        if t then
                            local wp; pcall(function() wp = t.WPlane end)
                            if wp then
                                local z; pcall(function() z = wp.Z end)
                                if z and z < -500000.0 then
                                    local book_idx = math.floor(MARKER_BASE - z + 0.5)
                                    if book_idx >= 1 and book_idx <= bn then
                                        local key = book_keys[book_idx]
                                        local orig = captured[hi] and captured[hi][ji]
                                        if key and orig then
                                            M._book_captured_transforms[key] = orig
                                            M._book_hism_refs[key] = { hism = h, idx = ji - 1 }
                                            mapped = mapped + 1
                                            -- Build aidx -> winner lookup
                                            local winner_book = books[book_idx]
                                            if winner_book and winner_book:IsValid() then
                                                local waidx = _book_valid_asset_idx(winner_book)
                                                if waidx ~= nil and not winner_by_aidx[waidx] then
                                                    winner_by_aidx[waidx] = {
                                                        hism = h,
                                                        idx = ji - 1,
                                                        transform = orig,
                                                    }
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Phase 4.5: Restore Phase-4 winners' canonicals to natural transforms
    -- BEFORE Phase 5 runs. mgr:UpdateInstance(BookInfo, marker) silently
    -- fails when the BookInfo's canonical HISM instance has been moved
    -- from its natural position — Phase 3 leaves every canonical at its
    -- marker Z (-1M range), so Phase 5's re-mark step would never succeed
    -- (717/717 losers failed with `no_canonical` before this fix).
    -- Restoring each winner's canonical here lets Phase 5 work.
    --
    -- Iterates warded books (not unique BookInfos): only the WINNER's
    -- slot has a ref recorded in M._book_hism_refs at this point, so
    -- each unique canonical gets exactly one restore call. Loser books
    -- have no refs yet and are handled by Phase 5.
    local restored = 0
    for i = 1, bn do
        if is_warded_book[i] then
            local key = book_keys[i]
            local ref = M._book_hism_refs[key]
            local orig = ref and M._book_captured_transforms[key]
            if orig then
                local b = books[i]
                if b and b:IsValid() then
                    local info; pcall(function() info = b.ItemInfo end)
                    if info then
                        pcall(function() mgr:UpdateInstance(info, orig) end)
                        restored = restored + 1
                    end
                end
            end
        end
    end
    log(("[hism-init] Phase4.5: restored %d winner canonical(s) to natural before Phase 5"):format(restored))

    -- Phase 5: for warded books not mapped in Phase 4 (BookInfo-canonical
    -- collisions), AddInstance via the winner-by-AssetIdx lookup built in
    -- Phase 4. The legacy mark-and-scan approach failed 100% of the time
    -- (`mgr:UpdateInstance` silently no-ops after Phase 3 has used it).
    --
    -- Approach:
    --   1. Look up winner_by_aidx[loser.AssetIdx] for a known-good
    --      (hism, transform) pair.
    --   2. AddInstance(winner.hism, winner.transform) directly — creates
    --      a new HISM slot adjacent to the winner's at the same location.
    --   3. Record loser book → (winner.hism, new_idx, winner.transform).
    --
    -- Multiple losers sharing AssetIdx with a single winner each get
    -- their own new HISM slot, all initially overlapping at the winner's
    -- natural position. Pass 2 teleports each warded loser independently
    -- to -1M Z; per-instance UpdateHISMInstance brings them back when
    -- the series unwards.
    local mod_actor = FindFirstOf("ModActor_C")
    local added, add_failed_no_winner, add_failed_addinstance = 0, 0, 0
    local first_add_logged = 0
    local FAIL_LOG_CAP = 15
    local nowinner_logged, addinst_logged = 0, 0
    -- Phase 5a allocation counter (per-HISM) for the PreAllocate below.
    -- (_phase5_queue is still built here but no longer drained -- the Phase 5b
    -- worker that consumed it was removed; losers are handled by Phase 8.)
    M._phase5_queue = {}
    M._phase5_pending_per_hism = {}
    local queued = 0
    for i = 1, bn do
        if is_warded_book[i] then
            local key = book_keys[i]
            if key and not M._book_hism_refs[key] then
                local b = books[i]
                if b and b:IsValid() then
                    local info; pcall(function() info = b.ItemInfo end)
                    if info then
                        -- Capture diagnostic fields for this book up-front.
                        local diag_aidx
                        pcall(function() diag_aidx = info.AssetIdx end)
                        local loser_aidx = diag_aidx  -- canonical lookup key
                        local diag_series  = (diag_aidx ~= nil and M._asset_to_series[diag_aidx])  or "?"
                        local diag_section = (diag_aidx ~= nil and M._asset_to_section[diag_aidx]) or "?"
                        diag_aidx = diag_aidx or -1
                        local diag_x, diag_y, diag_z = 0, 0, 0
                        pcall(function()
                            local loc = b:K2_GetActorLocation()
                            if loc then
                                diag_x = loc.X or 0
                                diag_y = loc.Y or 0
                                diag_z = loc.Z or 0
                            end
                        end)
                        local function record_unmapped()
                            M._unmapped_warded_books[key] = {
                                asset_idx = diag_aidx,
                                series    = diag_series,
                                section   = diag_section,
                                x = diag_x, y = diag_y, z = diag_z,
                            }
                        end

                        -- New: queue loser for async AddInstance in Phase 5b.
                        -- The synchronous AddInstance approach crashed at
                        -- offset 0x8 with 708 back-to-back render-state
                        -- updates; chunking 10/tick at 100ms gives the
                        -- render thread time to process each batch.
                        local winner = loser_aidx and winner_by_aidx[loser_aidx]

                        if not winner then
                            add_failed_no_winner = add_failed_no_winner + 1
                            record_unmapped()
                            if nowinner_logged < FAIL_LOG_CAP then
                                nowinner_logged = nowinner_logged + 1
                                log(("[hism-init][orphan/no-winner] book i=%d aidx=%s series='%s' section=%s actor_xyz=(%.0f,%.0f,%.0f) winner_in_lookup=%s"):format(
                                    i, tostring(loser_aidx), diag_series, diag_section,
                                    diag_x, diag_y, diag_z,
                                    tostring(winner ~= nil)))
                            end
                        else
                            -- Enqueue for chunked AddInstance.
                            table.insert(M._phase5_queue, {
                                key = key,
                                hism = winner.hism,
                                transform = winner.transform,
                                aidx = loser_aidx,
                            })
                            -- Track per-HISM allocation count so we can
                            -- PreAllocateInstancesMemory before the worker
                            -- starts adding (avoids reallocation crashes).
                            M._phase5_pending_per_hism[winner.hism] =
                                (M._phase5_pending_per_hism[winner.hism] or 0) + 1
                            queued = queued + 1
                            if first_add_logged < 3 then
                                first_add_logged = first_add_logged + 1
                                log(("[hism-init] Phase5 sample: book i=%d aidx=%s queued for async AddInstance"):format(
                                    i, tostring(loser_aidx)))
                            end
                        end
                    end
                end
            end
        end
    end

    log(("[hism-init] captured=%d marked=%d mapped=%d queued=%d (no_winner=%d)"):format(
        cap_count, marked_count, mapped, queued, add_failed_no_winner))

    -- Phase 5a finish: PreAllocate per HISM, then kick off the async
    -- AddInstance worker. PreAllocateInstancesMemory tells the HISM to
    -- grow its internal array once instead of on every AddInstance,
    -- avoiding render-thread issues from concurrent reallocation.
    local prealloc_hisms = 0
    for hism, count in pairs(M._phase5_pending_per_hism) do
        if hism and hism:IsValid() and count > 0 then
            pcall(function() hism:PreAllocateInstancesMemory(count) end)
            prealloc_hisms = prealloc_hisms + 1
        end
    end
    -- Phase 5b removed. Its AddInstance bursts (even chunked) crashed the game
    -- with a 0x8 null-deref; Phase 8 (actor.HISMController, no new instances)
    -- replaces it. _phase5_queue is built above but no longer consumed.
    if queued > 0 then
        log(("[hism-init] Phase5a done: %d queued (no Phase5b worker -- Phase 8 handles losers via HISMController)"):format(
            queued))
    end

    -- Phase 8: per-actor HISMController-based instance claim. For every
    -- warded book actor, get its HISMController (the specific HISM it
    -- renders through, exposed as actor.HISMController via reflection).
    -- Scan that HISM for an unclaimed natural-Z instance and record it
    -- as the actor's hide/show target.
    --
    -- This replaces Phases 3-7 entirely for hide ref discovery. Phase 3's
    -- mark-and-scan via mgr:UpdateInstance only found 1158/1880 because
    -- the manager has BookInfo-canonical collisions. Phases 6/7 (position
    -- scans) found 0/1 matches because dupes are at separate floor
    -- positions from canonicals AND actor.GetActorLocation is the
    -- trigger location, not the HISM render position. Phase 8 sidesteps
    -- both problems by reading the per-actor HISM reference directly.
    local p8_claimed = 0
    local p8_no_hismcontroller = 0
    local p8_no_natural = 0
    local p8_claimed_per_hism = {}  -- hism full name → set of claimed idx
    local p8_diag_logged = 0
    for i = 1, bn do
        if is_warded_book[i] then
            local key = book_keys[i]
            if key then
                local b = books[i]
                if b and b:IsValid() then
                    local hc
                    pcall(function() hc = b.HISMController end)
                    -- One-shot diagnostic on first 5 warded books: what
                    -- IS HISMController? Class? Instance count?
                    if p8_diag_logged < 5 and hc then
                        p8_diag_logged = p8_diag_logged + 1
                        local hc_class
                        pcall(function() hc_class = hc:GetClass():GetFullName() end)
                        local sm_data_check
                        pcall(function() sm_data_check = hc.PerInstanceSMData end)
                        local sn_check = -1
                        if sm_data_check then
                            pcall(function() sn_check = #sm_data_check end)
                        end
                        local hc_valid = hc:IsValid()
                        log(("[Phase8-diag] book i=%d HISMController class=%s isvalid=%s PerInstanceSMData count=%s"):format(
                            i, tostring(hc_class), tostring(hc_valid),
                            tostring(sn_check)))
                    end
                    if hc and hc:IsValid() then
                        local h_name
                        pcall(function() h_name = hc:GetFullName() end)
                        h_name = h_name or "?"
                        local claimed_set = p8_claimed_per_hism[h_name] or {}
                        p8_claimed_per_hism[h_name] = claimed_set
                        local sm_data
                        pcall(function() sm_data = hc.PerInstanceSMData end)
                        if sm_data then
                            local sn = 0
                            pcall(function() sn = #sm_data end)
                            local found_idx = nil
                            local found_orig = nil
                            for ji = 1, sn do
                                if not claimed_set[ji] then
                                    local entry = sm_data[ji]
                                    if entry then
                                        local t
                                        pcall(function() t = entry.Transform end)
                                        if t then
                                            local wp
                                            pcall(function() wp = t.WPlane end)
                                            if wp then
                                                local zv = wp.Z or 0
                                                if zv > -500000.0 then
                                                    -- Natural Z, claim it
                                                    local xp, yp, zp
                                                    pcall(function() xp = t.XPlane end)
                                                    pcall(function() yp = t.YPlane end)
                                                    pcall(function() zp = t.ZPlane end)
                                                    if xp and yp and zp then
                                                        local d = _decompose_matrix(xp, yp, zp, wp)
                                                        if d then
                                                            claimed_set[ji] = true
                                                            found_idx = ji - 1
                                                            found_orig = d
                                                            break
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            if found_idx ~= nil then
                                -- Overwrite any prior refs from Phase 4/5b
                                M._book_hism_refs[key] = { hism = hc, idx = found_idx }
                                M._book_captured_transforms[key] = found_orig
                                p8_claimed = p8_claimed + 1
                            else
                                p8_no_natural = p8_no_natural + 1
                            end
                        end
                    else
                        p8_no_hismcontroller = p8_no_hismcontroller + 1
                    end
                end
            end
        end
    end
    log(("[hism-init] Phase8 complete: claimed=%d no_hismcontroller=%d no_natural=%d"):format(
        p8_claimed, p8_no_hismcontroller, p8_no_natural))

    -- Group unmapped books by series so the player can verify which
    -- specific series may have "stuck" books and whether the same set
    -- appears across runs. Section-prefixed for cross-referencing with
    -- the level's cabinet labels.
    local unmapped_total = 0
    local by_series = {}  -- series_name → { section, count }
    for _, ud in pairs(M._unmapped_warded_books) do
        unmapped_total = unmapped_total + 1
        local bucket = by_series[ud.series] or { section = ud.section, count = 0 }
        bucket.count = bucket.count + 1
        by_series[ud.series] = bucket
    end
    if unmapped_total > 0 then
        local series_names = {}
        for s in pairs(by_series) do series_names[#series_names+1] = s end
        table.sort(series_names, function(a, b)
            local sa, sb = by_series[a].section, by_series[b].section
            if sa ~= sb then return sa < sb end
            return a < b
        end)
        log(("[hism-init] %d unmapped book(s) across %d series (these may appear stuck in walls/floors when unwarded):"):format(
            unmapped_total, #series_names))
        for _, sname in ipairs(series_names) do
            local bucket = by_series[sname]
            log(("  [%s] '%s' × %d book(s)"):format(bucket.section, sname, bucket.count))
        end
        log("[hism-init] (call ItemApply.dump_unmapped_books() for full per-book coordinates)")
    end

    M._hism_initialized = true
end

--- Toggle a book actor's mesh visibility. Tree-walk AttachChildren +
--- BlueprintCreatedComponents.
---
--- NOTE: We do NOT call SetActorVisible(visible) here. That's the game's
--- own BP-graph visibility function, and the BP Tick reverts it to the
--- "expected" state every frame — leading to a brief disappear-then-
--- reappear flicker, so we set the component flags directly instead. (Warded
--- books are kept hidden by Layer 3 pile hiding + Pass 1 actor warding.)
function M._set_book_mesh_visible(book, visible)
    if not book or not book:IsValid() then return end
    local root = book:K2_GetRootComponent()
    if root and root:IsValid() then
        _walk_set_visibility(root, visible)
    end
    local comps
    pcall(function() comps = book.BlueprintCreatedComponents end)
    if comps then
        local cn = 0; pcall(function() cn = #comps end)
        for i = 1, cn do
            local c = comps[i]
            if c and c:IsValid() then
                pcall(function() c:SetVisibility(visible, false) end)
                pcall(function() c:SetHiddenInGame(not visible, false) end)
                if _diag_on("RENDER_STATE_DIRTY") then
                    pcall(function() c:MarkRenderStateDirty() end)
                end
            end
        end
    end
end

--- Compute the set of series that should be unwarded (pickable) right now, given
--- the player's item state and the only_unward_shelfable_books mode. Returns
--- {[series_name] = true}. Recomputed on each apply (cheap).
---
--- Off (only_shelfable = false, DEFAULT): every RECEIVED series is unwarded,
---   regardless of which bookcase it lives on or whether that case is open. You can
---   pick a book up the moment its series arrives and stash it on any open shelf --
---   mis-shelving + moving it later is part of the loop. (Completing a row still
---   needs the home bookcase OPEN to place correctly -- that's the separate bookcase
---   warding. Generation gates row-completion on the bookcase being open, so this
---   pickup leniency never makes a check unreachable.)
---
--- On (only_shelfable = true, STRICT): a received series stays warded until its
---   home bookcase is open -- cases_open >= shelf_req for its section. A section with
---   0 cases open has none of its series pickable.
---
--- beta7: Off was previously shelf-req-gated (floor-of-1) on v1.0.3+ seeds; that
--- gate -- and the v1.0.2/v1.0.3 `_use_v103_warding` split -- was removed so Off
--- matches its documented "pickable as soon as received" behavior. On is unchanged.
function M._compute_unwarded_set(only_shelfable)
    local unwarded = {}
    if not only_shelfable then
        -- Off (default): every RECEIVED series is pickable, no shelf gating --
        -- regardless of which bookcase it lives on or whether that case is open.
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

-- B7 chunked-flush tuning.
-- Pass 1 walks ~3000 BP_GrabbingBook actors toggling SetActorHiddenInGame
-- + SetActorEnableCollision. All-in-one tick blocks the AP poll loop
-- long enough to drop the server connection on big item bursts.
--
-- BOOK_APPLY_CHUNK_SIZE       — books per tick (300 ≈ 10 chunks for a
--                                typical full flush).
-- BOOK_APPLY_CHUNK_DELAY_MS   — yield between chunks so the LoopAsync
--                                poll thread can pump c:poll() once.
--                                50ms < the 100-150ms AP heartbeat.
-- Total wall-clock ~10 chunks * 50ms = ~500ms, comparable to the
-- previous synchronous walk but split across 10 non-blocking ticks.
local BOOK_APPLY_CHUNK_SIZE     = 300
local BOOK_APPLY_CHUNK_DELAY_MS = 50

--- Walk every BP_GrabbingBook_C in the level and ward/unward based on
--- whether its series is in the current unwarded set. Section is NOT part
--- of the per-book gate — section unlocks affect bookcase/shelf visibility
--- (phase 2).
---
--- Pass 1 is chunked (see BOOK_APPLY_CHUNK_SIZE) so the LoopAsync poll
--- thread can pump c:poll() between chunks, keeping the AP socket alive
--- during big item-application bursts. The post-pass finalizer (Pass 2
--- in hidden mode, diff logging, state summary) runs after the last
--- chunk completes.
---
--- Re-entry: if a second flush is requested while one is in progress,
--- M._flush_pending is set; the finalizer self-re-fires once done so
--- the latest state is captured. Concurrent flushes are NOT supported
--- (no benefit + harder reasoning about state consistency).
function M._apply_books_to_world()
    -- Re-entry guard. If a flush is already running, just mark a
    -- follow-up and return — the in-flight flush's finalizer will
    -- pick it up.
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

    local hide_mesh = M._slot_data and M._slot_data.book_visibility == "hidden"

    -- Compute the unwarded set once per apply call. The rules (v1.0.2
    -- legacy vs v1.0.3 unified) are encapsulated in _compute_unwarded_set;
    -- per-book code just does a table lookup. Snapshot stays consistent
    -- across all chunks of THIS flush; if state changes mid-flight, the
    -- _flush_pending re-fire path captures it next.
    local only_shelfable = M._slot_data
        and M._slot_data.only_unward_shelfable_books == 1
    local unwarded_set = M._compute_unwarded_set(only_shelfable)

    -- Sanity check: are book actors INITIALIZED yet? When M01 first loads,
    -- BP_GrabbingBook actors are spawned but their ItemInfo.AssetIdx is the
    -- default 0 until the game runs its placement / population logic.
    -- Calling SetActorHiddenInGame on un-init actors has crashed the game.
    -- Sample the first 20 books; require ≥2 distinct non-zero AssetIdx
    -- values before treating the world as safe to mutate.
    do
        local sample = {}
        local distinct = 0
        for i = 1, math.min(20, n) do
            local b = books[i]
            if b and b:IsValid() then
                -- Split ItemInfo access (see detect_completed_rows for
                -- the full rationale). Same UE4SS reflection AV class.
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

    -- Hidden mode setup: brute-force per-book HISM mapping. Runs once
    -- per session after sanity check passes (so books are populated).
    if hide_mesh and not M._hism_initialized then
        M._initialize_hism_book_mapping()
    end

    -- We're committed to a flush now. Take the in-progress lock and
    -- start the chunked Pass-1 driver.
    M._flush_in_progress = true
    -- Pass-level marker: the book-actor warding walk (~3000 actors) is too high-volume to
    -- BEG/END per book, so we timestamp the whole flush. BOOK_ACTOR_WARDING is the real
    -- bisection lever for these; this just shows a flush was in flight near a crash.
    trace.mark("books-flush", nil, "n=" .. tostring(n))
    local stats = { warded = 0, unwarded = 0, skipped = 0, gate_skipped_unwards = 0 }
    local cursor = 1

    -- v1.1.0 (B10 book material swap): cache ModActor once per flush so
    -- we don't FindFirstOf for every one of ~3000 books. Captured by the
    -- _apply_one_book closure below. May be nil if the pre-v1.1.0 pak is
    -- installed (no ModActor exposed) or if pak failed to load — in that
    -- case the legacy SetActorHiddenInGame approach is the only ward.
    local mod_actor = FindFirstOf("ModActor_C")
    if not (mod_actor and mod_actor:IsValid()) then mod_actor = nil end

    -- v1.1.0: cache the BP_HISM_Manager for the new UpdateWPO call. WPO
    -- displaces book vertices via material parameter — invisible at deep
    -- Z without touching bHidden (which the game toggles view-dependently).
    local mgr_for_wpo = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr_for_wpo and mgr_for_wpo:IsValid()) then mgr_for_wpo = nil end

    -- v1.1.0: cache any valid BP_BookCase_C so we can call
    -- book:MoveToBookCase(deep_transform, any_case) — the function needs
    -- a non-null AttchedActor and any valid bookcase serves as the
    -- attachment target. Books animate to the deep-Z target and attach
    -- to the bookcase actor, hopefully keeping them out of view.
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

    -- One-shot diagnostic: introspect the ModActor for the new pak's
    -- ModActor BP function probe. Logs which expected functions are
    -- present so we can distinguish "pak loaded but functions missing"
    -- (cook issue) from "pak not loaded" (install issue) from "functions
    -- present but spawn fails at call time" (BP graph issue).
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

    --- Process a single book at index i. Extracted so the chunk loop
    --- body stays readable.
    local function _apply_one_book(book)
        if not (book and book:IsValid()) then
            stats.skipped = stats.skipped + 1
            return
        end
        -- Skip uninitialized books (orphan actors from the
        -- OpenLevel-on-connect reload have default BookInfo and
        -- trying to ward them via mgr.UpdateInstance corrupts HISM
        -- state). _book_valid_asset_idx returns nil for orphans
        -- but 0 for the real Monsterology series (section 1A).
        local asset_idx = _book_valid_asset_idx(book)
        if asset_idx == nil then
            stats.skipped = stats.skipped + 1
            return
        end
        local series_name = M._asset_to_series[asset_idx]
        -- Single-table lookup encapsulates v1.0.2-legacy and
        -- v1.0.3-unified rules. See _compute_unwarded_set above.
        local should_unward = series_name and unwarded_set[series_name]
        local key = book:GetFullName()
        local is_warded = M._books_warded[key] or false
        local ok = pcall(function()
            if should_unward then
                -- Unconditional unward (no `if is_warded` gate). UE
                -- SetActorHiddenInGame / SetActorEnableCollision are
                -- idempotent. The previous gate left books un-pickable
                -- ("last 1-2 of a series stayed stuck") in two cases:
                --   1. Book had AssetIdx=0 at first apply → skipped,
                --      no tracker entry; later when AssetIdx populated,
                --      gate kept us from unwarding (is_warded=false).
                --   2. Actor destroyed + respawned by lazy streaming;
                --      new GetFullName key → no tracker entry.
                -- gate_skipped_unwards counts cases the previous gate
                -- would have skipped (high on first flush, near-zero
                -- in steady state = real drift catches).
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
                        -- stacks mode (M._book_hide_mode == false): keep the book VISIBLE,
                        -- only disable collision so it can't be grabbed (walk-through).
                        if M._book_hide_mode then book:SetActorHiddenInGame(true) end
                        book:SetActorEnableCollision(false)
                    end
                    M._books_warded[key] = true
                    -- Per-book cover spawning was explored but visually
                    -- unsatisfactory (covers cluttered the scene,
                    -- didn't hide books in stacks). Books remain
                    -- visible-but-non-interactable.
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

    -- Finalizer: runs after the last Pass-1 chunk -- diff logging, state summary,
    -- and the in-progress/pending bookkeeping. (The old Pass 2 -- a per-book HISM
    -- teleport pass -- was removed: it was disabled, and pile hiding is handled by
    -- Layer 3 (apply_book_visibility) + Pass 1 actor warding, not per-book moves.)
    local function _finalize_apply()
        M._finalize_apply_books(books, n, stats)
        M._flush_in_progress = false

        -- Re-flush if a request landed mid-flight. Each re-flush
        -- clears _flush_pending first, so this won't loop forever.
        if M._flush_pending then
            M._flush_pending = false
            -- Bounce to the ASYNC thread instead of calling inline. This finalizer
            -- can run inside a game-thread closure (BOOK_ACTOR_GAMETHREAD), and
            -- flush_apply -> _on_game_thread -> ExecuteInGameThread would then NEST
            -- ExecuteInGameThread calls (UE4SS #1180: scheduling a tick-action while
            -- the tick-action list is being iterated). LoopAsync re-issues the flush
            -- from the async thread. Harmless (~10ms) when already on the async thread.
            LoopAsync(10, function() M.flush_apply() return true end)
        end
    end

    --- Pass 1, chunked, on the GAME THREAD. _book_process_one_chunk does one
    --- chunk's per-book reads+writes (_apply_one_book); _book_run_chunk runs it via
    --- _on_game_thread (gated BOOK_ACTOR_GAMETHREAD), then reschedules through
    --- LoopAsync -> _book_run_chunk so the next ExecuteInGameThread is issued from
    --- the async thread, never nested inside a game-thread callback (UE4SS #1180).
    --- pcall-guarded: a throwing chunk releases _flush_in_progress so it can't wedge
    --- the flush lock (which would block every future flush_apply). Moving the walk
    --- off the async thread also stops it starving the AP poll loop on big bursts.
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
function M._finalize_apply_books(books, n, stats)
    -- Diff: which series were newly unwarded this apply? Diff
    -- _series_unlocked against the last applied snapshot. Logs per-series
    -- book counts, flagging any books that are in the unmapped set (may
    -- appear stuck when their actor mesh becomes visible at an internal
    -- trigger location).
    local newly_unlocked = {}
    for s in pairs(M._series_unlocked) do
        if not M._last_applied_series_unlocked[s] then
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
    -- Update snapshot for next diff.
    M._last_applied_series_unlocked = {}
    for s in pairs(M._series_unlocked) do M._last_applied_series_unlocked[s] = true end

    local section_n = 0
    for _, c in pairs(M._shelves_open) do
        if c > 0 then section_n = section_n + 1 end
    end
    local series_n = 0
    for _ in pairs(M._series_unlocked) do series_n = series_n + 1 end
    log(("State: sections-active=%d series=%d | applied: unwarded=%d warded=%d skipped=%d gate-skipped-unwards=%d"):format(
        section_n, series_n, stats.unwarded, stats.warded, stats.skipped, stats.gate_skipped_unwards))
end

-- ============================================================================
-- Apply: Bookcases (Phase 2a — section-gated visibility)
-- ============================================================================

-- Each section has exactly one BP_M01_CabinetLabel_01_C. Its `Label Number`
-- (int32) maps ordinally to a section: 1..14 → 1A..1N, 21..37 → 2A..2Q
-- (gap 15-20 = unused). `CountBookCase` (TArray<AActor>) holds either
-- direct BookCases or wrapper actors (BP_M01_PillarCabinet_01_01_C,
-- BP_M01_Cabinet_01_C).
--
-- This is the authoritative mapping. CDI[1]-based derivation was
-- unreliable — data.py's series→section assignments are wrong for ~10
-- sections (series grouped under 2E/1B actually live in 1C/1D/1G/1H/
-- 2C/2D/2G/2H/2K/2L per the in-game labels).
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
    -- A (re)index means the world (or our view of it) changed — e.g. after
    -- quit→Continue, which reloads the world but REUSES actor paths, so the
    -- apply-on-change tracker would otherwise match and skip re-warding. Drop the
    -- warding tracker so every case re-wards fresh.
    M._case_ward_state = {}
    -- Do NOT drop the sign-glow caches (_section_to_label / _section_glow_state /
    -- _section_glow_orig) here. refresh_index_if_changed() re-indexes on EVERY
    -- streaming change (running around streams bookcase sublevels in/out), but the
    -- CabinetLabel actors + their SpotLights live in the PERSISTENT level — they
    -- don't reload with the bookcases. Clearing the glow caches here forced
    -- _apply_label_glow to re-map and re-touch all 31 SpotLights on every re-index;
    -- touching a SpotLight whose render state is mid-stream is the recurring
    -- BAE1A5E0 write-null crash (the glow re-map was the last thing logged before
    -- it). The glow caches ARE reset on a genuine world reload by reset_hism_state()
    -- (LoadMap), set_gameplay_active(false), and the ward-canary drift check — so the
    -- glow stays correct across Continue while only touching a SpotLight when its
    -- section's lock state actually changes.
    M._ward_canary = nil

    -- Step 1: build boi → BP_BookCase_C map. The wrappers (PillarCabinet,
    -- Cabinet_01) reference their child bookcases via BookOrderIndex (matches
    -- ABookCaseBase.BookOrderIdx on the child). This is more reliable than
    -- ChildActorComponent:GetChildActor() which has been returning nil for us.
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

    -- Step 2: walk CabinetLabels. LabelNumber → section ordinal. CountBookCase
    -- entries are either direct BookCases (add as-is) or wrapper actors
    -- (PillarCabinet / Cabinet_01) whose BookOrderIndex tells us which
    -- BookCases to pull out of boi_to_case.
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

    -- De-dup by GetFullName, not tostring(case): UE4SS doesn't always return
    -- the same Lua wrapper across different fetch paths (FindAllOf vs reading
    -- CabinetLabel.CountBookCase[j]) even when both point to the same UObject.
    -- GetFullName returns the actor's stable UE path so it matches across calls.
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
                                    -- Walk BookOrderIndex array → look up child BookCases
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

    -- Stray-case sweep: any BookCase actor not added via a CabinetLabel
    -- walk is a "stray" — a level-design artifact (case tucked into a
    -- wall corner) not part of any AP section. The placement system
    -- can still find these by aim angle and accept books there, but
    -- the player can't reach them — softlock. Kept permanently hidden
    -- + collision-off by _apply_bookcases_to_world. _case_key matches
    -- add_case's key so indexed cases aren't reclassified.
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

--- Re-run _index_bookcases and return true iff the index actually grew
--- (new sections found, or new cases in an existing section). Used by
--- main.lua's periodic refresh loop to catch lazily-streamed bookcases
--- without spamming the world-apply when nothing has changed.
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

-- Class-name → "vol capacity tier" priority for sorting cases within a
-- section. Smaller tier = unlocks earlier (matches AP world's shelf_req
-- assignment, which puts smaller-vol series in earlier cases).
--   tier 1: BP_BookCase_4x5_C (holds 5-vol series)
--   tier 2: everything else (BP_BookCase_C / 4x16 / 6x16 — holds 10-vol series)
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

-- Returns a flat list of AssetIdx that the given BookCase accepts.
--   Uniform cases  (CDI[1] AssetIdx is in the case's section): take CDI[1..N]
--                  where N = RowStatus length.
--   Mixed cases    (4x16, 6x16): CDI is a "decorator" set; use BAI groups
--                  (FColumnCorrectIdx.CorrectIdx), deduplicated.
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

-- Fence cover variants. Each warded case gets a chain-link fence in front,
-- but case sizes differ — bookcases come in standard, small (5-vol case
-- of a mixed-volume section), smallest (the even-narrower outer cases
-- of 2O), and cabinet (tall alcove-wrapped single-case sections that
-- need wider collision so books can't be physics-thrown through the
-- chain-link sides). Four Blueprint variants:
--   standard — BP_WardCover (existing): 10-vol case or uniform section
--   cabinet  — BP_WardCover_Cabinet: 1C/1D/1G/1H and 2C/2D/2G/2H/2K/2L
--   small    — BP_WardCover_Small: 5-vol case of a mixed section
--   smallest — BP_WardCover_Smallest: 2O outer cases (narrower than small)
--
-- FENCE_PER_CASE maps section → { [case_idx] = variant_name }. Cases not
-- listed (or any case in a section not in the table) default to standard
-- unless the section is in FENCE_CABINET_SECTIONS. Note the case_idx
-- order is the game's CabinetLabel.CountBookCase order, which doesn't
-- always match left-to-right physical layout — verify visually after
-- changes.
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

--- Per-section visibility: cases sorted by (vol_tier asc, BookOrderIdx asc),
--- with visible_count = min(shelves_open[section], n_cases).
--- The first `visible_count` cases of each section are shown, the rest hidden.
--- Each Progressive Shelf Unlock (section) item received increments shelves_open
--- and reveals the next bookcase. Smaller-vol cases (4x5) unlock first, which
--- mirrors the AP world's per-section shelf_req ordering — so series in 5-vol
--- cases become reachable before series in 10-vol cases.
--- Operates only on BP_BookCase_C actors so structural wrapper meshes
--- (pillars, walls) stay visible. Idempotent.
-- ── Section sign (CabinetLabel) glow ───────────────────────────────────────
-- Each section's BP_M01_CabinetLabel_01_C sign carries a SpotLight (the
-- completion glow). We drive it as an UNLOCK-PROGRESS cue: RED = none of the section's
-- cases unlocked, YELLOW = some but not all, OFF = all unlocked (the game's own
-- completion glow takes back over). The label→section map is built by the indexer (M._section_to_label,
-- via the label's `Label Number`), so we just read it here — no FindAllOf / position
-- matching. SAFE: gameplay-only (never the streaming window that AV'd),
-- apply-on-change, and we DO NOT persistently hold the SpotLight component (a
-- render-scene-tied reference held across teardown hung the game) — we look it up
-- on the rare state-change and keep only primitives (original intensity/vis/units).

-- Bright value by ELightUnits (0 Unitless, 1 Candelas, 2 Lumens, 3 EV). This
-- game's signs use Candelas (1); tune that entry for brightness.
local GLOW_INTENSITY = { [0] = 0.5, [1] = 0.5, [2] = 180.0, [3] = 1.0 }

-- Glow the locked signs immediately when we're in gameplay AND apply-safe, instead
-- of waiting up to 5s for the periodic loop. Forces a fresh map first (drops any
-- stale label refs from the prior world) so it's safe right after Continue.
function M._maybe_glow_now()
    if not (M._gameplay_active and M._apply_safe) then return end
    M._section_to_label = nil
    M._section_glow_state = {}
    M._section_glow_orig = {}
    pcall(M._apply_label_glow)
end

function M._apply_label_glow()
    -- One-time per session, IN GAMEPLAY: map sections → their CabinetLabel actor
    -- via the label's `Label Number`. Done here (not at index/load time) so nothing
    -- touches these label actors during the fragile streaming window.
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
        -- Three-state sign: RED = none of the section's cases unlocked, YELLOW = some but
        -- not all, OFF (hand the light back to the game) = all unlocked. Driven by
        -- shelves-open vs the section's total case count.
        local open = M._shelves_open[sid] or 0
        local total = (M._section_to_cases[sid] and #M._section_to_cases[sid]) or 0
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

-- Stage 2: layer-2 ward marshaled onto the GAME THREAD (gated CASE_WARD_GAMETHREAD).
-- Covers BOTH callers (the 5s loop + flush_apply). The impl below is byte-for-byte
-- unchanged -- all its _ward_collision writes (SetCollisionEnabled / SetCollisionResponseTo*
-- / SetVisibility / MarkRenderStateDirty) plus the ground-truth + canary collision reads
-- now run on the game thread, where they can't race the engine's collision/render workers.
function M._apply_bookcases_to_world()
    _on_game_thread(M._apply_bookcases_impl, "CASE_WARD_GAMETHREAD")
end

function M._apply_bookcases_impl()
    if not M._cases_indexed then return end
    -- Section sign glow: RED = none unlocked, YELLOW = some but not all, OFF = all unlocked.
    -- Gameplay-only (never during streaming), apply-on-change.
    if M._gameplay_active and M._apply_safe then
        pcall(M._apply_label_glow)
    end
    -- Drift canary: the game silently resets bookcase collision on some transitions
    -- (e.g. Menu→Continue) that fire NO mod event, so apply-on-change would keep
    -- skipping the now-unwarded cases forever. If our sample warded mesh's Camera
    -- response is no longer Ignore, it's been reset — drop the warding + glow
    -- trackers so this pass re-applies everything.
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

    -- Periodic ward reconciliation. Apply-on-change keeps steady-state passes
    -- cheap, but it also means that if a case is ever RECORDED as done in
    -- _case_ward_state while its real collision is wrong -- an unlock whose
    -- restore silently didn't take, or an event-less game-side reset the canary's
    -- single sentinel mesh happened to miss -- nothing would re-correct it (the
    -- shelf stays warded forever despite being unlocked). So every RECONCILE_EVERY
    -- passes we drop the ward cache to force a clean full re-assert from
    -- _shelves_open (the UNLOCK path's StaticMesh block-all then re-placeables any
    -- stranded shelf). Gated on gameplay+apply_safe so it never runs during
    -- streaming/teardown (can't race the world-teardown deref); the re-assert is
    -- cheap (ward is ~1-8 pcall-guarded calls/mesh) and self-limits to once per
    -- RECONCILE_EVERY passes. Captures (_case_orig_collision) are NOT cleared.
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
    for section_id, cases in pairs(M._section_to_cases) do
        local shelves_open = M._shelves_open[section_id] or 0
        local visible_count = math.min(shelves_open, #cases)

        -- Stable per-section order: smaller-vol cases first, BookOrderIdx
        -- breaks ties.
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

                -- Apply-on-change gate: only mutate this case when its visible
                -- (lock) state actually changes. The warding STICKS once applied
                -- (the BP doesn't fight our collision), so steady-state passes do
                -- nothing per case — a big perf win that also removes the window
                -- where a periodic poll could race the world teardown on quit and
                -- deref a freeing mesh (the 0x0 quit crash). State resets on world
                -- reload, so every case re-applies fresh next session.
                M._case_ward_state = M._case_ward_state or {}
                -- Decide whether to (re)ward by reading the case's ACTUAL collision rather
                -- than trusting our cache. The placement mesh's Camera channel (4) reads
                -- Ignore(0) when warded, Block(2) when unwarded (see _ward_collision). So a
                -- correctly-warded case is a no-op every pass -> NO render-state churn (the
                -- recurring crash is a main-thread mesh write racing the render/instance
                -- worker), while game-side drift (Menu->Continue silently resetting collision)
                -- is still caught within one pass. Falls back to the cache on a case's first
                -- pass (placement mesh not stashed yet) or whenever the read is unavailable.
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
                        -- Warding (Lua-only, crash-free) — 2e: LOCKED cases keep their
                        -- body meshes solid to OBJECT channels (block player + thrown
                        -- books) but IGNORE trace channels so the placement line-trace
                        -- misses → solid AND un-interactable. UNLOCKED restores them.
                        -- See `_ward_collision`.
                        case:SetActorHiddenInGame(false)
                        _ward_collision(case, case_key, not visible)
                        -- Tree-walk child components to ensure visibility
                        -- propagates. BP_BookCase children
                        -- (StaticMesh, PreviewBookLocation) don't always
                        -- inherit the actor flag.
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

                -- Cover-actor overlay. If the pak is loaded, ModActor
                -- exposes SpawnWardCover / SpawnWardCover_Cabinet /
                -- SpawnWardCover_Small + DespawnWardCover. We pick the
                -- variant per (section, case_idx) so cabinet alcoves get
                -- the taller fence with wider collision, and 5-vol cases
                -- of mixed sections get the narrower fence sized for the
                -- smaller bookcase. All wrapped in pcall so an older pak
                -- without the new variants falls back to standard
                -- SpawnWardCover where possible.
                -- v1.1.0 diagnostic: cover spawning is GATED OFF (M._covers_enabled
                -- is nil/false). Runtime cover actors are the connect/quit crash
                -- source — disabling them restores the stable connect path. The
                -- [row-diag] probe above doesn't depend on covers. The rewrite
                -- replaces this whole path; for now we just need stable play to
                -- capture the row structure.
                if case_key and M._covers_enabled then
                    local mod_actor = FindFirstOf("ModActor_C")
                    if mod_actor and mod_actor:IsValid() then
                        if visible then
                            -- Should be visible: despawn cover if any.
                            local existing_cover = M._case_covers[case_key]
                            if existing_cover and existing_cover:IsValid() then
                                pcall(function()
                                    mod_actor:DespawnWardCover(existing_cover)
                                end)
                            end
                            M._case_covers[case_key] = nil
                        else
                            -- Should be warded: spawn cover if not present.
                            local existing_cover = M._case_covers[case_key]
                            if not existing_cover or not existing_cover:IsValid() then
                                local variant = _fence_variant_for_case(section_id, i)
                                local fn_name = FENCE_BP_FUNC[variant] or "SpawnWardCover"
                                -- One-shot per (section, case_idx) log
                                -- so we can confirm the variant assignment
                                -- matches the in-game bookcases.
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
                                    -- UE4SS BP out-params: pass an EMPTY
                                    -- TABLE that UE4SS populates with
                                    -- the output value under the BP
                                    -- parameter's name. Passing nil fails
                                    -- with "no table was on the stack";
                                    -- {} works and the value lands in
                                    -- out_table.spawned_cover.
                                    local fn = mod_actor[fn_name]
                                    if fn ~= nil then
                                        fn(mod_actor, case, out_table)
                                    else
                                        -- Variant not in this pak; fall
                                        -- back to standard so the player
                                        -- still gets some kind of gate.
                                        mod_actor:SpawnWardCover(case, out_table)
                                    end
                                end)
                                spawned = out_table.spawned_cover
                                    or out_table.SpawnedCover
                                    or out_table[1]
                                    or out_table.ReturnValue
                                -- One-shot dump of table keys on first
                                -- call so we can see what UE4SS actually
                                -- populated, in case the field name we
                                -- assumed is wrong.
                                if not M._diag_spawnwardcover_table_dumped then
                                    M._diag_spawnwardcover_table_dumped = true
                                    local keys = {}
                                    for k, v in pairs(out_table) do
                                        keys[#keys + 1] = tostring(k) .. "=" .. tostring(v)
                                    end
                                    log(("[ward-diag] SpawnWardCover out_table keys: {%s}"):format(
                                        table.concat(keys, ", ")))
                                end
                                -- One-shot geometry diagnostic. Each step in
                                -- its own pcall + log so we get partial
                                -- output even when one accessor throws.
                                -- Uses tostring() (UE4SS wrapper has a
                                -- friendly tostring); .X/.Y/.Z field access
                                -- previously failed silently with no output.
                                -- +25 X in BP_WardCover places the fence in
                                -- front of the bookcase. Mesh component
                                -- access (spawned.MeshFence) and
                                -- GetActorBounds don't work cleanly from
                                -- UE4SS Lua, so we rely on fixed BP
                                -- component defaults instead.
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
                                    -- Runtime override: BP saved values for the BlockerBox keep
                                    -- coming through as Overlap (1) at runtime even when the
                                    -- editor shows Block. Force-set every channel to Block
                                    -- (ECR_Block = 2) on the BlockerBox component directly.
                                    -- Idempotent — re-setting an already-Block channel is free.
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

    -- Stray cases: cases that exist in the level but aren't tied to any
    -- section via CabinetLabel. Keep them permanently hidden + collision-
    -- off so the placement system can't drop books on them.
    local stray_disabled, stray_dead = 0, 0
    for i = 1, (_diag_on("CASE_WARDING") and #M._stray_cases or 0) do
        local case = M._stray_cases[i]
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

    -- Only log when something changed vs the last apply (the periodic
    -- re-apply runs every 5s and used to spam identical lines).
    local _diag_total = 0
    for _, _cs in pairs(M._section_to_cases) do _diag_total = _diag_total + #_cs end
    local key = string.format("%d/%d/%d/%d/%d", _diag_total, shown, hidden, dead, stray_disabled)
    if M._last_apply_log_key ~= key then
        log(("Bookcases: cases=%d shown=%d hidden=%d dead=%d stray=%d (gp=%s as=%s)"):format(
            _diag_total, shown, hidden, dead, stray_disabled,
            tostring(M._gameplay_active), tostring(M._apply_safe)))
        M._last_apply_log_key = key
    end

end

--- Logs a per-section summary of which series each VISIBLE case accepts vs
--- which of those series are currently UNLOCKED. Useful when the player
--- can't find any book that fits an open shelf. Marker `*` = unlocked.
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

-- Walks every indexed bookcase and fires the AP row-completion location for each
-- GENUINELY-completed shelf. AUTHORITATIVE signal: the game's per-case RowStatus
-- (BP_BookCase: TArray<bool>, ONE ENTRY PER SHELF) -- rs[i]==true ONLY when shelf i's
-- designated series is fully placed IN ORDER on that single shelf (the game validates
-- order + section before flipping the bit). Wrong order, wrong section, or a series
-- split across shelves never flips a bit -> never fires.
--   • Uniform case  -> completed shelf i maps to series CorrectBookDataIndex[i] (exact).
--   • Mixed cabinet -> fall back to "fully present in home section", capped by the count
--     of completed shelves.
-- BUG THIS FIXED: the old code read #case.RowStatus as a completion COUNT, but that is
-- the SHELF COUNT (TArray length), so the gate was always true and any series merely
-- PRESENT in its section fired regardless of order/single-row. Read the bool VALUES,
-- never the length (#RowStatus is still the right SHELF count for _case_accepted_assets).

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
                -- AUTHORITATIVE per-shelf completion. RowStatus is a TArray<bool> (game class
                -- BP_BookCase) with ONE ENTRY PER SHELF; rs[i]==true ONLY when shelf i holds its
                -- designated series fully placed IN ORDER -- the game validates order + section
                -- before flipping it. The old code read #case.RowStatus, but that is the SHELF
                -- COUNT, not the completed count: the gate was always true and ANY series merely
                -- PRESENT in its home section (count >= volumes) fired, regardless of order or
                -- whether it sat on one row. We now read the bool VALUES.
                local rs = nil; pcall(function() rs = case.RowStatus end)
                local rs_n = 0; if rs then pcall(function() rs_n = #rs end) end
                local completed = {}   -- 1-based shelf indices with rs[i] == true
                for i = 1, rs_n do
                    local done = false
                    pcall(function() local v = rs[i]; done = (v == true or v == 1) end)
                    if done then completed[#completed + 1] = i end
                end

                if #completed > 0 then
                    -- Read the completed series from the books ACTUALLY on each completed row.
                    -- Under free placement (any series on any row), CorrectBookDataIndex is the
                    -- SECTION's answer-set, NOT a per-row map -- using cdi[i] fired the wrong series
                    -- (1J row 3 held series 113 but cdi[3]=110). PlacingBookInfo is a flat row-major
                    -- grid of rows*per_row slots (CONFIRMED: 40 slots / 4 rows = 10/row, RowNumArray
                    -- corroborates 10), so row i's books are slots (i-1)*per_row+1 .. i*per_row.
                    -- Split ItemInfo access keeps the crash-safe path (a book sub-object can be
                    -- transiently freed mid-completion; pcall can't catch that native AV).
                    local pbi = nil; pcall(function() pbi = case.PlacingBookInfo end)
                    local pbi_n = 0; if pbi then pcall(function() pbi_n = #pbi end) end
                    local per_row = (rs_n > 0 and pbi_n > 0 and pbi_n % rs_n == 0)
                        and math.floor(pbi_n / rs_n) or 0

                    if pbi and per_row > 0 then
                        -- GRID: each completed row holds exactly one series in order -> read that
                        -- row's own slots and take the AssetIdx filling them (dominant guards a
                        -- transient partial read). No cdi[i], no section-wide guessing.
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
                            -- Fire ONLY for the correct section: the series found on the row must
                            -- belong to THIS bookcase's section. Under home-section placement that
                            -- always holds. If a row's series ever maps elsewhere (mis-indexed
                            -- bookcase / unexpected cross-section placement / transient mis-read),
                            -- log it loudly and do NOT fire a foreign section's location.
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
                        -- FALLBACK (non-grid PBI -- a cabinet whose slot count isn't rows*per_row):
                        -- "series fully present in its home section" scan, capped by #completed. Less
                        -- precise (can mis-pick among several fully-present series) but never invents
                        -- a not-present series; only used where rows can't be sliced.
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

--- Walk APClient._sent_checks and mark every matching row location in
--- _sent_row_locations. This recovers row-completion state across reconnects:
--- prior-session row checks the server already knows about end up populating
--- _sent_row_locations so fire_section_completions() can see that all rows
--- of a section are complete without having to re-discover each one via
--- detect_completed_rows. Returns the number of newly-marked entries.
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

--- Fire any unfired "Section Complete: <id>" location checks whose section
--- has had every row location marked sent. Tracks the firing in
--- _sent_section_completions so we don't re-send during the same session.
---
--- Derived from _sent_row_locations rather than an in-game event:
--- the game emits no "section complete" signal, and row-completion is
--- the only authoritative "this series's row is done" trigger we have.
--- Every row fired = every series in the section was correctly shelved.
---
--- Called from:
---   • The FinishRow hook (after detect_completed_rows) — catches new
---     section completions right when the player finishes the section's
---     last row.
---   • run_baseline_sync — fires any sections that were already complete
---     in a prior session (we sync _sent_row_locations from the server's
---     _sent_checks first so this works on reload).
function M.fire_section_completions()
    if not M._slot_data then return 0 end
    if not M._section_to_row_locs then return 0 end
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient.send_check) then return 0 end

    -- Prefer slot_data's section_location_map (new seeds). Fall back
    -- to AP_LOC_SECTION_FIRST + SECTION_IDX[sid] for legacy seeds —
    -- location ids are allocated identically apworld-side, so the
    -- fallback maps correctly.
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

--- Fire any unfired "Floor N Complete" location checks whose floor has had
--- every row location in its active sections marked sent. Mirrors
--- fire_section_completions but at the floor granularity.
---
--- Locations: AP IDs 1910550 (Floor 1) and 1910551 (Floor 2). Defined in
--- apworld/librarian/Locations.py:_floor_locations.
---
--- Called from:
---   • The FinishRow hook (after fire_section_completions) — catches the
---     final row that closes out a floor.
---   • The 3s detect_completed_rows poll (for swap completions that
---     don't go through FinishRow).
---   • run_baseline_sync — fires any floors that were already complete in
---     a prior session, after _sync_sent_row_locations_from_server has
---     hydrated _sent_row_locations from the server's _sent_checks.
function M.fire_floor_completions()
    if not M._slot_data then return 0 end
    if not M._floor_to_row_locs then return 0 end
    local APClient = package.loaded["AP/APClient"]
    if not (APClient and APClient.send_check) then return 0 end

    -- Prefer slot_data's authoritative floor_location_map (post-1.0.4
    -- seeds). Fall back to AP_LOC_FLOOR_FIRST + FLOOR_IDX[floor_n] for
    -- legacy seeds. Map keys are stringified ints ("1", "2") per the
    -- apworld-side convention, but try the int key first defensively in
    -- case any AP client surface delivers them unwrapped.
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

--- Fire any unfired "Complete N Rows" location checks whose threshold the
--- player has now reached. `total_rows` is the game's authoritative
--- correct-row counter (FinishRow event parameter or
--- GameSaveData.CurrentFinishedRowNum). Returns the number of checks sent.
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

-- Live book-placement counter from BP hook. Currently dormant — none of the
-- BP function-name candidates we registered fired in testing. The widget
-- read below is the real source. Kept around in case we add a pak-side BP
-- hook later that forwards a per-book event.
M._books_placed_observed = 0

-- Highest book count we've seen this session. The widget counter can DROP
-- when the player removes books from a shelf, but milestones should never
-- un-fire — once you've placed N books total, the threshold is achieved.
-- Reset on slot-connect.
M._books_placed_peak = 0

-- Read the live "books placed" count from the in-game HUD widget. There are
-- multiple WBP_PlayerInfo_C instances in the world; FindFirstOf returns a
-- stale title-screen one that always reads 0. We walk FindAllOf and take
-- the max — the active gameplay widget has the live count, stale ones read
-- 0. Returns nil if no widget is available yet.
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

-- Returns the highest level-up location marked sent in
-- APClient._sent_checks. The server populates _sent_checks with every
-- previously-checked location at slot_connect, making this the truth
-- source for "what level has this slot reached" across sessions —
-- independent of GameSaveData and the player BP.
--
-- Scans the full 1..AP_MAX_PLAYER_LEVEL range (not contiguous-only)
-- so prior-session gaps still produce a correct upper bound — better
-- to over-credit than under-credit.
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

-- Increments `_levels_reached` by 1 and sends the corresponding AP
-- location check. Called from main.lua's OnLevelUp BP hook — one event
-- per in-game level-up, no dependency on GameSaveData being synced.
--
-- Self-heals from _sent_checks BEFORE incrementing: if baseline sync
-- missed and _levels_reached=0 after a reload, the first OnLevelUp
-- would queue "Reached Level 1" which the server silently dedupes,
-- then Level 2 (dedup), etc. — _levels_reached lags forever. Catching
-- up to the server's view first guarantees the next increment fires a
-- new, unsent level location.
function M.on_level_up_event()
    if not M._slot_data then return end
    -- Defensive: only fire if we're actually in gameplay. BP-level
    -- events should never fire at title, but being explicit prevents a
    -- stale callback or timing edge from spuriously claiming a level
    -- check during title-screen save flushes.
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

    -- Calibration diagnostic: log GameSaveData row count + XP-curve
    -- prediction at OnLevelUp time. CurrentFinishedRowNum may lag by 1
    -- (row update not committed yet) but we mainly care whether the
    -- row count at which the game level-ups matches xp_curve. Player
    -- report: at ~56-59 rows game granted only Level 17, but XP_CURVE
    -- predicts Level 23 at row 55. Paired (row, level) data points
    -- help verify whether XP_CURVE is miscalibrated.
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

-- Reads GameSaveData.GameProgressData and the player's XP curve to:
--   • One-time at baseline (apply-safe): catch up _levels_reached to the
--     player's saved level so loaded saves register prior level-ups.
--     Subsequent level-ups arrive via on_level_up_event().
--   • Every call (baseline + each FinishRow): sync milestone checks based
--     on InsertedBookNum.
function M.sync_progress_state()
    if not M._slot_data then return 0, 0 end

    -- Defensive: never sync state when not in gameplay. Multiple call
    -- sites hit us (FinishRow / SaveGameData hooks); a bad-timing fire
    -- mid-transition to title can read the WRONG save slot and flood
    -- book-milestone checks.
    if not M._gameplay_active then return 0, 0 end
    if not M._apply_safe then return 0, 0 end

    -- Live book count: WBP_PlayerInfo HUD widget's Text_CurrentBookNum.
    -- Save struct's InsertedBookNum is a fallback (first frame, right
    -- after each save). Track peak — a threshold crossed stays crossed
    -- even if the player later removes books.
    --
    -- Save-slot guard: only read GameSaveData when SaveGameName is our
    -- AP slot (Sav_AP_<seed>_<slot>). Mid-transition to title can
    -- revert it to the default "Sav" — the non-AP save might have
    -- books=3072 already and blow past every milestone spuriously.
    --
    -- Crash dump (Failure.Hash same class as player reports) faulted at
    -- null+10 in UE4SS reflection: autosave fired ~330ms before
    -- FinishRow, then sync_progress_state ran while still writing.
    -- sg:IsValid() passed but GameProgressData was being reallocated.
    -- Split chained property reads into validated steps.
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
                    -- Split: capture GameProgressData sub-struct once
                    -- and verify before reading its fields. Without this,
                    -- a concurrent autosave reallocating GameProgressData
                    -- crashes UE4SS's Lua VM on the chained field read.
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
        -- Log once per save-slot mismatch (no heartbeat spam). When
        -- SaveGameName isn't our AP slot, don't trust GameSaveData.
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

    -- Read XP curve from player to compute current level. SkillLevelUpRowNum
    -- values are CUMULATIVE thresholds: Level N is reached at rows >= arr[N].
    -- (Tested empirically: Level 45 = 254 rows total, < 400 total rows in
    -- the game. Sum-based interpretation gives 3500+ which is unreachable.)
    local current_level = 0
    do
        local player = FindFirstOf("BP_LibrarianCharacter_C")
        if player and player:IsValid() then
            -- Split the array fetch from the iteration so the TArray
            -- wrapper is captured once and re-validated — a reallocation
            -- between fetch and iteration would crash UE4SS reading
            -- arr[i] on stale memory.
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

    -- Level-up baseline is handled by run_baseline_sync (first-movement
    -- trigger). After that, on_level_up_event maps the NEXT OnLevelUp
    -- to the right level location.
    --
    -- Belt-and-suspenders here: if _levels_reached ever regresses below
    -- either the XP-curve level or the server's sent floor, raise it
    -- back up. Guards against any path that leaves the counter stale.
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
        -- Fire send_check for every level in the catch-up range. Without
        -- this, the counter advances but checks for skipped levels never
        -- transmit — and the next OnLevelUp would only send N+1, leaving
        -- 1..N stranded. send_check dedupes against _sent_checks, so
        -- re-firing already-sent levels is a silent no-op.
        local APClient = package.loaded["AP/APClient"]
        if APClient and APClient.send_check then
            for level = 1, floor_level do
                APClient:send_check(AP_LOC_LEVEL_FIRST + (level - 1))
            end
            levels_sent = floor_level - prev_levels_reached
        end
    end

    -- Send milestone checks for crossed thresholds. milestone_thresholds is a
    -- list (ordinal-indexed) of book-count integers from slot_data.
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

-- AP item name → in-game EUpgradeAbility index. Used to build a counter
-- baseline from the saved skill levels (keyed by enum index in the save).
local SKILL_ITEM_BY_ABILITY_IDX = {
    [3] = "Progressive Shelf Guide",     -- ShowMatchingShelf
    [5] = "Progressive Sort",            -- SortBooks
    [6] = "Progressive Auto-Shelving",   -- AutoShelve
    [7] = "Progressive Insight",         -- ShowSameTypeBook
    [8] = "Progressive Assemble",        -- GrabSameTypeBook
}

--- Initialise _applied_skill_counts from the loaded save's
--- PlayerExtraData.SkillData TArray. Each entry's CurrentLevel becomes
--- the baseline "applied count" for that AP item, so AP's reconnect
--- re-dump doesn't trigger UpgradePlayer for skills already at level.
---
--- Also refreshes the in-game HUD via WBP_PlayerInfo_C:UpdateSkill —
--- without this, the ability icons stay empty even though the skill is
--- in the save (UpgradePlayer's BP graph normally drives the HUD bind,
--- but we're skipping it here since the level didn't change).
---
--- TArray is 1-indexed in Lua; the array order matches the EUpgradeAbility
--- enum (0..8 → array index 1..9).
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
    local skill_data
    pcall(function() skill_data = sg.PlayerExtraData.SkillData end)
    if not skill_data then
        log("[skill-baseline] no PlayerExtraData.SkillData — skipping init")
        return
    end
    local n = 0
    pcall(function() n = #skill_data end)
    log(("[skill-baseline] save SkillData has %d entries"):format(n))
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

    -- HUD refresh via our LogicMod BP (ModActor_C). Direct UpdateSkill
    -- from Lua crashes (AV, UE4SS in stack) — the BP graph dereferences
    -- SkillObject internals Lua leaves inconsistent. The BP custom
    -- event keeps the call inside engine context.
    M._refresh_hud_from_save()
end

--- Refresh HUD ability icons from save-side levels. Iterates the full
--- 9-entry SkillData TArray and calls our BP mod's RefreshSkillIcon for
--- every skill at level > 0 — including non-AP-tracked skills (Jump,
--- UpgradeBag*, Jogging) which the player gets through normal play.
---
--- Requires LibrarianAPHUDFix.pak in Content/Paks/LogicMods/. If the BP
--- isn't loaded, this no-ops with a warning (skill state still correct
--- in the menu, only the on-screen icon row is missing).
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
    local skill_data
    pcall(function() skill_data = sg.PlayerExtraData.SkillData end)
    if not skill_data then return end

    local n = 0
    pcall(function() n = #skill_data end)

    local refreshed, failed = 0, 0
    -- Refresh all skill icons EXCEPT bags. UpgradeBag (1) / UpgradeBag2
    -- (2) re-apply the bag-level increment via RefreshSkillIcon's BP
    -- graph, double-bumping bag capacity on reload (15 → 20). Bag
    -- levels restore naturally from save. Jump (0) and Jogging (4)
    -- don't have that side effect, so their icons (and Major Magic
    -- icons) ARE refreshed here — else they stay empty until next use.
    local SKIP_INDICES = { [1]=true, [2]=true }
    for i = 1, n do
        local entry
        pcall(function() entry = skill_data[i] end)
        if entry then
            local lvl = 0
            pcall(function() lvl = tonumber(entry.CurrentLevel) or 0 end)
            local ability_idx = i - 1  -- 1-based array → 0-based enum
            if lvl > 0 and ability_idx >= 0 and ability_idx <= 8 and not SKIP_INDICES[ability_idx] then
                -- left=-1 (not 0). 0 crashes the UpdateSkill BP path;
                -- -1 means "no banked points credited" (correct for a
                -- load refresh). 0 means "0 points just spent" → desync.
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

    -- Gate on apply_safe (which implies gameplay_active). Right after
    -- Continue, UpgradePlayer can land before the player+world are fully
    -- wired and the BP graph drops the upgrade silently. Queue until
    -- set_apply_safe(true) drains us — by then the world is settled.
    if not M._gameplay_active or not M._apply_safe then
        log(("queued (not yet apply-safe): %s"):format(name))
        M._pending_skill_grants[#M._pending_skill_grants + 1] = name
        return
    end

    -- Counter-based skip: only bump if we've applied fewer times than the
    -- received-counts say we should. The applied counter is initialised
    -- from save's PlayerExtraData.SkillData at apply-safe time, so an AP
    -- reconnect re-dump (which re-sends every received item) doesn't
    -- double-bump skills already at the right level.
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

--- Periodic skill-state resync. Compares "items the player has received"
--- (_received_counts) against "successful UpgradePlayer calls we've made"
--- (_applied_skill_counts). If the latter lags the former, retry the
--- missing levels via _apply_skill.
---
--- IMPORTANT: trusts _applied_skill_counts as truth, NOT
--- GameSaveData.PlayerExtraData.SkillData. Save's SkillData only
--- refreshes on save events; between saves it can read 0 while the
--- in-game player is level 5+. A previous version used save state for
--- the comparison and over-granted catastrophically (every tick read
--- save_level=0 and re-applied the entire target → every skill to
--- level 10 within ~30 seconds).
---
--- _applied_skill_counts is bumped only when UpgradePlayer's pcall
--- returns ok. Silent BP-side drops (pcall ok but no in-game effect)
--- won't be caught here — would need a runtime-state read.
---
--- Conservative: only ever applies UP to received count. Never over-grants.
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

--- Print the current derived state. Callable from a UE4SS console / dev
--- keybind for ad-hoc debugging; not wired to any user-facing keybind.
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

--- Walk every BP_GrabbingBook_C whose series is in _series_unlocked and
--- report its actor-level state — bHidden, collision-enabled, and the
--- _books_warded/_books_we_have_hidden tracking flags. If a book in an
--- unlocked series still has bHidden=true or collision=false, our Pass 1
--- failed to unward it (most likely because _books_warded[key] was nil
--- when the apply ran, so the unward branch was skipped).
---
--- Each problematic book is logged with full identifying info; series
--- with all books in the correct state are summarized as "OK".
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
                            hidden_by_us = M._books_we_have_hidden[key] and true or false,
                            has_ref = M._book_hism_refs[key] and true or false,
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
                log(("      aidx=%d hidden=%s coll=%s _warded=%s _hidden_by_us=%s has_ref=%s unmapped=%s @ (%.0f, %.0f, %.0f)"):format(
                    p.aidx,
                    tostring(p.hidden), tostring(p.coll),
                    tostring(p.warded_tracked), tostring(p.hidden_by_us),
                    tostring(p.has_ref), tostring(p.is_unmapped),
                    p.x, p.y, p.z))
            end
        else
            log(("  [%s] '%s' OK: %d book(s) pickable"):format(b.section, sname, b.total))
        end
    end
end

--- Print every book that we couldn't HISM-map. These render via the
--- actor's own mesh component at the actor's RootComponent world position,
--- which can be inside walls/floors if the level designer placed the
--- trigger there (the actual visible HISM instance is elsewhere on the
--- shelf, but we lost the link to it).
---
--- Use this to verify that the books appearing stuck in walls/floors are
--- the SAME books across runs (deterministic level layout → same set).
--- Coordinates are in cm (UE default). The 'unlocked' flag tells you
--- whether the book is currently unwarded (visible) right now.
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
-- Force-unward every book whose series name contains a substring (case-
-- insensitive). Bypasses slot_data / _series_unlocked entirely — books just
-- get SetActorHiddenInGame(false) + SetActorEnableCollision(true), and the
-- tracker is cleared so the next normal apply won't re-ward them this session.
-- The fence cover on the case stays in place (we don't touch _shelves_open or
-- _case_covers), which is exactly what's needed for testing whether the fence
-- collision is blocking grabs of books that don't physically stick past the
-- case front.
--
-- Usage (UE4SS console / debug console):
--   ap_unward_series Seduction Magic
--   ap_unward_series Theological Research on Holy Magic
--
-- The pattern matches any series name containing the substring, so you can
-- be as specific or loose as you want. Logs the matched series + count of
-- books that were force-unwarded.
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
    -- UE4SS passes parameters as a table of space-split tokens; rejoin
    -- so multi-word series names like "Seduction Magic" work.
    local pattern = ""
    if type(params) == "table" then
        pattern = table.concat(params, " ")
    elseif type(params) == "string" then
        pattern = params
    end
    pcall(function() M.force_unward_series(pattern) end)
    return true
end)

return M
