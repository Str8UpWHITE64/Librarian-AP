"""
Librarian: Tidy Up the Arcane Library! — Archipelago data

Source of truth for the library's section / series / volume structure.
This module is consumed by:
    - apworld/librarian/Items.py     (item generation)
    - apworld/librarian/Locations.py (location generation)
    - apworld/librarian/__init__.py  (logic rules)

Counts derived from this data:
    Sections: 31  (14 on floor 1 + 17 on floor 2)
    Series:   400 (one per shelf row — matches in-game 0/400 row counter)
    Volumes:  3072 (matches in-game 0/3072 book counter)
    Series-size distribution: 256 ten-volume, 40 five-volume, 104 three-volume.

Series volume counts are always 3, 5, or 10 — enforced by Series.__post_init__.

All series names match in-game text exactly (400/400 verified against the
game's book table). Some entries contain non-ASCII characters from the
game's text (smart quotes, fullwidth W in 1B Self-Ｗriting, etc.) — these
are intentional, not typos. Use UTF-8 when reading this file.
"""

from __future__ import annotations
from dataclasses import dataclass


# ============================================================================
# Type definitions
# ============================================================================


@dataclass(frozen=True)
class Series:
    """A multi-volume work that fills exactly one shelf row."""
    name: str
    volumes: int  # always 3, 5, or 10

    def __post_init__(self):
        if self.volumes not in (3, 5, 10):
            raise ValueError(
                f"Series '{self.name}' has invalid volume count {self.volumes} "
                f"(must be 3, 5, or 10)"
            )


@dataclass(frozen=True)
class Section:
    """A library section. Contains multiple shelf rows (one per series)."""
    id: str          # e.g., "1A", "2Q"
    name: str        # e.g., "Monsterology"
    floor: int       # 1 or 2
    color: str       # color-theme description (for flavor / UI hints)
    series: tuple[Series, ...]

    def __post_init__(self):
        if self.floor not in (1, 2):
            raise ValueError(f"Section {self.id} has invalid floor {self.floor}")
        if not self.series:
            raise ValueError(f"Section {self.id} has no series")
        # Section IDs must be like "1A".."1N" or "2A".."2Q"
        if len(self.id) != 2 or not self.id[0].isdigit() or not self.id[1].isalpha():
            raise ValueError(f"Section id '{self.id}' is malformed (expected '<floor><letter>')")

    @property
    def shelf_count(self) -> int:
        return len(self.series)

    @property
    def volume_count(self) -> int:
        return sum(s.volumes for s in self.series)

    @property
    def bookcase_count(self) -> int:
        """Number of physical bookcase actors in this section.

        Empirically observed in M01 via the F10 runtime probe (CabinetLabel +
        BookOrderIndex bridge). These are the AUTHORITATIVE counts — drives
        the per-section Progressive Shelf Unlock item quantity.
        """
        return _BOOKCASE_COUNT_BY_SECTION[self.id]


# Per-section bookcase actor counts. Drives Progressive Shelf Unlock item
# quantity per section and the logic rules that gate section access.
# Each value = number of physical bookcase actors in the section in M01.
#
# Physical bookcase types in M01:
#
#   Standard       — 10-vol-series capacity (~4 series per case). Used in
#                    all uniform 10-vol sections and the large cases of
#                    mixed-volume sections.
#   Small          — 5-vol-series capacity (~4 series per case, narrower
#                    physical footprint). Used for the small cases of
#                    mixed-volume sections.
#   Cabinet (tall) — single-case sections wrapped in a Cabinet_01_C alcove.
#                    Hold ~18 series mixing 10-vol and 3-vol:
#                    1C, 1D, 1G, 1H (Floor 1) and
#                    2C, 2D, 2G, 2H, 2K, 2L (Floor 2).
#
# Mixed-volume sections (series of different lengths in one section). Lower
# case indices hold the smaller-volume groups; _compute_shelf_req in
# __init__.py packs them this way so smaller-volume series unlock first.
#
#   1M  5 cases  →  cases 1-2: small (5-vol),  cases 3-5: standard (10-vol)
#   1N  5 cases  →  cases 1-2: small (5-vol),  cases 3-5: standard (10-vol)
#   2M  2 cases  →  case 1:    small (5-vol),  case 2:   standard (10-vol)
#   2N  2 cases  →  case 1:    small (5-vol),  case 2:   standard (10-vol)
#   2O  3 cases  →  cases 1+2: small (5-vol),  case 3:   standard (10-vol)
#                   (game's CountBookCase order for this section is
#                   left-outer / right-outer / middle, NOT left/middle/right;
#                   physical layout is small | standard | small with the
#                   outer pair narrower than the regular small variant —
#                   use BP_WardCover_Smallest on these)
#   2P  2 cases  →  case 1:    small (5-vol),  case 2:   standard (10-vol)
#   2Q  2 cases  →  case 1:    small (5-vol),  case 2:   standard (10-vol)
#
# Tall cabinet sections (single case mixing 10-vol and 3-vol, all series get
# shelf_req=1 since there's only one case to unlock):
#
#   1C, 1D, 1G, 1H  — Floor 1 cabinet sections
#   2C, 2D, 2G, 2H, 2K, 2L  — Floor 2 cabinet sections
_BOOKCASE_COUNT_BY_SECTION: dict[str, int] = {
    "1A": 3, "1B": 3, "1C": 1, "1D": 1, "1E": 3, "1F": 3, "1G": 1,
    "1H": 1, "1I": 3, "1J": 3, "1K": 2, "1L": 2, "1M": 5, "1N": 5,
    "2A": 3, "2B": 3, "2C": 1, "2D": 1, "2E": 3, "2F": 3, "2G": 1,
    "2H": 1, "2I": 3, "2J": 3, "2K": 1, "2L": 1, "2M": 2, "2N": 2,
    "2O": 3, "2P": 2, "2Q": 2,
}


# ============================================================================
# SECTIONS — 31 entries, source of truth
# ============================================================================

SECTIONS: tuple[Section, ...] = (

    # ============== FLOOR 1 — 14 sections ==============

    Section(
        id="1A",
        name="Monsterology",
        floor=1,
        color="brown / dark earthy",
        series=(
            Series("Monsterology: An Introduction to Forbidden Beast", 10),  # AssetIdx 0
            Series("The Illustrated Bestiary: Creatures of Land, Sky, and Sea", 10),  # AssetIdx 1
            Series("Monster Field Notes: A Beastmaster’s Journey", 10),  # AssetIdx 2
            Series("A Pictorial Guide to the Ecology of Monsters", 10),  # AssetIdx 3
            Series("Living with Monsters: A Guide to Care and Training", 10),  # AssetIdx 4
            Series("Monsterology: Language and Vocal Patterns of Monsters", 10),  # AssetIdx 5
            Series("Ecological Pyramid of Monsters", 10),  # AssetIdx 6
            Series("The World Encyclopedia of Dragons", 10),  # AssetIdx 7
            Series("Magical Creatures and Their Spells", 10),  # AssetIdx 8
            Series("Behavioral Patterns of Monsters", 10),  # AssetIdx 9
            Series("Tears of the Beasts: Records of the Extinct and Forgotten", 10),  # AssetIdx 10
            Series("A Field Guide to Monsters: Identification and Survival", 10),  # AssetIdx 11
        ),
    ),

    Section(
        id="1B",
        name="Astrology and Divination",
        floor=1,
        color="dark or light blue",
        series=(
            Series("Prophecy of the Advent of the Great King of Terror", 10),  # AssetIdx 12
            Series("One Right Guess in a Hundred Makes a Seer", 10),  # AssetIdx 13
            Series("Apocalypse of the Heavens: Omens and Warnings", 10),  # AssetIdx 14
            Series("Animal Oracles: Prophesying Match Results", 10),  # AssetIdx 15
            Series("The Seer's Journal: Daily Visions of the Future", 10),  # AssetIdx 16
            Series("The Art of Feng Shui: Reading Dragon Veins and Increasing Luck", 10),  # AssetIdx 17
            Series("The Crystal Tome: Practical Scrying and Clairvoyance", 10),  # AssetIdx 18
            Series("The Abyss of Tarot: A Book of Symbols and Intuition", 10),  # AssetIdx 19
            Series("Book of Constellations: The Thirteen Zodiac Signs That Guide Destiny", 10),  # AssetIdx 20
            Series("Voices of the Oracle: Revelations for the Chosen Listener", 10),  # AssetIdx 21
            Series("Prophecy : Angelic Self-Ｗriting", 10),  # AssetIdx 22
            Series("Prophecy by the Three Witches", 10),  # AssetIdx 23
        ),
    ),

    Section(
        id="1C",
        name="Curses and Dispels",
        floor=1,
        color="black with dark red",
        series=(
            Series("The Grand Compendium of Curses: 100 Hexes and 100 Dispells", 10),  # AssetIdx 24
            Series("The Dark Pact: The Birth of a Curse", 10),  # AssetIdx 25
            Series("The Countercurse Compendium: Magic That Bites Back", 10),  # AssetIdx 26
            Series("Seal and Sever: Lost Rites of Curse-Breaking", 10),  # AssetIdx 27
            Series("The Death's Note", 3),  # AssetIdx 28
            Series("Breaking the Curse of the Trophyless", 3),  # AssetIdx 29
            Series("The Lexicon of Curses: Malefic Words and Their Power", 3),  # AssetIdx 30
            Series("The Book of Curses: Forgotten Plagues and Their Dispells", 3),  # AssetIdx 31
            Series("Reverse Ritual Tracing for Curse Source Identification", 3),  # AssetIdx 32
            Series("Curse-Breaking Arithmancy and Sealing Arts", 3),  # AssetIdx 33
            Series("Advanced Curse Analysis: Multiple Structures and Dissolution Process", 3),  # AssetIdx 34
            Series("Introduction to Malediction Systems: Taxonomy, Structure, and Mechanisms", 3),  # AssetIdx 35
        ),
    ),

    Section(
        id="1D",
        name="Bard and Music",
        floor=1,
        color="green or earthy tones",
        series=(
            Series("Spell Chanting Technique: The Blending of Sound and Spell", 10),  # AssetIdx 36
            Series("The Chronicle of World Music of Magic", 10),  # AssetIdx 37
            Series("A Collection of Chanted Verses: Status Buffing and Nerfing", 10),  # AssetIdx 38
            Series("The Dark Sonata: Music That Attracts Calamity", 10),  # AssetIdx 39
            Series("Theory of Chanting: Principles of Mana Amplification via Voice", 3),  # AssetIdx 40
            Series("Chanting Methods for Resonating with Natural Entities", 3),  # AssetIdx 41
            Series("Magical Psalms: Methodology for Compiling Chanted Poetry", 3),  # AssetIdx 42
            Series("Musical Saint: A Great Figure Who Brought Music to the Masses", 3),  # AssetIdx 43
            Series("Witches’ Hymnal", 3),  # AssetIdx 44
            Series("Theoretical Foundations of Enchanted Music", 3),  # AssetIdx 45
            Series("The Bard’s Book of Spells", 3),  # AssetIdx 46
            Series("Transcendental Magic Etudes of Execution", 3),  # AssetIdx 47
        ),
    ),

    Section(
        id="1E",
        name="Necromancy",
        floor=1,
        color="dark blue or dark purple",
        series=(
            Series("Foundations of Necromancy: On the Fixation and Severance of Souls", 10),  # AssetIdx 48
            Series("Necrodefense Compendium: Dealing with Hauntings", 10),  # AssetIdx 49
            Series("Theory of the Nether Strata: Analysis of the Afterworld", 10),  # AssetIdx 50
            Series("Rituals of Calling and Commanding the Dead", 10),  # AssetIdx 51
            Series("A Technique to Turn Wandering Ghosts into Servants", 10),  # AssetIdx 52
            Series("Compendium of Necromancy: The Beginner's Guide", 10),  # AssetIdx 53
            Series("Night Parade of One Hundred Demons", 10),  # AssetIdx 54
            Series("How to Command the Army of the Dead", 10),  # AssetIdx 55
            Series("Compendium of Necromancy: The Arts of Management and Maintenance", 10),  # AssetIdx 56
            Series("Practical Necromancy: Skeleton Edition", 10),  # AssetIdx 57
            Series("Zombie: The Secret Rituals for Domination", 10),  # AssetIdx 58
            Series("Ritual Design Guidelines for the Practicing Necromancer", 10),  # AssetIdx 59
        ),
    ),

    Section(
        id="1F",
        name="Transfiguration",
        floor=1,
        color="dark red with brown",
        series=(
            Series("Introduction to the Theory of Transfiguration", 10),  # AssetIdx 60
            Series("Magical Physiology of Therianthropy", 10),  # AssetIdx 61
            Series("Reducing Metamorphosis Time: How to Minimize Vulnerability", 10),  # AssetIdx 62
            Series("Mastery of Mimicry: Theory and Practice of Visual Imitation", 10),  # AssetIdx 63
            Series("Humanization: A Transformation Guide for Non-Humans", 10),  # AssetIdx 64
            Series("Beastification and the Threshold of Madness", 10),  # AssetIdx 65
            Series("Complete Practical Transfiguration: Phases and Sustaining Techniques", 10),  # AssetIdx 66
            Series("The Codex of Transfiguration: Detection and Nullification", 10),  # AssetIdx 67
            Series("Correlation of Transformation Duration and Mana Depletion", 10),  # AssetIdx 68
            Series("Preservation of Mental Identity in Therianthropic Spells", 10),  # AssetIdx 69
            Series("Introduction to Inanimate Transfiguration", 10),  # AssetIdx 70
            Series("Foundations of Transformation: Object Alteration and Reassembly", 10),  # AssetIdx 71
        ),
    ),

    Section(
        id="1G",
        name="Magical Artifacts and Enchanting",
        floor=1,
        color="bright dark blue or bright dark purple",
        series=(
            Series("The Grand Encyclopedia of Magical Artifacts", 10),  # AssetIdx 72
            Series("Foundations of Magical Item Crafting and Materials", 10),  # AssetIdx 73
            Series("Magical Item’s Workshop Series", 10),  # AssetIdx 74
            Series("Practical Enchantment: Offense and Defense Enhancement", 10),  # AssetIdx 75
            Series("Crystal Catalog: Elemental Properties and Enchantment Mastery", 3),  # AssetIdx 76
            Series("Artifacts That Change the World", 3),  # AssetIdx 77
            Series("The Magic Ring That Steals Reason", 3),  # AssetIdx 78
            Series("Introduction to Enchantment Theory", 3),  # AssetIdx 79
            Series("The Inverse Law of High Grade Armor and Fabric Coverage", 3),  # AssetIdx 80
            Series("Forging Magical Items", 3),  # AssetIdx 81
            Series("Repair and Retuning of Enchanted Gear", 3),  # AssetIdx 82
            Series("Compendium of Forbidden Relics", 3),  # AssetIdx 83
        ),
    ),

    Section(
        id="1H",
        name="Stealth",
        floor=1,
        color="black",
        series=(
            Series("Complete Guide to Stealth Magic", 10),  # AssetIdx 84
            Series("Stealth Techniques: Concealment Among Nearby Objects", 10),  # AssetIdx 85
            Series("Hide vs Seek: Magical Warfare of Stealth and Detection", 10),  # AssetIdx 86
            Series("Codex of the Stealth Arts", 10),  # AssetIdx 87
            Series("Tactics of the Bucket: Vision-Sealing Theft", 3),  # AssetIdx 88
            Series("The Art of Shadow-Walking", 3),  # AssetIdx 89
            Series("Introduction to Stealth Magic: The Art of Shadowing", 3),  # AssetIdx 90
            Series("Foundations and Applications of Invisibility Magic", 3),  # AssetIdx 91
            Series("Stealth Arts: Techniques to Becoming Air", 3),  # AssetIdx 92
            Series("The Book of Ninja: Lurking in the Darkness", 3),  # AssetIdx 93
            Series("Shadowmages: Shadow Cloning and Teleportation", 3),  # AssetIdx 94
            Series("The Art of Hiding One's Presence", 3),  # AssetIdx 95
        ),
    ),

    Section(
        id="1I",
        name="Illusion Magic",
        floor=1,
        color="dark blue or dark purple",
        series=(
            Series("The Grand Compendium of Illusion Magic", 10),  # AssetIdx 96
            Series("Introduction to Illusion Magic: Truths of the Imaginary", 10),  # AssetIdx 97
            Series("Illusion Magic : The Art of Hypnosis", 10),  # AssetIdx 98
            Series("Chronostatic Illusions: Manipulating the Perception of Time", 10),  # AssetIdx 99
            Series("The Ultimate Illusion : Mirror Flower, Water Moon", 10),  # AssetIdx 100
            Series("Crafting Visual and Auditory Illusions", 10),  # AssetIdx 101
            Series("The Illusory Art: Sovereignty over the Five Senses", 10),  # AssetIdx 102
            Series("Where Illusion Ends and Reality Begins", 10),  # AssetIdx 103
            Series("Terror Illusions: Spells to Shatter the Enemy’s Mind", 10),  # AssetIdx 104
            Series("The Art of Illusion Defense: Mental Defences and Protection of the Five Senses", 10),  # AssetIdx 105
            Series("The Infinite Hall: Creating Inescapable Illusory Spaces", 10),  # AssetIdx 106
            Series("Enchanting Illusions: Seduction Magic", 10),  # AssetIdx 107
        ),
    ),

    Section(
        id="1J",
        name="Summoning Magic",
        floor=1,
        color="dark blue",
        series=(
            Series("Introduction to Summoning: Fundamentals of Otherworldly Contracts", 10),  # AssetIdx 108
            Series("Magic Circles and Summoning Syntax Explained", 10),  # AssetIdx 109
            Series("Trans-Temporal Summons and the Law of Causality", 10),  # AssetIdx 110
            Series("Theory and Practice of Hero Summoning from Another World", 10),  # AssetIdx 111
            Series("A Beginner's Guide: Summoning the Useless Goddess", 10),  # AssetIdx 112
            Series("Summoning Magic for Beginners", 10),  # AssetIdx 113
            Series("Divine Dragon Summoning: Descent of Bahamut", 10),  # AssetIdx 114
            Series("The Complete Summoning Grimoire", 10),  # AssetIdx 115
            Series("Summoning and Controlling Catastrophic Entities", 10),  # AssetIdx 116
            Series("Encyclopedia of 10,000 Summons: The Complete Collection from Heaven to the Abyss", 10),  # AssetIdx 117
            Series("Succubus Summoning Techniques and Practical Applications", 10),  # AssetIdx 118
            Series("The Book of Summoning and Contracts", 10),  # AssetIdx 119
        ),
    ),

    Section(
        id="1K",
        name="Healer and Healing Magic",
        floor=1,
        color="white with red",
        series=(
            Series("Fundamentals of Healing and Mana Control", 10),  # AssetIdx 120
            Series("Introduction to Magical Healing", 10),  # AssetIdx 121
            Series("Spells for Curing Poisons and Diseases", 10),  # AssetIdx 122
            Series("The Grand Compendium of Healing Magic", 10),  # AssetIdx 123
            Series("Advanced Healing Theory: Maintaining Vigor Until Daybreak", 10),  # AssetIdx 124
            Series("No More ''Healer Diff'': A Comprehensive Guide", 10),  # AssetIdx 125
            Series("The Four Principles of the Healer's Ethics", 10),  # AssetIdx 126
            Series("Healing Magic for the Reclamation of Mind and Consciousness", 10),  # AssetIdx 127
        ),
    ),

    Section(
        id="1L",
        name="Holy Magic",
        floor=1,
        color="white with gold",
        series=(
            Series("Theological Research on Holy Magic", 10),  # AssetIdx 128
            Series("Prolegomena to Holy Magic Theory", 10),  # AssetIdx 129
            Series("Fundamentals of Holy Power in Undead Annihilation", 10),  # AssetIdx 130
            Series("Compendium of Sacred Purification Magic", 10),  # AssetIdx 131
            Series("Spells of Holy Light for Concealing Vital Areas", 10),  # AssetIdx 132
            Series("Holy Magic: Undead Protection and Purification", 10),  # AssetIdx 133
            Series("Formation and Maintenance of Large Sacred Barriers", 10),  # AssetIdx 134
            Series("Selection and Application of Targets for Holy Magic", 10),  # AssetIdx 135
        ),
    ),

    Section(
        id="1M",
        name="Destruction Magic",
        floor=1,
        color="varied; identified by colored gemstones",
        series=(
            Series("Book of Spells: Fire - Novice -", 10),  # AssetIdx 136
            Series("Book of Spells: Water - Novice -", 10),  # AssetIdx 137
            Series("Book of Spells: Wind - Novice -", 10),  # AssetIdx 138
            Series("Book of Spells: Earth - Novice -", 10),  # AssetIdx 139
            Series("Book of Spells: Thunder - Adept -", 10),  # AssetIdx 140
            Series("Book of Spells: Ice - Adept -", 10),  # AssetIdx 141
            Series("Book of Spells: Shadow - Adept -", 10),  # AssetIdx 142
            Series("Book of Spells: Light - Adept -", 10),  # AssetIdx 143
            Series("Book of Spells: Pulverization - Expert -", 10),  # AssetIdx 144
            Series("Book of Spells: Dimension Rift - Expert -", 10),  # AssetIdx 145
            Series("Book of Spells: Forest Creation - Expert -", 10),  # AssetIdx 146
            Series("Book of Spells: Fluid - Expert -", 10),  # AssetIdx 147
            Series("Book of Spells: Matter Creation - Master -", 5),  # AssetIdx 148
            Series("Book of Spells: Psychokinesis - Master -", 5),  # AssetIdx 149
            Series("Book of Spells: Gravitation - Master -", 5),  # AssetIdx 150
            Series("Book of Spells: Abyss - Master -", 5),  # AssetIdx 151
            Series("Book of Spells: Explosion - Legendary -", 5),  # AssetIdx 152
            Series("Book of Spells: Time - Legendary -", 5),  # AssetIdx 153
            Series("Book of Spells: Energy - Legendary -", 5),  # AssetIdx 154
            Series("Book of Spells: Space - Legendary -", 5),  # AssetIdx 155
        ),
    ),

    Section(
        id="1N",
        name="Alchemy and Potion-Making",
        floor=1,
        color="varied; identified by tree-circle emblem",
        series=(
            Series("Alchemy Codex: An Introduction to Herbology", 10),  # AssetIdx 156
            Series("The Alchemist's Encyclopedia: Categories and Efficacy of Ingredients", 10),  # AssetIdx 157
            Series("The Alchemist's Field Guide: Natural Materials and Foraging", 10),  # AssetIdx 158
            Series("Forbidden Alchemy: The Guide to Toxin Brewing and Disposal", 10),  # AssetIdx 159
            Series("Books of Alchemy: Practical Extraction of High-Purity Essences", 10),  # AssetIdx 160
            Series("Books of Alchemy: Potion Safety and Storage Manual", 10),  # AssetIdx 161
            Series("Books of Alchemy: Homunculus - Chronicle of the Forbidden Creation", 10),  # AssetIdx 162
            Series("Books of Alchemy: The Little Herbology of the Faefolk", 10),  # AssetIdx 163
            Series("Books of Alchemy: Encyclopedia of World Potions", 10),  # AssetIdx 164
            Series("Books of Alchemy: A Practical Guide to Potion Crafting", 10),  # AssetIdx 165
            Series("Books of Alchemy: The Ultimate Secret of the Philosopher’s Stone", 10),  # AssetIdx 166
            Series("Books of Alchemy: The Laws and Taboos of Chimera Synthesis", 10),  # AssetIdx 167
            Series("Tomes of Alchemy: The Great Compendium of Synthesis Recipes", 5),  # AssetIdx 168
            Series("Tomes of Alchemy: A Grimoire of Elemental Fusion and Fission", 5),  # AssetIdx 169
            Series("Tomes of Alchemy: A Beginner's Guide to Modern Synthesis", 5),  # AssetIdx 170
            Series("Tomes of Alchemy: Complete Theory of Elemental Transmutation", 5),  # AssetIdx 171
            Series("Tomes of Alchemy: Beginner Manual of Alchemical Synthesis", 5),  # AssetIdx 172
            Series("Tomes of Alchemy: Alchemical Tools and Laboratory Apparatus", 5),  # AssetIdx 173
            Series("Tomes of Alchemy: The Alchemical Art of Transmuting Food to Poop", 5),  # AssetIdx 174
            Series("Tomes of Alchemy: Alchemical Safety Manual Handling Hazardous Materials", 5),  # AssetIdx 175
        ),
    ),

    # ============== FLOOR 2 — 17 sections ==============

    Section(
        id="2A",
        name="Warrior",
        floor=2,
        color="brown / dark red (one blue book among them)",
        series=(
            Series("Warrior's Foundation: Between Blade and Spell", 10),  # AssetIdx 176
            Series("The Dark Berserker and the Greatsword", 10),  # AssetIdx 177
            Series("The Weapon Compendium: Use of Swords, Axes and Spears", 10),  # AssetIdx 178
            Series("Armor and Muscle: Synergy Between Body and Steel", 10),  # AssetIdx 179
            Series("Blade: Dimension Slash Combat Technique", 10),  # AssetIdx 180
            Series("Heretic Blade Arts: Three Sword Style", 10),  # AssetIdx 181
            Series("Battlefield Logic: A Tactical Guide for Warriors", 10),  # AssetIdx 182
            Series("The Warrior's Creed: Only Cowards Become Long-Range Mages", 10),  # AssetIdx 183
            Series("The Supreme Creed: The Naked Warrior", 10),  # AssetIdx 184
            Series("Mind Like Still Water: The Zen of Perfect Parrying", 10),  # AssetIdx 185
            Series("Scion of the Axe God: Strongest Warrior Chosen by the Sun", 10),  # AssetIdx 186
            Series("Sword Saint: The One Who Sliced the Mountains", 10),  # AssetIdx 187
        ),
    ),

    Section(
        id="2B",
        name="Archery",
        floor=2,
        color="green",
        series=(
            Series("Arrow of the Shattered Knee", 10),  # AssetIdx 188
            Series("The Fundamentals of Archery: Spirit and Skill", 10),  # AssetIdx 189
            Series("The Hunter’s Archery Manual", 10),  # AssetIdx 190
            Series("Anatomy of the Bow and Arrow", 10),  # AssetIdx 191
            Series("From Longbow to Shortbow: Tactical Applications", 10),  # AssetIdx 192
            Series("The Book of Arcane Bows: Magic Infused Arrows", 10),  # AssetIdx 193
            Series("Archers of the Fairies Pact", 10),  # AssetIdx 194
            Series("Stellar Archery: Resonance of Stars and Arrows", 10),  # AssetIdx 195
            Series("Forging and Using Magical Bows", 10),  # AssetIdx 196
            Series("Applied Archery Tactics: Arrows of Stillness and Motion", 10),  # AssetIdx 197
            Series("The Grand Compendium of Archery", 10),  # AssetIdx 198
            Series("The Art of the Arrow Series", 10),  # AssetIdx 199
        ),
    ),

    Section(
        id="2C",
        name="Daily Magic",
        floor=2,
        color="pastel",
        series=(
            Series("Magic Techniques to Boost Household Efficiency", 10),  # AssetIdx 200
            Series("Minor Repairs: Practical Everyday Magic", 10),  # AssetIdx 201
            Series("A Compendium of Useless Magic from Around the World", 10),  # AssetIdx 202
            Series("Introduction to LifeHack Magic", 10),  # AssetIdx 203
            Series("1000 Easy Spells to Use at Home", 10),  # AssetIdx 204
            Series("The Complete Guide to Everyday Magic: Simple Life Enchantments", 10),  # AssetIdx 205
            Series("Home Magic: Spells to Protect and Nurture Your Dwelling", 3),  # AssetIdx 206
            Series("Broom Handling Techniques: The Art of Aerial Travel", 3),  # AssetIdx 207
            Series("Three Seconds to Office: Magic for Last-Minute Commuters", 3),  # AssetIdx 208
            Series("What Kind of Magic Works Best for Job Hunting?", 3),  # AssetIdx 209
            Series("Everyday Magic for Deep and Restful Sleep", 3),  # AssetIdx 210
            Series("Spoiler Prevention Magic", 3),  # AssetIdx 211
            Series("Storage Magic: Different Dimension Pocket", 3),  # AssetIdx 212
            Series("Compendium Magic for the Lazy", 3),  # AssetIdx 213
            Series("Handy Kitchen Magic Recipes", 3),  # AssetIdx 214
            Series("How to Commute with Magic", 3),  # AssetIdx 215
            Series("Magic to Mute a Specific Person's Voice", 3),  # AssetIdx 216
            Series("Magic to Speak and Convey", 3),  # AssetIdx 217
        ),
    ),

    Section(
        id="2D",
        name="Mathematics",
        floor=2,
        color="varied; identified by spine logo",
        series=(
            Series("Introduction to Sorcery Mathematics", 10),  # AssetIdx 218
            Series("Theory of Everything: Grasping Beautiful Theory through Equations", 10),  # AssetIdx 219
            Series("Mana Measurement and Conversion Equations", 10),  # AssetIdx 220
            Series("Structural Analysis of Sorcerous Equations", 10),  # AssetIdx 221
            Series("The Mathematical Geometry of Magic Circles", 10),  # AssetIdx 222
            Series("Easy Math! Magical Representation Theory for a 3-Year-Old", 10),  # AssetIdx 223
            Series("Prime Equation: The Absolute Order Hidden Behind Irregularity", 3),  # AssetIdx 224
            Series("Mass–Mana Equivalence", 3),  # AssetIdx 225
            Series("Genesis Theory: An Interpretation via Imaginary Numbers", 3),  # AssetIdx 226
            Series("Spatial Distribution of Mana Density and Its Fluctuation Characteristics", 3),  # AssetIdx 227
            Series("Arcane Glyphs and Pattern Theory", 3),  # AssetIdx 228
            Series("Mathematical Methods for Constructing Magic Circles", 3),  # AssetIdx 229
            Series("Magical Analysis Based on the Application of Infinite Series", 3),  # AssetIdx 230
            Series("Quantification of Cursed Power and Constraint Conditions", 3),  # AssetIdx 231
            Series("The Law of Equivalent Exchange", 3),  # AssetIdx 232
            Series("Vector Space Theory of Magic", 3),  # AssetIdx 233
            Series("Prophecy and Probability Theory", 3),  # AssetIdx 234
            Series("Temporal Magic and Chaos Theory", 3),  # AssetIdx 235
        ),
    ),

    Section(
        id="2E",
        name="Art",
        floor=2,
        color="varied",
        series=(
            Series("Introduction to Magical Art", 10),  # AssetIdx 236
            Series("Art Collection That No One Can Understand", 10),  # AssetIdx 237
            Series("Process: Sublimating Brain Fragments into Works", 10),  # AssetIdx 238
            Series("Perfect Lines and Circles: The Secret to Drawing in One Stroke", 10),  # AssetIdx 239
            Series("Puppet Crafting: An Introductory Guide to Automata and Statues", 10),  # AssetIdx 240
            Series("Living Paintings: Creating and Controlling Animated Magical Art", 10),  # AssetIdx 241
            Series("Drawing Moving Characters: Beginner Level", 10),  # AssetIdx 242
            Series("Techniques for Returning a Drawing to a Previous Step", 10),  # AssetIdx 243
            Series("Art is Sublime Because It Has No Answer", 10),  # AssetIdx 244
            Series("How to Change Drawn Art into Reality", 10),  # AssetIdx 245
            Series("Memory Transfer: The Technique of Direct Scene Depiction from your Brain", 10),  # AssetIdx 246
            Series("Art and Magic Circles: Definitions and Differences", 10),  # AssetIdx 247
        ),
    ),

    Section(
        id="2F",
        name="Management",
        floor=2,
        color="dark blue",
        series=(
            Series("Management: Administration of Magical Institutions", 10),  # AssetIdx 248
            Series("Management: Tactical Command of Magical Forces", 10),  # AssetIdx 249
            Series("Management: High-Ranking Magician Training and Evaluation System", 10),  # AssetIdx 250
            Series("Management: Mana Resource Allocation and Optimization", 10),  # AssetIdx 251
            Series("Magical Supply Chain Management", 10),  # AssetIdx 252
            Series("Guild Treasury and Reward System Management", 10),  # AssetIdx 253
            Series("Licensing and Regulation of Magic Users", 10),  # AssetIdx 254
            Series("Managing Diverse and Cross-Race Adventurer Parties", 10),  # AssetIdx 255
            Series("Research of Adventurer Party Tactics Series", 10),  # AssetIdx 256
            Series("Systems for Nurturing and Promotions in Guilds", 10),  # AssetIdx 257
            Series("Conflict Protocols for Guilds", 10),  # AssetIdx 258
            Series("Organizational Discipline: How Small Cracks Lead to Great Ruin", 10),  # AssetIdx 259
        ),
    ),

    Section(
        id="2G",
        name="Economics",
        floor=2,
        color="green",
        series=(
            Series("An Introduction to Magical Economics", 10),  # AssetIdx 260
            Series("Introduction to Arcane Market Systems", 10),  # AssetIdx 261
            Series("Magic and Value: Arcane Resource Valuations", 10),  # AssetIdx 262
            Series("Mana Currency Systems and Their Evolution", 10),  # AssetIdx 263
            Series("Arcane Economy Report: Regional Mana Market Analysis", 10),  # AssetIdx 264
            Series("Economics: Wage Structures in the Magical Professions", 10),  # AssetIdx 265
            Series("Spell Patents and IP Rights", 3),  # AssetIdx 266
            Series("Economics: Supply and Trade of Arcane Resources", 3),  # AssetIdx 267
            Series("Alchemy and Inflation: The Gold Collapse", 3),  # AssetIdx 268
            Series("Why Do Stocks Crash the Moment I Buy Them?", 3),  # AssetIdx 269
            Series("Financial: The Art of the Tariff", 3),  # AssetIdx 270
            Series("History of Demonic Financial Hegemony", 3),  # AssetIdx 271
            Series("Economics: Where Did the Taxes Go?", 3),  # AssetIdx 272
            Series("Economics: The Revolution in Logistics Through Teleportation", 3),  # AssetIdx 273
            Series("The Arcane Black Market and Price Manipulation", 3),  # AssetIdx 274
            Series("Economics: The Lost Three Decades", 3),  # AssetIdx 275
            Series("The Complete Works of Magical Economics", 3),  # AssetIdx 276
            Series("Studies in Arcane Fiscal Theory", 3),  # AssetIdx 277
        ),
    ),

    Section(
        id="2H",
        name="Sociology",
        floor=2,
        color="brownish (dark pink, dark orange)",
        series=(
            Series("Labor Studies: Even with Magic, Overtime Never Ends", 10),  # AssetIdx 278
            Series("Work Culture: The Mage Who Changed Jobs to a Sweatshop", 10),  # AssetIdx 279
            Series("Job Inequality: Low Salary even as a Licensed Sage", 10),  # AssetIdx 280
            Series("The Influence of Short-Lived Cultures on Long-Lived Species", 10),  # AssetIdx 281
            Series("Career Opportunity: Graduated from Magic University... Got Zero Job Offers", 10),  # AssetIdx 282
            Series("Interracial Social Dynamics", 10),  # AssetIdx 283
            Series("Social Structures of Magical Civilizations", 3),  # AssetIdx 284
            Series("Sociology: Mage Pension System on the Brink of Collapse", 3),  # AssetIdx 285
            Series("Marriage Is a Contract Spell: Advanced Disenchantment is required for Divorce", 3),  # AssetIdx 286
            Series("“Low Mana” a Form of Discrimination?", 3),  # AssetIdx 287
            Series("Wage Gaps: Universal Mana Income for Mages Now!", 3),  # AssetIdx 288
            Series("Mana and Labor: Sociology of Magical Economies", 3),  # AssetIdx 289
            Series("The Rift in Values Between Different Species with Differing Lifespans", 3),  # AssetIdx 290
            Series("The Structure of Power Monopolization Tendencies by Long-Lived Species", 3),  # AssetIdx 291
            Series("The Labor Reality of Mages: Unpaid and Unprotected Interns", 3),  # AssetIdx 292
            Series("A Media Society Manipulated by Magic", 3),  # AssetIdx 293
            Series("How to Survive a Mana-Disparity Society", 3),  # AssetIdx 294
            Series("Labor Studies: Where are the Workplaces to Apply Your University-Learned Magic?", 3),  # AssetIdx 295
        ),
    ),

    Section(
        id="2I",
        name="Psychology",
        floor=2,
        color="dark red",
        series=(
            Series("Ultimate Choice: Curry flavoured Poop, or Poop flavoured Curry?", 10),  # AssetIdx 296
            Series("Psychology: Mentality That the Weak Bark the Most", 10),  # AssetIdx 297
            Series("The Psychology: Powerlessness and Responsibility Shifting", 10),  # AssetIdx 298
            Series("Effort Builds Confidence, and Confidence Leads to Action", 10),  # AssetIdx 299
            Series("The Correlation of Magic and Emotion", 10),  # AssetIdx 300
            Series("Introduction to Psychological Principles and Analysis", 10),  # AssetIdx 301
            Series("The Psychology of Backseat Gaming", 10),  # AssetIdx 302
            Series("A Diary of the Change in the State of The Mind-Reading Girl", 10),  # AssetIdx 303
            Series("The Psychology of Prioritizing Gaming Over Tidying Your Room", 10),  # AssetIdx 304
            Series("Mind Reading: Detecting Lies through Facial Expressions and Gestures", 10),  # AssetIdx 305
            Series("The Psychology of Using Strong Language from a Safe Zone", 10),  # AssetIdx 306
            Series("A Psychologist’s Definition of “Happiness”: The Cutting Edge of Happiness Research", 10),  # AssetIdx 307
        ),
    ),

    Section(
        id="2J",
        name="Philosophy",
        floor=2,
        color="white",
        series=(
            Series("Soul, Mind, and Body: Are They Truly Distinct?", 10),  # AssetIdx 308
            Series("Philosophy: Power and Ethics", 10),  # AssetIdx 309
            Series("Philosophy of Self and Other", 10),  # AssetIdx 310
            Series("Foundations of Metaphysics", 10),  # AssetIdx 311
            Series("Philosophy of Science: Methodology and Truth", 10),  # AssetIdx 312
            Series("I think, therefore I am", 10),  # AssetIdx 313
            Series("Teachings of the Great Philosophers of Magic", 10),  # AssetIdx 314
            Series("Philosophy of Mana and Willpower", 10),  # AssetIdx 315
            Series("Ethics of Magic: Responsibility and Restraint", 10),  # AssetIdx 316
            Series("Fantasy or Reality? The Ontological Problem of World", 10),  # AssetIdx 317
            Series("Philosophical Studies in Magic", 10),  # AssetIdx 318
            Series("Introduction to Magical Determinism: Spell-Causality and the Philosophy", 10),  # AssetIdx 319
        ),
    ),

    Section(
        id="2K",
        name="Jurisprudence",
        floor=2,
        color="dark green or blue",
        series=(
            Series("Law: Foundations of Contemporary Magical Jurisprudence", 10),  # AssetIdx 320
            Series("Grand Compendium of Magic Jurisprudence", 10),  # AssetIdx 321
            Series("Chronicles of the Magical Court", 10),  # AssetIdx 322
            Series("Codex of Truth Verification", 10),  # AssetIdx 323
            Series("The System and Precedents of the Arcane Court", 10),  # AssetIdx 324
            Series("The Constitution of the Kingdom", 10),  # AssetIdx 325
            Series("Contract Law: How to Write Adventurer Contracts", 3),  # AssetIdx 326
            Series("Compendium of Magical Civil Law: Definition of Personhood, Rights and Succession", 3),  # AssetIdx 327
            Series("Monster Hunting Law: List of Prohibited Species and Regulation of Attack Methods", 3),  # AssetIdx 328
            Series("Magical Detective Law: Punishment Act for the Use of Unapproved and Unregistered Spell", 3),  # AssetIdx 329
            Series("Guild Charter: Guild Discipline and Expulsion Systems", 3),  # AssetIdx 330
            Series("Legal System for Magical Accidents and Accountability", 3),  # AssetIdx 331
            Series("Legality and Regulation of Magic Use", 3),  # AssetIdx 332
            Series("Comparative Study of National Magic Laws", 3),  # AssetIdx 333
            Series("Legal Treatment of Forbidden Magic", 3),  # AssetIdx 334
            Series("The Legalities of Party Disbandment: Property Distribution and Liability", 3),  # AssetIdx 335
            Series("Civil Liability Within Adventuring Parties", 3),  # AssetIdx 336
            Series("The Idea of Equality Under the Law Is Laughable", 3),  # AssetIdx 337
        ),
    ),

    Section(
        id="2L",
        name="Romance Novels",
        floor=2,
        color="varied (often pink)",
        series=(
            Series("Romance Novel: Senior And The Beast", 10),  # AssetIdx 338
            Series("Romance Novel: Whispers of the Moon", 10),  # AssetIdx 339
            Series("Romance Novel: A Pact Beneath the Stars", 10),  # AssetIdx 340
            Series("A Midsummer Night's Sweet Dream", 10),  # AssetIdx 341
            Series("A Kiss Wrought in Spells", 10),  # AssetIdx 342
            Series("Romance Novel: The Fire King and the Ice Queen", 10),  # AssetIdx 343
            Series("Cursed to Love You", 3),  # AssetIdx 344
            Series("Romance Novel: The Chicken and The Cat", 3),  # AssetIdx 345
            Series("Romance Novel: My Massive Golden Balls", 3),  # AssetIdx 346
            Series("Roses Are Red, Violets Are Blue", 3),  # AssetIdx 347
            Series("The Witch and the Accidental Love Potion", 3),  # AssetIdx 348
            Series("30 year old Wizard's First Love", 3),  # AssetIdx 349
            Series("Romance Novel: The Red Lady and the Bamboozled Men", 3),  # AssetIdx 350
            Series("Romance Novel: The Thorn Prince", 3),  # AssetIdx 351
            Series("Fill the Solitude of My Millennium with Your Ninety Years", 3),  # AssetIdx 352
            Series("The Strongest Archmage is Obsessed with Me, the Girl with Zero Magic!", 3),  # AssetIdx 353
            Series("True Love between A 20-Year-Old Lady and an 80-Year-Old Tycoon", 3),  # AssetIdx 354
            Series("Romance Novel: Lies More Beautiful Than Truth", 3),  # AssetIdx 355
        ),
    ),

    Section(
        id="2M",
        name="Mystery Novels",
        floor=2,
        color="varied",
        series=(
            Series("The Arcane Detective Files", 10),  # AssetIdx 356
            Series("Detective the Reaper", 10),  # AssetIdx 357
            Series("Mystery Fiction: The Prospero Code", 10),  # AssetIdx 358
            Series("Mystery Fiction: The Bloodstained Astrologer", 10),  # AssetIdx 359
            Series("Mystery Fiction: One Who Looks into the Abyss", 5),  # AssetIdx 360
            Series("Mystery Fiction: Judgment of the Spectral Tribunal", 5),  # AssetIdx 361
            Series("Mystery Fiction: Magical Theorist Maris", 5),  # AssetIdx 362
            Series("Mystery Fiction: The Pirate Captain Who Stepped Down from His Ship", 5),  # AssetIdx 363
        ),
    ),

    Section(
        id="2N",
        name="History",
        floor=2,
        color="dark red / purple / orange (one dark blue)",
        series=(
            Series("Origins of Magic: Awakening of the First Spells and Magic Power", 10),  # AssetIdx 364
            Series("Studies in the History of Magical Civilizations", 10),  # AssetIdx 365
            Series("The Genesis of Magic and the Evolution of Civilization", 10),  # AssetIdx 366
            Series("The Transition and Evolutionary History of Magic", 10),  # AssetIdx 367
            Series("The History of World Exploration and the Discovery of Lost Continents", 5),  # AssetIdx 368
            Series("History and Tactics of Magical Warfare", 5),  # AssetIdx 369
            Series("Ancient Manuscript Studies on Mage Birth", 5),  # AssetIdx 370
            Series("Record of the Demon King’s Subjugation: The Archmage’s Conquest", 5),  # AssetIdx 371
        ),
    ),

    Section(
        id="2O",
        name="The Travels of Otherworld",
        floor=2,
        color="varied",
        series=(
            Series("The Curious Daily Life in a World Without Magic", 10),  # AssetIdx 372
            Series("They Call Their Mana “Dark Energy”", 10),  # AssetIdx 373
            Series("The Cursed Workplaces of a Magicless World", 10),  # AssetIdx 374
            Series("A People Enchanted by Glowing Slabs", 10),  # AssetIdx 375
            Series("Otherworld Chronicles: A World Ruled by Data", 5),  # AssetIdx 376
            Series("They Worship an Invisible Entity Known as Wi-Fi", 5),  # AssetIdx 377
            Series("Strange Technology from Another World! The Ultimate Language: C++", 5),  # AssetIdx 378
            Series("In the Otherworld, Money Is the Ultimate Magic", 5),  # AssetIdx 379
            Series("The “Internet”: The All-Knowing Grimoire", 5),  # AssetIdx 380
            Series("A World Without a Demon Lord, Yet Full of Corporate Slaves", 5),  # AssetIdx 381
            Series("The Otherworld: Demanding Fresh Graduates with 10 Years of Experience", 5),  # AssetIdx 382
            Series("The Ultimate Guide to Otherworldly Swear Words", 5),  # AssetIdx 383
        ),
    ),

    Section(
        id="2P",
        name="Dungeons",
        floor=2,
        color="light purple or dark pink",
        series=(
            Series("Fundamentals of Dungeon Architecture", 10),  # AssetIdx 384
            Series("Dungeon of the Abyss", 10),  # AssetIdx 385
            Series("Bestiary Components: Dungeon Creatures", 10),  # AssetIdx 386
            Series("Compendium of Dungeon Resources", 10),  # AssetIdx 387
            Series("Gourmet Expeditions in the Dungeon", 5),  # AssetIdx 388
            Series("Optimization Theory of Dungeon Routes", 5),  # AssetIdx 389
            Series("Practical Dungeon Tactics", 5),  # AssetIdx 390
            Series("The Daily Dungeon Notes of the Party Chronicler", 5),  # AssetIdx 391
        ),
    ),

    Section(
        id="2Q",
        name="Language",
        floor=2,
        color="dark red / green (one blue) — Christmas palette",
        series=(
            Series("Everyone’s Elvish: The Graceful Speech of the Forest", 10),  # AssetIdx 392
            Series("Everyone’s Demonic: Words of Covenant and Power", 10),  # AssetIdx 393
            Series("Everyone’s Fairy Tongue: Tiny and Lovely Words", 10),  # AssetIdx 394
            Series("Everyone’s Dwarvish: The Craftsman's Language", 10),  # AssetIdx 395
            Series("The Language of Draconic: Roars of Ancient Wisdom and Primal Power", 5),  # AssetIdx 396
            Series("How Did the First Language Emerge? The Origins of Language Evolution", 5),  # AssetIdx 397
            Series("The Birth of Magical Languages: Secrets of Spells and Ancient Speech", 5),  # AssetIdx 398
            Series("Inter-Species Communication", 5),  # AssetIdx 399
        ),
    ),

)
# ============================================================================
# EUpgradeAbility — mirrors the in-game enum (CXXHeaderDump/Librarian_enums.hpp)
# ============================================================================


class UpgradeAbility:
    """Integer constants matching EUpgradeAbility in the game."""
    JUMP = 0                  # Minor — Crimson Octagon chest
    UPGRADE_BAG = 1           # Minor — Azure Star chest  (delta +3 in MaxBagItemLevel)
    UPGRADE_BAG_2 = 2         # Minor — Golden Diamond chest (delta +2)
    SHOW_MATCHING_SHELF = 3   # Major — Shelf Guide
    JOGGING = 4               # Minor — Emerald Club chest
    SORT_BOOKS = 5            # Major — Sort
    AUTO_SHELVE = 6           # Major — Auto-Shelving
    SHOW_SAME_TYPE_BOOK = 7   # Major — Insight
    GRAB_SAME_TYPE_BOOK = 8   # Major — Assemble


UPGRADE_INTERNAL_NAMES: dict[int, str] = {
    0: "Jump", 1: "UpgradeBag", 2: "UpgradeBag2",
    3: "ShowMatchingShelf", 4: "Jogging",
    5: "SortBooks", 6: "AutoShelve",
    7: "ShowSameTypeBook", 8: "GrabSameTypeBook",
}

# Player-facing display names.
UPGRADE_DISPLAY_NAMES: dict[int, str] = {
    0: "Jump", 1: "Bag Capacity I", 2: "Bag Capacity II",
    3: "Shelf Guide", 4: "Jogging",
    5: "Sort", 6: "Auto-Shelving",
    7: "Insight", 8: "Assemble",
}

# Max levels probed from the in-game Skill_* class instances at runtime.
SKILL_MAX_LEVELS: dict[int, int] = {
    UpgradeAbility.JUMP:                1,   # toggle
    UpgradeAbility.UPGRADE_BAG:         1,   # toggle
    UpgradeAbility.UPGRADE_BAG_2:       1,   # toggle
    UpgradeAbility.JOGGING:             1,   # toggle
    UpgradeAbility.SORT_BOOKS:          5,
    UpgradeAbility.SHOW_MATCHING_SHELF: 10,
    UpgradeAbility.AUTO_SHELVE:         10,
    UpgradeAbility.SHOW_SAME_TYPE_BOOK: 10,
    UpgradeAbility.GRAB_SAME_TYPE_BOOK: 10,
}

MINOR_MAGIC_ABILITIES: tuple[int, ...] = (
    UpgradeAbility.JUMP,
    UpgradeAbility.JOGGING,
    UpgradeAbility.UPGRADE_BAG,
    UpgradeAbility.UPGRADE_BAG_2,
)

MAJOR_MAGIC_ABILITIES: tuple[int, ...] = (
    UpgradeAbility.SORT_BOOKS,
    UpgradeAbility.SHOW_MATCHING_SHELF,
    UpgradeAbility.AUTO_SHELVE,
    UpgradeAbility.SHOW_SAME_TYPE_BOOK,
    UpgradeAbility.GRAB_SAME_TYPE_BOOK,
)

# Minor Magic chests: (player-facing chest/key name, ability granted on open).
# The matching colored key is the in-world pickup that lets the player open
# the chest; the AP location check fires on the chest opening, not the key.
MINOR_MAGIC_CHESTS: tuple[tuple[str, int], ...] = (
    ("Crimson Octagon", UpgradeAbility.JUMP),
    ("Emerald Club",    UpgradeAbility.JOGGING),
    ("Azure Star",      UpgradeAbility.UPGRADE_BAG),
    ("Golden Diamond",  UpgradeAbility.UPGRADE_BAG_2),
)

# Total skill items in the AP pool: 4 minor toggles + sum of major levels.
SKILL_ITEM_COUNT: int = sum(SKILL_MAX_LEVELS.values())  # = 49


# ============================================================================
# XP curve — rows-finished thresholds for each player level.
# Probed at runtime from BP_LibrarianCharacter.SkillLevelUpRowNum.
# Length = 45, so the player can reach level 45 and earn 45 banked points
# (which AP intercepts and converts into "Reached Level N" location checks).
# ============================================================================

XP_CURVE: tuple[int, ...] = (
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 19, 22, 25, 29, 33, 37, 41,
    46, 50, 55, 61, 66, 72, 78, 84, 91, 98, 105, 112, 120, 127, 135,
    152, 161, 170, 179, 189, 200, 212, 225, 239, 254,
)
MAX_PLAYER_LEVEL: int = len(XP_CURVE)  # = 45


# ============================================================================
# Bag capacity (probed from UItemBagComponent.MaxBagItemLevel).
# Index = bag level (0 = base, 1 = +UpgradeBag, 2 = +UpgradeBag2).
# ============================================================================

BAG_CAPACITY_BY_LEVEL: tuple[int, ...] = (10, 13, 15)


# ============================================================================
# Derived lookups
# ============================================================================

SECTIONS_BY_ID: dict[str, Section] = {s.id: s for s in SECTIONS}

# Flat list: (section_id, series_name, volumes), one entry per series (388 total).
ALL_SERIES: tuple[tuple[str, str, int], ...] = tuple(
    (section.id, series.name, series.volumes)
    for section in SECTIONS
    for series in section.series
)

# Reverse lookup: series_name -> section_id. Useful for AssetIdx mapping.
SERIES_TO_SECTION: dict[str, str] = {
    series.name: section.id
    for section in SECTIONS
    for series in section.series
}

# Flat list of every individual book (volume) -- the BookSanity granularity.
# One entry per (series, volume): (asset_idx, chapter, section_id, series_name).
#   asset_idx = the series' global index in ALL_SERIES == the AssetIdx the
#               in-game book actor reports.
#   chapter   = 0-based volume index within the series == the actor's Chapter.
# Global order = ALL_SERIES order, then volume order. len(ALL_BOOKS) == 3072.
ALL_BOOKS: tuple[tuple[int, int, str, str], ...] = tuple(
    (asset_idx, chapter, section_id, series_name)
    for asset_idx, (section_id, series_name, _volumes) in enumerate(ALL_SERIES)
    for chapter in range(_volumes)
)


# ============================================================================
# Helpers
# ============================================================================


def floor_sections(floor: int) -> list[Section]:
    """All sections on the given floor, in declaration order."""
    return [s for s in SECTIONS if s.floor == floor]


def total_shelves() -> int:
    """Sum of shelf rows across all sections (one per series)."""
    return sum(s.shelf_count for s in SECTIONS)


def total_volumes() -> int:
    """Sum of all volumes across all series. Should equal 3072."""
    return sum(s.volume_count for s in SECTIONS)


def total_bookcases() -> int:
    """Estimated total bookcase actor count across all sections."""
    return sum(s.bookcase_count for s in SECTIONS)


def section_for_series(series_name: str) -> Section | None:
    """Look up which section a series belongs to. None if not found."""
    section_id = SERIES_TO_SECTION.get(series_name)
    return SECTIONS_BY_ID.get(section_id) if section_id else None


# ============================================================================
# Sanity assertions — fail-fast at import if the data drifts
# ============================================================================

assert len(SECTIONS) == 31, f"Expected 31 sections, got {len(SECTIONS)}"
assert len(floor_sections(1)) == 14, "Floor 1 must have 14 sections"
assert len(floor_sections(2)) == 17, "Floor 2 must have 17 sections"
assert total_shelves() == 400, f"Expected 400 shelves, got {total_shelves()}"
assert total_volumes() == 3072, f"Expected 3072 volumes, got {total_volumes()}"
assert SKILL_ITEM_COUNT == 49, f"Expected 49 skill items, got {SKILL_ITEM_COUNT}"

# Section IDs must be unique.
_seen_ids = [s.id for s in SECTIONS]
assert len(_seen_ids) == len(set(_seen_ids)), "Duplicate section ID detected"

# Series names must be globally unique (so SERIES_TO_SECTION is unambiguous).
_seen_series = [s.name for sec in SECTIONS for s in sec.series]
assert len(_seen_series) == len(set(_seen_series)), "Duplicate series name detected"


# ============================================================================
# Self-test: run `python data.py` to print summary
# ============================================================================

if __name__ == "__main__":
    print("Librarian: Tidy Up the Arcane Library! — data summary")
    print("=" * 60)
    print(f"Sections:        {len(SECTIONS)}")
    print(f"  Floor 1:       {len(floor_sections(1))}  sections")
    print(f"  Floor 2:       {len(floor_sections(2))}  sections")
    print(f"Series (shelves): {total_shelves()}")
    print(f"Volumes:         {total_volumes()}")
    print(f"Skill items:     {SKILL_ITEM_COUNT}")
    print(f"Max player lvl:  {MAX_PLAYER_LEVEL}")
    print()
    print(f"{'ID':4s}{'Name':35s}{'Floor':6s}{'Shelves':9s}{'Volumes':8s}  Color")
    print("-" * 100)
    for s in SECTIONS:
        print(f"{s.id:4s}{s.name:35s}{s.floor:<6d}{s.shelf_count:<9d}{s.volume_count:<8d}  {s.color}")
    print()
    print("Volume distribution by series size:")
    sizes: dict[int, int] = {3: 0, 5: 0, 10: 0}
    for sec in SECTIONS:
        for ser in sec.series:
            sizes[ser.volumes] = sizes.get(ser.volumes, 0) + 1
    for k in (3, 5, 10):
        print(f"  {k:2d}-volume series: {sizes[k]}")
