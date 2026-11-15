-- AP/Traps.lua
-- Live-only traps. A trap changes what is on screen for a while, or moves loose books, and never
-- writes anything into the save: SpawnTransform, which the save fingerprint hashes, is not touched,
-- and a world load starts clean.
--
-- Adding a trap: write a handler and register it in HANDLERS under the item's name. A handler gets
-- (IA, ctx) and returns true when it ran, or false and a reason when it could not run safely. That
-- is a drop: the trap is spent, never queued again. ItemApply owns the once-per-item-index floor
-- (the same server-storage floor Fatigue uses), so a handler only has to do its effect.
--
--   Floor Shuffle   loose books on the floor swap places
--   Veil            unwarded loose books are hidden for a while, then come back
--   Butterfingers   some of the carried books (one up to all) fall in a pile beside the player
--   Shelf Spill     books of an unfinished row fall out onto the floor in front of the case
--   Scramble Shelf  books of an unfinished row trade places
local M = {}
local LOG_PREFIX = "[traps]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

local GRACE_S      = 20     -- a trap that cannot run yet (loading) waits this long, then is dropped
local SHUFFLE_N    = 40     -- books nearest the player that Floor Shuffle considers
local BAND         = 40     -- books trade only within a band this tall
local VEIL_CHUNK   = 150    -- books hidden or restored per tick, so a big library does not hitch
local VEIL_SECONDS = 30     -- how long a Veil lasts
local DEEP_Z       = 1000000.0   -- the pile instance of a veiled book sinks this far, as the ward does

M.HANDLERS = {}
-- Trap kinds with no argument. Items are named "<kind> Trap"; seeds made before the rename use the bare
-- kind, and "Fatigue: <skill>" for the skill traps, so those still work. "<skill> Fatigue Trap" is parsed apart.
M.NAMES = { ["Floor Shuffle"] = true, ["Veil"] = true, ["Butterfingers"] = true,
            ["Scramble Shelf"] = true, ["Shelf Spill"] = true }

M.pending = {}      -- { { kind, arg, index, deadline } }: traps waiting for a safe moment
M.veil    = nil     -- the running Veil, if any
M.veiled  = {}      -- book full name -> entry, for the books a Veil holds hidden
M.veiled_n = 0
M.stats = { fired = 0, dropped = 0 }

--- "Floor Shuffle Trap" -> "Floor Shuffle"; "Sort Fatigue Trap" -> "Fatigue", "Sort"; anything else nil.
function M.kind_of(item_name)
    if type(item_name) ~= "string" then return nil end
    local skill = item_name:match("^(.+) Fatigue Trap$") or item_name:match("^Fatigue: (.+)$")
    if skill then return "Fatigue", skill end
    if M.NAMES[item_name] then return item_name, nil end
    local kind = item_name:match("^(.+) Trap$")
    if kind and M.NAMES[kind] then return kind, nil end
    return nil
end

local function run_gt(IA, fn)
    if IA._poll_on_game_thread or type(ExecuteInGameThread) ~= "function" then return fn() end
    ExecuteInGameThread(fn)
end

local function key_of(book)
    local k
    pcall(function() k = book:GetFullName() end)
    return k
end

local function v3(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end

local function pawn()
    local p = FindFirstOf("BP_LibrarianCharacter_C")
    if p and p:IsValid() then return p end
    return nil
end

--- Why a trap cannot run right now, or nil when it can.
local function unsafe_reason(IA)
    if not (IA._gameplay_active and IA._apply_safe) then return "world not ready" end
    if IA._goal_met and IA._goal_met() then return "goal reached" end
    -- Before the ward flush has run, every book still looks unwarded; acting now would move or show books
    -- that are not the player's yet.
    if IA.ward_applied and not IA.ward_applied() then return "ward not applied yet" end
    return nil
end

--- True while a book is one a Veil holds hidden. Cheap when no Veil runs: every ward path asks.
function M.has(book)
    if M.veiled_n == 0 then return false end
    local k = key_of(book)
    return k ~= nil and M.veiled[k] ~= nil
end

-- ============================================================================
-- Shared book reading
-- ============================================================================

local function all_books()
    local list = {}
    local arr
    pcall(function() arr = FindAllOf("BP_GrabbingBook_C") end)
    if not arr then return list end
    local n = 0
    pcall(function() n = #arr end)
    for i = 1, n do
        local b = arr[i]
        if b and b:IsValid() then list[#list + 1] = b end
    end
    return list
end

--- Full names of the books in the player's bag, and the bag's books in order.
local function bag_books(IA, p)
    local set, list = {}, {}
    pcall(function()
        local bag = p.ItemBagComponent
        if not (bag and bag:IsValid()) then return end
        local items = bag.Items
        local n = 0
        pcall(function() n = #items end)
        for i = 1, n do
            local it = items[i]
            if it and it:IsValid() then
                local k = key_of(it)
                if k then set[k] = true end
                if IA._book_valid_asset_idx(it) ~= nil then list[#list + 1] = it end
            end
        end
    end)
    return set, list
end

--- Full names of every book sitting in a bookcase slot.
local function shelved_books(IA)
    local set = {}
    for _, cl in pairs(IA._section_to_cases or {}) do
        for _, c in ipairs(cl) do
            pcall(function()
                if not (c and c:IsValid()) then return end
                local pbi = c.PlacingBookInfo
                local n = #pbi
                for i = 1, n do
                    local b = pbi[i]
                    if b and b:IsValid() then
                        local k = key_of(b)
                        if k then set[k] = true end
                    end
                end
            end)
        end
    end
    return set
end

local function collision_on(book)
    local c
    pcall(function() c = book:GetActorEnableCollision() end)
    return c == true
end

-- ============================================================================
-- Butterfingers
-- ============================================================================
-- A random number of the carried books (one up to all of them) fall, one at a time, half a second
-- apart, onto one spot of open floor beside the player, each lying flat on top of the one before.
-- Measured in game: books carried past the first follow the player on the game's own path, and
-- that motion went on after the drop (three books ended inside each other under the player; one
-- went back to where it was picked up). So each dropped book has its movement timelines stopped,
-- and is held where it was laid while the game's own put-down settles (about 4 s), and put back if
-- anything moves it in that time.

local KSL_PATH   = "/Script/Engine.Default__KismetSystemLibrary"
local BF_DIRS    = { 0, 45, -45, 90, -90, 135, -135, 180 }   -- degrees off the player's facing, tried in order
local BF_DISTS   = { 70, 55 }   -- how far from the player's middle a pile may stand
local BF_KNEE    = 20     -- the way to the spot is tested this far over the floor, above books lying there
local BF_FLOOR   = 15     -- a landing must be within this of the player's own floor
local BF_PILE_MAX = 60    -- a pile this tall over its floor takes no more books; the next goes beside it
local BF_STAGGER = 2      -- ticks (a quarter second each) between two books of one trap
local BF_PIN_TICKS = 32   -- ticks a dropped book is held where it was laid (8 s)
local BF_PIN_SLACK = 1.5  -- moved further than this, it is put back
local BF_WAIT_TICKS = 80  -- a trap that cannot start (loading) waits this long, then is dropped
local BF_TIMELINES = { "CloseUp", "GoToPath", "BezierCurveMove", "ToCenterPoint", "RotateFromCenter", "ToBookCase" }

M.bf_jobs = {}      -- Butterfingers traps taken, dropping their books a tick at a time
M.bf_pins = {}      -- book full name -> { book, loc, rot, left, moved, maxd, epoch }

local function shelf_drop_mod()
    local SD = package.loaded["AP/ShelfDrop"]
    if not SD then
        local ok, mod = pcall(require, "AP/ShelfDrop")
        SD = ok and mod or nil
    end
    return SD
end

--- A straight line through world geometry, ignoring `ignore`. types: object types to hit.
--- Returns hit, impact z, whether the line started inside something, and what it hit (a name).
--- The call and the reads of what it gave back happen in one pcall.
--- M.bf_raw keeps what the last call gave back, for the log.
local function bf_trace(from, to, ignore, types)
    local k
    pcall(function() k = StaticFindObject(KSL_PATH) end)
    if not (k and k:IsValid()) then M.bf_raw = "no KismetSystemLibrary"; return nil end
    local hit, got, z, t, loc_z = {}, false, nil, nil, nil
    local black = { R = 0, G = 0, B = 0, A = 0 }
    local ok, e = pcall(function()
        got = k:LineTraceSingleForObjects(ignore[1], from, to, types or { 0, 1 }, false, ignore, 0, hit, true, black, black, 0)
        pcall(function() z = hit.ImpactPoint.Z end)
        pcall(function() loc_z = hit.Location.Z end)
        pcall(function() t = hit.Time end)
    end)
    M.bf_raw = ("ok=%s err=%s got=%s(%s) z=%s loc_z=%s t=%s"):format(tostring(ok), tostring(e), type(got), tostring(got),
        tostring(z), tostring(loc_z), tostring(t))
    if not ok then return nil end
    if type(z) ~= "number" then z = loc_z end
    -- a hit is any truthy answer with a point read back
    local hitp = (got and got ~= 0 and type(z) == "number") and true or false
    local inside = false
    if hitp and type(t) == "number" and t <= 0.0001 then inside = true end
    local who
    if hitp then
        pcall(function()
            local c = hit.Component
            if c and c.Get then c = c:Get() end
            who = c:GetOwner():GetFName():ToString()
        end)
        if not who then pcall(function() local r = hit.HitObjectHandle.ReferenceObject; if r and r.Get then r = r:Get() end; who = r:GetFName():ToString() end) end
    end
    return hitp, z, inside, who
end

--- A line down to the floor: the static world first, so a book lying there is not taken for the
--- floor; anything solid when the static world is not hit at all.
local function bf_floor_trace(from, to, ignore)
    local got, z, inside = bf_trace(from, to, ignore, { 0 })
    if got == false then got, z, inside = bf_trace(from, to, ignore, { 0, 1 }) end
    return got, z, inside
end

--- The book's bounds: origin and half size. nil when unreadable.
local function bf_box(book)
    local org, ext = {}, {}
    local o, e
    pcall(function()
        book:GetActorBounds(false, org, ext, false)
        o, e = v3(org), v3(ext)
    end)
    if o and e then return o, e end
    return nil
end

local function bf_bottom(book)
    local o, e = bf_box(book)
    return o and (o.Z - e.Z) or nil
end

--- How the book lies flat: pitch and roll that turn its thinnest side up, its thickness, its length
--- and width, and which way its long side points (true: along its own X once flat).
local function bf_flat(book)
    local dims
    pcall(function()
        local comp = book.SM_Book_1
        local b = comp.StaticMesh:GetBoundingBox()
        local mn, mx = v3(b.Min), v3(b.Max)
        local s = v3(comp:K2_GetComponentScale()) or { X = 1, Y = 1, Z = 1 }
        if mn and mx then
            dims = { X = (mx.X - mn.X) * math.abs(s.X), Y = (mx.Y - mn.Y) * math.abs(s.Y), Z = (mx.Z - mn.Z) * math.abs(s.Z) }
        end
    end)
    dims = dims or { X = 48, Y = 30, Z = 12 }
    local pitch, roll, thick, a, b = 0, 0, dims.Z, dims.X, dims.Y
    if dims.X <= dims.Y and dims.X <= dims.Z then pitch, thick, a, b = 90, dims.X, dims.Z, dims.Y
    elseif dims.Y <= dims.X and dims.Y <= dims.Z then roll, thick, a, b = 90, dims.Y, dims.X, dims.Z end
    -- a: the side along the book's X once laid, b: along its Y
    return { pitch = pitch, roll = roll, thick = thick, len = math.max(a, b), wid = math.min(a, b), long_x = a >= b }
end

--- The books still in the hands: full names, and the books in the bag in order (newest last).
local function bf_held(IA, p)
    local set, list = bag_books(IA, p)
    return set, list
end

--- The loose books lying near (px, py): { key, o (box origin), e (half size) }. Not `skip` itself,
--- not books in the hands, not ones a Veil hides. Read once per drop: a full name is not cheap.
local function bf_near(IA, p, px, py, skip)
    local held = bf_held(IA, p)
    local out = {}
    for _, b in ipairs(all_books()) do
        local x, y
        pcall(function() local l = b:K2_GetActorLocation(); x, y = l.X, l.Y end)
        if x and math.abs(x - px) < 250 and math.abs(y - py) < 250 and collision_on(b) then
            local k = key_of(b)
            local flying = false
            for _, n in ipairs(BF_TIMELINES) do
                pcall(function() if b[n]:IsPlaying() then flying = true end end)
            end
            if k and k ~= skip and not held[k] and not M.veiled[k] and not flying then
                local o, e = bf_box(b)
                if o then out[#out + 1] = { key = k, o = o, e = e, book = b } end
            end
        end
    end
    return out
end

--- The top of the pile in `near` under a footprint (centre x, y; half sizes hx, hy) on a floor at
--- fz, or nil. A pile is built from the floor up: a book counts only when it rests on the floor or
--- on a book already counted (so nothing floating over the spot, measured once at 42 over the
--- floor, can hold a book up in the air). Overlapping a little inside, so books side by side do not
--- count.
local function bf_pile_top(near, x, y, hx, hy, fz)
    local under = {}
    for _, n in ipairs(near) do
        local og, oe = n.o, n.e
        if math.abs(og.X - x) < hx + oe.X - 2 and math.abs(og.Y - y) < hy + oe.Y - 2 then
            under[#under + 1] = { bot = og.Z - oe.Z, top = og.Z + oe.Z }
        end
    end
    table.sort(under, function(a, b) return a.bot < b.bot end)
    local level = fz
    for _, u in ipairs(under) do
        if u.bot > fz - 10 and u.bot <= level + 3 and u.top > level then level = u.top end
    end
    if level > fz then return level end
    return nil
end

--- Spots of open floor around the player, in the order to try: ahead first, then to the sides,
--- then behind; each one with the way there clear at knee height and the player's own floor under
--- the whole book (not a railing, a case or a drop). The player's feet last.
--- Each spot: { x, y, fz, yaw, dir, d }.
local function bf_spots(p, ignore, fl, dists)
    local px, py, pz
    pcall(function() local l = p:K2_GetActorLocation(); px, py, pz = l.X, l.Y, l.Z end)
    if not px then return {} end
    local fz
    local got, z, inside = bf_floor_trace({ X = px, Y = py, Z = pz }, { X = px, Y = py, Z = pz - 300 }, ignore)
    if got and not inside and type(z) == "number" then fz = z end
    if (M.bf_raw_logged or 0) < 3 then
        M.bf_raw_logged = (M.bf_raw_logged or 0) + 1
        log(("Butterfingers: floor trace at the feet: %s"):format(tostring(M.bf_raw)))
    end
    if not fz then
        local hh = 90
        pcall(function() hh = p.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        fz = pz - hh
    end
    local yaw0 = 0
    pcall(function() yaw0 = p:K2_GetActorRotation().Yaw or 0 end)
    local out, why = {}, {}
    local function floor_at(x, y)
        local g, hz, inn = bf_floor_trace({ X = x, Y = y, Z = fz + 40 }, { X = x, Y = y, Z = fz - 60 }, ignore)
        if g and not inn and type(hz) == "number" and math.abs(hz - fz) <= BF_FLOOR then return hz end
        return nil
    end
    for _, a in ipairs(BF_DIRS) do
        local r = math.rad(yaw0 + a)
        local fx, fy = math.cos(r), math.sin(r)
        local tx, ty = -fy, fx            -- across the way out
        for _, d in ipairs(dists or BF_DISTS) do
            local x, y = px + fx * d, py + fy * d
            local reach = d + fl.wid / 2 + 8
            local g, _, gin, gwho = bf_trace({ X = px, Y = py, Z = fz + BF_KNEE }, { X = px + fx * reach, Y = py + fy * reach, Z = fz + BF_KNEE }, ignore)
            if g ~= false then
                why[#why + 1] = ("%d/%d way %s"):format(a, d, g == nil and "unreadable" or ((gin and "from inside " or "") .. tostring(gwho)))
            end
            if g == false then
                local hz = floor_at(x, y)
                local h = fl.len / 2
                if hz and floor_at(x + tx * h, y + ty * h) and floor_at(x - tx * h, y - ty * h)
                       and floor_at(x + fx * (fl.wid / 2 + 4), y + fy * (fl.wid / 2 + 4)) then
                    -- the long side lies across the way out, so the near edge stays clear of the player
                    local yaw = yaw0 + a + (fl.long_x and 90 or 0)
                    out[#out + 1] = { x = x, y = y, fz = hz, yaw = yaw, dir = a, d = d }
                    break
                end
                why[#why + 1] = ("%d/%d floor %s"):format(a, d, hz and "edge" or "missing")
            end
        end
    end
    out[#out + 1] = { x = px, y = py, fz = fz, yaw = yaw0, dir = 0, d = 0 }
    if #out == 1 and (M.bf_why_logged or 0) < 3 then
        M.bf_why_logged = (M.bf_why_logged or 0) + 1
        log(("Butterfingers: no open floor beside the player (floor %.0f): %s"):format(fz, table.concat(why, "; ")))
    end
    return out
end

--- The book's footprint half sizes once laid at `yaw`.
local function bf_half(fl, yaw)
    local r = math.rad(yaw)
    local c, s = math.abs(math.cos(r)), math.abs(math.sin(r))
    local lx, ly = fl.long_x and fl.len or fl.wid, fl.long_x and fl.wid or fl.len
    return (c * lx + s * ly) / 2, (s * lx + c * ly) / 2
end

--- Stop the game's own motion of a book that has left the hands.
local function bf_still(book)
    local stopped = {}
    for _, n in ipairs(BF_TIMELINES) do
        pcall(function()
            local tl = book[n]
            if tl and tl:IsValid() then
                if tl:IsPlaying() then stopped[#stopped + 1] = n end
                tl:Stop()
            end
        end)
    end
    pcall(function() book:SetSimulate(false) end)
    return stopped
end

--- Lay a book that is out of the hands on open floor by the player: the job's pile while it has room, else the
--- first checked spot around the player. Holds it there like Butterfingers does. Returns the spot, the book's final
--- location, the floor or pile top it rests on, and how many books it was lifted over; nil when no spot is readable.
local function bf_lay(IA, p, book, job, key, px, py, SD)
    local fl = bf_flat(book)
    local ignore = { book, p }
    for _, o in ipairs(select(2, bf_held(IA, p))) do ignore[#ignore + 1] = o end
    -- The job's pile while it has room, else the first spot around the player with room.
    local near = bf_near(IA, p, px, py, key)
    local spot, base
    local tries = {}
    if job.spot then tries[1] = job.spot end
    -- the last pile this world, while the player is still by it: a trap right after another adds to it
    local last = M.bf_pile
    if last and last.epoch == (IA._world_epoch or 0) and math.sqrt((last.x - px) ^ 2 + (last.y - py) ^ 2) <= 100 then
        tries[#tries + 1] = last
    end
    -- books lying near the player are not in the way: the way out is tested over them (a pile is
    -- what the next book goes onto, not an obstacle)
    local way_ignore = {}
    for _, o in ipairs(ignore) do way_ignore[#way_ignore + 1] = o end
    for _, n in ipairs(near) do way_ignore[#way_ignore + 1] = n.book end
    for _, s in ipairs(bf_spots(p, way_ignore, fl, job.dists)) do tries[#tries + 1] = s end
    for _, s in ipairs(tries) do
        local hx, hy = bf_half(fl, s.yaw)
        local top = bf_pile_top(near, s.x, s.y, hx, hy, s.fz)
        if not top or top - s.fz < BF_PILE_MAX or s.d == 0 then
            spot, base = s, math.max(s.fz, top or s.fz)
            break
        end
    end
    if not spot then return nil end   -- the player's place unreadable: the game's own fall puts it down
    job.spot = spot
    if spot.d > 0 then
        M.bf_pile = { x = spot.x, y = spot.y, fz = spot.fz, yaw = spot.yaw, dir = spot.dir, d = spot.d, epoch = IA._world_epoch or 0 }
    end
    local rot = { Pitch = fl.pitch, Yaw = spot.yaw, Roll = fl.roll }
    local loc = { X = spot.x, Y = spot.y, Z = base + fl.thick / 2 + 0.5 }
    SD.set_pose(IA, book, loc, rot)
    -- Rest it by its real bottom (its pivot is not always its middle), then lift it onto whatever
    -- its real footprint covers, so a pile of any height stacks book on book.
    local bottom = bf_bottom(book)
    if bottom and math.abs(bottom - (base + 0.3)) > 0.3 then
        loc.Z = loc.Z + (base + 0.3 - bottom)
        SD.set_pose(IA, book, loc, rot)
    end
    local under = 0
    for _ = 1, 8 do
        local o, e = bf_box(book)
        if not o then break end
        local top = bf_pile_top(near, o.X, o.Y, e.X, e.Y, spot.fz)
        local bot = o.Z - e.Z
        if not (top and top > bot - 0.1) then break end
        loc.Z = loc.Z + (top + 0.3 - bot)
        SD.set_pose(IA, book, loc, rot)
        under = under + 1
    end
    local final = v3((function() local l; pcall(function() l = book:K2_GetActorLocation() end); return l end)()) or loc
    M.bf_pins[key or tostring(book)] = { book = book, key = key, loc = { X = final.X, Y = final.Y, Z = final.Z }, rot = rot,
                                        left = BF_PIN_TICKS, moved = 0, maxd = 0, epoch = IA._world_epoch or 0 }
    return spot, final, base, under
end

--- Let one book go and lay it on the job's pile. Returns true when it left the hands.
local function bf_drop_one(IA, p, book, job)
    local key = key_of(book)
    local px, py, pz
    pcall(function() local l = p:K2_GetActorLocation(); px, py, pz = l.X, l.Y, l.Z end)
    if not px then return false end
    local was = -1
    pcall(function() local l = book:K2_GetActorLocation(); was = math.sqrt((l.X - px) ^ 2 + (l.Y - py) ^ 2 + (l.Z - pz) ^ 2) end)
    local in_hands = false
    pcall(function() local a = book:GetAttachParentActor(); in_hands = a ~= nil and a:IsValid() and key_of(a) == key_of(p) end)
    local function still_in_bag()
        local set = bf_held(IA, p)
        return key ~= nil and set[key] == true
    end
    -- HoldCancel(false) lets go at once; with true the game first plays out the put-down, and the book
    -- was measured still in the bag right after the call.
    local how = "HoldCancel"
    pcall(function() book:HoldCancel(false) end)
    if still_in_bag() then
        how = "DropGameItem"
        pcall(function() p.ItemBagComponent:DropGameItem(book) end)
        if still_in_bag() then
            log("Butterfingers: a book would not leave the hands")
            return false
        end
    end
    -- HoldCancel was measured clearing the owner itself; these only finish a fallback drop.
    pcall(function() book:K2_DetachFromActor(1, 1, 1) end)
    pcall(function() if book.OwningCharacter ~= nil and book.OwningCharacter:IsValid() then book.OwningCharacter = nil end end)
    pcall(function() book:SetActorEnableCollision(true) end)
    local stopped = bf_still(book)
    local SD = shelf_drop_mod()
    if not SD then return true end      -- out of the hands; the game's own fall puts it down

    local spot, final, base, under = bf_lay(IA, p, book, job, key, px, py, SD)
    if not spot then return true end   -- the player's place unreadable: the game's own fall puts it down
    local still_owned = false
    pcall(function() still_owned = book.OwningCharacter ~= nil and book.OwningCharacter:IsValid() end)
    if still_owned then log("Butterfingers: the book is still owned by the player after the drop") end
    local d = math.sqrt((final.X - px) ^ 2 + (final.Y - py) ^ 2 + (final.Z - pz) ^ 2)
    local bot2 = bf_bottom(book)
    log(("Butterfingers: dropped a book, %.0f from the player (%s, %.0f out at %d deg, on the floor at %.0f, "
        .. "resting at %.0f on %s, book at %.0f; it was %.0f away%s; stopped: %s)"):format(
        d, how, spot.d, spot.dir, spot.fz, bot2 or -1, (base > spot.fz + 1 or under > 0) and "a pile" or "the floor",
        final.Z, was, in_hands and ", in the hands" or ", not in the hands yet",
        #stopped > 0 and table.concat(stopped, ",") or "nothing moving"))
    return true
end

--- One step of the oldest Butterfingers trap: choose how many books fall, then one book per step.
local function bf_job_tick(IA)
    local job = M.bf_jobs[1]
    if not job then return end
    if (IA._world_epoch or 0) ~= job.epoch then
        table.remove(M.bf_jobs, 1)
        log(("Butterfingers (idx=%s): the world reloaded; nothing more falls"):format(tostring(job.index)))
        return
    end
    if job.wait > 0 then job.wait = job.wait - 1; return end
    local why = unsafe_reason(IA)
    local p = pawn()
    if why or not p then
        job.patience = job.patience - 1
        if job.patience <= 0 then
            table.remove(M.bf_jobs, 1)
            log(("Butterfingers (idx=%s): stopped, %s"):format(tostring(job.index), why or "no player"))
        end
        return
    end
    if not job.queue then
        local _, list = bf_held(IA, p)
        local n = #list
        if n == 0 then
            table.remove(M.bf_jobs, 1)
            log(("Butterfingers (idx=%s): the hands were already empty"):format(tostring(job.index)))
            return
        end
        -- one up to all of them, the most recently picked up first
        local k = math.random(1, n)
        job.queue, job.held, job.done = {}, n, 0
        for i = n, n - k + 1, -1 do job.queue[#job.queue + 1] = list[i] end
        log(("Butterfingers (idx=%s): %d of the %d books in the hands fall"):format(tostring(job.index), k, n))
    end
    local book = table.remove(job.queue, 1)
    if book and book:IsValid() then
        local set = bf_held(IA, p)
        local k = key_of(book)
        if k and set[k] and bf_drop_one(IA, p, book, job) then job.done = job.done + 1 end
    end
    if #job.queue == 0 then
        table.remove(M.bf_jobs, 1)
        local _, left = bf_held(IA, p)
        log(("Butterfingers (idx=%s): dropped %d of %d, %d still in the hands"):format(
            tostring(job.index), job.done, job.held, #left))
    else
        job.wait = BF_STAGGER - 1
    end
end

--- Hold each freshly dropped book where it was laid until the game's own put-down has settled.
local function bf_pin_tick(IA)
    for k, pin in pairs(M.bf_pins) do
        local b = pin.book
        local gone = (IA._world_epoch or 0) ~= pin.epoch or not (b and b:IsValid())
        if not gone then
            -- picked up again, or on a shelf: the player's now
            local owned, attached = false, false
            pcall(function() owned = b.OwningCharacter ~= nil and b.OwningCharacter:IsValid() end)
            pcall(function() attached = b.AttachedActor ~= nil and b.AttachedActor:IsValid() end)
            local p = pawn()
            local held = p and pin.key and bf_held(IA, p)[pin.key]
            -- a skill sending it to a shelf (the flight to a case), so not the follow-the-player motion
            local skill = false
            for _, n in ipairs({ "BezierCurveMove", "ToBookCase" }) do
                pcall(function() if b[n]:IsPlaying() then skill = true end end)
            end
            -- the player standing on or against it: whatever moves it now is the player's doing
            local close = false
            pcall(function()
                local a, c = p:K2_GetActorLocation(), b:K2_GetActorLocation()
                close = math.sqrt((a.X - c.X) ^ 2 + (a.Y - c.Y) ^ 2) < 45
            end)
            gone = owned or attached or held or skill or close
        end
        if not gone and not M.veiled[k] then
            local l = v3((function() local x; pcall(function() x = b:K2_GetActorLocation() end); return x end)())
            local sim = false
            pcall(function() sim = b:IsSimulatePhysics() == true end)
            if l then
                local d = math.sqrt((l.X - pin.loc.X) ^ 2 + (l.Y - pin.loc.Y) ^ 2 + (l.Z - pin.loc.Z) ^ 2)
                if d > BF_PIN_SLACK or sim then
                    bf_still(b)
                    local SD = shelf_drop_mod()
                    if SD then SD.set_pose(IA, b, pin.loc, pin.rot) end
                    pin.moved = pin.moved + 1
                    if d > pin.maxd then pin.maxd = d end
                end
            end
        end
        pin.left = pin.left - 1
        if gone or pin.left <= 0 then
            M.bf_pins[k] = nil
            if pin.moved > 0 then
                log(("Butterfingers: the game moved a dropped book %d time(s), up to %.0f away; put back each time"):format(
                    pin.moved, pin.maxd))
            end
        end
    end
end

--- Butterfingers is taken now (its notice shows) and runs over the next ticks. With empty hands it
--- has nothing to do and is dropped.
M.HANDLERS["Butterfingers"] = function(IA, ctx)
    local p = pawn()
    if not p then return false, "no player" end
    local bag
    pcall(function() bag = p.ItemBagComponent end)
    if not (bag and bag:IsValid()) then return false, "no bag" end
    local _, list = bf_held(IA, p)
    if #list == 0 then return false, "no book in hand" end
    M.bf_jobs[#M.bf_jobs + 1] = { index = ctx and ctx.index, epoch = IA._world_epoch or 0, wait = 0,
                                  patience = BF_WAIT_TICKS }
    return true
end

-- ============================================================================
-- Floor Shuffle
-- ============================================================================

--- The loose, unwarded floor books nearest the player swap places. Every pose used is one a book
--- already rests in, so each stays reachable and clear of geometry; only the book's flat thickness
--- differs, and the height is corrected for that.
M.HANDLERS["Floor Shuffle"] = function(IA)
    local SD = package.loaded["AP/ShelfDrop"]
    if not SD then
        local ok, mod = pcall(require, "AP/ShelfDrop")
        SD = ok and mod or nil
    end
    if not SD then return false, "ShelfDrop unavailable" end
    M.bf_pins = {}      -- the shuffle moves books on purpose: no dropped book is held against it
    local p = pawn()
    local pl
    if p then pcall(function() pl = v3(p:K2_GetActorLocation()) end) end
    if not pl then return false, "no player position" end
    local held = bag_books(IA, p)
    local unwarded = IA.unwarded_checker()
    local REACH_Z = 150     -- books on a perch higher or lower than this are not floor books; none moves to one
    local cands = {}
    for _, b in ipairs(all_books()) do
        local k = key_of(b)
        if k and not held[k] and not M.veiled[k] and unwarded(b) == true and collision_on(b) then
            local attached = false
            pcall(function() local a = b.AttachedActor; attached = a ~= nil and a:IsValid() end)
            local here = (not attached) and SD.loose_position(IA, b) or nil
            if here and math.abs(here.Z - pl.Z) > REACH_Z then here = nil end
            if here then
                local rot
                pcall(function() local r = b:K2_GetActorRotation(); rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end)
                if rot then
                    cands[#cands + 1] = { book = b, loc = here, rot = rot, thick = SD.thickness(b),
                                          d2 = (here.X - pl.X) ^ 2 + (here.Y - pl.Y) ^ 2 + (here.Z - pl.Z) ^ 2 }
                end
            end
        end
    end
    table.sort(cands, function(a, b) return a.d2 < b.d2 end)
    while #cands > SHUFFLE_N do cands[#cands] = nil end
    if #cands < 2 then return false, "fewer than two loose books" end
    -- Books only trade with books resting at about their own height (a 40 unit band), so a floor
    -- book never goes up to a perch and a perch book never drops to the floor: each lands where a
    -- similar book already lay. Inside a band: a random order, then each takes the next one's pose.
    local bands = {}
    for _, c in ipairs(cands) do
        local k = math.floor(c.loc.Z / BAND)
        bands[k] = bands[k] or {}
        table.insert(bands[k], c)
    end
    local moved, total = 0, 0
    for _, members in pairs(bands) do
        if #members >= 2 then
            local order = {}
            for i = 1, #members do order[i] = i end
            for i = #order, 2, -1 do
                local j = math.random(i)
                order[i], order[j] = order[j], order[i]
            end
            local poses = {}
            for i = 1, #order do poses[i] = members[order[i]] end
            for i = 1, #poses do
                local from = poses[i]
                local to = poses[(i % #poses) + 1]      -- the pose `from` takes was to's
                local loc = { X = to.loc.X, Y = to.loc.Y, Z = to.loc.Z - (to.thick - from.thick) / 2 }
                total = total + 1
                if SD.set_pose(IA, from.book, loc, to.rot) then moved = moved + 1 end
            end
        end
    end
    if total == 0 then return false, "no two loose books at the same height" end
    local poses = { length = total }
    log(("Floor Shuffle: %d of %d loose books swapped places"):format(moved, total))
    return moved > 0, moved > 0 and nil or "no book would move"
end

-- ============================================================================
-- Veil
-- ============================================================================

local function hism_array()
    local mgr = FindFirstOf("BP_HISM_Manager_C")
    if not (mgr and mgr:IsValid()) then return nil end
    local arr
    pcall(function() arr = mgr.HISMArray end)
    return arr
end

local function hide_one(IA, arr, b, e)
    pcall(function() e.was_hidden = b.bHidden == true end)
    pcall(function() b:SetActorHiddenInGame(true) end)
    pcall(function() b:SetActorEnableCollision(false) end)
    -- Assemble skips a book whose AttachedActor is set: the same anchor the ward uses.
    if IA._ward_anchor then pcall(IA._ward_anchor, b, true) end
    if arr and e.aidx and e.ch then
        local comp
        pcall(function() comp = arr[e.aidx + 1] end)
        if comp and comp:IsValid() then
            local cap = {}
            local got = false
            pcall(function() got = comp:GetInstanceTransform(e.ch, cap, true) end)
            local o = got and v3(cap.Translation)
            if o then
                local orig, deep
                pcall(function()
                    orig = { Translation = o, Rotation = { X = cap.Rotation.X, Y = cap.Rotation.Y, Z = cap.Rotation.Z, W = cap.Rotation.W },
                             Scale3D = { X = cap.Scale3D.X, Y = cap.Scale3D.Y, Z = cap.Scale3D.Z } }
                    deep = { Translation = { X = o.X, Y = o.Y, Z = o.Z - DEEP_Z }, Rotation = orig.Rotation, Scale3D = orig.Scale3D }
                end)
                if orig and deep and pcall(function() comp:UpdateInstanceTransform(e.ch, deep, true, true, true) end) then
                    e.pile_orig = orig
                end
            end
        end
    end
end

local function show_one(IA, arr, b, e)
    if e.pile_orig and arr then
        local comp
        pcall(function() comp = arr[e.aidx + 1] end)
        if comp and comp:IsValid() then
            pcall(function() comp:UpdateInstanceTransform(e.ch, e.pile_orig, true, true, true) end)
        end
    end
    -- A book the game itself had hidden (far away, drawn by its pile) stays the game's to show.
    if not e.was_hidden then pcall(function() b:SetActorHiddenInGame(false) end) end
    pcall(function() b:SetActorEnableCollision(true) end)
    if IA._ward_anchor then pcall(IA._ward_anchor, b, false) end
end

local function veil_forget(v)
    M.veiled, M.veiled_n = {}, 0
    if M.veil == v then M.veil = nil end
end

local function veil_tick(IA)
    local v = M.veil
    if not v then return end
    -- A new world: every book and pile this Veil touched is gone, and the new ones start shown.
    if (IA._world_epoch or 0) ~= v.epoch then
        log("Veil: the world reloaded; nothing to restore")
        veil_forget(v)
        return
    end
    if not (IA._gameplay_active and IA._apply_safe) then return end
    local arr = hism_array()
    if v.phase == "hide" then
        local last = math.min(v.cursor + VEIL_CHUNK - 1, #v.todo)
        for i = v.cursor, last do
            local b = v.todo[i]
            if b and b:IsValid() then
                local k = key_of(b)
                local aidx = IA._book_valid_asset_idx(b)
                if k and aidx ~= nil and not v.skip[k] and not M.veiled[k]
                        and v.unwarded(b) == true and collision_on(b) then
                    local ch
                    pcall(function() ch = tonumber(b.ItemInfo.Chapter) end)
                    local e = { book = b, key = k, aidx = aidx, ch = ch }
                    M.veiled[k] = e
                    M.veiled_n = M.veiled_n + 1
                    v.items[#v.items + 1] = e
                    hide_one(IA, arr, b, e)
                end
            end
        end
        v.cursor = last + 1
        if v.cursor > #v.todo then
            v.todo = nil
            v.phase = "on"
            log(("Veil: %d books hidden for %ds"):format(#v.items, v.dur))
        end
    end
    if v.phase == "on" and os.time() >= v.deadline then
        v.phase, v.cursor = "restore", 1
    end
    if v.phase == "restore" then
        local last = math.min(v.cursor + VEIL_CHUNK - 1, #v.items)
        for i = v.cursor, last do
            local e = v.items[i]
            if e.book and e.book:IsValid() then show_one(IA, arr, e.book, e) end
        end
        v.cursor = last + 1
        if v.cursor > #v.items then
            local n = #v.items
            veil_forget(v)
            -- Re-assert the true ward state over whatever the books look like now.
            pcall(function() IA.flush_apply() end)
            log(("Veil: over, %d books back"):format(n))
        end
    end
end

M.HANDLERS["Veil"] = function(IA)
    local dur = VEIL_SECONDS
    local v = M.veil
    if v then
        if v.phase == "restore" then return false, "a Veil is ending" end
        -- A second Veil while one runs holds it for a fresh full length, it does not add up.
        v.deadline = math.max(v.deadline, os.time() + dur)
        v.dur = math.max(v.dur, dur)
        log(("Veil: already running, held for %ds more"):format(dur))
        return true
    end
    local p = pawn()
    if not p then return false, "no player" end
    local held, skip = bag_books(IA, p), nil
    skip = shelved_books(IA)
    for k in pairs(held) do skip[k] = true end
    M.veil = { unwarded = IA.unwarded_checker(), phase = "hide", todo = all_books(), cursor = 1, items = {}, skip = skip,
               dur = dur, deadline = os.time() + dur, epoch = IA._world_epoch or 0 }
    return true
end

-- ============================================================================
-- Shelf traps: Shelf Spill and Scramble Shelf
-- ============================================================================
-- Both touch only rows the game does not mark finished, so a finished row, its check and the
-- rows-finished count never change. Measured in game (1.0.13): a book leaving a slot lowers the
-- game's book count, a book going back raises it to the true number again and never past it, so
-- spilling and reshelving cannot earn a check twice.
-- Rows are found on the grid bookcases
-- and on the wide cabinets, and are read the way the book count reads them, never from the
-- game's per-book "placed correctly" flag, which a load does not restore. Any book the player
-- has earned counts, however it was shelved. A case's finished-row count is read when its row is
-- picked and again once books leave it; if it moved, the books go back. The row is one the player
-- can see where possible: in the section they stand in, else nearby on the same floor, and only
-- when neither has one, the nearest anywhere.
--   Shelf Spill    BP_GrabbingItem_C:DetachActor() frees the slot (the case books it as taken)
--                   and leaves the book resting where it was; ShelfDrop then lays it on the floor
--                   in front of the case. A book with no clear floor goes back into its own slot.
--   Scramble Shelf  books of one series on one row (never left in chapter order, so it cannot
--                   finish a row) leave their slots, then go into each other's slots one at a
--                   time with the skill pickup and the case's own InsertBook, so the game judges
--                   every placement (and the misorder notice follows).
-- The work runs over a few ticks as a job; one job at a time, the rest wait their turn. A job
-- waits (up to SHELF_WAIT_S) while the player carries books, a save is being written or the ward
-- flush runs, and is dropped after that or when the goal is reached or the world reloads.

local SHELF_WAIT_S = 30
local SPILL_MIN, SPILL_MAX = 3, 5
local SCRAMBLE_MIN, SCRAMBLE_MAX = 2, 4
local NEAREST_ROWS = 3      -- the row is picked at random among this many nearest the player
local HOLD_TICKS = 34       -- Shelf Spill holds its books this many ticks (8.5 s) before its last look
local NEAR_R = 2000         -- a row in another section counts as near within this (about 20 m)

M.shelf_jobs = {}

local function save_busy()
    local busy = false
    pcall(function()
        local ss = FindFirstOf("SaveSubsystem")
        if ss and ss:IsValid() then busy = ss.WaitingSave and true or false end
    end)
    return busy
end

--- Why a shelf trap must wait now, or nil.
local function shelf_wait_reason(IA)
    local why = unsafe_reason(IA)
    if why then return why end
    if IA._flush_in_progress then return "ward flush running" end
    if save_busy() then return "saving" end
    local p = pawn()
    if not p then return "no player" end
    local _, list = bag_books(IA, p)
    if #list > 0 then return "player is carrying books" end
    return nil
end

local function slot_book(case, slot)
    local b
    pcall(function() b = case.PlacingBookInfo[slot + 1] end)
    if b then
        local ok = false
        pcall(function() ok = b:IsValid() end)
        if ok then return b end
    end
    return nil
end

local function same_actor(a, b)
    if not (a and b) then return false end
    local ka, kb = key_of(a), key_of(b)
    return ka ~= nil and ka == kb
end

local function row_done(case, r)
    local d = false
    pcall(function() local v = case.RowStatus[r + 1]; d = (v == true or v == 1) end)
    return d
end

--- How many of a case's rows the game marks finished. A shelf trap reads it before it moves a
--- book and again after: any change means the reading of the case was wrong, and the books go back.
local function finished_count(case)
    local n = 0
    pcall(function()
        local rs = case.RowStatus
        local k = #rs
        for i = 1, k do
            local v = rs[i]
            if v == true or v == 1 then n = n + 1 end
        end
    end)
    return n
end

local function abs_correct(book)
    local v
    pcall(function() v = book["Is Abs Correct"] end)
    return v == true
end

--- The books along one run (slot order) of one series that sit in chapter order: the longest run
--- of rising chapters, the same reading the book count uses. Returns a set of positions in g.
local function in_order_set(g)
    local best, prev = {}, {}
    for a = 1, #g do
        best[a] = 1
        for b = 1, a - 1 do
            if g[b].ch < g[a].ch and best[b] + 1 > best[a] then best[a], prev[a] = best[b] + 1, b end
        end
    end
    local on = {}
    if #g == 0 then return on end
    local tail = 1
    for a = 2, #g do if best[a] > best[tail] then tail = a end end
    local k = tail
    while k do on[k] = true; k = prev[k] end
    return on
end

--- Whether a shelved book sits where the game wants it. The game's own per-book flag is not
--- restored by a load (it reads false for every book shelved before it), so it only ever counts
--- for yes: the verdict the count recorded for this placement comes first, then the flag, then the
--- count's rule (this case takes the series in that slot, and the book is in chapter order).
local function in_place(IA, case, case_name, e, ordered)
    local v = IA._cnt_verdicts and e.key and IA._cnt_verdicts[e.key]
    if v and v.case == case_name and (v.slot == nil or v.slot == e.slot + 1) then return v.ok == true end
    if abs_correct(e.book) then return true end
    local col
    pcall(function() col = case:IsPlaceWithAbsCorrectColumn(e.slot, e.aidx) end)
    if col == false then return false end
    return ordered
end

--- Every place on one case a shelf trap may act on, as runs of books in slot order:
---   a grid case (its slots split evenly into its rows): each row the game does not mark finished;
---   a wide cabinet (1C, 1D, 1G, 1H and the floor-2 cabinets, whose rows have widths nothing
---     readable gives): each series on it that is not finished, read as the count and the row
---     check read cabinets (every volume, chapters 0..n-1 in slot order). The cabinet is used only
---     when that reading finds exactly as many finished series as the case marks finished rows.
--- A run lists only books the player has earned (not warded, not veiled); others are left out of
--- it, never moved. diag collects why places were passed over, for the drop message.
local function case_runs(IA, c, unwarded, diag)
    local out = {}
    local pbi, n, rn = nil, 0, 0
    pcall(function() pbi = c.PlacingBookInfo; n = #pbi end)
    pcall(function() rn = #c.RowStatus end)
    if n == 0 or rn == 0 then return out end
    local case_name = key_of(c)
    local function read(s)
        local b = slot_book(c, s)
        if not b then return nil end
        local aidx = IA._book_valid_asset_idx(b)
        local ch
        if aidx ~= nil then pcall(function() ch = tonumber(b.ItemInfo.Chapter) end) end
        if aidx == nil or ch == nil then diag.unreadable = diag.unreadable + 1; return nil end
        if unwarded(b) ~= true or M.has(b) then diag.not_earned = diag.not_earned + 1; return nil end
        return { book = b, slot = s, aidx = aidx, ch = ch, key = key_of(b) }
    end
    -- groups: series -> its books on the run in slot order, with which of them are in place
    local function finish_run(run)
        local by = {}
        for _, e in ipairs(run.books) do
            by[e.aidx] = by[e.aidx] or {}
            table.insert(by[e.aidx], e)
        end
        run.groups = {}
        for aidx, g in pairs(by) do
            local ord = in_order_set(g)
            local placed = {}
            for i, e in ipairs(g) do
                if in_place(IA, c, case_name, e, ord[i] == true) then placed[#placed + 1] = e end
            end
            run.groups[#run.groups + 1] = { aidx = aidx, books = g, placed = placed }
        end
        return run
    end
    if n % rn == 0 then
        diag.grid = diag.grid + 1
        local per = n // rn
        for r = 0, rn - 1 do
            local books = {}
            local any = false
            for s = r * per, r * per + per - 1 do
                if slot_book(c, s) then any = true end
                local e = read(s)
                if e then books[#books + 1] = e end
            end
            if any then
                diag.rows_with_books = diag.rows_with_books + 1
                if row_done(c, r) then
                    diag.rows_finished = diag.rows_finished + 1
                elseif #books > 0 then
                    out[#out + 1] = finish_run({ case = c, row = r, books = books })
                end
            end
        end
        return out
    end
    diag.cabinets = diag.cabinets + 1
    local all, by = {}, {}
    for s = 0, n - 1 do
        local b = slot_book(c, s)
        if b then
            -- every shelved book counts towards the finished reading, earned or not
            local aidx = IA._book_valid_asset_idx(b)
            local ch
            if aidx ~= nil then pcall(function() ch = tonumber(b.ItemInfo.Chapter) end) end
            if aidx == nil or ch == nil then
                diag.cabinets_unsafe = diag.cabinets_unsafe + 1
                return out              -- a book that cannot be read: the reading cannot be checked
            end
            by[aidx] = by[aidx] or {}
            table.insert(by[aidx], ch)
            all[#all + 1] = s
        end
    end
    if #all == 0 then return out end
    local finished, done_series = 0, {}
    for aidx, chs in pairs(by) do
        local want = tonumber(IA._asset_to_volumes and IA._asset_to_volumes[aidx]) or 0
        local ok = want > 0 and #chs == want
        if ok then
            for k = 1, #chs do if chs[k] ~= k - 1 then ok = false; break end end
        end
        if ok then finished = finished + 1; done_series[aidx] = true end
        diag.rows_with_books = diag.rows_with_books + 1
    end
    diag.rows_finished = diag.rows_finished + finished
    if finished ~= finished_count(c) then
        diag.cabinets_unsafe = diag.cabinets_unsafe + 1
        return out
    end
    local runs = {}
    for _, s in ipairs(all) do
        local e = read(s)
        if e and not done_series[e.aidx] then
            runs[e.aidx] = runs[e.aidx] or { case = c, row = nil, aidx = e.aidx, books = {} }
            table.insert(runs[e.aidx].books, e)
        end
    end
    for _, run in pairs(runs) do out[#out + 1] = finish_run(run) end
    return out
end

local function new_diag()
    return { cases = 0, grid = 0, cabinets = 0, cabinets_unsafe = 0, rows_with_books = 0,
             rows_finished = 0, not_earned = 0, unreadable = 0 }
end

--- Why a shelf trap found nothing, in game terms, for the drop line.
local function diag_text(d)
    return ("%d bookcases looked at (%d wide cabinets, %d of them passed over as not safely readable): "
        .. "%d rows with books, %d of them finished; %d shelved books not yet yours, %d unreadable"):format(
        d.cases, d.cabinets, d.cabinets_unsafe, d.rows_with_books, d.rows_finished, d.not_earned, d.unreadable)
end

--- Every unfinished place on any bookcase of the library, nearest the player first. Each run
--- carries its section, distance and the case's finished-row count at the time it was read.
local function all_runs(IA, diag)
    local pl
    local p = pawn()
    if p then pcall(function() pl = v3(p:K2_GetActorLocation()) end) end
    local unwarded = IA.unwarded_checker()
    local list = {}
    local here_sid, here_d2
    for sid, cl in pairs(IA._section_to_cases or {}) do
        for _, c in ipairs(cl) do
            local cloc
            pcall(function() if c:IsValid() then cloc = v3(c:K2_GetActorLocation()) end end)
            if cloc and not (cloc.X == 0 and cloc.Y == 0 and cloc.Z == 0) then
                diag.cases = diag.cases + 1
                local fin = finished_count(c)
                local d2 = pl and ((cloc.X - pl.X) ^ 2 + (cloc.Y - pl.Y) ^ 2 + (cloc.Z - pl.Z) ^ 2) or 0
                if pl and (not here_d2 or d2 < here_d2) then here_sid, here_d2 = sid, d2 end
                for _, run in ipairs(case_runs(IA, c, unwarded, diag)) do
                    run.sid, run.d2, run.fin = sid, d2, fin
                    list[#list + 1] = run
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d2 < b.d2 end)
    return list, here_sid
end

--- Which of `items` (nearest first; run_of(item) gives its run) a shelf trap acts on, so the player
--- sees it: a run in the section the player stands in (the section of the nearest bookcase) first,
--- then one on the same floor within NEAR_R, and only when there is neither, the nearest anywhere.
--- Within that group, a random one of the nearest few. Returns an index into items.
local function choose(items, here_sid, run_of)
    local floor = here_sid and tostring(here_sid):sub(1, 1)
    local tiers = { {}, {}, {} }
    for i, it in ipairs(items) do
        local r = run_of(it)
        local t = 3
        if here_sid and r.sid == here_sid then t = 1
        elseif floor and tostring(r.sid):sub(1, 1) == floor and (r.d2 or 0) <= NEAR_R * NEAR_R then t = 2 end
        table.insert(tiers[t], i)
    end
    for k, t in ipairs(tiers) do
        if #t > 0 then return t[math.random(math.min(#t, NEAREST_ROWS))], k end
    end
    return nil, 4
end

local function pick_near(rows, here_sid)
    return rows[(choose(rows, here_sid, function(r) return r end))]
end

--- A run named for the log: the grid row, or the cabinet series.
local function run_label(IA, sid, row, aidx)
    if row then return ("%s row %d"):format(tostring(sid), row) end
    local sname = aidx and IA._asset_to_series and IA._asset_to_series[aidx]
    return ("%s cabinet, %s"):format(tostring(sid), sname and ("'" .. sname .. "'") or "a series")
end

--- A HUD line for the player. Shelf traps say where they acted, in the same words as the
--- out-of-order row notice: the bookcase name, and a row counted from 1 (the log counts from 0).
local function hud(text)
    local H = package.loaded["AP/HUD"]
    if H and H.notify then pcall(H.notify, text, 12.0) end
end

local function where_text(IA, job)
    if job.row then return ("bookcase %s, row %d"):format(tostring(job.sid), job.row + 1) end
    local label = tostring(job.label or job.sid or "a bookcase")
    return "bookcase " .. label
end

local function shelfdrop()
    local SD = package.loaded["AP/ShelfDrop"]
    if not SD then
        local ok, mod = pcall(require, "AP/ShelfDrop")
        SD = ok and mod or nil
    end
    return SD
end

local function touched(IA, case)
    if IA.note_case_event then pcall(IA.note_case_event, case) end
end

--- Back into its own slot without the hands: the case's ReturnBookToCase (the Return All Books
--- path). Used only as the undo when a step cannot finish, so the book's verdict is the one it had.
local function put_back(case, slot, book)
    if slot_book(case, slot) then return false end
    return pcall(function() case:ReturnBookToCase(slot, book, false) end)
end

-- ---------------------------------------------------------------- Shelf Spill
local function spill_plan(IA, job)
    local diag = new_diag()
    local rows, here_sid = all_runs(IA, diag)
    if #rows == 0 then return false, "no unfinished row with books (" .. diag_text(diag) .. ")" end
    local first = pick_near(rows, here_sid)
    local order = { first }
    for _, r in ipairs(rows) do if r ~= first and r.case == first.case then order[#order + 1] = r end end
    for _, r in ipairs(rows) do if r.case ~= first.case then order[#order + 1] = r end end
    local want = math.random(SPILL_MIN, SPILL_MAX)
    job.items = {}
    -- Only a book that has a floor to land on is taken off its shelf: asked here, in its slot, with
    -- nothing moved. (A book that had to be put back after leaving was measured left out of its
    -- slot, so none is taken out on a guess.) A bounded number of asks per trap.
    local SD0 = shelfdrop()
    local asks, ASK_MAX = 0, 60
    for _, r in ipairs(order) do
        -- the lowest books first: a book off a low shelf lands on the floor right below it, while
        -- one off the top of a tall cabinet has to fall further (then, the last slots first)
        local books = {}
        for i = #r.books, 1, -1 do
            local e = r.books[i]
            local z
            pcall(function() z = e.book:K2_GetActorLocation().Z end)
            books[#books + 1] = { e = e, z = z or math.huge, k = #books }
        end
        table.sort(books, function(x, y) if x.z ~= y.z then return x.z < y.z end return x.k < y.k end)
        for _, b in ipairs(books) do
            if #job.items >= want then break end
            local e = b.e
            local ok_floor = true
            if SD0 and SD0.can_land then
                if asks >= ASK_MAX then ok_floor = false
                else
                    asks = asks + 1
                    ok_floor = SD0.can_land(IA, e.book, r.case)
                end
            end
            if ok_floor then
                job.items[#job.items + 1] = { book = e.book, slot = e.slot, case = r.case, row = r.row, sid = r.sid,
                                              fin = r.fin }
            end
        end
        if #job.items >= want then break end
    end
    if #job.items == 0 then return false, "no book has a bare floor to land on (" .. asks .. " looked at)" end
    job.sid, job.row = first.sid, first.row
    job.label = run_label(IA, first.sid, first.row, first.aidx)
    job.dist = math.sqrt(first.d2 or 0)
    return true
end

local function spill_step(IA, job)
    if job.phase == "detach" then
        local n = 0
        for _, it in ipairs(job.items) do
            -- still where it was planned, in a row still unfinished, on a case whose finished rows
            -- are the ones it had when the row was picked
            if same_actor(slot_book(it.case, it.slot), it.book)
                    and not (it.row and row_done(it.case, it.row))
                    and finished_count(it.case) == it.fin then
                -- where it stands in the slot: once out, the game may start carrying it off
                pcall(function() it.from = v3(it.book:K2_GetActorLocation()) end)
                it.detached = pcall(function() it.book:DetachActor() end)
                if it.detached then
                    n = n + 1
                    local SD = shelfdrop()
                    if SD and SD.still then SD.still(it.book) end
                end
            end
        end
        if n == 0 then return "done", "nothing left to spill" end
        job.phase = "drop"
        return nil
    end
    if job.phase == "drop" then
        -- A case that lost a finished row when its books left was read wrong: its books go back
        -- into their own slots before anything lands on the floor.
        local reverted = 0
        for _, it in ipairs(job.items) do
            if it.detached and finished_count(it.case) ~= it.fin then
                for _, x in ipairs(job.items) do
                    if x.detached and x.case == it.case then
                        put_back(x.case, x.slot, x.book)
                        x.detached = false
                        reverted = reverted + 1
                    end
                end
            end
        end
        if reverted > 0 then
            log(("Shelf Spill: a finished row changed on %s when its books left; %d put back"):format(
                tostring(job.label), reverted))
        end
        local SD = shelfdrop()
        local floor, back, stuck = 0, 0, 0
        for _, it in ipairs(job.items) do
            if it.detached then
                touched(IA, it.case)
                if slot_book(it.case, it.slot) and same_actor(slot_book(it.case, it.slot), it.book) then
                    stuck = stuck + 1          -- the case kept it: nothing moved
                else
                    local moved, why = false, "ShelfDrop unavailable"
                    if SD and SD.off_case then
                        local ok, m, w = pcall(SD.off_case, IA, it.book, it.case, it.from)
                        if ok then moved, why = m, w else why = tostring(m) end
                    end
                    if moved then
                        floor = floor + 1
                        pcall(function() it.landed = v3(it.book:K2_GetActorLocation()) end)
                    else
                        log(("Shelf Spill: no floor for a book off %s (%s); it goes back"):format(
                            tostring(job.label), tostring(why)))
                        if put_back(it.case, it.slot, it.book) then back = back + 1; it.returned = true
                        else stuck = stuck + 1 end
                    end
                end
            end
        end
        log(("Shelf Spill: %d books off %s onto the floor (%d put back, %d left; %.0f from the player)"):format(
            floor, tostring(job.label), back, stuck, job.dist or 0))
        if floor == 0 then return "done", "no book reached the floor" end
        hud(("Shelf Spill: %d book%s fell off %s"):format(floor, floor == 1 and "" or "s", where_text(IA, job)))
        job.phase, job.vt = "hold", HOLD_TICKS
        return nil
    end
    if job.phase == "hold" then
        -- ShelfDrop holds each laid book where it landed for 8 s (the game goes on moving books that
        -- left a slot), letting go once the player has it. Then a last look: a book away from where
        -- it landed, that the player did not take, is named in the log.
        local SD = shelfdrop()
        local running = (SD and SD.pin_tick) and SD.pin_tick(IA, pawn()) or 0
        job.vt = job.vt - 1
        if running > 0 and job.vt > 0 then return nil end
        local off = 0
        for _, it in ipairs(job.items) do
            if it.landed then
                local now, owned, attached = nil, false, false
                pcall(function() now = v3(it.book:K2_GetActorLocation()) end)
                pcall(function() owned = it.book.OwningCharacter ~= nil and it.book.OwningCharacter:IsValid() end)
                pcall(function() attached = it.book.AttachedActor ~= nil and it.book.AttachedActor:IsValid() end)
                local d = now and math.sqrt((now.X - it.landed.X) ^ 2 + (now.Y - it.landed.Y) ^ 2
                    + (now.Z - it.landed.Z) ^ 2) or -1
                if not owned and not attached and (d < 0 or d > 30) then
                    off = off + 1
                    log(("Shelf Spill: a book did not stay where it landed (now at %s, %.0f away)"):format(
                        now and ("%.0f, %.0f, %.0f"):format(now.X, now.Y, now.Z) or "?", d))
                end
            end
        end
        -- a book put back should be in its slot by now: if the case does not hold it, try again, and say so
        for _, it in ipairs(job.items) do
            if it.returned and not same_actor(slot_book(it.case, it.slot), it.book) then
                local again = put_back(it.case, it.slot, it.book)
                log(("Shelf Spill: a book put back is not in its slot; tried again (%s)"):format(tostring(again)))
            end
        end
        if off == 0 then log("Shelf Spill: every book stayed where it landed") end
        return "done"
    end
    return "done", "bad phase"
end

-- ---------------------------------------------------------------- Scramble Shelf
--- After `items` trade slots (each to its .target), are the series' books on the run in rising
--- chapter order? A Scramble only goes ahead when they are not, so it can never finish a row.
local function ascending_after(g, items)
    local at = {}
    for _, e in ipairs(g.books) do at[e.slot] = e.ch end
    for _, it in ipairs(items) do at[it.target] = it.ch end
    local slots = {}
    for s in pairs(at) do slots[#slots + 1] = s end
    table.sort(slots)
    for i = 2, #slots do
        if at[slots[i]] <= at[slots[i - 1]] then return false end
    end
    return true
end

local function shuffled(list)
    local pool = {}
    for i, e in ipairs(list) do pool[i] = e end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    return pool
end

--- Books of one series on one unfinished run trade slots in a cycle. Books the game would call in
--- place are preferred (the ones a scramble visibly undoes: each lands out of order); a run with
--- fewer than two of those still qualifies with any two of its books. The result is never in
--- chapter order, so whatever was there, a Scramble cannot finish a row.
local function scramble_plan(IA, job)
    local diag = new_diag()
    local rows, here_sid = all_runs(IA, diag)
    local best, rest = {}, {}
    for _, r in ipairs(rows) do
        for _, g in ipairs(r.groups or {}) do
            if #g.placed >= SCRAMBLE_MIN then best[#best + 1] = { run = r, g = g, pool = g.placed }
            elseif #g.books >= SCRAMBLE_MIN then rest[#rest + 1] = { run = r, g = g, pool = g.books } end
        end
    end
    if #best + #rest == 0 then
        return false, "no unfinished row with two books of one series (" .. diag_text(diag) .. ")"
    end
    -- the nearest group first (see choose); within it, a row with books in place over one without.
    -- The others are tried in turn, nearest first, if one cannot be scrambled out of order.
    local run_of = function(c) return c.run end
    local bi, bt = choose(best, here_sid, run_of)
    local ri, rt = choose(rest, here_sid, run_of)
    local cands, first = best, bi
    if not bi or rt < bt then cands, first = rest, ri end
    local tryorder = { first }
    for i = 1, #cands do if i ~= first then tryorder[#tryorder + 1] = i end end
    for _, ci in ipairs(tryorder) do
        local c = cands[ci]
        for _ = 1, 8 do
            local pool = shuffled(c.pool)
            local k = math.min(#pool, math.random(SCRAMBLE_MIN, SCRAMBLE_MAX))
            local items = {}
            for i = 1, k do items[i] = { book = pool[i].book, slot = pool[i].slot, ch = pool[i].ch } end
            -- each book takes the next one's slot: a cycle, so no book stays where it was
            for i = 1, k do items[i].target = items[(i % k) + 1].slot end
            if not ascending_after(c.g, items) then
                local r = c.run
                job.items = items
                job.case, job.row, job.sid, job.fin, job.i = r.case, r.row, r.sid, r.fin, 0
                job.label = run_label(IA, r.sid, r.row, c.g.aidx)
                job.dist = math.sqrt(r.d2 or 0)
                return true
            end
        end
    end
    return false, "no row whose books could be scrambled out of order (" .. diag_text(diag) .. ")"
end

local function scramble_undo(IA, job, from)
    for i = from, #job.items do
        local it = job.items[i]
        if it.detached and not it.placed then
            if not put_back(job.case, it.slot, it.book) then
                local SD = shelfdrop()
                if SD and SD.off_case then pcall(SD.off_case, IA, it.book, job.case) end
            end
        end
    end
end

local function scramble_step(IA, job)
    local case = job.case
    if job.phase == "detach" then
        if (job.row and row_done(case, job.row)) or finished_count(case) ~= job.fin then
            return "done", "a row on that bookcase was finished meanwhile"
        end
        for _, it in ipairs(job.items) do
            if not same_actor(slot_book(case, it.slot), it.book) then
                return "done", "the row changed before the scramble"
            end
        end
        for _, it in ipairs(job.items) do
            it.detached = pcall(function() it.book:DetachActor() end)
        end
        job.phase = "check"
        return nil
    end
    if job.phase == "check" then
        touched(IA, case)
        for _, it in ipairs(job.items) do
            if not it.detached or slot_book(case, it.slot) then
                scramble_undo(IA, job, 1)
                return "done", "a book did not leave its slot"
            end
        end
        -- the books leaving must not have cost the case a finished row: the reading was wrong
        if finished_count(case) ~= job.fin then
            scramble_undo(IA, job, 1)
            return "done", "a finished row on that bookcase changed; the books went back"
        end
        job.phase, job.i = "grab", 1
        return nil
    end
    local it = job.items[job.i]
    if job.phase == "grab" then
        local held_by_player = false
        pcall(function() held_by_player = it.book.OwningCharacter ~= nil and it.book.OwningCharacter:IsValid() end)
        if held_by_player or slot_book(case, it.target) then
            -- the player took it, or something filled its new slot: this one goes back home
            if not held_by_player then put_back(case, it.slot, it.book) end
            it.placed = true
            job.i = job.i + 1
            if job.i > #job.items then job.phase = "finish" end
            return nil
        end
        pcall(function() it.book:GrabFromSkill() end)
        job.phase = "insert"
        return nil
    end
    if job.phase == "insert" then
        local held = false
        pcall(function() held = it.book.OwningCharacter ~= nil and it.book.OwningCharacter:IsValid() end)
        if held and not slot_book(case, it.target) then
            pcall(function() case:InsertBook(it.target, it.book) end)
            it.moved = true
        else
            put_back(case, it.slot, it.book)
        end
        it.placed = true
        job.i = job.i + 1
        job.phase = (job.i > #job.items) and "finish" or "grab"
        return nil
    end
    if job.phase == "finish" then
        touched(IA, case)
        local n = 0
        for _, x in ipairs(job.items) do
            if x.moved and same_actor(slot_book(case, x.target), x.book) then n = n + 1 end
        end
        log(("Scramble Shelf: %d of %d books traded places in %s (%.0f from the player)"):format(
            n, #job.items, tostring(job.label), job.dist or 0))
        if finished_count(case) ~= job.fin then
            log(("Scramble Shelf: the finished rows on %s went from %d to %d"):format(
                tostring(job.label), job.fin, finished_count(case)))
        end
        if n >= 2 then
            hud(("Scramble Shelf: %d books on %s are out of order"):format(n, where_text(IA, job)))
            return "done"
        end
        return "done", "fewer than two books moved"
    end
    return "done", "bad phase"
end

local SHELF_KINDS = {
    ["Shelf Spill"]    = { plan = spill_plan, step = spill_step },
    ["Scramble Shelf"] = { plan = scramble_plan, step = scramble_step },
}

local function shelf_tick(IA)
    local job = M.shelf_jobs[1]
    if not job then return end
    local function finish(why)
        table.remove(M.shelf_jobs, 1)
        if why then
            M.stats.dropped = M.stats.dropped + 1
            log(("%s dropped (idx=%s): %s"):format(job.kind, tostring(job.index), why))
            if why == "player is carrying books" then
                hud(job.kind .. " skipped: you were carrying books")
            elseif why ~= "the world reloaded" and why ~= "goal reached" then
                hud(job.kind .. " skipped: nothing on the shelves for it to move")
            end
        end
    end
    if (IA._world_epoch or 0) ~= job.epoch then
        -- a reload: whatever was mid-way came back from the save as the game had it
        return finish("the world reloaded")
    end
    local K = SHELF_KINDS[job.kind]
    if job.phase == "wait" then
        local why = shelf_wait_reason(IA)
        if why == "goal reached" then return finish(why) end
        if why then
            if os.time() >= job.deadline then return finish(why) end
            return
        end
        local ok, why2 = K.plan(IA, job)
        if not ok then return finish(why2) end
        job.phase = "detach"
        return
    end
    -- Once books are out of their slots the job runs to the end without waiting, so no book is
    -- left half-moved.
    local state, why = K.step(IA, job)
    if state == "done" then finish(why) end
end

local function shelf_handler(kind)
    return function(IA, ctx)
        local job = { kind = kind, index = ctx and ctx.index, phase = "wait",
                      deadline = os.time() + SHELF_WAIT_S, epoch = IA._world_epoch or 0 }
        -- Nothing to act on and nothing to wait for: drop now rather than hold it.
        if not shelf_wait_reason(IA) and #M.shelf_jobs == 0 then
            local probe = {}
            local ok, why = SHELF_KINDS[kind].plan(IA, probe)
            if not ok then return false, why end
        end
        M.shelf_jobs[#M.shelf_jobs + 1] = job
        log(("%s queued (idx=%s)"):format(kind, tostring(job.index)))
        return true
    end
end
M.HANDLERS["Shelf Spill"] = shelf_handler("Shelf Spill")
M.HANDLERS["Scramble Shelf"] = shelf_handler("Scramble Shelf")

-- ============================================================================
-- Dispatch
-- ============================================================================

--- Run one trap now. ItemApply has already decided it has not fired before.
function M.run(IA, kind, arg, index)
    local h = M.HANDLERS[kind]
    if not h then
        M.stats.dropped = M.stats.dropped + 1
        log(("%s (idx=%s): no handler; dropped"):format(kind, tostring(index)))
        return
    end
    local why = unsafe_reason(IA)
    if why then
        -- Loading: try again for a short while, then give up. Never kept past the grace.
        M.pending[#M.pending + 1] = { kind = kind, arg = arg, index = index, deadline = os.time() + GRACE_S }
        return
    end
    run_gt(IA, function()
        local ok, did, reason = pcall(h, IA, { arg = arg, index = index })
        if ok and did then
            M.stats.fired = M.stats.fired + 1
            log(("%s fired (idx=%s)"):format(kind, tostring(index)))
        else
            M.stats.dropped = M.stats.dropped + 1
            log(("%s dropped (idx=%s): %s"):format(kind, tostring(index), ok and tostring(reason) or ("error: " .. tostring(did))))
        end
    end)
end

--- What AP/StackRecover needs: the same floor reading and landing as Butterfingers.
M.util = { trace = bf_trace, box = bf_box, collision = collision_on, key = key_of, still = bf_still, pawn = pawn }

--- Lay a loose book on open floor by the player, as Butterfingers does its dropped books, and hold it there for
--- a few seconds. `job` is a table kept for one batch of books: they share one pile. Returns the spot and the
--- book's final location, or nil when the player or a floor cannot be read.
function M.lay_loose(IA, book, job)
    local p = pawn()
    local SD = shelf_drop_mod()
    if not (p and SD) then return nil end
    local px, py
    pcall(function() local l = p:K2_GetActorLocation(); px, py = l.X, l.Y end)
    if not px then return nil end
    local spot, final = bf_lay(IA, p, book, job, key_of(book), px, py, SD)
    return spot, final
end

local SR_MOD = nil
local function stack_recover()
    if SR_MOD == nil then
        local ok, mod = pcall(require, "AP/StackRecover")
        SR_MOD = (ok and type(mod) == "table") and mod or false
    end
    return SR_MOD or nil
end

--- Called four times a second from main.lua. Runs the Veil's work and retries waiting traps.
--- A trap waiting only for the first ward flush stays until it has run (that flush comes with the
--- player's first movement, once the books are populated); every other unsafe state gets GRACE_S.
function M.tick(IA)
    if #M.pending > 0 then
        local keep = {}
        local why = unsafe_reason(IA)
        local now = os.time()
        for _, t in ipairs(M.pending) do
            if not why then
                M.run(IA, t.kind, t.arg, t.index)
            elseif why == "goal reached" then
                M.stats.dropped = M.stats.dropped + 1
                log(("%s dropped (idx=%s): %s"):format(t.kind, tostring(t.index), why))
            elseif why == "ward not applied yet" then
                t.deadline = now + GRACE_S      -- waiting on the flush is not a timeout
                keep[#keep + 1] = t
            elseif now >= t.deadline then
                M.stats.dropped = M.stats.dropped + 1
                log(("%s dropped (idx=%s): %s"):format(t.kind, tostring(t.index), why))
            else
                keep[#keep + 1] = t
            end
        end
        M.pending = keep
        -- Nothing else re-runs a flush that was deferred for unpopulated books: nudge it.
        if why == "ward not applied yet" and #keep > 0 and now - (M.last_nudge or 0) >= 5 then
            M.last_nudge = now
            pcall(function() IA.flush_apply() end)
        end
    end
    if M.veil then
        run_gt(IA, function() pcall(veil_tick, IA) end)
    end
    if #M.bf_jobs > 0 or next(M.bf_pins) ~= nil then
        run_gt(IA, function()
            local ok, e = pcall(bf_job_tick, IA)
            if not ok then
                local job = table.remove(M.bf_jobs, 1)
                log(("Butterfingers (idx=%s): stopped, error %s"):format(tostring(job and job.index), tostring(e)))
            end
            local ok2, e2 = pcall(bf_pin_tick, IA)
            if not ok2 then
                M.bf_pins = {}
                log("Butterfingers: holding dropped books stopped, error " .. tostring(e2))
            end
        end)
    end
    local sr = stack_recover()
    if sr then run_gt(IA, function() pcall(sr.tick, IA) end) end
    if #M.shelf_jobs > 0 then
        run_gt(IA, function()
            local ok, e = pcall(shelf_tick, IA)
            if not ok then
                local job = table.remove(M.shelf_jobs, 1)
                log(("%s dropped: error %s"):format(job and job.kind or "shelf trap", tostring(e)))
            end
        end)
    end
end

--- A new connection or slot: waiting traps belong to the old one. A running Veil ends at the next
--- tick instead of running on.
function M.reset()
    M.pending = {}
    -- a shelf job not started yet belongs to the old connection; one with books out of their slots
    -- finishes, so no book is left half-moved
    local keep = {}
    for _, j in ipairs(M.shelf_jobs) do if j.phase ~= "wait" then keep[#keep + 1] = j end end
    M.shelf_jobs = keep
    -- a Butterfingers trap that has not chosen its books yet belongs to the old connection
    local bf = {}
    for _, j in ipairs(M.bf_jobs) do if j.queue then bf[#bf + 1] = j end end
    M.bf_jobs = bf
    if M.veil and M.veil.phase == "on" then M.veil.deadline = 0 end
end

return M
