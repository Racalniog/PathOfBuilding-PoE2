# Build Optimizer

`src/Modules/BuildOptimizer.lua` builds a character around one skill gem and searches for the setup
with the highest damage. For a chosen class, ascendancy and skill it decides:

* the support gems linked to the skill,
* the auras, curses, marks and other skills whose buff or debuff raises the damage of the main skill,
* the equipment, once using crafted rares only and once with unique items allowed,
* the passive tree, including ascendancy nodes and jewel sockets,
* the jewels in the allocated sockets, and the runes / soul cores in item sockets,
* flasks and charms, where they add damage.

Every candidate is scored by the normal calculation engine (`calcs.initEnv` + `calcs.perform`), so
the number the optimizer reports is the number the program shows when the saved build is opened.

## Running it

The optimizer runs headless through `src/OptimizeBuild.lua`. From the `src` directory:

    luajit OptimizeBuild.lua --class Ranger --ascendancy Deadeye --skill "Lightning Arrow" --out ../builds

On Windows no Lua installation is needed; `OptimizeBuild.py` runs the same script in the LuaJIT
that ships in `runtime/`, and additionally writes an import code for every saved build:

    python OptimizeBuild.py --class Ranger --ascendancy Deadeye --skill "Lightning Arrow" --out ../builds

Two builds are produced, `<name> (rares).xml` and `<name> (uniques).xml`, each with a `.txt`
summary. Copy the `.xml` into the build folder, or paste the contents of the `.code.txt` into
*Import/Export Build -> Import from website or code*.

Useful options (`--help` lists all of them):

| Option | Meaning |
| --- | --- |
| `--ascendancy <name>` | Omit it to let the optimizer compare the ascendancies of the class |
| `--level <n>`, `--points <n>` | Character level and passive point budget |
| `--roll <0..1>` | Affix and unique roll quality; `1` is a perfect roll, `0.5` an average one |
| `--item-level <n>` | Highest affix tier that may be crafted |
| `--no-lineage`, `--no-runes` | Leave out lineage supports / socketed runes |
| `--no-aux`, `--no-flasks` | Leave out supporting skills / flasks and charms |
| `--no-combos` | Skip the search for combinations whose parts do nothing alone |
| `--thorough` | Try every unique as one half of a unique pair (adds several minutes) |
| `--config key=value` | Any Configuration tab input, e.g. `--config enemyIsBoss=Pinnacle` |
| `--metric <stat>` | Calc output to maximise, `CombinedDPS` by default |
| `--rounds <n>` | Passes over the whole pipeline per variant |

A full run takes roughly eight minutes (about 200,000 calculations).

From Lua the two entry points are:

```lua
local optimizer = LoadModule("Modules/BuildOptimizer")
optimizer.SetupCharacter(build, { class = "Ranger", ascendancy = "Deadeye", skill = "Lightning Arrow", level = 100 })
local result = optimizer.Optimize(build, { allowUniques = false })   -- options: optimizer.defaultOptions
print(result.score, optimizer.Describe(build))
```

`Optimize` works on the build in place and only ever accepts changes that raise the score, so it can
be called again on its own result (this is how the unique variant is derived from the rare one).

## How the search works

The space of builds is far too large to enumerate, and the stats interact (more/increased/added
damage, crit chance vs. crit damage, conversion), so the optimizer runs a sequence of greedy and
local-search passes, each scored exactly, and repeats the sequence so that earlier choices can react
to later ones:

1. **Weapon bootstrap** - attacks deal no damage unarmed, so a weapon is found first if needed.
2. **Support gems** - the links are filled greedily with the support that adds the most, then every
   link is swapped for a better one until nothing improves. Because a greedy fill can lock itself in
   (a support that is only good alone, or only in combination), the fill is restarted from the
   best few single supports and the best final set of links is kept. Supports of the same family are
   never combined.
3. **Supporting skills** - every skill gem with an effect beyond its own damage (persistent buffs,
   curses, marks, ...) is tried as an extra skill, and the one that adds the most is kept, until
   nothing helps or the skill slots are full. Each of them then gets the supports that raise the
   score, such as more curse effect. The engine applies the curse limit; one mark at most is
   allowed. A build that reserves more Spirit than it has scores as invalid everywhere, and a buff
   that only fails on Spirit gets one chance: the body armour or amulet is crafted again with the
   buff in place, which makes a Spirit affix worth its slot.
4. **Equipment** - for every slot the usable bases are ranked by evaluating them bare; the best base
   of each promising item type is then crafted. Crafting adds, one at a time, the highest eligible
   tier of whichever affix raises the score the most, respecting prefix/suffix limits, modifier
   groups and spawn weights, the same rules the "Craft item" dialog uses. Sockets are filled with the
   best runes. Main hand and off hand are searched as pairs so that a two-hander competes fairly
   with a one-hander plus quiver, focus, shield or second weapon. With uniques allowed, every unique
   that fits the slot competes with the crafted rare. Flask and charm slots are switched on and get
   the magic or unique item that adds the most; slots where nothing helps stay empty.
5. **Passive tree** - ascendancy points first, then the main tree. Each step values every reachable
   node on its own, estimates from that the value per point of whole paths and of whole clusters
   (all useful nodes of a group plus the travel to reach them), verifies the most promising
   candidates with a real calculation and allocates the best. Jewel sockets hold a jewel crafted for
   the build while this runs, so a socket is worth what can be put into it. Afterwards a local
   search repeatedly gives back the least valuable branch and lets the allocation spend the points
   again, keeping the result only when the build improves.
6. **Jewels** - every allocated socket gets its own jewel crafted in place, which is what lets
   Time-Lost jewels be judged by the passives actually in their radius.
7. **Attributes** - the allocated attribute nodes are set to meet the requirements of gems and gear,
   and otherwise to whichever attribute scores best.

### Combinations whose parts do nothing alone

A greedy search only ever adds things that help immediately, so it is blind to two modifiers that
are each worthless without the other. Testing all pairs is far too slow, so the optimizer uses
group testing: everything that did nothing on its own is applied at once. If the build doesn't
move, no combination among those things matters and one calculation has ruled them all out. If it
does move, the group is cut down by repeated halving to the few members that are responsible, and
those are offered to the search as a single candidate. This is done for

* support gems (on an empty skill, and on top of the best links found),
* affixes on every crafted item and jewel (after first re-testing each idle affix next to the ones
  already chosen),
* passive nodes, at every step of the tree allocation, including the ascendancy.

Uniques can't be applied all at once, so pairs of uniques are searched directly: for the leading
rejected uniques of every slot (`--thorough`: every unique), the unique is put on and every unique in
every other slot is tried next to it.

The pipeline is repeated, which is what connects the stages: a support that only pays off with a
certain affix, or a passive that needs a unique, is picked up in the next round as long as one side
of the pair is worth something by itself.

## What the optimizer does not know

There are no hard-coded build recipes. A unique interaction or skill setup is found if, and only
if, the calculation engine models it and its effect shows up in the optimised stat. In practice:

* Mechanics marked "Not supported in PoB yet" are worth nothing to the search.
* Conditional effects count only if their condition is on in the Configuration tab.
* Setups that depend on how a skill is played (combos, detonating one skill with another, charges
  generated by a second skill) are not modelled beyond what the engine assumes by default.

## Limitations

* The result is a strong build, not a proven optimum. Combinations are found within one kind of
  choice (supports, affixes of one item, passives, pairs of uniques). A combination of two things
  of different kinds that are both worthless alone, or of three or more uniques, can still be missed,
  as can a keystone that hurts on its own and only pays off after the build is changed around it.
* Only damage is optimised. Slots that can't add damage are left as an item base without
  modifiers, and life, resistances and other defences are ignored; treat those slots as free room
  for defensive stats.
* Damage depends on the Configuration tab (enemy type, charges, conditions such as "enemy is
  shocked"). The defaults of a new build are used unless `--config` says otherwise.
* Buffs, curses, marks, flasks and charms are counted as permanently active, the way the engine
  treats an enabled skill or flask. Skills that are counted for a short-lived effect (for example a
  buff that applies to the next attack) make the number an upper bound rather than a sustained
  figure; use `--no-aux` to see the build without them.
* Crafted items are "best case" items: any combination of top-tier affixes at the chosen roll
  quality. Lower `--roll` and `--item-level` for something closer to what can be bought.
* Item choice doesn't take attribute requirements into account. They are met afterwards with
  attribute nodes where possible, and the summary flags any requirement that is left unmet.
* Weapon-set passive points and a second weapon set are not part of the search.

## Ideas for going further

* **Defensive constraints** - require minimum life, resistances or effective hit pool, and spend the
  affix slots the damage search leaves empty on them.
* **Wider tree search** - the allocation is greedy with a prune-and-regrow polish. A beam search or
  simulated annealing over the allocation, or solving the "connect these notables as cheaply as
  possible" sub-problem exactly (a Steiner tree), would find trees the greedy path misses, at the
  cost of run time.
* **Negative-first choices** - try keystones and uniques that lower the score on their own by
  re-running the following stages with them forced in.
* **Cross-kind combinations** - extend the group test across kinds, e.g. idle supports together with
  idle passives.
* **Configuration awareness** - search over conditions the player can realistically maintain, and
  report how much each assumed condition contributes.
* **Parallel runs** - calculations are independent, so candidate evaluation could be spread over
  several processes; restarts with different first choices could then be explored in parallel.
* **Weapon sets** - use the weapon-set passive points and a second weapon set.
