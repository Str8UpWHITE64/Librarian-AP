-- AP/statelog.lua
-- The STATE snapshot line for the run log: slot, books unlocked and shelved, rows, checks, level
-- and goal, read from counters the other modules already keep. Nothing here walks actors.
local M = {}

local GOALS = { [0] = "full library", [1] = "custom", [2] = "floor 1", [3] = "floor 2" }

local function count_keys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--- Books unlocked and the library total, from the item tables.
local function books(IA)
    local total = 0
    for _, v in pairs(IA._asset_to_volumes or {}) do total = total + (tonumber(v) or 0) end
    if IA._per_book_unlocks then return count_keys(IA._books_unlocked), total end
    local n = 0
    for aidx, sname in pairs(IA._asset_to_series or {}) do
        if IA._series_unlocked and IA._series_unlocked[sname] then
            n = n + (tonumber((IA._asset_to_volumes or {})[aidx]) or 0)
        end
    end
    return n, total
end

local function goal_text(sd)
    local name = GOALS[sd.goal] or ("goal " .. tostring(sd.goal))
    local want = tonumber(sd.goal_row_threshold)
    local by_books = sd.goal == 1 and (sd.goal_counts_books == 1
        or (sd.goal_counts_books == nil and sd.book_sanity == 1))
    if by_books then want = tonumber(sd.goal_book_threshold) end
    if sd.goal == 1 and want then
        return ("%s (%d %s)"):format(name, want, by_books and "books shelved" or "rows")
    end
    return name
end

--- The sentence after "STATE ", or nil before a slot is connected.
function M.snapshot()
    local AC = package.loaded["AP/APClient"]
    local IA = package.loaded["AP/ItemApply"]
    if not (AC and IA and AC._slot_connected) then return nil end
    local sd = AC.slot_data or {}
    local unlocked, total = books(IA)
    local sent = count_keys(AC._sent_checks)
    local slots = count_keys(AC._slot_locations)
    local shelved = IA._count_total
    local rows = (IA._rows_by_case_epoch == (IA._world_epoch or 0)) and IA._rows_by_case or nil
    return ("slot=%s books_unlocked=%d/%d shelved=%s rows_done=%s checks=%d/%d level=%d goal=%s"):format(
        tostring(AC.slot), unlocked, total, shelved and tostring(shelved) or "?",
        rows and tostring(rows) or "?", sent, slots > 0 and slots or sent,
        tonumber(IA._levels_reached) or 0, goal_text(sd))
end

local RL = package.loaded["AP/runlog"]
if RL then RL.set_snapshot(M.snapshot) end
return M
