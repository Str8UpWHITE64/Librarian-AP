-- AP/ShelfDrop.lua
-- Books resting on a bookcase but not in a slot, moved to the floor in front of it. Some spawn on
-- shelf geometry; hidden, they pass through everything, so a player can shelve another book into
-- the same space and the hidden one reappears inside it. On reveal, or on load, such a book goes
-- out the case's front and lies flat on the lowest surface there. Only the live position moves:
-- SpawnTransform, which the save fingerprint hashes, is never written.
local M = {}
local LOG_PREFIX = "[ShelfDrop]"
local function log(msg) print(LOG_PREFIX .. " " .. tostring(msg)) end

local CLEAR = 8.0             -- gap past the case's front face, beyond the book's own length
local STEP, MAX_OUT = 15.0, 150.0 -- stepping further out until the floor is bare, and how far
local OFF_FLOOR = 5.0         -- a book this far above the case floor is resting on it
local GROUND_ABOVE_MAX = 60.0 -- a trace hit higher than this over the case floor is not the floor
local NEAR = 40.0             -- a book this close outside a case is logged as a near miss
local FRONT_PAD = 12.0        -- a book resting on a shelf pokes out past the case's front face:
                              -- measured 1, 3 and 9 units on three such books
local ON_SHELF = 15.0         -- that margin only counts this far above the floor, where books lying
                              -- on piles in front of a case (measured 20-34 units out) do not reach
local HIGH, HIGH_PAD = 90.0, 30.0 -- above this nothing but a shelf is there, and books resting on
                              -- one were measured 12-20 units past the face
local STACK_R = 30.0          -- a landing this close to one already made goes on top of it
local UPPER_REACH = 250.0     -- an upper floor counts only this far below the book it takes
local UPPER_FLAT = 5          -- and only when this many steps out (75 units deep) find that same floor
local LOW_START = 100.0       -- the low trace starts this far over the case's base
local KNEE = 20.0             -- the way out from the face is tested this far over the floor
local PLAYER_LEVEL = 10.0     -- the player stands on a floor when their own floor is within this of it
local line_hits, player_floor -- set further down, beside off_case
local SPREAD = 45.0           -- Shelf Spill: books lie at least this far apart where the floor allows.
                              -- Spilled books stacked on each other can be carried back up onto
                              -- their shelf by the game's own book motion moments later.
local NAMED_PARTS = { "StaticMesh", "SM_M01_BookCabinet_03", "SM_M01_CabinetWall_02" }
local KSL_PATH = "/Script/Engine.Default__KismetSystemLibrary"
local SMC_PATH = "/Script/Engine.StaticMeshComponent"

M.stats = { moved = 0, shelved = 0, blocked = 0, no_floor = 0, failed = 0 }
M._done = {}              -- book full name -> true once judged this world
M._cases, M._cases_epoch = nil, nil
M._trace_state = nil      -- nil untested, "ok", or "unreadable"
M._logged, M._near_logged = 0, 0
M._landed = {}            -- this world's landings: { x, y, top }, for stacking

local function v3(v)
    if not v then return nil end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    -- A field that is not there reads as an invalid wrapper in UE4SS, not nil: only numbers count.
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { X = x, Y = y, Z = z }
end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function add(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
local function mul(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end

--- A component's world scale. GetComponentScale is C++ only; K2_GetComponentScale is its script
--- name, with the relative scale as the fallback.
local function comp_scale(comp)
    local sc
    pcall(function() sc = v3(comp:K2_GetComponentScale()) end)
    if not sc then pcall(function() sc = v3(comp.RelativeScale3D) end) end
    return sc or { X = 1, Y = 1, Z = 1 }
end

local function mesh_box(comp)
    local mn, mx
    pcall(function()
        local mesh = comp.StaticMesh
        if not (mesh and mesh:IsValid()) then return end
        local b = mesh:GetBoundingBox()
        mn = v3(b.Min) or v3(b.min)
        mx = v3(b.Max) or v3(b.max)
    end)
    return mn, mx
end

--- A mesh component's frame and its mesh's local box: enough to test a world point against the
--- mesh's bounds and to move along its axes.
local function frame(comp)
    local f = {}
    local ok = pcall(function()
        f.loc = v3(comp:K2_GetComponentLocation())
        f.F = v3(comp:GetForwardVector())
        f.R = v3(comp:GetRightVector())
        f.U = v3(comp:GetUpVector())
        f.S = comp_scale(comp)
    end)
    if not (ok and f.loc and f.F and f.R and f.U and f.S) then return nil end
    f.min, f.max = mesh_box(comp)
    if not (f.min and f.max) then return nil end
    return f
end

local function to_local(f, p)
    local d = sub(p, f.loc)
    return { X = dot(d, f.F) / f.S.X, Y = dot(d, f.R) / f.S.Y, Z = dot(d, f.U) / f.S.Z }
end
local function to_world(f, l)
    return add(f.loc, add(mul(f.F, l.X * f.S.X), add(mul(f.R, l.Y * f.S.Y), mul(f.U, l.Z * f.S.Z))))
end
local function inside(f, l, pad)
    pad = pad or 0
    return l.X >= f.min.X - pad and l.X <= f.max.X + pad and l.Y >= f.min.Y - pad and l.Y <= f.max.Y + pad
        and l.Z >= f.min.Z - pad and l.Z <= f.max.Z + pad
end
--- How far outside a box a local point lies, on its worst axis (0 when within), in world units.
local function outside_by(f, l)
    local function ax(a)
        local lo, hi = f.min[a], f.max[a]
        local d = (l[a] < lo and lo - l[a]) or (l[a] > hi and l[a] - hi) or 0
        return d * math.abs(f.S[a])
    end
    return math.max(ax("X"), ax("Y"), ax("Z"))
end

--- Every mesh piece on a case. A cabinet is several meshes (body, wall), and the component
--- named StaticMesh is only one of them, so a box of that one alone let a book sit, and land,
--- inside the rest.
local function case_parts(c)
    local parts = {}
    local cls
    pcall(function() cls = StaticFindObject(SMC_PATH) end)
    local listed = 0
    if cls and cls:IsValid() then
        local ok, err = pcall(function()
            local arr = c:K2_GetComponentsByClass(cls)
            local n = #arr
            listed = n
            for i = 1, n do
                local comp = arr[i]
                -- Elements of a returned array arrive wrapped; the component is inside.
                pcall(function() if comp.get then comp = comp:get() end end)
                local name = ""
                pcall(function() name = comp:GetFName():ToString() end)
                -- The placement preview is a ghost book, not the case.
                if comp and comp:IsValid() and name ~= "PreviewBookLocation" then
                    local f = frame(comp)
                    if f then f.name = name; parts[#parts + 1] = f end
                end
            end
        end)
        if not ok and not M._list_said then
            M._list_said = true
            log("mesh piece listing failed: " .. tostring(err):sub(1, 120))
        end
    elseif not M._list_said then
        M._list_said = true
        log("mesh piece listing: StaticMeshComponent class not found")
    end
    -- The known pieces by name as well, whatever the listing found: a cabinet's body and wall.
    local have = {}
    for _, f in ipairs(parts) do have[f.name] = true end
    for _, nm in ipairs(NAMED_PARTS) do
        if not have[nm] then
            pcall(function()
                local comp = c[nm]
                if comp and comp:IsValid() then
                    local f = frame(comp)
                    if f then f.name = nm; parts[#parts + 1] = f end
                end
            end)
        end
    end
    return parts
end

--- Every bookcase, once per world: its parts, and from its main mesh the depth axis, the front
--- (the side its slots face), the outer faces over every part, and the floor height.
local function cases(IA)
    if M._cases and M._cases_epoch == (IA._world_epoch or 0) then return M._cases end
    local list, n_all, n_parts, fronts = {}, 0, 0, 0
    for sid, cl in pairs(IA._section_to_cases or {}) do
        for _, c in ipairs(cl) do
            n_all = n_all + 1
            local parts = (c and c:IsValid()) and case_parts(c) or {}
            local main
            for _, p in ipairs(parts) do if p.name == "StaticMesh" then main = p end end
            main = main or parts[1]
            if main then
                local e = { sid = sid, case = c, parts = parts, main = main }
                local dx = (main.max.X - main.min.X) * math.abs(main.S.X)
                local dy = (main.max.Y - main.min.Y) * math.abs(main.S.Y)
                e.axis = (dx <= dy) and "X" or "Y"
                e.floor_z = to_world(main, { X = (main.min.X + main.max.X) / 2, Y = (main.min.Y + main.max.Y) / 2,
                                             Z = main.min.Z }).Z
                pcall(function()
                    local bl = v3(c.Billboard1:K2_GetComponentLocation())
                    if bl then
                        local l = to_local(main, bl)
                        e.front = (l[e.axis] >= (main.min[e.axis] + main.max[e.axis]) / 2) and 1 or -1
                    end
                end)
                if e.front then fronts = fronts + 1 end
                local lo, hi = main.min[e.axis], main.max[e.axis]
                for _, p in ipairs(parts) do
                    for _, cx in ipairs({ p.min.X, p.max.X }) do
                        for _, cy in ipairs({ p.min.Y, p.max.Y }) do
                            local l = to_local(main, to_world(p, { X = cx, Y = cy, Z = p.min.Z }))
                            if l[e.axis] < lo then lo = l[e.axis] end
                            if l[e.axis] > hi then hi = l[e.axis] end
                        end
                    end
                end
                e.lo, e.hi = lo, hi
                n_parts = n_parts + #parts
                list[#list + 1] = e
            end
        end
    end
    M._cases, M._cases_epoch = list, IA._world_epoch or 0
    M._done, M._landed = {}, {}
    log(("bookcases: %d of %d read, %d mesh pieces, %d fronts from the slot billboards"):format(
        #list, n_all, n_parts, fronts))
    return list
end

--- The case a point is inside, if any: any of its pieces, with a pad.
local function case_at(IA, p, pad)
    for _, e in ipairs(cases(IA)) do
        for _, part in ipairs(e.parts) do
            if inside(part, to_local(part, p), pad or 0) then return e end
        end
    end
    return nil
end

--- The case a book is resting on: inside it, or poking out past its front face by a little,
--- high enough that it is on a shelf rather than on a pile of books on the floor in front.
local function case_resting(IA, p)
    local e = case_at(IA, p, 0)
    if e then return e end
    for _, c in ipairs(cases(IA)) do
        if p.Z > c.floor_z + ON_SHELF and c.front then
            local m, a = c.main, c.axis
            local l = to_local(m, p)
            local o = (a == "X") and "Y" or "X"
            local s = math.abs(m.S[a]) ~= 0 and math.abs(m.S[a]) or 1
            local pad = (p.Z > c.floor_z + HIGH) and HIGH_PAD or FRONT_PAD
            local lo = c.lo - ((c.front < 0) and pad / s or 0)
            local hi = c.hi + ((c.front > 0) and pad / s or 0)
            if l[a] >= lo and l[a] <= hi and l[o] >= m.min[o] and l[o] <= m.max[o]
                    and l.Z >= m.min.Z and l.Z <= m.max.Z then
                return c
            end
        end
    end
    return nil
end

--- The book's own size, from its mesh: the thin axis goes vertical when it lies flat.
local function book_dims(book)
    local comp
    pcall(function() comp = book.SM_Book_1 end)
    if not comp then return nil end
    local mn, mx = mesh_box(comp)
    if not (mn and mx) then return nil end
    local S = comp_scale(comp)
    return { X = (mx.X - mn.X) * math.abs(S.X), Y = (mx.Y - mn.Y) * math.abs(S.Y), Z = (mx.Z - mn.Z) * math.abs(S.Z) }
end

--- UE's FRotator -> FQuat, for the pile instance, which takes a transform.
local function quat(p, y, r)
    local d = math.pi / 360
    local sp, cp = math.sin(p * d), math.cos(p * d)
    local sy, cy = math.sin(y * d), math.cos(y * d)
    local sr, cr = math.sin(r * d), math.cos(r * d)
    return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
             Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end

local function weak_owner_class(wp)
    local name
    pcall(function()
        local obj = wp
        if obj and obj.Get then obj = obj:Get() end
        if obj and obj.get then obj = obj:get() end
        local owner = obj
        pcall(function() local o = obj:GetOwner(); if o and o:IsValid() then owner = o end end)
        name = owner:GetClass():GetFName():ToString()
    end)
    return name
end

--- The highest surface under a point, and what it belongs to: the floor, a book already lying
--- there, or something that is neither. nil when the trace cannot be read, which is then said
--- once and the case's own floor is used instead.
local function ground_z(book, x, y, z_from, z_to)
    if M._trace_state == "unreadable" then return nil end
    local ksl
    pcall(function() ksl = StaticFindObject(KSL_PATH) end)
    if not (ksl and ksl:IsValid()) then
        M._trace_state = "unreadable"; log("line trace: KismetSystemLibrary not found; using the case floor")
        return nil
    end
    local hit = {}
    local got, z, what = false, nil, nil
    local black = { R = 0, G = 0, B = 0, A = 0 }
    -- By object type first: static world, movable, physics body, destructible, so a book lying on
    -- the floor blocks it. The visibility channel alone passed straight through books, and every
    -- landing came out at floor height, on top of whatever book was already there.
    if M._obj_trace ~= false then
        local ok = pcall(function()
            got = ksl:LineTraceSingleForObjects(book, { X = x, Y = y, Z = z_from }, { X = x, Y = y, Z = z_to },
                { 0, 1, 3, 5 }, false, { book }, 0, hit, true, black, black, 0)
            local ip = v3(hit.ImpactPoint) or v3(hit.Location)
            if ip then z = ip.Z end
        end)
        if not ok and M._obj_trace == nil then
            M._obj_trace = false
            log("object trace: unavailable; tracing the visibility channel, stacking from this mod's own landings")
        elseif ok and M._obj_trace == nil then
            M._obj_trace = true
        end
    end
    if M._obj_trace == false then
        hit, got, z = {}, false, nil
        pcall(function()
            got = ksl:LineTraceSingle(book, { X = x, Y = y, Z = z_from }, { X = x, Y = y, Z = z_to },
                0, false, { book }, 0, hit, true, black, black, 0)
            local ip = v3(hit.ImpactPoint) or v3(hit.Location)
            if ip then z = ip.Z end
        end)
    end
    if got and z then
        what = weak_owner_class(hit.Component)
        if not what then pcall(function() what = weak_owner_class(hit.HitObjectHandle.ReferenceObject) end) end
        if M._trace_state ~= "ok" then
            M._trace_state = "ok"
            log(("line trace: readable, landing on the surface below (first hit: %s)"):format(tostring(what)))
        end
        return z, what
    end
    if got and not z then
        M._trace_state = "unreadable"; log("line trace: hit but its point did not read back; using the case floor")
    end
    return nil
end

local function book_name(IA, book)
    local aidx, ch
    pcall(function() aidx = tonumber(book.ItemInfo.AssetIdx); ch = tonumber(book.ItemInfo.Chapter) end)
    local sname = aidx and IA._asset_to_series and IA._asset_to_series[aidx] or "?"
    return ("%s vol %s"):format(tostring(sname), ch and tostring(ch + 1) or "?"), aidx, ch
end

--- Where a book at point p on case e belongs on the floor: out the case's front past its
--- outermost face by the book's full length, lying flat. The same answer from the same point
--- every session, so nothing new needs saving. nil and a reason when there is no clear spot.
function M.floor_spot(IA, book, e, p)
    local dims = book_dims(book) or { X = 48, Y = 30, Z = 12 }
    -- The whole length, not half: the pivot's place in the book is not known, and once it lies
    -- flat its far end can reach back by up to its full length.
    local reach = math.max(dims.X, dims.Y, dims.Z)
    local main, a = e.main, e.axis
    local l0 = to_local(main, p)
    local first = e.front or ((l0[a] >= (e.lo + e.hi) / 2) and 1 or -1)
    local s = math.abs(main.S[a]) ~= 0 and math.abs(main.S[a]) or 1
    -- Both faces, the front first. Which face is the front is read from a slot marker, and a case
    -- standing back to back with another, or a shelf that is not a bookcase, can sit on either
    -- side; the landing test in move() decides, not this guess.
    -- Out the front, in steps: the first spot clears the case's face by the book's length, and
    -- each step goes further, so whatever sits at the case's base (a plinth, a lip the mesh box
    -- does not cover) is passed over until the floor below is bare. move() takes the first one.
    local spots, why = {}, nil
    local lf = { X = l0.X, Y = l0.Y, Z = l0.Z }
    lf[a] = (first > 0) and (e.hi + CLEAR / s) or (e.lo - CLEAR / s)
    local face = to_world(main, lf)
    local extra = 0
    while extra <= MAX_OUT do
        local l = { X = l0.X, Y = l0.Y, Z = l0.Z }
        local d = (reach + CLEAR + extra) / s
        l[a] = (first > 0) and (e.hi + d) or (e.lo - d)
        local out = to_world(main, l)
        local blocker = case_at(IA, { X = out.X, Y = out.Y, Z = e.floor_z + 2 }, 0)
        if blocker and blocker.case ~= e.case then why = "landing inside " .. tostring(blocker.sid); break end
        if not blocker then spots[#spots + 1] = { x = out.X, y = out.Y, out = reach + CLEAR + extra } end
        extra = extra + STEP
    end
    if #spots == 0 then return nil, why or "no spot in front" end
    local yaw = 0
    pcall(function() yaw = book:K2_GetActorRotation().Yaw or 0 end)
    local pitch, roll, thick = 0, 0, dims.Z
    if dims.X <= dims.Y and dims.X <= dims.Z then pitch, thick = 90, dims.X
    elseif dims.Y <= dims.X and dims.Y <= dims.Z then roll, thick = 90, dims.Y end
    local scale
    pcall(function() scale = v3(book.SpawnTransform.Scale3D) end)
    if not scale or scale.X == 0 then scale = { X = 1, Y = 1, Z = 1 } end
    -- low_start: the traces start just over the case's base instead of at the book, so a book off a
    -- top shelf finds the floor the case stands on, under anything overhead in front of the shelf
    local from_z = e.low_start and (e.floor_z + LOW_START) or math.max(p.Z, e.floor_z + 100)
    return { spots = spots, from_z = from_z, floor_z = e.floor_z, sid = e.sid,
             face_x = face.X, face_y = face.Y, low_start = e.low_start,
             pitch = pitch, yaw = yaw, roll = roll, lift = thick / 2 + 0.5, scale = scale, dims = dims }
end

--- Put a book on its floor spot: actor and pile instance together, physics off, as the proven
--- home restore does. Returns true on a move.
function M.move(IA, book, spot, why)
    -- A landing proves itself: the trace down must hit the floor, or a book lying on it. Anything
    -- else, the bottom of a case, a table, a shelf this mod does not know, is not a landing.
    -- The floor is the lowest surface along the steps, not the case's bottom: some cases stand
    -- slightly into a raised floor (measured 16 units in part of floor 2), and the first step
    -- clear of the case with that surface under it is the landing.
    local hits, pick, gz, ground, first_hit = {}, nil, nil, nil, nil
    M.last_first_z = nil      -- the first surface the steps found, for off_case's upper-floor try
    for i, c in ipairs(spot.spots) do
        hits[i] = ground_z(book, c.x, c.y, spot.from_z, spot.floor_z - 50)
        if not hits[i] then break end
        first_hit = first_hit or (hits[i] - spot.floor_z)
        M.last_first_z = M.last_first_z or hits[i]
    end
    if not hits[1] then
        -- Unreadable trace: the case floor, a fair step further out than the first spot. Never for
        -- an upper floor, which only a trace can prove.
        if not spot.need_flat and not spot.low_start then
            local i = math.min(#spot.spots, 4)
            pick, gz, ground = spot.spots[i], spot.floor_z, "case floor"
        end
    else
        local low
        for _, z in ipairs(hits) do if not low or z < low then low = z end end
        -- need_flat: an upper floor must be a walkway, not a ledge: that many steps out from the
        -- face all find the same surface
        local flat_ok = true
        if spot.need_flat then
            local n = 0
            for i = 1, #spot.spots do
                if hits[i] and math.abs(hits[i] - low) <= 4 then n = n + 1 end
            end
            flat_ok = n >= spot.need_flat
        end
        if flat_ok and low <= spot.floor_z + GROUND_ABOVE_MAX then
            -- spread: the first bare-floor step with no landing of this world within SPREAD, so
            -- books spilled together lie side by side instead of on each other
            -- low_start: the way out from the case's face to the spot is open at knee height, so
            -- the spot is the floor in front of the case and not a space closed off under something
            local open = {}
            local function path_ok(i, c)
                -- spread (a spill): the book must lie loose where it lands, not on a plinth or the
                -- top of a low case (measured: one landed 35 up on something by the 1D cabinet)
                if spot.spread and case_resting(IA, { X = c.x, Y = c.y, Z = hits[i] + spot.lift }) then
                    return false
                end
                if not spot.low_start then return true end
                if open[i] == nil then
                    local z = spot.floor_z + KNEE
                    open[i] = not line_hits(book, { X = spot.face_x, Y = spot.face_y, Z = z }, { X = c.x, Y = c.y, Z = z })
                end
                return open[i]
            end
            if spot.spread then
                for i, c in ipairs(spot.spots) do
                    if hits[i] and hits[i] <= low + 4 and path_ok(i, c) then
                        local free = true
                        for _, l in ipairs(M._landed) do
                            local dx, dy = l.x - c.x, l.y - c.y
                            if dx * dx + dy * dy < SPREAD * SPREAD then free = false; break end
                        end
                        if free then pick, gz, ground = c, hits[i], "floor"; break end
                    end
                end
            end
            if not pick then
                for i, c in ipairs(spot.spots) do
                    if hits[i] and hits[i] <= low + 4 and path_ok(i, c) then pick, gz, ground = c, hits[i], "floor"; break end
                end
            end
        end
    end
    if pick then
        -- On top of what is already there. The trace finds a book lying on the floor when it can;
        -- this mod's own landings in this world are known regardless, so a second book off the
        -- same stretch of shelf goes on the first rather than inside it.
        local top = gz
        if hits[1] then
            for i, c in ipairs(spot.spots) do
                if c == pick and hits[i] and hits[i] > top and hits[i] <= spot.floor_z + GROUND_ABOVE_MAX then
                    top = hits[i]
                end
            end
        end
        for _, l in ipairs(M._landed) do
            local dx, dy = l.x - pick.x, l.y - pick.y
            if dx * dx + dy * dy <= STACK_R * STACK_R and l.top > top then top = l.top end
        end
        if top > gz + 1 then ground = "books on the floor" end
        gz = top
    end
    if not pick then
        if not spot.dry then
            M.stats.no_floor = M.stats.no_floor + 1
            log(("left on %s: %s (no bare floor within %.0f of its front; first surface %.0f up)"):format(
                tostring(spot.sid), (select(1, book_name(IA, book))), MAX_OUT, first_hit or -1))
        end
        return false
    end
    -- a dry run (can_land) only asks whether a landing exists: the book is not touched
    if spot.dry then return true end
    spot.x, spot.y = pick.x, pick.y
    ground = ("%s, %.0f out from the face"):format(ground, pick.out)
    local loc = { X = spot.x, Y = spot.y, Z = gz + spot.lift }
    local rot = { Pitch = spot.pitch, Yaw = spot.yaw, Roll = spot.roll }
    pcall(function() book:SetSimulate(false) end)
    local ok = false
    pcall(function() ok = book:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) and true or false end)
    if not ok then
        M.stats.failed = M.stats.failed + 1
        return false
    end
    local name, aidx, ch = book_name(IA, book)
    -- Second layer: the pile instance, which is what the far view draws.
    if aidx and ch then
        local t = { Translation = loc, Rotation = quat(rot.Pitch, rot.Yaw, rot.Roll), Scale3D = spot.scale }
        pcall(function()
            local mgr = FindFirstOf("BP_HISM_Manager_C")
            mgr.HISMArray[aidx + 1]:UpdateInstanceTransform(ch, t, true, true, true)
        end)
        local st = IA._book_inst_state and IA._book_inst_state[aidx .. "|" .. ch]
        if st then st.orig, st.hidden = t, false end
    end
    M._landed[#M._landed + 1] = { x = loc.X, y = loc.Y, top = loc.Z + spot.lift }
    M.last_pose = { loc = loc, rot = rot }
    M.stats.moved = M.stats.moved + 1
    if M._logged < 100 then
        M._logged = M._logged + 1
        log(("%s: %s off %s onto the %s at (%.0f, %.0f, %.0f), book %.0fx%.0fx%.0f laid pitch %d roll %d"):format(
            why or "moved", name, tostring(spot.sid), ground, loc.X, loc.Y, loc.Z,
            spot.dims.X, spot.dims.Y, spot.dims.Z, spot.pitch, spot.roll))
    end
    return true
end

--- A book's flat thickness: its thin axis is the one that goes vertical when it lies down.
function M.thickness(book)
    local d = book_dims(book)
    if not d then return 12 end
    return math.min(d.X, d.Y, d.Z)
end

--- Where a book is, when it is loose on the floor: not inside a bookcase and not resting on one.
--- nil for a book on a case, one at the world origin (the inert copy), or one that cannot be read.
function M.loose_position(IA, book)
    local here
    pcall(function() here = v3(book:K2_GetActorLocation()) end)
    if not here or (here.X == 0 and here.Y == 0 and here.Z == 0) then return nil end
    if case_resting(IA, here) then return nil end
    return here
end

--- Put a book at a pose: the actor and its pile instance together, physics off. The pile instance
--- keeps the book's own scale. Only the live position moves, never SpawnTransform.
function M.set_pose(IA, book, loc, rot)
    pcall(function() book:SetSimulate(false) end)
    local ok = false
    pcall(function() ok = book:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) and true or false end)
    if not ok then return false end
    local _, aidx, ch = book_name(IA, book)
    if aidx and ch then
        local scale
        pcall(function() scale = v3(book.SpawnTransform.Scale3D) end)
        if not scale or scale.X == 0 then scale = { X = 1, Y = 1, Z = 1 } end
        local t = { Translation = loc, Rotation = quat(rot.Pitch, rot.Yaw, rot.Roll), Scale3D = scale }
        pcall(function()
            local mgr = FindFirstOf("BP_HISM_Manager_C")
            mgr.HISMArray[aidx + 1]:UpdateInstanceTransform(ch, t, true, true, true)
        end)
        local st = IA._book_inst_state and IA._book_inst_state[aidx .. "|" .. ch]
        if st then st.orig, st.hidden = t, false end
    end
    return true
end

--- Lay a book flat on the floor under (x, y): the surface found by a trace down from from_z, or
--- fallback_z when the trace cannot be read. Actor and pile instance together. Returns ok, floor z.
function M.place_flat(IA, book, x, y, from_z, fallback_z)
    local dims = book_dims(book) or { X = 48, Y = 30, Z = 12 }
    local pitch, roll, thick = 0, 0, dims.Z
    if dims.X <= dims.Y and dims.X <= dims.Z then pitch, thick = 90, dims.X
    elseif dims.Y <= dims.X and dims.Y <= dims.Z then roll, thick = 90, dims.Y end
    local gz = ground_z(book, x, y, from_z, from_z - 600)
    if not gz or gz > from_z - 20 then gz = fallback_z end
    local yaw = 0
    pcall(function() yaw = book:K2_GetActorRotation().Yaw or 0 end)
    local ok = M.set_pose(IA, book, { X = x, Y = y, Z = gz + thick / 2 + 0.5 },
                          { Pitch = pitch, Yaw = yaw, Roll = roll })
    return ok, gz
end

local function in_slots(case, key)
    local found = false
    pcall(function()
        local pbi = case.PlacingBookInfo
        local n = #pbi
        for i = 1, n do
            local b = pbi[i]
            if b and b:IsValid() and b:GetFullName() == key then found = true; break end
        end
    end)
    return found
end

--- Called for each book the flush reveals, and for every revealed book on load. Judged once per
--- book per world by where it is now: inside a case, off its floor, and not in its slot list.
function M.on_unward(IA, book)
    local key
    pcall(function() key = book:GetFullName() end)
    if not key or M._done[key] then return end
    cases(IA)
    M._done[key] = true
    local here
    pcall(function() here = v3(book:K2_GetActorLocation()) end)
    -- The inert copy of the book set sits at the origin; it is never the one a player sees.
    if not here or (here.X == 0 and here.Y == 0 and here.Z == 0) then return end
    local e = case_resting(IA, here)
    if not e then
        -- Near misses, off the floor: a book resting on a case's edge rather than inside it.
        if M._near_logged < 60 then
            for _, c in ipairs(M._cases) do
                if here.Z > c.floor_z + 15 then
                    for _, part in ipairs(c.parts) do
                        local d = outside_by(part, to_local(part, here))
                        if d > 0 and d <= NEAR then
                            M._near_logged = M._near_logged + 1
                            log(("near miss: %s is %.0f outside %s (%s), %.0f above its floor; left alone"):format(
                                (book_name(IA, book)), d, tostring(c.sid), tostring(part.name), here.Z - c.floor_z))
                            return
                        end
                    end
                end
            end
        end
        return
    end
    if here.Z <= e.floor_z + OFF_FLOOR then return end
    if in_slots(e.case, key) then
        M.stats.shelved = M.stats.shelved + 1
        return
    end
    local spot, why = M.floor_spot(IA, book, e, here)
    if not spot then
        M.stats.blocked = M.stats.blocked + 1
        log(("left on %s: %s (%s)"):format(tostring(e.sid), (book_name(IA, book)), tostring(why)))
        return
    end
    M.move(IA, book, spot, "revealed")
end

--- For F8: where a loose book is, the bookcase piece nearest it, and how this module reads it.
--- The second value says whether it is by a bookcase: inside one, or within NEAR off the floor.
function M.explain(IA, book)
    local here
    pcall(function() here = v3(book:K2_GetActorLocation()) end)
    local name = select(1, book_name(IA, book))
    if not here then return name .. ": position unreadable", false end
    local best, bd, bp
    for _, c in ipairs(cases(IA)) do
        for _, part in ipairs(c.parts) do
            local d = outside_by(part, to_local(part, here))
            if not bd or d < bd then best, bd, bp = c, d, part end
        end
    end
    if not best then return name .. ": no bookcases read", false end
    local key
    pcall(function() key = book:GetFullName() end)
    local up = here.Z - best.floor_z
    local text = ("%s at (%.0f, %.0f, %.0f): %s %s (%s), %.0f above its floor; %s, %s"):format(
        name, here.X, here.Y, here.Z, bd > 0 and ("%.0f outside"):format(bd) or "inside",
        tostring(best.sid), tostring(bp.name), up,
        case_resting(IA, here) and "reads as resting on it" or "reads as not on it",
        (key and M._done[key]) and "judged this world" or "not judged this world")
    return text, bd <= NEAR and up > OFF_FLOOR, bd, up
end

--- For the paths that send a book home (Assemble's bag eviction, the planned trap): a book whose
--- spawn point is inside a case goes to the floor in front of it instead. nil when home is fine.
function M.redirect_home(IA, book)
    local home
    pcall(function() home = v3(book.SpawnTransform.Translation) end)
    if not home or (home.X == 0 and home.Y == 0 and home.Z == 0) then return nil end
    local e = case_resting(IA, home)
    if not e or home.Z <= e.floor_z + OFF_FLOOR then return nil end
    local spot = M.floor_spot(IA, book, e, home)
    if not spot then return nil end
    return M.move(IA, book, spot, "sent home")
end

--- For Shelf Spill: a book that has just left a slot of `case` goes to the floor in front of that
--- case. Unlike on_unward it does not ask whether the book reads as resting on the case (a wide
--- cabinet's pieces do not box its shelves, and a bottom-shelf book sits within OFF_FLOOR of the
--- case floor): the case is known. Out the front first, then the other face. Returns true on a move,
--- else false and why.
--- A straight line through world geometry (static and movable), ignoring the book: true when it
--- hits something, false when clear, nil when the trace cannot be read (counted as not clear).
line_hits = function(book, from, to)
    local ksl
    pcall(function() ksl = StaticFindObject(KSL_PATH) end)
    if not (ksl and ksl:IsValid()) then return true end
    local hit, got = {}, nil
    local black = { R = 0, G = 0, B = 0, A = 0 }
    local ok = pcall(function()
        got = ksl:LineTraceSingleForObjects(book, from, to, { 0, 1 }, false, { book }, 0, hit, true, black, black, 0)
    end)
    if not ok then return true end
    return got == true
end

--- The floor under the player: their capsule's bottom. nil when it cannot be read.
player_floor = function()
    local z
    pcall(function()
        local p = FindFirstOf("BP_LibrarianCharacter_C")
        if not (p and p:IsValid()) then return end
        local l = p:K2_GetActorLocation()
        local hh = 90
        pcall(function() hh = p.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
        z = l.Z - hh
    end)
    return z
end

--- Whether off_case would find this book a floor, asked while it is still in its slot: nothing is
--- moved, logged or counted. A book with no floor is then never taken off its shelf at all.
function M.can_land(IA, book, case)
    local ok, moved = pcall(M.off_case, IA, book, case, nil, true)
    return ok and moved == true
end

function M.off_case(IA, book, case, from, dry)
    if not dry then M.still(book) end
    local ck
    pcall(function() ck = case:GetFullName() end)
    local e
    for _, c in ipairs(cases(IA)) do
        local k
        pcall(function() k = c.case:GetFullName() end)
        if k and k == ck then e = c; break end
    end
    if not e then return false, "bookcase not read" end
    -- where the book stood in its slot, read before it left: once out, the game may already be
    -- carrying it somewhere
    local here = from
    if not here then pcall(function() here = v3(book:K2_GetActorLocation()) end) end
    if not here or (here.X == 0 and here.Y == 0 and here.Z == 0) then return false, "book position unreadable" end
    local why
    -- Where a spilled book may land, in order:
    --   the floor the case stands on, traced down from the book's height (an ordinary shelf);
    --   the same floor traced from just over the case's base, with the way out from the face open
    --     at knee height: the 1D cabinet stands two storeys high and its top shelves face a gallery
    --     450 over its base, so a book off them falls past it to the floor below;
    --   that upper floor itself, only while the player is standing on it (their own floor within
    --     PLAYER_LEVEL of it): it may be a level the player has not reached, and a book left there
    --     could not be fetched.
    local function try(side, floor_z, low)
        local f = e.front or 1
        local es = setmetatable({ front = f * side, floor_z = floor_z, low_start = low }, { __index = e })
        local spot, w = M.floor_spot(IA, book, es, here)
        local upper
        if spot then
            spot.spread = true
            spot.dry = dry
            if floor_z then spot.need_flat = UPPER_FLAT end
            if M.move(IA, book, spot, "spilled") then
                if not dry and M.last_pose then M.pin(IA, book, M.last_pose.loc, M.last_pose.rot) end
                return true
            end
            w = "no bare floor"
            upper = M.last_first_z
        end
        why = (why and (why .. "; ") or "") .. ((side == 1) and "front" or "back")
            .. (floor_z and (" at %.0f up"):format(floor_z - e.floor_z) or "") .. (low and " from below" or "")
            .. ": " .. tostring(w)
        return false, upper
    end
    local uppers = {}
    for _, side in ipairs({ 1, -1 }) do
        local ok, up = try(side, nil, false)
        if ok then return true end
        if up and up > e.floor_z + GROUND_ABOVE_MAX and up < here.Z and here.Z - up <= UPPER_REACH then
            uppers[#uppers + 1] = { side = side, z = up }
        end
    end
    if here.Z > e.floor_z + LOW_START then
        for _, side in ipairs({ 1, -1 }) do
            if try(side, nil, true) then return true end
        end
    end
    local pf = player_floor()
    for _, u in ipairs(uppers) do
        if pf and math.abs(pf - u.z) <= PLAYER_LEVEL then
            if try(u.side, u.z, false) then return true end
        else
            why = why .. ("; not the gallery %.0f up: the player is not on it"):format(u.z - e.floor_z)
        end
    end
    return false, why
end

-- ----------------------------------------------------------------------------
-- Holding a laid book still
-- ----------------------------------------------------------------------------
-- The game goes on moving a book after it leaves a slot: books Scramble Shelf had put on a shelf
-- were measured flying back to it (220 up, inside the face) or across the room (826 away) a moment
-- after they were laid on the floor. Its movement timelines are stopped before it is laid, and for
-- PIN_TICKS after, a book that moved is put back where it was laid. The hold lets go as soon as the
-- book is the player's again: owned (in the hands), on a shelf, flying to one (a skill or the
-- player's placing, started after the lay), or the player standing on or against it.
local MOTIONS = { "CloseUp", "GoToPath", "BezierCurveMove", "ToCenterPoint", "RotateFromCenter", "ToBookCase" }
local PIN_TICKS = 32          -- ticks of the shelf traps' clock (a quarter second each): 8 s
local PIN_SLACK = 1.5         -- moved further than this, it is put back
local PIN_CLOSE = 45.0        -- the player this close: whatever moves it is the player's doing
M.pins = {}                   -- book full name -> { book, loc, rot, left, moved, maxd, epoch }

--- Stop the game's own motion of a book and turn its physics off. Returns the motions that were running.
function M.still(book)
    local stopped = {}
    for _, n in ipairs(MOTIONS) do
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

--- Hold a book where it was just laid (loc, rot) for PIN_TICKS.
function M.pin(IA, book, loc, rot)
    local key
    pcall(function() key = book:GetFullName() end)
    M.pins[key or tostring(book)] = { book = book, loc = { X = loc.X, Y = loc.Y, Z = loc.Z },
        rot = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }, left = PIN_TICKS, moved = 0, maxd = 0,
        epoch = IA._world_epoch or 0 }
end

--- A held book was moved on purpose: its hold follows it to the new pose and keeps its time left.
function M.repin(book, loc, rot)
    local key
    pcall(function() key = book:GetFullName() end)
    local pin = M.pins[key or tostring(book)]
    if not pin then return false end
    pin.loc = { X = loc.X, Y = loc.Y, Z = loc.Z }
    pin.rot = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }
    return true
end

--- Whether a held book is the player's again, and why; nil while it is still held.
local function pin_released(IA, pin, p)
    local b = pin.book
    if (IA._world_epoch or 0) ~= pin.epoch or not (b and b:IsValid()) then return "gone" end
    local owned, attached = false, false
    pcall(function() owned = b.OwningCharacter ~= nil and b.OwningCharacter:IsValid() end)
    if owned then return "picked up" end
    pcall(function() attached = b.AttachedActor ~= nil and b.AttachedActor:IsValid() end)
    if attached then return "on a shelf" end
    for _, n in ipairs({ "BezierCurveMove", "ToBookCase" }) do
        local on = false
        pcall(function() on = b[n]:IsPlaying() == true end)
        if on then return "flying to a shelf" end
    end
    if p then
        local close = false
        pcall(function()
            local a, c = p:K2_GetActorLocation(), b:K2_GetActorLocation()
            close = math.sqrt((a.X - c.X) ^ 2 + (a.Y - c.Y) ^ 2) < PIN_CLOSE
        end)
        if close then return "the player is at it" end
    end
    return nil
end

--- One tick of every hold: a book that moved goes back where it was laid. p: the player, or nil.
--- Returns how many holds are still running.
function M.pin_tick(IA, p)
    local n = 0
    for k, pin in pairs(M.pins) do
        local why = pin_released(IA, pin, p)
        if not why then
            local b, l = pin.book, nil
            pcall(function() l = v3(b:K2_GetActorLocation()) end)
            local sim = false
            pcall(function() sim = b:IsSimulatePhysics() == true end)
            if l then
                local d = math.sqrt((l.X - pin.loc.X) ^ 2 + (l.Y - pin.loc.Y) ^ 2 + (l.Z - pin.loc.Z) ^ 2)
                if d > PIN_SLACK or sim then
                    local ran = M.still(b)
                    M.set_pose(IA, b, pin.loc, pin.rot)
                    pin.moved = pin.moved + 1
                    if d > pin.maxd then pin.maxd = d end
                    if #ran > 0 then pin.ran = table.concat(ran, ",") end
                end
            end
        end
        pin.left = pin.left - 1
        if why or pin.left <= 0 then
            M.pins[k] = nil
            if pin.moved > 0 or (why and why ~= "gone") then
                log(("hold: %s moved %d time(s), up to %.0f away, put back each time%s%s"):format(
                    (select(1, book_name(IA, pin.book))), pin.moved, pin.maxd,
                    pin.ran and ("; the game was running " .. pin.ran) or "",
                    why and ("; let go: " .. why) or ""))
            end
        else
            n = n + 1
        end
    end
    return n
end

function M.summary()
    local s = M.stats
    return ("moved %d; left alone: %d in a slot, %d with no clear landing, %d no floor; %d failed"):format(
        s.moved, s.shelved, s.blocked, s.no_floor, s.failed)
end

return M
