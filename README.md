# Librarian: Tidy Up the Arcane Library — Archipelago

An Archipelago multiworld integration for **Librarian: Tidy Up the Arcane
Library!** on Steam.

The mod gates the game's 400 book series and 31 sections behind Archipelago
items. As you complete shelves and milestones, the game sends location
checks to the Archipelago server; in return, you receive item unlocks that
open up new series and bookcases.

Two independent settings shape a run: `unlock_mode` decides how books reach
you, and `check_mode` decides what earns a check. At the granular end,
**BookSanity** sends a check for every one of the ~3,072 individual books, and
`individual_book_unlocks` makes every one of them an item as well. See YAML
options below.

---

## Requirements

- **Librarian: Tidy Up the Arcane Library!** https://store.steampowered.com/app/4197610/Librarian_Tidy_Up_the_Arcane_Library/
- **Archipelago** 0.6.x or newer on the server side.
- **UE4SS (experimental build)**. The stable UE4SS release isn't new
  enough; an experimental build is required. A known-good copy is
  bundled with every Librarian-AP release zip and with the source repo
  (at `third_party/UE4SS/`), so no separate download is needed.

  We bundle UE4SS because upstream overwrites `experimental-latest` in
  place with every build — a direct link to a specific working build
  stops resolving once superseded. The bundled copy is unmodified; see
  [`third_party/UE4SS/README.md`](third_party/UE4SS/README.md) for
  exact version and license (MIT).

  UE4SS ships with `BPModLoaderMod` included; that's the loader that
  picks up the `.pak` mod below.

---

## Installation

> **Steam Deck / Linux users:** the file copy alone is not enough.
> Proton needs a Wine DLL override or UE4SS will not load and the mod
> will appear to do nothing. Do the standard install below first, then
> jump to [Steam Deck / Linux (Proton) — extra step](#steam-deck--linux-proton--extra-step)
> before launching the game.

There are two paths. Pick whichever matches how you got Librarian-AP:

- **Quick install (from a GitHub release)** — for most players. One
  drag-drop into Steam plus one file copy into Archipelago.
- **Manual install (from a source checkout)** — for developers or
  anyone running unreleased changes from a `git clone`.

The Steam install is normally at:

```
C:\Program Files (x86)\Steam\steamapps\common\Librarian Tidy Up the Arcane Library!\
```

referred to below as `<Game>`.

### Quick install (from a GitHub release)

1. Download **both** files from the latest release on GitHub:
   - `Librarian-AP_v<version>.zip` (the game-side bundle)
   - `librarian.apworld` (the AP server module)

2. Extract the zip somewhere temporary. You'll see a top-level
   `Librarian/` folder and an `INSTALL.txt`.

3. Drag the `Librarian/` folder onto `<Game>\`. Windows will ask whether
   to merge folders — say yes. The UE4SS bootstrap, all required mods,
   and the companion `.pak` all land in the right places in one shot:

   ```
   <Game>\Librarian\Binaries\Win64\dwmapi.dll          (UE4SS bootstrap)
   <Game>\Librarian\Binaries\Win64\UE4SS.dll           (UE4SS main)
   <Game>\Librarian\Binaries\Win64\Mods\               (UE4SS mods + Librarian-AP)
   <Game>\Librarian\Content\Paks\LogicMods\LibrarianAPHUDFix.pak
   ```

4. Copy `librarian.apworld` into your Archipelago install:

   ```
   <Archipelago>\custom_worlds\librarian.apworld
   ```

That's it — skip to **Playing** (unless you're on Steam Deck / Linux,
in which case there's one more step below).

### Steam Deck / Linux (Proton) — extra step

Under Proton, the game won't load `dwmapi.dll` (the UE4SS proxy DLL)
unless you tell Wine to. Without this, UE4SS silently fails to
inject, no `UE4SS.log` is produced, and the mod looks like it isn't
installed at all.

In Steam, right-click the game → **Properties** → **General** →
**Launch Options**, and paste:

```
WINEDLLOVERRIDES="dwmapi=n,b" %command%
```

The `%command%` placeholder is mandatory — without it, Steam ignores
the override. `n,b` means "native, then built-in" — load our bundled
`dwmapi.dll` first, fall back to Wine's stub only if missing.

After launching the game once, check for a `UE4SS.log` at:

```
<Game>/Librarian/Binaries/Win64/UE4SS.log
```

If it exists, UE4SS is injecting correctly. If it's still missing
after the override, you're likely hitting a Proton-version
compatibility issue — try **Proton Experimental** in the game's
compatibility settings, or **GE-Proton 10-12** if you're on
GE-Proton. Some newer Proton builds have regressed UE4SS
injection.

### Manual install (from a source checkout)

If you're working from a repo clone, you can either:

- **Build the release zip locally** and follow the Quick install above:

  ```
  python tools/build_release.py
  ```

  This produces `dist/Librarian-AP_v<version>.zip` and
  `dist/librarian.apworld` from the current source tree.

- **Or copy files in place by hand** — useful while iterating on a
  single file. The four steps below cover that flow. The folder you'll
  be copying files into a lot is `<Game>\Librarian\Binaries\Win64\`,
  referred to as `<Win64>`.

#### 1. Install UE4SS

UE4SS is bundled in this repository at `third_party/UE4SS/`:

1. Copy `third_party/UE4SS/dwmapi.dll` into `<Win64>\`.
2. Copy the **contents** of `third_party/UE4SS/ue4ss/` (its inner files:
   `UE4SS.dll`, `UE4SS-settings.ini`, `Mods\`, `LICENSE`, etc. — not the
   `ue4ss` folder itself) into `<Win64>\`.

After this step `<Win64>\` should contain at least:

```
<Win64>\dwmapi.dll
<Win64>\UE4SS.dll
<Win64>\Mods\BPModLoaderMod\
<Win64>\Mods\mods.txt
... (other stock UE4SS bits)
```

#### 2. Install the Lua mod

Copy the `Librarian-AP/` folder from this repo into `<Win64>\Mods\`,
and copy this repo's `mods.txt` into `<Win64>\Mods\` to **overwrite**
the stock one (it has `Librarian-AP : 1` added to enable the mod).

So you end up with:

```
<Win64>\Mods\mods.txt                          (our version)
<Win64>\Mods\Librarian-AP\Scripts\main.lua
<Win64>\Mods\Librarian-AP\Scripts\AP\...
<Win64>\Mods\Librarian-AP\ap_config.json
```

#### 3. Install the BP companion pak

Copy `LibrarianAPHUDFix.pak` from the repo root into:

```
<Game>\Librarian\Content\Paks\LogicMods\
```

This pak contains the connection-menu widget, the HUD-refresh helper,
and the ModActor that bridges Lua ↔ Blueprint. It auto-spawns at game
start; nothing else to configure.

#### 4. Install the Archipelago apworld

Either run `python tools/build_release.py` (produces
`dist/librarian.apworld`) and copy that file, or zip up
`apworld/librarian/` manually and rename the result to
`librarian.apworld`. Then copy it into your Archipelago install:

```
<Archipelago>\custom_worlds\librarian.apworld
```

---

## Playing

### 1. Generate the YAML

After placing the APWorld file in Custom Worlds, relaunch Archipelago and click Generate Template Options. This will open up the templates, where you can find `Librarian Tidy Up the Arcane Library.yaml`.  Edit it with your preferred settings.

### 2. Generate a seed

Open up Archipelago and click Generate.

This produces a `.archipelago` file. Upload it to the Archipelago server,
or host it locally.

### 3. Start the game and connect

1. Launch Librarian normally.
2. At the title screen, the **Archipelago Connection** menu appears
   automatically. Type your server (e.g. `archipelago.gg:38281`), slot
   name, and password (leave blank if none), then click **Connect**.
   You can also press **F4** any time to toggle the menu.
3. The mod takes it from here. Connecting to a seed for the first time
   starts a New Game for you; returning to one loads that run's save.
   You don't need to click Continue or Start Game.
4. While the shelves are still being prepared (about 10 to 20 seconds)
   you're held in the pause menu, with Resume, Save and Load unavailable
   and Quit and Options still working. It releases itself as soon as the
   world is ready, so you never walk into a library mid-setup.
5. Play normally. As you complete shelves, the mod sends location checks
   to Archipelago; received items unlock more series and shelves.
6. When you reach your goal, the barrier at the far end of the library comes
   down and the way out opens. Walk to the door and use it to play the game's
   own ending; your victory reaches Archipelago a few seconds after the
   cutscene starts. If you would rather not walk over, it is sent on its own
   five minutes later.

### Tips

- Working connection details are saved back to
  `Mods\Librarian-AP\Scripts\ap_config.json` after a successful connect,
  so the menu prefills with your last-used values on the next launch.
  You can also pre-populate this JSON if you'd rather not type fields
  each time.
- Your AP progress is saved in a per-seed save slot named
  `Sav_AP_<seed>_<slot>.sav`, separate from your normal save. The
  original `Sav.sav` is left alone.
- **F12** is a direct-connect shortcut that bypasses the menu and uses
  whatever's currently in `ap_config.json`. Useful for quick reconnects.
- If you ever see visual artifacts (e.g., a book showing in an
  unexpected place), going to the title screen and clicking Continue
  again will force a clean world reload.

---

## YAML options

All options go under your `Librarian:` section in the YAML. The generated
template groups them the same way this section does: Goal, Unlocks, Checks,
Item pool, and The library.

3.0.0 reshapes the option set, so generate a fresh template rather than
reusing a 2.x YAML.

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
```

`individual_book_unlocks` on the `full` goal puts 3,072 progression items in
the pool, and Archipelago's spoiler playthrough step slows down faster than
that number grows: about a minute for one such player on their own, three and
a half for two, seven and a half for three. Every player in the lobby waits on it, so the
decision belongs to whoever runs generation. With it `false` (the default) a
YAML asking for that shape is refused with a message naming this setting;
set it `true` to allow it. Floor and custom goals in that mode are fine and
need nothing.

`allow_numbered_book_bundles` gates `numbered_book_bundles` the same way; see
that option under Unlocks for what it costs.

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
unless the host allows it; see Host settings below. A floor or custom goal
there needs no permission.

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

Range 0-20. Default 10.

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

The cap is 20. Past that it starts costing `spare_shelf_items` whole steps, and
on a custom goal a bigger margin mostly just re-adds the surplus checks the trim
exists to remove.

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

How many books you shelve between checks. Range 1-100. Default 10.
`check_mode: count` only.

Lower means more checks, each worth less. Lowered automatically if the seed
needs more checks than the selected interval.

---

### Item pool

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

Dropping a skill also drops its Mastery upgrades and its Fatigue trap. What they
held becomes filler. Nothing in logic needs magic, so a shorter list only
changes what you find, never whether the seed is winnable.

#### `local_filler`

Toggle (default `true`). Keeps this game's filler items in your own world
instead of scattering them across the multiworld. Your meaningful items still
circulate normally. Recommended, since Librarian adds a lot of checks. No effect
in a solo game.

---

### The library

#### `book_visibility`

What locked books look like before you unlock them.

| Value    | Meaning                                                                   |
|----------|---------------------------------------------------------------------------|
| `hidden` | (Default) Locked books are invisible. The library fills in as you unlock.  |
| `stacks` | Locked books stay visible but can't be taken; you walk through them.       |

`stacks` keeps the shelves looking full, and avoids the hidden-book display
glitch noted under Known issues.

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

---

## Verifying the install

When you launch the game, the UE4SS log
(`<Game>\Librarian\Binaries\Win64\UE4SS.log`) should include lines like:

```
[Lua] [LibrarianAP] LibAP v3.0.0 — Game v1.0.13 (verified compatible)
[Lua] [BPModLoaderMod] Actor: ModActor_C /Game/Librarian/Map/...
[Lua] [LibrarianAP] Press F4 to toggle the connection menu.
[Lua] [LibrarianAP] Press F12 to connect to Archipelago.
```

If you see those, both the Lua mod and the BP pak are loaded correctly.

If the connection menu doesn't appear at the title screen, check the
log for `[menu]` lines. The most common issues are a server URL the
client can't reach or a slot name that doesn't match the YAML.

---

## Managing save files

Each AP run claims one of the game's save slots, in the **20–30** range.
Your own saves use the lower slots and are never touched.

**To delete an old run**, right-click its slot in the **Load** menu at the
title screen and confirm. You can also do it from the Save menu in-game.
Either way the mod clears its own record of that run at the same time, so
there is nothing to tidy up by hand.

Note the game won't let you delete the save you're currently playing, so
clear old runs from the title screen before starting a new one.

**Deleting an AP save cannot be undone.** The run can only be regenerated,
not resumed.

**If a run's save goes missing**, whether you moved it or deleted it and
changed your mind, connecting to that seed will say so and wait. Put the save file
back and reconnect and the run continues as before. Press **New Game** and
the seed starts over from scratch. Nothing is thrown away until you press
it.

---

## Known issues

**A BookSanity check can lag behind the shelving that earned it.** The game
marks a book correctly placed slightly after it tells the mod the book was
shelved, so a check can occasionally miss its moment. If one hasn't
appeared, pull the book off the shelf and place it again; that sends it
immediately.

**A book can turn invisible the moment you pick it up** (hidden-book modes).
It looks fine on the shelf and stays grabbable, and it's random: different
books each session. Throw it out of bounds and the game's own stray-book
recovery returns it, visible, a few seconds later. Reloading also clears it.
Nothing is lost either way and your save is never affected.

This one is not fixable from the mod's side. The book's render proxy gets
stuck below the layer the mod can reach: every readable property matches a
healthy book, and rebuilding the proxy every way the engine allows produces
an equally invisible one. Only a brand-new component clears it, which is
what a reload or the out-of-bounds recovery gives you.

---

## Reporting issues

When reporting a problem, please include:

1. Your YAML (or at least the `Librarian:` section).
2. The relevant chunk of `UE4SS.log` (last 100–200 lines after the
   issue).
3. What you expected vs. what happened.

---

## Credits

AP integration: Str8UpWHITE64.
Original game: Librarian: Tidy Up the Arcane Library! (developer credit
remains with the game's publisher).

## Third-party software

This repository bundles **UE4SS** (Universal UE Script System) under its
MIT License (copyright (c) 2022 Narknon). The bundled copy is unmodified.
See [`third_party/UE4SS/README.md`](third_party/UE4SS/README.md) for the
exact build, upstream link, and license text.
