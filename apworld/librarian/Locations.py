"""
Librarian: Tidy Up the Arcane Library — Archipelago locations

Location pool composition (492 real + 1 goal event = 493 entries):

    Shelf Rows (400)
        One per series. Fires when the series is correctly placed.
        Name format: "Shelf: <SectionId> - <Series Name>"

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

    Milestones (10)
        Cumulative book-placement thresholds:
        50, 100, 250, 500, 750, 1000, 1500, 2000, 2500, 3000.

    Goal — "Library Tidied" (1, event-typed, no AP ID)
        Fires when the game's EndGame UFunction is observed.

ID layout within LOCATION_ID_BASE:
    1–499      Shelf rows (400 used: 1..400; 401-499 reserved for future)
    500–549    Section completions (31 used: 500..530)
    550–559    Floor completions (2 used: 550-551)
    560–619    Level-ups (45 used: 560..604)
    620–639    Chest openings (4 used: 620..623)
    640–679    Milestones (10 used: 640..649)
"""

from enum import IntEnum
from typing import NamedTuple
from BaseClasses import Location

from . import data


LOCATION_ID_BASE: int = 1910000


class LibrarianLocationCategory(IntEnum):
    EVENT      = 0
    ROW        = 1   # per-series shelf-row completion
    SECTION    = 2   # whole-section completion
    FLOOR      = 3   # whole-floor completion
    LEVEL_UP   = 4   # player level threshold reached
    CHEST      = 5   # minor magic chest opened (Crimson/Emerald/Azure/Golden)
    MILESTONE  = 6   # cumulative book-placement count
    GOAL       = 7   # EndGame (event-typed; no AP ID)


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


# --- Cumulative book-placement milestones: 10 entries (640..649) ---

MILESTONE_THRESHOLDS: tuple[int, ...] = (
    50, 100, 250, 500, 750, 1000, 1500, 2000, 2500, 3000,
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

_all_locations: list[LibrarianLocationData] = (
    _row_locations
    + _section_locations
    + _floor_locations
    + _levelup_locations
    + _chest_locations
    + _milestone_locations
    + _goal_locations
)

location_dictionary: dict[str, LibrarianLocationData] = {
    loc.name: loc for loc in _all_locations
}


# ============================================================================
# Location groups (for AP /track UI and option references)
# ============================================================================

location_name_groups: dict[str, set[str]] = {
    "Shelf Rows": {loc.name for loc in _row_locations},
    "Sections":   {loc.name for loc in _section_locations},
    "Floors":     {loc.name for loc in _floor_locations},
    "Level-Ups":  {loc.name for loc in _levelup_locations},
    "Chests":     {loc.name for loc in _chest_locations},
    "Milestones": {loc.name for loc in _milestone_locations},
    "Goal":       {loc.name for loc in _goal_locations},
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
assert len(_section_locations) == 31
assert len(_floor_locations) == 2
assert len(_levelup_locations) == 45
assert len(_chest_locations) == 4
assert len(_milestone_locations) == 10
assert len(_goal_locations) == 1
assert total_real_locations() == 492, f"Expected 492 real locations, got {total_real_locations()}"
assert total_locations() == 493

# Codes unique
_codes = [loc.code for loc in _all_locations if loc.code is not None]
assert len(_codes) == len(set(_codes)), "Duplicate location code"

# Names unique
_names = [loc.name for loc in _all_locations]
assert len(_names) == len(set(_names)), "Duplicate location name"

# Code ranges are within their declared category bounds
for cat, lo, hi in [
    (LibrarianLocationCategory.ROW,        1,   499),
    (LibrarianLocationCategory.SECTION,    500, 549),
    (LibrarianLocationCategory.FLOOR,      550, 559),
    (LibrarianLocationCategory.LEVEL_UP,   560, 619),
    (LibrarianLocationCategory.CHEST,      620, 639),
    (LibrarianLocationCategory.MILESTONE,  640, 679),
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
