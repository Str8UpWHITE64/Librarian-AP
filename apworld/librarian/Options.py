"""
Librarian: Tidy Up the Arcane Library -- Archipelago options.

Extra options can be added without breaking existing yamls because
Options dataclasses use positional fields by name only.
"""

from dataclasses import dataclass

from Options import Choice, Range, Toggle, PerGameCommonOptions


class Goal(Choice):
    """How much of the library must be tidied to win.

    floor_1   -- Complete Floor 1 only (sections 1A-1N, ~176 rows).
                 The Floor 2 sections are removed from the item / location
                 pool entirely.
    full      -- Complete the entire library, both floors (default).
                 Goal fires when the game's own EndGame event triggers
                 (i.e. you walk through the final door after all 400 rows).
    custom    -- Goal fires after a configurable number of rows. See
                 custom_goal_row_count. Pool stays full (all 400 rows
                 remain checkable; player may continue past the goal).
    floor_2   -- Complete Floor 2 only (sections 2A-2Q, ~224 rows).
                 The Floor 1 sections are removed from the pool entirely."""
    display_name = "Goal"

    option_full = 0
    option_custom = 1
    option_floor_1 = 2
    option_floor_2 = 3
    default = 0


class CustomGoalRowCount(Range):
    """Number of shelf rows needed to win when goal=custom.

    Has no effect for any other goal option. Standard AP Range options
    apply: you can also use 'random', 'random-low', 'random-high' in
    your YAML."""
    display_name = "Custom Goal Row Count"
    range_start = 1
    range_end = 400
    default = 200


class StartingSeriesCount(Range):
    """How many series the player begins with unlocked.

    The starting set is randomized per seed but is guaranteed to include
    at least one series whose shelf row is on the starting bookcase, so the
    player can always make their first check immediately."""
    display_name = "Starting Series Count"
    range_start = 5
    range_end = 25
    default = 10


class SeriesPerUnlock(Range):
    """How many series each Progressive Series Unlock item reveals.

    Lower values mean more granular gating (more items, each smaller in
    impact). Higher values mean fewer items, each more impactful.

    Minimum is 3 -- values below 3 produce a deep linear progression chain
    that fill struggles to route on tight configs (multi-player,
    accessibility: minimal, low custom_goal_row_count). At 3 the chain
    depth caps at 134, which fill handles reliably across all tested
    goal / accessibility / player-count combinations.
    """
    display_name = "Series Per Unlock"
    range_start = 3
    range_end = 10
    default = 5


class OnlyUnwardShelfableBooks(Toggle):
    """Require BOTH the series unlock AND its target bookcase before books
    are pickable.

    Off (default): a book becomes pickable as soon as its series has been
    received, regardless of whether its bookcase is open yet. The player
    can pick books up and stash them on any open shelf -- mis-shelving and
    moving them later is part of the loop.

    On: a book stays warded until both its series is received AND the
    bookcase it belongs in has been unlocked. Stricter logic; book-
    placement milestones fire later in seeds where shelf and series
    unlocks are spread apart, since the player can't pick anything up
    until both have arrived for at least one row.
    """
    display_name = "Only Unward Shelfable Books"
    default = 0


@dataclass
class LibrarianOptions(PerGameCommonOptions):
    goal: Goal
    custom_goal_row_count: CustomGoalRowCount
    starting_series_count: StartingSeriesCount
    series_per_unlock: SeriesPerUnlock
    only_unward_shelfable_books: OnlyUnwardShelfableBooks
