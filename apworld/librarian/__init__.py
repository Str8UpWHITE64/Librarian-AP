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

from BaseClasses import MultiWorld, Region, Tutorial, ItemClassification, CollectionState
from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule, add_rule, add_item_rule
from Fill import fill_restrictive, FillError, sweep_from_pool

from . import data
from .Items import (
    LibrarianItem,
    LibrarianItemCategory,
    item_dictionary,
    item_name_groups,
    ITEM_QUANTITIES,
    ITEM_ID_BASE,
    _filler_items,
    series_unlock_item_name,
    book_item_name,
)
from .Locations import (
    LibrarianLocation,
    LibrarianLocationCategory,
    location_dictionary,
    location_name_groups,
    total_real_locations,
    section_completion_name,
    levelup_name,
    chest_open_name,
    ROW_COMPLETION_THRESHOLDS,
    BOOK_COMPLETION_THRESHOLDS,
    _book_name,
    _row_locations,
    _row_completion_locations,
    _section_locations,
    _floor_locations,
    _levelup_locations,
    _chest_locations,
    _book_completion_locations,
    _goal_locations,
)
from .Options import LibrarianOptions

# Item names used as constants below (avoids typos)
ITEM_PROG_SERIES  = "Progressive Series Unlock"

# The 5 Major Magic item names. Used by create_items/_create_items_book to size
# and cap the Major Magic pool; they no longer gate any location (feasible_rows
# never modelled magic).
_MAJOR_MAGIC_NAMES = frozenset((
    "Progressive Sort", "Progressive Shelf Guide", "Progressive Insight",
    "Progressive Auto-Shelving", "Progressive Assemble",
))

# Prefix of every individual series-unlock item name (Items.series_unlock_item_name).
_SERIES_ITEM_PREFIX = "Series Unlock: "


def _buffs_traps_quantities() -> dict:
    """{item_name: qty} for the buff/trap items every mode adds: Skill Mastery (useful), Fatigue
    (trap), and Book Capacity (useful). Every skill gets its full 5-item Mastery set -- the pool now
    keeps all Major Magic so each skill maxes, and the client treats Mastery as extra skill levels
    past the native max. Fatigue (bites at any level) and the bag items always go in too."""
    q: dict = {}
    for name in ("Sort", "Shelf Guide", "Insight", "Auto-Shelving", "Assemble"):
        q[f"{name} Mastery"] = 5
        q[f"Fatigue: {name}"] = 2
    q["+2 Book Capacity"] = 8
    q["+3 Book Capacity"] = 3
    return q


# Full-goal invariant: the goal requires mm >= levels_kept (= MAX_PLAYER_LEVEL at
# the full goal), so the five Major Magic skills must be able to supply that many
# levels between them. These are independent data tables; pin the invariant here
# so a future edit that lowers a skill max or grows XP_CURVE fails loudly at world
# load instead of silently making the full goal unwinnable.
assert (sum(data.SKILL_MAX_LEVELS[a] for a in data.MAJOR_MAGIC_ABILITIES)
        >= data.MAX_PLAYER_LEVEL), (
    "Major Magic levels < MAX_PLAYER_LEVEL: the full goal would demand more "
    "magic than the pool can supply.")


def _librarian_carry_state(source: CollectionState, ret: CollectionState) -> CollectionState:
    """CollectionState.copy() rebuilds a fresh state and drops __dict__ extras,
    so a sweep-copy would lose our per-state stamp caches and the incremental
    feasible_books counter (reset to 0 -> wrong logic). Registered into
    additional_copy_functions to carry our _librarian_* keys across copies."""
    rd = ret.__dict__
    for k, v in source.__dict__.items():
        if k.startswith("_librarian_"):
            rd[k] = v
    return ret


if _librarian_carry_state not in CollectionState.additional_copy_functions:
    CollectionState.additional_copy_functions.append(_librarian_carry_state)


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
        self.starting_book_names = []  # booksanity: random books precollected at start
        self.series_req = {}
        self.shelf_req = {}
        # Per-state cache/counter keys, precomputed so the collect/remove hot
        # path never re-formats them.
        self._stamp_key = f"_librarian_stamp_{player}"
        self._bookcount_key = f"_librarian_bookcount_{player}"
        # individual mode: O(1) count of held series items (== feasible_rows, since
        # all shelves are precollected so has(shelf) is always true).
        self._seriescount_key = f"_librarian_seriescount_{player}"
        self._is_book_sanity = False  # set in generate_early

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
    # BookSanity (book_sanity) helpers
    # ------------------------------------------------------------------

    @property
    def book_sanity(self) -> bool:
        pt = self._ut_passthrough()
        if pt and "book_sanity" in pt:
            return bool(pt["book_sanity"])
        return (self.options.unlock_mode.value
                == self.options.unlock_mode.option_booksanity)

    @property
    def individual(self) -> bool:
        """True when unlock_mode == individual_series_unlocks (each series its own
        item). UT-aware: reads the passthrough int fill_slot_data emits."""
        pt = self._ut_passthrough()
        if pt and "individual_series_items" in pt:
            return bool(pt["individual_series_items"])
        return (self.options.unlock_mode.value
                == self.options.unlock_mode.option_individual_series_unlocks)

    @property
    def active_books(self) -> list[tuple[int, int, str, str]]:
        """(asset_idx, chapter, section_id, series_name) for every book in the
        active-goal sections, in data.ALL_BOOKS order."""
        active = self.active_section_ids
        return [b for b in data.ALL_BOOKS if b[2] in active]

    @property
    def max_reachable_books(self) -> int:
        """Total books in the active-goal scope (drives the level-up /
        book-completion filter, analogous to max_reachable_rows)."""
        return sum(s.volume_count for s in self.active_sections)

    def _levels_kept(self, max_reachable: int) -> int:
        """How many player levels are reachable given `max_reachable` rows/books
        (how many XP_CURVE thresholds fit). Single source of truth for BOTH the
        Major Magic pool size (create_items) and the goal's magic requirement
        (set_rules), so they cannot drift -- pass rows for grouped/individual and
        books for book_sanity. At the full goal this is MAX_PLAYER_LEVEL (45), so
        all magic is kept and required; it self-limits for floor/custom goals."""
        return sum(1 for idx in range(data.MAX_PLAYER_LEVEL)
                   if data.XP_CURVE[idx] <= max_reachable)


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
        # Cache the mode flag (a property reading options/passthrough) as a plain
        # bool -- the collect/remove hot path checks it constantly.
        self._is_book_sanity = self.book_sanity

        # local_filler is applied in pre_fill (_place_local_filler), NOT via
        # options.local_items: local_items lets AP's greedy remaining_fill strand
        # it on an all-tight multiworld. Pre-placing with a margin is robust.

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
            self.starting_book_names = list(pt.get("starting_books", []))
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

        # 6. BookSanity: precollect a random set of INDIVIDUAL books. The count is
        # the sum of starting_series_count rolled series sizes (3/5/10 each), so
        # e.g. 5 -> 15-50 random books. Independent of starting_series (the
        # whole-series concept the other modes use); every bookcase is open, so any
        # held book is a reachable sphere-0 check. Rolled last so it doesn't shift
        # the earlier per-seed RNG. Sent in slot_data for UT reconstruction.
        self.starting_book_names = []
        if self.book_sanity:
            n_books = sum(rng.choice((3, 5, 10))
                          for _ in range(self.options.starting_series_count.value))
            all_books = [book_item_name(name, ch)
                         for (_ai, ch, _sid, name) in self.active_books]
            rng.shuffle(all_books)
            self.starting_book_names = all_books[:min(n_books, len(all_books))]

    def _keep_row_completions(self) -> bool:
        """Whether to create the 72 'Complete N Rows' checks this seed.

        They are only needed as fill-routing surface for the deepest series chain
        (grouped mode, series_per_unlock <= 3). Every looser config generates fine
        without them, so we drop all 72 (fewer filler items) except for the P<=3
        deep-chain opt-in. book_sanity never creates them regardless."""
        if self.book_sanity or self.individual:
            return False
        return self.options.series_per_unlock.value <= 3

    # ------------------------------------------------------------------
    # create_regions — Menu → Library → 31 section regions
    # ------------------------------------------------------------------

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        library = Region("Library", self.player, self.multiworld)
        self.multiworld.regions.extend([menu, library])
        menu.connect(library, "Enter Library")

        active_ids = self.active_section_ids

        if self.book_sanity:
            self._create_regions_book(library)
            return

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

        # Row-completion count milestones: each fires when the player has
        # correctly completed N total rows. Filter by max_rows the same
        # way level-ups do — a milestone of "Complete 300 Rows" is
        # unreachable if the seed only has 200 rows in scope.
        active_row_completion_locs = [
            loc for idx, loc in enumerate(_row_completion_locations)
            if ROW_COMPLETION_THRESHOLDS[idx] <= max_rows
        ] if self._keep_row_completions() else []

        # Library-attached: floor completions, level-ups, chest openings,
        # milestones, row-completion milestones.
        for category in (active_floor_locs, active_levelup_locs,
                         _chest_locations, active_row_completion_locs):
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

    def _create_regions_book(self, library) -> None:
        """BookSanity region layout: one BOOK location per volume (gated on its
        own book item), plus section/floor/level-up/chest/book-completion and
        the goal. Mirrors create_regions but at book granularity."""
        mw = self.multiworld
        max_books = self.max_reachable_books

        for section in self.active_sections:
            region = Region(f"Section {section.id}", self.player, mw)
            mw.regions.append(region)
            library.connect(region, f"Open Section {section.id}")
            for series in section.series:
                for chapter in range(series.volumes):
                    loc_name = _book_name(section.id, series.name, chapter)
                    region.locations.append(LibrarianLocation(
                        self.player, loc_name,
                        self.location_name_to_id.get(loc_name), region))
            sec_name = section_completion_name(section.id)
            region.locations.append(LibrarianLocation(
                self.player, sec_name,
                self.location_name_to_id.get(sec_name), region))

        active_floors = {s.floor for s in self.active_sections}
        active_floor_locs = [
            loc for loc in _floor_locations
            if (loc.name == "Floor 1 Complete" and 1 in active_floors)
            or (loc.name == "Floor 2 Complete" and 2 in active_floors)
        ]
        # Level-ups + book-completion milestones within the active book count.
        active_levelup_locs = [
            loc for idx, loc in enumerate(_levelup_locations)
            if data.XP_CURVE[idx] <= max_books
        ]
        active_book_completion_locs = [
            loc for idx, loc in enumerate(_book_completion_locations)
            if BOOK_COMPLETION_THRESHOLDS[idx] <= max_books
        ]
        for category in (active_floor_locs, active_levelup_locs,
                         _chest_locations, active_book_completion_locs):
            for loc_data in category:
                library.locations.append(LibrarianLocation(
                    self.player, loc_data.name,
                    self.location_name_to_id.get(loc_data.name), library))

        goal_loc = LibrarianLocation(self.player, GOAL_LOCATION_NAME, None, library)
        library.locations.append(goal_loc)
        goal_loc.place_locked_item(LibrarianItem(
            VICTORY_ITEM_NAME, ItemClassification.progression, None, self.player
        ))

    # ------------------------------------------------------------------
    # create_items — pool sized to fit real-locations, with precollect
    # ------------------------------------------------------------------

    def create_items(self) -> None:
        if self.book_sanity:
            self._create_items_book()
            return

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

        # unlock_mode == individual_series_unlocks: every series is its own item.
        individual = self.individual
        if individual and self.options.goal.value == self.options.goal.option_custom:
            raise ValueError(
                "Librarian: unlock_mode individual_series_unlocks does not support "
                "goal: custom (v1.2.0). Use goal: full, floor_1, or floor_2."
            )

        precollect_names: list[str] = []
        if individual:
            # Individual mode starts with every bookcase open. Precollecting all
            # shelf unlocks collapses each row rule from `has(shelf, n) AND
            # has(series, 1)` down to `has(series, 1)`, so rows become depth-1 and
            # the shared cross-player fill of the series stays flat instead of
            # swap-storming on the shelf co-requirement (its `has(shelf, n)` term
            # flips false mid-fill as shared shelf copies get placed elsewhere).
            # It also frees the shelf slots into filler; the count-gated locations
            # are kept off the progression fill by an item-rule ban (set_rules) and
            # back-filled with filler + useful, so ~all series circulate cross-world.
            for _name, _qty in ITEM_QUANTITIES.items():
                if _name.startswith("Progressive Shelf Unlock ("):
                    _sid = _name[len("Progressive Shelf Unlock ("):-1]
                    if _sid in active_ids:
                        precollect_names.extend([_name] * _qty)
            precollect_names.extend(
                series_unlock_item_name(s) for s in self.starting_series)
        else:
            precollect_names.append(shelf_unlock_name(self.starting_section))
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
                if individual:
                    continue  # grouped item unused; per-series items added below
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
        if individual:
            # One item per ACTIVE series (self.series_order == all active series).
            for s in self.series_order:
                quantities[series_unlock_item_name(s)] = 1

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

        # Major Magic: keep one copy per reachable level (levels_kept). At the
        # full goal that is all 45, so every skill reaches its max and every
        # skill's Mastery is earnable; the goal requires mm >= levels_kept
        # (set_rules) so no copy is redundant progression weight. levels_kept
        # self-limits for floor/custom goals, and the excess-drop below trims
        # the pool down to it; filler fills the freed slots to keep per-player
        # |items| == |locations|.
        major_magic_names = (
            "Progressive Sort", "Progressive Shelf Guide",
            "Progressive Insight", "Progressive Auto-Shelving",
            "Progressive Assemble",
        )
        levels_kept = self._levels_kept(self.max_reachable_rows)
        max_major_magic_needed = levels_kept
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

        # Buffs + traps go in every mode's pool, replacing filler (fewer boring items scatter to
        # other players); per-skill Mastery gating lives in the helper. In individual/book mode
        # these useful/trap items back-fill the count-gated locations (kept off the progression
        # fill by the item-rule ban). BookSanity injects its own copy in _create_items_book.
        for _bt_name, _bt_qty in _buffs_traps_quantities().items():
            quantities[_bt_name] = _bt_qty

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
                # Still over (or nothing to lift -- individual mode has no Progressive Series
                # Unlock). Magic + Mastery + Fatigue + bag items are all useful/trap now (optional),
                # so drop the surplus from them to fit the smaller goal; magic first (most numerous).
                for name in (list(major_magic_names)
                             + list(_buffs_traps_quantities().keys())):
                    if excess <= 0:
                        break
                    take = min(quantities.get(name, 0), excess)
                    if take:
                        quantities[name] -= take
                        excess -= take
            if excess > 0:
                raise ValueError(
                    f"Pool overshoots target locations ({target}) by {excess} "
                    f"even after lifting Series Unlocks and dropping optional "
                    f"buffs. This config is fundamentally impossible — use a "
                    f"less restrictive goal."
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

    # Deep (count-gated) location categories: each is reachable only once many
    # distinct series are held. Leaving them as progression targets in the shared
    # cross-player fill makes it swap-storm, so individual mode forbids advancement
    # items on them via _ban_advancement_on_deep (set_rules); AP then back-fills
    # them with filler + useful items and progression routes only into shallow rows.
    _DEEP_CATEGORIES = frozenset((
        LibrarianLocationCategory.LEVEL_UP,
        LibrarianLocationCategory.ROW_COMPLETION,
        LibrarianLocationCategory.SECTION,
        LibrarianLocationCategory.FLOOR,
    ))

    def pre_fill(self) -> None:
        """Keep this world's filler in-world before the cross-player fill.

        The deep count-gated locations (level-ups, row/book completions, section
        and floor completions) are routed out of AP's swap-prone progression fill
        by an item-rule ban applied in set_rules for individual/book modes
        (_ban_advancement_on_deep). AP's remaining_fill then back-fills them with
        filler + useful items, so progression only ever routes into the shallow
        depth-1 rows/books; grouped keeps them as ordinary progression targets.
        pre_fill's only remaining job is the local-filler pass."""
        self._place_local_filler()

    def _ban_advancement_on_deep(self, deep_categories) -> None:
        """Forbid advancement items on this player's deep count-gated locations so
        AP's progression fill skips them natively: Location.can_fill checks
        item_rule before (and short-circuits) the access rule, so a series/book
        item is rejected here without ever evaluating feasible_rows and no
        swap-storm forms. The locations stay DEFAULT, so AP's remaining_fill still
        fills them with filler + useful items (magic can land on level-ups). This
        replaces the old hand-rolled deep-lock pre_fill."""
        p = self.player
        ban = lambda item: not item.advancement
        for loc in self.multiworld.get_unfilled_locations(p):
            data = location_dictionary.get(loc.name)
            if data is not None and data.category in deep_categories:
                add_item_rule(loc, ban)

    def _place_local_filler(self) -> None:
        """local_filler (default on): keep our filler in our own world by
        pre-placing it on our own unfilled locations before the cross-player fill,
        so it doesn't flood other slots; real items still circulate.

        Done here rather than via options.local_items because local_items lets the
        greedy remaining_fill strand our filler on an all-tight multiworld. We keep
        a margin of our locations open so the cross-fill always has reachable slots
        for progression. No-op solo and when the option is off. Filler is
        non-logical, so a locked filler placement can't make anything unreachable."""
        if not self.options.local_filler or self.multiworld.players <= 1:
            return
        mw = self.multiworld
        p = self.player
        filler_items = [it for it in mw.itempool
                        if it.player == p
                        and it.classification == ItemClassification.filler]
        if not filler_items:
            return
        n_prog = sum(1 for it in mw.itempool if it.player == p and it.advancement)
        own_unfilled = list(mw.get_unfilled_locations(p))
        # Place filler on the DEEPEST (latest-reachable) of our locations and leave
        # the SHALLOWEST open, so the cross-fill still has early reachable slots to
        # bootstrap the series/shelf progression chain. Random placement here
        # starves fill (a filler on an early row blocks the sphere-0 route).
        # Depth proxy: count-gated / completion locations are the deepest; a row's
        # depth is its series' unlock order (later series = deeper). Ties broken
        # deterministically so a seed is reproducible.
        rng_key = {loc: i for i, loc in enumerate(sorted(own_unfilled, key=lambda l: l.name))}
        def _depth(loc):
            cat = (location_dictionary[loc.name].category
                   if loc.name in location_dictionary else None)
            if cat == LibrarianLocationCategory.ROW:
                series = loc.name.split(" - ", 1)[-1]
                return (0, self.series_req.get(series, 0), rng_key[loc])
            if cat == LibrarianLocationCategory.CHEST:
                return (0, -1, rng_key[loc])          # chests: shallowest
            return (1, 0, rng_key[loc])               # count-gated: deepest
        own_unfilled.sort(key=_depth, reverse=True)   # deepest first
        # Keep the shallowest (own progression + 20% headroom) OPEN for the fill.
        keep_open = min(len(own_unfilled), n_prog + len(own_unfilled) // 5)
        placeable = own_unfilled[:len(own_unfilled) - keep_open]
        n_place = min(len(filler_items), len(placeable))
        for i in range(n_place):
            mw.itempool.remove(filler_items[i])
            placeable[i].place_locked_item(filler_items[i])

    # Deep count-gated categories banned from advancement in book_sanity (see
    # _ban_advancement_on_deep).
    _DEEP_CATEGORIES_BOOK = frozenset((
        LibrarianLocationCategory.LEVEL_UP,
        LibrarianLocationCategory.BOOK_COMPLETION,
        LibrarianLocationCategory.SECTION,
        LibrarianLocationCategory.FLOOR,
    ))

    def _create_items_book(self) -> None:
        """BookSanity item pool: every book is its own item. Every bookcase is
        precollected (all shelves open -> book locations are depth-1), plus the
        starting series' books. Pool = the other book items + Major Magic
        (capped) + filler padded to the location count."""
        mw = self.multiworld
        if self.options.goal.value == self.options.goal.option_custom:
            raise ValueError(
                "Librarian: book_sanity does not support goal: custom (v1.2.0). "
                "Use goal: full, floor_1, or floor_2.")
        if self.options.goal.value == self.options.goal.option_full:
            print("[Librarian] BookSanity + full goal (~3072 book checks): "
                  "generation's spoiler-playthrough step is quadratic in item "
                  "count and will be slow. A floor goal (floor_1/floor_2) "
                  "generates several times faster with ~1500 checks.")

        target = sum(len(r.locations) for r in mw.regions
                     if r.player == self.player) - 1
        active_ids = self.active_section_ids

        # Precollect all shelf unlocks (every bookcase open) + starting books.
        precollect_names: list[str] = []
        for name, qty in ITEM_QUANTITIES.items():
            if name.startswith("Progressive Shelf Unlock ("):
                sid = name[len("Progressive Shelf Unlock ("):-1]
                if sid in active_ids:
                    precollect_names.extend([name] * qty)
        starting_book_names = self.starting_book_names
        precollect_names.extend(starting_book_names)
        for name in precollect_names:
            mw.push_precollected(self.create_item(name))

        # One item per active book, minus the precollected starters.
        starting_ct: dict[str, int] = {}
        for n in starting_book_names:
            starting_ct[n] = starting_ct.get(n, 0) + 1
        pool_items: list[LibrarianItem] = []
        for (_ai, chapter, _sid, series_name) in self.active_books:
            n = book_item_name(series_name, chapter)
            if starting_ct.get(n, 0) > 0:
                starting_ct[n] -= 1
                continue
            pool_items.append(self.create_item(n))

        # Major Magic: keep one per reachable level (levels_kept), like the row
        # path; the goal requires mm >= levels_kept so none is redundant.
        levels_kept = self._levels_kept(self.max_reachable_books)
        max_major_magic = levels_kept
        magic_q = {n: ITEM_QUANTITIES.get(n, 0) for n in _MAJOR_MAGIC_NAMES}
        excess = sum(magic_q.values()) - max_major_magic
        while excess > 0:
            drop = max(_MAJOR_MAGIC_NAMES, key=lambda n: magic_q.get(n, 0))
            if magic_q.get(drop, 0) <= 0:
                break
            magic_q[drop] -= 1
            excess -= 1
        for name, qty in magic_q.items():
            for _ in range(qty):
                pool_items.append(self.create_item(name))

        # Buffs + traps, same as the other modes (replaces filler). Mastery gated on the capped
        # magic counts above.
        for bt_name, bt_qty in _buffs_traps_quantities().items():
            for _ in range(bt_qty):
                pool_items.append(self.create_item(bt_name))

        filler_needed = target - len(pool_items)
        if filler_needed < 0:
            # Overshoot relief (mirrors the row path): drop surplus optional items
            # -- Major Magic, then buffs/traps -- all non-book, non-progression, so
            # dropping them never affects winnability. Book items are never dropped.
            drop_set = set(_MAJOR_MAGIC_NAMES) | set(_buffs_traps_quantities().keys())
            excess = -filler_needed
            kept: list[LibrarianItem] = []
            for it in reversed(pool_items):
                if excess > 0 and it.name in drop_set:
                    excess -= 1
                    continue
                kept.append(it)
            pool_items = list(reversed(kept))
            filler_needed = target - len(pool_items)
            if filler_needed < 0:
                raise ValueError(
                    f"Librarian: book_sanity pool overshoots target by "
                    f"{-filler_needed} even after dropping optional buffs "
                    f"(target={target}, pool={len(pool_items)}). Use a less "
                    f"restrictive goal.")
        for i in range(filler_needed):
            f = _filler_items[i % len(_filler_items)]
            pool_items.append(self.create_item(f.name))

        mw.itempool.extend(pool_items)

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

    # feasible_rows cache invalidation (individual_series_items mode). Any
    # collect/remove of one of this player's progression items bumps an O(1)
    # per-state stamp that _set_rules_individual's feasible_rows caches on, so its
    # dependent rules share one O(held) compute per state. Airtight: any relevant
    # mutation changes the stamp, so a matching stamp means prog is unchanged.
    # Grouped seeds never read the stamp -- a harmless unused increment there.
    def collect(self, state, item, *args, **kwargs) -> bool:
        changed = super().collect(state, item, *args, **kwargs)
        if changed:
            sd = state.__dict__
            name = item.name
            if self._is_book_sanity:
                # book_sanity: feasible_books is an O(1) counter; section_done is
                # uncached (and rarely called -- section/floor locs hold FILLER,
                # so advancement sweeps skip them), so the general stamp is
                # unused here -- skip its per-collect bump entirely.
                if name.startswith("Book: "):
                    bk = self._bookcount_key
                    sd[bk] = sd.get(bk, 0) + 1
            else:
                sk = self._stamp_key
                sd[sk] = sd.get(sk, 0) + 1
                if name.startswith(_SERIES_ITEM_PREFIX):
                    sc = self._seriescount_key
                    sd[sc] = sd.get(sc, 0) + 1
        return changed

    def remove(self, state, item, *args, **kwargs) -> bool:
        changed = super().remove(state, item, *args, **kwargs)
        if changed:
            sd = state.__dict__
            name = item.name
            if self._is_book_sanity:
                if name.startswith("Book: "):
                    bk = self._bookcount_key
                    sd[bk] = sd.get(bk, 0) - 1
            else:
                sk = self._stamp_key
                sd[sk] = sd.get(sk, 0) + 1
                if name.startswith(_SERIES_ITEM_PREFIX):
                    sc = self._seriescount_key
                    sd[sc] = sd.get(sc, 0) - 1
        return changed

    # ------------------------------------------------------------------
    # set_rules (individual_series_items mode)
    # ------------------------------------------------------------------

    def _set_rules_individual(self) -> None:
        """Access rules when every series is its own item. Row/section/floor/
        goal rules check `has(series item, 1)` instead of a grouped
        Progressive-Series-Unlock count threshold. Kept separate from the
        grouped set_rules so the default path is byte-for-byte untouched.

        feasible_rows here can't use the grouped (series_count, shelf_sum) cache
        marker -- with independent per-series items it's no longer a complete key
        (different series sets can share a sum). It iterates only held items to
        stay O(held) rather than O(all series)."""
        mw = self.multiworld
        p = self.player
        active_sections = self.active_sections
        shelf_req = self.shelf_req

        shelf_names = {sec.id: shelf_unlock_name(sec.id) for sec in active_sections}

        # Per-state mutation stamp (bumped in collect/remove); used by section_done's
        # cache below.
        stamp_key = f"_librarian_stamp_{p}"

        # feasible_rows = number of distinct series items this player holds. Every
        # bookcase is precollected (create_items), so has(shelf, shelf_req) is always
        # true and a row is finishable iff its series item is held. Maintained as an
        # O(1) incremental counter in collect/remove (carried across copy() by
        # _librarian_carry_state), exactly like book_sanity's feasible_books.
        seriescount_key = self._seriescount_key

        def feasible_rows(state) -> int:
            return state.__dict__.get(seriescount_key, 0)

        # Precompute per-section requirements (shelf name, bookcase count, and the
        # series item names) so section_done does no string-formatting per call.
        section_reqs = {
            sec.id: (
                shelf_names[sec.id],
                sec.bookcase_count,
                [series_unlock_item_name(ser.name) for ser in sec.series],
            )
            for sec in active_sections
        }
        secdone_key = f"_librarian_secdone_indiv_{p}"

        def section_done(state, sec) -> bool:
            # Stamp-cached per section (goal/floor/section-completion rules all
            # call this; goal iterates every section). Same O(1) invalidation as
            # feasible_rows: a matching stamp means prog is unchanged.
            stamp = state.__dict__.get(stamp_key, 0)
            cache = state.__dict__.get(secdone_key)
            if cache is None or cache[0] != stamp:
                cache = (stamp, {})
                state.__dict__[secdone_key] = cache
            memo = cache[1]
            r = memo.get(sec.id)
            if r is not None:
                return r
            shelf_name, bc, series_items = section_reqs[sec.id]
            r = state.has(shelf_name, p, bc)
            if r:
                for iname in series_items:
                    if not state.has(iname, p, 1):
                        r = False
                        break
            memo[sec.id] = r
            return r

        # Section region access + per-row + section-completion rules.
        for section in active_sections:
            entrance = mw.get_entrance(f"Open Section {section.id}", p)
            entrance.access_rule = (
                lambda state, sname=shelf_names[section.id]:
                state.has(sname, p, 1)
            )

            for series in section.series:
                item_name = series_unlock_item_name(series.name)

                # Shelves all precollected -> has(shelf) always true; gate on series only.
                def make_row_rule(iname):
                    return lambda state: state.prog_items[p][iname] >= 1
                row_loc = mw.get_location(f"Shelf: {section.id} - {series.name}", p)
                row_loc.access_rule = make_row_rule(item_name)

            sec_loc = mw.get_location(section_completion_name(section.id), p)
            sec_loc.access_rule = (
                lambda state, sec=section: section_done(state, sec)
            )

        # Floor completions.
        floor_sections: dict[int, list] = {}
        for sec in active_sections:
            floor_sections.setdefault(sec.floor, []).append(sec)
        for floor_n, sections_in_floor in floor_sections.items():
            floor_loc = mw.get_location(f"Floor {floor_n} Complete", p)

            def make_floor_rule(secs):
                def rule(state):
                    for s in secs:
                        if not section_done(state, s):
                            return False
                    return True
                return rule
            floor_loc.access_rule = make_floor_rule(sections_in_floor)

        # Level-up rules — only for level-up locations that were created.
        max_rows = self.max_reachable_rows
        for level_n in range(1, data.MAX_PLAYER_LEVEL + 1):
            if data.XP_CURVE[level_n - 1] > max_rows:
                continue  # location was not created
            rows_needed = data.XP_CURVE[level_n - 1]
            loc = mw.get_location(f"Reached Level {level_n}", p)
            loc.access_rule = (
                lambda state, n=rows_needed: feasible_rows(state) >= n
            )

        # Row-completion milestones (only created for the deep-chain opt-in).
        if self._keep_row_completions():
            for thresh in ROW_COMPLETION_THRESHOLDS:
                if thresh > max_rows:
                    continue  # location was not created
                loc = mw.get_location(f"Complete {thresh} Rows", p)
                loc.access_rule = (lambda state, n=thresh: feasible_rows(state) >= n)

        # Goal — full / floor only (custom is rejected in create_items): every
        # active section fully cleared. Equivalent to feasible_rows == total rows:
        # every row finishable means every series is held AND its shelf_req is met,
        # and since each section's max shelf_req equals its bookcase_count, every
        # bookcase is open too -> every section done. Reuses the cached
        # feasible_rows instead of iterating every section x section_done.
        total_active_rows = sum(len(sec.series) for sec in active_sections)
        goal = mw.get_location(GOAL_LOCATION_NAME, p)
        goal.access_rule = (
            lambda state, n=total_active_rows: feasible_rows(state) >= n
        )

        self._ban_advancement_on_deep(self._DEEP_CATEGORIES)

        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    # ------------------------------------------------------------------
    # set_rules — access rules per region/location
    # ------------------------------------------------------------------

    def _set_rules_book(self) -> None:
        """Access rules for BookSanity. Each book location needs only its own
        book item (all shelves precollected -> depth-1). Count-gated locations
        (level-ups, 'Complete N Books', section/floor completions, goal) gate on
        feasible_books = number of distinct held book items (all placeable)."""
        mw = self.multiworld
        p = self.player
        active_sections = self.active_sections

        # Per-section book-item lists (section completion needs them all) + the
        # global set of active book-item names (feasible_books membership test).
        section_book_items: dict[str, list[str]] = {}
        all_book_item_names: set[str] = set()
        for sec in active_sections:
            names = [book_item_name(ser.name, ch)
                     for ser in sec.series for ch in range(ser.volumes)]
            section_book_items[sec.id] = names
            all_book_item_names.update(names)

        stamp_key = f"_librarian_stamp_{p}"
        fb_cache_key = f"_librarian_feasible_books_{p}"
        secdone_key = f"_librarian_secdone_book_{p}"

        # feasible_books = the incremental book counter maintained in
        # collect/remove (carried across copy() by _librarian_carry_state). O(1)
        # per call instead of O(held) -- the top fill hotspot.
        bookcount_key = self._bookcount_key

        def feasible_books(state) -> int:
            return state.__dict__.get(bookcount_key, 0)

        # Uncached: book_sanity skips the per-collect general-stamp bump (see
        # collect), and section/floor locations hold FILLER so advancement
        # sweeps skip them -- section_done is only hit by get_all_state / the
        # verify sweep, so an O(section-books) recompute is cheap overall.
        def section_done_book(state, sid) -> bool:
            prog = state.prog_items[p]
            for iname in section_book_items[sid]:
                if prog.get(iname, 0) < 1:
                    return False
            return True

        # Per-book locations (depth-1) + section completions. The rule inlines
        # has() (state.prog_items[p][n] >= 1); this lambda is evaluated a huge
        # number of times per fill, so skipping the method call is a real win.
        for sec in active_sections:
            for ser in sec.series:
                for ch in range(ser.volumes):
                    iname = book_item_name(ser.name, ch)
                    loc = mw.get_location(_book_name(sec.id, ser.name, ch), p)
                    loc.access_rule = (
                        lambda state, n=iname: state.prog_items[p][n] >= 1)
            sec_loc = mw.get_location(section_completion_name(sec.id), p)
            sec_loc.access_rule = (
                lambda state, sid=sec.id: section_done_book(state, sid))

        # Floor completions.
        floor_sections: dict[int, list[str]] = {}
        for sec in active_sections:
            floor_sections.setdefault(sec.floor, []).append(sec.id)
        for floor_n, sids in floor_sections.items():
            floor_loc = mw.get_location(f"Floor {floor_n} Complete", p)

            def make_floor(ids):
                def rule(state):
                    for sid in ids:
                        if not section_done_book(state, sid):
                            return False
                    return True
                return rule
            floor_loc.access_rule = make_floor(sids)

        # Level-ups (only those created) + book-completion milestones.
        max_books = self.max_reachable_books
        for level_n in range(1, data.MAX_PLAYER_LEVEL + 1):
            if data.XP_CURVE[level_n - 1] > max_books:
                continue
            loc = mw.get_location(f"Reached Level {level_n}", p)
            loc.access_rule = (
                lambda state, n=data.XP_CURVE[level_n - 1]:
                feasible_books(state) >= n)

        for thresh in BOOK_COMPLETION_THRESHOLDS:
            if thresh > max_books:
                continue
            loc = mw.get_location(f"Complete {thresh} Books", p)
            loc.access_rule = (lambda state, n=thresh: feasible_books(state) >= n)

        total_active_books = sum(s.volume_count for s in active_sections)
        goal = mw.get_location(GOAL_LOCATION_NAME, p)
        goal.access_rule = (
            lambda state, n=total_active_books: feasible_books(state) >= n)
        self._ban_advancement_on_deep(self._DEEP_CATEGORIES_BOOK)
        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    def set_rules(self) -> None:
        # opt-in: book_sanity / per-series items use separate rules paths so the
        # (default) grouped path below stays untouched.
        if self.book_sanity:
            self._set_rules_book()
            return
        if self.individual:
            self._set_rules_individual()
            return
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

        # Level-up access rules — only for level-up locations that were actually
        # created (create_regions drops ones beyond max_reachable_rows). Gate is
        # feasible_rows(state) >= XP_CURVE[N-1]; magic never gates a level-up
        # (feasible_rows never modelled magic).
        max_rows = self.max_reachable_rows
        for level_n in range(1, data.MAX_PLAYER_LEVEL + 1):
            if data.XP_CURVE[level_n - 1] > max_rows:
                continue  # location was not created
            rows_needed = data.XP_CURVE[level_n - 1]
            loc = mw.get_location(f"Reached Level {level_n}", p)
            loc.access_rule = (
                lambda state, n=rows_needed: feasible_rows(state) >= n
            )

        # Book-placement milestones were dropped (see create_regions); no
        # access_rule loop needed here.

        # Row-completion milestones. Each fires when the player has
        # correctly completed N total rows. Reachable when feasible_rows
        # (the same per-series item-availability check we already use)
        # is at least N. feasible_rows is cached, so the 200 rules share
        # one underlying computation per state.
        if self._keep_row_completions():
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
            goal.access_rule = (
                lambda state, n=threshold: feasible_rows(state) >= n)
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

        # BookSanity (book_sanity) maps. Keyed by "<series_name>|<chapter>", NOT
        # by AssetIdx: the apworld's asset index (ALL_SERIES order) need not match
        # the game's in-actor AssetIdx, but the SERIES NAME does (the client
        # resolves an actor's game-AssetIdx -> series name via _asset_to_series,
        # exactly as the row checks do). Empty when book_sanity is off.
        #   book_location_map["<series>|<chapter>"] -> AP location id: fired when
        #     that book is placed correctly.
        #   book_item_to_book["Book: <series> Vol N"] -> [series, chapter]: the
        #     book the client un-hides when it receives the item.
        book_location_map: dict[str, int] = {}
        book_item_to_book: dict[str, list] = {}
        book_completion_map: dict[str, int] = {}
        goal_book_threshold = 0
        if self.book_sanity:
            active_sids = self.active_section_ids
            for (asset_idx, chapter, sid, series_name) in data.ALL_BOOKS:
                if sid not in active_sids:
                    continue
                loc_id = self.location_name_to_id.get(
                    _book_name(sid, series_name, chapter))
                if loc_id is not None:
                    book_location_map[f"{series_name}|{chapter}"] = loc_id
                book_item_to_book[book_item_name(series_name, chapter)] = \
                    [series_name, chapter]
            max_books = self.max_reachable_books
            for thresh in BOOK_COMPLETION_THRESHOLDS:
                if thresh <= max_books:
                    bc_id = self.location_name_to_id.get(f"Complete {thresh} Books")
                    if bc_id is not None:
                        book_completion_map[str(thresh)] = bc_id
            if goal_value == self.options.goal.option_floor_1:
                goal_book_threshold = sum(
                    s.volume_count for s in data.SECTIONS if s.floor == 1)
            elif goal_value == self.options.goal.option_floor_2:
                goal_book_threshold = sum(
                    s.volume_count for s in data.SECTIONS if s.floor == 2)
            else:
                goal_book_threshold = sum(s.volume_count for s in data.SECTIONS)

        return {
            # Build label sent to the Lua client (matches main.lua MOD_VERSION); Lua
            # parses only the numeric X.Y.Z for its warding-rule gate, any pre-release
            # suffix is informational. NOT the AP world version -- that one
            # (archipelago.json:world_version) must be clean semver so AP can parse it
            # for YAML `requires: game:` checks (a suffix there reads as 0.0.0).
            "version": "1.2.0-beta3",
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
            # booksanity: the individual books precollected at start (random subset;
            # count = sum of starting_series_count rolled 3/5/10 sizes). Empty for
            # other modes. Emitted so Universal Tracker can reconstruct the seed.
            "starting_books": self.starting_book_names,
            "starting_series_count": self.options.starting_series_count.value,
            "series_per_unlock": self.options.series_per_unlock.value,
            "series_order": self.series_order,
            # Derived from unlock_mode for the Lua client (unchanged contract).
            # When 1, each series is its own item and the client resolves an
            # unlocked series from series_item_to_series instead of the
            # series_order prefix. Empty map when off.
            "individual_series_items": int(self.individual),
            "series_item_to_series": (
                {series_unlock_item_name(s): s for s in self.series_order}
                if self.individual else {}
            ),
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
            # fires when every row in the section is complete. May be
            # absent on old seeds; Lua treats a missing key as "no
            # section-completion firing".
            "section_location_map": section_location_map,
            # str(floor) → AP location id for "Floor N Complete". Lua
            # fires when every row in the floor's active sections is
            # complete. Active-goal floors only. May be absent on old
            # seeds; Lua falls back to a static FLOOR_IDX constant.
            "floor_location_map": floor_location_map,
            # Toggle: when 1, Lua wards a book unless BOTH its series and
            # its bookcase are unlocked. When 0 (default), only series
            # unlock matters.
            "only_unward_shelfable_books": int(self.options.only_unward_shelfable_books.value),
            # We don't create book-placement milestone locations (see
            # create_regions), so this ships empty and Lua's milestone-fire
            # loop is a no-op. The key is kept (empty, not dropped) so the
            # Lua-side counter infrastructure still parses it.
            "milestone_thresholds": [],
            # Lua tracks correctly-completed rows and fires each threshold.
            "row_completion_thresholds": (
                list(ROW_COMPLETION_THRESHOLDS) if self._keep_row_completions() else []),
            # Turns on the client skill-tuning system: Mastery items extend a maxed skill along
            # the game's curve, Fatigue traps hit a skill with a timed debuff. All modes.
            "attunement": 1,
            # Turns on the client book-capacity system: "+2/+3 Book Capacity" items re-apply the
            # game's bag grants each load (capacity resets past 15). All modes.
            "bag_capacity": 1,
            # Locked-series book appearance, from the BookVisibility option.
            # "hidden" (default) = invisible + non-grabbable; "stacks" =
            # visible-but-non-grabbable (collision off, walk through). The Lua
            # client gates ALL hiding on this == "hidden"; in "stacks" it only
            # disables collision, so none of the hide-path edge cases apply.
            "book_visibility": self.options.book_visibility.current_key,
            # BookSanity. When 1, every book is its own item AND check.
            # The client fires book_location_map["<AssetIdx>|<Chapter>"] when
            # that book is placed correctly, un-hides book_item_to_book[<item>]
            # on receiving a book item, and fires book_completion_map on the
            # cumulative correctly-placed-book count. Empty maps when off.
            "book_sanity": int(self.book_sanity),
            "book_location_map": book_location_map,
            "book_item_to_book": book_item_to_book,
            "book_completion_map": book_completion_map,
            "book_completion_thresholds": (
                [t for t in BOOK_COMPLETION_THRESHOLDS
                 if t <= self.max_reachable_books]
                if self.book_sanity else []),
            # Book count at which the client sends STATUS_GOAL (floor goals);
            # 0/full lets the game's EndGame fire it.
            "goal_book_threshold": goal_book_threshold,
        }
