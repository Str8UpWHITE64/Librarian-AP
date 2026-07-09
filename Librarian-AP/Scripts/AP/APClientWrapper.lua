--[[
    APClient Wrapper for lua-apclientpp.

    Loads the native DLL (lazy) and exposes a clean Lua API around it.
    DLL load is deferred so that creation + poll happen on the same thread,
    which lua-apclientpp requires.
]]

local APClientWrapper = {}

local LOG_PREFIX = "[APClientWrapper]"
local DLL_PATH = "Mods/Librarian-AP/Scripts/AP/lua-apclientpp.dll"

local apclientpp = nil
local dll_load_attempted = false

local function ensure_loaded()
    if apclientpp then return true end
    if dll_load_attempted then return false end
    dll_load_attempted = true

    local loader, err = package.loadlib(DLL_PATH, "luaopen_apclientpp")
    if loader then
        local ok, mod = pcall(loader)
        if ok and mod then
            print(LOG_PREFIX .. " Loaded DLL via package.loadlib: " .. DLL_PATH)
            apclientpp = mod
            return true
        end
        print(LOG_PREFIX .. " loadlib succeeded but init failed: " .. tostring(mod))
    end

    -- Fallback: cpath + require
    package.cpath = package.cpath .. ";Mods/Librarian-AP/Scripts/AP/?.dll"
    local success, result = pcall(require, "lua-apclientpp")
    if success then
        print(LOG_PREFIX .. " Loaded DLL via require")
        apclientpp = result
        return true
    end

    print(LOG_PREFIX .. " ERROR: Failed to load lua-apclientpp DLL")
    print(LOG_PREFIX .. " Tried: " .. DLL_PATH)
    print(LOG_PREFIX .. " Error: " .. tostring(err or result))
    return false
end

function APClientWrapper.is_available()
    if apclientpp then return true end
    if dll_load_attempted then return false end
    return true
end

function APClientWrapper.new(uuid, game_name, server)
    if not ensure_loaded() then
        print(LOG_PREFIX .. " Cannot create client: DLL not loaded")
        return nil
    end

    print(string.format("%s Creating client (game='%s', server='%s')", LOG_PREFIX, game_name, server))
    local ok, client = pcall(apclientpp, uuid, game_name, server)
    if not ok or not client then
        print(LOG_PREFIX .. " ERROR: Failed to create client: " .. tostring(client))
        return nil
    end

    print(LOG_PREFIX .. " Client created successfully")
    local wrapped = { _native = client }

    local function safe_call(method_name, ...)
        local fn = client[method_name]
        if not fn then
            print(string.format("%s WARNING: Method '%s' not available", LOG_PREFIX, method_name))
            return nil
        end
        local args = { ... }
        local success, result = pcall(function()
            return fn(client, table.unpack(args))
        end)
        if not success then
            print(string.format("%s ERROR in %s(): %s", LOG_PREFIX, method_name, tostring(result)))
            return nil
        end
        return result
    end

    function wrapped:poll()                              safe_call("poll") end
    function wrapped:get_state()                         return safe_call("get_state") end
    function wrapped:ConnectSlot(slot, password, items_handling, tags, version)
        print(string.format("%s ConnectSlot(slot='%s', items_handling=%d)", LOG_PREFIX, slot, items_handling))
        safe_call("ConnectSlot", slot, password, items_handling, tags, version)
    end
    function wrapped:ConnectUpdate(items_handling, tags) return safe_call("ConnectUpdate", items_handling, tags) end
    function wrapped:LocationChecks(locations)           safe_call("LocationChecks", locations) end
    function wrapped:LocationScouts(locations, hint)     safe_call("LocationScouts", locations, hint or 0) end
    function wrapped:StatusUpdate(status)
        print(string.format("%s StatusUpdate(%d)", LOG_PREFIX, status))
        safe_call("StatusUpdate", status)
    end
    function wrapped:Say(text)                           safe_call("Say", text) end
    function wrapped:Bounce(data, games, slots, tags)    safe_call("Bounce", data, games, slots, tags) end
    function wrapped:Get(keys)                           safe_call("Get", keys) end
    function wrapped:Set(key, dflt, want_reply, ops)     safe_call("Set", key, dflt, want_reply, ops) end

    function wrapped:get_player_alias(slot)              return safe_call("get_player_alias", slot) end
    function wrapped:get_player_game(slot)               return safe_call("get_player_game", slot) end
    function wrapped:get_item_name(item_id, game_name)   return safe_call("get_item_name", item_id, game_name or "") end
    function wrapped:get_location_name(loc_id, game)     return safe_call("get_location_name", loc_id, game or "") end
    function wrapped:get_player_number()                 return safe_call("get_player_number") end

    function wrapped:get_missing_locations()
        local ok, result = pcall(function() return client.missing_locations end)
        if ok then return result end
        return nil
    end
    function wrapped:get_checked_locations()
        local ok, result = pcall(function() return client.checked_locations end)
        if ok then return result end
        return nil
    end

    local function register_handler(handler_name, callback)
        local setter = client["set_" .. handler_name .. "_handler"]
        if not setter then
            print(string.format("%s WARNING: set_%s_handler not found", LOG_PREFIX, handler_name))
            return
        end
        local ok, err = pcall(setter, client, function(...)
            local cb_ok, cb_err = pcall(callback, ...)
            if not cb_ok then
                print(string.format("%s ERROR in %s handler: %s", LOG_PREFIX, handler_name, tostring(cb_err)))
            end
        end)
        if not ok then
            print(string.format("%s ERROR registering %s: %s", LOG_PREFIX, handler_name, tostring(err)))
        end
    end

    function wrapped:set_socket_connected_handler(fn)    register_handler("socket_connected", fn) end
    function wrapped:set_socket_disconnected_handler(fn) register_handler("socket_disconnected", fn) end
    function wrapped:set_socket_error_handler(fn)        register_handler("socket_error", fn) end
    function wrapped:set_room_info_handler(fn)           register_handler("room_info", fn) end
    function wrapped:set_slot_connected_handler(fn)      register_handler("slot_connected", fn) end
    function wrapped:set_slot_refused_handler(fn)        register_handler("slot_refused", fn) end
    function wrapped:set_items_received_handler(fn)      register_handler("items_received", fn) end
    function wrapped:set_location_checked_handler(fn)    register_handler("location_checked", fn) end
    function wrapped:set_print_handler(fn)               register_handler("print", fn) end
    function wrapped:set_print_json_handler(fn)          register_handler("print_json", fn) end
    function wrapped:set_bounced_handler(fn)             register_handler("bounced", fn) end
    function wrapped:set_data_package_changed_handler(fn) register_handler("data_package_changed", fn) end
    function wrapped:set_location_info_handler(fn)       register_handler("location_info", fn) end
    function wrapped:set_retrieved_handler(fn)           register_handler("retrieved", fn) end
    function wrapped:set_set_reply_handler(fn)           register_handler("set_reply", fn) end

    return wrapped
end

return APClientWrapper
