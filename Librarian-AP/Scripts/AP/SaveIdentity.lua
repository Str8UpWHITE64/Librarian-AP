--- AP/SaveIdentity.lua
--- Owns which game save slot belongs to this AP run, and whether the currently
--- loaded world is actually that run's save.
---
--- Background: the game replaced its single save file with numbered slot
--- directories (Map01/Save01..Save30, Map01/AutoSave01..03), and the old
--- SaveGameName redirect the mod used for per-seed isolation is now ignored.
--- AP runs therefore share slots with the player's vanilla saves, so the mod
--- has to claim one slot, remember it, and refuse to act when the loaded world
--- is something else.
---
--- Two failures are guarded here, and the second is the dangerous one:
---   * sending checks derived from a foreign save (corrupts a multiworld), and
---   * mirroring a foreign world INTO our slot (destroys the run's own save).
--- Both are gated on the same verdict, which defaults to "unknown" and must be
--- positively established.

local M = {}

-- Slots the mod may claim. Low slots are left to the player.
--
-- Claiming is occupancy-based (first_free_slot asks the game which slots hold a
-- save), not a counter, so two mod versions installed on one machine cannot hand
-- out the same slot. That only holds while this range and slot_data_path stay
-- identical across versions -- change one and a run claimed by the other version
-- becomes invisible to this one.
M.SLOT_MIN, M.SLOT_MAX = 20, 30

-- Verdicts. Only VERIFIED permits sending checks or writing our slot; UNKNOWN
-- is not a soft yes, it is a refusal that has not been explained yet.
M.UNKNOWN, M.VERIFIED, M.REJECTED = "unknown", "verified", "rejected"

M.verdict      = M.UNKNOWN
M.reason       = nil       -- human-readable, shown on screen when rejected
M.slot         = nil       -- game slot number claimed by this run
M.slot_source  = nil       -- "server" | "local" | "claimed"
M.override     = false     -- player lifted the block for this session
M.seed         = nil       -- AP seed, set at connect
M.ap_slot      = nil       -- AP slot number, set at connect
M.storage_key  = nil       -- server key holding the claimed slot
M.pending_fresh = false    -- New Game pressed; claim a slot once the world settles
-- This world came from New Game, so it has no history: every progress baseline is zero by
-- definition. Distinct from pending_fresh, which the slot claim clears within a second or two --
-- too early to gate reads that wait on the player moving. Cleared when a save is loaded.
M.fresh_world = false
M.title_preapply = false   -- warding the title-behind world is worth doing this run
M.stored_fp    = nil       -- layout hash recorded at this run's last save
M.fp_checked   = false     -- layout compared for the current world already
M.autoload_done = false    -- this run's save was already auto-loaded this session
M.autonew_done = false     -- New Game was already pressed for this run this session
-- The server's answer about this run's slot has arrived. Until it does, M.slot holds at most the
-- local fallback, so "no slot" does not yet mean "no save" -- and auto-New-Game must not act on it.
M.slot_resolved = false
M.start_enabled = false    -- the title gating's own verdict on New Game; auto-New-Game defers to it
M.mirror_pending = nil     -- a save happened; copy the world into our slot
M.mirroring    = false     -- a mirror write is in flight; ignore its own hook echo
M.disabled     = false     -- player chose vanilla; passive until the next connect

--- A fresh run is the one case identity is established by causation rather than
--- evidence: the player started this world from New Game while connected, so it
--- is this run's world by construction. Every other path has to prove it.
function M.mark_fresh_verified()
    M.verdict, M.reason = M.VERIFIED, nil
end

--- A verdict describes ONE world, not the session. Every level load replaces the
--- world, so the previous judgement is void -- without this, verifying the run's
--- own save would vouch for whatever the player loaded next. The slot record
--- survives; only the judgement is cleared.
function M.reset_world()
    if M.verdict ~= M.UNKNOWN then
        M.verdict, M.reason = M.UNKNOWN, nil
    end
    M.fp_checked = false
end

-- ---------------------------------------------------------------------------
-- Slot paths
-- ---------------------------------------------------------------------------

--- Slot metadata path as the game names it, e.g. "Map01/Save20/SlotData".
--- DoesSaveGameExist takes this form, not a filesystem path.
local function slot_data_path(n, is_auto)
    return ("Map01/%s%02d/SlotData"):format(is_auto and "AutoSave" or "Save", n)
end
M.slot_data_path = slot_data_path

local function statics()
    local s = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if s and s:IsValid() then return s end
    return nil
end

--- Whether a slot holds a save. Returns nil (not false) when the check itself
--- could not run, so callers can tell "empty" apart from "cannot tell" -- the
--- difference matters before claiming a slot.
function M.slot_exists(n, is_auto)
    local gs = statics()
    if not gs then return nil end
    local ok, res = pcall(function()
        return gs:DoesSaveGameExist(slot_data_path(n, is_auto), 0)
    end)
    if not ok then return nil end
    return res and true or false
end

--- Lowest unoccupied slot in our range, or nil if the range is full or the
--- occupancy check failed. Never returns a slot we could not verify as empty.
function M.first_free_slot()
    for n = M.SLOT_MIN, M.SLOT_MAX do
        if M.slot_exists(n, false) == false then return n end
    end
    return nil
end

--- Does ANY save exist? Replaces the old flat-file test behind the title
--- buttons, which looked for a file the game no longer writes and so always
--- reported "no save" -- disabling Continue even for vanilla players.
function M.any_save_exists()
    for n = 1, M.SLOT_MAX do
        if M.slot_exists(n, false) then return true end
    end
    for n = 1, 3 do
        if M.slot_exists(n, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Record store
-- ---------------------------------------------------------------------------
-- The slot record lives in two places because neither covers both cases: the
-- AP server copy survives a reinstall or a new machine but needs a connection,
-- and the local copy is readable at the title before any connection exists
-- (which is when the slot list is drawn). Server wins on conflict.

--- Sits in Saved/ next to SaveGames, never inside it: a record kept alongside
--- the saves would travel with a copied save and vouch for the wrong world.
--- Saved/ already exists, so no directory has to be created.
local function local_path()
    local appdata = os.getenv("LOCALAPPDATA")
    if not appdata or appdata == "" then return nil end
    return appdata .. "\\Librarian\\Saved\\LibrarianAP_slots.txt"
end

--- "<seed>|<ap_slot>" -- a seed alone is not unique because one multiworld has
--- several players, each needing their own game slot.
local function record_key(seed, ap_slot)
    return ("%s|%s"):format(tostring(seed or "?"), tostring(ap_slot or "?"))
end
M.record_key = record_key

--- Flat "key=slot" lines. Deliberately not JSON: this is read at the title with
--- no connection and must survive a partial write, so a corrupt line should
--- cost one record rather than the file.
function M.read_local(seed, ap_slot)
    local p = local_path()
    if not p then return nil end
    local want = record_key(seed, ap_slot)
    local f = io.open(p, "r")
    if not f then return nil end
    local found
    pcall(function()
        for line in f:lines() do
            -- "slot,hNNN" is home-keyed. "slot,NNN" is the older position-keyed hash and is
            -- discarded, not compared: comparing bases would reject every run already on disk.
            -- Those re-record a home-keyed hash at their next save.
            local k, v, fp = line:match("^(.-)=(%d+),h(%d+)$")
            if not k then
                local lk, lv = line:match("^(.-)=(%d+),%d+$")
                if lk then k, v, fp = lk, lv, nil end
            end
            if not k then k, v = line:match("^(.-)=(%d+)$") end
            if k == want then
                found = tonumber(v)
                M.stored_fp = fp and tonumber(fp) or nil
            end
        end
    end)
    pcall(function() f:close() end)
    return found
end

--- Called whenever the game saves: a save captures the world at that instant,
--- so the layout recorded here is exactly what reloading that save reproduces.
--- That is what makes the later comparison an exact match rather than a guess.
function M.record_layout()
    local fp, sample = M.fingerprint()
    if not fp then return nil end
    M.stored_fp = fp
    if M.seed and M.ap_slot and M.slot then
        M.write_local(M.seed, M.ap_slot, M.slot)
    end
    return fp, sample
end

--- Rewrites the file with this record replaced. Small enough that a full
--- rewrite beats an append-and-dedupe.
function M.write_local(seed, ap_slot, slot)
    local p = local_path()
    if not p then return false end

    local want, lines = record_key(seed, ap_slot), {}
    local f = io.open(p, "r")
    if f then
        pcall(function()
            for line in f:lines() do
                local k = line:match("^(.-)=%d+") 
                if k and k ~= want then lines[#lines + 1] = line end
            end
        end)
        pcall(function() f:close() end)
    end
    -- "h" marks the hash as home-keyed. A future change to the basis needs a new marker: a hash
    -- whose meaning changed silently is indistinguishable from a save that does not match.
    lines[#lines + 1] = M.stored_fp
        and ("%s=%d,h%d"):format(want, slot, M.stored_fp)
        or  ("%s=%d"):format(want, slot)

    local out = io.open(p, "w")
    if not out then return false end
    local ok = pcall(function()
        out:write(table.concat(lines, "\n"), "\n")
        out:flush()
    end)
    pcall(function() out:close() end)
    return ok
end

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------

--- Books the run has actually granted, as a set of "aidx|chapter" keys plus the
--- set of series names. BookSanity grants individual books and leaves the series
--- set empty by design, so both granularities are needed.
local function granted_sets(IA)
    local series = IA._series_unlocked or {}
    local books  = IA._books_unlocked or {}
    return series, books
end

--- Fingerprint of the world's book placement.
---
--- The game stores no seed; the per-run randomness is baked into where each book
--- belongs. The SPOTS are fixed across playthroughs and only the occupant varies,
--- so the identifying fact is which book belongs in which spot -- hence position
--- as the key, book as the value.
---
--- Keyed on SpawnTransform -- each book's own record of where it belongs -- not on
--- where it currently sits. Live positions changed whenever the player moved a book
--- or the mod evicted one, which refused runs their own save. Homes are serialized
--- and survive a quit, so every book counts and the sample never thins out.
---
--- AssetIdx 0 is excluded: that series is never randomised, so it agrees between any
--- two worlds. That exclusion also drops the inert copies in the resident test level,
--- which carry no ItemInfo and so read as 0.
---
--- Do NOT filter these by world. Which world holds the live books depends on how the
--- world was entered, and on a loaded save they are not the pawn's -- see
--- reconcile/eviction notes in main.lua.
---
--- Returns: hash, sample_count, unplaced_count
function M.fingerprint()
    -- Every nil return records WHY: a fingerprint that silently declines to exist reads exactly
    -- like one with nothing to say, and that ambiguity cost two wrong diagnoses.
    M.fp_why = nil
    -- Homes never move while a world is loaded, so one complete read is valid for that world's
    -- whole session. Without this the mirror recomputed it behind every game autosave -- a walk
    -- over ~6k actors, several times a minute during active shelving, felt as a periodic hitch.
    local IA = package.loaded["AP/ItemApply"]
    local epoch = IA and IA._world_epoch
    local cch = M._fp_cache
    if cch and epoch and cch.epoch == epoch then
        return cch.fp, cch.sample, cch.unplaced
    end
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then M.fp_why = "FindAllOf returned nothing"; return nil end
    local n = 0
    pcall(function() n = #books end)
    if n == 0 then M.fp_why = "no book actors"; return nil end

    -- Per-rejection tallies, so a zero-entry result says which filter ate everything rather than
    -- leaving it to be guessed at.
    local skip_info, skip_a0, skip_noxf = 0, 0, 0
    local entries, unplaced = {}, 0
    for i = 1, math.min(n, 8000) do
        local b = books[i]
        if b and b:IsValid() then
            do
                local info
                pcall(function() info = b.ItemInfo end)
                if not (info and info:IsValid()) then
                    skip_info = skip_info + 1
                else
                    local aidx, chap
                    pcall(function() aidx = info.AssetIdx end)
                    pcall(function() chap = info.Chapter end)
                    if not (aidx and aidx ~= 0 and chap) then
                        skip_a0 = skip_a0 + 1
                    else
                        local x, y, z
                        pcall(function()
                            local v = b.SpawnTransform and b.SpawnTransform.Translation
                            if v then x, y, z = v.X, v.Y, v.Z end
                        end)
                        if not x then skip_noxf = skip_noxf + 1 else
                            local px = math.floor(x + 0.5)
                            local py = math.floor(y + 0.5)
                            local pz = math.floor(z + 0.5)
                            if px == 0 and py == 0 and pz == 0 then
                                unplaced = unplaced + 1
                            else
                                entries[#entries + 1] =
                                    ("%d,%d,%d=%d|%d"):format(px, py, pz, aidx, chap)
                            end
                        end
                    end
                end
            end
        end
    end
    if #entries == 0 then
        M.fp_why = ("no usable books of %d (no-info=%d aidx0/no-chap=%d no-transform=%d origin=%d)")
            :format(n, skip_info, skip_a0, skip_noxf, unplaced)
        return nil
    end
    table.sort(entries)

    local h = 5381
    for i = 1, #entries do
        local s = entries[i]
        for c = 1, #s do
            h = (h * 33 + s:byte(c)) % 4294967296
        end
    end
    -- Cache only a COMPLETE read: a partial one (books still spawning, some at the origin) must
    -- not freeze for the session, or the frozen hash would never match a finished world.
    if epoch and unplaced == 0 and #entries >= 3000 then
        M._fp_cache = { epoch = epoch, fp = h, sample = #entries, unplaced = unplaced }
    end
    return h, #entries, unplaced
end

--- Does the loaded world contain progress this run could not have produced?
---
--- Locked books cannot be picked up, so anything shelved must come from a series
--- (or in BookSanity, a book) this run granted. A shelved item we never unlocked
--- is a contradiction rather than a coincidence -- and unlike the scattered-book
--- layout, this evidence grows as a run progresses, which is exactly where the
--- layout signal thins out.
---
--- Returns: n_impossible, n_shelved, example_name
function M.count_impossible(IA)
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return nil end
    local n = 0
    pcall(function() n = #books end)
    if n == 0 then return nil end

    local series_ok, books_ok = granted_sets(IA)
    local a2s = IA._asset_to_series or {}
    local book_mode = IA._book_sanity_enabled

    local n_bad, n_shelved, n_unresolved, example = 0, 0, 0, nil
    for i = 1, math.min(n, 8000) do
        local b = books[i]
        if b and b:IsValid() then
            local info
            pcall(function() info = b.ItemInfo end)
            if info and info:IsValid() then
                local attached = false
                pcall(function()
                    local p = b:GetAttachParentActor()
                    attached = (p and p:IsValid()) and true or false
                end)
                if attached then
                    n_shelved = n_shelved + 1
                    local aidx, chap
                    pcall(function() aidx = info.AssetIdx end)
                    pcall(function() chap = info.Chapter end)
                    local sname = aidx and a2s[aidx]
                    if not sname then
                        -- Cannot judge this one. Counted, because a world we
                        -- mostly cannot read must not pass for lack of evidence.
                        n_unresolved = n_unresolved + 1
                    else
                        local ok
                        if book_mode then
                            ok = (chap ~= nil) and books_ok[sname .. "|" .. chap] or false
                        else
                            ok = series_ok[sname] or false
                        end
                        if not ok then
                            n_bad = n_bad + 1
                            example = example or sname
                        end
                    end
                end
            end
        end
    end
    return n_bad, n_shelved, example, n_unresolved
end

--- Decide whether the loaded world belongs to this run. Called once the world is
--- populated and before anything is warded.
---
--- A fresh run is already VERIFIED by causation and is left alone. Everything
--- else must clear the impossibility test; a world with no shelved books yet
--- offers nothing to contradict, so it stays UNKNOWN rather than passing --
--- absence of evidence is not proof.
function M.evaluate()
    if M.verdict == M.VERIFIED then return M.verdict end

    -- A pending New Game is ours by construction, and saying so here rather than
    -- at claim time is what stops warding and the claim waiting on each other:
    -- the claim waits for the ward pass to drain, and warding waits for a
    -- verdict.
    if M.pending_fresh then
        M.verdict, M.reason = M.VERIFIED, nil
        return M.verdict
    end

    local IA = package.loaded["AP/ItemApply"]
    if not IA then return M.verdict end

    -- Layout first, once per world. The hash is over where books BELONG, which nothing in normal
    -- play changes, so a mismatch is real evidence rather than a stale reading.
    if not M.fp_checked and M.stored_fp then
        local fp, sample, unplaced = M.fingerprint()
        if fp then
            M.fp_checked = true
            -- sample is how many books went into the hash. It should be the same number every time
            -- for a given world; if it moves between a save and the next load, the hash cannot
            -- match whatever the homes are -- so it is the first thing to check when a run is
            -- refused its own save.
            M.last_fp = ("layout=%d stored=%d sample=%d unplaced=%d")
                :format(fp, M.stored_fp, sample or 0, unplaced or 0)
            if fp == M.stored_fp then
                M.verdict, M.reason = M.VERIFIED, nil
                return M.verdict
            end
            M.verdict = M.REJECTED
            M.reason = "book layout does not match this run's last save"
            return M.verdict
        end
    end

    local n_bad, n_shelved, example, n_unresolved = M.count_impossible(IA)
    if n_bad == nil then return M.verdict end   -- world not readable yet

    M.last_counts = ("shelved=%d impossible=%d unresolved=%d granted_series=%d granted_books=%d")
        :format(n_shelved, n_bad, n_unresolved,
                M.count_keys(IA._series_unlocked), M.count_keys(IA._books_unlocked))

    if n_bad > 0 then
        M.verdict = M.REJECTED
        M.reason = ("%d shelved item(s) this run never unlocked (e.g. %s)")
            :format(n_bad, tostring(example))
    elseif n_shelved > 0 and n_unresolved == 0 then
        M.verdict, M.reason = M.VERIFIED, nil
    end
    -- Otherwise stay UNKNOWN: either nothing is shelved yet, or too much of the
    -- world could not be read to call it either way. Refusing to decide is the
    -- safe answer -- a world we cannot read must not pass by default.
    return M.verdict
end

--- Size of a set-style table.
function M.count_keys(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Warding only makes sense in a world that belongs to this run. Applying it to
--- someone's vanilla save would hide their own books in their own game, so this
--- is a correctness gate before it is a performance one.
function M.may_ward()
    return M.verdict == M.VERIFIED
end

--- Checks may only be sent from a world proven to belong to this run. The
--- override is a deliberate escape hatch, but never for a contradiction --
--- that is evidence of the wrong world, not missing evidence.
function M.may_send_checks()
    if M.disabled then return false end
    if M.verdict == M.VERIFIED then return true end
    if M.override and M.verdict ~= M.REJECTED then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Write gate
-- ---------------------------------------------------------------------------

--- Every mod-issued save must pass this. The destination being right is the
--- easy half; the reason this is strict is the other direction -- writing an
--- unverified world into our own slot would overwrite the run with whatever
--- the player happened to load.
---
--- claim_target: set only while claiming a new slot, where the slot must be
--- empty rather than ours.
function M.can_force_save(claim_target)
    -- Writing this run's slot only makes sense while the run is live. A stale
    -- slot + verdict left over from an earlier connection would otherwise let
    -- the mirror keep writing after a disconnect, or during vanilla play.
    if M.disabled then return false, "mod passive (vanilla)" end
    local AC = package.loaded["AP/APClient"]
    if not (AC and AC._slot_connected) then return false, "not connected" end

    local IA = package.loaded["AP/ItemApply"]
    if not IA then return false, "ItemApply unavailable" end
    if not IA._gameplay_active then return false, "not in gameplay" end
    if not IA._apply_safe then return false, "world not settled" end
    if M.verdict ~= M.VERIFIED then return false, "identity " .. tostring(M.verdict) end
    if claim_target then
        if M.slot_exists(claim_target, false) ~= false then
            return false, "claim target not confirmed empty"
        end
    elseif not M.slot then
        return false, "no slot claimed"
    end

    -- Do not race the game's own write; the subsystem flags one in flight.
    local busy = false
    pcall(function()
        local ss = FindFirstOf("SaveSubsystem")
        if ss and ss:IsValid() then busy = ss.WaitingSave and true or false end
    end)
    if busy then return false, "save already in progress" end

    return true
end

--- One-line state summary for logs.
function M.describe()
    return ("slot=%s(%s) verdict=%s%s"):format(
        tostring(M.slot), tostring(M.slot_source), tostring(M.verdict),
        M.reason and (" reason=" .. M.reason) or "")
end

--- Cleared per connection; the slot is re-established from the server or the
--- local file, never carried over from a previous run.
function M.reset()
    M.verdict, M.reason = M.UNKNOWN, nil
    M.slot, M.slot_source = nil, nil
    M.override = false
    M.seed, M.ap_slot, M.storage_key = nil, nil, nil
    M.pending_fresh, M.title_preapply, M.fresh_world = false, false, false
    M.stored_fp, M.fp_checked, M.autoload_done = nil, false, false
    M.autonew_done, M.slot_resolved, M.start_enabled = false, false, false
    M.mirror_pending = nil
    -- Cleared here on purpose: a connection re-arms the mod even if the player
    -- had chosen vanilla earlier in the session. The vanilla path sets this
    -- again immediately after calling reset.
    M.disabled = false
end

return M
