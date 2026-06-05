-- AP/HUD.lua
-- Routes status + event lines through the game's native
-- GameMode:ShowNotification UFunction. FText is built via
-- KismetTextLibrary:Conv_StringToText so the engine handles struct
-- construction.
--
-- The notification appears in-game in the same spot the autosave
-- popup uses; no custom widget shipping required. At the title screen
-- (no GameMode) we fall back to log-only.
--
-- Caller API:
--   HUD.set_status(text, color)
--   HUD.push_log(text, color)
--   HUD.clear_log()
--   HUD.COL_* color presets

local M = {}

local LOG_PREFIX = "[HUD]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

-- Color presets for caller-side semantics. ShowNotification renders in the game's own style,
-- so these don't actually colour the on-screen popup (main.lua prefixes glyphs instead).
M.COL_STATUS_OK   = { R = 0.4,  G = 0.85, B = 0.4,  A = 1.0 }
M.COL_STATUS_WARN = { R = 0.95, G = 0.85, B = 0.3,  A = 1.0 }
M.COL_STATUS_BAD  = { R = 0.85, G = 0.3,  B = 0.3,  A = 1.0 }
M.COL_RECEIVED    = { R = 0.4,  G = 0.95, B = 0.4,  A = 1.0 }
M.COL_RECEIVED_X  = { R = 0.85, G = 0.4,  B = 0.85, A = 1.0 }
M.COL_RECEIVED_S  = { R = 0.85, G = 0.85, B = 0.95, A = 1.0 }
M.COL_SENT        = { R = 0.4,  G = 0.85, B = 0.95, A = 1.0 }
M.COL_NEUTRAL     = { R = 0.85, G = 0.85, B = 0.85, A = 1.0 }

local LOG_SLOTS         = 3
local DEFAULT_DURATION  = 5.0   -- on-screen seconds for an event line
local STATUS_DURATION   = 8.0   -- slightly longer for status changes

-- Throttle: BP-graph NotificationWidget construction can't keep up with
-- bursty calls (a slot-connect bulk dump can hit 11+ items in 22ms).
-- Queue events and drain at most one per DRAIN_MS. Cap at MAX_QUEUE so a
-- huge bulk dump can't grow memory unboundedly; on overflow, drop oldest
-- so the user still sees the most recent events.
local DRAIN_MS  = 300
local MAX_QUEUE = 3

M._status_text  = ""
M._status_color = M.COL_NEUTRAL
M._log = {}

-- Cached lookups to avoid re-walking the UObject array on every event.
local _ksl_cdo = nil
local _native_failed = false  -- once true, stop trying so we don't spam logs
local _notif_queue = {}

local function get_ksl_cdo()
    if _ksl_cdo then return _ksl_cdo end
    _ksl_cdo = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return _ksl_cdo
end

local function get_game_mode()
    -- GameMode is per-level; don't cache across LoadMaps.
    return FindFirstOf("BP_LibrarianGameMode_C") or FindFirstOf("LibrarianGameMode")
end

local function build_ftext(s)
    local cdo = get_ksl_cdo()
    if not cdo then return nil end
    local ftext
    pcall(function() ftext = cdo:Conv_StringToText(tostring(s or "")) end)
    return ftext
end

-- Actually fire the engine call. Called only from the drain loop.
-- Returns:
--   true              — notification fired successfully
--   false, "retry"    — transient failure (GameMode not ready, mid-LoadMap);
--                       caller should retry on next tick
--   false, "fatal"    — permanent failure (FText build or ShowNotification
--                       UFunction broke); _native_failed gets set and we
--                       stop trying for the rest of this session
local function emit_notification(text, duration)
    if _native_failed then return false, "fatal" end
    local gm = get_game_mode()
    if not gm then return false, "retry" end
    local valid = false
    pcall(function() valid = gm:IsValid() end)
    if not valid then return false, "retry" end

    local ftext = build_ftext(text)
    if not ftext then
        log("emit_notification: FText build failed — disabling native overlay")
        _native_failed = true
        return false, "fatal"
    end

    local ok, err = pcall(function() gm:ShowNotification(ftext, duration or DEFAULT_DURATION) end)
    if not ok then
        log("emit_notification: ShowNotification failed: " .. tostring(err) .. " — disabling")
        _native_failed = true
        return false, "fatal"
    end
    return true
end

-- Queue + drain. Drain runs every DRAIN_MS unconditionally; cheap when empty.
local function enqueue_notification(text, duration)
    if _native_failed then return end
    if #_notif_queue >= MAX_QUEUE then
        table.remove(_notif_queue, 1)  -- drop oldest
    end
    table.insert(_notif_queue, {
        text = text,
        duration = duration or DEFAULT_DURATION,
        retries = 0,
    })
end

local MAX_RETRIES = 10   -- 10 × 300ms = 3s of retry budget before dropping

LoopAsync(DRAIN_MS, function()
    if #_notif_queue == 0 then return false end
    local entry = _notif_queue[1]
    local ok, reason = emit_notification(entry.text, entry.duration)
    if ok or reason == "fatal" then
        table.remove(_notif_queue, 1)
        return false
    end
    -- Transient failure (likely mid-LoadMap). Bump retry count; drop after
    -- MAX_RETRIES so a broken entry can't block the whole queue forever.
    entry.retries = entry.retries + 1
    if entry.retries > MAX_RETRIES then
        log(("emit_notification: dropping after %d retries: '%s'"):format(
            MAX_RETRIES, tostring(entry.text)))
        table.remove(_notif_queue, 1)
    end
    return false
end)

function M.set_status(text, color)
    M._status_text  = text or ""
    M._status_color = color or M.COL_NEUTRAL
    log("[STATUS] " .. M._status_text)
    enqueue_notification(M._status_text, STATUS_DURATION)
end

-- show_native: false = log only, no on-screen popup. Use for high-volume
-- bulk events (slot-connect server pushes) where popups are noise.
function M.push_log(text, color, show_native)
    table.insert(M._log, 1, { text = text, color = color or M.COL_NEUTRAL })
    while #M._log > LOG_SLOTS do M._log[#M._log] = nil end
    log("[EVENT]  " .. tostring(text))
    if show_native ~= false then
        enqueue_notification(text, DEFAULT_DURATION)
    end
end

-- Fire-and-forget notification — no state mutation, just enqueues a popup
-- with a custom duration. Use for one-shot info like version-compat at boot.
function M.notify(text, duration)
    log("[INFO]   " .. tostring(text))
    enqueue_notification(text, duration or DEFAULT_DURATION)
end

function M.clear_log()
    M._log = {}
end

log("HUD module loaded (v1.5: GameMode.ShowNotification path; falls back to log-only at title screen)")
return M
