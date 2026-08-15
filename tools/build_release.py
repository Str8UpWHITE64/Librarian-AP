#!/usr/bin/env python3
"""Build a Librarian-AP release.

Produces two independent artifacts in <output_dir> (default: dist/),
neither of which contains the other:

    dist/librarian.apworld                Standalone apworld (a zip with the
                                          extension renamed). Drop into
                                          <Archipelago>/custom_worlds/ to
                                          generate / host seeds.

    dist/Librarian-AP_v<version>.zip      Player-side game-files archive.
                                          Layout:

        ├── INSTALL.txt
        └── Librarian/                    (drop into the game install root)
            ├── Binaries/
            │   └── Win64/
            │       ├── dwmapi.dll
            │       ├── UE4SS.dll
            │       ├── UE4SS-settings.ini
            │       ├── LICENSE           (UE4SS MIT)
            │       └── Mods/
            │           ├── BPModLoaderMod/   (+ other stock UE4SS mods)
            │           ├── shared/
            │           ├── mods.txt      (our version, enables Librarian-AP)
            │           └── Librarian-AP/ (the Lua mod)
            └── Content/
                └── Paks/
                    └── LogicMods/
                        └── LibrarianAPHUDFix.pak

Run from anywhere:

    python tools/build_release.py
    python tools/build_release.py --version 1.0.4-rc1
    python tools/build_release.py --output-dir releases/

The script uses only the Python stdlib (zipfile, shutil, pathlib, json).
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

# Repo root = parent of the directory this script lives in.
REPO_ROOT = Path(__file__).resolve().parent.parent

# Source paths (inputs).
UE4SS_DIR        = REPO_ROOT / "third_party" / "UE4SS"
UE4SS_DWMAPI     = UE4SS_DIR / "dwmapi.dll"
UE4SS_INNER      = UE4SS_DIR / "ue4ss"          # -> goes into Win64/
LIBRARIAN_AP_DIR = REPO_ROOT / "Librarian-AP"   # the Lua mod folder
MODS_TXT         = REPO_ROOT / "mods.txt"       # our version of mods.txt
HUD_PAK          = REPO_ROOT / "LibrarianAPHUDFix.pak"
APWORLD_SRC      = REPO_ROOT / "apworld" / "librarian"
ARCHIPELAGO_JSON = APWORLD_SRC / "archipelago.json"

# Output dir (created on demand).
DEFAULT_OUTPUT_DIR = REPO_ROOT / "dist"

# Build artefacts that should NOT be packaged into either zip.
# probe.lua is a dev harness: ~2,200 lines that only load when PROBE_MODE is
# explicitly true, which it never is in a release. Keeping it in the repo is
# useful; shipping 116KB of it to players is not.
EXCLUDE_PATTERNS = ("__pycache__", ".pyc", ".pyo", ".DS_Store", "Thumbs.db",
                    ".git", ".idea", ".vscode", "probe.lua")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(f"  {msg}")


def step(msg: str) -> None:
    print(f"==> {msg}")


def should_skip(name: str) -> bool:
    """True if a file/dir name matches any EXCLUDE_PATTERNS entry."""
    return any(pat in name for pat in EXCLUDE_PATTERNS)


def copy_tree(src: Path, dst: Path) -> None:
    """Mirror src -> dst, skipping excluded names. Overwrites if dst exists."""
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(
        src, dst,
        ignore=lambda _root, names: [n for n in names if should_skip(n)],
    )


def read_version() -> str:
    if not ARCHIPELAGO_JSON.exists():
        fail(f"Missing {ARCHIPELAGO_JSON.relative_to(REPO_ROOT)} — cannot read version.")
    try:
        data = json.loads(ARCHIPELAGO_JSON.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail(f"Could not parse {ARCHIPELAGO_JSON.name}: {e}")
    v = data.get("world_version")
    if not v:
        fail(f"{ARCHIPELAGO_JSON.name} has no 'world_version' field.")
    return str(v)


def validate_inputs() -> None:
    """Bail fast if any required source path is missing."""
    required = {
        "UE4SS dwmapi.dll":  UE4SS_DWMAPI,
        "UE4SS inner dir":   UE4SS_INNER,
        "UE4SS UE4SS.dll":   UE4SS_INNER / "UE4SS.dll",
        "UE4SS Mods dir":    UE4SS_INNER / "Mods",
        "Lua mod folder":    LIBRARIAN_AP_DIR,
        "mods.txt":          MODS_TXT,
        "HUD pak":           HUD_PAK,
        "apworld source":    APWORLD_SRC,
        "archipelago.json":  ARCHIPELAGO_JSON,
    }
    missing = [(label, p) for label, p in required.items() if not p.exists()]
    if missing:
        print("ERROR: Required source(s) missing:", file=sys.stderr)
        for label, p in missing:
            print(f"  - {label}: {p.relative_to(REPO_ROOT)}", file=sys.stderr)
        sys.exit(1)


# --------------------------------------------------------------------------
# Build steps
# --------------------------------------------------------------------------

def build_apworld(output_dir: Path) -> Path:
    """Build librarian.apworld as a standalone output in <output_dir>/.

    An .apworld file is just a zip with the extension renamed. The zip's
    root contains a single 'librarian/' folder mirroring apworld/librarian/
    (Archipelago's expected layout for custom_worlds/).

    Emitted as a primary output (not just a side effect of the release zip)
    so it can be uploaded to an AP server independently of the player-side
    game bundle.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    out = output_dir / "librarian.apworld"
    if out.exists():
        out.unlink()
    step("Building librarian.apworld")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(APWORLD_SRC.rglob("*")):
            if any(should_skip(part) for part in path.parts):
                continue
            if path.is_file():
                arcname = Path("librarian") / path.relative_to(APWORLD_SRC)
                zf.write(path, arcname.as_posix())
    info(f"wrote {out.relative_to(REPO_ROOT)} ({out.stat().st_size:,} bytes)")
    return out


def build_game_tree(staging: Path) -> Path:
    """Assemble the <staging>/Librarian/ tree mirroring the game install layout."""
    step("Assembling Librarian/ game tree")
    game = staging / "Librarian"
    win64 = game / "Binaries" / "Win64"
    mods_dir = win64 / "Mods"
    pak_dir = game / "Content" / "Paks" / "LogicMods"

    mods_dir.mkdir(parents=True, exist_ok=True)
    pak_dir.mkdir(parents=True, exist_ok=True)

    # UE4SS top-level files (dwmapi.dll lives one level up from ue4ss/).
    shutil.copy2(UE4SS_DWMAPI, win64 / "dwmapi.dll")
    info("copied dwmapi.dll")

    # UE4SS inner contents (UE4SS.dll, settings, LICENSE, Mods/).
    # ue4ss/* (NOT the ue4ss folder itself) lands directly under Win64/,
    # mirroring the README's install instructions. Mods/ from upstream
    # carries the stock mod set; we overwrite mods.txt below.
    for child in sorted(UE4SS_INNER.iterdir()):
        if should_skip(child.name):
            continue
        dst = win64 / child.name
        if child.is_dir():
            copy_tree(child, dst)
        else:
            shutil.copy2(child, dst)
    info("copied UE4SS.dll + UE4SS-settings.ini + LICENSE + Mods/")

    # Overwrite mods.txt with our version (enables Librarian-AP, keeps the
    # rest of the stock layout).
    shutil.copy2(MODS_TXT, mods_dir / "mods.txt")
    info("overwrote Mods/mods.txt with repo version (enables Librarian-AP)")

    # The Lua mod folder.
    copy_tree(LIBRARIAN_AP_DIR, mods_dir / "Librarian-AP")
    info("copied Librarian-AP/ Lua mod")

    # The BP companion pak.
    shutil.copy2(HUD_PAK, pak_dir / HUD_PAK.name)
    info(f"copied {HUD_PAK.name} -> Content/Paks/LogicMods/")

    return game


def write_install_txt(staging: Path, version: str) -> Path:
    """Write the top-level INSTALL.txt that walks new players through extraction."""
    step("Writing INSTALL.txt")
    out = staging / "INSTALL.txt"
    out.write_text(
        "Librarian-AP v" + version + " -- installation\n"
        "============================================\n"
        "\n"
        "Game side (this zip)\n"
        "--------------------\n"
        "\n"
        "Extract this zip somewhere temporary, then drag the 'Librarian/'\n"
        "folder into your Steam install directory. The default path is:\n"
        "\n"
        "    C:\\Program Files (x86)\\Steam\\steamapps\\common\\Librarian Tidy Up the Arcane Library!\\\n"
        "\n"
        "Windows will ask whether to merge / overwrite -- say yes. The files\n"
        "land at:\n"
        "\n"
        "    <Game>\\Librarian\\Binaries\\Win64\\dwmapi.dll        (UE4SS bootstrap)\n"
        "    <Game>\\Librarian\\Binaries\\Win64\\UE4SS.dll         (UE4SS main)\n"
        "    <Game>\\Librarian\\Binaries\\Win64\\Mods\\             (UE4SS mods + this AP mod)\n"
        "    <Game>\\Librarian\\Content\\Paks\\LogicMods\\LibrarianAPHUDFix.pak\n"
        "\n"
        "Server side (separate download)\n"
        "-------------------------------\n"
        "\n"
        "The Archipelago apworld is shipped as a separate file alongside\n"
        "this zip:\n"
        "\n"
        "    librarian.apworld\n"
        "\n"
        "Drop that file into your Archipelago install's 'custom_worlds/'\n"
        "folder. Restart Archipelago, click 'Generate Template Options',\n"
        "and edit Librarian Tidy Up the Arcane Library.yaml.\n"
        "\n"
        "Licensing\n"
        "---------\n"
        "\n"
        "UE4SS is bundled under the MIT License (copyright (c) 2022 Narknon).\n"
        "The full license text is preserved at:\n"
        "\n"
        "    Librarian/Binaries/Win64/LICENSE\n"
        "\n"
        "It covers the UE4SS files only (UE4SS.dll, dwmapi.dll, and the stock\n"
        "Mods that ship with UE4SS). The Librarian-AP mod itself is\n"
        "maintained separately; see the project README for credits.\n"
        "\n"
        "Reporting bugs\n"
        "--------------\n"
        "\n"
        "If something breaks, capture:\n"
        "  - Your YAML (or at least the Librarian: section)\n"
        "  - The last 100-200 lines of <Win64>\\UE4SS.log after the issue\n"
        "  - What you expected vs. what happened\n",
        encoding="utf-8",
    )
    info(f"wrote {out.name}")
    return out


def build_release_zip(staging: Path, output_dir: Path, version: str) -> Path:
    """Zip the staging dir into <output_dir>/Librarian-AP_v<version>.zip.

    Player-side bundle only (Librarian/ tree + INSTALL.txt). The apworld
    is emitted alongside this zip as a separate file in <output_dir>/, so
    server hosts can grab just that one file without downloading the
    full game-side archive.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    out = output_dir / f"Librarian-AP_v{version}.zip"
    if out.exists():
        out.unlink()
    step(f"Building release zip -> {out.relative_to(REPO_ROOT)}")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(staging.rglob("*")):
            if any(should_skip(part) for part in path.parts):
                continue
            if path.is_file():
                arcname = path.relative_to(staging)
                zf.write(path, arcname.as_posix())
    info(f"wrote {out.name} ({out.stat().st_size:,} bytes)")
    return out


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--version",
        help="Override the version string (default: read from "
             "apworld/librarian/archipelago.json:world_version).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Where to write the release zip (default: {DEFAULT_OUTPUT_DIR.relative_to(REPO_ROOT)}).",
    )
    parser.add_argument(
        "--keep-staging",
        action="store_true",
        help="Don't delete the staging directory after building (useful for debugging).",
    )
    args = parser.parse_args()

    validate_inputs()
    version = args.version or read_version()
    step(f"Librarian-AP release build -- v{version}")

    # Build into a temp staging dir, then zip. Caller can opt in to keeping
    # the staging dir for inspection via --keep-staging. Two independent
    # artifacts land in <output_dir>/: the standalone apworld for AP
    # servers, and the player-side release zip with the game tree.
    staging_root = Path(tempfile.mkdtemp(prefix="librarian-ap-build-"))
    try:
        out_apworld = build_apworld(args.output_dir)
        build_game_tree(staging_root)
        write_install_txt(staging_root, version)
        out_zip = build_release_zip(staging_root, args.output_dir, version)
    finally:
        if args.keep_staging:
            print(f"  (kept staging dir: {staging_root})")
        else:
            shutil.rmtree(staging_root, ignore_errors=True)

    step("Done. Artifacts:")
    print(f"  {out_apworld}")
    print(f"  {out_zip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
