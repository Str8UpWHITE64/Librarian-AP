# Librarian: Tidy Up the Arcane Library — Archipelago

An [Archipelago](https://archipelago.gg) randomizer for **Librarian: Tidy Up the Arcane Library!**

The mod locks the game's 400 book series and 31 sections behind items. Shelving books sends checks. Items from the multiworld unlock more books and bookcases.

## What you need

- [Librarian: Tidy Up the Arcane Library!](https://store.steampowered.com/app/4197610/Librarian_Tidy_Up_the_Arcane_Library/) on Steam (game 1.0.12 or 1.0.13).
- [Archipelago](https://github.com/ArchipelagoMW/Archipelago/releases) 0.6.4 or newer.
- UE4SS (experimental build). It is bundled in the release zip, so you do not download it.

## Install

The game folder is `Librarian Tidy Up the Arcane Library!` in your Steam `steamapps/common` folder.

1. Open the [latest release](../../releases/latest) and download both files: `Librarian-AP_v<version>.zip` and `librarian.apworld`.
2. Extract the zip anywhere. It holds a `Librarian/` folder.
3. Drag `Librarian/` onto the game folder. Say yes to merge.
4. Copy `librarian.apworld` into `custom_worlds/` in your Archipelago folder.
5. Steam Deck or Linux only: add a launch option. See [Troubleshooting](docs/TROUBLESHOOTING.md#steam-deck-and-linux-proton).

Upgrading: do the same steps. Regenerate any seed you have not started yet.

Where the files land:

- `Librarian/Binaries/Win64/Mods/Librarian-AP/` (the mod and `Scripts/ap_config.json`)
- `Librarian/Content/Paks/LogicMods/LibrarianAPHUDFix.pak`

## Play

1. Restart Archipelago. Click **Generate Template Options** and open `Librarian Tidy Up the Arcane Library.yaml`.
2. Set `name: Player1` and any options you want. Put the file in `Players/`.
3. Click **Generate**. Host the `.archipelago` file, or upload it.
4. Start the game. The Archipelago Connection menu opens at the title screen. Press **F4** to show or hide it.
5. Enter the server (for example `localhost:38281`), your slot name (`Player1`) and the password, if any. Click **Connect**.
6. The mod starts or loads the run for you. Wait 10 to 20 seconds while the shelves are set up.
7. Shelve books. Checks go out, items come in. When you reach your goal, the way out opens. Walk to the door.

Handy keys: **F8** shows what is left, **F9** reconnects with your saved details.

## Logs

The mod writes one log per launch to `Librarian/Binaries/Win64/Mods/Librarian-AP/logs/`. With a bug report, send the newest log file and your YAML.

## Known issues

- A BookSanity check can lag a moment behind the book that earned it. Pick the book up and place it again.
- A hidden book can turn invisible when you pick it up. Reload, or throw it out of bounds.

More in [Troubleshooting](docs/TROUBLESHOOTING.md).

## More

- [Options](docs/OPTIONS.md): every YAML option
- [Logic and rules](docs/LOGIC.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Developing](docs/DEVELOPING.md): build from source
- Credits: AP integration by Str8UpWHITE64. The game belongs to its developer and publisher.
- Licence: MIT, see [`LICENSE`](LICENSE). The bundled UE4SS is also MIT licensed, see [`third_party/UE4SS/README.md`](third_party/UE4SS/README.md).
