"""
Librarian: Tidy Up the Arcane Library — Archipelago World implementation.

Wires Items + Locations + Options into AP and produces a solvable seed.

Per-seed orderings randomized in generate_early():
  - series_order[i]   = series name unlocked at position i in the global
                        series queue. Each Progressive Series Unlock
                        advances the queue by `series_per_unlock` (default 5).
  - shelf_order[s][i] = bookcase index opened by the (i+1)-th Progressive
                        Shelf Unlock (s) item.

Section access is implicit: a section is reachable once the player holds
≥1 Progressive Shelf Unlock for it. Each subsequent unlock reveals the
next bookcase within that section.

Starting state (precollected):
  - 1× Progressive Shelf Unlock (starting_section) → first bookcase visible
  - 2× Progressive Series Unlock                   → 10 starting series

Access rules enforce solvability; AP's generator places progression items
in spheres that satisfy the rules.
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
    ROW_COMPLETION_THRESHOLDS,
    _row_locations,
    _row_completion_locations,
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
      - Uniform-volume section: spread series evenly across bookcase_count.
      - Mixed volume that fits in bookcase_count: smaller-vol cases unlock
        first; each volume group occupies ceil(group_count / cells_per_case)
        cases, ordered ascending.
      - Otherwise (e.g. 1-case sections that mix vols): all series get
        shelf_req=1 (only one case to unlock).
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
    Sort 3072 books across 400 shelves in 31 themed sections, gated by
    AP-delivered series/shelf unlocks. Major Magic skills are progression
    items (gate level-ups). Minor Magic abilities (Jump/Run/Bag/Bag2) are
    NOT AP items — the player gets each ability natively by opening its
    chest; the chest opening fires the AP location check.
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
    starting_section_b: "str | None"
    starting_series: list[str]
    series_req: dict[str, int]
    shelf_req: dict[tuple[str, str], int]

    def __init__(self, multiworld: MultiWorld, player: int):
        super().__init__(multiworld, player)
        self.series_order = []
        self.shelf_order = {}
        self.starting_section = ""
        self.starting_section_b: str | None = None
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
        - Custom goal: the player's chosen row threshold (the player can
          play past it in-game, but AP only tracks up to that point).
        - Full goal: all 400 rows."""
        # UT passthrough: options hold defaults during regen; slot_data
        # has the real value.
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

        # UT regen path: reconstruct the seed's state from slot_data
        # (stored in re_gen_passthrough by interpret_slot_data) rather
        # than randomizing. Without this, UT's reachability info wouldn't
        # match the actual seed.
        pt = self._ut_passthrough()
        if pt:
            self.starting_section = pt.get("starting_section", "")
            self.starting_section_b = pt.get("starting_section_b", None)
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

        # 1. Pick two random starting sections (different from each other
        #    when active scope allows). Each gets one precollected shelf
        #    unlock — opening the first bookcase of each at sphere 0.
        #    Two distinct sections (vs two bookcases in one) is what gives
        #    sphere-1 fill flexibility: AP can route progression through
        #    items gating either section's rows.
        section_ids = [s.id for s in active]
        rng.shuffle(section_ids)
        self.starting_section = section_ids[0]
        self.starting_section_b = section_ids[1] if len(section_ids) >= 2 else None

        # 2. Per-section bookcase order — ordinal for now; can randomize later.
        for section in active:
            self.shelf_order[section.id] = list(range(section.bookcase_count))

        # 3. shelf_req must come BEFORE the starting-series guarantee — we
        # use it to identify which series live in the first VISIBLE case
        # (Lua sorts cases by vol-tier ascending; shelf_req=1 ⇔ smallest
        # unlocked case). Mixed-vol sections like 1M (2×4x5 + 3×plain) have
        # smaller-vol cases unlock first, so a 10-vol series in 1M needs ≥3
        # unlocks before reachable. Lua side mirrors this ordering.
        CELLS_PER_CASE = 4  # standard BookCase capacity (4 series per case)
        for section in active:
            self.shelf_req.update(_compute_shelf_req(section, CELLS_PER_CASE))

        # 4. Build series order with one guaranteed series in each starting
        # section's first bookcase — so the player can complete a row in
        # each starting section before any AP item arrives (two distinct
        # sphere-0 paths). shelf_req must == 1 so the single precollected
        # shelf unlock per section makes them placeable.
        starting_count = self.options.starting_series_count.value

        def _guarantee_for_section(sid: str | None) -> str | None:
            if sid is None:
                return None
            sec_obj = data.SECTIONS_BY_ID[sid]
            reachable = [
                s.name for s in sec_obj.series
                if self.shelf_req[(sid, s.name)] == 1
            ]
            if not reachable:
                # Defensive fallback: pick any series in the section.
                reachable = [s.name for s in sec_obj.series]
            return rng.choice(reachable) if reachable else None

        guaranteed: list[str] = []
        primary_pick = _guarantee_for_section(self.starting_section)
        if primary_pick and len(guaranteed) < starting_count:
            guaranteed.append(primary_pick)
        secondary_pick = _guarantee_for_section(self.starting_section_b)
        if (secondary_pick
                and secondary_pick not in guaranteed
                and len(guaranteed) < starting_count):
            guaranteed.append(secondary_pick)

        all_series = [s.name for sec in active for s in sec.series]
        guaranteed_set = set(guaranteed)
        other_pool = [n for n in all_series if n not in guaranteed_set]
        rng.shuffle(other_pool)

        # Fill remaining starting slots from the shuffled non-guaranteed pool,
        # then mix guaranteed entries in at random positions.
        non_guaranteed_count = max(0, starting_count - len(guaranteed))
        starting = other_pool[:non_guaranteed_count] + guaranteed
        rng.shuffle(starting)
        rest = other_pool[non_guaranteed_count:]

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

            # Row locations for this section.
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

        # Book-placement milestones removed in v1.0.3 — closure-based
        # "in logic" leakage marked high thresholds reachable too early,
        # and the v1.0.2 default-mode warding made them swap-exploitable.
        # Replaced 1:1 by row-completion thresholds (see Locations.py).
        # MILESTONE_THRESHOLDS is still exported in case we re-add later.
        active_milestone_locs: list = []

        # Row-completion count milestones: each fires when the player has
        # correctly completed N total rows. Filter by max_rows the same
        # way level-ups do — a milestone of "Complete 300 Rows" is
        # unreachable if the seed only has 200 rows in scope.
        active_row_completion_locs = [
            loc for idx, loc in enumerate(_row_completion_locations)
            if ROW_COMPLETION_THRESHOLDS[idx] <= max_rows
        ]

        # Library-attached: floor completions, level-ups, chest openings,
        # milestones, row-completion milestones.
        for category in (active_floor_locs, active_levelup_locs,
                         _chest_locations, active_milestone_locs,
                         active_row_completion_locs):
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

        # Precollect: one shelf unlock for each of the two starting sections
        # + N starting-series worth of Progressive Series Unlock items.
        #
        # Two DIFFERENT sections (vs two bookcases in one section) is what
        # broadens sphere-1 fill flexibility — AP fill can route progression
        # through items that gate either section's rows. Multiple bookcases
        # in one section all gate behind the same shelf-unlock chain.
        starting_count = self.options.starting_series_count.value
        starting_unlock_count = math.ceil(starting_count / per_unlock)

        precollect_names: list[str] = [shelf_unlock_name(self.starting_section)]
        if self.starting_section_b is not None:
            precollect_names.append(shelf_unlock_name(self.starting_section_b))
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

        # Subtract items the user requested via start_inventory_from_pool.
        # AP's framework removes these from the pool AFTER create_items
        # returns; without pre-adjusting quantities here, the Major Magic
        # cap below can drop ALL copies of a skill the user wanted from
        # the pool, leaving zero copies for AP to precollect — silently
        # losing the user's request. Fixes "adding magic skills to
        # starting inventory does not work."
        #
        # multiworld.start_inventory_from_pool may not have an entry for
        # this player when the YAML doesn't set the option; use .get() to
        # default to an empty dict and skip the subtract step.
        sifp_option = self.multiworld.start_inventory_from_pool.get(self.player)
        sifp = sifp_option.value if sifp_option else {}
        for name, count in sifp.items():
            if name in quantities:
                quantities[name] = max(0, quantities[name] - count)

        # Major Magic cap: each player needs at most (levels_kept - 1)
        # Major Magic items to reach their highest reachable level. Extras
        # are redundant progression-classified items — AP still has to
        # place them, and in multi-player seeds with mixed goals (floor /
        # low-custom configs that drop level-ups) they starve the cross-
        # world progression pool and trigger "Not enough locations for
        # progression items" fill failures.
        #
        # Shrink the pool by the excess; filler fills the freed slots
        # below to keep per-player |items| == |locations|.
        major_magic_names = (
            "Progressive Sort", "Progressive Shelf Guide",
            "Progressive Insight", "Progressive Auto-Shelving",
            "Progressive Assemble",
        )
        levels_kept = sum(
            1 for idx in range(data.MAX_PLAYER_LEVEL)
            if data.XP_CURVE[idx] <= self.max_reachable_rows
        )
        max_major_magic_needed = max(0, levels_kept - 1)
        total_major_magic = sum(quantities.get(n, 0) for n in major_magic_names)
        excess_magic = total_major_magic - max_major_magic_needed
        if excess_magic > 0:
            # Drop excess copies, taking from skills with the most
            # remaining quantity first (keeps each skill's available
            # count roughly proportional to its cap).
            removed = 0
            while removed < excess_magic:
                drop_skill = max(major_magic_names, key=lambda n: quantities.get(n, 0))
                if quantities.get(drop_skill, 0) <= 0:
                    break  # nothing left to remove (shouldn't happen)
                quantities[drop_skill] -= 1
                removed += 1

        # Pool-overshoot guard. Triggers on combinations like
        # series_per_unlock=2 + starting_count near max + custom goal with
        # low row_count (drops level-up + milestone locations from target
        # while pool stays full).
        #
        # Relief valve: lift extra Series Unlocks into starting inventory.
        # That strictly improves the player's starting state while
        # shrinking the in-pool item count 1-for-1. Skills are always
        # preserved — players expect a full set.
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
        per_unlock = self.options.series_per_unlock.value
        active_sections = self.active_sections
        series_req = self.series_req
        shelf_req = self.shelf_req

        # Precomputed lookup tables — fill_restrictive invokes access
        # rules millions of times; hoisting these out is the biggest
        # wall-clock generation win. Each table replaces a per-call op:
        #   shelf_names[sid]         — pre-formatted unlock-item strings
        #   section_series_reqs[sid] — tuple of series_req values in order
        #   section_row_reqs[sid]    — (shelf_n, series_n) per series;
        #                              powers feasible_rows
        #   floor_sections[fn]       — pre-bucketed by floor
        shelf_names = {sec.id: shelf_unlock_name(sec.id) for sec in active_sections}
        section_series_reqs = {
            sec.id: tuple(series_req[s.name] for s in sec.series)
            for sec in active_sections
        }
        section_row_reqs = {
            sec.id: [
                (shelf_req[(sec.id, s.name)], series_req[s.name])
                for s in sec.series
            ]
            for sec in active_sections
        }
        floor_sections: dict[int, list] = {}
        for sec in active_sections:
            floor_sections.setdefault(sec.floor, []).append(sec)

        # Precomputed 2D reachable-rows table per section.
        # section_reach[sid][shelf_count][series_count] = rows in that
        # section reachable given that many shelf/series unlocks. Clamps
        # the indices so out-of-range counts cap at the table edges.
        #
        # Lets feasible_rows do one prog_items dict read per section + a
        # 2D list lookup — ~62 dict ops total, no string formatting, no
        # state.count calls. Level-up + row-completion rules fire ~250x
        # per state during fill sweeps, so the precompute pays for itself.
        max_series_idx = len(self.series_order)
        section_reach: dict[str, list[list[int]]] = {}
        for sec in active_sections:
            bc_count = sec.bookcase_count
            row_reqs = section_row_reqs[sec.id]
            table_2d: list[list[int]] = []
            for shelf_count in range(bc_count + 1):
                row_for_shelves: list[int] = [0] * (max_series_idx + 1)
                # Pass 1: per series_count, count how many series reqs
                # are met. Incremental — sort by series_n and run a
                # cumulative count.
                ready_at: list[int] = []  # series_n values that pass shelf
                for shelf_n, series_n in row_reqs:
                    if shelf_count >= shelf_n:
                        ready_at.append(series_n)
                ready_at.sort()
                idx = 0
                count_so_far = 0
                for series_count in range(max_series_idx + 1):
                    while idx < len(ready_at) and ready_at[idx] <= series_count:
                        count_so_far += 1
                        idx += 1
                    row_for_shelves[series_count] = count_so_far
                table_2d.append(row_for_shelves)
            section_reach[sec.id] = table_2d

        # Same idea, but flatten the per-section lookup into a flat list
        # of (shelf_unlock_name, table_2d, bc_count) tuples. The
        # feasible_rows hot loop iterates this list directly instead of
        # going through active_sections + dict[sec.id] every call.
        section_reach_list: list[tuple[str, list[list[int]], int]] = [
            (shelf_names[sec.id], section_reach[sec.id], sec.bookcase_count)
            for sec in active_sections
        ]

        # Helper: state-only check for "section X is fully cleared"
        # — every bookcase opened (= bookcase_count shelf unlocks for X),
        # every series in X unlocked.
        # Hoist series-count read outside the inner all(): fill calls this
        # rule a LOT during sweeps; saving N-1 state lookups per call adds
        # up across a multi-player generation.
        def section_done(state, sec) -> bool:
            if not state.has(shelf_names[sec.id], p, sec.bookcase_count):
                return False
            series_unlocked = state.count(ITEM_PROG_SERIES, p)
            for needed in section_series_reqs[sec.id]:
                if series_unlocked < needed:
                    return False
            return True

        # How many distinct rows can the player FINISH right now? Powered
        # by section_reach — O(active sections) direct-dict lookups, no
        # state.count calls, no string formatting. Reads prog_items
        # directly to skip state.count's two-dict-lookup overhead.
        #
        # feasible_rows is called by 96 separate access rules (50 row-
        # completion + 45 level-up + 1 goal). When fill evaluates these
        # against the same state in sequence, recomputing 96x is wasted.
        # We cache the result on the state object itself under a unique
        # attr name; marker = (series_count, sum of shelf counts). Any
        # tracked-item increment invalidates the marker, so stale reads
        # are impossible. State.copy() carries the attribute, and new
        # states post-collect get a different marker → refresh.
        cache_attr = f"_librarian_feasible_{p}"
        shelf_names_only = [name for name, _, _ in section_reach_list]

        def feasible_rows(state) -> int:
            prog = state.prog_items[p]
            series_count = prog[ITEM_PROG_SERIES]
            # Cheap freshness marker: (series count, sum of shelf counts).
            # Any state mutation that affects feasible_rows must change at
            # least one of these — they all feed into the lookup table.
            # Construction is ~32 dict reads vs ~31 table lookups + adds
            # in the full path, so cache hits save ~2/3 of the work.
            shelf_sum = 0
            for sn in shelf_names_only:
                shelf_sum += prog[sn]
            marker = (series_count, shelf_sum)
            cached = state.__dict__.get(cache_attr)
            if cached is not None and cached[0] == marker:
                return cached[1]

            # Cache miss — compute fully.
            if series_count > max_series_idx:
                series_count = max_series_idx
            total = 0
            for shelf_name, table_2d, bc_count in section_reach_list:
                shelf_count = prog[shelf_name]
                if shelf_count > bc_count:
                    shelf_count = bc_count
                total += table_2d[shelf_count][series_count]
            state.__dict__[cache_attr] = (marker, total)
            return total

        # Milestone helpers. Milestones fire on cumulative books PLACED;
        # any book on any shelf counts — correct placement isn't required.
        # Threshold is reachable once the player has enough unlocked-series
        # books to pick up AND enough open shelf capacity to drop them.
        # Both totals are cumulative and monotonic. Precompute lookup
        # arrays so each rule call is O(active_sections) rather than O(series).
        only_shelfable = bool(self.options.only_unward_shelfable_books.value)
        series_volumes_by_name = {
            ser.name: ser.volumes
            for sec in data.SECTIONS for ser in sec.series
        }
        # cumulative_books_unlocked[k] = total volumes in series_order[:k]
        cumulative_books_unlocked: list[int] = [0]
        for name in self.series_order:
            cumulative_books_unlocked.append(
                cumulative_books_unlocked[-1]
                + series_volumes_by_name.get(name, 0)
            )
        # section_cumulative_slots[sid][n] = total shelf-slot capacity of
        # the first n bookcases of section sid. Capacity per bookcase is the
        # sum of volumes of the series that live on it (via shelf_req).
        section_cumulative_slots: dict[str, list[int]] = {}
        for sec in active_sections:
            per_bookcase_volumes: dict[int, int] = {}
            for ser in sec.series:
                bc_idx = shelf_req[(sec.id, ser.name)]
                per_bookcase_volumes[bc_idx] = (
                    per_bookcase_volumes.get(bc_idx, 0) + ser.volumes
                )
            cumulative: list[int] = [0]
            for bc_idx in sorted(per_bookcase_volumes):
                cumulative.append(cumulative[-1] + per_bookcase_volumes[bc_idx])
            section_cumulative_slots[sec.id] = cumulative

        # Hoist len(...)-1 sentinels out of the per-call hot path so each
        # rule invocation just compares ints rather than calling len() and
        # subtracting on every iteration.
        _books_unlocked_max_idx = len(cumulative_books_unlocked) - 1
        _books_unlocked_max = cumulative_books_unlocked[-1]
        # Pre-extract (table, max_idx, max_value) tuples per section so
        # the hot-path loop in shelf_slots_open only does dict lookup once
        # and reuses the precomputed per-section bounds.
        section_slots_table = {
            sec.id: (
                section_cumulative_slots[sec.id],
                len(section_cumulative_slots[sec.id]) - 1,
                section_cumulative_slots[sec.id][-1],
            )
            for sec in active_sections
        }

        def books_unlocked(state) -> int:
            n_series = state.count(ITEM_PROG_SERIES, p) * per_unlock
            if n_series >= _books_unlocked_max_idx:
                return _books_unlocked_max
            return cumulative_books_unlocked[n_series]

        def shelf_slots_open(state) -> int:
            total = 0
            for sec in active_sections:
                n = state.count(shelf_names[sec.id], p)
                table, max_idx, max_val = section_slots_table[sec.id]
                if n >= max_idx:
                    total += max_val
                else:
                    total += table[n]
            return total

        # Section region access — gated by ≥1 Progressive Shelf Unlock for X.
        # Capture the precomputed shelf-unlock name string in the lambda
        # closure so the rule doesn't re-format the section id every call.
        for section in active_sections:
            entrance = mw.get_entrance(f"Open Section {section.id}", p)
            entrance.access_rule = (
                lambda state, sname=shelf_names[section.id]:
                state.has(sname, p, 1)
            )

            # Per-row: shelf unlock count + series unlock.
            sec_shelf_name = shelf_names[section.id]
            for series in section.series:
                shelf_n = shelf_req[(section.id, series.name)]
                series_n = series_req[series.name]

                def make_row_rule(sname, sn, sni):
                    return lambda state: (
                        state.has(sname, p, sn)
                        and state.has(ITEM_PROG_SERIES, p, sni)
                    )
                rule = make_row_rule(sec_shelf_name, shelf_n, series_n)

                row_loc = mw.get_location(f"Shelf: {section.id} - {series.name}", p)
                row_loc.access_rule = rule

            # Section completion: state-only check (no can_reach recursion)
            sec_loc = mw.get_location(section_completion_name(section.id), p)
            sec_loc.access_rule = (
                lambda state, sec=section: section_done(state, sec)
            )

        # Floor completions — only the active floor(s) were created in
        # create_regions, so iterate those. The pre-bucketed floor_sections,
        # shelf_names and section_series_reqs cut per-section work in the
        # rule to one state.has + one tuple iteration.
        for floor_n, sections_in_floor in floor_sections.items():
            floor_loc = mw.get_location(f"Floor {floor_n} Complete", p)

            def make_floor_rule(secs):
                def rule(state):
                    series_unlocked = state.count(ITEM_PROG_SERIES, p)
                    for s in secs:
                        if not state.has(shelf_names[s.id], p, s.bookcase_count):
                            return False
                        for needed in section_series_reqs[s.id]:
                            if series_unlocked < needed:
                                return False
                    return True
                return rule
            floor_loc.access_rule = make_floor_rule(sections_in_floor)

        # Minor Magic abilities are NOT AP items — the player gets each
        # ability natively from the chest it's stored in. The chest opening
        # is tracked as a location check, but no AP prereq is needed (the
        # in-game key chain gates which chests are reachable when).

        # Level-up access rules — only for level-up locations that were
        # actually created (create_regions drops ones beyond max_reachable_rows).
        # • feasible_rows(state) >= XP_CURVE[N-1]: player can finish that
        #   many rows (per-series shelf+series check).
        # • Major Magic total >= N-1: each post-level-1 level requires
        #   one Major Magic. Sum five state.count calls directly rather
        #   than count_group("Major Magic", p) — count_group walks the
        #   full item list per call, a hot-path cost during fill sweeps.
        major_magic_names = ("Progressive Sort", "Progressive Shelf Guide",
                             "Progressive Insight", "Progressive Auto-Shelving",
                             "Progressive Assemble")
        def major_magic_total(state) -> int:
            return sum(state.count(n, p) for n in major_magic_names)
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
                and major_magic_total(state) >= mm
            )

        # Book-placement milestones were removed in v1.0.3 (see
        # create_regions). No access_rule loop needed here; if any are
        # ever re-added, books_unlocked + shelf_slots_open are still
        # defined above as helpers.

        # Row-completion milestones. Each fires when the player has
        # correctly completed N total rows. Reachable when feasible_rows
        # (the same per-series item-availability check we already use)
        # is at least N. feasible_rows is cached, so the 200 rules share
        # one underlying computation per state.
        for thresh in ROW_COMPLETION_THRESHOLDS:
            if thresh > max_rows:
                continue  # location was not created
            loc = mw.get_location(f"Complete {thresh} Rows", p)
            loc.access_rule = (
                lambda state, n=thresh: feasible_rows(state) >= n
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
                    if not state.has(shelf_names[s.id], p, s.bookcase_count):
                        return False
                    for needed in section_series_reqs[s.id]:
                        if series_unlocked < needed:
                            return False
                return True
            goal.access_rule = goal_rule

        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    # ------------------------------------------------------------------
    # fill_slot_data — sent to the Lua client at slot-connect time
    # ------------------------------------------------------------------

    def fill_slot_data(self) -> dict[str, Any]:
        # (section_id|series_name) → location_id. Lua resolves the AP
        # location when FinishRow fires for a particular series. Active
        # sections only — floor goals exclude the other floor entirely.
        row_location_map: dict[str, int] = {}
        # series_name → bookcase index. Lua gates book unwarding so a book
        # is pickable only when BOTH its series is received and its
        # bookcase is open.
        shelf_req_map: dict[str, int] = {}
        # section_id → location id for "Section Complete: <id> (<name>)".
        # Lua fires when every row in the section is complete. Active
        # sections only — floor goals exclude the other floor's sections.
        section_location_map: dict[str, int] = {}
        for section in self.active_sections:
            for series in section.series:
                loc_name = f"Shelf: {section.id} - {series.name}"
                loc_id = self.location_name_to_id.get(loc_name)
                if loc_id is not None:
                    row_location_map[f"{section.id}|{series.name}"] = loc_id
                shelf_req_map[series.name] = self.shelf_req[(section.id, series.name)]
            sec_loc_name = section_completion_name(section.id)
            sec_loc_id = self.location_name_to_id.get(sec_loc_name)
            if sec_loc_id is not None:
                section_location_map[section.id] = sec_loc_id

        # str(floor) → location id for "Floor N Complete". Lua fires when
        # every row in the floor's active sections is complete. Only
        # active-goal floors. Keys stringified to match convention and
        # avoid the JSON-roundtrip "int keys become strings" Lua quirk.
        floor_location_map: dict[str, int] = {}
        active_floors_set = {s.floor for s in self.active_sections}
        for floor_n in sorted(active_floors_set):
            floor_loc_name = f"Floor {floor_n} Complete"
            floor_loc_id = self.location_name_to_id.get(floor_loc_name)
            if floor_loc_id is not None:
                floor_location_map[str(floor_n)] = floor_loc_id

        # Row count at which Lua should fire the goal. Floor goals fire
        # when their floor's section count is met (Lua tracks rows
        # globally; pool filtering to one floor makes those the only
        # checks anyway). Custom uses the player-chosen count. Full lets
        # the game's natural EndGame trigger fire.
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
            # Keep in sync with archipelago.json:world_version + main.lua MOD_VERSION.
            # (The Lua client parses only the numeric 1.1.0 from this for its warding-rule
            # gate; the -betaN suffix is informational, used in logs/telemetry.)
            "version": "1.1.0",
            "goal": goal_value,
            # Row count at which the Lua client should send STATUS_GOAL.
            # Ignored for the "full" goal (the game's EndGame fires it).
            "goal_row_threshold": goal_row_threshold,
            # Seed identifier — Lua uses this to isolate the in-game save slot
            # so each AP seed has its own Sav_AP_<seed>_<slot>.sav file.
            "seed": str(self.multiworld.seed_name),
            "starting_section": self.starting_section,
            "starting_section_b": self.starting_section_b,
            "starting_series": self.starting_series,
            "starting_series_count": self.options.starting_series_count.value,
            "series_per_unlock": self.options.series_per_unlock.value,
            "series_order": self.series_order,
            "shelf_order": self.shelf_order,
            # Per-section bookcase counts. Sizes the per-section shelf-
            # unlock cap (excess Progressive Shelf Unlocks have no visible
            # effect). Active sections only; for floor goals, the other
            # floor's bookcases stay hidden in-game.
            "bookcase_counts": {s.id: s.bookcase_count for s in self.active_sections},
            # "<sid>|<series_name>" → AP location id.
            "row_location_map": row_location_map,
            # series_name → bookcase index needed for its row. Lua uses
            # this in Pass 1 of book-warding to require BOTH series unlock
            # AND its bookcase open before a book becomes pickable. Only
            # consulted when only_unward_shelfable_books=1.
            "shelf_req_map": shelf_req_map,
            # section_id → AP location id for "Section Complete". Lua
            # fires when every row in the section is complete. Absent
            # from pre-1.0.3 seeds (Lua treats missing key as "no
            # section-completion firing"; backward compat).
            "section_location_map": section_location_map,
            # str(floor) → AP location id for "Floor N Complete". Lua
            # fires when every row in the floor's active sections is
            # complete. Active-goal floors only. Absent from pre-1.0.4
            # seeds; Lua falls back to a static FLOOR_IDX constant.
            "floor_location_map": floor_location_map,
            # Toggle: when 1, Lua wards a book unless BOTH its series and
            # its bookcase are unlocked. When 0 (default), only series
            # unlock matters.
            "only_unward_shelfable_books": int(self.options.only_unward_shelfable_books.value),
            # As of v1.0.3 we don't create book-placement milestone
            # locations (see create_regions), so this ships empty and
            # Lua's milestone-fire loop is a no-op. Lua-side counter
            # infrastructure stays around for future use — that's why
            # we send an empty list instead of dropping the key.
            "milestone_thresholds": [],
            # Lua tracks correctly-completed rows and fires each threshold.
            "row_completion_thresholds": list(ROW_COMPLETION_THRESHOLDS),
            # Locked-series book appearance, from the BookVisibility option.
            # "hidden" (default) = invisible + non-grabbable; "stacks" =
            # visible-but-non-grabbable (collision off, walk through). The Lua
            # client gates ALL hiding on this == "hidden"; in "stacks" it only
            # disables collision, so none of the hide-path edge cases apply.
            "book_visibility": self.options.book_visibility.current_key,
        }
