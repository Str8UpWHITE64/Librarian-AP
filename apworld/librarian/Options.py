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
    custom  -- Win after a number you choose. Set that number in
               custom_goal_row_count or custom_goal_book_count, whichever your
               check_mode counts in. Sections past your goal leave the seed, so you
               are not waiting on items you will never need.

    individual_book_unlocks is slow to generate on the full goal. Pick a floor or a
    custom goal there."""
    display_name = "Goal"

    option_full = 0
    option_custom = 1
    option_floor_1 = 2
    option_floor_2 = 3
    default = 0


class UnlockMode(Choice):
    """Choose how book series are unlocked.

    progressive_unlocks (default) -- each unlock item opens the next
        series_per_unlock series. Bookcases open a few at a time as well. The
        smallest item pool, and the classic setup.
    individual_series_unlocks -- one unlock item per series, about 400 of them.
        Every bookcase is open from the start.
    random_book_bundle -- each unlock item hands you books_per_bundle books from
        anywhere in the library, ignoring series. Bookcases open a few at a time.
        Needs check_mode: booksanity or count.
    individual_book_unlocks -- one unlock item per book, about 3000 of them. Every
        bookcase is open from the start. Much the biggest pool: it only works with
        check_mode: booksanity, and it is slow to generate on the full goal."""
    display_name = "Unlock Mode"

    option_progressive_unlocks = 0
    option_individual_series_unlocks = 1
    option_individual_book_unlocks = 2
    option_random_book_bundle = 3
    default = 0


class CustomGoalRowCount(Range):
    """How many rows to finish to win, when goal = custom and check_mode = series.

    Ignored otherwise: the other two check modes count books, through
    custom_goal_book_count. Accepts 'random', 'random-low', 'random-high'."""
    display_name = "Custom Goal Row Count"
    range_start = 1
    range_end = 400
    default = 200


class CustomGoalBookCount(Range):
    """How many books to shelve to win, when goal = custom and check_mode is
    booksanity or count.

    Ignored otherwise: check_mode series counts rows, through custom_goal_row_count.
    The library holds 3072 books in 400 rows, so a number that sounds big here is a
    shorter run than you might expect. The default is about half the library, which is
    close to the length of a floor goal. Accepts 'random', 'random-low',
    'random-high'."""
    display_name = "Custom Goal Book Count"
    range_start = 1
    range_end = 3072
    default = 1500


class SpareBookItemPercent(Range):
    """Spare Progressive Series Unlock copies, as a percentage, so you do not need
    every one of them to finish.

    On goal: custom it sets how much of the library the seed keeps past your goal.
    A goal of 200 rows and 10% spare leads to at least 220 series in the pool.
    A BookSanity goal of 1500 books and 10% spare has at least 1650 books in it."""
    display_name = "Spare Book Item Percent"
    range_start = 0
    range_end = 20
    default = 10


class SpareShelfItems(Range):
    """Spare Progressive Shelf Unlock copies, as a count per bookcase, so you do not
    need every one of them to open a section.

    Full and floor goals with progressive_unlocks. A seed with no room for the number
    you pick uses fewer and says so during generation."""
    display_name = "Spare Shelf Items"
    range_start = 0
    range_end = 3
    default = 0


class BookcaseUnlocks(Choice):
    """How the bookcases open up.

    progressive (default) -- one item per bookcase, so a section opens a few shelves
        at a time.
    whole -- one item per section, opening all of its bookcases at once.
    unlocked -- every bookcase is open from the start.

    The two individual unlock modes are always unlocked."""
    display_name = "Bookcase Unlocks"
    option_progressive = 0
    option_whole = 1
    option_unlocked = 2
    default = 0


class CheckMode(Choice):
    """Choose what earns you a check.

    series (default) -- finishing a whole row.
    booksanity -- shelving any single book correctly.
    count -- every check_interval books you shelve.

    Not every pairing works: individual_book_unlocks needs booksanity, and
    random_book_bundle needs booksanity or count. Generation will tell you if the
    pair you picked cannot be built."""
    display_name = "Check Mode"
    option_series = 0
    option_booksanity = 1
    option_count = 2
    default = 0


class CheckInterval(Range):
    """How many books you shelve between checks, when check_mode = count.

    Lower means more checks, each worth less. Lowered automatically if the seed needs
    more checks than your interval would give it."""
    display_name = "Check Interval"
    range_start = 1
    range_end = 100
    default = 10


class BooksPerBundle(Range):
    """How many books arrive in each bundle. random_book_bundle only.

    Higher means fewer, bigger deliveries. Raised automatically if the seed would need
    more bundles than it has checks to put them in."""
    display_name = "Books Per Bundle"
    range_start = 1
    range_end = 50
    default = 10


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
    """Require both the series unlock and its bookcase before a book can be picked up.

    On (default): a book stays hidden until its series and its bookcase are both open,
    so every book you are holding has a shelf waiting for it.

    Off: a book is grabbable as soon as it is sent to you, and can go on any shelf you
    have. Getting every check may then mean shelving a series, taking it back off, and
    cycling another one through the same shelf."""
    display_name = "Only Unward Shelfable Books"


@dataclass
class LibrarianOptions(PerGameCommonOptions):
    goal: Goal
    unlock_mode: UnlockMode
    check_mode: CheckMode
    bookcase_unlocks: BookcaseUnlocks
    check_interval: CheckInterval
    books_per_bundle: BooksPerBundle
    custom_goal_row_count: CustomGoalRowCount
    custom_goal_book_count: CustomGoalBookCount
    spare_book_item_percent: SpareBookItemPercent
    spare_shelf_items: SpareShelfItems
    starting_series_count: StartingSeriesCount
    series_per_unlock: SeriesPerUnlock
    book_visibility: BookVisibility
    local_filler: LocalFiller
    only_unward_shelfable_books: OnlyUnwardShelfableBooks
