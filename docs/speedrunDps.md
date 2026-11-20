# Speedrun DPS by level

Max DPS for the 11 class and skill combinations at the end of each speedrun stage. Each combination was
optimised at levels 20, 30 and 50 with rares only and the screen settings.

## Settings

| Setting | Value | Option |
|---|---|---|
| Character level | 20, 30 or 50 | `--level` |
| Item level | same as the character level | `--item-level` |
| Affix rolls | 60% of each range | `--roll 0.6` |
| Conditions | sustained buffs assumed | `--assume sustained` |
| Uniques | none, rare-only build | `--no-uniques` |
| Search | screen (one pass, one tree variant, one job) | `--rounds 1 --tree-width 1 --jobs 1` |

Ascendancy is not set. Without `--ascendancy` the optimiser picks one in every run, so these results are not
ascendancy-free. The optimiser has no option to exclude ascendancies.

Each run is one command, for example:

```
python OptimizeBuild.py --class Witch --skill Hexblast --level 30 --item-level 30 --roll 0.6 --assume sustained --rounds 1 --no-uniques --tree-width 1 --jobs 1
```

## Results

Rare-only DPS, the value the optimiser reports as `Rare-only build`.

| Class / Skill | Level 20 | Level 30 | Level 50 | Ascendancy picked (20 / 30 / 50) |
|---|---:|---:|---:|---|
| Warrior / Hammer of the Gods | 34,721 | 93,727 | 949,556 | Smith of Kitava / Smith of Kitava / Titan |
| Witch / Hexblast | 15,590 | 80,349 | 882,670 | Blood Mage (all) |
| Ranger / Rain of Arrows | 63,409 | 104,679 | 526,966 | Deadeye (all) |
| Mercenary / Armour Piercing Rounds | 34,941 | 94,592 | 612,006 | Gemling Legionnaire (all) |
| Witch / Comet | 13,582 | 48,036 | 455,382 | Blood Mage (all) |
| Sorceress / Firestorm | 19,353 | 41,009 | 401,157 | Stormweaver (all) |
| Mercenary / Plasma Blast | 29,607 | 54,312 | 374,776 | Gemling Legionnaire (all) |
| Monk / Ice Strike | 28,986 | 57,424 | 300,954 | Invoker (all) |
| Monk / Falling Thunder | 28,972 | 49,654 | 309,794 | Invoker (all) |
| Huntress / Fangs of Frost | 19,506 | 35,427 | 307,601 | Amazon (all) |
| Druid / Thunderstorm | 4,937 | 16,518 | 124,837 | Oracle (all) |

## Notes

- **The leader changes by stage.** Ranger / Rain of Arrows leads at level 20 with 63,409, and Warrior /
  Hammer of the Gods leads at level 50 with 949,556.
- **Witch / Hexblast climbs the most.** It is ninth at level 20 (15,590) and second at level 50 (882,670).
- **Level 95 results are not included.** Earlier screens at level 95 with item level 75 used the endgame
  settings and aren't comparable to these stages.
- **Ascendancy changes damage.** The Warrior ascendancy changes from Smith of Kitava to Titan between levels 30
  and 50, which changes the ranking at level 50.
- **Not verified.** The data doesn't give character-level unlocks for runes or lineage supports. The runs
  use `--no-uniques` only and don't exclude runes or lineage supports.
