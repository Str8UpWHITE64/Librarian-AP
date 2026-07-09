-- AP/APClient.lua
-- High-level Archipelago client for Librarian (UE4SS + lua-apclientpp).
--
-- IMPORTANT: lua-apclientpp requires that instantiation, handler firing, and
-- poll() all happen on the SAME thread. UE4SS RegisterHook callbacks run on
-- the game thread, but the DLL must be touched from a single LoopAsync. So
-- the pattern is:
--   - hooks queue intents (location IDs to check, chat to send, etc.) into
--     `_outgoing_*` tables on the Client instance
--   - LoopAsync (500ms) drains those queues by calling the DLL methods, and
--     also calls poll() to fire incoming handlers (items / messages / etc.)
--
-- This module handles: connect, send location checks, receive items (logged
-- + handed off via callback). State application (warding books, granting
-- skills, etc.) happens in AP/ItemApply.lua via `Client.on_item`.

local APClientWrapper = require("AP/APClientWrapper")
local APConfig        = require("AP/APConfig")

local Client = {
    enabled = false,

    -- Config (populated from ap_config.json)
    server = "localhost:38281",
    slot = "",
    password = "",
    game = "Librarian Tidy Up the Arcane Library",
    uuid = "",
    tags = { "AP" },
    items_handling = 7,           -- own + others' + starting
    version = { 0, 5, 1 },

    -- Runtime state
    _client = nil,
    _connected = false,
    _slot_connected = false,
    _deferred_init = false,

    -- Slot data from server (populated in slot_connected handler)
    slot_number = -1,
    slot_data = {},

    -- Scout cache: loc_id → { item_id, player, item_name, player_name, location_name }
    -- Populated by location_info_handler after we LocationScouts() on connect.
    -- Used by on_check_sent for "You sent ITEM to PLAYER (LOCATION)" messages.
    _scout_cache = {},

    -- Player alias cache: slot → alias_string. Lazy-populated on first
    -- lookup via get_player_alias. Used by on_item to label items received
    -- from other players in a multiworld. Reset on each slot_connected.
    _player_alias_cache = {},

    -- Item tracking
    _applied_index = -1,
    _pending_items = {},

    -- Outgoing queues (populated by hooks, drained by LoopAsync)
    _outgoing_checks = {},
    _outgoing_say = {},
    _outgoing_status = nil,
    _outgoing_storage = {},

    -- Already-sent location IDs so we don't double-send
    _sent_checks = {},

    -- Gate on in-game state. When false, received items stay queued in
    -- _pending_items but on_item is NOT fired. Set true after the player
    -- loads M01; lets us defer game-state mutations until the level is
    -- actually loaded.
    _in_game = false,

    -- Callbacks (set by main.lua)
    on_item = nil,                -- function(it: {item, location, player, flags, index})
    on_message = nil,             -- function(text)
    on_slot_connected = nil,      -- function(slot_data)
    on_disconnected = nil,        -- function()
    on_slot_refused = nil,        -- function(reason_str)
    on_check_sent = nil,          -- function(loc_id) — fires when a check is queued
    on_storage = nil,             -- function(key, value) — data-storage read replies
}

local LOG_PREFIX = "[LibrarianAP]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

-- AP status constants (matches CommonClient)
Client.STATUS_UNKNOWN   = 0
Client.STATUS_CONNECTED = 5
Client.STATUS_READY     = 10
Client.STATUS_PLAYING   = 20
Client.STATUS_GOAL      = 30

--- Initialize from ap_config.json. Starts the LoopAsync poll thread but
--- does NOT connect. Call connect() to actually open the socket.
function Client:init(config_path)
    config_path = config_path or "Mods/Librarian-AP/Scripts/ap_config.json"
    local config = APConfig.load(config_path)

    self.server         = config.server         or self.server
    self.slot           = config.slot           or self.slot
    self.password       = config.password       or self.password
    self.game           = config.game           or self.game
    self.uuid           = config.uuid           or self.uuid
    self.items_handling = config.items_handling or self.items_handling

    if self.slot == "" then
        log("WARNING: no slot name configured; edit Scripts/ap_config.json")
    end

    self.enabled = true
    self:_start_async_loop()
    log(("Initialized (server=%s slot='%s')"):format(self.server, self.slot))
    return true
end

--- Trigger connection. Sets _deferred_init so the LoopAsync creates the client
--- and opens the socket on its next tick (same thread requirement).
function Client:connect()
    if self._slot_connected then
        log("Already connected to slot")
        return
    end
    self._deferred_init = true
    log("Connecting...")
end

-- Per-tick body: (first tick) create the client, then poll + drain outgoing + apply pending items.
-- Runs on EXACTLY ONE thread at a time: the async LoopAsync below when _poll_on_game_thread is off
-- (legacy), or the game-thread pawn tick (main.lua BP_LibrarianCharacter_C:ReceiveTick) when on.
-- apclientpp requires create + poll + handlers on ONE consistent thread, so this must never run on
-- both threads concurrently -- the LoopAsync below stays idle whenever the pawn tick is advancing.
function Client:_tick_once()
    if self._deferred_init then self:_create_client() end
    if not self._client then return end
    self._client:poll()
    self:_process_outgoing()
    self:_apply_pending_items()
end

-- Bumped by the game-thread pawn tick each frame it drives _tick_once (main.lua). The async loop
-- watches it to tell whether the pawn tick is alive (advancing) and stays idle if so. Set true by
-- main.lua from the POLL_ON_GAME_THREAD diag flag.
Client._gt_tick_count = 0
Client._poll_on_game_thread = false

function Client:_start_async_loop()
    local self_ref = self
    local async_last_seen = -1
    LoopAsync(500, function()
        if not self_ref.enabled then return false end

        if self_ref._poll_on_game_thread then
            -- The game-thread pawn tick owns create+poll+apply. Only cover the window where it is NOT
            -- firing yet (pre-connect title / LoadMap gap, no pawn): marshal ONE tick onto the game
            -- thread via ExecuteInGameThread, so the DLL is still only ever touched from the game thread.
            local tc = self_ref._gt_tick_count or 0
            if tc ~= async_last_seen then async_last_seen = tc; return false end   -- pawn tick alive -> idle
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(function()
                    local ok, e = pcall(function() self_ref:_tick_once() end)
                    if not ok then log("game-thread tick error: " .. tostring(e)) end
                end)
            end
            return false
        end

        -- Legacy path (flag off): run the whole tick inline on the async thread (unchanged behavior).
        local ok, err = pcall(function() self_ref:_tick_once() end)
        if not ok then log("Async loop error: " .. tostring(err)) end
        return false
    end)
    log("LoopAsync started (500ms)")
end

function Client:_create_client()
    self._deferred_init = false
    log("Creating native client...")
    self._client = APClientWrapper.new(self.uuid, self.game, self.server)
    if not self._client then
        log("ERROR: failed to create AP client")
        self.enabled = false
        return
    end
    self:_register_handlers()
    log("AP client ready")
end

function Client:_register_handlers()
    local c = self._client

    c:set_socket_connected_handler(function()
        self._connected = true
        log("Socket connected to " .. self.server)
    end)
    c:set_socket_disconnected_handler(function()
        self._connected = false
        self._slot_connected = false
        log("Socket disconnected")
        if self.on_disconnected then pcall(self.on_disconnected) end
    end)
    c:set_socket_error_handler(function(err)
        log("Socket error: " .. tostring(err))
    end)
    c:set_room_info_handler(function()
        log("RoomInfo received; sending ConnectSlot...")
        c:ConnectSlot(self.slot, self.password, self.items_handling, self.tags, self.version)
    end)
    c:set_slot_connected_handler(function(slot_data)
        self._slot_connected = true
        self.slot_data = slot_data or {}
        pcall(function() self.slot_number = c:get_player_number() or -1 end)
        log("Slot connected (slot #" .. tostring(self.slot_number) .. ")")
        if type(slot_data) == "table" then
            local keys = {}
            for k in pairs(slot_data) do keys[#keys + 1] = k end
            log("slot_data keys: " .. table.concat(keys, ", "))
        end
        -- Reset caches; we'll repopulate from this connection's data.
        self._scout_cache = {}
        self._player_alias_cache = {}
        -- Fresh connection: drop item-tracking and data-storage state from any prior slot/socket.
        -- The server re-dumps received items on connect, so the applied-index high-water mark must
        -- reset or the re-dump is skipped; clearing the queues and on_storage stops a stranded item
        -- or stale key from a prior slot leaking into this one.
        self._applied_index = -1
        self._pending_items = {}
        self._outgoing_storage = {}
        self.on_storage = nil
        if self.on_slot_connected then pcall(self.on_slot_connected, self.slot_data) end
        -- Fire scouts for all our missing locations so on_check_sent can
        -- name what we're sending. Batched (25 per tick × 200ms delay) so
        -- the location_info handler doesn't blast ~1500 native calls in
        -- one frame.
        self:scout_missing()
    end)
    c:set_slot_refused_handler(function(reasons)
        self._slot_connected = false
        local reason_str = (type(reasons) == "table") and table.concat(reasons, ", ") or tostring(reasons)
        log("ERROR: slot refused: " .. reason_str)
        if self.on_slot_refused then pcall(self.on_slot_refused, reason_str) end
    end)
    c:set_items_received_handler(function(items)
        self:_on_items_received(items)
    end)
    c:set_location_checked_handler(function(locations)
        if type(locations) ~= "table" then return end
        for _, loc in ipairs(locations) do
            self._sent_checks[tonumber(loc)] = true
        end
    end)
    c:set_print_handler(function(text)
        if text and text ~= "" then
            log("[server] " .. tostring(text))
            if self.on_message then pcall(self.on_message, tostring(text)) end
        end
    end)
    c:set_data_package_changed_handler(function(_)
        log("Data package updated")
    end)
    -- Data-storage replies. Retrieved answers a Get; set_reply answers a Set with
    -- want_reply. Both funnel into on_storage(key, value) so callers see one path.
    c:set_retrieved_handler(function(data)
        if type(data) ~= "table" then return end
        for k, v in pairs(data) do
            if self.on_storage then pcall(self.on_storage, k, v) end
        end
    end)
    c:set_set_reply_handler(function(reply)
        if type(reply) ~= "table" then return end
        if self.on_storage then pcall(self.on_storage, reply.key, reply.value) end
    end)
    c:set_location_info_handler(function(locations)
        if type(locations) ~= "table" then return end
        local game_name = self.game
        local count = 0
        for _, info in ipairs(locations) do
            local loc_id  = tonumber(info.location)
            local item_id = tonumber(info.item)
            local player  = tonumber(info.player) or -1
            if loc_id and item_id then
                local entry = { item_id = item_id, player = player }
                -- The item at one of OUR locations belongs to the RECEIVING
                -- player's game, not ours -- resolve its NAME against THAT game's
                -- data package. Using our own game returned "Unknown" for every
                -- cross-game item. (The LOCATION is ours, so location_name keeps
                -- game_name; for items we send to ourselves, get_player_game
                -- returns our game and this behaves exactly as before.)
                local item_game = game_name
                pcall(function()
                    local g = c:get_player_game(player)
                    if g and g ~= "" then item_game = g end
                end)
                pcall(function() entry.item_name = c:get_item_name(item_id, item_game) end)
                pcall(function() entry.location_name = c:get_location_name(loc_id, game_name) end)
                pcall(function() entry.player_name = c:get_player_alias(player) end)
                self._scout_cache[loc_id] = entry
                count = count + 1
            end
        end
        local total = 0
        for _ in pairs(self._scout_cache) do total = total + 1 end
        log(("location_info: cached %d entries (total %d)"):format(count, total))
    end)
end

--- Lookup a player's alias by slot number, with caching. Returns nil for
--- invalid/server slots (slot <= 0). Safe to call from poll-thread
--- callbacks (apclient handlers) — single native call per unique slot.
function Client:get_alias(slot)
    if not slot or slot <= 0 then return nil end
    if self._player_alias_cache[slot] then
        return self._player_alias_cache[slot]
    end
    if not self._client then return nil end
    local alias
    pcall(function() alias = self._client:get_player_alias(slot) end)
    if alias and alias ~= "" then
        self._player_alias_cache[slot] = alias
        return alias
    end
    return nil
end

--- Request item/player info for every location we still need to check,
--- in BATCHES so the location_info handler isn't asked to do hundreds of
--- native DLL lookups in a single frame. Sending all 492 at once
--- triggered a delayed crash on the first New Game flush.
---
--- Each batch's location_info_handler does (3 native calls × batch_size)
--- in one tick. SCOUT_BATCH_SIZE=25 → 75 native calls per handler tick.
--- Total time = ceil(missing / 25) × delay (~4s for 492 locations).
local SCOUT_BATCH_SIZE     = 25
local SCOUT_BATCH_DELAY_MS = 200

function Client:scout_missing()
    if not self._client or not self._slot_connected then return end
    local missing = self._client:get_missing_locations()
    if not missing then
        log("scout_missing: no missing list available")
        return
    end
    local list = {}
    pcall(function()
        for i = 1, #missing do list[#list + 1] = missing[i] end
    end)
    if #list == 0 then
        log("scout_missing: empty missing list")
        return
    end
    local total_batches = math.ceil(#list / SCOUT_BATCH_SIZE)
    log(("scout_missing: %d locations in %d batches of %d (≈%.1fs)"):format(
        #list, total_batches, SCOUT_BATCH_SIZE,
        total_batches * SCOUT_BATCH_DELAY_MS / 1000))

    if self._poll_on_game_thread then
        -- Single-thread: DLL calls must stay on the polling (game) thread. Stash the list; the pawn
        -- tick's _process_outgoing drains ONE batch per ~12 polls (keeps the ~200ms cadence).
        self._scout_list = list
        self._scout_idx = 1
        return
    end

    local idx = 1
    local self_ref = self
    LoopAsync(SCOUT_BATCH_DELAY_MS, function()
        if not self_ref._slot_connected then
            return true  -- abort if user disconnected mid-scout
        end
        if idx > #list then
            log(("scout_missing: all batches sent (%d locations queued)"):format(#list))
            return true
        end
        local batch = {}
        local end_idx = math.min(idx + SCOUT_BATCH_SIZE - 1, #list)
        for i = idx, end_idx do batch[#batch + 1] = list[i] end
        idx = end_idx + 1
        pcall(function() self_ref._client:LocationScouts(batch, 0) end)
        return false  -- keep ticking
    end)
end

-- ---------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------

function Client:_on_items_received(items)
    if type(items) ~= "table" then return end
    for _, it in ipairs(items) do
        self._pending_items[#self._pending_items + 1] = it
    end
end

function Client:_apply_pending_items()
    if not self._in_game then return end  -- hold until player has loaded M01
    if #self._pending_items == 0 then return end
    local pending = self._pending_items
    self._pending_items = {}
    for _, it in ipairs(pending) do
        local idx = tonumber(it.index) or -1
        if idx > self._applied_index then
            self._applied_index = idx
            local item_id = tonumber(it.item) or 0
            local name = nil
            pcall(function() name = self._client:get_item_name(item_id, "") end)
            log(("Received item idx=%d id=%d name=%s player=%s loc=%s"):format(
                idx, item_id, tostring(name or "?"),
                tostring(it.player), tostring(it.location)))
            if self.on_item then
                pcall(self.on_item, it, name)
            end
        end
    end
end

-- ---------------------------------------------------------------
-- Outgoing (queued from hooks; drained on LoopAsync thread)
-- ---------------------------------------------------------------

--- Queue a location check. De-duped against already-sent locations.
function Client:send_check(location_id)
    location_id = tonumber(location_id)
    if not location_id then return end
    if self._sent_checks[location_id] then return end
    self._outgoing_checks[#self._outgoing_checks + 1] = location_id
    if self.on_check_sent then pcall(self.on_check_sent, location_id) end
end

--- Mark whether the player is currently in a gameplay level. When false,
--- received items remain queued but their on_item callback is NOT fired.
--- main.lua wires this to the LoadMap post hook for /M01/PL_M01.
function Client:set_in_game(state)
    state = state and true or false
    if self._in_game == state then return end
    self._in_game = state
    if state then
        local pending_count = #self._pending_items
        log(("In-game flag set TRUE; %d pending items will apply on next tick"):format(pending_count))
    else
        log("In-game flag set FALSE; pending items will be held")
    end
end

--- Read a server data-storage key, creating it at `default` if missing.
--- The value returns through on_storage(key, value), always concrete since
--- create-if-missing guarantees the key exists by reply time.
function Client:storage_read(key, default)
    self._outgoing_storage[#self._outgoing_storage + 1] =
        { key = key, dflt = default, reply = true,
          ops = { { operation = "default", value = 0 } } }
end

--- Raise a server data-storage key to `value` if that's higher than what's stored.
--- Fire-and-forget; no reply.
function Client:storage_max(key, value)
    self._outgoing_storage[#self._outgoing_storage + 1] =
        { key = key, dflt = value, reply = false,
          ops = { { operation = "max", value = value } } }
end

function Client:say(text)
    self._outgoing_say[#self._outgoing_say + 1] = tostring(text)
end

function Client:set_status(status)
    self._outgoing_status = status
end

function Client:_process_outgoing()
    if not self._slot_connected then return end

    if #self._outgoing_checks > 0 then
        local new_checks = {}
        for _, lid in ipairs(self._outgoing_checks) do
            if not self._sent_checks[lid] then
                self._sent_checks[lid] = true
                new_checks[#new_checks + 1] = lid
            end
        end
        self._outgoing_checks = {}
        if #new_checks > 0 then
            log(("Sending %d location checks: %s"):format(#new_checks, table.concat(new_checks, ", ")))
            self._client:LocationChecks(new_checks)
        end
    end

    if #self._outgoing_say > 0 then
        for _, text in ipairs(self._outgoing_say) do
            self._client:Say(text)
        end
        self._outgoing_say = {}
    end

    if self._outgoing_status ~= nil then
        self._client:StatusUpdate(self._outgoing_status)
        self._outgoing_status = nil
    end

    if #self._outgoing_storage > 0 then
        for _, s in ipairs(self._outgoing_storage) do
            self._client:Set(s.key, s.dflt, s.reply, s.ops)
        end
        self._outgoing_storage = {}
    end

    -- Single-thread: drain ONE stashed scout batch per ~12 polls, so all DLL LocationScouts calls
    -- happen on the game (polling) thread and at roughly the old SCOUT_BATCH_DELAY_MS cadence.
    if self._scout_list then
        self._scout_tick = (self._scout_tick or 0) + 1
        if self._scout_tick % 12 == 0 then
            local list = self._scout_list
            if self._scout_idx > #list then
                log(("scout_missing: all batches sent (%d locations queued)"):format(#list))
                self._scout_list = nil
            else
                local batch = {}
                local end_idx = math.min(self._scout_idx + SCOUT_BATCH_SIZE - 1, #list)
                for i = self._scout_idx, end_idx do batch[#batch + 1] = list[i] end
                self._scout_idx = end_idx + 1
                pcall(function() self._client:LocationScouts(batch, 0) end)
            end
        end
    end
end

return Client
