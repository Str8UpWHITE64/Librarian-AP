"""
Librarian: Tidy Up the Arcane Library — Archipelago locations

Location pool composition (554 real + 1 goal event = 555 entries):

    Shelf Rows (400)
        One per series. Fires when the series is correctly placed.
        Name format: "Shelf: <SectionId> - <Series Name>"

    Row Completions
        Cumulative row-completion-count milestones. Fires when the player
        has correctly completed N total rows (any combination of series).
        Hand-tuned distribution — dense early, sparser late — to balance
        coverage against per-rule fill cost (each rule calls
        feasible_rows, which is O(active_sections)).
        Name format: "Complete <N> Rows"

    Section Completions (31)
        Fires when every series in a section is correctly placed.
        Name format: "Section Complete: <SectionId> (<Section Name>)"

    Floor Completions (2)
        Fires when every section on the floor is complete.

    Level-Ups (45)
        Fires once per OnLevelUp event.

    Chests (4)
        Fires when the player opens one of the four Minor Magic chests
        (Crimson Octagon / Emerald Club / Azure Star / Golden Diamond).
        The corresponding key is the in-world pickup that lets the player
        open the chest; the AP check fires on the chest's grant of the
        ability, not on the key pickup itself.

    Goal — "Library Tidied" (1, event-typed, no AP ID)
        Fires when the game's EndGame UFunction is observed.

Defined but NOT in the active pool:

    Milestones (22)
        Cumulative book-placement thresholds. Any book on a shelf counts —
        correct placement isn't required. Not in _all_locations; their slots
        were replaced by additional row-completion thresholds. Definitions
        retained for possible future re-enable.

ID layout within LOCATION_ID_BASE:
    1–499      Shelf rows (400 used: 1..400; 401-499 reserved for future)
    500–549    Section completions (31 used: 500..530)
    550–559    Floor completions (2 used: 550-551)
    560–619    Level-ups (45 used: 560..604)
    620–639    Chest openings (4 used: 620..623)
    640–679    Milestones (22 used: 640..661; 662-679 reserved; defined but
                            not in the active pool)
    1000–1199  Row completions (1000..1071; 1072-1199 reserved)
"""

from enum import IntEnum
from typing import NamedTuple
from BaseClasses import Location

from . import data


LOCATION_ID_BASE: int = 1910000


class LibrarianLocationCategory(IntEnum):
    EVENT          = 0
    ROW            = 1   # per-series shelf-row completion
    SECTION        = 2   # whole-section completion
    FLOOR          = 3   # whole-floor completion
    LEVEL_UP       = 4   # player level threshold reached
    CHEST          = 5   # minor magic chest opened (Crimson/Emerald/Azure/Golden)
    MILESTONE      = 6   # cumulative book-placement count
    GOAL           = 7   # EndGame (event-typed; no AP ID)
    ROW_COMPLETION = 8   # cumulative rows-correctly-completed count.
                         # Access rule: feasible_rows(state) >= N (same
                         # check as primary row locations). Lua client
                         # tracks total rows completed and fires each
                         # threshold.
    BOOK           = 9   # book_sanity: one per book. Fires when that book is
                         # placed correctly. Access rule: has(that book's item).
    BOOK_COMPLETION = 10 # book_sanity cumulative books-placed-correctly count.
    COUNT_TICK      = 11 # check_mode=by_count: 'Shelved N Books' at a chosen interval
                         # Access rule: feasible_books(state) >= N.


class LibrarianLocationData(NamedTuple):
    name: str
    code: int | None              # offset within LOCATION_ID_BASE; None for events
    category: LibrarianLocationCategory


class LibrarianLocation(Location):
    game: str = "Librarian Tidy Up the Arcane Library"

    @staticmethod
    def get_name_to_id() -> dict[str, int | None]:
        return {
            loc.name: (LOCATION_ID_BASE + loc.code if loc.code is not None else None)
            for loc in _all_locations
        }


# ============================================================================
# Location definitions
# ============================================================================

# --- Shelf rows: 400 entries (1..400), one per series in declaration order ---

def _row_name(section: data.Section, series: data.Series) -> str:
    return f"Shelf: {section.id} - {series.name}"


_row_locations: list[LibrarianLocationData] = []
_row_idx = 1
for _section in data.SECTIONS:
    for _series in _section.series:
        _row_locations.append(LibrarianLocationData(
            _row_name(_section, _series),
            _row_idx,
            LibrarianLocationCategory.ROW,
        ))
        _row_idx += 1


# --- Row-completion count milestones (1000..) ---
#
# Fires when the player has correctly completed N total rows (any series).
# Each 'Complete N Rows' is gated on feasible_rows(state) >= N -- a fillable
# location reachable only once N distinct series are held. In
# individual_series_items mode a deep threshold opens only in a late fill
# sphere, and a swarm of those late count-gated slots drives a cross-player
# swap-storm; that mode pre-fills them locally (see LibrarianWorld.pre_fill) so
# the shared fill only routes into shallow row locations. Grouped (default) mode
# leaves them in the normal fill, where cached feasible_rows keeps them cheap.
# These checks are load-bearing, not filler padding: they are the shallow
# count-gated locations that let fill route the deep series-unlock chain.
# Removing them breaks fill on tight configs; cut filler on the item side
# instead. Kept in full.
ROW_COMPLETION_THRESHOLDS: tuple[int, ...] = (
    # Every row 1-20 (densest part — most fill routing happens here)
    1,   2,   3,   4,   5,   6,   7,   8,   9,  10,
    11,  12,  13,  14,  15,  16,  17,  18,  19,  20,
    # Mid-frequent through 50
    22,  24,  26,  28,  30,  35,  40,  45,  50,
    # Every 5 through 100
    55,  60,  65,  70,  75,  80,  85,  90,  95, 100,
    # Steady on to 250
    105, 110, 115, 120, 130, 140, 145, 160, 175, 190, 205, 220, 235, 245,
    # Existing late-game distribution
    250, 265, 280, 295, 310, 325, 340, 355, 360, 365,
    372, 379, 385, 390, 393, 396, 398, 399, 400,
)

_row_completion_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        f"Complete {thresh} Rows",
        1000 + idx,
        LibrarianLocationCategory.ROW_COMPLETION,
    )
    for idx, thresh in enumerate(ROW_COMPLETION_THRESHOLDS)
]


# --- Section completions: 31 entries (500..530) ---

_section_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        f"Section Complete: {section.id} ({section.name})",
        500 + idx,
        LibrarianLocationCategory.SECTION,
    )
    for idx, section in enumerate(data.SECTIONS)
]


# --- Floor completions: 2 entries ---

_floor_locations: list[LibrarianLocationData] = [
    LibrarianLocationData("Floor 1 Complete", 550, LibrarianLocationCategory.FLOOR),
    LibrarianLocationData("Floor 2 Complete", 551, LibrarianLocationCategory.FLOOR),
]


# --- Level-ups: one per XP threshold (45 entries, 560..604) ---

_levelup_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        f"Reached Level {n}",
        560 + (n - 1),
        LibrarianLocationCategory.LEVEL_UP,
    )
    for n in range(1, data.MAX_PLAYER_LEVEL + 1)  # 1..45
]


# --- Chest openings: 4 entries (620..623) ---

_chest_locations: list[LibrarianLocationData] = [
    LibrarianLocationData("Chest: Crimson Octagon", 620, LibrarianLocationCategory.CHEST),
    LibrarianLocationData("Chest: Emerald Club",    621, LibrarianLocationCategory.CHEST),
    LibrarianLocationData("Chest: Azure Star",      622, LibrarianLocationCategory.CHEST),
    LibrarianLocationData("Chest: Golden Diamond",  623, LibrarianLocationCategory.CHEST),
]


# --- Cumulative book-placement milestones: 22 entries (640..661) ---
#
# Reserved 640..679 (40 slots) — room for further milestones in future
# updates. Thresholds are denser at the early end where most fill-routing
# happens, and reach 3072 (= all books across all sections) at the top.
MILESTONE_THRESHOLDS: tuple[int, ...] = (
    25, 50, 100, 150, 200,
    300, 400, 500, 600, 750,
    900, 1100, 1300, 1500, 1700,
    1900, 2100, 2300, 2500, 2700,
    2900, 3072,
)

_milestone_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        f"Milestone: {threshold} Books Placed",
        640 + idx,
        LibrarianLocationCategory.MILESTONE,
    )
    for idx, threshold in enumerate(MILESTONE_THRESHOLDS)
]


# --- Goal event: 1 entry, no ID ---

_goal_locations: list[LibrarianLocationData] = [
    LibrarianLocationData("Library Tidied", None, LibrarianLocationCategory.GOAL),
]


# --- Combined ---
# _milestone_locations no longer added to _all_locations — the book-placement
# milestones were replaced by additional row-completion thresholds.
# MILESTONE_THRESHOLDS + _milestone_locations stay defined above so future
# code can opt back in.

# --- BookSanity: one book location per book + book-completion milestones ---
#
# One location per individual book (volume), created only when book_sanity is
# on. Fires when that book is placed on its correct shelf. Gated on has(the
# book's own item) -- depth-1, so the shared fill stays flat. Global order
# matches data.ALL_BOOKS.
def _book_name(section_id: str, series_name: str, chapter: int) -> str:
    return f"Book: {section_id} - {series_name} Vol {chapter + 1}"


_book_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        _book_name(_section_id, _series_name, _chapter),
        2000 + _idx,
        LibrarianLocationCategory.BOOK,
    )
    for _idx, (_asset_idx, _chapter, _section_id, _series_name)
    in enumerate(data.ALL_BOOKS)
]

# Cumulative "Correctly shelve N books" milestones (book_sanity). Dense early,
# sparse late; count kept modest to bound the deep-lock. Access rule:
# feasible_books(state) >= N.
BOOK_COMPLETION_THRESHOLDS: tuple[int, ...] = (
    5,   10,   25,   50,   75,  100,  150,  200,  300,  400,
    500, 650,  800, 1000, 1200, 1400, 1600, 1800, 2000, 2200,
    2400, 2600, 2800, 2900, 3000, 3050, 3072,
)

_book_completion_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        f"Correctly shelve {_thresh} books",
        5100 + _idx,
        LibrarianLocationCategory.BOOK_COMPLETION,
    )
    for _idx, _thresh in enumerate(BOOK_COMPLETION_THRESHOLDS)
]


# check_mode=by_count: one location per possible cumulative book count. Names have to be
# static for the datapackage, so every tick from 1 to the library size is defined here and a
# seed creates only the multiples of its own check_interval. Unused names cost nothing.
COUNT_TICK_MAX: int = 3072

_count_tick_locations: list[LibrarianLocationData] = [
    LibrarianLocationData(
        f"Shelved {_n} Books",
        6000 + _n,
        LibrarianLocationCategory.COUNT_TICK,
    )
    for _n in range(1, COUNT_TICK_MAX + 1)
]


# _all_locations is the master union across ALL modes (drives the name->id map);
# create_regions/create_items pick the active subset per option.
_all_locations: list[LibrarianLocationData] = (
    _row_locations
    + _row_completion_locations
    + _section_locations
    + _floor_locations
    + _levelup_locations
    + _chest_locations
    + _book_locations
    + _book_completion_locations
    + _count_tick_locations
    + _goal_locations
)

location_dictionary: dict[str, LibrarianLocationData] = {
    loc.name: loc for loc in _all_locations
}


# ============================================================================
# Location groups (for AP /track UI and option references)
# ============================================================================

# Groups name real, ID-bearing locations only. The book-placement milestones were replaced
# by row-completion thresholds and are no longer created, and the goal is an event with no
# ID, so neither can appear here.
location_name_groups: dict[str, set[str]] = {
    "Shelf Rows":      {loc.name for loc in _row_locations},
    "Row Completions": {loc.name for loc in _row_completion_locations},
    "Sections":        {loc.name for loc in _section_locations},
    "Floors":          {loc.name for loc in _floor_locations},
    "Level-Ups":       {loc.name for loc in _levelup_locations},
    "Chests":          {loc.name for loc in _chest_locations},
    "Books":           {loc.name for loc in _book_locations},
    "Book Completions": {loc.name for loc in _book_completion_locations},
}

# Per-section row groupings — useful for the World's region-building.
location_groups_by_section: dict[str, list[str]] = {
    section.id: [_row_name(section, series) for series in section.series]
    for section in data.SECTIONS
}


# ============================================================================
# Helpers
# ============================================================================

def total_real_locations() -> int:
    """Locations with AP IDs (excludes event/goal locations)."""
    return sum(1 for loc in _all_locations if loc.code is not None)


def total_locations() -> int:
    """Total location entries including events."""
    return len(_all_locations)


def location_name_to_id() -> dict[str, int]:
    """Mapping for non-event locations only."""
    return {
        loc.name: LOCATION_ID_BASE + loc.code
        for loc in _all_locations
        if loc.code is not None
    }


def section_completion_name(section_id: str) -> str:
    section = data.SECTIONS_BY_ID[section_id]
    return f"Section Complete: {section.id} ({section.name})"


def levelup_name(level: int) -> str:
    return f"Reached Level {level}"


def chest_open_name(chest_name: str) -> str:
    return f"Chest: {chest_name}"


# ============================================================================
# Sanity assertions
# ============================================================================

assert len(_row_locations) == 400, f"Expected 400 row locations, got {len(_row_locations)}"
assert len(_row_completion_locations) == len(ROW_COMPLETION_THRESHOLDS)
assert len(_section_locations) == 31
assert len(_floor_locations) == 2
assert len(_levelup_locations) == 45
assert len(_chest_locations) == 4
assert len(_milestone_locations) == 22
assert len(_goal_locations) == 1
assert len(_book_locations) == 3072, f"Expected 3072 book locations, got {len(_book_locations)}"
assert len(_book_completion_locations) == len(BOOK_COMPLETION_THRESHOLDS)
# Real location count derives from the (tunable) threshold sets. The master
# union includes both row-mode and book-mode locations; create_regions only
# instantiates the active subset per option.
_expected_real = (400 + len(ROW_COMPLETION_THRESHOLDS) + 31 + 2 + 45 + 4
                  + len(_book_locations) + len(BOOK_COMPLETION_THRESHOLDS)
                  + len(_count_tick_locations))
assert total_real_locations() == _expected_real, \
    f"Expected {_expected_real} real locations, got {total_real_locations()}"
assert total_locations() == _expected_real + 1

# Codes unique
_codes = [loc.code for loc in _all_locations if loc.code is not None]
assert len(_codes) == len(set(_codes)), "Duplicate location code"

# Names unique
_names = [loc.name for loc in _all_locations]
assert len(_names) == len(set(_names)), "Duplicate location name"

# Code ranges are within their declared category bounds
for cat, lo, hi in [
    (LibrarianLocationCategory.ROW,        1,    499),
    (LibrarianLocationCategory.SECTION,    500,  549),
    (LibrarianLocationCategory.FLOOR,      550,  559),
    (LibrarianLocationCategory.LEVEL_UP,   560,  619),
    (LibrarianLocationCategory.CHEST,      620,  639),
    (LibrarianLocationCategory.MILESTONE,      640,  679),
    (LibrarianLocationCategory.ROW_COMPLETION, 1000, 1199),
    (LibrarianLocationCategory.BOOK,           2000, 5099),
    (LibrarianLocationCategory.BOOK_COMPLETION, 5100, 5299),
    (LibrarianLocationCategory.COUNT_TICK,      6001, 9072),
]:
    for loc in _all_locations:
        if loc.category == cat:
            assert loc.code is not None and lo <= loc.code <= hi, (
                f"Location '{loc.name}' has code {loc.code} outside category range {lo}-{hi}"
            )


# ============================================================================
# Self-test
# ============================================================================

if __name__ == "__main__":
    print("Librarian — Locations.py summary")
    print("=" * 60)
    print(f"Shelf rows:         {len(_row_locations):4d}")
    print(f"Row completions:    {len(_row_completion_locations):4d}")
    print(f"Section completions:{len(_section_locations):4d}")
    print(f"Floor completions:  {len(_floor_locations):4d}")
    print(f"Level-ups:          {len(_levelup_locations):4d}")
    print(f"Chest openings:     {len(_chest_locations):4d}")
    print(f"Milestones:         {len(_milestone_locations):4d}")
    print(f"Goal events:        {len(_goal_locations):4d}")
    print("-" * 60)
    print(f"Real locations:     {total_real_locations():4d}")
    print(f"Total entries:      {total_locations():4d}")
    print()
    print(f"ID range: {LOCATION_ID_BASE + 1} ... {max(LOCATION_ID_BASE + (loc.code or 0) for loc in _all_locations)}")
    print()
    print("Sample shelf rows (first 5):")
    for loc in _row_locations[:5]:
        print(f"  {LOCATION_ID_BASE + loc.code}  {loc.name}")
    print("...")
    print("Sample shelf rows (last 5):")
    for loc in _row_locations[-5:]:
        print(f"  {LOCATION_ID_BASE + loc.code}  {loc.name}")
    print()
    print("Section completions (all 31):")
    for loc in _section_locations:
        print(f"  {LOCATION_ID_BASE + loc.code}  {loc.name}")
    print()
    print("Milestone thresholds:")
    for t in MILESTONE_THRESHOLDS:
        print(f"  {t} books placed")
    print()
    print(f"Pool math check (with 230 filler items):")
    print(f"  progression  + useful + filler = 251 + 230 = {251 + 230}")
    print(f"  vs real locations:                {total_real_locations()}")
    print(f"  diff:                              {total_real_locations() - 481}")
    print()
    print("(Adjust filler count in Items.py to match: filler = total_real_locations() - 251 = "
          f"{total_real_locations() - 251})")
