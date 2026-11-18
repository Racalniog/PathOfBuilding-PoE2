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
- Next: rank the lines by impact:
  - how often they appear in optimizer results (the *Strong options the engine could not fully
    evaluate* list in each summary), and
  - their best "readable part" value from `optimizer.BlindSpotReport`.
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
    average stacks; the estimate is report-only for now.
  - **Known limits:** Siphon Elements counts as a buff on you (as in the game). Archon of Undeath's Command
    cooldown has no effect yet (no Command skill condition). With several Archon sources the first one is
    used. Whether increased Archon effect scales the conversion is untested.
  - Census: 1,170 → about 1,126.

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
       it). The estimate is reported in the calcs tab but doesn't feed the multipliers yet, because the rates come
       from the offence calculation.
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
       Nebuloch an attack main skill spends one Endurance Charge per crit: the share of attacks that crit ≈ min(1, gain rate / attack rate),
       report-only (the exact 100% applies only to a configured count).
     - The kill-based part feeds the charge count, before offence, for charge types the main skill doesn't consume. Hits, critical hits and
       uses are only known after offence, so the full estimate is report-only (Calcs tab, Charges: *Estimate (approx.)*, *Consumed Recently*).
       Per-charge modifiers count whole charges (multipliers are floored), so a fractional average counts its integer part.
     - Not modelled: charges on Stun, Block, Heavy Stun, Low Life or maximum Rage and from charm use (no event rate), recovery per consumed
       charge (Phase 3 item 3), Elemental / Chaotic Surge triggers, charge sharing with allies.
     - Census: 1,126 → 1,076; Charges 105 → 55 (the rest are mostly flask, charm and Energy Shield Recharge lines the group's word match catches).
3. **Recovery on events**: on kill, in Presence, leech variants (151 lines). Started early, as the
   first user of the approximation model: on-kill recovery uses the kills-per-second rate.
4. **Ailments**: spread, magnitude and duration interactions (102 lines).
5. **Guard, block, stun and parry** (60 lines). Moved forward with the defence work. The optimizer
   doesn't score defence yet, which needs a survivability score as well as damage.
6. **Thorns, ground surfaces, shapeshifting, Presence effects.**

For each mechanic:
- Write the rule down with its source (patch note, help text or wiki test), in a comment next to
  the code.
- Add a configuration option where the state isn't known (e.g. "Archon is active").
- Add a spec with a hand-calculated result.

### Phase 4: Approximation model

Build this once Phase 3's state flags exist, because it supplies them with rates. See the next
section.

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
