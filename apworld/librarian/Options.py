"""
Librarian: Tidy Up the Arcane Library -- Archipelago options.

Options match yaml keys by name, so the order here is cosmetic: goal ->
progression shape -> visibility / quality-of-life -> niche.
"""

from dataclasses import dataclass

from Options import Choice, Range, Toggle, DefaultOnToggle, PerGameCommonOptions


class Goal(Choice):
    """How much of the library must be tidied to win.

    full    -- Complete the whole library, both floors (default).
    floor_1 -- Complete Floor 1 only (1A-1N); Floor 2 leaves the pool.
    floor_2 -- Complete Floor 2 only (2A-2Q); Floor 1 leaves the pool.
    custom  -- Win after custom_goal_row_count rows; the full pool stays checkable."""
    display_name = "Goal"

    option_full = 0
    option_custom = 1
    option_floor_1 = 2
    option_floor_2 = 3
    default = 0


class CustomGoalRowCount(Range):
    """Rows needed to win when goal = custom. Ignored for every other goal.
    Accepts 'random', 'random-low', 'random-high' in your yaml."""
    display_name = "Custom Goal Row Count"
    range_start = 1
    range_end = 400
    default = 200


class StartingSeriesCount(Range):
    """How many series you begin with unlocked. Always includes at least one whose
    row is on the starting bookcase, so your first check is available right away."""
    display_name = "Starting Series Count"
    range_start = 5
    range_end = 25
    default = 10


class SeriesPerUnlock(Range):
    """How many series each Progressive Series Unlock reveals. Lower means more
    unlocks with smaller impact; higher means fewer, bigger ones. (Below 3 makes a
    long unlock chain that's hard to place in tight seeds, so 3 is the minimum.)"""
    display_name = "Series Per Unlock"
    range_start = 3
    range_end = 10
    default = 5


class IndividualSeriesItems(Toggle):
    """Make each series its own item instead of grouped Progressive Series Unlocks.

    Off (default): series unlock in groups of series_per_unlock.
    On: each of the ~400 series is its own "Series Unlock: <series>" item -- more
    granular, larger pool. Every bookcase starts open. Not supported with goal = custom."""
    display_name = "Individual Series Items"
    default = 0


class BookSanity(Toggle):
    """Make every individual book its own item and its own check (~3072 of each).

    Off (default): checks are per shelf-row (a whole series).
    On: each "Book: <series> Vol N" item unlocks that book, and placing it on the
    correct shelf is its own check. Every bookcase starts open. Can't be combined
    with individual_series_items. Not supported with goal = custom."""
    display_name = "BookSanity"
    default = 0


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


class OnlyUnwardShelfableBooks(Toggle):
    """Require both the series unlock AND its bookcase before a book is pickable.

    Off (default): a book is pickable as soon as its series arrives -- you can stash
    it on any open shelf and move it later.
    On: stricter -- a book stays warded until its series and its bookcase are both open."""
    display_name = "Only Unward Shelfable Books"
    default = 0


@dataclass
class LibrarianOptions(PerGameCommonOptions):
    goal: Goal
    custom_goal_row_count: CustomGoalRowCount
    starting_series_count: StartingSeriesCount
    series_per_unlock: SeriesPerUnlock
    individual_series_items: IndividualSeriesItems
    book_sanity: BookSanity
    book_visibility: BookVisibility
    local_filler: LocalFiller
    only_unward_shelfable_books: OnlyUnwardShelfableBooks
