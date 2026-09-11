-- AP/runlog.lua
-- One log file per launch. UE4SS rewrites UE4SS.log every time the game starts and offers no
-- rotation, so a tester who plays three sessions before reporting has the last one. Every line
-- of ours goes through print, so this wraps print once and mirrors each line, with a clock
-- time, into Mods/Librarian-AP/logs/LibAP_<run>_<date>.log. The newest twenty runs are kept;
-- older ones are removed by name from the index the module keeps for itself.
local M = { file = nil, name = nil }
local DIR, KEEP = "Mods/Librarian-AP/logs", 20
local INDEX = DIR .. "/index.txt"

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
    local run = 0
    local last = names[#names]
    if last then run = tonumber(last:match("LibAP_(%d+)_")) or #names end
    local ok, stamp = pcall(os.date, "%Y%m%d-%H%M%S")
    local name = ("%s/LibAP_%04d_%s.log"):format(DIR, run + 1, (ok and stamp) or "run")
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

function M.write(line)
    local f = M.file
    if not f then return end
    local ok, t = pcall(os.date, "%H:%M:%S")
    f:write(ok and t or "--:--:--", " ", line, "\n")
    f:flush()
end

local orig_print = print
M.file, M.name = open_run()
if M.file then
    print = function(...)
        orig_print(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        local line = (table.concat(parts, "\t"):gsub("[\r\n]+$", ""))
        M.write(line)
    end
    M.write("=== Librarian-AP run log: " .. tostring(M.name) .. " ===")
else
    orig_print("[LibrarianAP] run log: could not open " .. DIR .. " (folder missing?); this run is in UE4SS.log only")
end
return M
