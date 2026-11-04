# Options

Every YAML option for Librarian. Put them under the `Librarian:` section of your YAML. Generate a fresh template from Archipelago (Generate Template Options) rather than reusing an old YAML.

The template groups them the way this page does: Goal, Unlocks, Checks, Traps, and The library.

Two settings shape everything else, and in 3.0.0 they are independent of each
other:

- **`unlock_mode`** decides how books reach you.
- **`check_mode`** decides what earns a check.

Every pairing but one can be built. The one that cannot is switched to
`booksanity` at generation, and the generation log says so:

| `unlock_mode` \ `check_mode` | `series`       | `booksanity` | `count` |
|-----------------------------|----------------|--------------|---------|
| `random_series_bundles`       | yes            | yes          | yes     |
| `individual_series_unlocks` | yes            | yes          | yes     |
| `random_book_bundle`        | yes            | yes          | yes     |
| `individual_book_unlocks`   | to booksanity  | yes          | yes     |

`individual_book_unlocks` puts ~3,072 items in the pool, which cannot sit in
~400 row checks. With `count` its interval becomes 1, so every book is a
check there too. `random_book_bundle` with `series` orders the bundles so
that a series finishes at a steady rate; each bundle still draws from across
the library.

Locked books can't be taken in any mode, including by the magic skills:
Assemble won't pull one into your bag, and Insight won't reveal one.

---

### Host settings

One setting lives in the generating machine's `host.yaml`, not in any player's
YAML, under `librarian_options`:

```yaml
librarian_options:
  allow_individual_book_unlocks: false
  allow_numbered_book_bundles: false
  allow_high_spare_book_percent: false
```

`individual_book_unlocks` on the `full` goal puts 3,072 progression items in
the pool, and Archipelago's spoiler playthrough step slows down faster than
that number grows: about a minute for one such player on their own, three and
a half for two, seven and a half for three. Every player in the lobby waits on it, so the
decision belongs to whoever runs generation. With it `false` (the default) a
YAML asking for that shape is refused with a message naming this setting;
set it `true` to allow it. A custom goal counts as that shape once it keeps
more books than one floor holds (about 1,600, spare books included), since
by then it is most of the library. Floor goals, and smaller custom goals,
need nothing.

`allow_numbered_book_bundles` gates `numbered_book_bundles` the same way; see
that option under Unlocks for what it costs.

`allow_high_spare_book_percent` gates `spare_book_item_percent` above 20, which
only works on `goal: custom`; see that option under Unlocks. If your
`host.yaml` already has a `librarian_options` block from an earlier version,
add the new key by hand, or let Archipelago add it the next time it loads the
apworld.

Archipelago writes the keys into `host.yaml` the first time it loads the
apworld, so look there after one generation.

---

### Goal

#### `goal`

How much of the library must be tidied to win.

| Value      | Meaning                                                      |
|------------|--------------------------------------------------------------|
| `full`     | (Default) Complete both floors                               |
| `floor_1`  | Complete Floor 1 only (~176 rows). Floor 2 removed from pool |
| `floor_2`  | Complete Floor 2 only (~224 rows). Floor 1 removed from pool |
| `custom`   | A count you choose, see below                                |

With `custom`, the seed is trimmed to roughly what your goal needs plus
`spare_book_item_percent` slack. Sections past that leave the pool entirely,
rather than remaining as checks holding items nobody will collect.

Whichever goal you pick, reaching it opens the way out rather than ending the
run on the spot. The library has its own ending, and the mod leaves it to you.

`individual_book_unlocks` on the `full` goal is slow to generate, so it is off
unless the host allows it; see Host settings above. So is a custom goal there
that keeps more books than one floor holds. A floor goal needs no permission.

#### `custom_goal_row_count`

When `goal: custom` **and** `check_mode: series`, the number of rows needed to
win. Range 25-400. Supports `random`, `random-low`, `random-high`. Default 200.

The other two check modes count books, through `custom_goal_book_count`, and
ignore this.

#### `custom_goal_book_count`

When `goal: custom` **and** `check_mode` is `booksanity` or `count`, the number
of correctly shelved books needed to win. Range 100-3072. Default 1500.
Supports `random`, `random-low`, `random-high`.

Note the scale: the library holds 3072 books across 400 rows, so a row-shaped
number here is a far shorter run than it looks. The default of 1500 is about
half the library, which lands near the size of a floor goal.

A custom book goal is also the fastest way to play the book-heavy modes, since
it sidesteps the full goal's slow generation entirely.

---

### Unlocks

#### `unlock_mode`

How books become available. This changes the size and shape of the item pool,
and what several of the other options mean.

| Value                       | Meaning                                                                      |
|-----------------------------|------------------------------------------------------------------------------|
| `random_series_bundles`       | (Default) Series unlock in groups of `series_per_unlock`. Smallest pool.     |
| `individual_series_unlocks` | Each of the ~400 series is its own item. Every bookcase starts open.         |
| `random_book_bundle`        | Each item hands you `books_per_bundle` books from anywhere, ignoring series. |
| `individual_book_unlocks`   | Each of the ~3,072 books is its own item. Every bookcase starts open. Full goal needs host permission. |

In the two individual modes every bookcase starts open, so `bookcase_unlocks`
does not apply to them.

Series bundles are numbered items, `Series Bundle 12`, so a hint can be asked
for the exact one; they arrive in any order. Book bundles are copies of one
item, `Progressive Book Bundle`, that open the seed's order in sequence,
unless `numbered_book_bundles` is on (see below). Which books a bundle carries
is fixed by the seed either way.

**Which bundle has a book in it?** Ask Universal Tracker. Its
`/get_logical_path` command answers for any book or row check, for example:

```
Book: 2L - Alchemy Tomes Vol 3 -- not in logic yet. Book Bundle 12: not yet
received; bookcase: Progressive Shelf Unlock (2L) x2 (you hold 1).
```

The tracker autofills location names into that command, so pick the book from
its list. Under series bundles it names the `Series Bundle` instead; with
plain book bundles it says which copy ("the 12th Progressive Book Bundle: you
hold 7, 5 more to go"); a row under book bundles lists every bundle holding
one of its volumes. The same bundle names show up in the tracker's region
path for the check.

#### `numbered_book_bundles`

Toggle (default `false`). `random_book_bundle` only. Makes every book bundle
its own item, `Book Bundle 1`, `Book Bundle 2`, ..., so a hint can target the
exact one; they then arrive in any order. Needs the host's permission
(`allow_numbered_book_bundles` in `host.yaml`), because numbered book bundles
make the fill work much harder: about three times the generation time with
`check_mode: count`, growing steeply with the lobby size, and it can fail to
generate with unlocked bookcases and series checks. Off, the tracker still
answers which bundle holds a book.

#### `series_per_unlock`

How many series each `Series Bundle` item grants. Range 3-10.
Default 5. Lower values mean more items in the pool, each with smaller impact;
higher values mean fewer items, each more impactful.

Only applies to `random_series_bundles`; the other three hand out series or books
directly.

#### `books_per_bundle`

How many books arrive in each `Book Bundle`. Range 2-50. Default
10. `random_book_bundle` only.

Higher means fewer, larger deliveries. Raised automatically if the seed would
need more bundles than it has checks to put them in, and a little further with
`check_mode: series` or `count` so the checks stay fillable, so a small number
on a large goal is a request rather than a guarantee.

#### `starting_series_count`

How many series you begin with unlocked. Range 5-25. Default 10. The starting
set is randomized per seed but always includes at least one series whose shelf
row is on the starting bookcase, so your first check is always reachable.

What the number buys depends on the unlock mode:

| `unlock_mode` | what you start with |
|---|---|
| `random_series_bundles`, `individual_series_unlocks` | That many series. |
| `random_book_bundle` | Enough bundles to cover that many series, so the real amount depends on `books_per_bundle`. |
| `individual_book_unlocks` | That many series' *worth* of books. Each one rolls a series size (3, 5 or 10 volumes), so 5 starts you with roughly 15 to 50 individual books. |

#### `bookcase_unlocks`

How the 31 sections' bookcases open up.

| Value         | Meaning                                                                      |
|---------------|------------------------------------------------------------------------------|
| `progressive` | (Default) One item per bookcase, so a section opens a few shelves at a time. |
| `whole`       | One `Section Unlock` item per section, opening all of its bookcases at once. |
| `unlocked`    | Every bookcase is open from the start.                                       |

Pick `unlocked` if you would rather the run be only about books. The two
individual unlock modes are always `unlocked` regardless of what you set here.

#### `spare_book_item_percent`

Range 0-100. Default 10. Above 20 only works on `goal: custom`, and only when
the host allows it (`allow_high_spare_book_percent` in `host.yaml`, see Host
settings). On every other goal the value is held to 20, and the generation log
says so.

How much slack to leave beyond what your goal actually needs. A goal that needs
every last unlock is fragile in a multiworld: one item sitting in a stalled or
abandoned game can leave you stuck for good. This gives you a margin, so you
need most of what the seed holds rather than all of it, which should cut down on
getting BK'd.

It does that two ways, depending on the goal:

| goal | what it does |
|---|---|
| `custom` | Grows the trimmed seed. A 200-row goal at 10 keeps about 220 rows instead of 200, and the extra rows bring extra unlocks with them. |
| `full` / `floor_1` / `floor_2` | The seed already holds everything, so there is nothing to grow. It adds that percentage of extra `Series Bundle` items to the pool instead, replacing filler. |

On a 200-row custom goal: 0 gives no margin, 10 gives about three spare unlocks,
20 gives about eight.

Past 20 it starts costing `spare_shelf_items` whole steps, and on a custom goal
a bigger margin mostly just re-adds the surplus checks the trim exists to
remove. That is why the higher range is off by default. The kept amount never
goes past the whole library, so 100 on a large goal simply keeps all of it. With
`individual_book_unlocks` a big margin also slows generation, the same way the
full goal does.

The spare-copy half is `random_series_bundles` only. Everywhere else each series
or book is its own specific item, or bundles are handed out to a fixed count, so
a duplicate unlocks nothing. A `custom` goal in any mode still trims the seed by
this percentage.

#### `spare_shelf_items`

Range 0-3. Default 0. Full and floor goals, with `random_series_bundles` and
`bookcase_unlocks: progressive`.

The same idea for bookcases, as a count per bookcase rather than a percentage,
since sections hold as few as three. It adds an extra N `Progressive Shelf
Unlock` items for each section, so any section can lose that many copies to a
stalled game and still open fully.

This is the most expensive setting in the YAML. Every step is one item slot per
bookcase, 71 of them at the full goal, all replacing filler:

| `spare_shelf_items` | shelf unlocks | filler left |
|---------------------|---------------|-------------|
| 0 | 69 | 244 |
| 1 | 140 | 173 |
| 2 | 211 | 102 |
| 3 | 282 | 31 |

*(full goal, `series_per_unlock: 5`, `spare_book_item_percent: 0`,
`bookcase_unlocks: progressive`)*

A seed without room drops back a step rather than failing, and says so during
generation, so asking for more than fits costs nothing. How much room there is
depends on the goal and on `series_per_unlock`, so tighter configurations keep
fewer steps: a `floor_1` seed with `series_per_unlock: 3` takes 2, not 3.

Spares past the cap do nothing. The mod already stops applying unlocks past the
last series and the last bookcase.

The other `bookcase_unlocks` settings hand out whole sections or none at all, so
there is nothing for a spare copy to open, and this is ignored there.

---

### Checks

#### `check_mode`

What earns you a check.

| Value        | Meaning                                            |
|--------------|----------------------------------------------------|
| `series`     | (Default) Finishing a whole row.                   |
| `booksanity` | Shelving any single book correctly. ~3,072 checks. |
| `count`      | Every `check_interval` books you shelve.           |

In `booksanity` the checks read `Book: <Section> - <Series> Vol N`. In `count`
they read as running totals, so the run is paced by how much shelving you do
rather than by which shelves you finish.

#### `check_interval`

How many books you shelve between checks, when `check_mode` is `count`. Range 1-100. Default 10.
Lower means more checks, each worth less. The seed needs enough checks to
hold its items, so a wide interval is narrowed to fit, and generation prints
what it landed on.

With `random_book_bundle` there is a second limit: the interval can be at
most about `books_per_bundle` divided by 2.5. Five books or fewer per bundle
means a check every book; 10 per bundle allows every 3; 25 per bundle allows
every 6 to 9, depending on `bookcase_unlocks`. Which of the two settings gives
way is `count_bundle_preference`.

#### `count_bundle_preference`

When `check_mode` is `count` and `random_book_bundle` cannot honor both
`check_interval` and `books_per_bundle`, which one keeps its value.

| Value | Effect |
|---|---|
| `narrow_interval` | Keep `books_per_bundle`; checks come more often than asked (default). |
| `widen_bundle` | Keep `check_interval`; bundles hold more books than asked. |

Generation prints what it landed on either way. The other unlock modes have no
such limit, so this does nothing there.

#### `magic_skills_enabled`

Which magic skills can turn up. A list; take out any you would rather not be
given. All five are included by default:

```yaml
  magic_skills_enabled:
    - Sort
    - Shelf Guide
    - Insight
    - Auto-Shelving
    - Assemble
```

Dropping a skill also drops its Mastery upgrades, and its Fatigue trap can no
longer come up (see Traps). What they held becomes filler. Nothing in logic needs magic, so a shorter list only
changes what you find, never whether the seed is winnable.

#### `vanilla_caps`

Toggle (default `false`). By default this randomizer makes you **stronger than
the base game ever does**:

- Each magic skill can go up to five steps past its normal maximum through
  `<Skill> Mastery` items: shorter cooldowns, longer effects.
- `+2 Book Capacity` and `+3 Book Capacity` items let you carry up to 40 books
  instead of the game's 15.

Set `vanilla_caps: true` to stop where the base game does. There are then no
Mastery or Book Capacity items: skills top out at their normal maximum, and you
carry at most 15 books. Their places go to filler. Traps are separate: they
are controlled by `trap_percentage` and `trap_weights`, not by this.

#### `local_filler`

Toggle (default `true`). Keeps this game's filler items in your own world
instead of scattering them across the multiworld. Your meaningful items still
circulate normally. Recommended, since Librarian adds a lot of checks. No effect
in a solo game.

---

### Traps

Traps are items that make things harder for a short while. They take the place
of filler items, never of anything a check or your goal depends on, so they
cannot make a seed unwinnable. Every effect is temporary and none of it is
saved into your game: quit and reload and it is gone.

**Traps are on by default.** A YAML that says nothing about them gets about 10%
of its filler turned into traps. Set `trap_percentage: 0` for a seed with none.
A YAML from before 3.0.2 has no trap lines either, so regenerating it with the
new apworld gives it traps too.

#### `trap_percentage`

Range 0-100. Default 10.

The share of your filler items that become traps. 0 turns traps off entirely.
Filler is whatever the pool has left over after the items the seed needs, so
with `local_filler` on, the traps you receive come from your own world.

#### `trap_weights`

How likely each trap is when a filler item becomes a trap. A weight of 0 turns
that trap off. The defaults:

```yaml
  trap_weights:
    Fatigue: 2
    Floor Shuffle: 2
    Veil: 2
    Butterfingers: 2
    Scramble Shelf: 1
    Shelf Spill: 1
```

In the multiworld each trap shows up as an item named with "Trap" on the end:
`Floor Shuffle Trap`, `Veil Trap`, `Butterfingers Trap`, `Scramble Shelf Trap`,
`Shelf Spill Trap`, and one `<skill> Fatigue Trap` per skill (`Sort Fatigue Trap`,
`Shelf Guide Fatigue Trap` and so on). The `trap_weights` keys stay the
short names, so existing YAMLs keep working.

When a trap takes effect you see a notice on screen, for example "Received Veil Trap from
Player2". Older item names without "Trap" still work too.

| Trap | What it does |
|---|---|
| `Fatigue` | One magic skill recovers slowly for two minutes. Which skill is picked at generation, from the skills you have enabled. |
| `Floor Shuffle` | The loose books lying on the floor swap places with each other. |
| `Veil` | The loose books you could pick up are hidden for 30 seconds, then come back. |
| `Butterfingers` | Some of the books in your hands, from one up to all of them, fall to the floor beside you in a pile. |
| `Scramble Shelf` | A few books in a row you have not finished trade places. A notice names the bookcase and row. |
| `Shelf Spill` | A few books in a row you have not finished fall out onto the floor in front of their bookcase. A notice names the bookcase and row. |

The two shelf traps never touch a finished row, so a row you completed, and the
check it gave, stay done. They have half the default weight of the others
because they undo shelving work. If you would rather not have them, set both to
0.

---

### The library

#### `book_visibility`

What locked books look like before you unlock them.

| Value    | Meaning                                                                   |
|----------|---------------------------------------------------------------------------|
| `hidden` | (Default) Locked books are invisible. The library fills in as you unlock.  |
| `stacks` | Locked books stay visible but can't be taken; you walk through them.       |

`stacks` keeps the shelves looking full, and avoids the hidden-book display
glitch described in [Troubleshooting](TROUBLESHOOTING.md#known-issues).

#### `only_unward_shelfable_books`

Toggle (default `true`). Controls how strictly books are gated by
shelf unlocks.

**On (default)** - A book stays hidden until its series **and** its bookcase are
both open. This is the default so you never have to shuffle series around: you
need **both** the series unlock **and** the bookcase unlocks that reach the
series's home bookcase. No visibility floor: if a section has zero bookcases
open, none of its series are pickable.

**Off** - Books are unhidden and grabbable as soon as they are sent to you,
**regardless of whether their bookcase is open yet**. This means you can place
books on shelves "out of order".

Be aware of what that involves: to collect every available check you may need to
shelf a series, then **replace it with a different series on the same shelf**,
working through the series you hold using the shelves you have.

The difference: **Off** lets you hold any received series' books immediately
(placing them once that shelf opens); **On** withholds the books themselves
until the shelf is open. Either way, *finishing* a row requires its bookcase
open.

