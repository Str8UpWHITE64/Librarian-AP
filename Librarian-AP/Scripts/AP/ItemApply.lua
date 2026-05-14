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

-- ============================================================================
-- Constants (mirrors apworld/librarian/data.py::UpgradeAbility)
-- ============================================================================

-- AP location ID layout (mirrors apworld/librarian/Locations.py)
local AP_BASE              = 1910000
local AP_LOC_LEVEL_FIRST   = AP_BASE + 560   -- 45 entries: Level 1..45
local AP_LOC_MILESTONE_FIRST = AP_BASE + 640 -- 22 entries: aligned to MILESTONE_THRESHOLDS order
local AP_LOC_ROW_COMPLETION_FIRST = AP_BASE + 1000 -- 50 entries: aligned to ROW_COMPLETION_THRESHOLDS order
local AP_MAX_PLAYER_LEVEL  = 45

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

-- Highest player level we've sent a "Reached Level N" check for. Synced from
-- GameSaveData ONCE at apply-safe (baseline) so loaded saves catch up to
-- their actual level. Subsequent level-ups arrive via the OnLevelUp BP
-- hook → on_level_up_event(), which increments and sends per-event.
-- (Avoids reading GameSaveData.CurrentFinishedRowNum at OnLevelUp time —
-- empirically that field hasn't updated yet when the event fires.)
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
    M._received_counts    = {}
    M._series_unlocked    = {}
    M._shelves_open       = {}
    M._pending_skill_grants = {}
    M._applied_skill_counts = {}
    M._sent_row_locations = {}
    M._sent_row_completions = {}
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
    -- Allow pre-apply: the OpenLevel-on-connect that main.lua fires right
    -- after this will trigger a fresh M01 LoadMap → apply-gate retry loop.
    -- main.lua's title-button logic keeps Continue disabled until
    -- _pre_apply_complete flips true (after the deferred tree-walk drains).
    M._allow_pre_apply = true
    M._pre_apply_complete = false
    log("Slot data set; per-connection state reset; pre-apply enabled")

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
        end
        -- Drop pending skill grants — they'll be re-queued on the next
        -- slot_connect via set_slot_data's reset + AP item re-dump.
        if #M._pending_skill_grants > 0 then
            log(("Clearing %d pending skill grants (left gameplay)"):format(#M._pending_skill_grants))
            M._pending_skill_grants = {}
        end
    end
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
    -- During pre-apply (post-connect title, before player clicks Continue),
    -- skip the per-item world flush. The starting-item dump can be 14+
    -- items; flushing per item is wasteful (each iterates all 3072 books)
    -- AND causes visual flicker because earlier items see "everything
    -- warded" state and later items un-ward incrementally. Instead, just
    -- update derived state here — the pre-apply settle loop in main.lua
    -- fires ONE flush_apply once items quiet down, so the world is warded
    -- exactly once with the FINAL post-starting-items state.
    if M._allow_pre_apply and not M._gameplay_active then
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

--- Return the BP_GrabbingBook_C actor's AssetIdx if the book is
--- initialized (real game data), or nil if it's an orphan / uninitialized
--- actor whose ItemInfo has default field values.
---
--- AssetIdx=0 is a VALID game asset ("Monsterology: An Introduction to
--- Forbidden Beast" in section 1A — the first declared series in
--- data.py). Gating on `AssetIdx > 0` therefore skips that series and
--- leaves its 10 books permanently un-warded, even when they're in
--- off-floor scope. We disambiguate by checking ItemInfo.Mesh: real
--- books have a populated UStaticMesh*, orphan actors from the
--- OpenLevel-on-connect reload leave it nil. For AssetIdx > 0 we trust
--- the value directly — default-constructed ItemInfo can't produce a
--- non-zero index, so any non-zero AssetIdx implies an initialized book.
local function _book_valid_asset_idx(book)
    if not book or not book:IsValid() then return nil end
    local info; pcall(function() info = book.ItemInfo end)
    if not info then return nil end
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
    pcall(function() comp:MarkRenderStateDirty() end)
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
--- Only runs when slot_data.book_visibility == "hidden". The shipped v1
--- config emits "stacks" unconditionally, so this code path is dormant
--- by default — kept for possible re-introduction once a cleaner approach
--- (per-instance opacity via custom material) is available.
M._hism_initialized = false
M._book_captured_transforms = {}         -- key → HISM original transform
M._books_we_have_hidden = {}             -- key → true if our hide moved this book
M._books_warded = {}                     -- key → true if actor.bHidden + collision-off applied

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
    M._hism_initialized = false
    M._book_captured_transforms = {}
    M._books_we_have_hidden = {}
    M._books_warded = {}
    M._unmapped_warded_books = {}
    M._last_applied_series_unlocked = {}
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
    -- mark warded books (the ones we'll need to hide). Same rule as
    -- _apply_books_to_world Pass 1 — the only_unward_shelfable_books
    -- toggle gates whether the bookcase-side check is added on top of
    -- the series unlock.
    local only_shelfable = M._slot_data
        and M._slot_data.only_unward_shelfable_books == 1
    local shelf_req_map = (M._slot_data and M._slot_data.shelf_req_map) or {}
    local is_warded_book = {}
    local warded_count, unwarded_count, uninit_count = 0, 0, 0
    for i = 1, bn do
        local b = books[i]
        if b and b:IsValid() then
            local asset_idx = _book_valid_asset_idx(b)
            if asset_idx ~= nil then
                local series = M._asset_to_series[asset_idx]
                local section_id = M._asset_to_section[asset_idx]
                local series_open = series and M._series_unlocked[series]
                local should_unward = series_open
                if only_shelfable and series_open and section_id then
                    local needed = shelf_req_map[series]
                    if needed and needed > 0 then
                        local open = M._shelves_open[section_id] or 0
                        if open < needed then should_unward = false end
                    end
                end
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

    -- Phase 5: for warded books that didn't get mapped (BookInfo-canonical
    -- collisions where another book "stole" their canonical via the bulk
    -- mark), spawn a NEW HISM instance per book using
    -- ModActor.AddHISMInstance. Each loser book ends up with its own
    -- (HISM, idx), enabling independent hide/show.
    --
    -- Process per unmapped book:
    --   1. Mark with a Phase-5-unique Z so we can find which HISM's
    --      canonical it owns.
    --   2. Scan HISMs for that Z → (H, idx) is the canonical.
    --   3. AddHISMInstance(H, captured_transform) → new instance idx.
    --   4. Restore the canonical to natural via mgr:UpdateInstance so
    --      the dupe partner (the winning book at this canonical) is back
    --      at its rendered position.
    --   5. Record loser book → (H, new_idx, captured_transform).
    local mod_actor = FindFirstOf("ModActor_C")
    local added, add_failed_no_canonical, add_failed_addinstance = 0, 0, 0
    local first_add_logged = 0
    local PHASE5_BASE = -3000000.0  -- separate range from Phase 3 markers
    for i = 1, bn do
        if is_warded_book[i] then
            local key = book_keys[i]
            if key and not M._book_hism_refs[key] then
                local b = books[i]
                if b and b:IsValid() then
                    local info; pcall(function() info = b.ItemInfo end)
                    if info then
                        local marker_z = PHASE5_BASE - i
                        local marker = {
                            Rotation    = {X=0, Y=0, Z=0, W=1},
                            Translation = {X=0, Y=0, Z=marker_z},
                            Scale3D     = {X=1, Y=1, Z=1},
                        }
                        pcall(function() mgr:UpdateInstance(info, marker) end)

                        -- Scan for this unique Z. Short-circuit on first hit.
                        local found_h, found_idx_lua, found_orig = nil, nil, nil
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
                                                    if z and math.abs(z - marker_z) < 0.5 then
                                                        found_h = h
                                                        found_idx_lua = ji
                                                        found_orig = captured[hi] and captured[hi][ji]
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            if found_h then break end
                        end

                        -- Capture diagnostic fields for this book up-front. If
                        -- we end up failing to map it, we want to know which
                        -- specific book is stuck so the user can verify it's
                        -- the same set across runs. AssetIdx=0 is a valid game
                        -- index (Monsterology series), so we don't gate on > 0.
                        local diag_aidx
                        pcall(function() diag_aidx = info.AssetIdx end)
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

                        if not (found_h and found_orig) then
                            add_failed_no_canonical = add_failed_no_canonical + 1
                            record_unmapped()
                        else
                            -- Try direct AddInstance on the HISM first; fall
                            -- back to ModActor wrapper if direct call fails.
                            local new_idx = nil
                            pcall(function() new_idx = found_h:AddInstance(found_orig, true) end)
                            local via = "direct"
                            if not new_idx and mod_actor and mod_actor:IsValid() then
                                pcall(function()
                                    new_idx = mod_actor:AddHISMInstance(found_h, found_orig)
                                end)
                                via = "modactor"
                            end
                            if first_add_logged < 3 then
                                first_add_logged = first_add_logged + 1
                                log(("[hism-init] Phase5 sample: book i=%d marker_z=%.1f found_idx_lua=%s new_idx=%s via=%s"):format(
                                    i, marker_z, tostring(found_idx_lua),
                                    tostring(new_idx), via))
                            end
                            if new_idx then
                                M._book_hism_refs[key] = { hism = found_h, idx = new_idx }
                                M._book_captured_transforms[key] = found_orig
                                added = added + 1
                            else
                                add_failed_addinstance = add_failed_addinstance + 1
                                record_unmapped()
                            end
                            -- Restore canonical to natural (so the winning dupe
                            -- partner's rendered mesh is back in place).
                            pcall(function() mgr:UpdateInstance(info, found_orig) end)
                        end
                    end
                end
            end
        end
    end

    log(("[hism-init] captured=%d marked=%d mapped=%d added=%d (no_canonical=%d addinstance_failed=%d)"):format(
        cap_count, marked_count, mapped, added,
        add_failed_no_canonical, add_failed_addinstance))

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

--- Hide a book's HISM instance. Uses per-instance UpdateHISMInstance
--- via ModActor — moves only this book's specific HISM instance, not
--- the canonical (which other dupe-partner books may share). Books
--- without a recorded (HISM, idx) ref (e.g. failed Phase 5 AddInstance)
--- silently no-op — they remain visible (the documented edge case).
--- Tracked in M._books_we_have_hidden so we know whether to restore.
function M._hide_book_in_hism(book)
    if not book or not book:IsValid() then return end
    local key = book:GetFullName()
    if M._books_we_have_hidden[key] then return end

    local ref = M._book_hism_refs[key]
    if not ref then return end
    local orig = M._book_captured_transforms[key]
    local rot = (orig and orig.Rotation) or {X=0, Y=0, Z=0, W=1}
    local far_t = {
        Rotation    = rot,
        Translation = {X=0, Y=0, Z=-1000000.0},
        Scale3D     = {X=1, Y=1, Z=1},
    }
    local mod_actor = FindFirstOf("ModActor_C")
    if mod_actor and mod_actor:IsValid() then
        pcall(function() mod_actor:UpdateHISMInstance(ref.hism, ref.idx, far_t) end)
    end

    M._books_we_have_hidden[key] = true
end

--- Restore a book's HISM instance to natural transform via per-instance
--- UpdateHISMInstance. No-op for books we never hid.
function M._show_book_in_hism(book)
    if not book or not book:IsValid() then return end
    local key = book:GetFullName()
    if not M._books_we_have_hidden[key] then return end

    local ref = M._book_hism_refs[key]
    local orig = M._book_captured_transforms[key]
    if ref and orig then
        local mod_actor = FindFirstOf("ModActor_C")
        if mod_actor and mod_actor:IsValid() then
            pcall(function() mod_actor:UpdateHISMInstance(ref.hism, ref.idx, orig) end)
        end
    end

    M._books_we_have_hidden[key] = nil
end

--- Toggle a book actor's mesh visibility. Tree-walk AttachChildren +
--- BlueprintCreatedComponents.
---
--- NOTE: We do NOT call SetActorVisible(visible) here. That's the game's
--- own BP-graph visibility function, and the BP Tick reverts it to the
--- "expected" state every frame — leading to a brief disappear-then-
--- reappear flicker. We instead rely on the actor displacement done
--- by _hide_book_in_hism to keep warded books out of view.
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
                pcall(function() c:MarkRenderStateDirty() end)
            end
        end
    end
end

--- Walk every BP_GrabbingBook_C in the level and ward/unward based on
--- whether its series is in _series_unlocked. Section is NOT part of the
--- per-book gate — section unlocks affect bookcase/shelf visibility (phase 2).
function M._apply_books_to_world()
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

    local hide_mesh = M._slot_data
        and M._slot_data.book_visibility == "hidden"

    -- only_unward_shelfable_books (YAML toggle, default off): when set, a
    -- book is only unwarded if BOTH its series is received AND its target
    -- bookcase is open. The shelf_req_map is the per-series bookcase index
    -- needed (series_name → required shelf count). Disabled by default to
    -- preserve the "pick up any unlocked-series book, mis-shelf and recover"
    -- gameplay loop.
    local only_shelfable = M._slot_data
        and M._slot_data.only_unward_shelfable_books == 1
    local shelf_req_map = (M._slot_data and M._slot_data.shelf_req_map) or {}

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
                local idx
                pcall(function() idx = b.ItemInfo.AssetIdx end)
                if idx and idx > 0 and not sample[idx] then
                    sample[idx] = true
                    distinct = distinct + 1
                    if distinct >= 2 then break end
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

    local warded, unwarded, skipped = 0, 0, 0

    -- Pass 1 (fast, both modes): actor.bHidden + collision toggles in one
    -- tight loop across all books. This stops pickup on every soon-to-be-
    -- warded book before the slow Pass 2 visual hide drains — so the
    -- player can't grab a doomed book while warding is still animating.
    -- Each call is idempotent (UE no-ops if the flag is already correct);
    -- M._books_warded tracks state to keep redundant calls cheap on
    -- subsequent applies.
    for i = 1, n do
        local book = books[i]
        if book and book:IsValid() then
            -- Skip uninitialized books (orphan actors from the
            -- OpenLevel-on-connect reload have default BookInfo and
            -- trying to ward them via mgr.UpdateInstance corrupts HISM
            -- state). _book_valid_asset_idx returns nil for orphans
            -- but 0 for the real Monsterology series (section 1A).
            local asset_idx = _book_valid_asset_idx(book)
            if asset_idx ~= nil then
                local series_name = M._asset_to_series[asset_idx]
                local section_id = M._asset_to_section[asset_idx]
                -- Default rule: any book in an unlocked series is pickable
                -- (the player can mis-shelve and recover). With the YAML
                -- toggle only_unward_shelfable_books = 1, ADD a
                -- shelf-side check — the book stays warded until its
                -- own bookcase is also open. The Python world's
                -- milestone access rule is paired with this toggle so
                -- the two stay in sync.
                local series_open = series_name and M._series_unlocked[series_name]
                local should_unward = series_open
                if only_shelfable and series_open and section_id then
                    local needed = shelf_req_map[series_name]
                    if needed and needed > 0 then
                        local open = M._shelves_open[section_id] or 0
                        if open < needed then should_unward = false end
                    end
                end
                local key = book:GetFullName()
                local is_warded = M._books_warded[key] or false
                local ok = pcall(function()
                    if should_unward then
                        if is_warded then
                            book:SetActorHiddenInGame(false)
                            book:SetActorEnableCollision(true)
                            M._books_warded[key] = nil
                        end
                    else
                        if not is_warded then
                            book:SetActorHiddenInGame(true)
                            book:SetActorEnableCollision(false)
                            M._books_warded[key] = true
                        end
                    end
                end)
                if ok then
                    if should_unward then unwarded = unwarded + 1
                    else warded = warded + 1 end
                else
                    skipped = skipped + 1
                end
            else
                skipped = skipped + 1
            end
        end
    end

    -- Pass 2 (slow, hidden mode only): HISM teleport + deferred tree-walk
    -- queue. Skipped entirely in stacked mode — Pass 1 is sufficient there.
    -- Idempotency tracked separately via M._books_we_have_hidden, which
    -- the _hide_book_in_hism / _show_book_in_hism helpers maintain.
    if hide_mesh then
        for i = 1, n do
            local book = books[i]
            if book and book:IsValid() then
                local asset_idx = _book_valid_asset_idx(book)
                if asset_idx ~= nil then
                    local series_name = M._asset_to_series[asset_idx]
                    local section_id = M._asset_to_section[asset_idx]
                    -- Same rule as Pass 1 — toggle gates the shelf-side
                    -- intersection. Default off keeps the old visibility
                    -- behavior; on adds the shelf check.
                    local series_open = series_name and M._series_unlocked[series_name]
                    local should_unward = series_open
                    if only_shelfable and series_open and section_id then
                        local needed = shelf_req_map[series_name]
                        if needed and needed > 0 then
                            local open = M._shelves_open[section_id] or 0
                            if open < needed then should_unward = false end
                        end
                    end
                    local key = book:GetFullName()
                    local is_hidden_by_us = M._books_we_have_hidden[key] or false
                    pcall(function()
                        if should_unward then
                            if is_hidden_by_us then
                                M._show_book_in_hism(book)
                                M._queue_book_visibility(book, true)
                            end
                        else
                            if not is_hidden_by_us then
                                M._hide_book_in_hism(book)
                                M._queue_book_visibility(book, false)
                            end
                        end
                    end)
                end
            end
        end
    end

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
    log(("State: sections-active=%d series=%d | applied: unwarded=%d warded=%d skipped=%d"):format(
        section_n, series_n, unwarded, warded, skipped))
end

-- ============================================================================
-- Apply: Bookcases (Phase 2a — section-gated visibility)
-- ============================================================================

-- Each section has exactly one BP_M01_CabinetLabel_01_C in the world. The
-- label's `Label Number` (int32) ordinally maps to a section: 1..14 → 1A..1N,
-- 21..37 → 2A..2Q (the gap 15-20 reflects unused slots from level design).
-- Each label's `CountBookCase` (TArray<AActor>) holds the actors that fill
-- that section — sometimes direct BookCases, sometimes wrapper actors
-- (BP_M01_PillarCabinet_01_01_C, BP_M01_Cabinet_01_C).
--
-- This is the authoritative mapping. CDI[1]-based derivation was unreliable
-- because data.py's series→section assignments are wrong for ~10 sections
-- (series mistakenly grouped under 2E/1B that actually live in 1C/1D/1G/1H/
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

    -- Stray-case sweep: every BookCase actor in the level that wasn't
    -- added via a CabinetLabel walk is treated as a "stray" — a level-
    -- design artifact (e.g., a case tucked into a wall corner) that
    -- isn't part of any AP section. The game's placement system can
    -- still find these by aim angle and accept books on them, but the
    -- player can't navigate back to retrieve those books — softlock.
    -- We collect them here and keep them permanently hidden + collision-
    -- off via _apply_bookcases_to_world. _case_key matches the add_case
    -- key so already-indexed cases aren't re-classified as strays.
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

--- Per-section visibility: cases sorted by (vol_tier asc, BookOrderIdx asc),
--- with visible_count = min(shelves_open[section], n_cases).
--- The first `visible_count` cases of each section are shown, the rest hidden.
--- Each Progressive Shelf Unlock (section) item received increments shelves_open
--- and reveals the next bookcase. Smaller-vol cases (4x5) unlock first, which
--- mirrors the AP world's per-section shelf_req ordering — so series in 5-vol
--- cases become reachable before series in 10-vol cases.
--- Operates only on BP_BookCase_C actors so structural wrapper meshes
--- (pillars, walls) stay visible. Idempotent.
function M._apply_bookcases_to_world()
    if not M._cases_indexed then return end
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
                local ok = pcall(function()
                    case:SetActorHiddenInGame(not visible)
                    case:SetActorEnableCollision(visible)
                    -- Tree-walk child components too. SetActorHiddenInGame
                    -- doesn't always propagate (same issue as BP_GrabbingBook).
                    -- BP_BookCase has UStaticMeshComponent children (StaticMesh,
                    -- PreviewBookLocation) that can stay in the previous state
                    -- otherwise. Symmetric: hide-children when hiding the
                    -- case, show-children when revealing it (a shelf unlock
                    -- that flips a case from hidden->visible needs the show
                    -- pass or the case stays invisible despite the actor flag).
                    local root = case:K2_GetRootComponent()
                    if root and root:IsValid() then
                        _walk_set_visibility(root, visible)
                    end
                    local comps
                    pcall(function() comps = case.BlueprintCreatedComponents end)
                    if comps then
                        local cn = 0; pcall(function() cn = #comps end)
                        for j = 1, cn do
                            local c = comps[j]
                            if c and c:IsValid() then
                                pcall(function() c:SetVisibility(visible, false) end)
                                pcall(function() c:SetHiddenInGame(not visible, false) end)
                                pcall(function() c:MarkRenderStateDirty() end)
                            end
                        end
                    end
                end)
                if ok then
                    if visible then shown = shown + 1 else hidden = hidden + 1 end
                else
                    dead = dead + 1
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
    for i = 1, #M._stray_cases do
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
                            pcall(function() c:MarkRenderStateDirty() end)
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
    local key = string.format("%d/%d/%d/%d", shown, hidden, dead, stray_disabled)
    if M._last_apply_log_key ~= key then
        log(("Bookcases: shown=%d hidden=%d dead=%d stray=%d"):format(
            shown, hidden, dead, stray_disabled))
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

-- Walks every indexed bookcase and detects newly-complete series.
--
-- Authoritative trigger: the game's own per-case RowStatus list. The game
-- only appends to a case's RowStatus when it considers a row complete on
-- that case — correct series, all volumes, in volume order. If the player
-- places books in the wrong order, or in the wrong section, or splits a
-- series across rows, RowStatus does not grow and we don't fire.
--
-- When a case's RowStatus length grows, we walk PlacingBookInfo on that
-- case to find which AssetIdx now has count >= expected_volumes and hasn't
-- already been fired. Where on the case (which bookcase slot) the series
-- lives doesn't matter — the game's RowStatus already validated it. We
-- only need to identify the AssetIdx for the AP location lookup.
function M.detect_completed_rows()
    if not M._cases_indexed then return 0 end
    if not M._slot_data then return 0 end
    local row_loc_map = M._slot_data.row_location_map
    if type(row_loc_map) ~= "table" then return 0 end

    local sent_count = 0
    for sid, cases in pairs(M._section_to_cases) do
        for _, case in ipairs(cases) do
            if case and case:IsValid() then
                -- Game's authoritative completion count for this case.
                local current_rows = 0
                pcall(function() current_rows = #case.RowStatus end)

                if current_rows > 0 then
                    -- At least one row is complete on this case. Walk
                    -- PlacingBookInfo to find which AssetIdx(s) have a
                    -- full volume count placed. We always re-sweep (not
                    -- gated on count diff) so a "complete -> remove ->
                    -- recomplete in same case" cycle fires the new
                    -- series's check correctly.
                    local current = {}
                    pcall(function()
                        local pbi = case.PlacingBookInfo
                        if pbi then
                            local n = 0; pcall(function() n = #pbi end)
                            for i = 1, n do
                                local book = pbi[i]
                                if book and book:IsValid() then
                                    local aidx
                                    pcall(function()
                                        aidx = tonumber(book.ItemInfo.AssetIdx)
                                    end)
                                    if aidx and aidx >= 0 then
                                        current[aidx] = (current[aidx] or 0) + 1
                                    end
                                end
                            end
                        end
                    end)

                    -- Sweep full-count, home-section series in the case
                    -- and split them into:
                    --   • candidates  = unfired, eligible to fire this pass
                    --   • already_fired = previously-sent series still
                    --                     occupying RowStatus slots
                    --
                    -- already_fired comes from the CURRENT PBI state (NOT
                    -- a sticky per-case flag), so a series we fired earlier
                    -- and the player has since removed no longer counts
                    -- against the cap. That's what unblocks the
                    -- "complete A → remove A → complete B in same case"
                    -- case the old count-diff guard missed.
                    --
                    -- Home-section filter rejects misplaced cross-section
                    -- books. Sort by AssetIdx so deterministic order when
                    -- multiple series happen to be complete at once.
                    local candidates = {}
                    local already_fired = 0
                    for aidx, count in pairs(current) do
                        local expected = M._asset_to_volumes[aidx] or 0
                        if expected > 0 and count >= expected
                                and M._asset_to_section[aidx] == sid then
                            local series_name = M._asset_to_series[aidx]
                            local map_key = sid .. "|" .. (series_name or "")
                            local loc_id = row_loc_map[map_key]
                            if loc_id then
                                if M._sent_row_locations[loc_id] then
                                    already_fired = already_fired + 1
                                else
                                    candidates[#candidates + 1] = {
                                        aidx = aidx,
                                        loc_id = loc_id,
                                        name = series_name,
                                    }
                                end
                            elseif series_name then
                                log(("[row-detect] %s / %s -- no loc_id in row_location_map"):format(
                                    sid, series_name))
                            end
                        end
                    end
                    table.sort(candidates, function(a, b) return a.aidx < b.aidx end)

                    -- Cap fires by remaining RowStatus capacity.
                    local cap = current_rows - already_fired
                    if cap > 0 and #candidates > 0 then
                        local to_fire = math.min(cap, #candidates)
                        for k = 1, to_fire do
                            local c = candidates[k]
                            M._sent_row_locations[c.loc_id] = true
                            log(("[row-detect] %s / %s (AssetIdx %d) -> loc %d"):format(
                                sid, c.name, c.aidx, c.loc_id))
                            local APClient = package.loaded["AP/APClient"]
                            if APClient and APClient.send_check then
                                APClient:send_check(c.loc_id)
                                sent_count = sent_count + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return sent_count
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

-- Increments `_levels_reached` by 1 and sends the corresponding AP location
-- check. Called from main.lua's OnLevelUp BP hook — one event per in-game
-- level-up, so the counter stays in lockstep without depending on
-- GameSaveData being synchronously updated.
function M.on_level_up_event()
    if not M._slot_data then return end
    if M._levels_reached >= AP_MAX_PLAYER_LEVEL then return end
    M._levels_reached = M._levels_reached + 1
    local loc = AP_LOC_LEVEL_FIRST + (M._levels_reached - 1)
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

    -- Live book count: read from the active WBP_PlayerInfo HUD widget's
    -- Text_CurrentBookNum (the on-screen counter). The save struct's
    -- InsertedBookNum is a fallback for the first frame and for the
    -- moment right after each save event.
    --
    -- Books placed never logically decreases for milestone purposes — a
    -- threshold crossed is a threshold crossed even if the player later
    -- removes books from a shelf. So we track the peak observed value
    -- and use that for milestone evaluation.
    local rows_finished = 0
    local books_placed_save = 0
    pcall(function()
        local gi = FindFirstOf("BP_LibrarianGameInstance_C") or FindFirstOf("LibrarianGameInstanceBase")
        if gi and gi:IsValid() then
            local sg = gi.GameSaveData
            if sg and sg:IsValid() then
                pcall(function() rows_finished     = tonumber(sg.GameProgressData.CurrentFinishedRowNum) or 0 end)
                pcall(function() books_placed_save = tonumber(sg.GameProgressData.InsertedBookNum) or 0 end)
            end
        end
    end)
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
            pcall(function()
                local arr = player.SkillLevelUpRowNum
                local n = 0; pcall(function() n = #arr end)
                for i = 1, math.min(n, AP_MAX_PLAYER_LEVEL) do
                    local needed = tonumber(arr[i]) or 0
                    if rows_finished >= needed then
                        current_level = i
                    else
                        return
                    end
                end
            end)
        end
    end

    -- Level-up checks are sent ONLY via on_level_up_event() during play.
    -- We don't baseline-sync from CurrentFinishedRowNum because that field
    -- has been observed to return non-zero on fresh saves (semantics
    -- unclear or stale-read at apply-safe time), which spuriously fires
    -- "Reached Level 1" on new games. Trade-off: a save loaded mid-run
    -- doesn't replay missed level checks, but the AP server already has
    -- those from the prior session if OnLevelUp fired correctly.
    local levels_sent = 0
    if not M._level_baseline_done then
        log(("[progress] baseline rows=%d (level-sync skipped — will track via OnLevelUp events)"):format(
            rows_finished))
        M._level_baseline_done = true
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

    -- HUD refresh: route through our LogicMod BP (ModActor_C). Calling
    -- UpdateSkill from Lua direct crashed (EXCEPTION_ACCESS_VIOLATION,
    -- UE4SS in stack) because the BP graph dereferences SkillObject
    -- internals that Lua leaves in inconsistent state. Going via a BP
    -- custom event keeps the call inside engine context, where dispatch
    -- works the same as the game's natural UpgradePlayer flow.
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
    -- Refresh all skill icons EXCEPT the bag ones. UpgradeBag (1) and
    -- UpgradeBag2 (2) have a side effect in RefreshSkillIcon's BP graph
    -- that re-applies the bag-level increment, observed to double-bump
    -- the player's bag capacity on reload (15 → 20). The game restores
    -- the actual bag level from save data naturally on load. Jump (0)
    -- and Jogging (4) don't have that side effect, so their icons (and
    -- the five Major Magic icons) are still worth refreshing here —
    -- otherwise they stay empty until the next in-game skill use.
    local SKIP_INDICES = { [1]=true, [2]=true }
    for i = 1, n do
        local entry
        pcall(function() entry = skill_data[i] end)
        if entry then
            local lvl = 0
            pcall(function() lvl = tonumber(entry.CurrentLevel) or 0 end)
            local ability_idx = i - 1  -- 1-based array → 0-based enum
            if lvl > 0 and ability_idx >= 0 and ability_idx <= 8 and not SKIP_INDICES[ability_idx] then
                -- left=-1 (not 0). 0 crashes the UpdateSkill BP path; the
                -- game itself passes -1 here, meaning "no banked points
                -- credited" — correct for a load refresh;
                -- 0 tells the HUD "0 points just spent" and desyncs state.
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

return M
