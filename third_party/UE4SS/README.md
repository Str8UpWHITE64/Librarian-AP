# UE4SS (bundled third-party dependency)

This folder contains an unmodified copy of the **UE4SS** experimental build
that Librarian-AP is currently developed and tested against. It is bundled
in this repository because the upstream `experimental-latest` GitHub release
is overwritten in place each time a new experimental build is published, so
direct links to a specific commit's zip stop resolving once that commit is
superseded.

## Bundled version

- **Build**: `UE4SS_v3.0.1-946-g265115c0`
- **Upstream commit**: `265115c0`
- **Upstream repo**: <https://github.com/UE4SS-RE/RE-UE4SS>
- **Project**: UE4SS-RE / RE-UE4SS

## License

UE4SS is distributed under the **MIT License**, copyright (c) 2022 Narknon.
The full license text is preserved in two places:

- `./LICENSE` (surfaced copy at the top of this folder for visibility)
- `./ue4ss/LICENSE` (original location inside the upstream archive)

Both are byte-identical to the upstream `LICENSE` file. No modifications
have been made to UE4SS binaries or files.

## What's in here

```
third_party/UE4SS/
├── LICENSE              MIT license text (surfaced copy)
├── README.md            this file
├── dwmapi.dll           UE4SS bootstrap (ASI loader shim)
└── ue4ss/
    ├── LICENSE          MIT license text (original)
    ├── UE4SS.dll        the main UE4SS module
    ├── UE4SS-settings.ini
    └── Mods/
        ├── BPModLoaderMod/
        ├── shared/
        └── (other stock UE4SS mods)
```

## Installation

See the main repository README (`Installation` → `1. Install UE4SS`). The
short version: copy `dwmapi.dll` and the **contents** of the `ue4ss/`
folder (not the folder itself) into the game's `Librarian\Binaries\Win64\`
directory.

## Updating

When upstream ships a new experimental build that we want to roll forward
to:

1. Download the new build zip from <https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest>.
2. Extract it on top of `third_party/UE4SS/`, overwriting `dwmapi.dll` and
   the entire `ue4ss/` subfolder.
3. Refresh the surfaced `./LICENSE` copy from `./ue4ss/LICENSE` (in case
   upstream ever changes the license text).
4. Update the **Bundled version** section above with the new build name
   and commit short hash.
5. Smoke-test the mod against the new build before committing the update.
