# Plan: closing the calculation gaps in PoB2

Path of Building for PoE2 cannot yet calculate a large share of the game's modifiers. A modifier the
engine can't read is worth nothing to the calculation, and so also to the [build optimizer](buildOptimizer.md),
however strong it is in the game. This plan measures the gaps, sorts them by what it takes to close
them, and sets out the work in phases: real calculations first, an approximation model only for
what can't be calculated exactly.

**Decisions (November 2026)**
- Approximations are **off by default**. A button in the build screen's sidebar, next to *Optimizer* (*Approx: Off / On*),
  turns them on and off, along with the *Use approximations* option in the Configuration tab.
- **Defence mechanics come first**, alongside the parser work: Guard, recoup, stun, block, damage
  taken and recovery.

## Contents

- [Where we stand](#where-we-stand)
- [What kind of gaps these are](#what-kind-of-gaps-these-are)
- [Data sources](#data-sources)
- [Phases](#phases)
- [The approximation model](#the-approximation-model)
- [Validation](#validation)
- [Open questions](#open-questions)

## Where we stand

Census of the program's data on branch `build-optimizer`, November 2026. It counts entries with at
least one modifier the engine can't read, using the optimizer's coverage report
(`optimizer.CoverageReport`):

| Data | Not fully calculated | Share |
|---|---:|---:|
| Keystones | 10 of 33 | 30% |
| Ascendancy passives | 74 of 404 | 18% |
| Notables | 207 of 984 | 21% |
| Small passives | 186 of 3,074 | 6% |
| Unique items | 210 of 443 | 47% |
| Item affixes | 118 of 2,550 | 5% |
| Jewel affixes | 14 of 377 | 4% |
| Flask affixes | 24 of 78 | 31% |
| Charm affixes | 25 of 51 | 49% |
| Desecrated affixes | 55 of 388 | 14% |
| Corruption modifiers | 5 of 127 | 4% |
| Rune / soul core effects | 128 of 627 | 20% |
| Support gems with a stat that has no calculation | 307 of 567 | 54% |
| Skill gems with a stat that has no calculation | 260 of 263 | 99% |

In total there are 1,391 modifier lines the engine can't read. There are also 500 support gem stats
and 2,594 skill gem stats without a calculation. Many of the gem stats only change visuals or geometry.

The modifier lines fall into these mechanics (one group per line, first match wins):

| Mechanic | Lines | Examples |
|---|---:|---|
| Life, mana and ES recovery, leech, regeneration | 151 | Recover 3% of maximum Life when an Enemy dies in your Presence |
| On-kill, on-hit, "every N seconds", triggers | 144 | 25% chance to Intimidate Enemies for 4 seconds on Hit |
| Endurance, frenzy and power charges | 113 | Attacks consume an Endurance Charge to Critically Hit |
| Ailments | 102 | Ignites you inflict spread to other Enemies within 1.5 metres |
| Elemental Infusion and Archon | 87 | Every 5 seconds, gain a Verisium Infusion |
| Minions, companions, totems | 62 | Gain 3% of Damage as Chaos Damage per Undead Minion |
| Stun, daze, block, parry, Guard | 60 | Gain Guard equal to 10% of missing Energy Shield when you Dodge Roll |
| Spirit, reservation, auras, Presence | 43 | Remnants you create affect Allies in your Presence |
| Movement, sprint, dodge roll | 31 | Dodge Roll avoids all Hits |
| Ground surfaces, curses, shapeshifting, Thorns, flasks, utility, other | 83 | Chance to deal your Thorns Damage to Enemies you Hit |
| Not in a mechanic group | 515 | Lightning Skills Chain +1 times; Take 30% less Damage from Hits |

## What kind of gaps these are

Very few of the gaps are missing data. The game data PoB2 needs is already in `src/Data`: values,
tiers, per-level gem stats and stat texts. What's missing falls into four kinds, from cheapest to
most expensive:

1. **Parser gaps.** The engine already models the mechanic but doesn't recognise the text.
   - About 300 lines have no condition attached, such as "Lightning Skills Chain +1 times",
     "Projectiles from Spells Fork" and "Take 30% less Damage from Hits".
   - 43 lines are fragments of modifiers that span two lines and are read as two halves, such as
     "...gain Onslaught for 3 seconds when you kill an" / "Enemy".
   - 24 lines use negative ranges like "(-15-15)% reduced Cast Speed".
   - Fix: patterns in `ModParser.lua`. No new data is needed.
2. **Gem stats without a stat map.** The stat and its values per level are exported, but no
   `SkillStatMap` or `statMap` entry turns them into modifiers.
   - About 900 of the 2,594 skill gem stats look visual or geometric (art variations, radii,
     display stats) and only need to be marked as such.
   - The rest need a mapping, and some need a new engine mechanic (kind 3).
3. **Missing mechanics with known rules.** Infusion and Archon, charge generation, Guard, Thorns,
   recovery on events, ailment spread, Presence. The numbers are in the data. The rules come
   from patch notes, the in-game help texts and community testing. Each one needs engine code in
   `CalcOffence` / `CalcDefence` / `CalcPerform` and usually a configuration option.
4. **Behaviour-dependent effects.** On kill, on hit, on dodge roll, "every N seconds", chance to
   gain a buff. The rule is exact, but how often it fires depends on how the build is played
   (kill rate, enemies nearby, boss or mapping). PoB has no fixed answer for these. They need the
   [approximation model](#the-approximation-model).

## Data sources

| Source | What it gives | Use |
|---|---|---|
| **PoB2's own exporter** (`src/Export`) | Reads the game's bundled `.datc64` tables and stat descriptions from a local install and writes `src/Data`. Raw stat IDs, per-level values, mods, tiers, tree | **Main source.** We already data-mine ourselves. Re-run it for every game patch, and extend `src/Export/Scripts` when a table we need isn't exported yet (e.g. buff definitions) |
| dat-schema ([poe-tool-dev/dat-schema](https://github.com/poe-tool-dev/dat-schema)), [poe-dat-viewer](https://github.com/SnosMe/poe-dat-viewer) | Community schema of the dat tables; the viewer supports PoE2 `.datc64` | Find columns and tables our `spec.lua` doesn't read yet |
| [poe2db.tw](https://poe2db.tw/us/) | The same game files rendered as HTML. Per-level tables, hidden stats, version history | **Checking only.** It has no API, and its content is CC BY-NC-SA, so no bulk scraping. It adds no formulas we can't get from our own export |
| [poe2wiki.net](https://www.poe2wiki.net/) | Cargo tables (e.g. `skill_stats_per_level`) and mechanic pages written by players | Mechanic descriptions and test results. The site blocks automated requests, so it's for reading by hand |
| Patch notes, developer posts, in-game help texts | The stated rules of mechanics | Source for kind 3 |
| Measurement in the game | Actual damage, uptime, recovery | Calibrating kind 4 and checking kind 3 |

**Key limitation.** The game files hold values and texts, not formulas. Many rules live in the
game's code, often on the server. They can't be data-mined. They come from statements and
measurement, and that's true for poe2db as well.

**Rules.**
- Only read local game files offline, the way the exporter does today.
- Don't touch the running game or undocumented web endpoints. GGG's developer docs list those as
  Terms of Use violations.
- Datamined content can include decoy assets, so a new mechanic only goes in once a patch note,
  a help text or a measurement confirms it.

## Phases

Every phase finishes with one runnable check: a spec in `spec/System` or a census number that has to
go down.

### Phase 0: Gap tracker (done)

- `python OptimizeBuild.py --gaps [lines.tsv]` (run in `src`, script `src/CalcGaps.lua`) prints
  the counts above and the count per mechanic group. With a file name, it also writes every
  unreadable line with its source (unique, passive, affix, rune) and mechanic group.
- `--rank <results folder>...` ranks the lines by impact: it reads every optimizer summary (`*.txt`) under the
  folders, matches their *Strong options the engine could not fully evaluate* and *Parts of this build the engine does
  not calculate* lines to the census (numbers and ranges become `#`), and appends the columns seen in builds, strong
  option, best readable part, data frequency and score to the tsv (sorted by score). Score = seen in builds x 3 +
  strong option + data frequency / 10 (a notable or keystone row counts 5 in the frequency). A line counts once per
  summary. To rerun: `python OptimizeBuild.py --gaps lines.tsv --rank <folder>...`; check with `--gaps --selftest`.
- Current to-do order (top 30 of 1,040 lines, November 2026; summaries from top100, top100b, survival, survival2,
  tank_approx, archon_dps, archon_dps2). Strong option counts are inflated, as stage 1 and stage 2 list the same
  build; read them as a ranking, not as a count of builds.

| Score | Seen | Strong | Group | Line |
| ---: | ---: | ---: | --- | --- |
| 833.0 | 173 | 305 | Other | (10-15)% reduced Slowing Potency of Debuffs on You |
| 595.5 | 185 | 40 | Other | Offerings cannot be damaged if they have been created Recently |
| 330.1 | 0 | 330 | Thorns | Gain Physical Thorns damage equal to 8% - 12% of maximum Life |
| 327.2 | 0 | 327 | Movement, sprint, dodge roll | Your speed is Unaffected by Slows while Sprinting |
| 320.2 | 0 | 320 | Other | Deal 10% of Overkill damage to enemies within 2 metres of the enemy killed |
| 320.1 | 0 | 320 | Ailments | Drop Ignited Ground while moving, which lasts 8 seconds and Ignites as though dealing Fire Damage equal to 10% of your maximum Life |
| 318.6 | 0 | 318 | Minions, companions, totems | You can have two Companions of different types |
| 217.3 | 0 | 215 | Other | Meta Skills gain (10-16)% increased Energy |
| 214.5 | 0 | 214 | Other | Echoed Spells have 25% increased Area of Effect |
| 192.0 | 0 | 191 | On kill, on hit, triggers | Attacks have 10% chance to Maim on Hit |
| 190.5 | 0 | 190 | Minions, companions, totems | 50% increased Minion Damage while you have at least two different active Offerings |
| 188.1 | 0 | 188 | Other | Take (25-100)% of Mana Costs you pay for Skills as Physical Damage |
| 187.5 | 0 | 187 | On kill, on hit, triggers | Invocation Skills cannot gain Energy while Triggering Spells |
| 187.5 | 0 | 187 | On kill, on hit, triggers | Invocation Skills instead Trigger Spells every 2 seconds |
| 187.5 | 0 | 187 | Other | Invoked Spells consume 50% less Energy |
| 185.1 | 0 | 185 | Other | Critical Hits cannot Extract Impale |
| 185.1 | 0 | 185 | Other | Critical Hits inflict Impale |
| 181.1 | 0 | 181 | On kill, on hit, triggers | Sacrifice (5-15)% of maximum Life to gain that much Energy Shield when you Cast a Spell |
| 177.5 | 2 | 170 | On kill, on hit, triggers | (20-39)% chance to build an additional Combo on Hit |
| 176.1 | 0 | 176 | Other | 10% of Physical damage dealt by your Hits causes Blood Loss |
| 155.5 | 0 | 155 | Other | 20% chance for Damage of Enemies Hitting you to be Unlucky |
| 155.5 | 0 | 155 | Other | 40% increased Projectile Damage with Spears while there are no Enemies within 3m |
| 149.1 | 0 | 149 | Charges | Gain a random Charge on reaching Maximum Rage, no more than once every (3-6) seconds |
| 136.1 | 0 | 136 | Flasks, charms | (25-50)% increased Corrupted Charms effect duration |
| 120.3 | 40 | 0 | On kill, on hit, triggers | Alternating every 5 seconds: |
| 114.2 | 0 | 114 | Ailments | Enemies in your Presence are Ignited as though dealt 100 Base Fire Damage |
| 111.2 | 37 | 0 | Other | Maim on Critical Hit |
| 110.2 | 0 | 110 | Other | 250% of Melee Physical Damage taken reflected to Attacker |
| 109.2 | 0 | 109 | Other | Gain 10 Rage when Critically Hit by an Enemy |
| 108.5 | 0 | 108 | Other | Volatile Power also grants 1% increased Critical Hit chance per Volatility exploded |

- Output: a sorted to-do list, and numbers that show progress after every phase.

### Phase 1: Parser gaps (about 370 lines, low risk)

Defence lines first (Guard, recoup, stun threshold, block, damage taken, armour break, resistances).

Progress:
- First defence pass done. Now parsed: stun threshold and evasion while parrying or with the shield raised,
  block with a raised shield, leech rates, flask recovery, recoup during flask effect, dodge-roll conditions,
  physical damage taken as cold or lightning, and negative ranges that roll to 0.
- New config options: *Are you Parrying?* and *Is your Shield raised?*.
- Recovery on kill (including "when an Enemy dies in your Presence") is the first approximation.
  Keeper of the Arc's alternating "less Damage from Hits" counts half, as an approximation.
- Census: 1,391 → 1,352 unreadable lines.
- Second defence pass, with new engine code:
  - **Recoup:** of damage prevented by armour and physical reduction, of deflected hits, and of damage
    blocked (as mana); "increased speed of Recoup Effects" applies to every recoup.
  - **Guard:** a buffer in front of Life and ES, capped at maximum Life (or ES), with a
    *Do you have Guard?* option. Only the largest source counts, an assumption until tested in the game.
  - **Approximation-only:** Guard from events, and chance to Avoid Death from Hits (capped at 99%).
  - Census: 1,352 → 1,309.
- Optimizer: survivability score (damage^(1−w) × effective HP^w) and an approximations option.
  Effective HP is a hit pool, so recovery doesn't raise the score yet. That needs its own term.
- Still open: Armour Break, Dodge Roll, leech and flask overflow, Guard from sacrificed life, and
  life-flask-based Guard.
- Third pass:
  - **Wrapped modifiers:** modifiers the game wraps over two lines are read as one, on the tree, items
    and in the census. A line that is understood on its own is never given up for a continuation.
  - **New patterns:** chain and fork for spells and lightning skills, mana cost efficiency of spells,
    and "Equipment has no Attribute Requirements".
  - **Archon Buffs:** effect scaling of "Archon Buffs also grant", "while affected by an Archon Buff",
    and recovery-period modifiers, with an *Are you affected by an Archon Buff?* option. With
    approximations on, the uptime is duration / (duration + recovery period). Duration and recovery
    period default to 10 s each, a guess; the real values come from the buff definitions.
  - **Elemental Infusion supply**: see Phase 3.
  - **Data re-export** against the live game (Forbidden Rites): skills, mods, uniques, stat descriptions,
    soul cores and the tree are unchanged.
  - Census: 1,309 → 1,170.
- Fourth pass: Archon values and Elemental Infusions, from the live game data
  - **Data:** the exporter writes the Archon Buff templates (10 s duration and each buff's own stats) to
    `data.archonBuffs`; infusion constants (3 per element, 20 s, remnants 12 s) were already in
    `data.gameConstants`. The Archon recovery period isn't in the game data and stays a configurable guess.
  - **Archon Buffs** apply their own stats (25% more spell damage of their element, conversion, more ailment
    chance, Undeath minion damage, Nature plant damage and duration, Chayula physical and chaos damage),
    with an *Archon Buff* choice in the configuration.
  - **Elemental Infusions:** exact counts per element in the configuration, capped at the maximum. With
    approximations on, the Calcs tab also estimates remnant generation, consumption, infused share and
    average stacks; the second pass (Phase 4) feeds the average stacks to the counts left empty.
  - **Known limits:** Siphon Elements counts as a buff on you (as in the game). Archon of Undeath's Command
    cooldown has no effect yet (no Command skill condition). With several Archon sources the first one is
    used. Whether increased Archon effect scales the conversion is untested.
  - Census: 1,170 → about 1,126.
- Fifth pass ("Other" group, 994 → 973 unreadable lines, Other 465 → 453): Armour Break sources, Rage gained on any event,
  damage / crit chance per time pierced, two additional Projectiles while moving, Chaos taken as a random element,
  enemies on full life can't evade, and stun / chill immunity conditions. Most of the rest of the group needs a new
  mechanic: Slow Potency / Magnitude, Remnants, Meta-skill Energy, Glory, chance-based Fork / Maim, Impale (a legacy
  PoE1 stat the engine zeroes) and non-calculation lines (crafting, fishing, gold).

- Join modifiers that span two lines before parsing.
- Accept negative ranges.
- Add `ModParser.lua` patterns for unconditional lines whose mechanic the engine already has
  (chain, fork, pierce, "less damage from hits", armour break, slow magnitude, ...).
- Check: a spec with one line per pattern, which must parse to the expected modifiers. The census
  count must drop.

### Phase 2: Gem stats (about 3,100 stats, mostly mechanical)

- Mark the visual and geometric stats as having no effect on the calculation, in a list next to
  `SkillStatMap.lua`, so they leave the census.
- Map the remaining stats that correspond to existing mechanics. Start with support gems: there
  a missing stat usually means a missing effect.
- Re-run the exporter for the current game version first, so the mapping isn't done against
  stale data.
- Check: the gem lines of the census, plus spot checks of per-level values against poe2db.

### Phase 3: Missing mechanics, in order of impact

Order by the Phase 0 ranking. The census suggests this order:

1. **Elemental Infusion and Archon** (87 lines, mostly on the tree). These are central to caster
   builds, and the top optimizer builds are casters.
   - Archon done (November 2026): an *Are you affected by an Archon Buff?* option applies "Archon Buffs also
     grant ..." (scaled by the effect of Archon Buffs) and "while affected by an Archon Buff" lines. With
     approximations on, an Archon source gives the "also grant" part an uptime of duration / (duration + recovery
     period), from *Archon Buff duration* and *Archon recovery period* inputs (10 s each, a guess: the base values
     and what each Archon Buff grants by itself aren't exported yet, see Phase 5).
   - Census: 1,309 → 1,261; Infusion / Archon 87 → 39.
   - Archon Buffs' own effects and Elemental Infusion (November 2026), from the exported buff templates and game
     constants (Phase 5):
     - An *Archon Buff* choice (Elemental, Flame, Ice, Lightning, Undeath, Nature, Chayula; by default the one your
       Archon source grants) applies the buff's own stats: more spell damage of its element and conversion to it, more
       ignite / shock chance and freeze buildup with spells, more minion damage and Command cooldown recovery (Undeath),
       plant damage and duration (Nature), more physical and chaos damage and Wither (Chayula). The effect of Archon
       Buffs scales them, an assumption from the wording. The base duration (10 s) comes from the data; the recovery
       period isn't in the data and stays a 10 s input. Not modelled: Overgrown chance, plant and temporary minion
       limits, Chayula's tornado.
     - *# of Fire / Cold / Lightning Infusions* set `Multiplier:<Element>Infusion`, capped at 3 per element plus
       "maximum ... Infusions" (each infusion buff has its own maximum); the Inhibitor support counts infusion types.
       Infusion duration is 20 s, raised by "Elemental Infusion duration".
     - With approximations on and a count left empty, the average infusions and the share of infused casts of the main
       skill are estimated from Remnant generation (Siphon Elements' chance on ignite / freeze / shock, a per-element
       *Infusion Remnants/s, other* input, remnant conversion keystones, extra remnants and infusions on pickup,
       Verisium every N s) and consumption (casts of a skill that consumes the infusion, less the chance to not remove
       it). The rates come from the offence calculation, so the second pass (Phase 4) feeds the average stacks to
       `Multiplier:<Element>Infusion`; the infused share is reported only (PoB has no infused skill variants).
     - Census: 1,171 → 1,126; Infusion / Archon 35 → 4 (Infernal Flame, minion Archon, Power Charge on consumption).
2. **Charges**: generation, consumption and "per charge" effects (113 lines).
   - Done (November 2026), rules from the stat descriptions:
     - **Exact, from the configured charges:** Nebuloch's "Attacks consume an Endurance Charge to Critically Hit" (attacks always crit with
       an Endurance Charge to spend), Redflare Conduit's "lose all Power Charges on reaching maximum" (at most maximum - 1), Conduit and its
       rune versions (the charges go to allies, so you have none). "Per charge", "while at maximum" and maximum-charge lines were already read.
     - **Approximation (Use approximations on, "Do you use ... Charges?" left unchecked):** charges gained per second from "chance to gain a
       ... Charge on kill / Hit / Critical Hit", Resonance's swapped types, additional charges per gain, "instead gain up to maximum", and the
       main skill's consumption (less "chance to not remove Charges"). Average charges ≈ min(maximum, gain rate × duration); for a consuming
       main skill, charges per use ≈ min(maximum, gain rate × time between removing uses), and charges consumed Recently (4 s). With
       Nebuloch an attack main skill spends one Endurance Charge per crit: the share of attacks that crit ≈ min(1, gain rate / attack rate)
       (the exact 100% applies only to a configured count).
     - The kill-based part feeds the charge count, before offence, for charge types the main skill doesn't consume. Hits, critical hits and
       uses are only known after offence, so the second pass (Phase 4) feeds the full estimate: the count (charges per use for a consuming
       main skill), the charges consumed Recently, and Nebuloch's share as crit chance.
       Per-charge modifiers count whole charges (multipliers are floored), so a fractional average counts its integer part.
     - Not modelled: charges on Stun, Block, Heavy Stun, Low Life or maximum Rage and from charm use (no event rate), recovery per consumed
       charge (Phase 3 item 3), Elemental / Chaotic Surge triggers, charge sharing with allies.
     - Census: 1,126 → 1,076; Charges 105 → 55 (the rest are mostly flask, charm and Energy Shield Recharge lines the group's word match catches).
3. **Recovery on events**: on kill, in Presence, leech variants (151 lines). Started early, as the
   first user of the approximation model: on-kill recovery uses the kills-per-second rate.
4. **Ailments**: spread, magnitude and duration interactions (102 lines).
   - Done (November 2026), rules from the stat descriptions:
     - **Exact:** increased chance to Poison / inflict Bleeding, "Chance to Poison is calculated from your base chance to inflict Bleeding
       instead" and the reverse (the other ailment's flat chance), Magnitude of Elemental Ailments with Spells (Ignite, Shock, Chill; spell
       Ignite only), Elemental Ailment Application (Ignite and Shock chance, like "chance to inflict Elemental Ailments"; whether it raises
       Freeze Buildup is untested), "<type> Damage from Hits also Contributes to Flammability and Ignite / Chill Magnitudes", Freeze Buildup
       with Empowered Attacks, minions' Magnitude of Damaging Ailments, "Enemies Ignited by you permanently take ... Fire Damage" (new
       *Seconds of ignite on enemy?* option, like the chill and freeze ones), "Enemies standing on Chilled / Ignited Ground take ..." (new
       *Is the enemy on Ignited Ground?* option), "Projectiles Pierce all Ignited enemies", Become Ignited on Critical Hit (Fire degen
       while *Are you Ignited?*).
     - **Approximation (Use approximations on):** aggravating Bleeding on Hit, on Critical Hit, with Empowered Attacks and "older than N
       seconds". A Hit aggravates the Bleeding instances on the target for the rest of their duration D (100% more damage), and the
       strongest instance deals damage, so the share is the chance that an aggravated instance is alive: 1 − e^(−a·(D − N)) for "older
       than N" (a = Bleeding applied per second) and 1 − e^(−r·D) for chances on Hit / Critical Hit (r = hits/s × chance per hit),
       combined as independent. Hit rates are known inside offence, so this feeds Bleed DPS directly (Calcs tab, Bleed: *Aggravated
       (approx.)*). The Malady support's base chance swap is mapped too.
     - **Pack only (Use approximations on, new *Enemies near the target* input, 3 by default, a guess):** Ignite spread gives *Pack DPS
       (approx.)* = Ignite DPS × (1 + enemies near the target); Shock spread gives the average Shocked enemies near the target,
       enemies × (1 − e^(−chance × Shocking Hits/s × Shock duration)). Neither changes single-target DPS or the optimizer score.
     - Not modelled: ailments on you (chill from damage taken, reflected Poison / Ignite, immunity windows, Electrocute immunity), Volatility,
       Rage on Ignite, Shatter,
       "per Enemy Ignited / Frozen in the last 8 seconds", Withered not expiring, aggravated Ignites, Beasts (no enemy type option).
     - Census: 1,076 → 1,040; Ailments 98 → 65.
5. **Guard, block, stun and parry** (60 lines). Moved forward with the defence work. The optimizer
   doesn't score defence yet, which needs a survivability score as well as damage.
6. **Thorns, ground surfaces, shapeshifting, Presence effects.**
   - Thorns, Overkill and Ignites not caused by your Hits done (November 2026), rules from the stat descriptions:
     - **Exact:** Physical Thorns damage equal to 8% - 12% of maximum Life, per Runic Plate (new *# of Runic Plates* option, at most 4
       from Runic Tempering's `runic_tempering_max_runes`), Lucky Thorns against Fully Broken Armour, and Thorns on melee Hits ("N% chance
       to deal your Thorns Damage to Enemies you Hit with Melee Attacks", "... you Critically Hit with Melee Attacks"). A Thorns hit is the
       hidden Thorns skill's Average Damage; on-hit Thorns DPS = chance per landed Hit x Hits per second x that damage. It is damage of the
       main skill's Hits on the target, like Impale, so it is added to Combined DPS and Full DPS (and so to the optimizer's score); shown as
       *Thorns on Hit DPS* (Calcs tab, Other Effects; sidebar). Totems and other proxies don't count, and a combined hit of both weapons is one
       Hit. The Thorns damage comes from a second calculation with the Thorns skill as main skill (with the candidate's override and the
       optimizer's cached base databases), only for skills with these lines: about 1.5x the time of an evaluation for those builds. A
       calculation without a MAIN pass (optimizer candidates) adds the Thorns skill without its group when the candidate brings the first
       Thorns damage. Also fixed: Thorns from "0.08% of Item Armour on Equipped Body Armour" (decimal percentages).
     - **Approximation (Use approximations on):** Thorns retaliating against Hits you take, at *Enemy hits on you per second* (2 by default,
       a guess) x 1/2 (assumed Melee share; every Hit with "Thorns can Retaliate against all Hits"). This replaces the Thorns skill's speed
       (so speed modifiers don't scale it; without approximations it keeps PoB's 1 hit/s placeholder) and shows as that skill's own DPS, never
       in another skill's Combined DPS.
     - **Pack only (approximations on):** "Deal N% of Overkill damage to enemies within 2 metres of the enemy killed": *Overkill Pack DPS
       (approx.)* = kills/s x half an average landed Hit x N% x enemies near the target.
     - **Per affected enemy, outside Combined DPS:** "Enemies in your Presence are Ignited as though dealt N Base Fire Damage" and the Ignited
       Ground of "Drop Ignited Ground while moving ... equal to N% of your maximum Life": N x 20%/s (IgniteHitDamagePercentPerMinute) x Ignite
       Magnitude x the enemy's Fire resistance and damage taken. The base isn't scaled by your damage modifiers (unclear from the texts). An
       enemy has one Ignite, the strongest, so these don't add to the main skill's Ignite.
     - Not modelled: Thorns on Stun (no stun rate), Thorns retaliation cooldowns, Overkill's armour mitigation, charm-created Ignited Ground.
     - Census: 1,040 → 1,028; Thorns 8 → 1, Ailments 65 → 62, Other 467 → 465.
7. **Minions, companions, totems** (59 lines). Done (November 2026), rules from the stat descriptions and skill data:
   - **Exact, from the skills in the build:** counts of persistent Minions (`Multiplier:PersistentMinions`, a skill without a limit is one
     Minion, a pool with a limit counts its limit), Undead Minions (`CreatesUndeadMinion` skills) for "Gain N% of Damage as Chaos Damage per
     Undead Minion", different active Offerings (the Bone, Pain and Soul Offering skills, for "50% increased Minion Damage while you have at least
     two different active Offerings"), and different Companions (for "15% increased Damage per each different Companion in your Presence").
     *Companion limit:* one, "You can have two Companions of different types" makes it two (the keystone and Yriel's Fostering don't add up),
     "any number" unlimited. The stat descriptions give no base, so one is read from that wording (`ponytail`). The main skill's Companion gets
     a slot first, then the skill list order decides; Wild Protector's Bear Spirit takes none (its description). PoB can't switch a skill off, so
     a Companion past the limit still calculates its own skill; it only stops counting as one of "your Companions" (types, persistent types,
     persistent Minions). The same Minion from two socket groups counts once. "Minions Revive 35% faster if all
     your Minions are Companions" looks at the persistent Minion skills only. "Your Totem Limit is doubled" is 100% more of the total Totem
     limit (also of the additional Totems; Ballistas are Totems).
   - **Exact, from the configuration:** *# of different active Offerings*, *# of Undead Minions* (the Skeleton skills have no limit stat in the
     current data, their number depends on Spirit), *# of different types of dead Companions* ("Companions deal 10% more Damage for each ..."),
     *Have your Minions Revived Recently?* (Gigantic, 20% more Life and Damage), *Is the enemy a Beast?* (Culling Strike against Beasts with a
     Companion in your Presence; *# of different Companions (if not all)* overrides the Companion count), the existing *Has a Minion Died Recently?* now also drives "Gain Onslaught / Arcane Surge when a Minion Dies".
     Also read: Minions' Surpassing chance for an additional Projectile, "Every five Rage also grants ... Minion Attack Speed", Companions in
     your Presence (resistances, extra Damage of a random Element, Onslaught while Shapeshifted: all need the Companion in your Presence),
     Minions Break Armour (like Anvil's Weight it only enables *Is enemy Armour Broken?*, the amount isn't calculated), reduced Reservation
     Efficiency of Undead Minion skills, Minions Revive slower, and Totem placement range (no effect on the calculation).
   - **Approximation (Use approximations on and a Minion that can die, new *Minion deaths per second* input, 0.1 by default, a guess):** Onslaught (4 s) and Arcane
     Surge (10 s, the support's `support_arcane_surge_base_duration_ms`; the Minion death text gives none) gained when a Minion dies are up
     1 − e^(−deaths/s × duration) of the time (`calcLib.approxUptime`). Like the Archon buff, only their own bonuses are averaged: a flag can't
     be scaled, so "while you have Onslaught" lines count only when the *Minion died recently* option makes it certain. "Recover N% of maximum
     Life when one of your Minions is Revived": n persistent Minions each die at d = deaths/s / n and need the revival time T (7.5 s, shortened by
     "Minions Revive faster", or the main skill's own base revival time) before they can die again, so they are revived n × d / (1 + d × T) times per second
     (`calcLib.approxRateWhileUnaffected`); *On Minion Revival (approx.)* in the Life section. Both are known before offence, so they don't use
     the second pass.
   - **Not modelled** (PoB has no model of what kills or heals Minions, Totems and Offerings, and assumes enabled skills are up): "Offerings
     cannot be damaged if they have been created Recently" and Offering life, chances to revive Minions (on a Command skill, on kill, when an
     Offering expires; the only effect of a revival in PoB is the recovery above), Minion and Companion recovery (Life Flask and leech sharing,
     "cannot Die while affected by a Life Flask"), Totem life, regeneration, recoup and death rules, Totems only using Skills when you fire an
     Attack Projectile, Volatility and Runic Ward on Minion death (Volatility isn't modelled), Gruelling Madness, Melee Splash, Rage on Hit of
     Companions, Onslaught on hitting Marked targets (needs the Minions' Hit rate), Low Runic Ward (no condition for it).
   - Census: 1,028 → 994; Minions, companions, totems 59 → 25.

For each mechanic:
- Write the rule down with its source (patch note, help text or wiki test), in a comment next to
  the code.
- Add a configuration option where the state isn't known (e.g. "Archon is active").
- Add a spec with a hand-calculated result.

### Phase 4: Approximation model

Build this once Phase 3's state flags exist, because it supplies them with rates. See the next
section.

Progress:
- **Second pass** (November 2026, `calcs.perform` in `CalcPerform.lua`): estimates that need the main skill's rates, known only after
  its offence calculation, used to be report-only. Now the first pass marks that it has one (`output.ApproxFeedsSecondPass`); the
  environment is restored to a snapshot taken before the first pass (`calcs.snapshotEnv`: the environment, its actors, modifier
  databases, items and skills, one level deep, in place, so every caller and the optimizer get it), and a second pass feeds the
  first pass's estimates in before offence (`output.ApproxSecondPass`):
  - average Elemental Infusions → `Multiplier:<Element>Infusion` for counts left empty;
  - charges from hits, critical hits and uses → the charge count (charges per use for a consuming main skill), the charges consumed
    Recently → their multiplier; Nebuloch's crit share → crit chance, share × 100% + (1 − share) × the attack's own chance;
  - Archon sources with a known event rate wait for it after the recovery period: uptime = duration / (duration + recovery +
    1 / rate). Arbiter's Ignition (`gain_archon_elemental_when_you_ignite_enemy_chance_%`, now mapped) has rate = chance × the main
    skill's Ignites per second; "after spending 100% of your maximum mana" has rate = mana spent per second / maximum mana. Sources
    without a rate in PoB (Energy Shield Recharge, High Infernal Flame, Command skills, Offerings, Overgrown plants) keep the
    immediate assumption.
  - Configured values win, as before; the breakdowns of fed values say "from the first pass's rates, used in the second pass".
  - Ceiling: one extra pass, not a fixed point (the second pass's rates would move the estimates again). Cost: approximations off
    is one pass, bit-identical, without a snapshot; on, the snapshot costs about a fifth of a pass (3.4 ms against 2.8 ms per
    evaluation on the Lightning Arrow test build), and a build that needs the second pass takes about 1.6× (4.5 ms).
  - A first version re-initialised the environment with an accelerated `initEnv` instead; that drops what `initEnv` writes
    straight into the modifier database in the skipped steps (item Spirit, charm slots, The Adorned multipliers, group properties,
    Hollow Palm, node counts from the optimizer's added nodes). `calcFullDPS` used to reuse an environment between skills that
    way, so the Full DPS of the second and later skills of one weapon set missed those values (item Spirit, for one). Fixed:
    it takes a `calcs.snapshotEnv` of the environment before each skill and restores it before the next one of the same weapon
    set (paired weapon-set environments and a change of set still get a full `initEnv`). A snapshot restores once, hence one
    per skill; TestFullDPSCache checks every skill's Full DPS against its own main calculation, with item Spirit.
  - Still report-only: the infused share of casts (no infused skill variants), Ignite / Shock spread pack values (by design).

### Phase 5: Exporter extensions (as needed)

When a mechanic needs a value that isn't exported (buff durations and limits, monster scaling,
infusion numbers):
- find the table with dat-schema or poe-dat-viewer,
- add it to `src/Export/spec.lua` and an export script, and
- regenerate `src/Data`.

Done: Archon Buff templates (duration and own stats) in `data.archonBuffs`, written by `Export/Scripts/miscdata.lua`
to `src/Data/Misc.lua`. The infusion constants (BaseMaximumInfusionCount, BaseInfusionDurationMs,
InfusionRemnantBaseDuration) were already in `data.gameConstants`.

### Phase 6: Measurement in the game (ongoing)

- Check Phase 3 mechanics and calibrate Phase 4 defaults against the game, as described under
  [Validation](#validation).

### Optimizer and performance follow-ups

- **Search variance:** with more mechanics the optimizer's greedy search sometimes ends in a clearly
  weaker build (Stormweaver Comet 47.6M → 35.6M, Infernalist Comet 74.2M → 64.9M, although the
  earlier builds still calculate the same). Done: a round that makes the build worse is undone
  (the best build after each round is kept), and `--restarts n` / *Restarts* runs the whole search
  n times, each time with another order (the tree before the equipment on every second run) and
  tree exponents scaled by 1 - 0.05 per run, and keeps the best; the run time grows with n.
  Still open: seeding the search from a known good build, and making ties in the search
  deterministic (reruns of one setup differ because some steps iterate tables in memory order).
- **Speed:** one evaluation takes about 2–4 ms of branchy Lua over modifier tables; a GPU port would
  mean a second engine and isn't worth it. In order: (1) profile an optimizer run to find the hot
  paths (likely modifier lookups and environment setup), (2) recalculate only what a candidate
  changes, (3) screen candidates with a fast stand-in model of stat totals (vectorisable, NumPy is
  enough) and verify the best few with the full calculation, (4) more parallel workers per run.
- **Recovery in the survivability score:** effective HP is a hit pool; regeneration, leech and
  recovery on kill still don't count.

## The approximation model

For effects that depend on events, PoB calculates an **expected value** from a few
playstyle assumptions, instead of ignoring the effect or assuming it's always on.

**Inputs.** New configuration options with sensible defaults per scenario (boss / mapping):

- hits per second: from the calculation itself
- kills per second: a scenario default, editable
- enemies in Presence / nearby: a scenario default
- dodge rolls, skill uses and damage taken per second: from the calculation or a default

**Rules.** One small set of shared functions, not one approximation per modifier:

| Effect type | Expected value |
|---|---|
| Buff for D seconds with chance p per event, event rate r | uptime = 1 − e^(−p·r·D) |
| Stacking buff, max N stacks, each lasting D | average stacks ≈ min(N, p·r·D) |
| "Every T seconds, gain X" | rate 1/T. With a duration D: uptime min(1, D/T) |
| "Recover X on kill / on event" | X · p · r per second, added to recovery |
| Charge gain p per event, decay D, max N | average charges ≈ min(N, p·r·D) |
| Cooldown-limited trigger | rate = min(event rate · p, 1 / cooldown) |

**Visibility.**
- Approximations are **off by default**. They're turned on with the *Approx* button in the sidebar
  or *Use approximations* in the Configuration tab, and both stay in sync.
- Each approximated modifier gets a flag. The calcs breakdown shows these values as
  approximations ("≈").
- A configuration switch turns all approximations off, so you can compare exact and approximate
  results.
- The optimizer reports how much of a build's score comes from approximations. A build that
  depends on them shows that in its summary.

**Calibration.** The defaults for kills and enemies per second are guesses at first. Phase 6
measurements replace them. Mark them in the code with a `ponytail:` comment naming the
assumption, so they can be upgraded later.

## Validation

- **Specs.** Every parser pattern and every mechanic gets a spec with a hand-calculated result.
  The full suite runs before every commit.
- **Census.** The Phase 0 numbers are recorded per phase in this document. They may only go down.
- **Cross-checks.** Gem values per level and modifier tiers are spot-checked against poe2db after
  every export.
- **Measurement in the game** (Phase 6, ongoing):
  - Compare a few reference builds' sheet values and damage on a target dummy against PoB.
  - Measure uptime and recovery for the approximation defaults.
  - Record each test with build code, game version and result.
- **Optimizer regression.** Re-run the [optimizer batch](buildOptimizerRuns.md) after each phase.
  Large ranking changes must come from intended mechanics, not bugs.

## Open questions

- Which game version is `src/Data` exported from, and does the exporter run on the current patch
  without schema changes? Check this before Phase 2.
- Defences (Guard, block, recovery) only help once the optimizer scores survivability as well as
  damage. That's a separate optimizer feature.
- Can poe2wiki's Cargo data be used (license and access)? Ask the wiki before building on it.
