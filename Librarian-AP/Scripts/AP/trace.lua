-- AP/trace.lua
-- Durable, crash-survivable breadcrumb ledger for the Librarian-AP crash hunt.
--
-- WHY THIS EXISTS (see CRASH_HANDOFF.md): the recurring crash is a native
-- EXCEPTION_ACCESS_VIOLATION inside a game function that operates on the book pile's
-- render data. It fires either inline on the game thread (hash BAE1A5E0) or on a
-- ParallelFor worker the game thread is blocked waiting on (hash 423B7BBD) -- the SAME
-- operation. The mod is the only thing mutating those live components mid-frame, so the
-- lead hypothesis is a main-thread-mutation-vs-engine-parallel-read race on the book
-- pile. We can't catch the native AV from Lua and we can't name the game UFunction from
-- the dispatch layer (UE4SS v3.0.1 has no global ProcessEvent prehook), so instead we
-- make the LEAD-UP observable: every game-object WRITE the mod performs is bracketed
-- begin/finish here, keyed by the object's raw address (GetAddress).
--
-- The old `[crumb]` line went through print() -> UE4SS.log, whose buffering is
-- unconfirmed; a hard AV can lose the last buffered lines. This module writes its own
-- file and `f:flush()`es on EVERY line, so the breadcrumb immediately preceding the
-- crash always reaches disk.
--
-- READING crash_trace.log after a crash:
--   * tail is a "BEG <op> <addr>" with NO matching "END"  -> the crash happened INSIDE
--     that mutation, on that object: synchronous inline race (BAE1A5E0 shape). The op +
--     object name point straight at the culprit.
--   * tail is an "END" / "MRK hb" (heartbeat)             -> the crash is DECOUPLED from
--     our last write: worker race / deferred corruption (423B7BBD shape). Compare the
--     heartbeat time to the crash time (SecondsSinceStart) for "how long after".
--   * the header line records which DIAG flags were live, so the report is
--     self-describing for the bisection (see diag_flags.lua).

local T = {}

-- Co-located with the mod + the .dmp/UE4SS.log so a tester sends one folder.
local FILE_PATH = "Mods/Librarian-AP/crash_trace.log"

local _f          = nil
local _open_ok    = false
local _seq        = 0
local _ring       = {}          -- fixed-size in-memory mirror (for T.dump / future use)
local _ring_n     = 0
local RING_MAX    = 512
local _name_cache = {}          -- addr(string) -> GetFullName() (avoid repeat FName scans)
local _open_ops   = {}          -- op -> depth of unmatched begins (cheap "stuck inside" hint)

-- os.clock() is unreliable as wall time across Lua builds; the monotonic _seq is the
-- authoritative ordering. We also stamp HH:MM:SS so lines line up with UE4SS.log.
local function _hms()
    local ok, s = pcall(function() return os.date("%H:%M:%S") end)
    return (ok and s) or "??:??:??"
end

local function _addr(obj)
    if obj == nil then return "-" end
    local a
    local ok = pcall(function() a = obj:GetAddress() end)
    if not ok or a == nil then return "?" end
    if type(a) == "number" then
        local hok, hs = pcall(string.format, "0x%x", a)
        return hok and hs or tostring(a)
    end
    return tostring(a)
end

local function _name(obj, addr)
    if obj == nil then return "-" end
    if addr and addr ~= "?" and addr ~= "-" and _name_cache[addr] then
        return _name_cache[addr]
    end
    local n
    local ok = pcall(function() n = obj:GetFullName() end)
    n = (ok and n) and tostring(n) or "?"
    if addr and addr ~= "?" and addr ~= "-" then _name_cache[addr] = n end
    return n
end

local function _emit(line)
    _seq = _seq + 1
    local full = ("%07d %s %s"):format(_seq, _hms(), line)
    _ring_n = _ring_n + 1
    _ring[((_ring_n - 1) % RING_MAX) + 1] = full
    if _open_ok and _f then
        local ok = pcall(function()
            _f:write(full); _f:write("\n"); _f:flush()
        end)
        if not ok then _open_ok = false end   -- stop touching a broken handle
    end
end

--- Open (truncate) the ledger and write a self-describing header.
--- meta = { version=string, seed=string, flags=string }. All optional.
--- Safe to call more than once (re-opens fresh, e.g. on a new connect).
function T.init(meta)
    meta = meta or {}
    pcall(function()
        if _f then pcall(function() _f:close() end); _f = nil end
        _f = io.open(FILE_PATH, "w")
        _open_ok = (_f ~= nil)
    end)
    _seq = 0
    _ring = {}; _ring_n = 0
    _open_ops = {}
    local hdr = ("=== Librarian-AP crash_trace | %s | mod=%s seed=%s | flags=%s ==="):format(
        (pcall(os.date) and os.date("%Y-%m-%d %H:%M:%S")) or "?",
        tostring(meta.version or "?"),
        tostring(meta.seed or "?"),
        tostring(meta.flags or "?"))
    _emit("HDR " .. hdr)
    -- Legend so a tester/fresh reader can interpret the file without the source.
    _emit("HDR legend: BEG/END=mutation begin/end (tail BEG w/o END = crash INSIDE it); "
        .. "MRK=marker; addr=GetAddress; name=GetFullName")
end

--- Mark the start of a game-object mutation. Pair with T.finish(op, obj).
function T.begin(op, obj)
    local a = _addr(obj)
    _open_ops[op] = (_open_ops[op] or 0) + 1
    _emit(("BEG %-16s %s %s"):format(tostring(op), a, _name(obj, a)))
end

--- Mark the end of a game-object mutation started with T.begin(op, obj).
function T.finish(op, obj)
    local a = _addr(obj)
    local d = (_open_ops[op] or 1) - 1
    if d < 0 then d = 0 end
    _open_ops[op] = d
    _emit(("END %-16s %s"):format(tostring(op), a))
end

--- One-shot marker (heartbeat, reset, stale-ref, lifecycle, etc.). `extra` optional.
function T.mark(tag, obj, extra)
    local a = obj and _addr(obj) or "-"
    local nm = obj and _name(obj, a) or "-"
    _emit(("MRK %-16s %s %s%s"):format(
        tostring(tag), a, nm, extra and (" " .. tostring(extra)) or ""))
end

--- Return the in-memory ring (oldest..newest) for ad-hoc dumping. Cheap.
function T.recent()
    local out = {}
    local count = math.min(_ring_n, RING_MAX)
    local start = _ring_n - count
    for i = 1, count do
        out[i] = _ring[((start + i - 1) % RING_MAX) + 1]
    end
    return out
end

return T
