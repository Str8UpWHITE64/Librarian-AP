"""
Librarian: Tidy Up the Arcane Library — Archipelago items

Item pool composition (matches the design from data.py):

    PROGRESSION (load-bearing in logic)
        Progressive Series Unlock           ×  N    (qty = ceil(active_series /
                                                     series_per_unlock); covers
                                                     all series in goal scope)
        Progressive Shelf Unlock: <Section> ×  M    (per-section, qty = bookcase
                                                     count for that section)
        Major Magic (5 progressive lines, 45 items total)

    Section access is implicit: a section is reachable as soon as the player
    holds ≥1 Progressive Shelf Unlock for it. Each subsequent unlock reveals
    one more bookcase within that section.

    Minor Magic abilities (Jump / Jogging / two bag upgrades) are NOT AP
    items — the player gets each natively from its Minor Magic chest
    (Crimson Octagon / Emerald Club / Azure Star / Golden Diamond). The
    chest opening is tracked as a location check; the matching key is
    an in-game pickup that gates chest reachability.

    FILLER (varies — fills the remaining slots up to total location count)
        Whisper of Lore, Library Token, Magical Polish,
        Forgotten Bookmark, Dust of Ages

Item-code layout within ITEM_ID_BASE:
    1–9        meta (Series)
    100–199    Progressive Shelf Unlock, one per section (31 entries)
    200–299    Major Magic skills (5 progressive items)
    400–499    Filler
"""

from enum import IntEnum
from typing import NamedTuple
from BaseClasses import Item, ItemClassification

from . import data


# ============================================================================
# AP boilerplate
# ============================================================================

# Unique base ID for this game. Adjacent AP worlds use:
#   Crab Champions: 1890000
# Librarian uses 1910000 to avoid collision. Final ID is reserved when the
# world is contributed back to the AP project.
ITEM_ID_BASE: int = 1910000


class LibrarianItemCategory(IntEnum):
    EVENT       = 0   # internal events (e.g., goal completion)
    SERIES      = 2   # Progressive Series Unlock (5 series each)
    SHELF       = 3   # Progressive Shelf Unlock: <SectionId>
    MAJOR_SKILL = 4   # 5 Major Magic skills (progressive)
    FILLER      = 6
    TRAP        = 7   # reserved for v2; unused in v1


class LibrarianItemData(NamedTuple):
    name: str
    code: int | None              # offset within ITEM_ID_BASE; None for events
    category: LibrarianItemCategory
    classification: ItemClassification


class LibrarianItem(Item):
    game: str = "Librarian Tidy Up the Arcane Library"

    @staticmethod
    def get_name_to_id() -> dict[str, int | None]:
        return {
            it.name: (ITEM_ID_BASE + it.code if it.code is not None else None)
            for it in _all_items
        }


# ============================================================================
# Item definitions (one entry per unique item NAME, regardless of pool count)
# ============================================================================

# --- Series / shelf-unlock meta items ---

_series_items: list[LibrarianItemData] = [
    LibrarianItemData(
        "Progressive Series Unlock", 2,
        LibrarianItemCategory.SERIES, ItemClassification.progression,
    ),
]

# 31 unique shelf-unlock items, one per section. Holding ≥1 of these for a
# section makes that section reachable; each additional copy reveals the
# next bookcase within the section.
_shelf_items: list[LibrarianItemData] = [
    LibrarianItemData(
        f"Progressive Shelf Unlock ({section.id})",
        100 + idx,
        LibrarianItemCategory.SHELF,
        ItemClassification.progression,
    )
    for idx, section in enumerate(data.SECTIONS)
]

# --- Major Magic (progressive) ---
#
# progression_skip_balancing rather than plain progression: these items
# gate ONLY the 45 level-up locations (one copy per post-level-1 level)
# and have no row/section/floor/goal dependency. Including 45 progression
# copies in fill's balancing pass inflates routing work without helping
# routing — skip_balancing keeps them progression-priority (placed before
# filler) but out of the balancing loop. One of the bigger single fill
# speedup wins available.
_major_skill_items: list[LibrarianItemData] = [
    LibrarianItemData("Progressive Sort",          200, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.progression_skip_balancing),
    LibrarianItemData("Progressive Shelf Guide",   201, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.progression_skip_balancing),
    LibrarianItemData("Progressive Insight",       202, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.progression_skip_balancing),
    LibrarianItemData("Progressive Auto-Shelving", 203, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.progression_skip_balancing),
    LibrarianItemData("Progressive Assemble",      204, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.progression_skip_balancing),
]

# --- Filler (themed) ---

_filler_items: list[LibrarianItemData] = [
    LibrarianItemData("Whisper of Lore",      400, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Library Token",        401, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Magical Polish",       402, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Forgotten Bookmark",   403, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Dust of Ages",         404, LibrarianItemCategory.FILLER, ItemClassification.filler),
]

# --- Combined, in stable order for ID assignment ---

_all_items: list[LibrarianItemData] = (
    _series_items
    + _shelf_items
    + _major_skill_items
    + _filler_items
)

item_dictionary: dict[str, LibrarianItemData] = {it.name: it for it in _all_items}


# ============================================================================
# Item groups (for AP /track UI and option references)
# ============================================================================

item_name_groups: dict[str, set[str]] = {
    "Series Unlocks":   {it.name for it in _series_items},
    "Shelf Unlocks":    {it.name for it in _shelf_items},
    "Major Magic":      {it.name for it in _major_skill_items},
    "Skills":           {it.name for it in _major_skill_items},
    "Filler":           {it.name for it in _filler_items},
}


# ============================================================================
# Pool quantities — how many copies of each item land in the pool
# ============================================================================

# Per-name count for everything except filler. Filler is computed from the
# remaining-slots count in build_item_pool().
ITEM_QUANTITIES: dict[str, int] = {
    "Progressive Series Unlock":  80,   # 80 × 5 series each = 400 series total

    # Per-section shelf-unlock counts: one per physical bookcase in that section.
    # Total across 31 sections = 73 (matches the in-game count from F10 probe).
    **{
        f"Progressive Shelf Unlock ({s.id})": s.bookcase_count
        for s in data.SECTIONS
    },

    # Major Magic — quantity = max level for that skill
    "Progressive Sort":          data.SKILL_MAX_LEVELS[data.UpgradeAbility.SORT_BOOKS],          # 5
    "Progressive Shelf Guide":   data.SKILL_MAX_LEVELS[data.UpgradeAbility.SHOW_MATCHING_SHELF],  # 10
    "Progressive Insight":       data.SKILL_MAX_LEVELS[data.UpgradeAbility.SHOW_SAME_TYPE_BOOK],  # 10
    "Progressive Auto-Shelving": data.SKILL_MAX_LEVELS[data.UpgradeAbility.AUTO_SHELVE],          # 10
    "Progressive Assemble":      data.SKILL_MAX_LEVELS[data.UpgradeAbility.GRAB_SAME_TYPE_BOOK],  # 10
}


# ============================================================================
# Pool-construction helpers
# ============================================================================

def progression_pool_size() -> int:
    """Total progression item count (series + shelf unlocks + major magic)."""
    return (
        ITEM_QUANTITIES["Progressive Series Unlock"]
        + sum(s.bookcase_count for s in data.SECTIONS)
        + sum(data.SKILL_MAX_LEVELS[a] for a in data.MAJOR_MAGIC_ABILITIES)
    )


def useful_pool_size() -> int:
    """Total useful item count (none — Minor Magic abilities aren't items)."""
    return 0


def required_filler_count(total_locations: int) -> int:
    """Filler items needed to fill remaining location slots."""
    return total_locations - progression_pool_size() - useful_pool_size()


def build_item_pool(total_locations: int, rng=None) -> list[LibrarianItemData]:
    """Build the full item pool sized to fit `total_locations`.

    Distribution:
        - All progression items at their fixed quantities
        - Filler items distributed roughly evenly to fill the remainder
    """
    pool: list[LibrarianItemData] = []

    # 1. Progression items at fixed quantities
    for name, qty in ITEM_QUANTITIES.items():
        item = item_dictionary[name]
        pool.extend([item] * qty)

    # 2. Filler — distributed across the themed filler items
    needed = total_locations - len(pool)
    if needed < 0:
        raise ValueError(
            f"Item pool ({len(pool)}) already exceeds location count "
            f"({total_locations}). Reduce shelf-group quantities or add more locations."
        )

    if needed > 0 and _filler_items:
        per_filler = needed // len(_filler_items)
        extras = needed % len(_filler_items)
        for i, item in enumerate(_filler_items):
            count = per_filler + (1 if i < extras else 0)
            pool.extend([item] * count)

    if rng is not None:
        rng.shuffle(pool)
    return pool


# ============================================================================
# Sanity assertions
# ============================================================================

# IDs must be unique
_ids = [it.code for it in _all_items if it.code is not None]
assert len(_ids) == len(set(_ids)), "Duplicate item code detected"

# Names must be unique
_names = [it.name for it in _all_items]
assert len(_names) == len(set(_names)), "Duplicate item name detected"

# Item ID ranges shouldn't overlap categories
for cat, lo, hi in [
    (LibrarianItemCategory.SERIES,      2,   2),
    (LibrarianItemCategory.SHELF,       100, 199),
    (LibrarianItemCategory.MAJOR_SKILL, 200, 299),
    (LibrarianItemCategory.FILLER,      400, 499),
]:
    for it in _all_items:
        if it.category == cat:
            assert it.code is not None and lo <= it.code <= hi, (
                f"Item '{it.name}' has code {it.code} outside category range {lo}-{hi}"
            )

# All ITEM_QUANTITIES entries must reference defined items
for name in ITEM_QUANTITIES:
    assert name in item_dictionary, f"ITEM_QUANTITIES references unknown item '{name}'"

# Final sanity: useful pool is empty (Minor Magic abilities are not items)
assert useful_pool_size() == 0, f"Expected 0 useful items, got {useful_pool_size()}"
# (Progression count varies with section.bookcase_count; not asserted to a fixed value.)


# ============================================================================
# Self-test
# ============================================================================

if __name__ == "__main__":
    print("Librarian — Items.py summary")
    print("=" * 60)
    print(f"Distinct item names:        {len(_all_items)}")
    print(f"  Series:                    {len(_series_items)}")
    print(f"  Shelf unlocks (per-section): {len(_shelf_items)}")
    print(f"  Major skills (progressive): {len(_major_skill_items)}")
    print(f"  Filler types:               {len(_filler_items)}")
    print()
    print(f"Pool sizes (excluding filler):")
    print(f"  Progression: {progression_pool_size()}")
    print(f"  Useful:      {useful_pool_size()}")
    print(f"  Subtotal:    {progression_pool_size() + useful_pool_size()}")
    print()
    print(f"Item-name → ID mapping (sample):")
    for name, item_id in list(LibrarianItem.get_name_to_id().items())[:10]:
        print(f"  {name:42s} → {item_id}")
    print(f"  ... ({len(_all_items) - 10} more)")
    print()
    print(f"Per-section shelf-unlock quantities:")
    for s in data.SECTIONS:
        print(f"  {s.id} {s.name:35s} bookcases={s.bookcase_count}")
    print()
    pool_for_481 = build_item_pool(481)
    print(f"Sample build_item_pool(481): {len(pool_for_481)} items")
    print(f"  Filler count in pool: {sum(1 for it in pool_for_481 if it.category == LibrarianItemCategory.FILLER)}")
