"""
Librarian: Tidy Up the Arcane Library — Archipelago World implementation.

Wires Items + Locations + Options into the AP machinery and produces a
solvable, playable seed.

Per-seed orderings are randomized in generate_early():
  - series_order[i]       = series name unlocked at position i in the
                            global series queue. Each Progressive Series
                            Unlock advances the queue by `series_per_unlock`
                            (default 5).
  - shelf_order[s][i]     = bookcase index opened by the (i+1)-th
                            Progressive Shelf Unlock (s) item.

Section access is implicit: a section is reachable as soon as the player
holds ≥1 Progressive Shelf Unlock for it. Each subsequent unlock reveals
the next bookcase within that section.

Starting state (precollected):
  - 1× Progressive Shelf Unlock (starting_section) → first bookcase visible
  - 2× Progressive Series Unlock                   → 10 starting series

Solvability is enforced by access rules; AP's generator places progression
items in spheres that satisfy the rules.
"""

from typing import Any
import math

from BaseClasses import MultiWorld, Region, Tutorial, ItemClassification
from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule, add_rule

from . import data
from .Items import (
    LibrarianItem,
    LibrarianItemCategory,
    item_dictionary,
    item_name_groups,
    ITEM_QUANTITIES,
    ITEM_ID_BASE,
    _filler_items,
)
from .Locations import (
    LibrarianLocation,
    LibrarianLocationCategory,
    location_name_groups,
    total_real_locations,
    section_completion_name,
    levelup_name,
    chest_open_name,
    MILESTONE_THRESHOLDS,
    _row_locations,
    _section_locations,
    _floor_locations,
    _levelup_locations,
    _chest_locations,
    _milestone_locations,
    _goal_locations,
)
from .Options import LibrarianOptions

# Item names used as constants below (avoids typos)
ITEM_PROG_SERIES  = "Progressive Series Unlock"


def shelf_unlock_name(section_id: str) -> str:
    return f"Progressive Shelf Unlock ({section_id})"


def _compute_shelf_req(section, cells_per_case: int) -> dict[tuple[str, str], int]:
    """Compute shelf_req for every series in a section.

    Strategy:
      - If the section is uniform-volume (all series have the same volume
        count): spread series evenly across bookcase_count cases.
      - If mixed volume AND the per-volume cases fit into bookcase_count:
        smaller-vol cases unlock first. Each volume group occupies
        ceil(group_count / cells_per_case) cases, ordered ascending.
      - Otherwise (e.g. 1-case sections that mix vols): all series get
        shelf_req=1, since there's only one case to unlock.
    """
    out: dict[tuple[str, str], int] = {}
    by_vol: dict[int, list] = {}
    for s in section.series:
        by_vol.setdefault(s.volumes, []).append(s)

    # Uniform: simple even spread
    if len(by_vol) == 1:
        bs = max(1, math.ceil(section.shelf_count / section.bookcase_count))
        for i, s in enumerate(section.series):
            out[(section.id, s.name)] = (i // bs) + 1
        return out

    # Mixed: see if per-volume groups fit the available cases.
    sorted_vols = sorted(by_vol.keys())
    cases_per_group = [
        (v, math.ceil(len(by_vol[v]) / cells_per_case)) for v in sorted_vols
    ]
    total_cases = sum(c for _, c in cases_per_group)

    if total_cases <= section.bookcase_count:
        case_idx = 1
        for v, n_cases in cases_per_group:
            series_list = by_vol[v]
            for i, s in enumerate(series_list):
                out[(section.id, s.name)] = case_idx + (i // cells_per_case)
            case_idx += n_cases
        return out

    # Doesn't fit (e.g. single-case section with mixed vols). Single case
    # holds everything → shelf_req=1 for all.
    for s in section.series:
        out[(section.id, s.name)] = 1
    return out

GOAL_LOCATION_NAME = "Library Tidied"
VICTORY_ITEM_NAME = "Victory"


# ============================================================================
# WebWorld (display info on the AP web frontend)
# ============================================================================

class LibrarianWeb(WebWorld):
    theme = "stone"
    setup_en = Tutorial(
        "Multiworld Setup Guide",
        "A guide to setting up the Archipelago Librarian randomizer on your computer.",
        "English",
        "setup_en.md",
        "setup/en",
        ["Str8UpWHITE64"],
    )
    game_info_languages = ["en"]
    tutorials = [setup_en]


# ============================================================================
# LibrarianWorld
# ============================================================================

class LibrarianWorld(World):
    """
    Librarian: Tidy Up the Arcane Library!  Sort 3072 books across 400 shelves
    in 31 themed sections, gated by AP-delivered series/shelf unlocks. Major
    Magic skills are progression items (gating level-ups). Minor Magic
    abilities (Jump/Run/Bag/Bag2) are NOT AP items — the player gets each
    ability natively by opening its chest; the chest opening is what fires
    the AP location check.
    """

    game = "Librarian Tidy Up the Arcane Library"
    options_dataclass = LibrarianOptions
    options: LibrarianOptions
    web = LibrarianWeb()
    topology_present = True
    required_client_version = (0, 5, 0)

    item_name_to_id = LibrarianItem.get_name_to_id()
    location_name_to_id = LibrarianLocation.get_name_to_id()
    item_name_groups = item_name_groups
    location_name_groups = location_name_groups

    # Per-seed state populated in generate_early().
    series_order: list[str]
    shelf_order: dict[str, list[int]]
    starting_section: str
    starting_series: list[str]
    series_req: dict[str, int]
    shelf_req: dict[tuple[str, str], int]

    def __init__(self, multiworld: MultiWorld, player: int):
        super().__init__(multiworld, player)
        self.series_order = []
        self.shelf_order = {}
        self.starting_section = ""
        self.starting_series = []
        self.series_req = {}
        self.shelf_req = {}

    # Sections in the active goal scope. Floor goals filter the pool to
    # one floor; everything else (full / custom) keeps all 31 sections.
    # If we're in UT regen mode, the goal comes from passthrough slot_data
    # (options are defaults at that point).
    @property
    def active_sections(self) -> list[data.Section]:
        pt = getattr(self.multiworld, "re_gen_passthrough", {}).get(
            "Librarian Tidy Up the Arcane Library", {}
        )
        if pt and "goal" in pt:
            v = pt["goal"]
        else:
            v = self.options.goal.value
        if v == self.options.goal.option_floor_1:
            return [s for s in data.SECTIONS if s.floor == 1]
        if v == self.options.goal.option_floor_2:
            return [s for s in data.SECTIONS if s.floor == 2]
        return list(data.SECTIONS)

    @property
    def active_section_ids(self) -> set[str]:
        return {s.id for s in self.active_sections}

    @property
    def max_reachable_rows(self) -> int:
        """Upper bound on rows finishable in this seed. Drives the
        level-up + milestone filter in create_regions:
        - Floor goals: rows on that floor only.
        - Custom goal: the player's chosen row threshold (player can play
          past it in-game, but AP only tracks levels/milestones up to
          that point).
        - Full goal: all 400 rows."""
        # UT passthrough: respect goal from slot_data (options are defaults
        # during UT regen; passthrough has the real value).
        pt = self._ut_passthrough()
        if pt:
            goal_v = pt.get("goal")
            custom = pt.get("custom_goal_row_count")
            if goal_v == self.options.goal.option_custom and custom is not None:
                return int(custom)
            if goal_v == self.options.goal.option_floor_1:
                return sum(s.shelf_count for s in data.SECTIONS if s.floor == 1)
            if goal_v == self.options.goal.option_floor_2:
                return sum(s.shelf_count for s in data.SECTIONS if s.floor == 2)
            if goal_v == self.options.goal.option_full:
                return sum(s.shelf_count for s in data.SECTIONS)
        v = self.options.goal.value
        if v == self.options.goal.option_custom:
            return self.options.custom_goal_row_count.value
        return sum(s.shelf_count for s in self.active_sections)

    # ------------------------------------------------------------------
    # Universal Tracker integration
    # ------------------------------------------------------------------

    # Lets UT generate this world without a YAML; the slot_data passthrough
    # carries everything needed to reconstruct the seed's state.
    ut_can_gen_without_yaml = True

    def _ut_passthrough(self) -> dict:
        """Return the re_gen_passthrough dict for this game (or {} if not
        in UT regen mode). Centralised so callers don't repeat the lookup."""
        return getattr(self.multiworld, "re_gen_passthrough", {}).get(
            "Librarian Tidy Up the Arcane Library", {}
        )

    def interpret_slot_data(self, slot_data: dict) -> dict:
        """UT hook. UT invokes this with server slot_data after its first
        (defaults-only) generation. Returning a dict triggers UT to
        regenerate the world with that dict stored in
        ``multiworld.re_gen_passthrough[<game name>]`` — generate_early
        below reads it and rebuilds state to match the real seed."""
        return slot_data

    # ------------------------------------------------------------------
    # generate_early — per-seed orderings + starting state
    # ------------------------------------------------------------------

    def generate_early(self) -> None:
        rng = self.random

        # Universal Tracker regen path: reconstruct the seed's state from
        # slot_data (stored in re_gen_passthrough by interpret_slot_data)
        # rather than randomizing. Without this, UT's logic doesn't match
        # the actual seed and reachability info is wrong.
        pt = self._ut_passthrough()
        if pt:
            self.starting_section = pt.get("starting_section", "")
            self.starting_series = list(pt.get("starting_series", []))
            self.series_order = list(pt.get("series_order", []))
            self.shelf_order = {sid: list(v) for sid, v in pt.get("shelf_order", {}).items()}
            CELLS_PER_CASE = 4
            for section in self.active_sections:
                self.shelf_req.update(_compute_shelf_req(section, CELLS_PER_CASE))
            per_unlock = pt.get("series_per_unlock", self.options.series_per_unlock.value)
            self.series_req = {
                name: math.ceil((i + 1) / per_unlock)
                for i, name in enumerate(self.series_order)
            }
            return

        # Use active_sections (filtered by goal) so floor goals stay
        # entirely within the chosen floor.
        active = self.active_sections

        # 1. Pick a random starting section (purely cosmetic for slot_data /
        #    Lua starting-state; access rules don't reference an order).
        section_ids = [s.id for s in active]
        rng.shuffle(section_ids)
        self.starting_section = section_ids[0]

        # 2. Per-section bookcase order — ordinal for now; can randomize later.
        for section in active:
            self.shelf_order[section.id] = list(range(section.bookcase_count))

        # 3. shelf_req must come BEFORE the starting-series guarantee, since
        # we use it to identify which series live in the first VISIBLE case
        # (Lua sorts cases by vol-tier ascending; series with shelf_req=1 are
        # exactly those in the smallest unlocked case).
        #
        # For mixed-vol sections (e.g. 1M with 2×4x5 + 3×plain), smaller-vol
        # cases unlock first — so a 10-vol series in 1M needs ≥3 unlocks
        # before it's reachable. The Lua side mirrors this ordering.
        CELLS_PER_CASE = 4  # standard BookCase capacity (4 series per case)
        for section in active:
            self.shelf_req.update(_compute_shelf_req(section, CELLS_PER_CASE))

        # 4. Build series order with the "≥1 fits starting bookcase" guarantee.
        # The guaranteed series MUST live in the section's first VISIBLE case
        # (shelf_req=1) so the player can actually place it with their single
        # starting Progressive Shelf Unlock. data.py declaration order is
        # AssetIdx-ascending, which puts large-vol series first for sections
        # like 2M — but Lua reveals 4x5 cases first, so we filter by shelf_req.
        starting_section_obj = data.SECTIONS_BY_ID[self.starting_section]
        starting_bookcase_series = [
            s.name for s in starting_section_obj.series
            if self.shelf_req[(self.starting_section, s.name)] == 1
        ]
        if not starting_bookcase_series:
            # Defensive fallback: shouldn't happen, but if it did pick anything.
            starting_bookcase_series = [s.name for s in starting_section_obj.series]

        starting_count = self.options.starting_series_count.value
        guaranteed = rng.choice(starting_bookcase_series)

        all_series = [s.name for sec in active for s in sec.series]
        other_pool = [n for n in all_series if n != guaranteed]
        rng.shuffle(other_pool)

        # First `starting_count - 1` from the shuffled pool, then guaranteed
        # inserted at a random position within the starting set.
        starting = other_pool[: starting_count - 1] + [guaranteed]
        rng.shuffle(starting)
        rest = other_pool[starting_count - 1 :]

        self.starting_series = starting
        self.series_order = starting + rest

        # 5. series_req depends on series_order, so it goes last.
        per_unlock = self.options.series_per_unlock.value
        self.series_req = {
            name: math.ceil((i + 1) / per_unlock)
            for i, name in enumerate(self.series_order)
        }

    # ------------------------------------------------------------------
    # create_regions — Menu → Library → 31 section regions
    # ------------------------------------------------------------------

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        library = Region("Library", self.player, self.multiworld)
        self.multiworld.regions.extend([menu, library])
        menu.connect(library, "Enter Library")

        active_ids = self.active_section_ids

        # Per-section regions — only for active sections (floor goals
        # exclude the other floor entirely from the location pool).
        for section in self.active_sections:
            region = Region(f"Section {section.id}", self.player, self.multiworld)
            self.multiworld.regions.append(region)
            library.connect(region, f"Open Section {section.id}")

            # Row locations for this section
            for series in section.series:
                loc_name = f"Shelf: {section.id} - {series.name}"
                loc = LibrarianLocation(
                    self.player, loc_name,
                    self.location_name_to_id.get(loc_name), region,
                )
                region.locations.append(loc)

            # Section completion location
            sec_name = section_completion_name(section.id)
            sec_loc = LibrarianLocation(
                self.player, sec_name,
                self.location_name_to_id.get(sec_name), region,
            )
            region.locations.append(sec_loc)

        # Floor completions: only include the floor(s) covered by the goal.
        active_floors = {s.floor for s in self.active_sections}
        active_floor_locs = [
            loc for loc in _floor_locations
            if (loc.name == "Floor 1 Complete" and 1 in active_floors)
            or (loc.name == "Floor 2 Complete" and 2 in active_floors)
        ]

        # Level-ups: drop any whose XP_CURVE threshold exceeds what the
        # active pool can reach. (Floor goals cap rows < 400; an unreachable
        # location fails AP's accessibility check during generation.)
        max_rows = self.max_reachable_rows
        active_levelup_locs = [
            loc for idx, loc in enumerate(_levelup_locations)
            if data.XP_CURVE[idx] <= max_rows
        ]

        # Milestones: same idea, but threshold is in books. The access
        # rule converts to feasible_rows via ceil(thresh / 8).
        active_milestone_locs = [
            loc for idx, loc in enumerate(_milestone_locations)
            if math.ceil(MILESTONE_THRESHOLDS[idx] / 8) <= max_rows
        ]

        # Library-attached: floor completions, level-ups, chest openings, milestones.
        for category in (active_floor_locs, active_levelup_locs,
                         _chest_locations, active_milestone_locs):
            for loc_data in category:
                loc = LibrarianLocation(
                    self.player, loc_data.name,
                    self.location_name_to_id.get(loc_data.name), library,
                )
                library.locations.append(loc)

        # Goal event location (no AP id; carries the Victory event item)
        goal_loc = LibrarianLocation(self.player, GOAL_LOCATION_NAME, None, library)
        library.locations.append(goal_loc)
        goal_loc.place_locked_item(LibrarianItem(
            VICTORY_ITEM_NAME, ItemClassification.progression, None, self.player
        ))

    # ------------------------------------------------------------------
    # create_items — pool sized to fit real-locations, with precollect
    # ------------------------------------------------------------------

    def create_items(self) -> None:
        # Compute the location target from the actual regions we created
        # (which honours active_sections), not the static total.
        target = sum(len(r.locations) for r in self.multiworld.regions
                     if r.player == self.player)
        # Subtract the goal event-location (no AP item, no pool slot).
        target -= 1

        active_ids = self.active_section_ids
        active_series_count = sum(len(s.series) for s in self.active_sections)
        per_unlock = self.options.series_per_unlock.value

        # Precollect: 1 starting-section shelf unlock + N starting-series worth of unlocks.
        starting_count = self.options.starting_series_count.value
        starting_unlock_count = math.ceil(starting_count / per_unlock)

        precollect_names: list[str] = [
            shelf_unlock_name(self.starting_section),
        ]
        precollect_names.extend([ITEM_PROG_SERIES] * starting_unlock_count)

        for name in precollect_names:
            self.multiworld.push_precollected(self.create_item(name))

        # Build per-name quantities, filtered to active sections / series.
        # Shelf unlocks: only for active sections.
        # Series unlocks: scaled to cover the active series count.
        quantities: dict[str, int] = {}
        for name, qty in ITEM_QUANTITIES.items():
            if name == ITEM_PROG_SERIES:
                # Need ceil(active_series_count / per_unlock) Progressive
                # Series Unlocks to cover all series in the active scope.
                quantities[name] = math.ceil(active_series_count / per_unlock)
            elif name.startswith("Progressive Shelf Unlock ("):
                # Match on section id; drop if not in active set.
                section_id = name[len("Progressive Shelf Unlock ("):-1]
                if section_id in active_ids:
                    quantities[name] = qty
                # else: skip
            else:
                quantities[name] = qty

        # Subtract precollected.
        for name in precollect_names:
            quantities[name] = max(0, quantities.get(name, 0) - 1)

        # Pool-overshoot guard. Happens with combinations like
        # series_per_unlock=2 + starting_count near max + custom goal with
        # low row_count (drops level-up + milestone locations from target
        # while pool stays full).
        #
        # Skills are always preserved — players expect a full set of skill
        # items even if the rest of the world is constrained. The relief
        # valve instead is to lift extra Series Unlock items into starting
        # inventory: that strictly improves the player's starting state
        # (more series unlocked from the outset) while shrinking the
        # in-pool item count by the same number. No filler is added until
        # the static pool fits.
        total = sum(quantities.values())
        if total > target:
            excess = total - target
            series_qty = quantities.get(ITEM_PROG_SERIES, 0)
            lift = min(series_qty, excess)
            if lift > 0:
                quantities[ITEM_PROG_SERIES] = series_qty - lift
                for _ in range(lift):
                    self.multiworld.push_precollected(
                        self.create_item(ITEM_PROG_SERIES))
                excess -= lift
                extra_series = lift * self.options.series_per_unlock.value
                print(f"[Librarian] pool-overshoot guard lifted {lift} "
                      f"Series Unlock(s) to starting inventory "
                      f"(~{extra_series} extra series unlocked at start) "
                      f"so all skills can stay in the pool.")
            if excess > 0:
                raise ValueError(
                    f"Pool overshoots target locations ({target}) by {excess} "
                    f"even after lifting all in-pool Series Unlocks to "
                    f"starting inventory. This config is fundamentally "
                    f"impossible — use a less restrictive goal."
                )

        pool_items: list[LibrarianItem] = []
        for name, qty in quantities.items():
            for _ in range(qty):
                pool_items.append(self.create_item(name))

        # Pad with filler to fill remaining real-location slots.
        # (Pool size is now guaranteed <= target by the overshoot guard above.)
        filler_needed = target - len(pool_items)
        if filler_needed > 0:
            for i in range(filler_needed):
                f = _filler_items[i % len(_filler_items)]
                pool_items.append(self.create_item(f.name))

        self.multiworld.itempool.extend(pool_items)

    def create_item(self, name: str) -> LibrarianItem:
        if name == VICTORY_ITEM_NAME:
            return LibrarianItem(name, ItemClassification.progression, None, self.player)
        item_data = item_dictionary[name]
        return LibrarianItem(
            name,
            item_data.classification,
            self.item_name_to_id[name],
            self.player,
        )

    def get_filler_item_name(self) -> str:
        return _filler_items[0].name  # "Whisper of Lore"

    # ------------------------------------------------------------------
    # set_rules — access rules per region/location
    # ------------------------------------------------------------------

    def set_rules(self) -> None:
        mw = self.multiworld
        p = self.player

        # Helper: state-only check for "section X is fully cleared"
        # — every bookcase opened (= bookcase_count shelf unlocks for X),
        # every series in X unlocked.
        # Hoist series-count read outside the inner all(): fill calls this
        # rule a LOT during sweeps; saving N-1 state lookups per call adds
        # up across a multi-player generation.
        series_req = self.series_req
        def section_done(state, sec) -> bool:
            if not state.has(shelf_unlock_name(sec.id), p, sec.bookcase_count):
                return False
            series_unlocked = state.count(ITEM_PROG_SERIES, p)
            for s in sec.series:
                if series_unlocked < series_req[s.name]:
                    return False
            return True

        # Lenient counter for level-up / milestone gating: sum of all shelf
        # unlocks across active sections, capped per-section at the section's
        # actual bookcase count (extra unlocks beyond bookcase_count are
        # cosmetic in-game; they shouldn't inflate the "progression depth").
        active_sections_local = self.active_sections
        def total_shelves_open(state) -> int:
            return sum(
                min(state.count(shelf_unlock_name(sec.id), p), sec.bookcase_count)
                for sec in active_sections_local
            )

        # How many distinct rows can the player FINISH right now? Each row =
        # 1 series in 1 section. The row is reachable iff BOTH:
        #   (a) state.has(shelf_unlock_name(sec.id), shelf_req[(sec, series)])
        #   (b) state.has(Progressive Series Unlock,  series_req[series])
        #
        # Per-series check (not per-section aggregate): a single unlocked
        # series whose case is still hidden is NOT a reachable row, even if
        # other cases in that section are open. This catches edge cases like
        # "1J has 2 cases open but the only unlocked 1J series lives in
        # case 3" — count = 0, not min(structural=8, unlocked=1) = 1.
        per_unlock = self.options.series_per_unlock.value
        active_sections = self.active_sections
        shelf_req = self.shelf_req
        def feasible_rows(state) -> int:
            # Hoist counts outside loops: state.count is O(1) but fill
            # calls this rule heavily. One count per section + one count
            # for series cuts ~3x the lookups vs the prior implementation.
            series_unlocked = state.count(ITEM_PROG_SERIES, p)
            total = 0
            for sec in active_sections:
                shelf_count = state.count(shelf_unlock_name(sec.id), p)
                if shelf_count == 0:
                    continue
                sid = sec.id
                for series in sec.series:
                    shelf_n = shelf_req[(sid, series.name)]
                    series_n = series_req[series.name]
                    if shelf_count >= shelf_n and series_unlocked >= series_n:
                        total += 1
            return total

        # Section region access — gated by ≥1 Progressive Shelf Unlock for X.
        for section in active_sections:
            entrance = mw.get_entrance(f"Open Section {section.id}", p)
            sid = section.id
            entrance.access_rule = (
                lambda state, sid=sid: state.has(shelf_unlock_name(sid), p, 1)
            )

            # Per-row: shelf unlock count + series unlock
            for series in section.series:
                row_loc = mw.get_location(f"Shelf: {section.id} - {series.name}", p)
                shelf_n = self.shelf_req[(section.id, series.name)]
                series_n = self.series_req[series.name]
                row_loc.access_rule = (
                    lambda state, sn=shelf_n, sni=series_n, sid=section.id:
                    state.has(shelf_unlock_name(sid), p, sn)
                    and state.has(ITEM_PROG_SERIES, p, sni)
                )

            # Section completion: state-only check (no can_reach recursion)
            sec_loc = mw.get_location(section_completion_name(section.id), p)
            sec_loc.access_rule = (
                lambda state, sec=section: section_done(state, sec)
            )

        # Floor completions — only the active floor(s) were created in
        # create_regions, so iterate those. Inlined section-check so the
        # series-unlock count gets read just once per rule invocation
        # (vs once per section in the prior `all(section_done(...))` form).
        active_floors = {s.floor for s in active_sections}
        def make_floor_rule(fn):
            def rule(state):
                series_unlocked = state.count(ITEM_PROG_SERIES, p)
                for s in active_sections:
                    if s.floor != fn:
                        continue
                    if not state.has(shelf_unlock_name(s.id), p, s.bookcase_count):
                        return False
                    for ser in s.series:
                        if series_unlocked < series_req[ser.name]:
                            return False
                return True
            return rule
        for floor_n in active_floors:
            floor_loc = mw.get_location(f"Floor {floor_n} Complete", p)
            floor_loc.access_rule = make_floor_rule(floor_n)

        # Minor Magic abilities are NOT AP items — the player gets each
        # ability natively from the chest it's stored in. The chest opening
        # is tracked as a location check, but no AP prereq is needed (the
        # in-game key chain gates which chests are reachable when).

        # Level-up access rules — only for level-up locations that were
        # actually created (create_regions drops ones beyond max_reachable_rows).
        # • feasible_rows(state) >= XP_CURVE[N-1]: the player can actually
        #   finish that many rows (per-series shelf+series check).
        # • count_group("Major Magic") >= N-1: each post-level-1 level
        #   requires one more Major Magic item.
        max_rows = self.max_reachable_rows
        for level_n in range(1, data.MAX_PLAYER_LEVEL + 1):
            if data.XP_CURVE[level_n - 1] > max_rows:
                continue  # location was not created
            rows_needed = data.XP_CURVE[level_n - 1]
            major_magic_needed = max(0, level_n - 1)
            loc = mw.get_location(f"Reached Level {level_n}", p)
            loc.access_rule = (
                lambda state, n=rows_needed, mm=major_magic_needed:
                feasible_rows(state) >= n
                and state.count_group("Major Magic", p) >= mm
            )

        # Milestone access rules — only for milestones whose threshold is
        # reachable in the active pool. Each row is 3, 5, or 10 volumes
        # (avg 3072/400 ≈ 7.68); we use 8 as a conservative divisor.
        for thresh in MILESTONE_THRESHOLDS:
            rows_needed = max(1, math.ceil(thresh / 8))
            if rows_needed > max_rows:
                continue  # location was not created
            loc = mw.get_location(f"Milestone: {thresh} Books Placed", p)
            loc.access_rule = (
                lambda state, n=rows_needed:
                feasible_rows(state) >= n
            )

        # All four chest openings (Crimson, Emerald, Azure, Golden) have
        # no AP rules — the in-game key/chest progression gates them
        # naturally.

        # Goal: state-only checks. The access rule expresses "logically
        # reachable" — what items the player must have received before AP
        # generation considers the goal achievable. The actual goal-fire
        # is in the Lua client based on the row threshold sent in slot_data.
        goal = mw.get_location(GOAL_LOCATION_NAME, p)
        goal_value = self.options.goal.value
        if goal_value == self.options.goal.option_custom:
            # Custom-row goal is reachable once feasible_rows >= threshold.
            threshold = self.options.custom_goal_row_count.value
            goal.access_rule = lambda state, n=threshold: feasible_rows(state) >= n
        else:
            # full / floor_1 / floor_2 all require every active section
            # to be cleared. For floor goals, active_sections is already
            # filtered to that floor; for full it's all 31 sections.
            # Inlined for the same reason as the floor rule: read
            # series-unlock count once per rule call rather than per
            # section (saves 30 lookups on full goal).
            def goal_rule(state):
                series_unlocked = state.count(ITEM_PROG_SERIES, p)
                for s in active_sections:
                    if not state.has(shelf_unlock_name(s.id), p, s.bookcase_count):
                        return False
                    for ser in s.series:
                        if series_unlocked < series_req[ser.name]:
                            return False
                return True
            goal.access_rule = goal_rule

        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    # ------------------------------------------------------------------
    # fill_slot_data — sent to the Lua client at slot-connect time
    # ------------------------------------------------------------------

    def fill_slot_data(self) -> dict[str, Any]:
        # Build (section_id|series_name) → location_id map so the Lua client
        # can resolve the correct AP location when the in-game FinishRow event
        # tells us a particular series's row has been completed. Only includes
        # active sections — for floor goals, the other floor's rows aren't
        # actual locations and shouldn't appear here.
        row_location_map: dict[str, int] = {}
        for section in self.active_sections:
            for series in section.series:
                loc_name = f"Shelf: {section.id} - {series.name}"
                loc_id = self.location_name_to_id.get(loc_name)
                if loc_id is not None:
                    row_location_map[f"{section.id}|{series.name}"] = loc_id

        # Compute the row count at which the Lua client should fire the
        # goal. Floor goals fire when their floor's section count is
        # finished (Lua tracks rows globally, but with pool filtered to
        # one floor, those are the only checks possible). Custom uses
        # the player-chosen row count. Full lets the game's natural
        # EndGame trigger fire.
        goal_value = int(self.options.goal.value)
        if goal_value == self.options.goal.option_floor_1:
            goal_row_threshold = sum(s.shelf_count for s in data.SECTIONS if s.floor == 1)
        elif goal_value == self.options.goal.option_floor_2:
            goal_row_threshold = sum(s.shelf_count for s in data.SECTIONS if s.floor == 2)
        elif goal_value == self.options.goal.option_custom:
            goal_row_threshold = self.options.custom_goal_row_count.value
        else:  # option_full
            # Lua does not pre-fire for full; EndGame fires when player walks the final door.
            goal_row_threshold = sum(s.shelf_count for s in data.SECTIONS)

        return {
            "version": "1.0.0",
            "goal": goal_value,
            # Row count at which the Lua client should send STATUS_GOAL.
            # Ignored for the "full" goal (the game's EndGame fires it).
            "goal_row_threshold": goal_row_threshold,
            # Seed identifier — Lua uses this to isolate the in-game save slot
            # so each AP seed has its own Sav_AP_<seed>_<slot>.sav file.
            "seed": str(self.multiworld.seed_name),
            "starting_section": self.starting_section,
            "starting_series": self.starting_series,
            "starting_series_count": self.options.starting_series_count.value,
            "series_per_unlock": self.options.series_per_unlock.value,
            "series_order": self.series_order,
            "shelf_order": self.shelf_order,
            # Per-section bookcase counts — Lua uses this to size the per-section
            # shelf-unlock cap (Progressive Shelf Unlock items beyond this count
            # have no visible effect). Only active sections; for floor goals,
            # the other floor's bookcases stay hidden in-game (no shelf
            # unlocks ever arrive for them).
            "bookcase_counts": {s.id: s.bookcase_count for s in self.active_sections},
            # Row-completion location lookup: "<sid>|<series_name>" → AP location id.
            "row_location_map": row_location_map,
            # Milestone thresholds shipped so the Lua side knows when to fire each.
            "milestone_thresholds": list(MILESTONE_THRESHOLDS),
            # How locked-series books should look. "stacks" = visible-but-disabled
            # (preserves visual density; collision off so player walks through).
            # The hidden-mode code path is still present in the Lua client for
            # possible future re-introduction, but the YAML option was removed
            # for v1.0 because the HISM per-instance limitations left ~5-10
            # books visible in walls/floors.
            "book_visibility": "stacks",
        }
