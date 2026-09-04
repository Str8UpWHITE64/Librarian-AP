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

from typing import Any, ClassVar
import bisect
from bisect import bisect_right as _bisect_right
import math

from BaseClasses import MultiWorld, Region, Tutorial, ItemClassification, CollectionState
from worlds.AutoWorld import World, WebWorld
from worlds.generic.Rules import set_rule, add_rule, add_item_rule
from Fill import fill_restrictive, FillError, sweep_from_pool
from Options import OptionError

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
from .Options import LibrarianOptions, LibrarianSettings, option_groups

# Item names used as constants below (avoids typos)
ITEM_PROG_SERIES  = "Progressive Series Unlock"
ITEM_PROG_BUNDLE  = "Progressive Book Bundle"

# The 5 Major Magic item names. Used by create_items/_create_items_book to size
# and cap the Major Magic pool; they no longer gate any location (feasible_rows
# never modelled magic).
# A TUPLE, not a set: this is iterated, and max() over it breaks ties by iteration order.
# Python randomises string hashing per process, so a set here picked a different skill to
# trim whenever two were tied -- the same seed generating a different pool run to run.
_MAJOR_MAGIC_NAMES = (
    "Progressive Sort", "Progressive Shelf Guide", "Progressive Insight",
    "Progressive Auto-Shelving", "Progressive Assemble",
)

# Prefix of every individual series-unlock item name (Items.series_unlock_item_name).
_SERIES_ITEM_PREFIX = "Series Unlock: "


_SKILL_NAMES = ("Sort", "Shelf Guide", "Insight", "Auto-Shelving", "Assemble")


def _trap_names() -> list:
    """Fatigue items, the only trap category. First to be dropped when the pool overshoots."""
    return [f"Fatigue: {n}" for n in _SKILL_NAMES]


def _mastery_names() -> list:
    """Skill Mastery items -- useful, but they only extend a skill already at its native max,
    so they are the cheapest useful thing to lose before the bag and base magic."""
    return [f"{n} Mastery" for n in _SKILL_NAMES]


def _buffs_traps_quantities() -> dict:
    """{item_name: qty} for the buff/trap items every mode adds: Skill Mastery (useful), Fatigue
    (trap), and Book Capacity (useful). Every skill gets its full 5-item Mastery set -- the pool now
    keeps all Major Magic so each skill maxes, and the client treats Mastery as extra skill levels
    past the native max. Fatigue (bites at any level) and the bag items always go in too."""
    q: dict = {}
    for name in _SKILL_NAMES:
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


def section_unlock_name(section_id: str) -> str:
    return f"Section Unlock ({section_id})"


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
    option_groups = option_groups
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
    settings: ClassVar[LibrarianSettings]
    web = LibrarianWeb()
    topology_present = True
    required_client_version = (0, 5, 0)

    item_name_to_id = LibrarianItem.get_name_to_id()
    location_name_to_id = LibrarianLocation.get_name_to_id()
    item_name_groups = item_name_groups
    location_name_groups = location_name_groups

    # Per-seed state populated in generate_early().
    series_order: list[str]
    book_order: list[str]
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
    def enabled_skills(self) -> tuple:
        """Magic skills this seed may hand out, in the canonical order.

        Ordered, never a set: what survives here decides pool contents, and set order is
        not stable between processes. UT-aware, since options hold defaults on a re-gen."""
        pt = self._ut_passthrough()
        if pt and "magic_skills_enabled" in pt:
            keep = set(pt["magic_skills_enabled"])
        else:
            keep = set(self.options.magic_skills_enabled.value)
        return tuple(n for n in _SKILL_NAMES if n in keep)

    def _optional_quantities(self) -> dict:
        """The buff/trap block, minus anything belonging to a skill that is turned off."""
        return self._drop_disabled_skills(dict(_buffs_traps_quantities()))

    def _enabled_magic_names(self) -> tuple:
        """Progressive item names for the skills this seed keeps."""
        return tuple(f"Progressive {n}" for n in self.enabled_skills)

    def _drop_disabled_skills(self, quantities: dict) -> dict:
        """Strip every item belonging to a skill the player turned off.

        Magic is useful and never gates anything, so this cannot affect logic; each pool
        builder pads back to the location count with filler afterwards."""
        keep = self.enabled_skills
        for name in _SKILL_NAMES:
            if name in keep:
                continue
            for item in (f"Progressive {name}", f"{name} Mastery", f"Fatigue: {name}"):
                quantities.pop(item, None)
        return quantities

    @property
    def goal_value(self) -> int:
        """The goal this seed was built with.

        Options hold DEFAULTS during a tracker re-gen, so reading options.goal there makes
        the tracker model a full-library run for a seed that was actually floor or custom.
        slot_data carries it; the passthrough wins whenever it is present."""
        pt = self._ut_passthrough()
        if pt and "goal" in pt:
            return int(pt["goal"])
        return int(self.options.goal.value)

    @property
    def active_sections(self) -> list[data.Section]:
        pt = getattr(self.multiworld, "re_gen_passthrough", {}).get(
            "Librarian Tidy Up the Arcane Library", {}
        )
        if pt and "goal" in pt:
            v = pt["goal"]
        else:
            v = self.goal_value
        if v == self.options.goal.option_floor_1:
            return [s for s in data.SECTIONS if s.floor == 1]
        if v == self.options.goal.option_floor_2:
            return [s for s in data.SECTIONS if s.floor == 2]
        if v == self.options.goal.option_custom:
            # UT re-gen: unlike the floor goals, this set is a seeded roll and cannot be
            # re-derived from the options, so fill_slot_data emits it and we read it back.
            ids = pt.get("active_sections") if pt else None
            if ids:
                keep = set(ids)
                return [s for s in data.SECTIONS if s.id in keep]
            return self._custom_active_sections()
        return list(data.SECTIONS)

    def _custom_active_sections(self) -> list[data.Section]:
        """Sections kept for a custom goal: enough to cover the goal plus
        spare_book_item_percent slack, and no more.

        A custom goal only needs its own count, so every section past that is surplus --
        checks that still hold items, and in a multiworld can hold another game's
        progression, which then waits on a check this player has no reason to do. Trimming
        the world is what stops that, rather than trying to force those checks to filler:
        in individual/booksanity every series IS a check, so there is no filler to move
        there anyway.

        Whole sections only. A partially included section could never complete its section
        check, and the same whole-section shape is what the floor goals already rely on.
        Measured in books under booksanity and rows otherwise, matching what that mode's
        goal actually counts.
        """
        cached = getattr(self, "_custom_sections_cache", None)
        if cached is not None:
            return cached

        # Counted the way the seed CHECKS, not the way it unlocks: a custom goal of 200 on a
        # by-book seed means 200 books, and trimming the seed by rows there would leave it
        # holding sections the goal never reaches.
        book_mode = not self.check_by_series
        if book_mode:
            need = self.options.custom_goal_book_count.value
            size = lambda s: s.volume_count
        else:
            need = self.options.custom_goal_row_count.value
            size = lambda s: s.shelf_count
        library_total = sum(size(s) for s in data.SECTIONS)
        # Clamp to the library. Both the goal itself and the slack can be asked for beyond what
        # exists -- 400 rows plus 10% is 440 -- and an uncapped target just means "keep
        # everything" while reading like a real number in logs and in the section maths.
        need = min(need, library_total)
        target = min(
            math.ceil(need * (1 + self._ut_opt("spare_book_item_percent",
                                                self.options.spare_book_item_percent) / 100)),
            library_total,
        )

        pool = list(data.SECTIONS)
        self.random.shuffle(pool)
        kept, total = [], 0
        for sec in pool:
            if total >= target:
                break
            kept.append(sec)
            total += size(sec)
        if not kept:                      # target 0 cannot leave an empty world
            kept = [pool[0]]
        # Restore declaration order so section/floor grouping downstream is stable.
        keep_ids = {s.id for s in kept}
        kept = [s for s in data.SECTIONS if s.id in keep_ids]
        self._custom_sections_cache = kept
        return kept

    @property
    def active_section_ids(self) -> set[str]:
        return {s.id for s in self.active_sections}

    @property
    def max_reachable_rows(self) -> int:
        """Rows this seed actually contains: the bound for the level-up + milestone
        filter in create_regions.

        Just the rows in the active sections, for every goal. It used to answer the
        player's chosen row count under a custom goal, which stopped being true once
        2.0.2 began trimming the seed: it claimed 200 rows while the world held about
        60, so create_regions made level locations nothing could reach and generation
        failed its accessibility check. active_sections is already the trimmed,
        UT-aware set, so deriving from it cannot drift again."""
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
                == self.options.unlock_mode.option_individual_book_unlocks)

    @property
    def random_bundle(self) -> bool:
        """random_book_bundle: books arrive in fungible Progressive Book Bundle items.

        The unlock granularity is coarse, the CHECK granularity is still per-book -- which is
        the whole point of the mode. Book locations therefore come from book_checks, not from
        book_sanity."""
        pt = self._ut_passthrough()
        if pt and "random_bundle" in pt:
            return bool(pt["random_bundle"])
        return (self.options.unlock_mode.value
                == self.options.unlock_mode.option_random_book_bundle)

    @property
    def bookcase_unlocks(self) -> int:
        """How bookcases open: progressive (0), whole section (1), or already open (2).

        The two individual unlock modes force "unlocked": series mode precollects the
        bookcases so its ~400 shared series items stay a flat depth-1 fill, and book mode
        is slow enough to generate already."""
        if self.individual or self.book_sanity:
            return self.options.bookcase_unlocks.option_unlocked
        return int(self._ut_opt("bookcase_unlocks", self.options.bookcase_unlocks))

    def _slow_to_generate(self) -> str:
        """Name the option shape that makes generation slow, or "" if this one is fine.

        Measured with the spoiler on (the default): individual_book_unlocks on the full
        goal is about 70s solo, and the paring step grows faster than the player count.
        The other big pools are not the problem -- individual series with booksanity is
        11s solo and 12s for three players -- because the cost follows the number of
        advancement items, and only this shape has 3072 of them."""
        if (self.book_sanity
                and self.options.goal.value == self.options.goal.option_full):
            return "unlock_mode: individual_book_unlocks on goal: full"
        return ""

    def _shelf_gate(self, sid: str, series_name: str) -> tuple[str, int]:
        """The item and count that open the bookcase holding one row.

        Every rule asks here rather than reaching for shelf_req directly, so the three
        bookcase modes differ in one place instead of in every access rule. Under "whole"
        a section is a single item, so a row's requirement collapses to one copy; under
        "unlocked" the requirement is zero, which state.has answers true for.
        """
        mode = self.bookcase_unlocks
        opt = self.options.bookcase_unlocks
        if mode == opt.option_whole:
            return section_unlock_name(sid), 1
        if mode == opt.option_unlocked:
            return shelf_unlock_name(sid), 0
        return shelf_unlock_name(sid), self.shelf_req[(sid, series_name)]

    def _section_gate(self, sec) -> tuple[str, int]:
        """The item and count that open a WHOLE section (its last bookcase included)."""
        mode = self.bookcase_unlocks
        opt = self.options.bookcase_unlocks
        if mode == opt.option_whole:
            return section_unlock_name(sec.id), 1
        if mode == opt.option_unlocked:
            return shelf_unlock_name(sec.id), 0
        return shelf_unlock_name(sec.id), sec.bookcase_count

    @property
    def check_by_series(self) -> bool:
        """check_mode=by_series: a completed row is the check. Any unlock mode."""
        pt = self._ut_passthrough()
        if pt:
            if "check_by_series" in pt:
                return bool(pt["check_by_series"])
            # A seed seeded before the check axis existed. Options hold DEFAULTS during a
            # tracker re-gen, not the player's yaml, so falling through to them would call
            # every pre-3.0.0 seed by_book and rebuild it with the wrong locations. Back
            # then the rule was simply: books check per book, everything else per row.
            return not bool(pt.get("book_sanity"))
        return (self.options.check_mode.value
                == self.options.check_mode.option_series)

    @property
    def check_by_count(self) -> bool:
        """check_mode=by_count: checks are cumulative book-count ticks. Any unlock mode."""
        pt = self._ut_passthrough()
        if pt:
            # Absent means the seed predates by_count, which nothing could have been.
            return bool(pt.get("check_by_count", 0))
        return (self.options.check_mode.value
                == self.options.check_mode.option_count)

    @property
    def count_ticks(self) -> list[int]:
        """The cumulative book counts this seed checks at, clamped to fit the pool.

        The interval is a preference: too fine and the ticks outnumber the bundles that
        have to fill them, so it widens until the pool fits, the same way the bundle size
        and the spare settings do."""
        total = sum(s.volume_count for s in self.active_sections)
        step = max(1, self._ut_opt("check_interval", self.options.check_interval))
        per = max(1, self._ut_opt("books_per_bundle", self.options.books_per_bundle))

        # There has to be at least one tick per item the pool will hold, or the seed has
        # more items than checks. A wide interval is the failure case here, not a narrow
        # one, so this clamps the interval DOWN until the ticks can hold the pool.
        #
        # How many items that is depends on the UNLOCK mode, which this used to ignore: it
        # always estimated the bundle pool, so a seed unlocking one item per series asked
        # for a few dozen ticks to hold a few hundred items and overshot.
        n_series = sum(len(sec.series) for sec in self.active_sections)
        if self.individual:
            unlocks = n_series
        elif self.random_bundle:
            unlocks = math.ceil(total / per)
        elif self.book_sanity:
            unlocks = total
        else:
            unlocks = math.ceil(n_series / max(1, self._ut_opt(
                "series_per_unlock", self.options.series_per_unlock)))
        # Bookcases share the pool too, unless they all start open.
        if self.bookcase_unlocks != self.options.bookcase_unlocks.option_unlocked:
            unlocks += sum(
                q for nm, q in ITEM_QUANTITIES.items()
                if nm.startswith("Progressive Shelf Unlock (")
                and nm[nm.index("(") + 1:-1] in self.active_section_ids)
        need = (unlocks
                + sum(self._optional_quantities().values())
                + len(_MAJOR_MAGIC_NAMES) * 10)
        # Fitting the pool is not enough when the unlocks are a chain. Every rung of the
        # ladder needs series (or bundles) AND their bookcases, so the chain of paired
        # items is deep, and a deep chain against a ladder with no slack deadlocks the
        # fill: the early links end up with no reachable rung left to sit on. Measured on
        # the full goal at series_per_unlock 3 and 4, seeds fail below about 2.1 ticks
        # per chain item and pass from 2.5; bundles at 8 per item failed 7 of 20 at 1.4.
        # The individual modes hand out one specific item per series or book, no chain,
        # so they keep the plain fit.
        if not (self.individual or self.book_sanity):
            need = max(need, math.ceil(unlocks * 2.5))
        step = min(step, max(1, total // max(1, need)))
        return list(range(step, total + 1, step))

    @property
    def book_checks(self) -> bool:
        """Does this seed check per BOOK? That is the check axis alone, whatever unlocks.

        booksanity reaches this the same way every other unlock mode does: it is only ever
        paired with by_book, because 3072 book items cannot fit into any smaller set of
        checks. generate_early rejects the other two pairings outright."""
        return not self.check_by_series and not self.check_by_count

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
        """Total books in the active-goal scope. Drives the book-completion filter and
        a booksanity custom goal -- NOT the level-up filter, which is row-counted like
        XP_CURVE and uses max_reachable_rows in every mode."""
        return sum(s.volume_count for s in self.active_sections)

    def _levels_kept(self, max_reachable: int) -> int:
        """How many player levels are reachable given `max_reachable` rows/books
        (how many XP_CURVE thresholds fit). Single source of truth for BOTH the
        Major Magic pool size (create_items) and the goal's magic requirement
        (set_rules), so they cannot drift.

        ALWAYS pass ROWS, in every mode. XP_CURVE counts rows finished, and levels are
        earned by finishing rows whether or not books are the items. This used to say
        "books for book_sanity", and passing 3072 where 400 was meant kept the full magic
        pool and put every level in logic at once. At the full goal this is
        MAX_PLAYER_LEVEL (45); it self-limits for floor/custom goals."""
        return sum(1 for idx in range(data.MAX_PLAYER_LEVEL)
                   if data.XP_CURVE[idx] <= max_reachable)


    # ------------------------------------------------------------------
    # Universal Tracker integration
    # ------------------------------------------------------------------

    # Lets UT generate this world without a YAML; the slot_data passthrough
    # carries everything needed to reconstruct the seed's state.
    ut_can_gen_without_yaml = True

    def _ut_opt(self, key: str, option):
        """Read an option the way generation saw it, not the way this run was configured.

        Under a Universal Tracker re-gen the options object holds DEFAULTS -- the player's
        yaml is not replayed -- so anything derived from options silently describes a
        different seed than the one being tracked. slot_data carries the real values, so
        prefer those whenever a passthrough is present.
        """
        pt = self._ut_passthrough()
        if pt and key in pt:
            try:
                return int(pt[key])
            except (TypeError, ValueError):
                pass
        return option.value

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
        self._validate_modes()
        # How many books each series unlock is worth. Series hold 3, 5 or 10 volumes, so a
        # book count cannot be derived from a row count -- collect/remove carries this sum
        # the same way it carries the row count.
        self._series_item_volumes = {
            series_unlock_item_name(ser.name): ser.volumes
            for sec in self.active_sections for ser in sec.series
        }
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
            self.book_order = list(pt.get("book_order", []))
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
        # random_book_bundle: the order bundles hand books out in. Seeded, so it must ride
        # slot_data for the client and for a tracker re-gen -- there is no way to re-derive it.
        self.book_order = []
        if self.random_bundle:
            shuffled = [(sid, book_item_name(name, ch))
                        for (_ai, ch, sid, name) in self.active_books]
            rng.shuffle(shuffled)
            # Lead with the sections that start open. Bundles draw library-wide, so an
            # unbiased order spends the first bundles on books scattered across sections
            # the player cannot open yet: sphere 0 ends up with nowhere to put anything
            # and the fill has no reachable spot for its first item. Everything after the
            # opening stretch stays in shuffled order, so the mode is still library-wide.
            start = {self.starting_section, self.starting_section_b} - {None}
            self.book_order = ([b for sid, b in shuffled if sid in start]
                               + [b for sid, b in shuffled if sid not in start])
            if self.check_by_series:
                self.book_order = self._spread_series_completions(rng, start)

        self.starting_book_names = []
        if self.book_sanity:
            n_books = sum(rng.choice((3, 5, 10))
                          for _ in range(self.options.starting_series_count.value))
            all_books = [book_item_name(name, ch)
                         for (_ai, ch, _sid, name) in self.active_books]
            rng.shuffle(all_books)
            self.starting_book_names = all_books[:min(n_books, len(all_books))]

    def _spread_series_completions(self, rng, start_sections) -> list[str]:
        """Bundle order for bundle+series: series finish at a steady rate.

        A row check needs every volume of its series, so under bundles a row opens when
        its LAST volume arrives. In a plain shuffle the last of 3 to 10 volumes sits near
        the end for almost every series, so almost every row needs almost every bundle and
        the fill has nowhere to put the first two hundred items. This keeps each bundle
        library-wide but schedules the closing volume of each series at an even spacing
        through the order, with its other volumes anywhere before it: the k-th row opens
        around the k-th share of the bundles, the shape the progressive chain already has.
        Starting sections' series go first so sphere 0 has rows to open."""
        series = [(sec.id, ser) for sec in self.active_sections for ser in sec.series]
        rng.shuffle(series)
        series.sort(key=lambda t: t[0] not in start_sections)   # stable: keeps the shuffle
        n_books = sum(ser.volumes for _sid, ser in series)
        order: list = [None] * n_books
        free = list(range(n_books))          # free slot indices, ascending
        n_series = len(series)
        for i, (_sid, ser) in enumerate(series):
            close_at = min(n_books - 1, int((i + 1) * n_books / n_series) - 1)
            # closing volume at the nearest free slot at or before its scheduled point
            # (or the first free one after, if the run-up is already full)
            k = _bisect_right(free, close_at) - 1
            if k < 0:
                k = 0
            close_slot = free.pop(k)
            vols = list(range(ser.volumes))
            rng.shuffle(vols)
            order[close_slot] = book_item_name(ser.name, vols[0])
            for ch in vols[1:]:
                # anywhere earlier: an uneven spread here keeps the bundles mixed
                upto = _bisect_right(free, close_slot)
                j = rng.randrange(upto) if upto > 0 else 0
                order[free.pop(j)] = book_item_name(ser.name, ch)
        assert None not in order
        return order

    def _keep_row_completions(self) -> bool:
        """Whether to create the 72 'Complete N Rows' checks this seed.

        They are only needed as fill-routing surface for the deepest series chain
        (grouped mode, series_per_unlock <= 3). Every looser config generates fine
        without them, so we drop all 72 (fewer filler items) except for the P<=3
        deep-chain opt-in.

        Only a seed whose checks ARE rows has them: the by-book and by-count layouts
        build a different set of locations entirely, and asking for a row milestone there
        looked one up that was never created."""
        if not self.check_by_series or self.individual:
            return False
        return self.options.series_per_unlock.value <= 3

    # ------------------------------------------------------------------
    # create_regions — Menu → Library → 31 section regions
    # ------------------------------------------------------------------

    def _validate_modes(self) -> None:
        """Settle the option shapes that cannot generate as asked.

        Pairings that cannot be filled are switched to the check mode that can hold them
        and say so, the way the interval and the bundle size already adjust; a YAML should
        generate rather than bounce for a pairing the seed can settle itself. Only two
        things still refuse: a pool no goal can hold, and a shape the host has not allowed.

        A UT re-gen reads its shape from slot_data, which by definition already generated,
        so it is not re-validated."""
        if self._ut_passthrough():
            return
        # Shapes that are slow to generate are the host's call, not the player's: the
        # spoiler's playthrough paring grows faster than linearly in advancement items,
        # and every player in the lobby waits on it. The gate lives in host.yaml under
        # librarian_options, so a host who is fine with the wait can lift it.
        if (self._slow_to_generate()
                and not getattr(self.settings, "allow_individual_book_unlocks", False)):
            raise OptionError(
                f"[Librarian - '{self.player_name}'] {self._slow_to_generate()} is slow to "
                f"generate and is off by default. The host can allow it by setting "
                f"librarian_options: allow_individual_book_unlocks: true in host.yaml. "
                f"Otherwise pick a floor or custom goal, or a different unlock mode."
            )
        # Every book its own item only fits when every book is also a check: ~3072 items
        # cannot go into ~400 rows or a few hundred count ticks. Bundles are drawn from
        # the whole library, so a row fills only once nearly every bundle has arrived and
        # the fill cannot route it. Both settle to booksanity, the check mode built for
        # book-shaped unlocks.
        opt = self.options.check_mode
        if self.book_sanity and self.check_by_series:
            print(f"[Librarian - '{self.player_name}'] unlock_mode: individual_book_unlocks "
                  f"gives every book its own item, and ~3072 items cannot sit in ~400 row "
                  f"checks; using check_mode: booksanity instead of series.")
            opt.value = opt.option_booksanity
        # The count ladder with a deep series chain. Every rung needs series and their
        # bookcases together, and at series_per_unlock 3 or 4 on the full library the fill
        # deadlocks on a share of seeds however dense the ladder is made (measured: 4/50 at
        # 2.5 ticks per chain item, 2/50 at 3), while 5 is 50 for 50. So count mode reads
        # the option as "at least 5": the seed adjusts, the way it adjusts the interval
        # and the bundle size, and the option's text says so. Done here, before anything
        # derives from the value, so slot_data and the tracker see the clamped number.
        if self.check_by_count and self.options.series_per_unlock.value < 5:
            print(f"[Librarian - '{self.player_name}'] check_mode: count needs "
                  f"series_per_unlock of at least 5; using 5 instead of "
                  f"{self.options.series_per_unlock.value}.")
            self.options.series_per_unlock.value = 5

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        library = Region("Library", self.player, self.multiworld)
        self.multiworld.regions.extend([menu, library])
        menu.connect(library, "Enter Library")

        active_ids = self.active_section_ids

        if self.check_by_count:
            self._create_regions_count(library)
            return
        if self.book_checks:
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

    def _create_regions_count(self, library) -> None:
        """check_mode=by_count layout: no per-book or per-row checks, just the cumulative
        ticks plus the usual section/floor/level/chest meta.

        Every tick name is predefined in Locations.py, so a seed creates only the multiples
        of its own interval and leaves the rest of the band unused."""
        mw = self.multiworld
        for n in self.count_ticks:
            name = f"Shelved {n} Books"
            library.locations.append(LibrarianLocation(
                self.player, name, self.location_name_to_id.get(name), library))

        for section in self.active_sections:
            region = Region(f"Section {section.id}", self.player, mw)
            mw.regions.append(region)
            library.connect(region, f"Open Section {section.id}")
            sec_name = section_completion_name(section.id)
            region.locations.append(LibrarianLocation(
                self.player, sec_name,
                self.location_name_to_id.get(sec_name), region))

        active_floors = {s.floor for s in self.active_sections}
        max_rows = self.max_reachable_rows
        for category in (
            [loc for loc in _floor_locations
             if (loc.name == "Floor 1 Complete" and 1 in active_floors)
             or (loc.name == "Floor 2 Complete" and 2 in active_floors)],
            [loc for idx, loc in enumerate(_levelup_locations)
             if data.XP_CURVE[idx] <= max_rows],
            _chest_locations,
        ):
            for loc_data in category:
                library.locations.append(LibrarianLocation(
                    self.player, loc_data.name,
                    self.location_name_to_id.get(loc_data.name), library))

        goal_loc = LibrarianLocation(self.player, GOAL_LOCATION_NAME, None, library)
        library.locations.append(goal_loc)
        goal_loc.place_locked_item(LibrarianItem(
            VICTORY_ITEM_NAME, ItemClassification.progression, None, self.player))

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
        if self.random_bundle:
            self._create_items_bundle()
            return
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
        per_unlock = self._ut_opt("series_per_unlock", self.options.series_per_unlock)

        # Precollect: one shelf unlock for each of the two starting sections
        # + N starting-series worth of Progressive Series Unlock items.
        #
        # Two DIFFERENT sections (vs two bookcases in one section) is what
        # broadens sphere-1 fill flexibility — AP fill can route progression
        # through items that gate either section's rows. Multiple bookcases
        # in one section all gate behind the same shelf-unlock chain.
        starting_count = self._ut_opt("starting_series_count",
                                      self.options.starting_series_count)
        starting_unlock_count = math.ceil(starting_count / per_unlock)

        # unlock_mode == individual_series_unlocks: every series is its own item.
        individual = self.individual

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
        elif self.bookcase_unlocks == self.options.bookcase_unlocks.option_unlocked:
            # Every bookcase open from the start: precollect the lot and keep them out of
            # the pool, where they would only be dead copies taking filler slots.
            for _name, _qty in ITEM_QUANTITIES.items():
                if _name.startswith("Progressive Shelf Unlock ("):
                    _sid = _name[len("Progressive Shelf Unlock ("):-1]
                    if _sid in active_ids:
                        precollect_names.extend([_name] * _qty)
            precollect_names.extend([ITEM_PROG_SERIES] * starting_unlock_count)
        else:
            # One opened section to start, whichever item shape opens it.
            precollect_names.append(self._section_gate(
                next(s for s in self.active_sections if s.id == self.starting_section))[0])
            if self.starting_section_b is not None:
                precollect_names.append(self._section_gate(
                    next(s for s in self.active_sections
                         if s.id == self.starting_section_b))[0])
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
                # Match on section id; drop if not in active set, or if this seed opens
                # bookcases some other way and these would be dead copies.
                section_id = name[len("Progressive Shelf Unlock ("):-1]
                if (section_id in active_ids and self.bookcase_unlocks
                        == self.options.bookcase_unlocks.option_progressive):
                    quantities[name] = qty
            elif name.startswith("Section Unlock ("):
                section_id = name[len("Section Unlock ("):-1]
                if (section_id in active_ids and self.bookcase_unlocks
                        == self.options.bookcase_unlocks.option_whole):
                    quantities[name] = qty
                # else: skip
            else:
                quantities[name] = qty
        if individual:
            # One item per ACTIVE series (self.series_order == all active series).
            for s in self.series_order:
                quantities[series_unlock_item_name(s)] = 1

        # Spare unlock copies, paid for out of filler (the pool is padded to the location
        # count, so raising these lowers filler by the same amount).
        #
        # A full or floor goal needs every series in its scope, which means a single unlock
        # sitting in a stalled game can end the run. Extra copies make the requirement "most
        # of them" instead of "all of them", and cost nothing once the player is at the cap:
        # the client already clamps to the last series and the last bookcase.
        #
        # Grouped only, and deliberately so. These two items are interchangeable, so a spare
        # is worth something; in individual/booksanity every item is one specific series or
        # book, so a duplicate unlocks nothing. Custom goals get their slack from the seed
        # trimming instead, so they are left alone here.
        if (not individual and not self.book_sanity
                and self.goal_value != self.options.goal.option_custom):
            # Series unlocks scale as a PERCENTAGE: there are ~80 of them, so a share of
            # the whole reads sensibly.
            # The buff/trap items join the pool further down, so they have to be counted
            # or the estimate reads ~46 slots richer than the seed really is.
            def _free_slots():
                return (target - sum(quantities.values())
                        - sum(self._optional_quantities().values()))

            spare_pct = self._ut_opt("spare_book_item_percent",
                                     self.options.spare_book_item_percent)
            if spare_pct > 0 and quantities.get(ITEM_PROG_SERIES, 0) > 0:
                base = quantities[ITEM_PROG_SERIES]
                # Clamped like the shelf side. At the capped 20% this has never bound in
                # testing, but overshooting does not fail loudly -- the guard quietly lifts
                # Series Unlocks into the starting inventory -- so it should not be able to
                # happen at all if a later config change makes the pool tighter.
                quantities[ITEM_PROG_SERIES] = base + min(
                    math.ceil(base * spare_pct / 100), max(0, _free_slots()))

            # Shelf unlocks take a COUNT PER BOOKCASE instead. Sections hold as few as
            # three, so a percentage either rounds away to nothing or hands a small
            # section a disproportionate share; a flat per-bookcase count gives every
            # section the same protection regardless of size.
            spare_shelf = self._ut_opt("spare_shelf_items",
                                       self.options.spare_shelf_items)
            shelf_base = sum(q for n, q in quantities.items()
                             if n.startswith("Progressive Shelf Unlock ("))
            # Clamp to what the seed can actually hold. Each step costs one item per
            # bookcase -- 71 slots at the full goal -- and asking for more than the free
            # slots does not fail loudly: the overshoot guard quietly lifts Series Unlocks
            # into the starting inventory, handing out free series nobody asked for. How
            # much room there is depends on the goal and on series_per_unlock, so a fixed
            # maximum would be wrong for one config or the other; this reduces the step
            # count until it fits, and says so.
            headroom = _free_slots()
            asked = spare_shelf
            while spare_shelf > 0 and shelf_base * spare_shelf > headroom:
                spare_shelf -= 1
            if spare_shelf < asked:
                print(f"[Librarian] spare_shelf_items {asked} does not fit this seed "
                      f"({headroom} free item slots, {shelf_base} bookcases); "
                      f"using {spare_shelf}.")
            if spare_shelf > 0:
                for name in list(quantities):
                    if name.startswith("Progressive Shelf Unlock ("):
                        base = quantities[name]
                        if base > 0:
                            quantities[name] = base + base * spare_shelf

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
        major_magic_names = self._enabled_magic_names()
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
        for _bt_name, _bt_qty in self._optional_quantities().items():
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
                # so drop the surplus from them to fit the smaller goal.
                #
                # Order is deliberate, worst-to-keep first. It used to run magic first "(most
                # numerous)", which meant a trimmed goal stripped Progressive Insight and friends
                # while keeping every Fatigue trap -- a smaller seed made of debuffs. Traps go
                # first now, then the extras that only extend an already-maxed skill, then the bag,
                # and base magic last since that is what makes a skill work at all.
                for name in (_trap_names()
                             + _mastery_names()
                             + ["+2 Book Capacity", "+3 Book Capacity"]
                             + list(major_magic_names)):
                    if excess <= 0:
                        break
                    take = min(quantities.get(name, 0), excess)
                    if take:
                        quantities[name] -= take
                        excess -= take
            if excess > 0:
                raise OptionError(
                    f"Librarian: the item pool overshoots this goal's {target} checks "
                    f"by {excess} even after lifting Series Unlocks into the start and "
                    f"dropping optional items. Raise the custom goal.")

        self._drop_disabled_skills(quantities)   # magic the player turned off
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

    def _create_items_bundle(self) -> None:
        """random_book_bundle pool: fungible Progressive Book Bundle items, one per
        books_per_bundle books in scope, plus the usual optional block and filler.

        Deliberately the same shape as the grouped series chain -- one repeated item, a
        count gate on the locations -- because that is the shape AP's fill handles best and
        the one this world already proves at 400 locations. The only difference is that it
        gates ~3000 book checks instead of 400 row checks.
        """
        mw = self.multiworld
        target = sum(len(r.locations) for r in mw.regions
                     if r.player == self.player) - 1

        n_books = len(self.book_order)
        per = max(1, self._ut_opt("books_per_bundle", self.options.books_per_bundle))

        # Clamp the bundle size UP until the pool fits the checks this seed offers. A small
        # bundle wants more items than a by_series seed has room for -- 3072 books at 5 per
        # bundle is 615 items against ~554 row checks -- and the size is a preference, not a
        # constraint worth failing generation over.
        # A tracker re-gen already knows the answer: slot_data carries the size the seed
        # actually used. Re-deriving it here can land somewhere else and rebuild a world
        # handing out books in different groups than the one being tracked.
        pt = self._ut_passthrough()
        if pt and "books_per_bundle" in pt:
            self.books_per_bundle_effective = per
            self._finish_bundle_pool(per, math.ceil(n_books / per), target)
            return

        asked = per
        # The bookcase unlocks share this pool, so they come out of the head room too --
        # without them the clamp lets books_per_bundle sit low enough that bundles plus
        # bookcases outnumber the checks.
        shelf_pool = sum(
            q for nm, q in ITEM_QUANTITIES.items()
            if (nm.startswith("Progressive Shelf Unlock (")
                and self.bookcase_unlocks == self.options.bookcase_unlocks.option_progressive
                or nm.startswith("Section Unlock (")
                and self.bookcase_unlocks == self.options.bookcase_unlocks.option_whole)
            and nm[nm.index("(") + 1:-1] in self.active_section_ids)
        head_room = (target - sum(self._optional_quantities().values())
                     - len(_MAJOR_MAGIC_NAMES) * 10 - shelf_pool)
        # Two ceilings. The pool has to fit the checks, and -- when the bookcases are gated
        # too -- the bundle chain has to stay short enough to interleave with them. Books
        # are drawn library-wide, so a book needs its bundle AND its bookcase; at small
        # bundle sizes that conjunction leaves the fill with nowhere reachable to place the
        # next item. Measured: with bookcases open every size fills, with them gated the
        # small sizes fail, seed-dependently rather than at a clean threshold.
        # Rows as the checks need a shorter chain still: a row opens on its closing
        # volume, so the bundle chain and the bookcase chain interleave at every row.
        # Measured on the full goal with progressive bookcases: 154 bundles fail 4 of
        # 10, 110 or fewer fill 10 of 10.
        chain_div = 5 if self.check_by_series else 3
        chain_cap = (max(1, target // chain_div)
                     if self.bookcase_unlocks != self.options.bookcase_unlocks.option_unlocked
                     else n_books)
        while per < n_books and (math.ceil(n_books / per) > max(1, head_room)
                                 or math.ceil(n_books / per) > chain_cap):
            per += 1
        if per != asked:
            print(f"[Librarian] books_per_bundle {asked} needs "
                  f"{math.ceil(n_books / asked)} bundles, more than this seed can place "
                  f"alongside its bookcase unlocks; using {per}.")
        self.books_per_bundle_effective = per
        self._finish_bundle_pool(per, math.ceil(n_books / per), target)

    def _finish_bundle_pool(self, per: int, needed: int, target: int) -> None:
        """Build the bundle pool once the size is settled, whether this seed clamped it or
        a tracker re-gen read it back from slot_data."""
        mw = self.multiworld
        n_books = len(self.book_order)
        quantities: dict[str, int] = {ITEM_PROG_BUNDLE: needed}
        # Bookcases unlock progressively here too. Without these the mode generated fine and
        # was unplayable: no shelf unlock ever arrived, so no bookcase ever opened.
        active_ids = self.active_section_ids
        bmode = self.bookcase_unlocks
        bopt = self.options.bookcase_unlocks
        for _name, _qty in ITEM_QUANTITIES.items():
            is_shelf = _name.startswith("Progressive Shelf Unlock (")
            is_section = _name.startswith("Section Unlock (")
            if not (is_shelf or is_section):
                continue
            _sid = _name[_name.index("(") + 1:-1]
            if _sid not in active_ids:
                continue
            if is_shelf and bmode == bopt.option_progressive:
                quantities[_name] = _qty
            elif is_section and bmode == bopt.option_whole:
                quantities[_name] = _qty
            elif is_shelf and bmode == bopt.option_unlocked:
                for _ in range(_qty):
                    mw.push_precollected(self.create_item(_name))
        for bt_name, bt_qty in self._optional_quantities().items():
            quantities[bt_name] = bt_qty
        magic_keep = self._levels_kept(self.max_reachable_rows)
        for nm in self._enabled_magic_names():
            quantities[nm] = min(ITEM_QUANTITIES.get(nm, 0), magic_keep)

        # Start the player off so sphere 0 is not empty: starting_series_count bundles.
        start_bundles = max(1, self._ut_opt("starting_series_count",
                                            self.options.starting_series_count) // per)
        start_bundles = min(start_bundles, needed)
        for _ in range(start_bundles):
            mw.push_precollected(self.create_item(ITEM_PROG_BUNDLE))
        quantities[ITEM_PROG_BUNDLE] = needed - start_bundles
        # Open the starting sections COMPLETELY, not just their first bookcase. Bundles
        # draw library-wide, so the early ones hand out books from everywhere; with only
        # one bookcase open there is almost nowhere to put them and the fill runs out of
        # reachable spots on the larger goals.
        if bmode != bopt.option_unlocked:
            for sid in (self.starting_section, self.starting_section_b):
                if not sid:
                    continue
                nm = (section_unlock_name(sid) if bmode == bopt.option_whole
                      else shelf_unlock_name(sid))
                for _ in range(quantities.get(nm, 0)):
                    quantities[nm] -= 1
                    mw.push_precollected(self.create_item(nm))

        self._drop_disabled_skills(quantities)   # magic the player turned off
        pool_items: list[LibrarianItem] = []
        for name, qty in quantities.items():
            for _ in range(max(0, qty)):
                pool_items.append(self.create_item(name))

        filler_needed = target - len(pool_items)
        if filler_needed < 0:
            raise OptionError(
                f"Librarian: random_book_bundle pool overshoots this goal's checks by "
                f"{-filler_needed}. Raise books_per_bundle or the custom goal.")
        for i in range(filler_needed):
            pool_items.append(self.create_item(_filler_items[i % len(_filler_items)].name))
        mw.itempool.extend(pool_items)

    def _create_items_book(self) -> None:
        """BookSanity item pool: every book is its own item. Every bookcase is
        precollected (all shelves open -> book locations are depth-1), plus the
        starting series' books. Pool = the other book items + Major Magic
        (capped) + filler padded to the location count."""
        mw = self.multiworld
        if self.goal_value == self.options.goal.option_full:
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
        levels_kept = self._levels_kept(self.max_reachable_rows)
        max_major_magic = levels_kept
        kept_magic = self._enabled_magic_names()
        magic_q = {n: ITEM_QUANTITIES.get(n, 0) for n in kept_magic}
        excess = sum(magic_q.values()) - max_major_magic
        while excess > 0 and kept_magic:
            drop = max(kept_magic, key=lambda n: magic_q.get(n, 0))
            if magic_q.get(drop, 0) <= 0:
                break
            magic_q[drop] -= 1
            excess -= 1
        for name, qty in magic_q.items():
            for _ in range(qty):
                pool_items.append(self.create_item(name))

        # Buffs + traps, same as the other modes (replaces filler). Mastery gated on the capped
        # magic counts above.
        for bt_name, bt_qty in self._optional_quantities().items():
            for _ in range(bt_qty):
                pool_items.append(self.create_item(bt_name))

        filler_needed = target - len(pool_items)
        if filler_needed < 0:
            # Overshoot relief (mirrors the row path): drop surplus optional items -- all
            # non-book, non-progression, so dropping them never affects winnability. Book
            # items are never dropped.
            #
            # Worst-to-keep order, same as the row path: traps, then the extras that only
            # extend an already-maxed skill, then the bag, then base magic. This used to walk
            # the pool backwards against an unordered set, so what survived depended on list
            # position rather than on whether the player was losing a debuff or their Insight
            # levels -- and a trimmed goal could leave a seed made largely of Fatigue.
            drop_order = (_trap_names() + _mastery_names()
                          + ["+2 Book Capacity", "+3 Book Capacity"]
                          + list(_MAJOR_MAGIC_NAMES))
            rank = {n: i for i, n in enumerate(drop_order)}
            droppable = sorted(
                (i for i, it in enumerate(pool_items) if it.name in rank),
                key=lambda i: rank[pool_items[i].name])
            remove = set(droppable[:-filler_needed])
            pool_items = [it for i, it in enumerate(pool_items) if i not in remove]
            filler_needed = target - len(pool_items)
            if filler_needed < 0:
                raise OptionError(
                    f"Librarian: individual_book_unlocks pool overshoots this goal's "
                    f"checks by {-filler_needed} even after dropping optional items "
                    f"(target={target}, pool={len(pool_items)}). Raise the custom goal.")
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
                    bk = self._bookcount_key
                    sd[bk] = sd.get(bk, 0) + self._series_item_volumes.get(name, 0)
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
                    bk = self._bookcount_key
                    sd[bk] = sd.get(bk, 0) - self._series_item_volumes.get(name, 0)
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

        # Books held, summed by collect/remove from each series' own volume count. Series
        # are 3, 5 or 10 volumes, so this cannot be feasible_rows scaled by an average.
        bookcount_key = self._bookcount_key

        def feasible_books(state) -> int:
            return state.__dict__.get(bookcount_key, 0)

        # Every bookcase is precollected in this mode, so a row costs exactly its series
        # item -- and a book costs the same, since nothing gates books individually here.
        def row_rule(_sec, ser):
            return lambda state, iname=series_unlock_item_name(ser.name): (
                state.prog_items[p][iname] >= 1)

        def book_rule(sec, ser, _ch):
            return row_rule(sec, ser)

        self._apply_check_locations(row_rule, book_rule, feasible_books)

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
        # custom: the same counter against the player's own row target, capped at what this
        # goal's sections actually hold so an over-large target cannot be unwinnable.
        # The goal counts whatever this seed checks: rows under check_mode series, books
        # otherwise. Both counters are exact, so neither needs a conversion.
        custom = self.goal_value == self.options.goal.option_custom
        if self.check_by_series:
            total_active_rows = sum(len(sec.series) for sec in active_sections)
            need = (min(self.options.custom_goal_row_count.value, total_active_rows)
                    if custom else total_active_rows)
            counter = feasible_rows
        else:
            total_active_books = sum(sec.volume_count for sec in active_sections)
            need = (min(self.options.custom_goal_book_count.value, total_active_books)
                    if custom else total_active_books)
            counter = feasible_books
        goal = mw.get_location(GOAL_LOCATION_NAME, p)
        goal.access_rule = (lambda state, n=need, f=counter: f(state) >= n)

        self._ban_advancement_on_deep(self._DEEP_CATEGORIES)

        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    # ------------------------------------------------------------------
    # set_rules — access rules per region/location
    # ------------------------------------------------------------------

    def _apply_check_locations(self, row_rule, book_rule, feasible_books) -> None:
        """Attach an unlock mode's requirements to whichever locations the check mode built.

        The unlock mode decides what it costs to reach a row or a book; the check mode
        decides which of those the seed actually checks. Splitting the two is the whole
        point of the 3.0.0 option matrix -- before this, each unlock mode hard-coded the
        row locations it expected and broke the moment another check mode ran.

        row_rule(sec, ser)        -> rule for completing that row
        book_rule(sec, ser, ch)   -> rule for shelving that book, or None to skip it
        feasible_books(state)     -> how many books the state can already shelve
        """
        mw, p = self.multiworld, self.player
        if self.check_by_count:
            for n in self.count_ticks:
                mw.get_location(f"Shelved {n} Books", p).access_rule = (
                    lambda state, k=n: feasible_books(state) >= k)
            return
        if self.check_by_series:
            for sec in self.active_sections:
                for ser in sec.series:
                    mw.get_location(f"Shelf: {sec.id} - {ser.name}", p).access_rule = (
                        row_rule(sec, ser))
            return
        for sec in self.active_sections:
            for ser in sec.series:
                for ch in range(ser.volumes):
                    rule = book_rule(sec, ser, ch)
                    if rule is None:
                        continue
                    mw.get_location(_book_name(sec.id, ser.name, ch), p).access_rule = rule

    def _set_rules_bundle(self) -> None:
        """random_book_bundle rules: each book check is gated on how many bundles the
        player holds, by that book's position in book_order.

        A count gate on one fungible item, which is the same shape as the grouped series
        chain -- not the per-item lookup booksanity uses. state.count is O(1) for a single
        name, so none of booksanity's caching machinery is needed here.
        """
        mw = self.multiworld
        p = self.player
        active_sections = self.active_sections

        per = getattr(self, "books_per_bundle_effective", None) or max(
            1, self._ut_opt("books_per_bundle", self.options.books_per_bundle))
        # book_order position -> bundles required to have reached it.
        need_at = {name: (idx // per) + 1 for idx, name in enumerate(self.book_order)}

        # How many bundles it takes to hold a whole series: the position of its LAST book.
        def series_need(ser) -> int:
            return max((need_at.get(book_item_name(ser.name, ch), 1)
                        for ch in range(ser.volumes)), default=1)

        total_books = sum(s.volume_count for s in active_sections)

        # Everything count-gated -- count rungs, milestones, levels, the goal -- reads how
        # many books the player can shelve, and that is NOT bundles x per: a held book only
        # counts once its bookcase is open. Reading the bundle count alone put "shelve 400
        # books" in logic for a player holding 57 bundles with six bookcases open and 180
        # books shelvable. Grouped by gate (one per section, or per row tier under
        # progressive bookcases) with the bundle positions of its books and rows sorted,
        # so a count is one bisect per gate rather than a walk of the library, and cached
        # on the state the way the progressive rules cache theirs.
        gates: dict[tuple[str, int], tuple[list[int], list[int]]] = {}
        for sec in active_sections:
            for ser in sec.series:
                books, rows = gates.setdefault(self._shelf_gate(sec.id, ser.name), ([], []))
                books.extend(need_at[book_item_name(ser.name, ch)]
                             for ch in range(ser.volumes)
                             if book_item_name(ser.name, ch) in need_at)
                rows.append(series_need(ser))
        gate_list = [(item, n, sorted(b), sorted(r)) for (item, n), (b, r) in gates.items()]
        gate_items = sorted({item for item, _, _, _ in gate_list})
        cache_attr = f"_librarian_bundle_feasible_{p}"

        def _feasible(state) -> tuple[int, int]:
            prog = state.prog_items[p]
            held = prog[ITEM_PROG_BUNDLE]
            marker = (held, tuple([prog[nm] for nm in gate_items]))
            cached = state.__dict__.get(cache_attr)
            if cached is not None and cached[0] == marker:
                return cached[1]
            books = rows = 0
            for item, n, bpos, rpos in gate_list:
                if n and prog[item] < n:
                    continue
                books += bisect.bisect_right(bpos, held)
                rows += bisect.bisect_right(rpos, held)
            state.__dict__[cache_attr] = (marker, (books, rows))
            return books, rows

        def feasible_books(state) -> int:
            return _feasible(state)[0]

        def feasible_rows(state) -> int:
            return _feasible(state)[1]

        # A book needs its bundle AND its bookcase. The bundle half stays a depth-1 count:
        # the chain is ordered, so "all of a series" is just its last book's position.
        for sec in active_sections:
            gname, _ = self._shelf_gate(sec.id, sec.series[0].name)
            mw.get_entrance(f"Open Section {sec.id}", p).access_rule = (
                lambda state, sname=gname: state.has(sname, p, 1))

        def row_rule(sec, ser):
            sname, sn = self._shelf_gate(sec.id, ser.name)
            return lambda state, k=series_need(ser), sname=sname, sn=sn: (
                state.count(ITEM_PROG_BUNDLE, p) >= k and state.has(sname, p, sn))

        def book_rule(sec, ser, ch):
            n = need_at.get(book_item_name(ser.name, ch))
            if n is None:
                return None
            sname, sn = self._shelf_gate(sec.id, ser.name)
            return lambda state, k=n, sname=sname, sn=sn: (
                state.count(ITEM_PROG_BUNDLE, p) >= k and state.has(sname, p, sn))

        self._apply_check_locations(row_rule, book_rule, feasible_books)

        # A section or floor is complete only with every one of its bookcases open, so
        # these carry the whole-section gate on top of the bundle count.
        for sec in active_sections:
            need = max((series_need(ser) for ser in sec.series), default=1)
            gitem, gn = self._section_gate(sec)
            mw.get_location(section_completion_name(sec.id), p).access_rule = (
                lambda state, k=need, gi=gitem, gn=gn: (
                    state.count(ITEM_PROG_BUNDLE, p) >= k and state.has(gi, p, gn)))

        floors: dict[int, list] = {}
        for sec in active_sections:
            floors.setdefault(sec.floor, []).append(sec)
        for fl, secs in floors.items():
            need = max((series_need(ser) for sec in secs for ser in sec.series), default=1)
            fgates = [self._section_gate(sec) for sec in secs]
            mw.get_location(f"Floor {fl} Complete", p).access_rule = (
                lambda state, k=need, gs=fgates: (
                    state.count(ITEM_PROG_BUNDLE, p) >= k
                    and all(state.has(gi, p, gn) for gi, gn in gs)))

        total_rows = sum(len(sec.series) for sec in active_sections)

        # The player levels up per ROW shelved, so the XP curve is compared against rows.
        # This used to scale it by an average books-per-row, which is the same rows-for-books
        # substitution that put the row-completion tracker out in 2.0.3.
        max_rows = self.max_reachable_rows
        for level_n in range(1, data.MAX_PLAYER_LEVEL + 1):
            if data.XP_CURVE[level_n - 1] > max_rows:
                continue
            mw.get_location(f"Reached Level {level_n}", p).access_rule = (
                lambda state, n=data.XP_CURVE[level_n - 1]: feasible_rows(state) >= n)

        if self.check_by_count:
            books_needed = (min(self.options.custom_goal_book_count.value, total_books)
                            if self.goal_value == self.options.goal.option_custom
                            else total_books)
            mw.get_location(GOAL_LOCATION_NAME, p).access_rule = (
                lambda state, n=books_needed: feasible_books(state) >= n)
        elif self.check_by_series:
            # Rows are the checks here, so the milestones and the goal are row-shaped too.
            if self._keep_row_completions():
                for idx, thresh in enumerate(ROW_COMPLETION_THRESHOLDS):
                    if thresh > total_rows:
                        continue
                    mw.get_location(f"Complete {thresh} Rows", p).access_rule = (
                        lambda state, n=thresh: feasible_rows(state) >= n)
            rows_needed = (min(self.options.custom_goal_row_count.value, total_rows)
                           if self.goal_value == self.options.goal.option_custom
                           else total_rows)
            mw.get_location(GOAL_LOCATION_NAME, p).access_rule = (
                lambda state, n=rows_needed: feasible_rows(state) >= n)
        else:
            max_books = self.max_reachable_books
            for thresh in BOOK_COMPLETION_THRESHOLDS:
                if thresh > max_books:
                    continue
                mw.get_location(f"Correctly shelve {thresh} books", p).access_rule = (
                    lambda state, n=thresh: feasible_books(state) >= n)

            books_needed = (min(self.options.custom_goal_book_count.value, total_books)
                            if self.goal_value == self.options.goal.option_custom
                            else total_books)
            mw.get_location(GOAL_LOCATION_NAME, p).access_rule = (
                lambda state, n=books_needed: feasible_books(state) >= n)
        self._ban_advancement_on_deep(self._DEEP_CATEGORIES_BOOK)
        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    def _set_rules_book(self) -> None:
        """Access rules for BookSanity. Each book location needs only its own
        book item (all shelves precollected -> depth-1). Count-gated locations
        (level-ups, 'Correctly shelve N books', section/floor completions, goal) gate on
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

        # Rows the player could actually FINISH: series whose every volume is held.
        #
        # Levels are earned by finishing rows, and XP_CURVE counts rows, so the level rules
        # cannot use feasible_books. Comparing a row threshold against a book count asked for
        # "254 books" where it meant 254 rows, and with 3072 books in play that put all 45
        # levels in sphere 1 -- a tracker would call the whole ladder reachable immediately.
        # Holding N books is not N rows: a row needs its whole set.
        #
        # Uncached for the same reason section_done_book is: level-ups are in
        # _DEEP_CATEGORIES_BOOK, so they hold filler and advancement sweeps skip them.
        series_book_items: list[list[str]] = [
            [book_item_name(ser.name, ch) for ch in range(ser.volumes)]
            for sec in active_sections for ser in sec.series
        ]

        def feasible_rows_book(state) -> int:
            prog = state.prog_items[p]
            done = 0
            for names in series_book_items:
                for iname in names:
                    if prog.get(iname, 0) < 1:
                        break
                else:
                    done += 1
            return done

        # Per-book locations (depth-1) + section completions. The rule inlines
        # has() (state.prog_items[p][n] >= 1); this lambda is evaluated a huge
        # number of times per fill, so skipping the method call is a real win.
        # Under count mode the checks are the count rungs instead, and every held book
        # can be shelved (all bookcases open), so a rung needs that many book items.
        if self.check_by_count:
            for n in self.count_ticks:
                mw.get_location(f"Shelved {n} Books", p).access_rule = (
                    lambda state, k=n: feasible_books(state) >= k)
        for sec in active_sections:
            if not self.check_by_count:
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

        # Level-ups (only those created) + book-completion milestones. The level filter
        # matches create_regions, which has always filtered on max_reachable_ROWS -- this
        # side filtered on books, so the two disagreed about which levels exist.
        #
        # Two units live here on purpose: levels count ROWS (XP_CURVE), the completion
        # milestones count BOOKS. Conflating them is exactly what broke this.
        max_rows = self.max_reachable_rows
        max_books = self.max_reachable_books
        for level_n in range(1, data.MAX_PLAYER_LEVEL + 1):
            if data.XP_CURVE[level_n - 1] > max_rows:
                continue
            loc = mw.get_location(f"Reached Level {level_n}", p)
            loc.access_rule = (
                lambda state, n=data.XP_CURVE[level_n - 1]:
                feasible_rows_book(state) >= n)

        if not self.check_by_count:      # count mode has rungs instead of milestones
            for thresh in BOOK_COMPLETION_THRESHOLDS:
                if thresh > max_books:
                    continue
                loc = mw.get_location(f"Correctly shelve {thresh} books", p)
                loc.access_rule = (lambda state, n=thresh: feasible_books(state) >= n)

        # custom counts BOOKS here, not rows: 400 rows hold 3072 books, so a row-shaped
        # target would end the run almost immediately. Capped at the goal's own book total.
        total_active_books = sum(s.volume_count for s in active_sections)
        if self.goal_value == self.options.goal.option_custom:
            books_needed = min(self.options.custom_goal_book_count.value, total_active_books)
        else:
            books_needed = total_active_books
        goal = mw.get_location(GOAL_LOCATION_NAME, p)
        goal.access_rule = (
            lambda state, n=books_needed: feasible_books(state) >= n)
        self._ban_advancement_on_deep(self._DEEP_CATEGORIES_BOOK)
        mw.completion_condition[p] = lambda state: state.has(VICTORY_ITEM_NAME, p)

    def set_rules(self) -> None:
        # opt-in: book_sanity / per-series items use separate rules paths so the
        # (default) grouped path below stays untouched.
        if self.random_bundle:
            self._set_rules_bundle()
            return
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
        shelf_names = {sec.id: self._section_gate(sec)[0] for sec in active_sections}
        section_series_reqs = {
            sec.id: tuple(series_req[s.name] for s in sec.series)
            for sec in active_sections
        }
        # Under "whole" a section is one item, so every row in it needs one copy and the
        # table below only has to model 0 or 1 -- the same shape, one bookcase wide.
        section_row_reqs = {
            sec.id: [
                (self._shelf_gate(sec.id, s.name)[1], series_req[s.name])
                for s in sec.series
            ]
            for sec in active_sections
        }
        # How many copies of the gate item a section can absorb: its bookcase count when
        # they arrive one at a time, one when the whole section is a single item.
        section_caps = {sec.id: self._section_gate(sec)[1] for sec in active_sections}
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
        # The same table counting BOOKS instead of rows, for check_mode by_count. Rows hold
        # 3, 5 or 10 volumes, so scaling a row count by an average is wrong in both
        # directions -- that guesswork is what put the level-up rules out by a wide margin.
        # Summing the real volume counts here costs one more precomputed table and nothing
        # per call.
        section_reach_books: dict[str, list[list[int]]] = {}
        for sec in active_sections:
            bc_count = section_caps[sec.id]
            row_reqs = section_row_reqs[sec.id]
            volumes = [ser.volumes for ser in sec.series]
            table_2d: list[list[int]] = []
            table_books: list[list[int]] = []
            for shelf_count in range(bc_count + 1):
                row_for_shelves: list[int] = [0] * (max_series_idx + 1)
                book_for_shelves: list[int] = [0] * (max_series_idx + 1)
                # Pass 1: per series_count, count how many series reqs
                # are met. Incremental — sort by series_n and run a
                # cumulative count.
                ready_at: list[tuple[int, int]] = []  # (series_n, volumes) that pass shelf
                for (shelf_n, series_n), vol in zip(row_reqs, volumes):
                    if shelf_count >= shelf_n:
                        ready_at.append((series_n, vol))
                ready_at.sort()
                idx = 0
                count_so_far = 0
                books_so_far = 0
                for series_count in range(max_series_idx + 1):
                    while idx < len(ready_at) and ready_at[idx][0] <= series_count:
                        count_so_far += 1
                        books_so_far += ready_at[idx][1]
                        idx += 1
                    row_for_shelves[series_count] = count_so_far
                    book_for_shelves[series_count] = books_so_far
                table_2d.append(row_for_shelves)
                table_books.append(book_for_shelves)
            section_reach[sec.id] = table_2d
            section_reach_books[sec.id] = table_books

        # Same idea, but flatten the per-section lookup into a flat list
        # of (shelf_unlock_name, table_2d, bc_count) tuples. The
        # feasible_rows hot loop iterates this list directly instead of
        # going through active_sections + dict[sec.id] every call.
        section_reach_list: list[tuple[str, list[list[int]], int]] = [
            (shelf_names[sec.id], section_reach[sec.id], section_caps[sec.id])
            for sec in active_sections
        ]
        section_books_list: list[tuple[str, list[list[int]], int]] = [
            (shelf_names[sec.id], section_reach_books[sec.id], section_caps[sec.id])
            for sec in active_sections
        ]

        # Helper: state-only check for "section X is fully cleared"
        # — every bookcase opened (= bookcase_count shelf unlocks for X),
        # every series in X unlocked.
        # Hoist series-count read outside the inner all(): fill calls this
        # rule a LOT during sweeps; saving N-1 state lookups per call adds
        # up across a multi-player generation.
        def section_done(state, sec) -> bool:
            if not state.has(shelf_names[sec.id], p, section_caps[sec.id]):
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
            # Per-section counts, not their SUM. A sum is not a key: holding two unlocks
            # for one section and none for another has the same total as one each, and
            # those reach different rows. The stale answer that collision returns depends
            # on which state was cached first, which is how a seed with a fixed seed
            # number still came out different run to run.
            marker = (series_count, tuple([prog[sn] for sn in shelf_names_only]))
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

        books_attr = f"_librarian_feasbooks_{p}"

        def feasible_books(state) -> int:
            """Books the state can already shelve, from the volume table above.

            Same shape and same marker as feasible_rows -- only the table differs."""
            prog = state.prog_items[p]
            series_count = prog[ITEM_PROG_SERIES]
            # Per-section counts, not their SUM. A sum is not a key: holding two unlocks
            # for one section and none for another has the same total as one each, and
            # those reach different rows. The stale answer that collision returns depends
            # on which state was cached first, which is how a seed with a fixed seed
            # number still came out different run to run.
            marker = (series_count, tuple([prog[sn] for sn in shelf_names_only]))
            cached = state.__dict__.get(books_attr)
            if cached is not None and cached[0] == marker:
                return cached[1]
            if series_count > max_series_idx:
                series_count = max_series_idx
            total = 0
            for shelf_name, table_2d, bc_count in section_books_list:
                shelf_count = prog[shelf_name]
                if shelf_count > bc_count:
                    shelf_count = bc_count
                total += table_2d[shelf_count][series_count]
            state.__dict__[books_attr] = (marker, total)
            return total

        # A row costs its bookcase unlocks plus its series unlock. Series modes have no
        # per-book gate, so a book costs exactly what its row costs -- which is what makes
        # by_book a change of granularity rather than a change of logic.
        def row_rule(sec, ser):
            sname, sn = self._shelf_gate(sec.id, ser.name)
            return lambda state, sname=sname, sn=sn, sni=series_req[ser.name]: (
                state.has(sname, p, sn) and state.has(ITEM_PROG_SERIES, p, sni))

        def book_rule(sec, ser, _ch):
            return row_rule(sec, ser)

        self._apply_check_locations(row_rule, book_rule, feasible_books)

        # Section region access — gated by ≥1 Progressive Shelf Unlock for X.
        # Capture the precomputed shelf-unlock name string in the lambda
        # closure so the rule doesn't re-format the section id every call.
        for section in active_sections:
            entrance = mw.get_entrance(f"Open Section {section.id}", p)
            entrance.access_rule = (
                lambda state, sname=shelf_names[section.id]:
                state.has(sname, p, 1)
            )

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
                        if not state.has(shelf_names[s.id], p, section_caps[s.id]):
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
        goal_value = self.goal_value
        if goal_value == self.options.goal.option_custom:
            # Counted the way this seed checks: rows under check_mode series, books
            # otherwise. Both counters are exact, so neither needs a conversion.
            if self.check_by_series:
                threshold = self.options.custom_goal_row_count.value
                goal.access_rule = (
                    lambda state, n=threshold: feasible_rows(state) >= n)
            else:
                threshold = self.options.custom_goal_book_count.value
                goal.access_rule = (
                    lambda state, n=threshold: feasible_books(state) >= n)
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
                    if not state.has(shelf_names[s.id], p, section_caps[s.id]):
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
        goal_value = int(self.goal_value)
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
        # The name->book map is needed by any mode that hands out books, even when books
        # are not what gets checked: bundle mode still has to know which books a bundle
        # un-wards. The location map is not -- location_name_to_id is the whole game's
        # static table, so it answers for locations this seed never created.
        goal_counts_books = not self.check_by_series
        if goal_counts_books:
            # Whatever the seed checks, the goal is counted the same way, so every by-book
            # and by-count seed needs this threshold -- not just the booksanity ones.
            if goal_value == self.options.goal.option_floor_1:
                goal_book_threshold = sum(
                    s.volume_count for s in data.SECTIONS if s.floor == 1)
            elif goal_value == self.options.goal.option_floor_2:
                goal_book_threshold = sum(
                    s.volume_count for s in data.SECTIONS if s.floor == 2)
            elif goal_value == self.options.goal.option_custom:
                goal_book_threshold = min(
                    self.options.custom_goal_book_count.value,
                    sum(s.volume_count for s in data.SECTIONS))
            else:
                goal_book_threshold = sum(s.volume_count for s in data.SECTIONS)
        if self.book_checks or self.random_bundle:
            active_sids = self.active_section_ids
            for (asset_idx, chapter, sid, series_name) in data.ALL_BOOKS:
                if sid not in active_sids:
                    continue
                if self.book_checks:
                    loc_id = self.location_name_to_id.get(
                        _book_name(sid, series_name, chapter))
                    if loc_id is not None:
                        book_location_map[f"{series_name}|{chapter}"] = loc_id
                book_item_to_book[book_item_name(series_name, chapter)] = \
                    [series_name, chapter]
            max_books = self.max_reachable_books
            for thresh in (BOOK_COMPLETION_THRESHOLDS if self.book_checks else ()):
                if thresh <= max_books:
                    bc_id = self.location_name_to_id.get(f"Correctly shelve {thresh} books")
                    if bc_id is not None:
                        book_completion_map[str(thresh)] = bc_id

        return {
            # Build label sent to the Lua client (matches main.lua MOD_VERSION); Lua
            # parses only the numeric X.Y.Z for its warding-rule gate, any pre-release
            # suffix is informational. NOT the AP world version -- that one
            # (archipelago.json:world_version) must be clean semver so AP can parse it
            # for YAML `requires: game:` checks (a suffix there reads as 0.0.0).
            "version": "3.0.0",
            "goal": goal_value,
            # Row count at which the Lua client should send STATUS_GOAL.
            # Ignored for the "full" goal (the game's EndGame fires it).
            "goal_row_threshold": goal_row_threshold,
            # Seed identifier — Lua uses this to isolate the in-game save slot
            # so each AP seed has its own Sav_AP_<seed>_<slot>.sav file.
            "seed": str(self.multiworld.seed_name),
            # Which sections this seed actually contains. Informational for the floor and
            # full goals (derivable from `goal`), load-bearing for custom: that set is a
            # seeded roll, so a UT re-gen has no other way to reproduce it.
            "active_sections": sorted(self.active_section_ids),
            "starting_section": self.starting_section,
            "starting_section_b": self.starting_section_b,
            "starting_series": self.starting_series,
            # booksanity: the individual books precollected at start (random subset;
            # count = sum of starting_series_count rolled 3/5/10 sizes). Empty for
            # other modes. Emitted so Universal Tracker can reconstruct the seed.
            "starting_books": self.starting_book_names,
            "starting_series_count": self.options.starting_series_count.value,
            # random_book_bundle: the client turns bundle count x books_per_bundle into
            # unlocked books by walking book_order, so both must ride slot_data. book_order
            # is a seeded roll and cannot be re-derived by a tracker re-gen.
            "random_bundle": int(self.random_bundle),
            "check_by_series": int(self.check_by_series),
            "check_by_count": int(self.check_by_count),
            "count_ticks": self.count_ticks if self.check_by_count else [],
            # str(tick) -> AP location id. The ticks alone are just numbers; the client
            # needs the ids to send, the same way row_location_map serves row checks.
            "count_location_map": ({
                str(n): self.location_name_to_id[f"Shelved {n} Books"]
                for n in self.count_ticks
                if f"Shelved {n} Books" in self.location_name_to_id
            } if self.check_by_count else {}),
            "books_per_bundle": getattr(self, "books_per_bundle_effective", None)
                                or self.options.books_per_bundle.value,
            "book_order": self.book_order if self.random_bundle else [],
            # Rides slot_data for the same reason the two above do: a tracker re-gen sees
            # option defaults, and guessing this one wrong changes how many unlocks it
            # thinks the pool holds.
            "spare_book_item_percent": self.options.spare_book_item_percent.value,
            "spare_shelf_items": self.options.spare_shelf_items.value,
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
                if self.book_checks else []),
            # Book count at which the client sends STATUS_GOAL (floor goals);
            # 0/full lets the game's EndGame fire it.
            "goal_book_threshold": goal_book_threshold,
            # Which threshold the client should fire the goal from. The check mode
            # decides it now, so book_sanity no longer answers the question.
            "goal_counts_books": int(goal_counts_books),
            # Options hold defaults on a tracker re-gen, so this has to ride slot_data
            # or the tracker rebuilds the seed with the bookcases gated the wrong way.
            "bookcase_unlocks": int(self.bookcase_unlocks),
            "magic_skills_enabled": list(self.enabled_skills),
            # section id -> how many bookcases one unlock item opens. 1 under the
            # progressive mode, the whole section under "whole"; the client cannot
            # tell the two apart from the item name alone.
            "bookcases_per_unlock": {
                s.id: (s.bookcase_count
                       if self.bookcase_unlocks
                       == self.options.bookcase_unlocks.option_whole else 1)
                for s in self.active_sections
            },
        }
