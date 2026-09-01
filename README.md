# Librarian: Tidy Up the Arcane Library — Archipelago

An Archipelago multiworld integration for **Librarian: Tidy Up the Arcane
Library!** on Steam.

The mod gates the game's 400 book series and 31 sections behind Archipelago
items. As you complete shelves and milestones, the game sends location
checks to the Archipelago server; in return, you receive item unlocks that
open up new series and bookcases.

If you want something far more granular, **BookSanity** turns every one of
the ~3,072 individual books into its own item and its own check. See
`unlock_mode` below.

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

All options go under your `Librarian:` section in the YAML.

### `unlock_mode`

How books become available. This is the biggest choice in the YAML: it
changes the size and shape of the item pool, and what the other options
mean.

| Value                       | Meaning                                                                  |
|-----------------------------|--------------------------------------------------------------------------|
| `progressive_unlocks`       | (Default) Series unlock in groups of `series_per_unlock`. Smallest pool. |
| `individual_series_unlocks` | Each of the ~400 series is its own item. Every bookcase starts open.     |
| `booksanity`                | Every one of the ~3,072 books is its own item **and** its own check.     |

In `booksanity`, every bookcase starts open and you send a check for each
book you place correctly. Items arrive as `Book: <Series> Vol N`; the
matching checks read `Book: <Section> - <Series> Vol N`. A floor goal is
recommended, since the full goal is slow to generate at that size.

Locked books can't be taken in any mode, including by the magic skills:
Assemble won't pull one into your bag, and Insight won't reveal one.

### `goal`

How much of the library must be tidied to win.

| Value      | Meaning                                                       |
|------------|---------------------------------------------------------------|
| `full`     | (Default) Complete both floors — game ends naturally          |
| `floor_1`  | Complete Floor 1 only (~176 rows). Floor 2 removed from pool  |
| `floor_2`  | Complete Floor 2 only (~224 rows). Floor 1 removed from pool  |
| `custom`   | A count you choose — see below. Works in all three unlock modes |

With `custom`, the seed is trimmed to roughly what your goal needs plus
`spare_book_item_percent` slack. Sections past that leave the pool entirely,
rather than remaining as checks holding items nobody will collect.

### `custom_goal_row_count`

When `goal: custom`, the number of rows needed to win. Range 1–400.
Supports `random`, `random-low`, `random-high`. Default 200.

Used by `progressive_unlocks` and `individual_series_unlocks`. In
`booksanity` the goal counts books instead, so `custom_goal_book_count`
applies there and this is ignored.

### `custom_goal_book_count`

When `goal: custom` **and** `unlock_mode: booksanity`, the number of
correctly shelved books needed to win. Range 1–3072. Default 1500.
Supports `random`, `random-low`, `random-high`. Ignored for every other
goal and unlock mode.

Note the scale: the library holds 3072 books across 400 rows, so a
row-shaped number here is a far shorter run than it looks. The default of
1500 is about half the library, which lands near the size of a floor goal.

A custom book goal is also the fastest way to play BookSanity — it
sidesteps the full goal's slow generation entirely.

### `spare_book_item_percent`

Range 0-20. Default 10. `progressive_unlocks` only.

**Renamed from `extra_series_percent` in 2.0.3. Regenerate your YAML to update
the name.**

How much slack to leave beyond what your goal actually needs. A goal that needs
every last unlock is fragile in a multiworld: one item sitting in a stalled or
abandoned game can leave you stuck for good. This gives you a margin, so you
need most of what the seed holds rather than all of it, which should cut down on
getting BK'd.

It does that two ways, depending on the goal:

| goal | what it does |
|---|---|
| `custom` | Grows the trimmed seed. A 200-row goal at 10 keeps about 220 rows instead of 200, and the extra rows bring extra unlocks with them. |
| `full` / `floor_1` / `floor_2` | The seed already holds everything, so there is nothing to grow. It adds that percentage of extra `Progressive Series Unlock` items to the pool instead, replacing filler. |

On a 200-row custom goal: 0 gives no margin, 10 gives about three spare unlocks,
20 gives about eight.

The cap is 20. Past that it starts costing `spare_shelf_items` whole steps, and
on a custom goal a bigger margin mostly just re-adds the surplus checks the trim
exists to remove.

In `individual_series_unlocks` and `booksanity` every series or book is its own
specific item, so a duplicate unlocks nothing and the spare-copy half does
nothing. A `custom` goal there still trims the seed by this percentage.

### `spare_shelf_items`

Range 0-3. Default 0. Full and floor goals, `progressive_unlocks` only.

The same for bookcases, as a count per bookcase rather than a percentage, since
sections hold as few as three. It adds an extra N `Progressive Shelf Unlock`
items for each section, so any section can lose that many copies to a stalled
game and still open fully.

This is the most expensive setting in the YAML. Every step is one item slot per
bookcase, 71 of them at the full goal, all replacing filler:

| `spare_shelf_items` | shelf unlocks | filler left |
|---------------------|---------------|-------------|
| 0 | 69 | 244 |
| 1 | 140 | 173 |
| 2 | 211 | 102 |
| 3 | 282 | 31 |

*(full goal, `series_per_unlock: 5`, `spare_book_item_percent: 0`)*

A seed without room drops back a step rather than failing, and says so during
generation, so asking for more than fits costs nothing. How much room there is
depends on the goal and on `series_per_unlock`, so tighter configurations keep
fewer steps: a `floor_1` seed with `series_per_unlock: 3` takes 2, not 3.

Spares past the cap do nothing. The mod already stops applying unlocks past the
last series and the last bookcase.

Ignored in `individual_series_unlocks` and `booksanity`, which start with every
bookcase already open.

### `starting_series_count`

How many series the player begins with unlocked. Range 5–25. Default 10.
The starting set is randomized per seed but always includes at least one
series whose shelf row is on the starting bookcase, so the first check
is always reachable.

In `booksanity` this counts series' *worth* of books rather than whole
series: each one rolls a series size (3, 5 or 10 volumes), so a count of 5
starts you with roughly 15 to 50 individual books.

### `series_per_unlock`

How many series each `Progressive Series Unlock` item grants. Range 3–10.
Default 5. Lower values mean more items in the pool, each with smaller
impact; higher values mean fewer items, each more impactful.

Only applies to `progressive_unlocks`; the other unlock modes hand out
series or books individually.

### `book_visibility`

What locked books look like before you unlock them.

| Value    | Meaning                                                                  |
|----------|--------------------------------------------------------------------------|
| `hidden` | (Default) Locked books are invisible. The library fills in as you unlock. |
| `stacks` | Locked books stay visible but can't be taken; you walk through them.      |

`stacks` keeps the shelves looking full, and avoids the hidden-book display
glitch noted under Known issues.

### `local_filler`

Toggle (default `true`). Keeps this game's filler items in your own world
instead of scattering them across the multiworld. Your meaningful items
still circulate normally. Recommended, since Librarian adds a lot of
checks. No effect in a solo game.

### `only_unward_shelfable_books`

Toggle (default `true`). Controls how strictly books are gated by
shelf unlocks.

**On (default)** — A book stays hidden until its series **and** its bookcase are
both open. This is the default so you never have to shuffle series around: you
need **both** the series unlock **and** enough Progressive Shelf Unlocks for that
section to reach the series's home bookcase. No visibility floor — if a section
has zero bookcases open, none of its series are pickable.

**Off** — Books are unhidden and grabbable as soon as they are sent to you,
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
[Lua] [LibrarianAP] LibAP v2.0.0 — Game v1.0.13 (verified compatible)
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
