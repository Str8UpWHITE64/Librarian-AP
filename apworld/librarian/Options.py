"""
Librarian: Tidy Up the Arcane Library -- Archipelago options.

Grouped the way they are read: the mode first, then the settings that only mean
something under it. option_groups at the bottom is what the template and the web
options page lay out from, so the class order here follows it.
"""

from dataclasses import dataclass
from typing import Union

from Options import (Choice, Range, Toggle, DefaultOnToggle, OptionGroup,
                     OptionSet, PerGameCommonOptions)
from settings import Bool, Group


# --------------------------------------------------------------------------
# Goal
# --------------------------------------------------------------------------

class Goal(Choice):
    """How much of the library must be tidied to win.

    full    -- Complete the whole library, both floors (default).
    floor_1 -- Complete Floor 1 only (1A-1N); Floor 2 leaves the pool.
    floor_2 -- Complete Floor 2 only (2A-2Q); Floor 1 leaves the pool.
    custom  -- Win after a number you choose. Set that number in
               custom_goal_row_count or custom_goal_book_count, whichever your
               check_mode counts in. Sections past your goal leave the seed, so you
               are not waiting on items you will never need.

    individual_book_unlocks on the full goal is slow to generate and is off unless the
    host allows it (allow_individual_book_unlocks in host.yaml). A floor or custom
    goal there needs no permission."""
    display_name = "Goal"

    option_full = 0
    option_custom = 1
    option_floor_1 = 2
    option_floor_2 = 3
    default = 0


class CustomGoalRowCount(Range):
    """How many rows to finish to win, when goal = custom and check_mode = series.

    Ignored otherwise: the other two check modes count books, through
    custom_goal_book_count. Accepts 'random', 'random-low', 'random-high'."""
    display_name = "Custom Goal Row Count"
    range_start = 25
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
    range_start = 100
    range_end = 3072
    default = 1500



# --------------------------------------------------------------------------
# Unlocks
# --------------------------------------------------------------------------

class UnlockMode(Choice):
    """Choose how book series are unlocked.

    random_series_bundles (default) -- each Series Bundle item opens a group of
        series_per_unlock series. Bundles are numbered and arrive in any order. The
        smallest item pool, and the classic setup.
    individual_series_unlocks -- one unlock item per series, about 400 of them.
        Every bookcase is open from the start.
    random_book_bundle -- each Progressive Book Bundle hands you the next
        books_per_bundle books of the seed's order, drawn from anywhere in the
        library, ignoring series. With check_mode: series the order is laid out so
        that a series finishes at a steady rate. numbered_book_bundles makes each
        bundle its own item instead.
    individual_book_unlocks -- one unlock item per book, about 3000 of them. Every
        bookcase is open from the start. Much the biggest pool: with check_mode:
        series it is switched to booksanity, since 3000 items cannot sit in 400 row
        checks, and on the full goal it needs the host's permission
        (allow_individual_book_unlocks in host.yaml) because it is slow to generate."""
    display_name = "Unlock Mode"

    option_random_series_bundles = 0
    option_individual_series_unlocks = 1
    option_individual_book_unlocks = 2
    option_random_book_bundle = 3
    default = 0


class SeriesPerUnlock(Range):
    """How many series each Series Bundle holds. Lower means more
    unlocks with smaller impact; higher means fewer, bigger ones. (Below 3 makes a
    long unlock chain that's hard to place in tight seeds, so 3 is the minimum.)

    Only applies to the random_series_bundles mode; the other three hand out series
    or books directly, so they ignore it."""
    display_name = "Series Per Unlock"
    range_start = 3
    range_end = 10
    default = 5


class BooksPerBundle(Range):
    """How many books arrive in each bundle. random_book_bundle only.

    Higher means fewer, bigger deliveries. Raised automatically if the seed would need
    more bundles than it has checks to put them in, and a little further with
    check_mode: series or count so the checks stay fillable."""
    display_name = "Books Per Bundle"
    range_start = 2
    range_end = 50
    default = 10


class NumberedBookBundles(Toggle):
    """Give every Book Bundle its own number (Book Bundle 1, Book Bundle 2, ...) so a hint
    can target the exact one. random_book_bundle only.

    Off (default): bundles are copies of one item, Progressive Book Bundle, that open the
    seed's book order in sequence. The tracker still tells you which bundle holds a book.
    On: each bundle is its own item and they arrive in any order. This makes generation
    noticeably slower with check_mode: count, so the host has to allow it
    (allow_numbered_book_bundles in host.yaml)."""
    display_name = "Numbered Book Bundles"


class StartingSeriesCount(Range):
    """How many series you begin with unlocked. Always includes at least one whose
    row is on the starting bookcase, so your first check is available right away.

    random_series_bundles / individual_series_unlocks: that many series.
    random_book_bundle: enough bundles to cover that many series, so what you
    actually start with depends on books_per_bundle.
    individual_book_unlocks: that many series' worth of random books -- each count
    rolls a series size (3, 5, or 10 volumes), so e.g. 5 starts you with roughly
    15-50 random individual books, not whole series."""
    display_name = "Starting Series Count"
    range_start = 5
    range_end = 25
    default = 10


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


class SpareBookItemPercent(Range):
    """Spare Series Bundle copies, as a percentage, so you do not need every one of
    them to finish.

    On goal: custom it sets how much of the library the seed keeps past your goal.
    A goal of 200 rows and 10% spare leads to at least 220 series in the pool.
    A book-counted goal of 1500 books and 10% spare has at least 1650 books in it."""
    display_name = "Spare Book Item Percent"
    range_start = 0
    range_end = 20
    default = 10


class SpareShelfItems(Range):
    """Spare Progressive Shelf Unlock copies, as a count per bookcase, so you do not
    need every one of them to open a section.

    Full and floor goals with random_series_bundles and bookcase_unlocks: progressive.
    The other bookcase settings hand out whole sections or none at all, so there is
    nothing for a spare copy to open. A seed with no room for the number you pick uses
    fewer and says so during generation."""
    display_name = "Spare Shelf Items"
    range_start = 0
    range_end = 3
    default = 0



# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

class CheckMode(Choice):
    """Choose what earns you a check.

    series (default) -- finishing a whole row.
    booksanity -- shelving any single book correctly.
    count -- every check_interval books you shelve.

    One pairing cannot be built: individual_book_unlocks with series, since 3000
    book items cannot sit in 400 row checks. It is switched to booksanity, and
    generation says so."""
    display_name = "Check Mode"
    option_series = 0
    option_booksanity = 1
    option_count = 2
    default = 0


class CheckInterval(Range):
    """How many books you shelve between checks, when check_mode = count.

    Lower means more checks, each worth less. Lowered automatically if the seed needs
    more checks than the selected interval; with individual_book_unlocks that is every
    book, so the interval becomes 1."""
    display_name = "Check Interval"
    range_start = 1
    range_end = 100
    default = 10



# --------------------------------------------------------------------------
# Item Pool
# --------------------------------------------------------------------------

class MagicSkillsEnabled(OptionSet):
    """Which magic skills can turn up. Take out any you would rather not be given.

    Dropping a skill also drops its Mastery and its Fatigue trap. What it held becomes
    filler, and nothing in logic needs magic, so a shorter list only changes what you find."""
    display_name = "Magic Skills Enabled"
    valid_keys = ("Sort", "Shelf Guide", "Insight", "Auto-Shelving", "Assemble")
    default = frozenset(valid_keys)


class LocalFiller(DefaultOnToggle):
    """Keep this game's filler items in your own world.

    On (default): Librarian filler fills your own locations instead of scattering
    into other players' worlds; your meaningful items still circulate. Recommended,
    since Librarian adds a lot of checks.
    Off: filler is distributed across the multiworld like anything else.
    Has no effect in a solo game."""
    display_name = "Local Filler"



# --------------------------------------------------------------------------
# The Library
# --------------------------------------------------------------------------

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
    custom_goal_row_count: CustomGoalRowCount
    custom_goal_book_count: CustomGoalBookCount
    unlock_mode: UnlockMode
    series_per_unlock: SeriesPerUnlock
    books_per_bundle: BooksPerBundle
    numbered_book_bundles: NumberedBookBundles
    starting_series_count: StartingSeriesCount
    bookcase_unlocks: BookcaseUnlocks
    spare_book_item_percent: SpareBookItemPercent
    spare_shelf_items: SpareShelfItems
    check_mode: CheckMode
    check_interval: CheckInterval
    magic_skills_enabled: MagicSkillsEnabled
    local_filler: LocalFiller
    book_visibility: BookVisibility
    only_unward_shelfable_books: OnlyUnwardShelfableBooks


class LibrarianSettings(Group):
    """host.yaml settings for the machine that generates. The player's YAML cannot turn
    these on; only whoever runs generation can, which is the point: some option shapes
    make the whole multiworld's generation slow, and that cost lands on the host."""

    class AllowIndividualBookUnlocks(Bool):
        """Allow unlock_mode: individual_book_unlocks on the full goal. Its 3072 book items
        make the spoiler's playthrough step slow for the whole multiworld: about a minute
        solo, and it grows faster than the player count."""

    class AllowNumberedBookBundles(Bool):
        """Allow numbered_book_bundles. Numbered bundles make the fill search harder:
        about three times the generation time with check_mode: count, and it can fail
        to generate with bookcases unlocked and series checks."""

    allow_individual_book_unlocks: Union[AllowIndividualBookUnlocks, bool] = False
    allow_numbered_book_bundles: Union[AllowNumberedBookBundles, bool] = False


option_groups = [
    OptionGroup(
        "Goal",
        [Goal, CustomGoalRowCount, CustomGoalBookCount],
    ),
    OptionGroup(
        "Unlocks",
        [UnlockMode, SeriesPerUnlock, BooksPerBundle, NumberedBookBundles, StartingSeriesCount, BookcaseUnlocks, SpareBookItemPercent, SpareShelfItems],
    ),
    OptionGroup(
        "Checks",
        [CheckMode, CheckInterval],
    ),
    OptionGroup(
        "Item Pool",
        [MagicSkillsEnabled, LocalFiller],
    ),
    OptionGroup(
        "The Library",
        [BookVisibility, OnlyUnwardShelfableBooks],
    ),
]
