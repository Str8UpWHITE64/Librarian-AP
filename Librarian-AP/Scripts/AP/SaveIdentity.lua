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
-- Set alongside pending_fresh, but outlives it: the slot claim clears pending_fresh within a
-- second or two, too early to gate reads that wait on the player moving. New Game has no history,
-- so its progress baselines must not read the previous session's save still in GameSaveData.
M.fresh_world  = false
M.title_preapply = false   -- warding the title-behind world is worth doing this run
M.stored_fp    = nil       -- layout hash recorded at this run's last save
M.stored_fp_kind = nil     -- "home" (current) or "legacy" (pre-1.1.2 position hash); nil = none
M.fp_checked   = false     -- layout compared for the current world already
M.autoload_done = false    -- this run's save was already auto-loaded this session
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
            -- Three forms: "slot,hNNN" home-keyed (current), "slot,NNN" legacy position hash,
            -- "slot" no hash. The kind decides how evaluate compares it.
            local k, v, fp = line:match("^(.-)=(%d+),h(%d+)$")
            local kind = "home"
            if not k then
                k, v, fp = line:match("^(.-)=(%d+),(%d+)$")
                kind = "legacy"
            end
            if not k then
                k, v = line:match("^(.-)=(%d+)$")
                fp, kind = nil, nil
            end
            if k == want then
                found = tonumber(v)
                M.stored_fp = fp and tonumber(fp) or nil
                M.stored_fp_kind = M.stored_fp and kind or nil
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
    M.stored_fp_kind = "home"
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
    -- Serialize the hash in the format its KIND says it is. This is called on a plain slot resync
    -- too (server slot != local), when stored_fp may still be a legacy value not yet upgraded --
    -- writing that with the home "h" marker would make the next load compare a home hash against a
    -- legacy number and falsely reject. "h" marks home-keyed; a legacy value keeps the bare form.
    -- (An older build does not match "slot,hNNN" as its "slot,NNN" hash, so it falls through to the
    -- impossibility check rather than wrongly rejecting -- a safe cross-version failure.)
    local suffix = ""
    if M.stored_fp then
        suffix = (M.stored_fp_kind == "legacy")
            and (",%d"):format(M.stored_fp)
            or  (",h%d"):format(M.stored_fp)
    end
    lines[#lines + 1] = ("%s=%d%s"):format(want, slot, suffix)

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

--- Fingerprint of the world's book placement, keyed on where each book BELONGS.
---
--- The game stores no seed; the per-run randomness is baked into where each book
--- belongs. The spots are fixed and only the occupant varies, so the identifying
--- fact is which book belongs in which spot -- position as the key, book as value.
---
--- Keyed on SpawnTransform, each book's own record of its home, not on where it
--- currently sits. Live positions made the old hash fragile: a crash (or the
--- player simply moving books) changed the layout enough to fail the check and
--- lock the run out of its own save. Homes are serialized and do not move, so a
--- save matches itself regardless of what happened to the loose books. Every book
--- counts now, not only loose ones.
---
--- AssetIdx 0 is excluded: the game never randomises that series, so it agrees
--- between any two worlds. An unfilled home reads as the origin and is unplaced.
---
--- Returns: hash, sample_count, unplaced_count
function M.fingerprint()
    M.fp_why = nil
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then M.fp_why = "FindAllOf returned nothing"; return nil end
    local n = 0
    pcall(function() n = #books end)
    if n == 0 then M.fp_why = "no book actors"; return nil end

    local skip_info, skip_a0, skip_noxf = 0, 0, 0
    local entries, unplaced = {}, 0
    for i = 1, math.min(n, 8000) do
        local b = books[i]
        if b and b:IsValid() then
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
                    if not x then
                        skip_noxf = skip_noxf + 1
                    else
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
    return h, #entries, unplaced
end

--- The pre-1.1.2 fingerprint: keyed on live LOOSE-book positions. Kept only so an
--- existing save recorded under it can be recognised once and upgraded to a
--- home-keyed hash -- see M.evaluate. Never recorded going forward.
---
--- Returns: hash, sample_count, unplaced_count
function M.fingerprint_legacy()
    local books = FindAllOf("BP_GrabbingBook_C")
    if not books then return nil end
    local n = 0
    pcall(function() n = #books end)
    if n == 0 then return nil end

    local entries, unplaced = {}, 0
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
                local aidx, chap
                pcall(function() aidx = info.AssetIdx end)
                pcall(function() chap = info.Chapter end)
                if not attached and aidx and aidx ~= 0 and chap then
                    local x, y, z
                    pcall(function()
                        local loc = b:K2_GetActorLocation()
                        x, y, z = loc.X, loc.Y, loc.Z
                    end)
                    if x then
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
    if #entries == 0 then return nil end
    table.sort(entries)

    local h = 5381
    for i = 1, #entries do
        local s = entries[i]
        for c = 1, #s do
            h = (h * 33 + s:byte(c)) % 4294967296
        end
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

    -- Layout check, once per world. The hash is over where books BELONG, which nothing in normal
    -- play changes, so a match is durable rather than a snapshot that drifts as books are moved.
    if not M.fp_checked then
        if M.stored_fp_kind == "home" then
            local fp, sample = M.fingerprint()
            if fp then
                M.fp_checked = true
                M.last_fp = ("layout=%d stored=%d(home) sample=%d"):format(fp, M.stored_fp, sample or 0)
                if fp == M.stored_fp then
                    M.verdict, M.reason = M.VERIFIED, nil
                else
                    M.verdict = M.REJECTED
                    M.reason = "book layout does not match this run's last save"
                end
                return M.verdict
            end

        elseif M.stored_fp_kind == "legacy" then
            -- A save recorded under the old position hash. Compare against it once. A player who
            -- did NOT crash still has their loose books where they left them, so it matches --
            -- verify them and upgrade the record to a home hash so future loads are crash-proof.
            -- A crash moved the books, so it will not match; those runs are REJECTED, and the
            -- documented recovery is to delete the hash line, which routes through the no-record
            -- path below.
            local legacy = M.fingerprint_legacy()
            if legacy then
                M.fp_checked = true
                M.last_fp = ("layout=%d stored=%d(legacy) sample=?"):format(legacy, M.stored_fp)
                if legacy == M.stored_fp then
                    M.verdict, M.reason = M.VERIFIED, nil
                    M.record_layout()   -- upgrade: write a home-keyed hash for next time
                else
                    M.verdict = M.REJECTED
                    M.reason = "book layout does not match this run's last save"
                end
                return M.verdict
            end

        else
            -- No recorded layout for this run: a save from before the fingerprint existed, or one
            -- whose hash was deleted to recover from a bad reject. Adopt the current world as this
            -- run's layout and verify -- unless the impossibility check finds a book shelved that
            -- the run never unlocked, which is a real contradiction and rejects. This is the one
            -- place a load is trusted on sight, so it is gated on that check.
            local n_bad, _, example, n_unresolved = M.count_impossible(IA)
            if n_bad == nil then return M.verdict end   -- world not readable yet; retry
            if n_bad > 0 then
                M.fp_checked = true
                M.verdict = M.REJECTED
                M.reason = ("a shelved book was never unlocked in this run (e.g. %s)")
                    :format(tostring(example))
                return M.verdict
            end
            -- Wait for the world to be fully readable before adopting -- a partial read is not
            -- proof of anything. This only defers past the load, not a lasting unverified state.
            if (n_unresolved or 0) > 0 then return M.verdict end
            M.fp_checked = true
            M.verdict, M.reason = M.VERIFIED, nil
            M.record_layout()
            M.last_fp = ("adopted current layout (no prior record); stored=%s"):format(tostring(M.stored_fp))
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
    M.stored_fp, M.stored_fp_kind, M.fp_checked, M.autoload_done = nil, nil, false, false
    M.mirror_pending = nil
    -- Cleared here on purpose: a connection re-arms the mod even if the player
    -- had chosen vanilla earlier in the session. The vanilla path sets this
    -- again immediately after calling reset.
    M.disabled = false
end

return M
