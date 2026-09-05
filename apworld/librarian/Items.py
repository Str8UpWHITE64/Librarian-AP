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
    USEFUL      = 5   # Attunement: extend a maxed skill's cooldown / active-time
    FILLER      = 6
    TRAP        = 7   # Fatigue: a timed debuff on a skill
    SERIES_INDIV = 8  # per-series unlock items (individual_series_items)
    BOOK        = 9   # per-book items (book_sanity)
    BOOK_BUNDLE = 10  # Progressive Book Bundle (N random books each)
    SECTION     = 11  # Section Unlock: <SectionId> (opens all of a section's bookcases)
    SERIES_BUNDLE = 12  # Series Bundle N: the N-th group of series_per_unlock series
    BOOK_BUNDLE_N = 13  # Book Bundle N: the N-th group of books_per_bundle books


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
    # random_book_bundle: each copy reveals the next books_per_bundle books from the
    # seed's shuffled book_order. One name however large the bundle, so the bundle size
    # stays a slot_data number rather than something the datapackage has to enumerate.
    LibrarianItemData(
        "Progressive Book Bundle", 3,
        LibrarianItemCategory.BOOK_BUNDLE, ItemClassification.progression,
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

# 31 whole-section unlocks, the coarse alternative to the progressive shelf items above:
# one item opens every bookcase in its section. Both sets always exist in the datapackage
# (it is static per game); a seed uses whichever its bookcase_unlocks setting calls for.
_section_items: list[LibrarianItemData] = [
    LibrarianItemData(
        f"Section Unlock ({section.id})",
        131 + idx,
        LibrarianItemCategory.SECTION,
        ItemClassification.progression,
    )
    for idx, section in enumerate(data.SECTIONS)
]

# --- Major Magic (progressive) ---
#
# USEFUL, not progression. Skills help you sort faster but are never REQUIRED to
# finish a row or win -- feasible_rows models rows from series + shelf only, never
# magic -- so gating on them was artificial. As useful items they spread across the
# multiworld (not pinned to the player's own level-ups) and level-ups host filler
# instead: less boring, more cross-world, and all 45 still ship in the pool.
_major_skill_items: list[LibrarianItemData] = [
    LibrarianItemData("Progressive Sort",          200, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.useful),
    LibrarianItemData("Progressive Shelf Guide",   201, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.useful),
    LibrarianItemData("Progressive Insight",       202, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.useful),
    LibrarianItemData("Progressive Auto-Shelving", 203, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.useful),
    LibrarianItemData("Progressive Assemble",      204, LibrarianItemCategory.MAJOR_SKILL, ItemClassification.useful),
]

# --- Filler (themed) ---

_filler_items: list[LibrarianItemData] = [
    LibrarianItemData("Whisper of Lore",      400, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Library Token",        401, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Magical Polish",       402, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Forgotten Bookmark",   403, LibrarianItemCategory.FILLER, ItemClassification.filler),
    LibrarianItemData("Dust of Ages",         404, LibrarianItemCategory.FILLER, ItemClassification.filler),
]

# --- Individual series-unlock items (opt-in: individual_series_items) ---
#
# One distinct item per series (~400), each unlocking that specific series.
# progression_skip_balancing, not plain progression: keeps progression priority
# but stays out of fill's balancing loop, where 400 items x N players is far too
# slow. Codes 700 + index in data.ALL_SERIES. Always defined so their AP ids
# exist, but only enter the pool when the option is on (see create_items);
# ITEM_QUANTITIES omits them.
def series_unlock_item_name(series_name: str) -> str:
    return f"Series Unlock: {series_name}"


_individual_series_items: list[LibrarianItemData] = [
    LibrarianItemData(
        series_unlock_item_name(series_name),
        700 + idx,
        LibrarianItemCategory.SERIES_INDIV,
        ItemClassification.progression_skip_balancing,
    )
    for idx, (_sid, series_name, _vols) in enumerate(data.ALL_SERIES)
]


# BookSanity: one item per individual book (volume). Added to the pool only
# when book_sanity is on (see create_items); ITEM_QUANTITIES omits them. Global
# order matches data.ALL_BOOKS. Series names are globally unique, so
# "Book: <series> Vol N" is a unique item name.
def book_item_name(series_name: str, chapter: int) -> str:
    return f"Book: {series_name} Vol {chapter + 1}"


_book_items: list[LibrarianItemData] = [
    LibrarianItemData(
        book_item_name(_series_name, _chapter),
        2000 + _idx,
        LibrarianItemCategory.BOOK,
        ItemClassification.progression_skip_balancing,
    )
    for _idx, (_asset_idx, _chapter, _sid, _series_name) in enumerate(data.ALL_BOOKS)
]

# --- Numbered bundles ---
#
# A bundle is a specific item rather than one more copy of a name, so a hint or a
# tracker can point at the one holding a given book. What the k-th bundle holds is still
# decided per seed (slot_data carries the order); the datapackage only needs enough
# names for the largest possible count: 400 series at 3 per bundle, 3072 books at 2.
MAX_SERIES_BUNDLES = 134
MAX_BOOK_BUNDLES = 1536


def series_bundle_name(k: int) -> str:
    return f"Series Bundle {k}"


def book_bundle_name(k: int) -> str:
    return f"Book Bundle {k}"


_series_bundle_items: list[LibrarianItemData] = [
    LibrarianItemData(series_bundle_name(_k), 1199 + _k,
                      LibrarianItemCategory.SERIES_BUNDLE, ItemClassification.progression)
    for _k in range(1, MAX_SERIES_BUNDLES + 1)
]

_book_bundle_items: list[LibrarianItemData] = [
    LibrarianItemData(book_bundle_name(_k), 5999 + _k,
                      LibrarianItemCategory.BOOK_BUNDLE_N,
                      ItemClassification.progression_skip_balancing)
    for _k in range(1, MAX_BOOK_BUNDLES + 1)
]

# --- Skill Mastery (useful) + Fatigue (trap) ---
#
# Mastery: pushes a skill one step past its real max along the game's tuning curve (lower cooldown,
# longer active-time). A useful item, not more Progressive copies -- those are load-bearing level-up
# gates. Fatigue: a one-shot ~2-min debuff (slow recovery, short active-time) that bites at any
# level. Client-side only; names must match the client's ATTUNE_SKILLS ("<skill> Mastery" /
# "Fatigue: <skill>").
_ATTUNE_SKILLS = ("Sort", "Shelf Guide", "Insight", "Auto-Shelving", "Assemble")

_attunement_items: list[LibrarianItemData] = [
    LibrarianItemData(f"{name} Mastery", 300 + i,
                      LibrarianItemCategory.USEFUL, ItemClassification.useful)
    for i, name in enumerate(_ATTUNE_SKILLS)
]

# Book capacity: the game's two bag upgrades as useful items. "+2" = UpgradeBag (Azure Star),
# "+3" = UpgradeBag2 (Golden Diamond). The client applies these via the bag grant, gated on the
# matching chest check, and re-applies each load (the game only saves capacity up to its 15 cap).
_bag_items: list[LibrarianItemData] = [
    LibrarianItemData("+2 Book Capacity", 305, LibrarianItemCategory.USEFUL, ItemClassification.useful),
    LibrarianItemData("+3 Book Capacity", 306, LibrarianItemCategory.USEFUL, ItemClassification.useful),
]

_fatigue_items: list[LibrarianItemData] = [
    LibrarianItemData(f"Fatigue: {name}", 307 + i,
                      LibrarianItemCategory.TRAP, ItemClassification.trap)
    for i, name in enumerate(_ATTUNE_SKILLS)
]


# --- Combined, in stable order for ID assignment ---

_all_items: list[LibrarianItemData] = (
    _series_items
    + _shelf_items
    + _section_items
    + _major_skill_items
    + _attunement_items
    + _bag_items
    + _fatigue_items
    + _filler_items
    + _individual_series_items
    + _book_items
    + _series_bundle_items
    + _book_bundle_items
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
    "Series Unlocks (Individual)": {it.name for it in _individual_series_items},
    "Books":            {it.name for it in _book_items},
    "Series Bundles":   {it.name for it in _series_bundle_items},
    "Book Bundles":     {it.name for it in _book_bundle_items},
    "Skill Mastery":    {it.name for it in _attunement_items},
    "Book Capacity":    {it.name for it in _bag_items},
    "Traps":            {it.name for it in _fatigue_items},
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

    # One per section, used instead of the per-bookcase items above when
    # bookcase_unlocks is "whole".
    **{
        f"Section Unlock ({s.id})": 1
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
    (LibrarianItemCategory.SERIES,       2,   2),
    (LibrarianItemCategory.BOOK_BUNDLE,  3,   3),
    (LibrarianItemCategory.SHELF,        100, 130),
    (LibrarianItemCategory.SECTION,      131, 199),
    (LibrarianItemCategory.MAJOR_SKILL,  200, 299),
    (LibrarianItemCategory.USEFUL,       300, 306),
    (LibrarianItemCategory.TRAP,         307, 311),
    (LibrarianItemCategory.FILLER,       400, 499),
    (LibrarianItemCategory.SERIES_INDIV, 700, 1199),
    (LibrarianItemCategory.BOOK,         2000, 5099),
    (LibrarianItemCategory.SERIES_BUNDLE, 1200, 1399),
    (LibrarianItemCategory.BOOK_BUNDLE_N, 6000, 7599),
]:
    for it in _all_items:
        if it.category == cat:
            assert it.code is not None and lo <= it.code <= hi, (
                f"Item '{it.name}' has code {it.code} outside category range {lo}-{hi}"
            )

# All ITEM_QUANTITIES entries must reference defined items
for name in ITEM_QUANTITIES:
    assert name in item_dictionary, f"ITEM_QUANTITIES references unknown item '{name}'"

# (Progression count varies with section.bookcase_count; not asserted to a fixed value.)
