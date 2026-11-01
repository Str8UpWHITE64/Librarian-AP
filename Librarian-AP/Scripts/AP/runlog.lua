-- AP/runlog.lua
-- One log file per launch: Mods/Librarian-AP/logs/AP_<YYYY-MM-DD_HH-MM-SS>.log, newest ten kept.
-- UE4SS rewrites UE4SS.log every start and mixes in every other mod, so this file is the one a
-- player sends with a bug report.
--
-- Line format:  HH:MM:SS.mmm LEVEL [category] sentence
-- Categories: start config conn items checks state death goal error, plus a few feature tags.
-- DEBUG lines are written only when "debug": true is set in ap_config.json.
--
-- Most of the mod still logs through print. print is wrapped once and each line is sorted into
-- a level and category from its tag and text; lines that matter are written with M.event.
-- Milliseconds come from the game-thread clock (M.advance); it restarts at each wall-clock
-- second, so lines order correctly within a second.
local M = { file = nil, name = nil, debug = false, force = nil }
local DIR, KEEP = "Mods/Librarian-AP/logs", 10
local INDEX = DIR .. "/index.txt"

local clock_ms, sec_base, sec_last = 0, 0, nil
local held = {}          -- DEBUG lines written before the config said whether to keep them
local HELD_MAX = 300
local snapshot_every, snapshot_at = 300, nil

local function read_index()
    local names = {}
    local f = io.open(INDEX, "r")
    if f then
        for line in f:lines() do
            if #line > 0 then names[#names + 1] = line end
        end
        f:close()
    end
    return names
end

local function open_run()
    local names = read_index()
    local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
    local name = ("%s/AP_%s.log"):format(DIR, (ok and stamp) or "run")
    local f = io.open(name, "w")
    if not f then return nil end
    names[#names + 1] = name
    while #names > KEEP do
        pcall(os.remove, table.remove(names, 1))
    end
    local ix = io.open(INDEX, "w")
    if ix then
        ix:write(table.concat(names, "\n"), "\n")
        ix:close()
    end
    return f, name
end

--- Advance the millisecond clock; called once per game-thread tick.
function M.advance(dt_ms)
    local d = tonumber(dt_ms)
    if d and d == d and d >= 0 and d < 1e9 then clock_ms = clock_ms + d end
end

local function stamp()
    local ok, now = pcall(os.time)
    if not ok then return "--:--:--.000" end
    if now ~= sec_last then sec_last, sec_base = now, clock_ms end
    local ms = math.floor(clock_ms - sec_base)
    if ms < 0 then ms = 0 elseif ms > 999 then ms = 999 end
    local ok2, t = pcall(os.date, "%H:%M:%S", now)
    return ("%s.%03d"):format(ok2 and t or "--:--:--", ms)
end

local function put(level, cat, msg)
    local f = M.file
    if not f then return end
    pcall(function()
        f:write(stamp(), " ", ("%-5s"):format(tostring(level)), " [", tostring(cat), "] ", tostring(msg), "\n")
        f:flush()
    end)
end

local function emit(level, cat, msg)
    if level == "DEBUG" and not M.debug then
        if M.debug == false and not M.configured and #held < HELD_MAX then
            local ok, t = pcall(stamp)
            held[#held + 1] = { ok and t or "--:--:--.000", cat, msg }
        end
        return
    end
    put(level, cat, msg)
end

local orig_print = print

--- Write a line to the run log and to UE4SS.log. level: DEBUG INFO WARN ERROR.
function M.event(level, cat, msg)
    pcall(function()
        msg = tostring(msg)
        cat = tostring(cat or "mod")
        orig_print(("[LibrarianAP] [%s] %s\n"):format(cat, msg))
        emit(tostring(level or "INFO"), cat, msg)
    end)
end

--- Called once the config is read; decides whether DEBUG lines are kept.
function M.configure(cfg)
    M.debug = type(cfg) == "table" and cfg.debug == true
    M.configured = true
    local f = M.file
    if f and M.debug then
        for _, h in ipairs(held) do
            f:write(h[1], " DEBUG [", h[2], "] ", h[3], "\n")
        end
        f:flush()
    end
    held = {}
end

-- ---------------------------------------------------------------------------
-- Sorting the print lines
-- ---------------------------------------------------------------------------
-- Tags that stay in the log at INFO. Every other tagged line is DEBUG.
local INFO_TAGS = {
    traps = true, misorder = true, ["save-id"] = true, gameplay = true, lifecycle = true,
    progress = true, ["row-completion"] = true, ["section-completion"] = true,
    ["goal-scope"] = true, save = true, ["save-delete"] = true,
    calibration = true, report = true, ["book-vis"] = true,
    ["end-door"] = true, ["book-sanity"] = true,
}
local MODULE_PREFIX = { LibrarianAP = true, ItemApply = true, HUD = true, APClientWrapper = true,
                        APConfig = true, ShelfDrop = true }

local function classify(line)
    local rest = line
    local cat
    -- Module prefix first, then the feature tags after it.
    while true do
        local tag, after = rest:match("^%[([%w_%-]+)%]%s*(.*)$")
        if not tag then break end
        if MODULE_PREFIX[tag] then
            rest = after
        elseif tag == "AP" then
            rest = after
            if not cat then
                if rest:find("goal", 1, true) or rest:find("STATUS_GOAL", 1, true) then cat = "goal"
                elseif rest:find("onnect", 1, true) then cat = "conn" end
            end
        else
            cat = cat or tag
            rest = after
        end
    end
    local level = "DEBUG"
    if rest:find("ERROR", 1, true) or rest:find(" error:", 1, true) or rest:find("failed:", 1, true) then
        level = "ERROR"
        if cat and cat ~= "error" then rest = "[" .. cat .. "] " .. rest end
        cat = "error"
    elseif rest:find("WARN", 1, true) then
        level = "WARN"
    elseif cat == "goal" or cat == "conn" or (cat and INFO_TAGS[cat]) or rest:match("^State:") or rest:match("^LibAP v") then
        level = "INFO"
    end
    if not cat then
        cat = rest:match("^State:") and "state" or "mod"
    end
    return level, cat, rest
end

if M.file == nil then
    M.file, M.name = open_run()
end
if M.file then
    print = function(...)
        orig_print(...)
        local parts = {}
        local args = { n = select("#", ...), ... }
        pcall(function()
            for i = 1, args.n do parts[i] = tostring(args[i]) end
            local text = table.concat(parts, "\t")
            for line in (text .. "\n"):gmatch("(.-)\r?\n") do
                if line:match("%S") then
                    if M.force then
                        emit("INFO", M.force, (line:gsub("^%[%w+%]%s*", "")))
                    else
                        local level, cat, msg = classify(line)
                        emit(level, cat, msg)
                    end
                end
            end
        end)
    end
    local v = M.name and M.name:match("([^/]+)$") or "?"
    put("INFO", "start", "Run log " .. v)
else
    orig_print("[LibrarianAP] run log: could not open " .. DIR .. " (folder missing?); this run is in UE4SS.log only")
end

-- ---------------------------------------------------------------------------
-- STATE snapshot
-- ---------------------------------------------------------------------------
--- Install the function that returns the snapshot sentence (nil while there is nothing to say).
function M.set_snapshot(fn) M.snapshot_fn = fn end

--- Write a STATE line now.
function M.snapshot()
    local fn = M.snapshot_fn
    if not fn then return end
    local ok, text = pcall(fn)
    if ok and text then M.event("INFO", "state", "STATE " .. text) end
end

--- Called every second while playing; writes the snapshot every five minutes.
function M.tick_snapshot()
    local now = os.time()
    snapshot_at = snapshot_at or now
    if now - snapshot_at >= snapshot_every then
        snapshot_at = now
        M.snapshot()
    end
end

--- Restart the five-minute count (after the connect snapshot).
function M.reset_snapshot_clock() snapshot_at = os.time() end

return M
