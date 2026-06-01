# Librarian: Tidy Up the Arcane Library — Archipelago

An Archipelago multiworld integration for **Librarian: Tidy Up the Arcane
Library!** on Steam.

The mod gates the game's 400 book series and 31 sections behind Archipelago
items. As you complete shelves and milestones, the game sends location
checks to the Archipelago server; in return, you receive item unlocks that
open up new series and bookcases.

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
3. Wait for `AP: World ready — click Continue` to appear (about 10–20
   seconds while the mod wards locked books behind the menu). The
   Continue / Start Game buttons stay disabled until then.
4. Click **Continue** (or **Start Game** if this is a fresh slot) and
   play normally. As you complete shelves, the mod sends location
   checks to Archipelago; received items unlock more series and shelves.

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

### `goal`

How much of the library must be tidied to win.

| Value      | Meaning                                                       |
|------------|---------------------------------------------------------------|
| `full`     | (Default) Complete both floors — game ends naturally          |
| `floor_1`  | Complete Floor 1 only (~176 rows). Floor 2 removed from pool  |
| `floor_2`  | Complete Floor 2 only (~224 rows). Floor 1 removed from pool  |
| `custom`   | Configurable row count via `custom_goal_row_count`            |

### `custom_goal_row_count`

When `goal: custom`, the number of rows needed to win. Range 1–400.
Supports `random`, `random-low`, `random-high`. Default 200.

### `starting_series_count`

How many series the player begins with unlocked. Range 5–25. Default 10.
The starting set is randomized per seed but always includes at least one
series whose shelf row is on the starting bookcase, so the first check
is always reachable.

### `series_per_unlock`

How many series each `Progressive Series Unlock` item grants. Range 3–10.
Default 5. Lower values mean more items in the pool, each with smaller
impact; higher values mean fewer items, each more impactful.

Books from locked (warded) series stay visible on the shelves but can't
be picked up or collided with — you walk through them, and the
"look through the pile" experience preserves the game's visual density.

### `only_unward_shelfable_books`

Toggle (default `false`). Controls how strictly books are gated by
shelf unlocks.

**Off (default)** — A series's books are pickable as soon as either
(a) the section's first bookcase is open, or (b) the series has
`shelf_req == 1` (lives on bookcase 1 of its section). So the
"first 4" series of every section become pickable as soon as you
receive their series unlock, even if no shelf in that section is
open yet. Higher-`shelf_req` series stay warded until their target
bookcase is open.

**On** — Stricter. A series's books stay warded until you have **both**
the series unlock **and** enough Progressive Shelf Unlocks for that
section to reach the series's home bookcase. No visibility floor — if
a section has zero bookcases open, none of its series are pickable.

The difference only matters for sections that haven't been opened at
all yet — once you have any shelf unlock in a section, both modes
behave identically.

> **v1.0.3 note**: cumulative-book-placement milestones
> (`Milestone: N Books Placed`) were removed from the seed entirely in
> v1.0.3, regardless of this option. The 22 milestone slots were
> replaced with finer-grained row-completion thresholds
> (`Complete N Rows`) so the pool size stays the same. The book-count
> tracking infrastructure on the Lua side is preserved for future use.

---

## Verifying the install

When you launch the game, the UE4SS log
(`<Game>\Librarian\Binaries\Win64\UE4SS.log`) should include lines like:

```
[Lua] [LibrarianAP] LibAP v1.1.0-beta1 — Game v1.0.8 (verified compatible)
[Lua] [BPModLoaderMod] Actor: ModActor_C /Game/Librarian/Map/...
[Lua] [LibrarianAP] Press F4 to toggle the connection menu.
[Lua] [LibrarianAP] Press F12 to connect to Archipelago.
```

If you see those, both the Lua mod and the BP pak are loaded correctly.

If the connection menu doesn't appear at the title screen, check the
log for `[menu]` lines. The most common issues are a server URL the
client can't reach or a slot name that doesn't match the YAML.

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
