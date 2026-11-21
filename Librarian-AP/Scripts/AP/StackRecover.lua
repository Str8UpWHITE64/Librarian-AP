-- AP/StackRecover.lua
-- After the player puts a stack of books down (holding Cancel lets the whole stack go where it hangs, with no
-- check of the floor or the walls), a book can come to rest inside the floor, a wall or a bookcase, where it
-- cannot be seen or picked up. Once the dropped books have settled, any that are buried are laid on open floor
-- near the player, the way Butterfingers lays its books. Nothing else is touched: only books that have just left
-- the hands are looked at, and never one on a shelf, flying to one, hidden, or still held.
local M = {}
local LOG_PREFIX = "[stack-recover]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

local T = nil                   -- AP/Traps, loaded on first use
local BAG_OK_TICKS = 8          -- ticks (a quarter second each) after the last book left the hands before judging
local STILL_TICKS = 3           -- ...and the books must have stopped moving for this many ticks
local MAX_TICKS = 48            -- a stack still moving after this long is judged anyway (12 s)
local DEPTH_MIN = 3.0           -- a book is buried when the floor runs this far up into it
local PER_TICK = 3              -- books re-seated per tick
local PROBE_UP = 60             -- the upward probe reaches this far over the book's top
local PROBE_DOWN = 40           -- the downward probe starts this far over the book's top
local RECHECK_TICKS = 16        -- a second look this long after the first: some books settle late
local SAME_SPOT = 3             -- a book this close to where it was laid has not moved since
local LAY_DISTS = { 90, 130, 180, 240 }   -- how far from the player a recovered book may be laid, nearest first

M.stats = { puts = 0, buried = 0, laid = 0, failed = 0 }
M.st = { epoch = nil, n = nil, list = nil, job = nil }

local function traps()
    if T == nil then
        local ok, t = pcall(require, "AP/Traps")
        T = (ok and type(t) == "table" and t.util) and t or false
    end
    return T or nil
end

local function valid(o)
    local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and v == true
end

local function loc_of(o)
    local x, y, z
    pcall(function() local l = o:K2_GetActorLocation(); x, y, z = l.X, l.Y, l.Z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return x, y, z
end

local function owned(b)
    local o = false
    pcall(function() o = b.OwningCharacter ~= nil and b.OwningCharacter:IsValid() end)
    return o
end

local function attached(b)
    local a = false
    pcall(function() a = b.AttachedActor ~= nil and b.AttachedActor:IsValid() end)
    return a
end

--- True while the game is moving the book on a timeline (a flight to a shelf, a follow of the player).
local function flying(b)
    for _, n in ipairs({ "CloseUp", "GoToPath", "BezierCurveMove", "ToCenterPoint", "RotateFromCenter", "ToBookCase" }) do
        local on = false
        pcall(function() on = b[n]:IsPlaying() == true end)
        if on then return true end
    end
    return false
end

local function name_of(IA, b)
    local aidx, ch
    pcall(function() aidx = IA._book_valid_asset_idx(b) end)
    pcall(function() ch = tonumber(b.ItemInfo.Chapter) end)
    return tostring(aidx) .. "|" .. tostring(ch)
end

local function bag_items(p)
    local items, n = nil, 0
    pcall(function()
        local bag = p.ItemBagComponent
        if not valid(bag) then return end
        items = bag.Items
        n = #items
    end)
    return items, n
end

--- The books in the bag now, as objects. Read only when the bag's size changes.
local function read_list(IA, items, n)
    local list = {}
    for i = 1, n do
        local it
        pcall(function() it = items[i] end)
        if valid(it) and IA._book_valid_asset_idx(it) ~= nil then list[#list + 1] = it end
    end
    return list
end

--- How deep a settled book lies in the floor or a wall, and the height of the surface it lies in; nil when it is
--- not buried.
--- A probe up from just over its bottom starts inside geometry (or meets it before the book's top) when the
--- surface runs through the book; a probe down from over its top then says how far up the floor reaches.
local function buried_depth(u, book, ignore)
    local o, e = u.box(book)
    if not o then return nil end
    local bottom, top = o.Z - e.Z, o.Z + e.Z
    local hit, z, inside, who = u.trace({ X = o.X, Y = o.Y, Z = bottom + 0.5 }, { X = o.X, Y = o.Y, Z = top + PROBE_UP }, ignore, { 0, 1 })
    if not hit then return nil end
    if who and tostring(who):find("GrabbingBook", 1, true) then   -- another book, not the world
        return nil, "in another book"
    end
    if not inside and not (type(z) == "number" and z < top - 1) then return nil end   -- a slab over it, not through it
    local h2, z2, in2, who2 = u.trace({ X = o.X, Y = o.Y, Z = top + PROBE_DOWN }, { X = o.X, Y = o.Y, Z = bottom - 300 }, ignore, { 0, 1 })
    if h2 and not in2 and type(z2) == "number" then
        if who2 and tostring(who2):find("GrabbingBook", 1, true) then return nil, "over another book" end
        local depth = z2 - bottom
        if depth > DEPTH_MIN then return depth, nil, z2 end
        return nil
    end
    return 999        -- the whole book is inside something (a wall, a bookcase)
end

--- Whether a player could stand somewhere with a clear look at the book: free air at head height on a ring round it,
--- a floor under it, and nothing in the line to the book. Used only for a book lying inside a bookcase's volume.
local function reachable(u, book, ignore)
    local o = u.box(book)
    if not o then return true end
    local ign = { ignore[1], book }
    for i = 2, #ignore do ign[#ign + 1] = ignore[i] end
    for _, r in ipairs({ 70, 110 }) do
        for i = 0, 11 do
            local a = i * math.pi / 6
            local x, y, z = o.X + math.cos(a) * r, o.Y + math.sin(a) * r, o.Z + 60
            local in_wall = u.trace({ X = x, Y = y, Z = z }, { X = x, Y = y, Z = z + 2 }, ign, { 0, 1 })
            if not in_wall then
                local floor = u.trace({ X = x, Y = y, Z = z }, { X = x, Y = y, Z = z - 200 }, ign, { 0, 1 })
                if floor then
                    local blocked = u.trace({ X = x, Y = y, Z = z }, { X = o.X, Y = o.Y, Z = o.Z }, ign, { 0, 1 })
                    if not blocked then return true end
                end
            end
        end
    end
    return false
end

--- One settled put-down: re-seat every buried book in its list.
local function judge(IA, p, job)
    local u = T.util
    local ignore = { p }
    for _, b in ipairs(job.books) do ignore[#ignore + 1] = b end
    local skipped = { shelved = 0, flying = 0, hidden = 0, held = 0, pinned = 0, gone = 0 }
    local todo = {}
    for _, b in ipairs(job.books) do
        if not valid(b) then skipped.gone = skipped.gone + 1
        elseif owned(b) then skipped.held = skipped.held + 1
        elseif attached(b) then skipped.shelved = skipped.shelved + 1
        elseif flying(b) then skipped.flying = skipped.flying + 1
        elseif not u.collision(b) then skipped.hidden = skipped.hidden + 1
        else
            local k = u.key(b)
            if k and T.bf_pins[k] then
                skipped.pinned = skipped.pinned + 1
            else
                local x, y, z = loc_of(b)
                if x and not (x == 0 and y == 0 and z == 0) then
                    local d, why, surf = buried_depth(u, b, ignore)
                    if why then
                        log(("book %s not moved: %s (%.0f, %.0f, %.0f)"):format(name_of(IA, b), why, x, y, z))
                    end
                    local SD = package.loaded["AP/ShelfDrop"]
                    local lodged = false
                    if not d and SD and SD.loose_position then
                        -- inside a bookcase's volume but not on a shelf: lodged, unless a player could still see it
                        local okc, here = pcall(SD.loose_position, IA, b)
                        lodged = okc and here == nil and not reachable(u, b, ignore)
                    end
                    local e
                    if d then e = { book = b, depth = d }
                    elseif lodged then e = { book = b, depth = 0, case = true } end
                    -- still buried where it was laid: that spot is not open floor at the height it was read
                    local was = e and job.laid_at and job.laid_at[b]
                    if was and math.abs(x - was.X) < SAME_SPOT and math.abs(y - was.Y) < SAME_SPOT
                           and math.abs(z - was.Z) < SAME_SPOT then
                        e.again = { x = x, y = y, floor = (d and d < 900) and surf or nil }
                    end
                    if e then todo[#todo + 1] = e end
                end
            end
        end
    end
    job.todo = todo
    job.skipped = skipped
    job.laid, job.failed = 0, 0
    M.stats.buried = M.stats.buried + #todo
    -- a book that went to a shelf is a shelving, not a put-down: nothing to say about it
    if #job.books - skipped.shelved - skipped.gone <= 0 then return end
    M.stats.puts = M.stats.puts + 1
    log(("put-down of %d books settled: %d buried; left alone: %d shelved, %d flying, %d hidden, %d held, %d placed by a trap"):format(
        #job.books, #todo, skipped.shelved, skipped.flying, skipped.hidden, skipped.held, skipped.pinned))
end

--- Lay up to PER_TICK of the buried books; true while some are left.
local function lay_some(IA, p, job)
    local u = T.util
    for _ = 1, PER_TICK do
        local e = table.remove(job.todo, 1)
        if not e then break end
        local b = e.book
        if valid(b) and not owned(b) and not attached(b) then
            local x0, y0, z0 = loc_of(b)
            u.still(b)
            local spot, final = T.lay_loose(IA, b, job.lay, e.again)
            if spot and final then
                job.laid = job.laid + 1
                M.stats.laid = M.stats.laid + 1
                job.laid_at = job.laid_at or {}
                job.laid_at[b] = { X = final.X, Y = final.Y, Z = final.Z }
                log(("book %s was buried%s at (%.0f, %.0f, %.0f)%s; laid on the floor at (%.0f, %.0f, %.0f), %.0f from the player"):format(
                    name_of(IA, b),
                    e.case and " lodged in a bookcase" or (e.depth < 900 and (" " .. string.format("%.0f", e.depth) .. " deep") or " inside geometry"),
                    x0 or 0, y0 or 0, z0 or 0, e.again and ", where it was laid" or "", final.X, final.Y, final.Z, spot.d or 0))
            else
                job.failed = job.failed + 1
                M.stats.failed = M.stats.failed + 1
                -- once per book: the second look meets it again where it was left
                job.left = job.left or {}
                if not job.left[b] then
                    job.left[b] = true
                    log(("book %s is buried and no open floor by the player has room for it%s; left where it lies"):format(
                        name_of(IA, b), e.again and " (other than where it was laid)" or ""))
                end
            end
        end
    end
    return #job.todo > 0
end

local function reset()
    M.st = { epoch = nil, n = nil, list = nil, job = nil }
end

--- Called four times a second from the traps' clock.
function M.tick(IA)
    if not (IA._gameplay_active and IA._apply_safe) then
        if M.st.n ~= nil then reset() end
        return
    end
    if not traps() then return end
    local st = M.st
    local ep = IA._world_epoch or 0
    if st.epoch ~= ep then reset(); st = M.st; st.epoch = ep end
    local p = rawget(_G, "_librarian_tick_pawn")
    if not valid(p) then p = T.util.pawn() end
    if not p then return end
    local items, n = bag_items(p)
    if items == nil then return end
    local job = st.job
    if st.n == nil then
        st.n, st.list = n, read_list(IA, items, n)
    elseif n ~= st.n then
        if n < st.n and st.list then
            -- books left the hands (a put-down, or a shelving: the judging tells them apart)
            local gone = {}
            for _, b in ipairs(st.list) do
                if valid(b) and not owned(b) then gone[#gone + 1] = b end
            end
            if #gone > 0 then
                job = job or { books = {}, seen = {}, age = 0, still = 0, pass = 1, lay = { dists = LAY_DISTS } }
                st.job = job
                -- a book can still be listed in the bag a read after it left: count it once
                for _, b in ipairs(gone) do
                    local k = T.util.key(b) or tostring(b)
                    if not job.seen[k] then
                        job.seen[k] = true
                        job.books[#job.books + 1] = b
                    end
                end
                job.quiet = 0           -- ticks since the last book left
            end
        end
        st.n, st.list = n, read_list(IA, items, n)
    end
    if not job then return end
    if job.todo then
        local ok, more = pcall(lay_some, IA, p, job)
        if not ok then
            log("stopped, error " .. tostring(more))
            st.job = nil
        elseif not more then
            if job.laid + job.failed > 0 then
                log(("re-seated %d of %d buried books"):format(job.laid, job.laid + job.failed + #job.todo))
            end
            job.todo = nil
            if job.pass >= 2 then
                st.job = nil
            else
                job.pass, job.age, job.quiet, job.still, job.sig = 2, 0, -RECHECK_TICKS, 0, nil
            end
        end
        return
    end
    -- wait for the books to come to rest
    job.age, job.quiet = job.age + 1, (job.quiet or 0) + 1
    local sig = 0
    for _, b in ipairs(job.books) do
        local x, y, z = loc_of(b)
        if x then sig = sig + x + y + z end
    end
    if job.sig and math.abs(sig - job.sig) < 0.05 then job.still = job.still + 1 else job.still = 0 end
    job.sig = sig
    if (job.quiet >= BAG_OK_TICKS and job.still >= STILL_TICKS) or job.age >= MAX_TICKS then
        local ok, e = pcall(judge, IA, p, job)
        if not ok then
            log("stopped, error " .. tostring(e))
            st.job = nil
        elseif #job.todo == 0 then
            if job.pass >= 2 then
                st.job = nil
            else
                job.todo = nil
                job.pass, job.age, job.quiet, job.still, job.sig = 2, 0, -RECHECK_TICKS, 0, nil
            end
        end
    end
end

return M
