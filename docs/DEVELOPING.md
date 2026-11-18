# Developing

Building and installing from a source checkout.

## Install from source

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
<Win64>\Mods\mods.txt                          (this repo's version)
<Win64>\Mods\Librarian-AP\Scripts\main.lua
<Win64>\Mods\Librarian-AP\Scripts\AP\...
<Win64>\Mods\Librarian-AP\Scripts\ap_config.json
```

#### 3. Install the BP companion pak

Copy `LibrarianAPHUDFix.pak` from the repo root into:

```
<Game>\Librarian\Content\Paks\LogicMods\
```

This pak contains the connection-menu widget, the HUD-refresh code,
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
