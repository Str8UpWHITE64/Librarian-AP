# Troubleshooting

## Steam Deck and Linux (Proton)

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
the override. `n,b` means "native, then built-in" — load the bundled
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

## Checking the install

When you launch the game, the UE4SS log
(`<Game>\Librarian\Binaries\Win64\UE4SS.log`) should include lines like:

```
[Lua] [LibrarianAP] LibAP v3.0.2 — Game v1.0.13 (verified compatible)
[Lua] [BPModLoaderMod] Actor: ModActor_C /Game/Librarian/Map/...
[Lua] [LibrarianAP] Press F4 to toggle the connection menu.
[Lua] [LibrarianAP] Press F9 to connect to Archipelago.
```

If you see those, both the Lua mod and the BP pak are loaded correctly.

If the connection menu doesn't appear at the title screen, check the
log for `[menu]` lines. The most common issues are a server URL the
client can't reach or a slot name that doesn't match the YAML.

## Managing save files

Each AP run claims one of the game's save slots, in the **20–30** range.
Your own saves use the lower slots and are never touched.

**To delete an old run**, right-click its slot in the **Load** menu at the
title screen and confirm. You can also do it from the Save menu in-game.
Either way the mod clears its own record of that run at the same time, so
there is nothing to tidy up by hand.

Note the game won't let you delete the save you're currently playing, so
clear old runs from the title screen before starting a new one.

**If all eleven AP slots are in use**, a new seed refuses to start: the mod
disconnects and tells you so instead of letting the game save the new run
over one of your own slots. Click **Close** on the AP window, open **Load**,
delete an old AP save in the 20–30 range, then restart the game and connect
again.

**Deleting an AP save cannot be undone.** The run can only be regenerated,
not resumed.

**If the mod says the save does not match**, checks are paused until it
does. There are two messages:

- *Book layout does not match this run's last save.* Usually you loaded a
  different slot; load the run's own slot and carry on. If you are sure this
  is the run's save (you restored it from a backup, say), press **F7** to
  accept it. The mod re-checks that nothing on the shelves is a book this run
  never unlocked, then records this save as the run's and resumes.
- *This save holds books this run never unlocked.* That save belongs to
  another game and cannot be accepted. Load the run's own slot, or delete
  the AP save from the Load menu and start the seed over.

The match record is kept on your machine, not on the server, so there is
nothing to reset there.

**If a run's save goes missing**, whether you moved it or deleted it and
changed your mind, connecting to that seed will say so and wait. Put the save file
back and reconnect and the run continues as before. Press **New Game** and
the seed starts over from scratch. Nothing is thrown away until you press
it.


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

## Reporting a bug

When reporting a problem, please include:

1. Your YAML (or at least the `Librarian:` section).
2. The log. The mod keeps one file per launch under
   `<Game>\Librarian\Binaries\Win64\Mods\Librarian-AP\logs\` (the newest
   ten), so attach the file for the session where it happened; `UE4SS.log`
   in `Win64` holds only the most recent launch.
3. What you expected vs. what happened.
