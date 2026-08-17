"""
Librarian: Tidy Up the Arcane Library -- Archipelago options.

Options match yaml keys by name, so the order here drives the template layout:
goal -> unlock shape -> starting amounts -> visibility / quality-of-life -> niche.
"""

from dataclasses import dataclass

from Options import Choice, Range, Toggle, DefaultOnToggle, PerGameCommonOptions


class Goal(Choice):
    """How much of the library must be tidied to win.

    full    -- Complete the whole library, both floors (default).
    floor_1 -- Complete Floor 1 only (1A-1N); Floor 2 leaves the pool.
    floor_2 -- Complete Floor 2 only (2A-2Q); Floor 1 leaves the pool.
    custom  -- Win after a count you choose: custom_goal_row_count rows, or
               custom_goal_book_count books under booksanity. Works in all three
               unlock modes. The seed is trimmed to about what that goal needs, plus
               extra_series_percent slack -- sections past it leave the pool rather
               than sitting there holding items nobody will collect.

    For booksanity, a floor or custom goal is recommended: the full goal has ~3072
    book items and takes noticeably longer to generate."""
    display_name = "Goal"

    option_full = 0
    option_custom = 1
    option_floor_1 = 2
    option_floor_2 = 3
    default = 0


class CustomGoalRowCount(Range):
    """Rows needed to win when goal = custom. Ignored for every other goal.

    Used by progressive_unlocks and individual_series_unlocks. In booksanity the
    goal counts books instead, so custom_goal_book_count applies there and this is
    ignored. Accepts 'random', 'random-low', 'random-high' in your yaml."""
    display_name = "Custom Goal Row Count"
    range_start = 1
    range_end = 400
    default = 200


class CustomGoalBookCount(Range):
    """Books needed to win when goal = custom and unlock_mode = booksanity.

    Ignored for every other goal and unlock mode -- the other two modes count rows,
    via custom_goal_row_count. The library holds 3072 books across 400 rows, so a
    row-shaped number here is a much shorter run than it looks; the default is about
    half the library, which lands near the size of a floor goal. Accepts 'random',
    'random-low', 'random-high' in your yaml."""
    display_name = "Custom Goal Book Count"
    range_start = 1
    range_end = 3072
    default = 1500


class ExtraSeriesPercent(Range):
    """Spare series to include past a custom goal, as a percentage. goal = custom only.

    A custom goal only needs its own row count, so the rest of the library is surplus:
    those checks still exist, still hold items, and in a multiworld can hold another
    game's progression -- which then waits on a check you have no reason to do. This
    trims the seed to roughly what the goal needs, plus this much slack so the run does
    not become a forced march through every remaining row.

    0 means no slack at all. Sections are kept whole, so the real total lands on the
    next section boundary rather than exactly on the percentage."""
    display_name = "Extra Series Percent"
    range_start = 0
    range_end = 100
    default = 10


class UnlockMode(Choice):
    """Choose how book series are unlocked.

    progressive_unlocks (default) -- series unlock in fungible groups: each
        Progressive Series Unlock item reveals series_per_unlock series, and
        bookcases unlock progressively. The classic, most compact item pool.
    individual_series_unlocks -- every one of the ~400 series is its own unlock
        item. More granular and a larger pool; every bookcase starts open.
    booksanity -- every individual book (~3072) is its own item AND its own check,
        the most granular option. Every bookcase starts open. A floor goal is
        recommended (the full goal is slow to generate at this size)."""
    display_name = "Unlock Mode"

    option_progressive_unlocks = 0
    option_individual_series_unlocks = 1
    option_booksanity = 2
    default = 0


class StartingSeriesCount(Range):
    """How many series you begin with unlocked. Always includes at least one whose
    row is on the starting bookcase, so your first check is available right away.

    progressive_unlocks / individual_series_unlocks: that many series.
    booksanity: that many series' worth of random books -- each count rolls a series
    size (3, 5, or 10 volumes), so e.g. 5 starts you with roughly 15-50 random
    individual books (not whole series)."""
    display_name = "Starting Series Count"
    range_start = 5
    range_end = 25
    default = 10


class SeriesPerUnlock(Range):
    """How many series each Progressive Series Unlock reveals. Lower means more
    unlocks with smaller impact; higher means fewer, bigger ones. (Below 3 makes a
    long unlock chain that's hard to place in tight seeds, so 3 is the minimum.)

    Only applies to the progressive_unlocks mode; ignored for
    individual_series_unlocks and booksanity."""
    display_name = "Series Per Unlock"
    range_start = 3
    range_end = 10
    default = 5


class BookVisibility(Choice):
    """How books from locked series look before you unlock them.

    hidden -- locked books are invisible and non-grabbable; the library fills in as
              you unlock series (default).
    stacks -- locked books stay visible but non-grabbable -- you walk through them.
              Pick this for a full-looking library or to avoid any hide glitches."""
    display_name = "Book Visibility"
    option_hidden = 0
    option_stacks = 1
    default = 0


class LocalFiller(DefaultOnToggle):
    """Keep this game's filler items in your own world.

    On (default): Librarian filler fills your own locations instead of scattering
    into other players' worlds; your meaningful items still circulate. Recommended,
    since Librarian adds a lot of checks.
    Off: filler is distributed across the multiworld like anything else.
    Has no effect in a solo game."""
    display_name = "Local Filler"


class OnlyUnwardShelfableBooks(DefaultOnToggle):
    """Require both the series unlock AND its bookcase before a book is pickable.

    On (default): a book stays hidden until its series and its bookcase are
    both open.  Default option to avoid having to shuffle series around.

    Off: books are unhidden and grabbable once they are sent to you. This means you
    can place books on shelves 'out of order'.  This may lead you to need to
    shelf a series and then replace it with a different series on the same
    shelf in order to get all available checks."""
    display_name = "Only Unward Shelfable Books"


@dataclass
class LibrarianOptions(PerGameCommonOptions):
    goal: Goal
    custom_goal_row_count: CustomGoalRowCount
    custom_goal_book_count: CustomGoalBookCount
    extra_series_percent: ExtraSeriesPercent
    unlock_mode: UnlockMode
    starting_series_count: StartingSeriesCount
    series_per_unlock: SeriesPerUnlock
    book_visibility: BookVisibility
    local_filler: LocalFiller
    only_unward_shelfable_books: OnlyUnwardShelfableBooks
