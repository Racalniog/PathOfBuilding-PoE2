# Build optimizer runs

Results of two batches of 100 optimizer runs each (November 2026), made to find the strongest builds the
optimizer can put together with realistic gear. Every score is the build's Combined DPS as Path of Building
calculates it, with the main skill's minions included for minion skills.

How the optimizer works and what it cannot see is described in the [build optimizer guide](buildOptimizer.md).

## Contents

- [Settings](#settings)
- [Best builds overall](#best-builds-overall)
- [What the search options changed](#what-the-search-options-changed)
- [First batch](#first-batch)
- [Second batch](#second-batch)
- [Survivability runs](#survivability-runs)
- [Tankiest builds](#tankiest-builds)
- [Damage builds with approximations](#damage-builds-with-approximations)
- [Caveats](#caveats)

## Settings

All runs use obtainable rather than perfect gear:

| Setting | Value | Option |
|---|---|---|
| Character level | 92 | `--level 92` |
| Affix rolls | 60% of each range | `--roll 0.6` |
| Highest affix level | 75 | `--item-level 75` |
| Conditions | sustained buffs assumed | `--assume sustained` |

Each batch ran in two stages:

1. **Screen**: a quick rares-only run of many class, ascendancy and skill combinations
   (`--rounds 1 --no-uniques --tree-width 1`), to find the promising ones.
2. **Full run**: the best combinations from the screen with the default search, rares first and then uniques.
   Some leaders were also run with `--rounds 3` and `--thorough`.

Any run can be repeated from the command line, for example the best build:

```
python OptimizeBuild.py --class Witch --ascendancy "Blood Mage" --skill "Hexblast" --level 92 --roll 0.6 --item-level 75 --assume sustained --unique-variants
```

## Best builds overall

The best full run of every build, with uniques, across both batches.

| # | Class / Ascendancy | Skill | Rares only | With uniques | Run |
|---:|---|---|---:|---:|---|
| 1 | Witch / Blood Mage | Hexblast | 90.8M | **164.4M** | second batch, `bloodmage_hexblast` |
| 2 | Witch / Blood Mage | Comet | 60.6M | **84.1M** | second batch, `bloodmage_comet_r3_thorough` |
| 3 | Witch / Infernalist | Comet | 39.6M | **74.2M** | second batch, `infernalist_comet_uv` |
| 4 | Witch / Blood Mage | Ember Fusillade | 56.1M | **73.3M** | first batch, `bloodmage_emberfusillade_r3` |
| 5 | Warrior / Titan | Hammer of the Gods | 36.5M | **67.2M** | second batch, `titan_hammerofthegods` |
| 6 | Witch / Blood Mage | Firestorm | 36.1M | **58.5M** | second batch, `bloodmage_firestorm_uv` |
| 7 | Witch / Lich | Hexblast | 43.6M | **56.5M** | second batch, `lich_hexblast_r3` |
| 8 | Warrior / Smith of Kitava | Hammer of the Gods | 23.4M | **52.2M** | second batch, `smithofkitava_hammerofthegods_r3` |
| 9 | Sorceress / Stormweaver | Comet | 14.2M | **47.1M** | second batch, `stormweaver_comet_uv` |
| 10 | Warrior / Warbringer | Hammer of the Gods | 21.0M | **47.1M** | second batch, `warbringer_hammerofthegods` |
| 11 | Witch / Infernalist | Ember Fusillade | 33.9M | **45.6M** | first batch, `infernalist_emberfusillade` |
| 12 | Ranger / Deadeye | Rain of Arrows | 21.5M | **35.6M** | first batch, `deadeye_rainofarrows_r3` |
| 13 | Witch / Blood Mage | Arc | 24.0M | **35.4M** | first batch, `bloodmage_arc_r3` |
| 14 | Sorceress / Disciple of Varashta | Firestorm | 20.3M | **33.3M** | second batch, `discipleofvarashta_firestorm` |
| 15 | Warrior / Smith of Kitava | Supercharged Slam | 11.7M | **32.6M** | second batch, `smithofkitava_superchargedslam` |
| 16 | Sorceress / Chronomancer | Firestorm | 19.8M | **32.6M** | second batch, `chronomancer_firestorm` |
| 17 | Sorceress / Disciple of Varashta | Comet | 14.1M | **32.0M** | second batch, `discipleofvarashta_comet` |
| 18 | Witch / Lich | Skeletal Sniper | 17.0M | **31.4M** | second batch, `lich_skeletalsniper` |
| 19 | Sorceress / Chronomancer | Comet | 14.2M | **31.3M** | second batch, `chronomancer_comet` |
| 20 | Witch / Blood Mage | Fireball | 22.6M | **29.7M** | first batch, `bloodmage_fireball` |
| 21 | Sorceress / Chronomancer | Ember Fusillade | 16.3M | **29.3M** | second batch, `chronomancer_emberfusillade` |
| 22 | Witch / Infernalist | Firestorm | 22.0M | **29.3M** | first batch, `infernalist_firestorm` |
| 23 | Witch / Blood Mage | Essence Drain | 15.0M | **29.3M** | first batch, `bloodmage_essencedrain` |
| 24 | Ranger / Pathfinder | Rain of Arrows | 17.3M | **27.6M** | first batch, `pathfinder_rainofarrows` |
| 25 | Sorceress / Stormweaver | Firestorm | 20.6M | **27.1M** | first batch, `stormweaver_firestorm` |
| 26 | Witch / Infernalist | Skeletal Sniper | 15.7M | **24.5M** | second batch, `infernalist_skeletalsniper` |
| 27 | Sorceress / Stormweaver | Ember Fusillade | 18.2M | **23.9M** | first batch, `stormweaver_emberfusillade_r3` |
| 28 | Sorceress / Disciple of Varashta | Ember Fusillade | 16.3M | **21.4M** | second batch, `discipleofvarashta_emberfusillade` |
| 29 | Mercenary / Tactician | Plasma Blast | 11.4M | **17.9M** | second batch, `tactician_plasmablast` |
| 30 | Witch / Abyssal Lich | Skeletal Frost Mage | 9.1M | **16.2M** | second batch, `abyssallich_skeletalfrostmage` |
| 31 | Monk / Acolyte of Chayula | Falling Thunder | 11.1M | **16.0M** | second batch, `acolyteofchayula_fallingthunder` |
| 32 | Monk / Acolyte of Chayula | Ice Strike | 11.1M | **15.8M** | second batch, `acolyteofchayula_icestrike` |
| 33 | Mercenary / Tactician | Armour Piercing Rounds | 8.7M | **15.2M** | second batch, `tactician_armourpiercingrounds` |
| 34 | Witch / Lich | Essence Drain | 7.9M | **13.4M** | first batch, `lich_essencedrain_r3` |
| 35 | Sorceress / Stormweaver | Frostbolt | 10.1M | **13.2M** | first batch, `stormweaver_frostbolt` |
| 36 | Sorceress / Disciple of Varashta | Frostbolt | 9.2M | **13.0M** | second batch, `discipleofvarashta_frostbolt` |
| 37 | Monk / Invoker | Falling Thunder | 8.0M | **12.0M** | first batch, `invoker_fallingthunder` |
| 38 | Monk / Invoker | Ice Strike | 7.6M | **11.7M** | first batch, `invoker_icestrike` |

### The best build: Blood Mage Hexblast

164.4M DPS with uniques (90.8M rares only).

- **Supports**: Considered Casting, Rakiata's Flow, Concentrated Area, Deliberation, Elemental Focus
- **Uniques**: Trenchtimbre, Mageblood, Prism of Belief (Hexblast), Voices (4 Sinister Sockets)
- **Keystones**: Eldritch Battery
- **Other skills**: Despair with Heightened Curse, Archmage, Elemental Conflux, and Soul Offering and Freezing Mark cast from the second weapon set
- **Rares**: a Dueling Wand and a Focus stacked with spell levels, increased spell and lightning damage and cast speed

## What the search options changed

### Unique versions

Leaders of the first batch were run again in the second batch with **Unique versions** on (suffix `_uv`).

| Build | Without | With Unique versions | Change |
|---|---:|---:|---:|
| Blood Mage Comet | 72.2M | 84.1M | +16% |
| Infernalist Comet | 64.9M | 74.2M | +14% |
| Blood Mage Ember Fusillade | 73.1M | 73.1M | +0% |
| Blood Mage Firestorm | 46.5M | 58.5M | +26% |
| Stormweaver Comet | 43.8M | 47.1M | +8% |
| Infernalist Ember Fusillade | 45.6M | 45.6M | +0% |
| Deadeye Rain of Arrows | 33.6M | 34.4M | +2% |
| Blood Mage Arc | 32.8M | 32.8M | +0% |

Nearly all of the gain comes from **Prism of Belief** in the version for the build's own main skill. Without the
option only the version the unique database selects is tried. Builds whose skill has no helpful Prism version
did not change. **Voices** in its *4 Sinister Sockets* version was picked in every build that used Voices.

### More rounds and the thorough search

Each run compared with the default search of the same build in the same batch.

| Batch | Run | Rares only | vs default | With uniques | vs default |
|---|---|---:|---:|---:|---:|
| First batch | `bloodmage_emberfusillade_r3` | 56.1M | +1.4% | 73.3M | +0.4% |
| First batch | `bloodmage_comet_r3` | 60.6M | +21.4% | 73.1M | +1.2% |
| First batch | `infernalist_comet_r3` | 52.6M | +32.7% | 64.9M | +0.1% |
| First batch | `bloodmage_firestorm_r3` | 36.9M | +2.4% | 47.1M | +1.2% |
| First batch | `infernalist_emberfusillade_r3` | 34.2M | +1.0% | 45.4M | -0.4% |
| First batch | `deadeye_rainofarrows_r3` | 21.5M | +1.8% | 35.6M | +6.0% |
| First batch | `bloodmage_arc_r3` | 24.0M | +18.8% | 35.4M | +7.6% |
| First batch | `bloodmage_fireball_r3` | 22.6M | +0.0% | 29.6M | -0.1% |
| First batch | `infernalist_firestorm_r3` | 22.3M | +1.4% | 29.3M | +0.0% |
| First batch | `bloodmage_essencedrain_r3` | 16.3M | +9.0% | 25.7M | -12.1% |
| First batch | `stormweaver_emberfusillade_r3` | 18.2M | +0.0% | 23.9M | +0.8% |
| First batch | `lich_essencedrain_r3` | 7.9M | +5.9% | 13.4M | +7.0% |
| First batch | `invoker_icestrike_r3` | 8.0M | +4.6% | 11.7M | -0.6% |
| Second batch | `bloodmage_hexblast_r3` | 97.1M | +6.9% | 164.3M | -0.1% |
| Second batch | `bloodmage_hexblast_r3_thorough` | 97.1M | +6.9% | 164.3M | -0.1% |
| Second batch | `bloodmage_comet_r3_thorough` | 60.6M | +21.4% | 84.1M | +0.0% |
| Second batch | `bloodmage_emberfusillade_r3_thorough` | 56.1M | +1.4% | 73.3M | +0.4% |
| Second batch | `titan_hammerofthegods_r3` | 37.2M | +1.9% | 67.1M | -0.1% |
| Second batch | `lich_hexblast_r3` | 43.6M | +0.6% | 56.5M | +0.2% |
| Second batch | `smithofkitava_hammerofthegods_r3` | 23.4M | +22.1% | 52.2M | +2.1% |

More rounds or the thorough search often found a better rare-only build (up to +33%), but once uniques were added
most results stayed within 2% of the default search, between -12% and +8% at the extremes. The default settings
already get close to what the search can find.

## First batch

The Unique versions option was not available yet, so only the default version of each unique was tried.

### Screen (69 runs, rares only)

| # | Class / Ascendancy | Skill | DPS |
|---:|---|---|---:|
| 1 | Witch / Blood Mage | Ember Fusillade | 26.6M |
| 2 | Witch / Blood Mage | Firestorm | 23.1M |
| 3 | Witch / Infernalist | Ember Fusillade | 22.7M |
| 4 | Witch / Blood Mage | Comet | 22.4M |
| 5 | Witch / Infernalist | Comet | 22.2M |
| 6 | Witch / Infernalist | Firestorm | 19.5M |
| 7 | Sorceress / Stormweaver | Ember Fusillade | 11.7M |
| 8 | Ranger / Deadeye | Rain of Arrows | 9.9M |
| 9 | Sorceress / Stormweaver | Firestorm | 9.8M |
| 10 | Sorceress / Stormweaver | Comet | 8.5M |
| 11 | Ranger / Pathfinder | Rain of Arrows | 8.2M |
| 12 | Witch / Blood Mage | Arc | 7.7M |
| 13 | Sorceress / Stormweaver | Frostbolt | 7.5M |
| 14 | Sorceress / Chronomancer | Frostbolt | 7.2M |
| 15 | Witch / Blood Mage | Fireball | 7.1M |
| 16 | Witch / Blood Mage | Essence Drain | 6.7M |
| 17 | Witch / Infernalist | Fireball | 6.1M |
| 18 | Sorceress / Stormweaver | Arc | 5.8M |
| 19 | Witch / Blood Mage | Ball Lightning | 5.7M |
| 20 | Monk / Invoker | Falling Thunder | 5.4M |
| 21 | Monk / Invoker | Ice Strike | 5.3M |
| 22 | Sorceress / Stormweaver | Ice Nova | 4.9M |
| 23 | Sorceress / Chronomancer | Ice Nova | 4.6M |
| 24 | Witch / Lich | Essence Drain | 4.6M |
| 25 | Monk / Martial Artist | Falling Thunder | 4.6M |
| 26 | Monk / Martial Artist | Ice Strike | 4.4M |
| 27 | Warrior / Titan | Sunder | 4.2M |
| 28 | Monk / Invoker | Storm Wave | 4.2M |
| 29 | Sorceress / Stormweaver | Fireball | 4.2M |
| 30 | Witch / Blood Mage | Spark | 4.0M |
| 31 | Warrior / Warbringer | Sunder | 3.8M |
| 32 | Monk / Martial Artist | Storm Wave | 3.6M |
| 33 | Huntress / Amazon | Fangs of Frost | 3.6M |
| 34 | Mercenary / Gemling Legionnaire | High Velocity Rounds | 3.5M |
| 35 | Witch / Abyssal Lich | Essence Drain | 3.5M |
| 36 | Sorceress / Stormweaver | Ball Lightning | 3.1M |
| 37 | Ranger / Deadeye | Ice Shot | 3.1M |
| 38 | Monk / Invoker | Tempest Flurry | 3.0M |
| 39 | Sorceress / Stormweaver | Spark | 2.9M |
| 40 | Mercenary / Witchhunter | High Velocity Rounds | 2.8M |
| 41 | Huntress / Ritualist | Fangs of Frost | 2.8M |
| 42 | Monk / Martial Artist | Tempest Flurry | 2.6M |
| 43 | Ranger / Deadeye | Lightning Arrow | 2.6M |
| 44 | Huntress / Amazon | Lightning Spear | 2.4M |
| 45 | Ranger / Pathfinder | Ice Shot | 2.4M |
| 46 | Ranger / Pathfinder | Lightning Arrow | 2.2M |
| 47 | Huntress / Amazon | Twister | 2.1M |
| 48 | Warrior / Titan | Boneshatter | 2.1M |
| 49 | Warrior / Warbringer | Boneshatter | 2.1M |
| 50 | Ranger / Deadeye | Tornado Shot | 2.0M |
| 51 | Huntress / Ritualist | Lightning Spear | 1.8M |
| 52 | Ranger / Pathfinder | Tornado Shot | 1.6M |
| 53 | Mercenary / Gemling Legionnaire | Explosive Shot | 1.6M |
| 54 | Mercenary / Gemling Legionnaire | Hailstorm Rounds | 1.5M |
| 55 | Huntress / Amazon | Explosive Spear | 1.4M |
| 56 | Druid / Oracle | Volcano | 1.4M |
| 57 | Huntress / Ritualist | Twister | 1.4M |
| 58 | Mercenary / Witchhunter | Explosive Shot | 1.4M |
| 59 | Mercenary / Witchhunter | Hailstorm Rounds | 1.3M |
| 60 | Huntress / Ritualist | Explosive Spear | 1.1M |
| 61 | Druid / Shaman | Volcano | 1.1M |
| 62 | Warrior / Titan | Earthquake | 959,209 |
| 63 | Warrior / Warbringer | Earthquake | 959,209 |
| 64 | Mercenary / Gemling Legionnaire | Galvanic Shards | 365,770 |
| 65 | Mercenary / Witchhunter | Galvanic Shards | 318,369 |
| 66 | Warrior / Titan | Rolling Slam | 195,316 |
| 67 | Warrior / Warbringer | Rolling Slam | 171,263 |
| 68 | Druid / Oracle | Tornado | 153,922 |
| 69 | Druid / Shaman | Tornado | 152,883 |

### Full runs (31 runs)

| # | Run | Class / Ascendancy | Skill | Extra options | Rares only | With uniques |
|---:|---|---|---|---|---:|---:|
| 1 | `bloodmage_emberfusillade_r3` | Witch / Blood Mage | Ember Fusillade | `--rounds 3` | 56.1M | 73.3M |
| 2 | `bloodmage_comet_r3` | Witch / Blood Mage | Comet | `--rounds 3` | 60.6M | 73.1M |
| 3 | `bloodmage_emberfusillade` | Witch / Blood Mage | Ember Fusillade | – | 55.3M | 73.1M |
| 4 | `bloodmage_comet` | Witch / Blood Mage | Comet | – | 49.9M | 72.2M |
| 5 | `infernalist_comet_r3` | Witch / Infernalist | Comet | `--rounds 3` | 52.6M | 64.9M |
| 6 | `infernalist_comet` | Witch / Infernalist | Comet | – | 39.6M | 64.9M |
| 7 | `bloodmage_firestorm_r3` | Witch / Blood Mage | Firestorm | `--rounds 3` | 36.9M | 47.1M |
| 8 | `bloodmage_firestorm` | Witch / Blood Mage | Firestorm | – | 36.1M | 46.5M |
| 9 | `infernalist_emberfusillade` | Witch / Infernalist | Ember Fusillade | – | 33.9M | 45.6M |
| 10 | `infernalist_emberfusillade_r3` | Witch / Infernalist | Ember Fusillade | `--rounds 3` | 34.2M | 45.4M |
| 11 | `stormweaver_comet` | Sorceress / Stormweaver | Comet | – | 14.2M | 43.8M |
| 12 | `deadeye_rainofarrows_r3` | Ranger / Deadeye | Rain of Arrows | `--rounds 3` | 21.5M | 35.6M |
| 13 | `bloodmage_arc_r3` | Witch / Blood Mage | Arc | `--rounds 3` | 24.0M | 35.4M |
| 14 | `deadeye_rainofarrows` | Ranger / Deadeye | Rain of Arrows | – | 21.1M | 33.6M |
| 15 | `bloodmage_arc` | Witch / Blood Mage | Arc | – | 20.2M | 32.8M |
| 16 | `bloodmage_fireball` | Witch / Blood Mage | Fireball | – | 22.6M | 29.7M |
| 17 | `bloodmage_fireball_r3` | Witch / Blood Mage | Fireball | `--rounds 3` | 22.6M | 29.6M |
| 18 | `infernalist_firestorm` | Witch / Infernalist | Firestorm | – | 22.0M | 29.3M |
| 19 | `infernalist_firestorm_r3` | Witch / Infernalist | Firestorm | `--rounds 3` | 22.3M | 29.3M |
| 20 | `bloodmage_essencedrain` | Witch / Blood Mage | Essence Drain | – | 15.0M | 29.3M |
| 21 | `pathfinder_rainofarrows` | Ranger / Pathfinder | Rain of Arrows | – | 17.3M | 27.6M |
| 22 | `stormweaver_firestorm` | Sorceress / Stormweaver | Firestorm | – | 20.6M | 27.1M |
| 23 | `bloodmage_essencedrain_r3` | Witch / Blood Mage | Essence Drain | `--rounds 3` | 16.3M | 25.7M |
| 24 | `stormweaver_emberfusillade_r3` | Sorceress / Stormweaver | Ember Fusillade | `--rounds 3` | 18.2M | 23.9M |
| 25 | `stormweaver_emberfusillade` | Sorceress / Stormweaver | Ember Fusillade | – | 18.2M | 23.7M |
| 26 | `lich_essencedrain_r3` | Witch / Lich | Essence Drain | `--rounds 3` | 7.9M | 13.4M |
| 27 | `stormweaver_frostbolt` | Sorceress / Stormweaver | Frostbolt | – | 10.1M | 13.2M |
| 28 | `lich_essencedrain` | Witch / Lich | Essence Drain | – | 7.5M | 12.5M |
| 29 | `invoker_fallingthunder` | Monk / Invoker | Falling Thunder | – | 8.0M | 12.0M |
| 30 | `invoker_icestrike` | Monk / Invoker | Ice Strike | – | 7.6M | 11.7M |
| 31 | `invoker_icestrike_r3` | Monk / Invoker | Ice Strike | `--rounds 3` | 8.0M | 11.7M |

<details><summary>Supports, uniques and keystones of each full run</summary>

| Run | Supports | Uniques | Keystones |
|---|---|---|---|
| `bloodmage_emberfusillade_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices | Eldritch Battery |
| `bloodmage_comet_r3` | Living Lightning II, Minion Pact II, Elemental Focus, Concentrated Area, Considered Casting | Mageblood, Voices | Eldritch Battery |
| `bloodmage_emberfusillade` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices | Eldritch Battery |
| `bloodmage_comet` | Living Lightning II, Minion Pact II, Elemental Focus, Concentrated Area, Considered Casting | Mageblood, Voices | Eldritch Battery |
| `infernalist_comet_r3` | Living Lightning II, Minion Pact II, Scouring Flame, Concentrated Area, Considered Casting | Blood Price, Kalandra's Touch, Mageblood, Voices | - |
| `infernalist_comet` | Living Lightning II, Minion Pact II, Scouring Flame, Concentrated Area, Considered Casting | Blood Price, Mageblood, Voices | - |
| `bloodmage_firestorm_r3` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Ingenuity, Voices | Wildsurge Incantation |
| `bloodmage_firestorm` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Ingenuity, Voices | Wildsurge Incantation |
| `infernalist_emberfusillade` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices | Eldritch Battery |
| `infernalist_emberfusillade_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices | Eldritch Battery |
| `stormweaver_comet` | Cold Mastery, Rakiata's Flow, Concentrated Area, Considered Casting, Elemental Focus | Atsak's Sight, Plaguefinger, Mageblood, Voices | - |
| `deadeye_rainofarrows_r3` | Zerphi's Infamy, Rakiata's Flow, Concentrated Area, Hourglass, Elemental Armament II | Runeseeker's Call, Irongrasp, Wake of Destruction, Mageblood, Voices | - |
| `bloodmage_arc_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Considered Casting | Trenchtimbre, Ingenuity, Voices | Eldritch Battery |
| `deadeye_rainofarrows` | Zerphi's Infamy, Rakiata's Flow, Concentrated Area, Hourglass, Elemental Armament II | Runeseeker's Call, Blood Price, Irongrasp, Wake of Destruction, Mageblood, Voices | - |
| `bloodmage_arc` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Considered Casting | Trenchtimbre, Ingenuity, Voices | Eldritch Battery |
| `bloodmage_fireball` | Living Lightning II, Minion Pact II, Rakiata's Flow, Deliberation, Considered Casting | Mageblood, Voices | Eldritch Battery |
| `bloodmage_fireball_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Deliberation, Considered Casting | Mageblood, Voices | Eldritch Battery |
| `infernalist_firestorm` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Mageblood, Voices | Wildsurge Incantation |
| `infernalist_firestorm_r3` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Mageblood, Voices | Wildsurge Incantation |
| `bloodmage_essencedrain` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Trenchtimbre, Mageblood, Voices | Eldritch Battery |
| `pathfinder_rainofarrows` | Zerphi's Infamy, Rakiata's Flow, Concentrated Area, Hourglass, Elemental Armament II | Runeseeker's Call, Blood Price, Irongrasp, Wake of Destruction, Mageblood, Voices | - |
| `stormweaver_firestorm` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Mageblood, Voices | Eldritch Battery, Wildsurge Incantation |
| `bloodmage_essencedrain_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Trenchtimbre, Mageblood, Voices | Eldritch Battery |
| `stormweaver_emberfusillade_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices | - |
| `stormweaver_emberfusillade` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices | - |
| `lich_essencedrain_r3` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Trenchtimbre, Mageblood, Voices | Eldritch Battery |
| `stormweaver_frostbolt` | Elemental Focus, Rakiata's Flow, Concentrated Area, Inexorable Critical I, Deliberation | Mageblood, Voices | - |
| `lich_essencedrain` | Living Lightning II, Minion Pact II, Rakiata's Flow, Considered Casting, Deliberation | Trenchtimbre, Mageblood, Voices | Eldritch Battery |
| `invoker_fallingthunder` | Rakiata's Flow, Zerphi's Infamy, Hit and Run, Aftershock II, Concentrated Area | Collapsing Horizon, Wake of Destruction, Mageblood, Voices | - |
| `invoker_icestrike` | Rakiata's Flow, Zerphi's Infamy, Hit and Run, Concentrated Area, Elemental Armament II | Wake of Destruction, Mageblood, Voices | Chaos Inoculation |
| `invoker_icestrike_r3` | Rakiata's Flow, Zerphi's Infamy, Hit and Run, Concentrated Area, Elemental Armament II | Wake of Destruction, Mageblood, Voices | Chaos Inoculation |

</details>

## Second batch

New combinations, more rounds and the thorough search for the leaders, and every full run with **Unique versions** on (`--unique-variants`).

### Screen (65 runs, rares only)

| # | Class / Ascendancy | Skill | DPS |
|---:|---|---|---:|
| 1 | Witch / Blood Mage | Hexblast | 37.2M |
| 2 | Witch / Lich | Hexblast | 23.7M |
| 3 | Warrior / Titan | Hammer of the Gods | 14.9M |
| 4 | Warrior / Smith of Kitava | Hammer of the Gods | 14.2M |
| 5 | Warrior / Warbringer | Hammer of the Gods | 14.2M |
| 6 | Sorceress / Chronomancer | Ember Fusillade | 11.5M |
| 7 | Sorceress / Disciple of Varashta | Ember Fusillade | 11.0M |
| 8 | Sorceress / Chronomancer | Firestorm | 9.5M |
| 9 | Sorceress / Disciple of Varashta | Firestorm | 9.5M |
| 10 | Witch / Infernalist | Skeletal Sniper | 9.3M |
| 11 | Witch / Lich | Skeletal Sniper | 9.0M |
| 12 | Sorceress / Chronomancer | Comet | 8.1M |
| 13 | Sorceress / Disciple of Varashta | Comet | 8.0M |
| 14 | Sorceress / Disciple of Varashta | Frostbolt | 6.7M |
| 15 | Witch / Abyssal Lich | Skeletal Frost Mage | 6.5M |
| 16 | Monk / Acolyte of Chayula | Falling Thunder | 6.0M |
| 17 | Mercenary / Tactician | Plasma Blast | 5.6M |
| 18 | Warrior / Smith of Kitava | Supercharged Slam | 5.5M |
| 19 | Warrior / Titan | Supercharged Slam | 5.4M |
| 20 | Warrior / Warbringer | Supercharged Slam | 5.4M |
| 21 | Sorceress / Chronomancer | Arc | 5.3M |
| 22 | Sorceress / Disciple of Varashta | Arc | 5.3M |
| 23 | Monk / Acolyte of Chayula | Ice Strike | 5.3M |
| 24 | Mercenary / Tactician | Armour Piercing Rounds | 5.1M |
| 25 | Druid / Oracle | Thunderstorm | 4.6M |
| 26 | Monk / Acolyte of Chayula | Storm Wave | 4.4M |
| 27 | Sorceress / Disciple of Varashta | Fireball | 3.9M |
| 28 | Druid / Shaman | Thunderstorm | 3.7M |
| 29 | Witch / Blood Mage | Bonestorm | 3.2M |
| 30 | Monk / Acolyte of Chayula | Tempest Flurry | 3.2M |
| 31 | Druid / Oracle | Wing Blast | 3.1M |
| 32 | Mercenary / Tactician | High Velocity Rounds | 2.8M |
| 33 | Sorceress / Disciple of Varashta | Spark | 2.7M |
| 34 | Witch / Lich | Bonestorm | 2.7M |
| 35 | Huntress / Spirit Walker | Fangs of Frost | 2.6M |
| 36 | Warrior / Smith of Kitava | Boneshatter | 2.6M |
| 37 | Warrior / Titan | Volcanic Fissure | 2.5M |
| 38 | Druid / Shaman | Wing Blast | 2.4M |
| 39 | Huntress / Amazon | Whirlwind Lance | 2.4M |
| 40 | Warrior / Smith of Kitava | Volcanic Fissure | 2.3M |
| 41 | Druid / Oracle | Fury of the Mountain | 2.2M |
| 42 | Warrior / Warbringer | Volcanic Fissure | 2.2M |
| 43 | Ranger / Deadeye | Shockchain Arrow | 1.9M |
| 44 | Huntress / Spirit Walker | Lightning Spear | 1.9M |
| 45 | Huntress / Spirit Walker | Whirlwind Lance | 1.8M |
| 46 | Druid / Shaman | Fury of the Mountain | 1.7M |
| 47 | Warrior / Titan | Earthshatter | 1.7M |
| 48 | Huntress / Spirit Walker | Twister | 1.6M |
| 49 | Monk / Acolyte of Chayula | Killing Palm | 1.6M |
| 50 | Warrior / Smith of Kitava | Earthshatter | 1.5M |
| 51 | Warrior / Warbringer | Earthshatter | 1.5M |
| 52 | Sorceress / Disciple of Varashta | Lightning Conduit | 1.4M |
| 53 | Sorceress / Stormweaver | Lightning Conduit | 1.4M |
| 54 | Mercenary / Tactician | Explosive Shot | 1.4M |
| 55 | Mercenary / Tactician | Hailstorm Rounds | 1.3M |
| 56 | Huntress / Amazon | Storm Lance | 1.3M |
| 57 | Huntress / Amazon | Spear of Solaris | 1.2M |
| 58 | Huntress / Spirit Walker | Explosive Spear | 1.1M |
| 59 | Huntress / Spirit Walker | Storm Lance | 990,317 |
| 60 | Warrior / Smith of Kitava | Forge Hammer | 892,146 |
| 61 | Monk / Acolyte of Chayula | Tempest Bell | 853,077 |
| 62 | Ranger / Deadeye | Spiral Volley | 692,730 |
| 63 | Ranger / Deadeye | Stormcaller Arrow | 567,123 |
| 64 | Mercenary / Tactician | Permafrost Bolts | 380,104 |
| 65 | Witch / Infernalist | Raging Spirits | 277,718 |

### Full runs (35 runs)

| # | Run | Class / Ascendancy | Skill | Extra options | Rares only | With uniques |
|---:|---|---|---|---|---:|---:|
| 1 | `bloodmage_hexblast` | Witch / Blood Mage | Hexblast | `--unique-variants` | 90.8M | 164.4M |
| 2 | `bloodmage_hexblast_r3` | Witch / Blood Mage | Hexblast | `--unique-variants` `--rounds 3` | 97.1M | 164.3M |
| 3 | `bloodmage_hexblast_r3_thorough` | Witch / Blood Mage | Hexblast | `--unique-variants` `--rounds 3` `--thorough` | 97.1M | 164.3M |
| 4 | `bloodmage_comet_r3_thorough` | Witch / Blood Mage | Comet | `--unique-variants` `--rounds 3` `--thorough` | 60.6M | 84.1M |
| 5 | `bloodmage_comet_uv` | Witch / Blood Mage | Comet | `--unique-variants` | 49.9M | 84.1M |
| 6 | `infernalist_comet_uv` | Witch / Infernalist | Comet | `--unique-variants` | 39.6M | 74.2M |
| 7 | `bloodmage_emberfusillade_r3_thorough` | Witch / Blood Mage | Ember Fusillade | `--unique-variants` `--rounds 3` `--thorough` | 56.1M | 73.3M |
| 8 | `bloodmage_emberfusillade_uv` | Witch / Blood Mage | Ember Fusillade | `--unique-variants` | 55.3M | 73.1M |
| 9 | `titan_hammerofthegods` | Warrior / Titan | Hammer of the Gods | `--unique-variants` | 36.5M | 67.2M |
| 10 | `titan_hammerofthegods_r3` | Warrior / Titan | Hammer of the Gods | `--unique-variants` `--rounds 3` | 37.2M | 67.1M |
| 11 | `bloodmage_firestorm_uv` | Witch / Blood Mage | Firestorm | `--unique-variants` | 36.1M | 58.5M |
| 12 | `lich_hexblast_r3` | Witch / Lich | Hexblast | `--unique-variants` `--rounds 3` | 43.6M | 56.5M |
| 13 | `lich_hexblast` | Witch / Lich | Hexblast | `--unique-variants` | 43.3M | 56.4M |
| 14 | `smithofkitava_hammerofthegods_r3` | Warrior / Smith of Kitava | Hammer of the Gods | `--unique-variants` `--rounds 3` | 23.4M | 52.2M |
| 15 | `smithofkitava_hammerofthegods` | Warrior / Smith of Kitava | Hammer of the Gods | `--unique-variants` | 19.2M | 51.1M |
| 16 | `stormweaver_comet_uv` | Sorceress / Stormweaver | Comet | `--unique-variants` | 14.2M | 47.1M |
| 17 | `warbringer_hammerofthegods` | Warrior / Warbringer | Hammer of the Gods | `--unique-variants` | 21.0M | 47.1M |
| 18 | `infernalist_emberfusillade_uv` | Witch / Infernalist | Ember Fusillade | `--unique-variants` | 33.9M | 45.6M |
| 19 | `deadeye_rainofarrows_uv` | Ranger / Deadeye | Rain of Arrows | `--unique-variants` | 21.1M | 34.4M |
| 20 | `discipleofvarashta_firestorm` | Sorceress / Disciple of Varashta | Firestorm | `--unique-variants` | 20.3M | 33.3M |
| 21 | `bloodmage_arc_uv` | Witch / Blood Mage | Arc | `--unique-variants` | 20.2M | 32.8M |
| 22 | `smithofkitava_superchargedslam` | Warrior / Smith of Kitava | Supercharged Slam | `--unique-variants` | 11.7M | 32.6M |
| 23 | `chronomancer_firestorm` | Sorceress / Chronomancer | Firestorm | `--unique-variants` | 19.8M | 32.6M |
| 24 | `discipleofvarashta_comet` | Sorceress / Disciple of Varashta | Comet | `--unique-variants` | 14.1M | 32.0M |
| 25 | `lich_skeletalsniper` | Witch / Lich | Skeletal Sniper | `--unique-variants` | 17.0M | 31.4M |
| 26 | `chronomancer_comet` | Sorceress / Chronomancer | Comet | `--unique-variants` | 14.2M | 31.3M |
| 27 | `chronomancer_emberfusillade` | Sorceress / Chronomancer | Ember Fusillade | `--unique-variants` | 16.3M | 29.3M |
| 28 | `infernalist_skeletalsniper` | Witch / Infernalist | Skeletal Sniper | `--unique-variants` | 15.7M | 24.5M |
| 29 | `discipleofvarashta_emberfusillade` | Sorceress / Disciple of Varashta | Ember Fusillade | `--unique-variants` | 16.3M | 21.4M |
| 30 | `tactician_plasmablast` | Mercenary / Tactician | Plasma Blast | `--unique-variants` | 11.4M | 17.9M |
| 31 | `abyssallich_skeletalfrostmage` | Witch / Abyssal Lich | Skeletal Frost Mage | `--unique-variants` | 9.1M | 16.2M |
| 32 | `acolyteofchayula_fallingthunder` | Monk / Acolyte of Chayula | Falling Thunder | `--unique-variants` | 11.1M | 16.0M |
| 33 | `acolyteofchayula_icestrike` | Monk / Acolyte of Chayula | Ice Strike | `--unique-variants` | 11.1M | 15.8M |
| 34 | `tactician_armourpiercingrounds` | Mercenary / Tactician | Armour Piercing Rounds | `--unique-variants` | 8.7M | 15.2M |
| 35 | `discipleofvarashta_frostbolt` | Sorceress / Disciple of Varashta | Frostbolt | `--unique-variants` | 9.2M | 13.0M |

<details><summary>Supports, uniques and keystones of each full run</summary>

| Run | Supports | Uniques | Keystones |
|---|---|---|---|
| `bloodmage_hexblast` | Considered Casting, Rakiata's Flow, Concentrated Area, Deliberation, Elemental Focus | Trenchtimbre, Mageblood, Prism of Belief (Hexblast), Voices (4 Sinister Sockets) | Eldritch Battery |
| `bloodmage_hexblast_r3` | Considered Casting, Rakiata's Flow, Concentrated Area, Elemental Focus, Deliberation | Trenchtimbre, Mageblood, Prism of Belief (Hexblast), Voices (4 Sinister Sockets) | Eldritch Battery |
| `bloodmage_hexblast_r3_thorough` | Considered Casting, Rakiata's Flow, Concentrated Area, Elemental Focus, Deliberation | Trenchtimbre, Mageblood, Prism of Belief (Hexblast), Voices (4 Sinister Sockets) | Eldritch Battery |
| `bloodmage_comet_r3_thorough` | Living Lightning II, Minion Pact II, Elemental Focus, Concentrated Area, Considered Casting | Mageblood, Prism of Belief (Comet), Voices (4 Sinister Sockets) | Eldritch Battery |
| `bloodmage_comet_uv` | Living Lightning II, Minion Pact II, Elemental Focus, Concentrated Area, Considered Casting | Mageblood, Prism of Belief (Comet), Voices (4 Sinister Sockets) | Eldritch Battery |
| `infernalist_comet_uv` | Living Lightning II, Minion Pact II, Scouring Flame, Concentrated Area, Considered Casting | Blood Price, Mageblood, Prism of Belief (Comet), Voices (4 Sinister Sockets) | - |
| `bloodmage_emberfusillade_r3_thorough` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices (4 Sinister Sockets) | Eldritch Battery |
| `bloodmage_emberfusillade_uv` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices (4 Sinister Sockets) | Eldritch Battery |
| `titan_hammerofthegods` | Zerphi's Infamy, Deliberation, Concentrated Area, Inexorable Critical I, Uul-Netol's Embrace | Blood Price, Loreweave, Rondel of Fragility, Ming's Heart, Mageblood, Voices (4 Sinister Sockets) | - |
| `titan_hammerofthegods_r3` | Zerphi's Infamy, Deliberation, Concentrated Area, Inexorable Critical I, Uul-Netol's Embrace | Blood Price, Loreweave, Rondel of Fragility, Ming's Heart, Mageblood, Voices (4 Sinister Sockets) | - |
| `bloodmage_firestorm_uv` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Ingenuity, Prism of Belief (Firestorm), Voices (4 Sinister Sockets) | Wildsurge Incantation |
| `lich_hexblast_r3` | Dialla's Desire, Rakiata's Flow, Concentrated Area, Deliberation, Chaos Mastery | Trenchtimbre, Mageblood, Voices (4 Sinister Sockets) | Eldritch Battery |
| `lich_hexblast` | Dialla's Desire, Rakiata's Flow, Concentrated Area, Deliberation, Chaos Mastery | Trenchtimbre, Mageblood, Voices (4 Sinister Sockets) | Eldritch Battery |
| `smithofkitava_hammerofthegods_r3` | Zerphi's Infamy, Close Combat II, Concentrated Area, Deliberation, Inexorable Critical I | Crest of Ardura, Blood Price, Kalandra's Touch, Ming's Heart, Mageblood, Voices (4 Sinister Sockets) | Crimson Assault |
| `smithofkitava_hammerofthegods` | Zerphi's Infamy, Close Combat II, Concentrated Area, Deliberation, Inexorable Critical I | Crest of Ardura, Atsak's Sight, Ming's Heart, Mageblood, Voices (4 Sinister Sockets) | Crimson Assault |
| `stormweaver_comet_uv` | Deadly Poison II, Rakiata's Flow, Concentrated Area, Considered Casting, Elemental Focus | Atsak's Sight, Plaguefinger, Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Comet) | - |
| `warbringer_hammerofthegods` | Zerphi's Infamy, Uul-Netol's Embrace, Concentrated Area, Inexorable Critical I, Deliberation | Blood Price, Loreweave, Ming's Heart, Mageblood, Voices (4 Sinister Sockets) | - |
| `infernalist_emberfusillade_uv` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices (4 Sinister Sockets) | Eldritch Battery |
| `deadeye_rainofarrows_uv` | Zerphi's Infamy, Rakiata's Flow, Concentrated Area, Hourglass, Elemental Armament II | Blood Price, Irongrasp, Wake of Destruction, Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Rain of Arrows) | - |
| `discipleofvarashta_firestorm` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Mageblood, Prism of Belief (Firestorm), Voices (4 Sinister Sockets) | Eldritch Battery, Wildsurge Incantation |
| `bloodmage_arc_uv` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Considered Casting | Trenchtimbre, Ingenuity, Voices (4 Sinister Sockets) | Eldritch Battery |
| `smithofkitava_superchargedslam` | Zerphi's Infamy, Close Combat II, Concentrated Area, Garukhan's Resolve, Uul-Netol's Embrace | Ming's Heart, Ingenuity, Voices (4 Sinister Sockets), Prism of Belief (Supercharged Slam) | - |
| `chronomancer_firestorm` | Rakiata's Flow, Elemental Focus, Considered Casting, Concentrated Area, Hourglass | Mageblood, Prism of Belief (Firestorm), Voices (4 Sinister Sockets) | Eldritch Battery, Wildsurge Incantation |
| `discipleofvarashta_comet` | Unleash, Rakiata's Flow, Concentrated Area, Considered Casting, Elemental Focus | Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Comet) | Eldritch Battery |
| `lich_skeletalsniper` | Pinpoint Critical, Poison III, Feeding Frenzy I, Uul-Netol's Embrace, Dialla's Desire | Bones of Ullr, Prism of Belief (Skeletal Sniper), Voices (4 Sinister Sockets) | - |
| `chronomancer_comet` | Unleash, Rakiata's Flow, Concentrated Area, Considered Casting, Elemental Focus | Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Comet) | Eldritch Battery |
| `chronomancer_emberfusillade` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices (4 Sinister Sockets) | Eldritch Battery |
| `infernalist_skeletalsniper` | Rakiata's Flow, Poison III, Feeding Frenzy I, Uul-Netol's Embrace, Dialla's Desire | Bones of Ullr, Prism of Belief (Skeletal Sniper), Voices (4 Sinister Sockets) | - |
| `discipleofvarashta_emberfusillade` | Living Lightning II, Minion Pact II, Rakiata's Flow, Elemental Focus, Deliberation | Mageblood, Voices (4 Sinister Sockets) | - |
| `tactician_plasmablast` | Rakiata's Flow, Garukhan's Resolve, Zerphi's Infamy, Elemental Armament II, Elemental Focus | Blood Price, Perfidy, Wake of Destruction, Ingenuity, Voices (4 Sinister Sockets), Prism of Belief (Plasma Blast) | - |
| `abyssallich_skeletalfrostmage` | Rakiata's Flow, Dialla's Desire, Feeding Frenzy I, Elemental Focus, Cold Attunement | Bones of Ullr, Voices (4 Sinister Sockets), Prism of Belief (Skeletal Frost Mage) | - |
| `acolyteofchayula_fallingthunder` | Rakiata's Flow, Zerphi's Infamy, Hit and Run, Embitter, Aftershock II | Collapsing Horizon, Wake of Destruction, Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Falling Thunder) | - |
| `acolyteofchayula_icestrike` | Rakiata's Flow, Zerphi's Infamy, Embitter, Hit and Run, Concentrated Area | Wake of Destruction, Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Ice Strike) | Chaos Inoculation |
| `tactician_armourpiercingrounds` | Rakiata's Flow, Fresh Clip II, Hit and Run, Elemental Focus, Elemental Armament II | Hyrri's Ire, Wake of Destruction, Mageblood, Voices (4 Sinister Sockets), Prism of Belief (Armour Piercing Rounds) | - |
| `discipleofvarashta_frostbolt` | Elemental Focus, Rakiata's Flow, Concentrated Area, Inexorable Critical I, Deliberation | Mageblood, Voices (4 Sinister Sockets) | - |

</details>

## Survivability runs

Eight runs with the survivability score (score = damage^(1−w) × effective HP^w) and approximations on
(1 kill per second), same realistic settings, uniques with all versions. Effective HP is PoB's
effective hit pool against its default enemy hits. They were run after the Runic Ward fix to the
effective HP calculation (commit 8efa6ca9d).

| Build | Survivability weight | Approx. | Combined DPS | Effective HP | Life / ES | Resistances |
|---|---:|:---:|---:|---:|---|---|
| Blood Mage Hexblast | 0% | on | 164.4M | 1,792 | 1,800 / 0 | −5% |
| Blood Mage Hexblast | 25% | on | 73.8M | 21,055 | 2,175 / 244 | capped |
| Blood Mage Hexblast | 50% | off | 18.8M | 144,398 | 3,484 / 1,183 | capped |
| Blood Mage Hexblast | 50% | on | 21.9M | 75,895 | 3,061 / 1,091 | capped |
| Titan Hammer of the Gods | 50% | on | 7.9M | 914,468 | 2,709 / 222 | capped |
| Lich Skeletal Sniper | 50% | on | 3.3M | 230,697 | 2,387 / 0 | capped |
| Infernalist Comet | 50% | on | 8.5M | 105,137 | 2,406 / 6,905 | 65% |
| Deadeye Rain of Arrows | 50% | on | 15.2M | 85,212 | 2,616 / 0 | capped |

- At 25% weight Hexblast keeps 45% of its damage and gets about 12 times the effective HP, with
  capped resistances. At 50% it trades most of its damage for defence.
- **Approximations** didn't change the damage-only build (164,404,159 both ways). With them on,
  every survivability build picked the "Legacy of Keeper of the Arc" rune, whose alternating
  "Take 20% less Damage from Hits" counts half as an approximation. The run with them off didn't.
- The two Hexblast runs at 50% differ mainly because the search took different paths. One run per
  setting can't settle which is better.
- Effective HP is a hit pool, so recovery (regeneration, leech, recovery on kill) doesn't count
  toward the score. Most builds end with no net life recovery.

## Tankiest builds

Ten class and skill combinations with survivability weight 1, so the score is effective HP only, with
approximations on and the same realistic settings. Damage doesn't count at all, so these builds deal
almost none. They show how much defence the engine can stack.

| # | Build | Effective HP | Life / ES | Armour / Evasion | Block | Max hit (phys / fire) | Net Life recovery |
|---:|---|---:|---|---|---:|---|---:|
| 1 | Titan Earthquake | endless | 4,166 / 0 | 50,020 / 32,802 | 50% | 9,199 / 26,926 | 41.7/s |
| 2 | Warbringer Shield Charge | endless | 2,668 / 188 | 35,817 / 28,463 | 60% | 8,018 / 20,902 | 13.3/s |
| 3 | Chronomancer Comet | endless | 2,537 / 89 | 34,757 / 21,725 | 58% | 7,667 / 13,220 | – |
| 4 | Lich Skeletal Sniper | 3,047,779 | 2,831 / 3,796 | 23,343 / 30,801 | 58% | 13,204 / 40,839 | 4.8/s |
| 5 | Pathfinder Rain of Arrows | 1,950,303 | 2,651 / 0 | 34,242 / 35,073 | 50% | 9,478 / 26,883 | – |
| 6 | Shaman Fury of the Mountain | 1,881,205 | 4,434 / 0 | 32,532 / 32,814 | 17% | 13,788 / 35,944 | – |
| 7 | Gemling Legionnaire Fragmentation Rounds | 1,853,618 | 4,596 / 0 | 31,862 / 33,042 | 16% | 12,323 / 33,399 | – |
| 8 | Amazon Lightning Spear | 1,703,648 | 3,104 / 284 | 41,170 / 51,299 | 50% | 9,191 / 26,210 | – |
| 9 | Witchhunter Galvanic Shards | 772,045 | 3,484 / 338 | 35,535 / 35,053 | 17% | 8,277 / 32,939 | – |
| 10 | Invoker Ice Strike | 562,890 | 3,321 / 531 | 27,294 / 30,737 | 15% | 9,049 / 31,548 | – |

- **"Endless"** means the build recovers more per enemy attack than it loses against PoB's default enemy,
  so the effective HP simulation never ends. The Chronomancer, for example, recovers 119 Life and
  12 ES per block, blocks 58% of hits and isn't hit at all 68% of the time. The optimizer caps
  endless at one value, so the order of the top three is arbitrary. By maximum hit taken, Titan leads.
- Every build caps or overcaps its resistances except the Chronomancer, which out-heals the default
  enemy anyway.
- The largest single hits are taken by the Lich (13.2k physical, 40.8k fire), thanks to its large
  Energy Shield.

## Damage builds with approximations

The ten best damage combinations, run again on the current engine with approximations on (1 kill per
second) and damage as the only score.

| # | Build | Rares only | With uniques |
|---:|---|---:|---:|
| 1 | Blood Mage Hexblast | 90.8M | 164.4M |
| 2 | Blood Mage Comet | 49.9M | 84.1M |
| 3 | Infernalist Comet | 39.6M | 74.2M |
| 4 | Blood Mage Ember Fusillade | 55.3M | 73.1M |
| 5 | Titan Hammer of the Gods | 36.5M | 67.2M |
| 6 | Blood Mage Firestorm | 36.1M | 58.5M |
| 7 | Lich Hexblast | 43.3M | 56.4M |
| 8 | Smith of Kitava Hammer of the Gods | 19.2M | 51.1M |
| 9 | Stormweaver Comet | 14.2M | 47.1M |
| 10 | Warbringer Hammer of the Gods | 21.0M | 47.1M |

Every result is identical to the earlier runs of the same build, to the last digit. The approximations
so far only cover defence and recovery, and the new defence mechanics don't change damage. Damage
approximations, such as Elemental Infusion and Archon uptime, are the next step of the
[calculation gaps plan](calculationGapsPlan.md).

## Caveats

- Scores are what Path of Building calculates. Some modifiers on the chosen runes and uniques are marked
  "Not supported in PoB yet" and are left out, and some strong uniques (Trusted Kinship, Demon Stitcher,
  Scold's Bridle and others) could only be judged by their readable part. Every build's summary lists them under
  *Strong options the engine could not fully evaluate*.
- The optimizer maximises damage only. Defences, mana sustain and how the build plays are not part of the score.
- A score depends on the game data of the program version the runs were made with; later data changes can move
  the ranking.
