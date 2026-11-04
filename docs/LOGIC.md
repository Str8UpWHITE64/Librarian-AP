# Logic and gameplay rules

How unlock modes and check modes fit together, and the rules to know while playing.

## Unlock and check modes

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

## While you play

- Stuck, or not sure what is left? Press **F8** in the library. The HUD shows
  how many books you have unwarded, on their shelf and loose, and the full
  picture goes into that session's log, `Mods\Librarian-AP\logs\AP_<date>_<time>.log`: every
  section's open bookcases and, for any series that needs attention, which
  volumes are loose, on the wrong shelf, or out of order. When you ask for
  help, that log is the one file to send.
- With count checks, a book left in a wrong slot does not count. The HUD
  names it after a few seconds and reminds you until it moves.
- A row only counts when every volume is in its own slot. If a row is full
  but out of order, the HUD names it and says how many volumes are out of
  place, and repeats once a minute until it is fixed.
- Working connection details are saved back to
  `Mods\Librarian-AP\Scripts\ap_config.json` after a successful connect,
  so the menu prefills with your last-used values on the next launch.
  You can also pre-populate this JSON if you'd rather not type fields
  each time.
- Your AP progress is saved in a per-seed save slot named
  `Sav_AP_<seed>_<slot>.sav`, separate from your normal save. The
  original `Sav.sav` is left alone.
- **F9** is a direct-connect shortcut that bypasses the menu and uses
  whatever's currently in `ap_config.json`. Useful for quick reconnects.
  (Before 3.0.0 it was F12, which Steam uses for screenshots.)
- If you ever see visual artifacts (e.g., a book showing in an
  unexpected place), going to the title screen and clicking Continue
  again will force a clean world reload.

Reaching your goal opens the way out. Walk to the door and use it to play the game's own ending; your victory reaches Archipelago a few seconds after the cutscene starts. If you do not walk over, it is sent on its own five minutes later.
