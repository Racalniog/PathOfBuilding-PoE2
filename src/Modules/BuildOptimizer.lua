-- Path of Building
--
-- Module: Build Optimizer
-- Searches for a build that maximises the damage of one skill gem for a given class/ascendancy.
-- It picks the support gems for the skill, crafts rare equipment (optionally competing against
-- the unique item database), allocates the passive tree (including ascendancy and jewel sockets)
-- and crafts the jewels for the allocated sockets.
--
-- Everything is scored with the regular calculation engine, so the result is exactly what the
-- program would show for the same build. The search itself is a sequence of greedy/local-search
-- passes; it finds a strong build, not a provably optimal one. See docs/buildOptimizer.md.
--
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort
local t_concat = table.concat
local m_max = math.max
local m_min = math.min
local m_floor = math.floor
local m_huge = math.huge
local s_format = string.format

local optimizer = { }

optimizer.defaultOptions = {
	-- Output stat to maximise. A string (field of the calc output; the minion's value of the same
	-- field is added when present) or a function(output) returning a number
	metric = "CombinedDPS",
	-- Weight w (0..1) of survivability, PoB's effective hit pool (output.TotalEHP), in the score:
	-- score = metric ^ (1 - w) * TotalEHP ^ w. 0 = damage only, 0.5 weighs both alike
	survivability = 0,
	-- Seconds of recovery that count towards the survivability part of the score: the hit pool is
	-- scaled by (1 + recovery per second x seconds / pool), see optimizer.Survivability. 0 = the hit
	-- pool alone (regeneration, leech and recoup then count for nothing). Only used when survivability > 0
	recoveryHorizon = 0,
	-- Switch on the Configuration tab's approximations in the build (recovery on kill from a kill
	-- rate, ...) with this many kills per second
	approximations = false,
	killsPerSecond = 1,
	level = 100,
	-- Passive points to spend; nil = (level - 1) + quest points available at that level
	points = nil,
	ascendancyPoints = 8,
	maxSupports = 5,
	-- Number of different first supports the support gem search is started from
	supportStarts = 4,
	-- Allow lineage support gems
	lineage = true,
	gemQuality = 20,
	-- Roll quality of crafted affixes and unique modifier ranges: 0 = minimum, 1 = perfect
	affixRoll = 1,
	-- Highest modifier tier level that may be crafted
	itemLevel = 82,
	-- Fill item sockets with the best runes / soul cores
	runes = true,
	-- Add auras, curses, marks and other skills whose effect raises the damage of the main skill
	auxSkills = true,
	-- Skill gems the character can have in total (the main skill included)
	maxSkills = 9,
	-- Spells the optimiser sockets into a meta skill (Cast on Critical, ...); more are added while the group's Full DPS rises
	-- ponytail: the game's number of Spell sockets of a meta gem isn't in the data; upgrade path = that number
	maxMetaSpells = 3,
	-- Equip flasks and charms where they add damage (they are assumed to be active)
	flasks = true,
	-- Use the second weapon set: supporting skills that gain from it are cast with their own
	-- weapons and weapon-set passives, the main skill keeps the first set
	weaponSets = true,
	-- Look for combinations whose parts do nothing on their own (supports, affixes, passives, uniques)
	combos = true,
	-- Number of rejected uniques per slot that are tried as one half of a unique pair
	uniquePairAnchors = 4,
	-- Check every unique as one half of a pair instead (slow)
	thorough = false,
	-- Also try legacy uniques: older versions of a unique ("Pre 0.4.0") and uniques that are no
	-- longer obtainable. Off by default, the search only uses what can be found in the game now
	legacyUniques = false,
	-- Also try every current alternative of uniques that come in several versions (Cursecarver's
	-- curse, Darkness Enthroned's slot, the keystone of From Nothing, ...). Off by default, only the
	-- version the unique database selects is tried; on, the unique search takes noticeably longer
	uniqueVariants = false,
	-- Radius used when crafting Time-Lost jewels
	jewelRadius = "Small",
	-- Number of distinct weapon base types that are fully crafted and compared
	baseCandidates = 3,
	-- Number of main hand candidates for which a matching off hand is searched
	weaponCombos = 3,
	-- Number of tree candidates that are verified with a full calculation each step
	treeVerify = 10,
	-- Number of failed prune-and-regrow attempts before the tree refinement stops
	treeRefineFails = 6,
	-- The tree is built several times with a different appetite for long travel, and the best
	-- result is kept. A candidate is ranked by gain / cost ^ exponent: 1 is plain value per point,
	-- lower exponents accept more travel to reach a strong cluster. The first treeWidth entries are used
	treeExponents = { 1, 0.75, 0.85, 0.65 },
	treeWidth = 4,
	-- function(job) starting a worker process for one tree variant and returning an object with a
	-- wait() method that returns { score =, nodes = }; nil = build every variant in this process
	spawnWorker = nil,
	-- Number of worker processes that may run at the same time
	workers = 0,
	-- Full passes over supports -> equipment -> tree -> jewels
	rounds = 2,
	-- Times the whole search is run from the starting build, the best result is kept. 1 = once.
	-- Run i (0 = the first, which is the plain search) builds the tree before the equipment when i is
	-- odd and scales the tree exponents by 1 - 0.05 * i: a different, deterministic path to another
	-- local optimum. ponytail: a build that already has a tree (the unique stage after the rare one)
	-- only gets the changed order; upgrade path = perturb the equipment choices too
	restarts = 1,
	-- Score a skill that shows average damage instead of DPS by damage per second (average x use rate) instead of its average damage per use
	perSecond = false,
	-- Relative improvement below which a change is not considered worth it
	epsilon = 1e-6,
	-- Configuration tab conditions to switch on because the build keeps them up by itself:
	-- "none", "sustained" (see optimizer.sustainedConditions) or a list of option names
	assume = "none",
	-- function(text) used to report progress
	log = nil,
}

local gearSlots = { "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Ring 3", "Belt" }
local attributeNames = { "Str", "Dex", "Int" }

-----------------------------------------------------------------------------------------------
-- Scoring
-----------------------------------------------------------------------------------------------

local function log(ctx, fmt, ...)
	if ctx.opts.log then
		ctx.opts.log(s_format(fmt, ...))
	end
end

-- The base modifier databases (class stats, level, Configuration and Party tab mods) only change
-- with those inputs, so they are built once and reused for every evaluation until one changes.
-- The tables of the config mod lists are replaced on every rebuild, which makes them a cheap key
local function baseSignature(build)
	return table.concat({ tostring(build.configTab.modList), tostring(build.configTab.enemyModList),
		tostring(build.partyTab and build.partyTab.enemyModList), tostring(build.characterLevel), tostring(build.spec.curClassId) }, "|")
end

-- Spells that follow a meta skill (Cast on Block, Cast on Critical, ...) in its group: the group is the meta skill, its Spells, then the
-- supports. The meta skill triggers the Spells, and they deal the damage. Returns how many Spells the group has (0 for a group that
-- isn't a meta skill's, or a meta skill without a Spell yet)
local function metaSpellCount(group)
	local meta = group.displaySkillList and group.displaySkillList[1]
	local count = 0
	if meta and meta.activeEffect.grantedEffect.skillTypes[SkillType.Meta] then
		while true do
			local spell = group.gemList[count + 2] and group.gemList[count + 2].gemData
			if not spell or spell.grantedEffect.support then
				break
			end
			count = count + 1
		end
	end
	return count
end

-- The engine calculates the main skill of the selected socket group only. A meta skill's group with several Spells has each of them
-- as its own skill (all triggered at the group's rate, which falls with every Spell: the Energy they need is summed), so its damage is
-- the program's Full DPS of the group (the group has "Include in Full DPS" on, which the optimiser only sets for a group with several
-- Spells), added to the output as FullDPS and scored instead of CombinedDPS (scoreOutput)
local function addGroupTotal(ctx, override, output)
	local group = ctx.group
	if group.includeInFullDPS and metaSpellCount(group) > 0 then
		local base = ctx.baseDB
		output.FullDPS = ctx.calcs.calcFullDPS(ctx.build, "CALCULATOR", override, { cachedPlayerDB = base.player, cachedEnemyDB = base.enemy, cachedMinionDB = base.minion }).combinedDPS
	end
end

local function calcOutput(ctx, override)
	local build = ctx.build
	local signature = baseSignature(build)
	local base = ctx.baseDB
	if base and base.signature == signature then
		local cachedDBs = { cachedPlayerDB = base.player, cachedEnemyDB = base.enemy, cachedMinionDB = base.minion }
		local env = ctx.calcs.initEnv(build, "CALCULATOR", override, cachedDBs)
		-- A minion that appeared after the cache was built has no base database; rebuild it then
		if not (env.minion and not base.minion) then
			-- for skills calculated in their own environment during perform (calcs.buildActiveSkill: Thorns hits, buff rates)
			env.override, env.cachedDBs = override, cachedDBs
			ctx.calcs.perform(env, ctx.skipEHP)
			addGroupTotal(ctx, override, env.player.output)
			return env.player.output, env
		end
	end
	local env, player, enemy, minion = ctx.calcs.initEnv(build, "CALCULATOR", override)
	ctx.baseDB = { signature = signature, player = player, enemy = enemy, minion = minion }
	env.override = override
	ctx.calcs.perform(env, ctx.skipEHP)
	addGroupTotal(ctx, override, env.player.output)
	return env.player.output, env
end

-- The engine reports the damage of a single minion; how many there are is the "Count" of the gem,
-- which only decides how much Spirit is reserved. For minions that reserve Spirit per minion this
-- returns the number the character can field with the Spirit that is left after everything else,
-- so that the score is the damage of the whole army and Spirit is worth what it buys.
-- Returns nil for skills where the count isn't a matter of Spirit
local function minionCount(ctx, output, env)
	local skill = env and env.player and env.player.mainSkill
	if not skill or not skill.minion or not skill.skillTypes or not skill.skillTypes[SkillType.MultipleReservation] then
		return nil
	end
	local current = ctx.group.gemList[1].count or 1
	local free = skill.skillModList:Sum("BASE", skill.skillCfg, "MinionFreeSpiritCount")
	local reserved = skill.skillData.SpiritReservedBase or 0
	if current <= free or reserved <= 0 then
		-- Nothing is reserved at the current count, so the cost of one more minion is unknown
		return current, free
	end
	local available = (output.SpiritUnreserved or 0) + reserved
	if available < 0 then
		return 0, free
	end
	return free + m_floor(available / (reserved / (current - free)) + 1e-9), free
end

-- Life and Energy Shield recovered per second: regeneration and recovery (on kill with
-- approximations) net of degeneration, average recoup (the Comprehensive net figures already hold
-- recoup and degeneration from enemies when the engine calculated them) and leech / gain on hit.
-- Flask recovery is taken out: the engine counts a flask as a permanent rate, which would swamp
-- everything else (918 per second against 70 of regeneration in a Titan build)
-- ponytail: Energy Shield recharge, mana, runic ward and flasks are left out (recharge stops when
-- hit; a flask runs while its charges last); upgrade path = flask recovery x the uptime its charge
-- generation allows, EnergyShieldRecharge x a "not recently hit" share
local function recoveryRate(output, env)
	local life = output.ComprehensiveNetLifeRegen or ((output.NetLifeRegen or output.LifeRegenRecovery or 0) + (output.LifeRecoupRecoveryAvg or 0) - (output.LifeLossLostAvg or 0))
	local shield = output.ComprehensiveNetEnergyShieldRegen or ((output.NetEnergyShieldRegen or output.EnergyShieldRegenRecovery or 0) + (output.EnergyShieldRecoupRecoveryAvg or 0))
	local flasks = env and env.flasks
	if flasks and next(flasks) then
		-- The flask's recovery mods carry the flask's name as their source
		local names = { }
		for item in pairs(flasks) do
			names[item.name] = true
		end
		local modDB = env.player.modDB
		for _, resource in ipairs({ "Life", "EnergyShield" }) do
			local rate = 0
			for _, entry in ipairs(modDB:Tabulate("BASE", nil, resource .. "Recovery")) do
				if names[entry.mod.source] then
					rate = rate + entry.value
				end
			end
			rate = rate * (output[resource .. "RecoveryRateMod"] or 1)
			if resource == "Life" then
				life = life - rate
			else
				shield = shield - rate
			end
		end
	end
	return life + shield + (output.LifeLeechRate or 0) + (output.LifeOnHitRate or 0) + (output.EnergyShieldLeechRate or 0) + (output.EnergyShieldOnHitRate or 0)
end

-- The survivability of an output: its effective hit pool plus what the horizon's worth of recovery
-- adds, in the same unit. A point of Life or Energy Shield is worth TotalEHP / pool of hit pool, so
-- TotalEHP + rate x horizon x TotalEHP / pool = TotalEHP x (1 + x), x = rate x horizon / pool.
-- ponytail: x is saturated as x / (1 + |x|), so the factor is about 1 + x for small x, never more
-- than 2 (you can't usefully recover more than you lost) and never less than 0 (net degeneration
-- lowers it): without that a 1 Life build (Chaos Inoculation) with a life flask scored 3800 x its
-- hit pool. Upgrade path = simulate the damage taken per second instead
-- Returns the survivability and the recovery per second
function optimizer.Survivability(output, horizon, env)
	-- No (or a broken) hit pool counts as 1, which leaves the damage part alone
	-- ponytail: a hit pool the engine thinks is endless is capped at 1e12, so such builds rank highest instead of scoring 0
	local ehp = m_min(tonumber(output.TotalEHP) or 1, 1e12)
	ehp = ehp >= 1 and ehp or 1
	if not (horizon > 0) then
		return ehp, 0
	end
	local rate = recoveryRate(output, env)
	local pool = m_max((output.LifeRecoverable or output.Life or 0) + (output.EnergyShieldRecoveryCap or output.EnergyShield or 0), 1)
	local x = rate * horizon / pool
	local survivability = ehp * (1 + x / (1 + math.abs(x)))
	return survivability >= 1 and survivability or 1, rate
end

local function scoreOutput(ctx, output, env)
	local minions = ctx.group.gemList[1].count or 1
	if not ctx.ignoreSpirit then
		local count = minionCount(ctx, output, env)
		if count then
			-- The army is sized to the Spirit that is left, so Spirit can't be overspent by it
			if count < 1 then
				return -1
			end
			minions = count
		elseif (output.SpiritUnreserved or 0) < 0 then
			-- A build that reserves more Spirit than it has is not a build
			return -1
		end
	end
	local metric = ctx.opts.metric
	local value
	if type(metric) == "function" then
		value = metric(output, minions)
	else
		value = output[metric] or 0
		if metric == "CombinedDPS" and output.FullDPS then
			value = output.FullDPS -- (a meta skill's group with several Spells, see addGroupTotal)
		end
		-- A skill that shows average damage instead of DPS (Comet, Firestorm, Volatile Dead, ...: 58 gem skills) has its average damage per use
		-- as Combined DPS. perSecond scores it per second instead: x the rate (Speed: cast rate, cooldown or trigger rate)
		local skillData = env and env.player and env.player.mainSkill and env.player.mainSkill.skillData
		if ctx.opts.perSecond and skillData and skillData.showAverage and (output.AverageDamage or 0) > 0 and output.TotalDPS then
			value = value * output.TotalDPS / output.AverageDamage
		end
		if output.Minion and type(output.Minion[metric]) == "number" then
			value = value + output.Minion[metric] * minions
		end
	end
	local weight = ctx.opts.survivability
	if weight > 0 and type(value) == "number" and value > 0 then
		value = value ^ (1 - weight) * (optimizer.Survivability(output, ctx.opts.recoveryHorizon, env)) ^ weight
	end
	if type(value) ~= "number" or value ~= value or value == m_huge or value == -m_huge then
		return 0
	end
	return value
end

-- Score the build as it currently is, with an optional calculation override applied
-- The skill's source (ctx.opts.pin: the item in its slot, or the node) is frozen for the whole search. A calculation with an override
-- keeps the main skill's group as it is, so a candidate that replaces or removes the source would be scored as if the skill were still
-- there: it is rejected here (score 0) instead. A main hand that can't go with a pinned off hand counts as replacing it
local function pinVetoes(ctx, override)
	local pin = ctx.opts.pin
	if not (pin and override) then
		return false
	end
	local slotName, item = override.repSlotName, override.repItem
	if pin.slotName and slotName then
		if slotName == pin.slotName then
			local slot = ctx.build.itemsTab.slots[slotName]
			return item ~= (slot and ctx.build.itemsTab.items[slot.selItemId])
		elseif pin.slotName == "Weapon 2" and slotName == "Weapon 1" and item and item.base then
			return not (ctx.build.data.weaponTypeInfo[item.base.type] or { }).oneHand
		end
	end
	if pin.nodeId and override.removeNodes then
		for node in pairs(override.removeNodes) do
			if type(node) == "table" and node.id == pin.nodeId then
				return true
			end
		end
	end
	return false
end

local function eval(ctx, override)
	ctx.evals = ctx.evals + 1
	ctx.lastOutput = nil
	if pinVetoes(ctx, override) then
		return 0
	end
	local ok, output, env = pcall(calcOutput, ctx, override)
	if not ok then
		ctx.errors = ctx.errors + 1
		ctx.lastError = output
		return -1
	end
	ctx.lastOutput = output -- (for callers that look at more than the score)
	return scoreOutput(ctx, output, env)
end

local function better(ctx, new, old)
	return new > old + math.abs(old) * ctx.opts.epsilon and new > old
end

-- Reduce a list to a small sub-list for which keeps(list) still holds (delta debugging). Used to
-- pin down which members of a large group are responsible for an effect the group has as a whole.
-- With a budget, returns nil once keeps() has been called that many times
local function shrink(items, keeps, budget)
	local parts = 2
	while #items >= 2 do
		local chunk = math.ceil(#items / parts)
		local reduced = false
		for start = 1, #items, chunk do
			local rest = { }
			for index, entry in ipairs(items) do
				if index < start or index >= start + chunk then
					t_insert(rest, entry)
				end
			end
			if budget then
				budget = budget - 1
				if budget < 0 then
					return nil
				end
			end
			if #rest > 0 and keeps(rest) then
				items = rest
				parts = m_max(parts - 1, 2)
				reduced = true
				break
			end
		end
		if not reduced then
			if parts >= #items then
				break
			end
			parts = m_min(#items, parts * 2)
		end
	end
	return items
end

-- Push pending changes through the regular build update so derived state (sockets, slot validity,
-- granted passives, main output) is consistent again
local function sync(ctx)
	for index, group in ipairs(ctx.build.skillsTab.socketGroupList) do
		if group == ctx.group then
			ctx.build.mainSocketGroup = index
			break
		end
	end
	-- Keep the minion gem's count at the number of minions the build can field right now
	local gemInstance = ctx.group.gemList[1]
	for _ = 1, 2 do
		local ok, output, env = pcall(calcOutput, ctx)
		local count, free = nil, nil
		if ok then
			count, free = minionCount(ctx, output, env)
		end
		if not count then
			break
		end
		if (gemInstance.count or 1) <= free then
			-- Probe with one paid minion to learn what a minion costs
			gemInstance.count = free + 1
		else
			if count >= 1 then
				gemInstance.count = count
			end
			break
		end
	end
	ctx.build.buildFlag = true
	if runCallback then
		runCallback("OnFrame")
	end
end

-----------------------------------------------------------------------------------------------
-- Character and skill setup
-----------------------------------------------------------------------------------------------

local function findByName(list, name)
	name = name:lower()
	for id, entry in pairs(list) do
		if entry.name and entry.name:lower() == name then
			return id, entry
		end
	end
end

local function gemLevelForCharacter(gemData, characterLevel, wanted)
	local levels = gemData.grantedEffect.levels
	local level = m_min(wanted or gemData.naturalMaxLevel or 1, #levels > 0 and #levels or 1)
	while level > 1 and levels[level] and (levels[level].levelRequirement or 0) > characterLevel do
		level = level - 1
	end
	return level
end

local function makeGemInstance(ctx, gemData, level)
	return {
		level = gemLevelForCharacter(gemData, ctx.build.characterLevel, level),
		quality = ctx.opts.gemQuality,
		count = 1,
		enabled = true,
		enableGlobal1 = true,
		enableGlobal2 = true,
		gemId = gemData.id,
		nameSpec = gemData.name,
		skillId = gemData.grantedEffectId,
		gemData = gemData,
	}
end

-- Skills that don't come from a gem: granted by a unique item ("Grants Skill") or by a passive tree node. PoB makes a socket group
-- for each of them while the item is equipped / the node allocated, so the build needs that item or node for as long as the skill is
-- the main skill. The pin returned with the setup says which: { skillId, slotName = the item's slot | nodeId = the node }
local grantSlots = { "Weapon 1", "Weapon 2", "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Belt" }

-- Granted skills whose name is `wanted` (exact), else contains it. Returns a list of { skillId, name, item | node }
local function findGrantedSkills(build, wanted, source)
	local found, exact = { }, false
	local function consider(skillId, entry)
		local skill = build.data.skills[skillId]
		local name = skill and skill.name and skill.name:lower()
		if name and (name == wanted or (wanted ~= "" and name:find(wanted, 1, true))) then
			entry.skillId, entry.name = skillId, skill.name
			t_insert(found, entry)
			exact = exact or name == wanted
		end
	end
	if source ~= "tree" and main.uniqueDB and main.uniqueDB.list then
		local names = { }
		for name in pairs(main.uniqueDB.list) do
			t_insert(names, name)
		end
		t_sort(names)
		for _, name in ipairs(names) do
			-- (not the ones that can't be obtained any more, as in the unique search)
			local item = #optimizer.UniqueVariants(main.uniqueDB.list[name], { }) > 0 and new("Item"):Item(main.uniqueDB.list[name]:BuildRaw())
			for _, skill in ipairs(item and item.base and item.grantedSkills or { }) do
				consider(skill.skillId, { item = item })
			end
		end
	end
	if source ~= "item" then
		local ids = { }
		for id in pairs(build.spec.tree.nodes) do
			t_insert(ids, id)
		end
		t_sort(ids, function(a, b) return tostring(a) < tostring(b) end)
		for _, id in ipairs(ids) do
			local node = build.spec.tree.nodes[id]
			for _, mod in ipairs(node.modList or { }) do
				if mod.name == "ExtraSkill" and type(mod.value) == "table" and mod.value.skillId then
					consider(mod.value.skillId, { node = node })
				end
			end
		end
	end
	if exact then
		local list = { }
		for _, entry in ipairs(found) do
			if entry.name:lower() == wanted then
				t_insert(list, entry)
			end
		end
		found = list
	end
	return found
end

-- Make the main skill one that an item or a passive node grants: equip the item / allocate the node, let the program make the
-- skill's socket group and select it. Returns true and the pin, or nil and an error message
local function setupGrantedSkill(build, setup, wanted)
	local found = findGrantedSkills(build, wanted, setup.skillSource)
	local skillIds, names = { }, { }
	for _, entry in ipairs(found) do
		if not skillIds[entry.skillId] then
			skillIds[entry.skillId] = true
			t_insert(names, entry.name)
		end
	end
	if #found == 0 then
		return nil, "'" .. tostring(setup.skill) .. "' is not an active skill gem, and no unique or passive node grants it"
	elseif #names > 1 then
		t_sort(names)
		return nil, "Ambiguous skill '" .. tostring(setup.skill) .. "'. Granted skills matching: " .. t_concat(names, ", ")
	end
	local spec, itemsTab = build.spec, build.itemsTab
	local wantedAscendancy = (setup.ascendancy or ""):lower()
	local pin
	for _, entry in ipairs(found) do
		if entry.item then
			for _, slotName in ipairs(grantSlots) do
				local slot = itemsTab.slots[slotName]
				if slot and not itemsTab.items[slot.selItemId] and itemsTab:IsItemValidForSlot(entry.item, slotName) then
					entry.item.id = nil
					itemsTab:AddItem(entry.item, true)
					slot:SetSelItemId(entry.item.id)
					itemsTab:PopulateSlots()
					pin = { skillId = entry.skillId, slotName = slotName, itemName = entry.item.title or entry.item.name }
					break
				end
			end
		else
			local node = entry.node
			local fits = true
			if node.ascendancyName and spec.curAscendClassName ~= node.ascendancyName then
				-- (an ascendancy that was asked for stays)
				local ascendClassId = (wantedAscendancy == "" or wantedAscendancy == "auto") and findByName(spec.curClass.classes, node.ascendancyName)
				if ascendClassId and ascendClassId ~= 0 then
					spec:SelectAscendClass(ascendClassId)
				else
					fits = false
				end
			end
			node = fits and spec.nodes[node.id]
			if node and node.path then
				spec:AllocNode(node)
				pin = { skillId = entry.skillId, nodeId = node.id, itemName = node.dn }
			end
		end
		if pin then
			break
		end
	end
	if not pin then
		return nil, "No unique that grants '" .. tostring(setup.skill) .. "' fits an empty slot, and no node granting it can be allocated for this class and ascendancy"
	end
	build.buildFlag = true
	if runCallback then
		runCallback("OnFrame")
	end
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		local gem = group.gemList[1]
		if gem and gem.skillId == pin.skillId and (group.sourceItem or group.sourceNode) then
			build.mainSocketGroup = index
			-- (calculate again with that group as the main skill: an item may grant several skills)
			build.buildFlag = true
			if runCallback then
				runCallback("OnFrame")
			end
			return true, pin
		end
	end
	return nil, "The program made no skill group for " .. tostring(pin.itemName)
end

-- Configure class, ascendancy, level and the main skill on a (fresh) build.
-- setup = { class = "Ranger", ascendancy = "Deadeye" | nil, skill = "Lightning Arrow", level = 100, gemLevel = nil, config = { } }
-- A skill that no gem gives but a unique item or a passive node does is set up through that item / node (setupGrantedSkill);
-- setup.skillSource ("gem", "item", "tree") says where to look, nil tries gems first. Returns true (and the pin for such a
-- skill), or nil and an error message
function optimizer.SetupCharacter(build, setup)
	local spec = build.spec
	local classId, class = findByName(spec.tree.classes, setup.class or "")
	if not classId then
		local names = { }
		for _, c in pairs(spec.tree.classes) do
			t_insert(names, c.name)
		end
		t_sort(names)
		return nil, "Unknown class '" .. tostring(setup.class) .. "'. Available: " .. t_concat(names, ", ")
	end
	spec:SelectClass(classId)
	if setup.ascendancy and setup.ascendancy ~= "" and setup.ascendancy:lower() ~= "auto" then
		local ascendClassId = findByName(class.classes, setup.ascendancy)
		if not ascendClassId or ascendClassId == 0 then
			local names = { }
			for id, c in pairs(class.classes) do
				if id ~= 0 then
					t_insert(names, c.name)
				end
			end
			t_sort(names)
			return nil, "Unknown ascendancy '" .. setup.ascendancy .. "' for " .. class.name .. ". Available: " .. t_concat(names, ", ")
		end
		spec:SelectAscendClass(ascendClassId)
	end

	build.characterLevel = m_max(1, m_min(100, setup.level or optimizer.defaultOptions.level))
	build.characterLevelAutoMode = false
	if build.controls and build.controls.characterLevel then
		build.controls.characterLevel:SetText(build.characterLevel)
	end
	for key, value in pairs(setup.config or { }) do
		build.configTab.input[key] = value
	end
	build.configTab:BuildModList()

	local skillsTab = build.skillsTab
	-- Exact name first, then a unique partial match among the active skill gems
	local wanted = (setup.skill or ""):lower()
	if setup.skillSource and setup.skillSource ~= "gem" and setup.skillSource ~= "item" and setup.skillSource ~= "tree" then
		return nil, "--skill-source expects gem, item or tree, not '" .. tostring(setup.skillSource) .. "'"
	end
	if setup.skillSource == "item" or setup.skillSource == "tree" then
		return setupGrantedSkill(build, setup, wanted)
	end
	local gemData
	local partial = { }
	for _, candidate in pairs(build.data.gems) do
		local grantedEffect = candidate.grantedEffect
		if not grantedEffect.support and not grantedEffect.fromItem and not grantedEffect.fromTree and not grantedEffect.hideFromSideBar then
			local name = candidate.name:lower()
			if name == wanted then
				gemData = candidate
				break
			elseif wanted ~= "" and name:find(wanted, 1, true) then
				t_insert(partial, candidate)
			end
		end
	end
	if not gemData then
		if #partial == 1 then
			gemData = partial[1]
		elseif #partial > 1 then
			local names = { }
			for _, candidate in ipairs(partial) do
				t_insert(names, candidate.name)
			end
			t_sort(names)
			return nil, "Ambiguous skill '" .. tostring(setup.skill) .. "'. Matches: " .. t_concat(names, ", ")
		elseif setup.skillSource == "gem" then
			return nil, "'" .. tostring(setup.skill) .. "' is not an active skill gem"
		else
			return setupGrantedSkill(build, setup, wanted)
		end
	end
	local group = {
		label = "",
		enabled = true,
		gemList = { {
			level = gemLevelForCharacter(gemData, build.characterLevel, setup.gemLevel),
			quality = setup.gemQuality or optimizer.defaultOptions.gemQuality,
			count = 1,
			enabled = true,
			enableGlobal1 = true,
			enableGlobal2 = true,
			gemId = gemData.id,
			nameSpec = gemData.name,
			skillId = gemData.grantedEffectId,
		} },
	}
	t_insert(skillsTab.socketGroupList, group)
	skillsTab:ProcessSocketGroup(group)
	build.mainSocketGroup = #skillsTab.socketGroupList
	build.buildFlag = true
	if runCallback then
		runCallback("OnFrame")
	end
	return true
end

-- Start from a saved build (the XML text of an earlier result) instead of a fresh character: the search then refines its
-- equipment, gems and tree (an existing tree is only refined, not searched anew). The build has to match the setup's class,
-- ascendancy (when given) and main skill (exact or partial name, as in SetupCharacter); level and gems stay the seed's.
-- Returns true (and the pin of a skill that an item or node grants), or nil and an error message
function optimizer.SeedBuild(build, xmlText, setup)
	loadBuildFromXML(xmlText, "seed") -- (the build object stays the same, its tabs are made anew)
	local spec = build.spec
	if (spec.curClassName or ""):lower() ~= (setup.class or ""):lower() then
		return nil, "The seed build is a " .. tostring(spec.curClassName) .. ", not a " .. tostring(setup.class)
	end
	local wanted = (setup.ascendancy or ""):lower()
	if wanted ~= "" and wanted ~= "auto" and (spec.curAscendClassName or ""):lower() ~= wanted then
		return nil, "The seed build's ascendancy is " .. tostring(spec.curAscendClassName) .. ", not " .. setup.ascendancy
	end
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local gem = group and group.gemList[1]
	local skill = ((gem and gem.nameSpec) or ""):lower()
	local wantedSkill = (setup.skill or ""):lower()
	if wantedSkill == "" or not skill:find(wantedSkill, 1, true) then
		return nil, "The seed build's main skill is " .. tostring(gem and gem.nameSpec) .. ", not " .. tostring(setup.skill)
	end
	for key, value in pairs(setup.config or { }) do
		build.configTab.input[key] = value
	end
	build.configTab:BuildModList()
	build.buildFlag = true
	if runCallback then
		runCallback("OnFrame")
	end
	-- a main skill that an item or a node grants keeps that item / node (see setupGrantedSkill)
	local pin
	if group.sourceItem and group.slot then
		pin = { skillId = gem.skillId, slotName = group.slot, itemName = group.sourceItem.title or group.sourceItem.name }
	elseif group.sourceNode then
		pin = { skillId = gem.skillId, nodeId = group.sourceNode.id, itemName = group.sourceNode.dn }
	end
	return true, pin
end

-----------------------------------------------------------------------------------------------
-- Support gems
-----------------------------------------------------------------------------------------------

local function sharesFamily(a, b)
	if a == b or a.plusVersionOf == b.id or b.plusVersionOf == a.id then
		return true
	end
	if a.gemFamily and b.gemFamily then
		for _, family in ipairs(a.gemFamily) do
			for _, otherFamily in ipairs(b.gemFamily) do
				if family == otherFamily then
					return true
				end
			end
		end
	end
	return false
end

local function supportCandidates(ctx)
	local build = ctx.build
	local activeSkills = ctx.group.displaySkillList
	local list = { }
	for _, gemData in pairs(build.data.gems) do
		local grantedEffect = gemData.grantedEffect
		if grantedEffect.support and not grantedEffect.fromItem and not grantedEffect.fromTree and not grantedEffect.legacy
		and (ctx.opts.lineage or not grantedEffect.isLineage) then
			local levelReq = grantedEffect.levels and grantedEffect.levels[1] and grantedEffect.levels[1].levelRequirement or 1
			if levelReq <= build.characterLevel then
				local canSupport = not (activeSkills and activeSkills[1])
				if not canSupport then
					for _, activeSkill in ipairs(activeSkills) do
						if calcLib.canGrantedEffectSupportActiveSkill(grantedEffect, activeSkill) then
							canSupport = true
							break
						end
					end
				end
				if canSupport then
					t_insert(list, gemData)
				end
			end
		end
	end
	t_sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- Fill the support slots of the main skill. A plain greedy fill can lock itself in with its first
-- pick (some supports only work alone, or are only good in combination), so the fill is started
-- from several different first supports, and from the current links; every result is then
-- polished by swapping single supports, and the best set of links wins
local function optimizeSupports(ctx)
	local gemList = ctx.group.gemList
	local candidates = supportCandidates(ctx)
	local cur
	-- (the first support slot: after the meta skill's Spells, if it has any)
	local first = metaSpellCount(ctx.group) + 2

	local function conflicts(gemData, skipIndex)
		for index = first, #gemList do
			local other = gemList[index].gemData
			if index ~= skipIndex and other and sharesFamily(other.grantedEffect, gemData.grantedEffect) then
				return true
			end
		end
	end
	local function bestForIndex(index)
		local old = gemList[index]
		local best, bestScore = nil, cur
		for _, gemData in ipairs(candidates) do
			if not conflicts(gemData, index) and not (old and old.gemData == gemData) then
				gemList[index] = makeGemInstance(ctx, gemData)
				local score = eval(ctx)
				if better(ctx, score, bestScore) then
					best, bestScore = gemData, score
				end
			end
		end
		gemList[index] = old
		return best, bestScore
	end
	local function setLinks(links)
		for index = #gemList, first, -1 do
			gemList[index] = nil
		end
		for _, gemData in ipairs(links) do
			t_insert(gemList, makeGemInstance(ctx, gemData))
		end
	end
	local function getLinks()
		local links = { }
		for index = first, #gemList do
			if gemList[index].gemData then
				t_insert(links, gemList[index].gemData)
			end
		end
		return links
	end
	-- Complete and polish the links that are currently set
	local function finish()
		cur = eval(ctx)
		while #gemList - (first - 1) < ctx.opts.maxSupports do
			local best, bestScore = bestForIndex(#gemList + 1)
			if not best then
				break
			end
			t_insert(gemList, makeGemInstance(ctx, best))
			cur = bestScore
		end
		for _ = 1, 3 do
			local improved = false
			for index = first, #gemList do
				local best, bestScore = bestForIndex(index)
				if best then
					gemList[index] = makeGemInstance(ctx, best)
					cur = bestScore
					improved = true
				end
			end
			if not improved then
				break
			end
		end
		return cur
	end

	local starts = { getLinks() }
	-- Supports that do nothing for the skill on their own
	local idle = { }
	local function scoreLinks(links)
		local saved = getLinks()
		setLinks(links)
		local score = eval(ctx)
		setLinks(saved)
		return score
	end
	-- If the idle supports do something as a group, find the few of them that are responsible
	local function idleCombo(baseLinks)
		if not ctx.opts.combos or #idle < 2 then
			return
		end
		local function with(list)
			local links = { }
			for _, gemData in ipairs(baseLinks) do
				t_insert(links, gemData)
			end
			for _, gemData in ipairs(list) do
				t_insert(links, gemData)
			end
			return scoreLinks(links)
		end
		local baseScore = scoreLinks(baseLinks)
		local all = with(idle)
		if better(ctx, all, baseScore) and all - baseScore > math.abs(baseScore) * 1e-4 then
			local combo = shrink(idle, function(list) return with(list) - baseScore >= (all - baseScore) * 0.5 end)
			if #combo <= ctx.opts.maxSupports then
				return combo
			end
		end
	end
	if ctx.multiStart and ctx.opts.supportStarts > 0 and ctx.opts.maxSupports > 0 then
		-- Rank every support on its own to find the alternative starting points
		setLinks({ })
		local ranked = { }
		for _, gemData in ipairs(candidates) do
			gemList[first] = makeGemInstance(ctx, gemData)
			t_insert(ranked, { gemData = gemData, score = eval(ctx) })
		end
		gemList[first] = nil
		local emptyScore = eval(ctx)
		for _, entry in ipairs(ranked) do
			if entry.score == emptyScore then
				t_insert(idle, entry.gemData)
			end
		end
		t_sort(ranked, function(a, b)
			if a.score ~= b.score then
				return a.score > b.score
			end
			return a.gemData.id < b.gemData.id
		end)
		for index = 1, m_min(#ranked, ctx.opts.supportStarts) do
			t_insert(starts, { ranked[index].gemData })
		end
	end
	local combo = idleCombo({ })
	if combo then
		t_insert(starts, combo)
	end
	local bestLinks, bestScore
	for _, links in ipairs(starts) do
		setLinks(links)
		local score = finish()
		if not bestLinks or better(ctx, score, bestScore) then
			bestLinks, bestScore = getLinks(), score
		end
	end
	-- The same check on top of the winning links: the combination then has to push out weaker links
	combo = idleCombo(bestLinks)
	if combo then
		local links = { }
		for _, gemData in ipairs(combo) do
			t_insert(links, gemData)
		end
		for _, gemData in ipairs(bestLinks) do
			if #links < ctx.opts.maxSupports then
				t_insert(links, gemData)
			end
		end
		setLinks(links)
		local score = finish()
		if better(ctx, score, bestScore) then
			bestLinks, bestScore = getLinks(), score
			log(ctx, "  support combination found: %s", combo[1].name .. (combo[2] and (" + " .. combo[2].name) or ""))
		end
	end
	setLinks(bestLinks)
	ctx.build.skillsTab:ProcessSocketGroup(ctx.group)
	sync(ctx)
	return bestScore
end

-----------------------------------------------------------------------------------------------
-- Items
-----------------------------------------------------------------------------------------------

local function isJewelSlot(slotName)
	return slotName:match("^Jewel %d+$") ~= nil
end

local function evalItem(ctx, slotName, item, extra)
	local override = { repSlotName = slotName, repItem = item }
	if extra then
		for key, value in pairs(extra) do
			override[key] = value
		end
	end
	return eval(ctx, override)
end

local function makeRare(ctx, baseName, title)
	local base = ctx.build.data.itemBases[baseName]
	local lines
	if base.type == "Flask" or base.type == "Charm" then
		-- Flasks and charms can only be magic
		lines = { "Rarity: MAGIC", baseName, "Crafted: true" }
	else
		lines = { "Rarity: RARE", title or "Optimised Item", baseName, "Crafted: true" }
	end
	if base.socketLimit and base.socketLimit > 0 and (base.weapon or base.armour or base.tags.wand or base.tags.staff or base.tags.sceptre) then
		t_insert(lines, "Sockets: " .. ("S "):rep(base.socketLimit):sub(1, -2))
	end
	if base.type == "Jewel" and base.subType == "Radius" then
		t_insert(lines, "Radius: " .. ctx.opts.jewelRadius)
	end
	local item = new("Item"):Item(t_concat(lines, "\n") .. "\n")
	if not item.base then
		return nil
	end
	item:NormaliseQuality()
	item:BuildAndParseRaw()
	return item
end

-- Highest eligible tier of every modifier series that can spawn on the item
local function affixCandidates(ctx, item)
	local bestBySeries = { }
	for modId, mod in pairs(item.affixes or { }) do
		if (mod.type == "Prefix" or mod.type == "Suffix") and (mod.level or 1) <= ctx.opts.itemLevel and item:GetModSpawnWeight(mod) > 0 then
			local key = mod.type .. "|" .. tostring(mod.group) .. "|" .. t_concat(mod.statOrder or { }, ",")
			local cur = bestBySeries[key]
			if not cur or (mod.level or 1) > (item.affixes[cur].level or 1) or ((mod.level or 1) == (item.affixes[cur].level or 1) and modId < cur) then
				bestBySeries[key] = modId
			end
		end
	end
	local list = { }
	for _, modId in pairs(bestBySeries) do
		t_insert(list, modId)
	end
	t_sort(list)
	return list
end

-- Greedily add the affix with the largest gain until the item is full or nothing helps anymore.
-- Affixes that do nothing on their own are dropped after the first pass to keep this fast, so
-- when the greedy fill stalls they get a second chance: first each of them next to what has been
-- chosen by then, then all of them at once to find combinations that only work together.
local function craftAffixes(ctx, item, slotName, extra)
	local cur = evalItem(ctx, slotName, item, extra)
	if not item.crafted or not item.affixes or item.affixLimit == 0 then
		return cur
	end
	local roll = ctx.opts.affixRoll
	local allCandidates = affixCandidates(ctx, item)
	local candidates = allCandidates
	local usedGroups = { }
	local idle = { }
	local function freeIndex(list)
		for index = 1, (list.limit or (item.affixLimit / 2)) do
			if not list[index] or list[index].modId == "None" then
				return index
			end
		end
	end
	-- Note that Craft() re-parses the item, which replaces its prefix/suffix tables, so those are
	-- always looked up again through the item
	local function place(modIds)
		local placed = { }
		for _, modId in ipairs(modIds) do
			local listName = item.affixes[modId].type == "Prefix" and "prefixes" or "suffixes"
			local index = freeIndex(item[listName])
			if not index then
				for _, entry in ipairs(placed) do
					item[entry[1]][entry[2]] = { modId = "None" }
				end
				return nil
			end
			item[listName][index] = { modId = modId, range = roll }
			t_insert(placed, { listName, index })
		end
		item:Craft()
		return placed
	end
	-- Score the item with these affixes added, leaving it as it was; nil if they don't fit
	local function try(modIds)
		local placed = place(modIds)
		if not placed then
			return nil
		end
		local score = evalItem(ctx, slotName, item, extra)
		for _, entry in ipairs(placed) do
			item[entry[1]][entry[2]] = { modId = "None" }
		end
		return score
	end
	local function commit(modIds, score)
		place(modIds)
		for _, modId in ipairs(modIds) do
			usedGroups[item.affixes[modId].group or modId] = true
			if ctx.opts.debug then
				log(ctx, "      + %s: %s (%+.1f)", slotName, t_concat(item.affixes[modId], " / "), score - cur)
			end
		end
		cur = score
	end
	-- Score the item with any number of extra modifiers, ignoring the affix limits
	local function scoreWithExtra(modIds)
		local lines = { item:BuildRaw() }
		for _, modId in ipairs(modIds) do
			for _, line in ipairs(item.affixes[modId]) do
				t_insert(lines, "{custom}" .. itemLib.applyRange(line, roll))
			end
		end
		local testItem = new("Item"):Item(t_concat(lines, "\n"))
		if not testItem.base then
			return cur
		end
		return evalItem(ctx, slotName, testItem, extra)
	end
	local function findCombo()
		local pool = { }
		for _, modId in ipairs(idle) do
			local mod = item.affixes[modId]
			if not usedGroups[mod.group or modId] and freeIndex(item[mod.type == "Prefix" and "prefixes" or "suffixes"]) then
				t_insert(pool, modId)
			end
		end
		if #pool < 2 then
			return
		end
		local all = scoreWithExtra(pool)
		if not better(ctx, all, cur) or all - cur <= math.abs(cur) * 1e-4 then
			return
		end
		local combo = shrink(pool, function(list) return scoreWithExtra(list) - cur >= (all - cur) * 0.5 end)
		-- The responsible modifiers may not all fit, or may share a group; take the best pair that does
		local best, bestScore = nil, cur
		if #combo <= 4 then
			local score = try(combo)
			if score and better(ctx, score, bestScore) then
				best, bestScore = combo, score
			end
		end
		if not best and #combo <= 16 then
			for first = 1, #combo do
				for second = first + 1, #combo do
					local modA, modB = item.affixes[combo[first]], item.affixes[combo[second]]
					if (modA.group or combo[first]) ~= (modB.group or combo[second]) then
						local score = try({ combo[first], combo[second] })
						if score and better(ctx, score, bestScore) then
							best, bestScore = { combo[first], combo[second] }, score
						end
					end
				end
			end
		end
		return best, bestScore
	end

	local firstPass, retried, comboTried = true, false, false
	while true do
		local best, bestScore = nil, cur
		local relevant = { }
		for _, modId in ipairs(candidates) do
			local mod = item.affixes[modId]
			if not usedGroups[mod.group or modId] then
				local score = try({ modId })
				if score then
					if score ~= cur then
						t_insert(relevant, modId)
					elseif firstPass then
						t_insert(idle, modId)
					end
					if better(ctx, score, bestScore) then
						best, bestScore = modId, score
					end
				end
			end
		end
		if firstPass then
			candidates = relevant
			firstPass = false
		end
		if best then
			commit({ best }, bestScore)
			if retried then
				-- Something that used to be idle became useful; everything is in play again
				retried = false
				candidates = allCandidates
			end
		elseif not ctx.opts.combos then
			break
		elseif not retried and #idle > 0 then
			retried = true
			candidates = allCandidates
		elseif not comboTried then
			comboTried = true
			local combo, comboScore = findCombo()
			if not combo then
				break
			end
			if ctx.opts.debug then
				log(ctx, "      affix combination found on %s", slotName)
			end
			commit(combo, comboScore)
			retried = false
			candidates = allCandidates
		else
			break
		end
	end
	item:Craft()
	return cur
end

local function setRune(item, index, name)
	item.runes[index] = name
	-- Only the rune lines change, so their mods are rebuilt without parsing the whole item again
	item:UpdateRunes()
	item:BuildModList()
end

-- Fill every socket of the item with the rune / soul core that adds the most
local function optimizeRunes(ctx, item, slotName, extra, cur)
	local socketCount = item.itemSocketCount or 0
	if not ctx.opts.runes or socketCount == 0 then
		return cur
	end
	local characterLevel = ctx.build.characterLevel
	local runes = { }
	for _, rune in ipairs(ctx.build.itemsTab:GetValidRunesForItem(item)) do
		if rune.name ~= "None" and (rune.req or 0) <= characterLevel then
			t_insert(runes, rune)
		end
	end
	for index = 1, socketCount do
		local original = item.runes[index] or "None"
		local best, bestScore = original, cur
		local relevant = { }
		for _, rune in ipairs(runes) do
			local count = 0
			for other = 1, socketCount do
				if other ~= index and item.runes[other] == rune.name then
					count = count + 1
				end
			end
			if rune.name ~= original and (not rune.limit or count < rune.limit) then
				setRune(item, index, rune.name)
				local score = evalItem(ctx, slotName, item, extra)
				if score ~= cur then
					t_insert(relevant, rune)
				end
				if better(ctx, score, bestScore) then
					best, bestScore = rune.name, score
				end
			end
		end
		setRune(item, index, best)
		if index == 1 then
			runes = relevant
		end
		cur = bestScore
	end
	return cur
end

local function itemBaseList(ctx)
	if not ctx.baseNames then
		ctx.baseNames = { }
		for name, base in pairs(ctx.build.data.itemBases) do
			if not base.hidden and base.type ~= "Fishing Rod" and (base.req.level or 0) <= ctx.build.characterLevel then
				t_insert(ctx.baseNames, name)
			end
		end
		t_sort(ctx.baseNames)
		ctx.baseItems = { }
	end
	return ctx.baseNames
end

local function baseCouldFitSlot(base, slotName)
	slotName = slotName:gsub(" Swap$", "")
	if isJewelSlot(slotName) then
		return base.type == "Jewel"
	elseif slotName == "Weapon 1" then
		return base.tags.onehand or base.tags.twohand
	elseif slotName == "Weapon 2" then
		return base.tags.onehand or base.tags.twohand or base.type == "Shield" or base.type == "Focus" or base.type == "Quiver" or base.type == "Sceptre"
	end
	return base.type == slotName:gsub(" %d+$", "")
end

-- Attribute requirements of the base that the main skill gem doesn't call for anyway
local function offAttributeCost(ctx, base)
	local gemData = ctx.group.gemList[1].gemData
	local cost = 0
	if gemData then
		if (gemData.reqStr or 0) == 0 then cost = cost + (base.req.str or 0) end
		if (gemData.reqDex or 0) == 0 then cost = cost + (base.req.dex or 0) end
		if (gemData.reqInt or 0) == 0 then cost = cost + (base.req.int or 0) end
	end
	return cost
end

-- Returns the bases worth crafting for a slot, best first
local function rankBases(ctx, slotName, extra)
	local itemsTab = ctx.build.itemsTab
	local bases = ctx.build.data.itemBases
	local entries = { }
	for _, name in ipairs(itemBaseList(ctx)) do
		local base = bases[name]
		if baseCouldFitSlot(base, slotName) then
			local item = ctx.baseItems[name]
			if item == nil then
				item = makeRare(ctx, name) or false
				ctx.baseItems[name] = item
			end
			if item and itemsTab:IsItemValidForSlot(item, slotName) then
				t_insert(entries, {
					name = name,
					base = base,
					typeKey = base.type .. "/" .. tostring(base.subType),
					score = evalItem(ctx, slotName, item, extra),
					offAttr = offAttributeCost(ctx, base),
					level = base.req.level or 0,
				})
			end
		end
	end
	local function order(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		elseif a.offAttr ~= b.offAttr then
			return a.offAttr < b.offAttr
		elseif a.level ~= b.level then
			return a.level > b.level
		end
		return a.name < b.name
	end
	t_sort(entries, order)
	if isJewelSlot(slotName) then
		-- Every jewel base has its own modifier pool
		return entries
	end
	-- Keep the best base of every item type
	local picked, seenType = { }, { }
	for _, entry in ipairs(entries) do
		if not seenType[entry.typeKey] then
			seenType[entry.typeKey] = true
			t_insert(picked, entry)
		end
	end
	local result = { }
	local isWeaponSlot = slotName:match("^Weapon") ~= nil
	for index, entry in ipairs(picked) do
		if index == 1 then
			t_insert(result, entry)
		elseif isWeaponSlot then
			-- Different weapon types have different modifier pools, so when the bare bases can't be told
			-- apart (e.g. for spells) every tied type has to be crafted to know which one is best
			local tied = entry.score == result[#result].score
			if #result < ctx.opts.baseCandidates or tied then
				t_insert(result, entry)
			else
				break
			end
		else
			if entry.score == result[1].score or #result >= ctx.opts.baseCandidates then
				break
			end
			t_insert(result, entry)
		end
	end
	return result
end

-- Older versions of a unique ("Pre 0.4.0", "Fire (Pre 0.2.1 )", or named by the version they
-- were changed in, "0.2.0"). Test variants (From Nothing's "Everything") don't exist in the game at all
local function isLegacyVariant(name)
	return name:match("^Pre ") or name:match("%(Pre ") or name:match("^%d+%.%d+")
end
local function isTestVariant(name)
	return name:find("Test Variant", 1, true) ~= nil
end

-- Variant numbers of a unique the search tries (false = the unique has no variants), or an empty
-- list if it is not obtainable. By default that is the selected variant, or the newest current one
-- if the selected variant is legacy or a test variant. opts.legacyUniques adds every legacy variant
-- and the unobtainable uniques, opts.uniqueVariants every other current variant of uniques with one
-- choice. Uniques with several choices at once ("Has Alt Variant": Megalomaniac's notables, Grip of
-- Kulemak's modifiers, ...) keep their selection: varying only the first choice is no real search,
-- and their hundreds of variants would each become a full item
function optimizer.UniqueVariants(source, opts)
	local legacyUniques = opts and opts.legacyUniques
	local alternatives = opts and opts.uniqueVariants and not source.hasAltVariant
	-- Same rule as the "Obtainable" filter of the unique database (Classes/ItemDBControl.lua)
	if not legacyUniques and (source.source == "No longer obtainable" or source.league == "Race Events") then
		return { }
	end
	local names = source.variantList
	if not names or #names == 0 then
		return { false }
	end
	local function current(name)
		return not isLegacyVariant(name) and not isTestVariant(name)
	end
	local selected = source.variant or #names
	if not current(names[selected]) then
		for index = #names, 1, -1 do
			if current(names[index]) then
				selected = index
				break
			end
		end
	end
	local list = { }
	if current(names[selected]) or (legacyUniques and not isTestVariant(names[selected])) then
		t_insert(list, selected)
	end
	for index, name in ipairs(names) do
		if index ~= selected and ((legacyUniques and isLegacyVariant(name)) or (alternatives and current(name))) then
			t_insert(list, index)
		end
	end
	return list
end

-- Which version of a unique the build uses, for the summary: legacy versions, and the chosen one of
-- several current alternatives
local function variantNote(item)
	local names = item.rarity == "UNIQUE" and item.variantList
	local name = names and item.variant and names[item.variant]
	if not name then
		return ""
	elseif isLegacyVariant(name) then
		return " (legacy version: " .. name .. ")"
	elseif item.hasAltVariant then
		-- Several choices at once (Mageblood's Legacies); the first alone would mislead
		return ""
	end
	local alternatives = 0
	for _, other in ipairs(names) do
		if not isLegacyVariant(other) and not isTestVariant(other) then
			alternatives = alternatives + 1
		end
	end
	return alternatives > 1 and (" (version: " .. name .. ")") or ""
end

local function rollUnique(ctx, source, variant)
	local item = new("Item"):Item(source:BuildRaw())
	if not item.base then
		return nil
	end
	if variant and item.variant ~= variant then
		item.variant = variant
		item:BuildAndParseRaw()
	end
	local changed = false
	for _, list in ipairs({ item.implicitModLines, item.explicitModLines, item.enchantModLines }) do
		for _, modLine in ipairs(list or { }) do
			if modLine.range then
				modLine.range = ctx.opts.affixRoll
				changed = true
			end
		end
	end
	if changed then
		item:BuildAndParseRaw()
	end
	return item
end

-- Every unique that can go into the slot, rolled to the configured quality
local function uniquesForSlot(ctx, slotName)
	local list = { }
	if not (main.uniqueDB and main.uniqueDB.list) then
		return list
	end
	local itemsTab = ctx.build.itemsTab
	local names = { }
	for name in pairs(main.uniqueDB.list) do
		t_insert(names, name)
	end
	t_sort(names)
	for _, name in ipairs(names) do
		local source = main.uniqueDB.list[name]
		local limitReached = source.limit and (ctx.uniqueCount[source.title or name] or 0) >= source.limit
		if source.base and not limitReached and baseCouldFitSlot(source.base, slotName) and itemsTab:IsItemValidForSlot(source, slotName)
		and (source.requirements.level or 0) <= ctx.build.characterLevel then
			for _, variant in ipairs(optimizer.UniqueVariants(source, ctx.opts)) do
				local item = rollUnique(ctx, source, variant)
				if item then
					t_insert(list, item)
				end
			end
		end
	end
	return list
end

-- Finds the best item for a slot given everything else that is currently equipped.
-- Returns item, score (item is nil if nothing fits the slot)
local function bestItemForSlot(ctx, slotName, allowUniques, extra, label)
	local best, bestScore
	local crafted = { }
	for _, entry in ipairs(rankBases(ctx, slotName, extra)) do
		local item = makeRare(ctx, entry.name, label or ("Optimised " .. slotName))
		if item then
			local score = craftAffixes(ctx, item, slotName, extra)
			score = optimizeRunes(ctx, item, slotName, extra, score)
			t_insert(crafted, { item = item, score = score })
			if not best or better(ctx, score, bestScore) then
				best, bestScore = item, score
			end
		end
	end
	if allowUniques then
		local uniques = { }
		for _, item in ipairs(uniquesForSlot(ctx, slotName)) do
			t_insert(uniques, { item = item, score = evalItem(ctx, slotName, item, extra) })
		end
		t_sort(uniques, function(a, b) return a.score > b.score end)
		-- Runes can change the ranking, so the leading uniques are socketed before comparing
		for index = 1, m_min(#uniques, 3) do
			local entry = uniques[index]
			entry.score = optimizeRunes(ctx, entry.item, slotName, extra, entry.score)
			if not best or better(ctx, entry.score, bestScore) then
				best, bestScore = entry.item, entry.score
			end
		end
	end
	return best, bestScore, crafted
end

local function slotFor(ctx, slotName)
	return ctx.build.itemsTab.slots[slotName]
end

local function equippedItem(ctx, slotName)
	local slot = slotFor(ctx, slotName)
	return slot and ctx.build.itemsTab.items[slot.selItemId]
end

local function countUnique(ctx, item, delta)
	if item and (item.rarity == "UNIQUE" or item.rarity == "RELIC") then
		local key = item.title or item.name
		ctx.uniqueCount[key] = (ctx.uniqueCount[key] or 0) + delta
	end
end

-- The item that grants the main skill (ctx.opts.pin) stays in its slot as it is: another item, even one that grants the same skill, or the
-- same item put back would be another item id, that is another skill group without the supports. A main hand that PoB would clear a
-- pinned off hand for stays out too
local function pinBlocks(ctx, slotName, item)
	local pin = ctx.opts.pin
	if not (pin and pin.slotName) then
		return false
	end
	if slotName == pin.slotName then
		return true
	end
	return pin.slotName == "Weapon 2" and slotName == "Weapon 1" and item and item.base and not (ctx.build.data.weaponTypeInfo[item.base.type] or { }).oneHand or false
end

local function unequip(ctx, slotName)
	local itemsTab = ctx.build.itemsTab
	local slot = slotFor(ctx, slotName)
	local old = slot and itemsTab.items[slot.selItemId]
	if old and pinBlocks(ctx, slotName, nil) then
		return nil
	end
	if old then
		slot:SetSelItemId(0)
		itemsTab.items[old.id] = nil
		for index, id in ipairs(itemsTab.itemOrderList) do
			if id == old.id then
				t_remove(itemsTab.itemOrderList, index)
				break
			end
		end
		countUnique(ctx, old, -1)
		old.id = nil
	end
	return old
end

local function equip(ctx, slotName, item)
	local itemsTab = ctx.build.itemsTab
	if pinBlocks(ctx, slotName, item) then
		return
	end
	unequip(ctx, slotName)
	if item then
		item.id = nil
		itemsTab:AddItem(item, true)
		slotFor(ctx, slotName):SetSelItemId(item.id)
		countUnique(ctx, item, 1)
	end
	itemsTab:PopulateSlots()
	sync(ctx)
end

-- Main hand and off hand are searched together: the best main hand on its own isn't necessarily
-- part of the best pair (two-hander vs. one-hander with quiver/focus/shield/second weapon)
local function optimizeWeapons(ctx, allowUniques)
	local startMain, startOff = equippedItem(ctx, "Weapon 1"), equippedItem(ctx, "Weapon 2")
	local startScore = eval(ctx)

	-- Candidates for the main hand are scored without the current off hand, which may not fit them
	unequip(ctx, "Weapon 2")
	sync(ctx)
	local bestMain, bestMainScore, crafted = bestItemForSlot(ctx, "Weapon 1", allowUniques, nil, "Optimised Weapon")
	local candidates = { }
	for _, entry in ipairs(crafted or { }) do
		t_insert(candidates, entry)
	end
	if bestMain and (bestMain.rarity == "UNIQUE" or bestMain.rarity == "RELIC") then
		t_insert(candidates, { item = bestMain, score = bestMainScore })
	end
	t_sort(candidates, function(a, b) return a.score > b.score end)
	-- Take the leading candidates, but make sure both one-handed and two-handed options are represented
	local shortlist, haveOneHand, haveTwoHand = { }, false, false
	for _, entry in ipairs(candidates) do
		local oneHand = entry.item.base.tags.onehand and true or false
		if #shortlist < ctx.opts.weaponCombos or (oneHand and not haveOneHand) or (not oneHand and not haveTwoHand) then
			t_insert(shortlist, entry)
			haveOneHand = haveOneHand or oneHand
			haveTwoHand = haveTwoHand or not oneHand
		end
	end

	local bestPair, bestPairScore
	for _, entry in ipairs(shortlist) do
		equip(ctx, "Weapon 1", entry.item)
		local offHand, pairScore = bestItemForSlot(ctx, "Weapon 2", allowUniques, nil, "Optimised Off Hand")
		if not offHand then
			pairScore = eval(ctx)
		end
		log(ctx, "    %s%s -> %.1f", entry.item.name, offHand and (" + " .. offHand.name) or "", pairScore)
		if not bestPair or better(ctx, pairScore, bestPairScore) then
			bestPair, bestPairScore = { entry.item, offHand }, pairScore
		end
		unequip(ctx, "Weapon 1")
	end

	if bestPair and (not startMain or better(ctx, bestPairScore, startScore)) then
		equip(ctx, "Weapon 1", bestPair[1])
		if bestPair[2] then
			equip(ctx, "Weapon 2", bestPair[2])
		end
		return bestPairScore
	end
	-- Nothing better than what was equipped before
	if startMain then
		equip(ctx, "Weapon 1", startMain)
	end
	if startOff then
		equip(ctx, "Weapon 2", startOff)
	end
	return startScore
end

local function slotAvailable(ctx, slotName)
	if not slotFor(ctx, slotName) then
		return false
	end
	if slotName == "Ring 3" then
		local mainEnv = ctx.build.calcsTab.mainEnv
		return mainEnv and mainEnv.modDB:Flag(nil, "AdditionalRingSlot") or false
	end
	return true
end

local function optimizeGear(ctx, allowUniques)
	local cur = optimizeWeapons(ctx, allowUniques)
	log(ctx, "  weapons: %.1f", cur)
	for _, slotName in ipairs(gearSlots) do
		if slotAvailable(ctx, slotName) then
			local current = equippedItem(ctx, slotName)
			local item, score = bestItemForSlot(ctx, slotName, allowUniques)
			if item and (not current and score >= cur or better(ctx, score, cur)) then
				equip(ctx, slotName, item)
				cur = score
				log(ctx, "  %s: %s -> %.1f", slotName, item.name, cur)
			end
		end
	end
	return cur
end

-- Uniques can switch off other slots ("Can't use Body Armour") or make earlier choices pointless.
-- Items that were crafted with modifiers but no longer change the result are taken off again
local function removeDeadItems(ctx)
	local cur = eval(ctx)
	local slots = { "Weapon 2" }
	for _, slotName in ipairs(gearSlots) do
		t_insert(slots, slotName)
	end
	for _, slotName in ipairs(slots) do
		local item = equippedItem(ctx, slotName)
		if item then
			local hasMods = #item.explicitModLines > 0 or #(item.runeModLines or { }) > 0
			if hasMods and eval(ctx, { repSlotName = slotName }) >= cur then
				log(ctx, "  %s: %s no longer contributes, removed", slotName, item.name)
				equip(ctx, slotName, nil)
			end
		end
	end
end

-- Two uniques can be worth equipping together although neither is on its own. For the leading
-- rejected uniques of every slot (all of them in thorough mode), put the unique on and see whether
-- any unique in any other slot then lifts the build above where it is now
local function optimizeUniquePairs(ctx)
	local anchorSlots, partnerSlots = { }, { "Weapon 1", "Weapon 2" }
	for _, slotName in ipairs(gearSlots) do
		if slotAvailable(ctx, slotName) then
			t_insert(anchorSlots, slotName)
			t_insert(partnerSlots, slotName)
		end
	end
	local cur = eval(ctx)
	for _ = 1, 3 do
		local cache = { }
		local function uniques(slotName)
			if not cache[slotName] then
				cache[slotName] = uniquesForSlot(ctx, slotName)
			end
			return cache[slotName]
		end
		local best
		for _, anchorSlot in ipairs(anchorSlots) do
			local old = equippedItem(ctx, anchorSlot)
			local ranked = { }
			for _, item in ipairs(uniques(anchorSlot)) do
				if not (old and old.title == item.title) then
					t_insert(ranked, { item = item, score = evalItem(ctx, anchorSlot, item) })
				end
			end
			t_sort(ranked, function(a, b) return a.score > b.score end)
			for index = 1, ctx.opts.thorough and #ranked or m_min(#ranked, ctx.opts.uniquePairAnchors) do
				local anchor = ranked[index]
				if anchor.score > 0 then
					equip(ctx, anchorSlot, anchor.item)
					for _, partnerSlot in ipairs(partnerSlots) do
						if partnerSlot ~= anchorSlot then
							for _, partner in ipairs(uniques(partnerSlot)) do
								local score = evalItem(ctx, partnerSlot, partner)
								if better(ctx, score, best and best.score or cur) then
									best = { anchorSlot = anchorSlot, anchor = anchor.item, partnerSlot = partnerSlot, partner = partner, score = score }
								end
							end
						end
					end
					equip(ctx, anchorSlot, old)
				end
			end
		end
		if not best then
			break
		end
		equip(ctx, best.anchorSlot, best.anchor)
		equip(ctx, best.partnerSlot, best.partner)
		cur = eval(ctx)
		log(ctx, "  unique pair: %s + %s -> %.1f", best.anchor.name, best.partner.name, cur)
	end
	return cur
end

-----------------------------------------------------------------------------------------------
-- Auxiliary skills, flasks and charms
-----------------------------------------------------------------------------------------------

local function isAuxGroup(ctx, group)
	return group ~= ctx.group and not group.source and not group.sourceItem and not group.sourceNode
end

-- The group that holds the source of a node- or item-triggered main skill (optimizeTriggerSource); the label is what a saved build keeps
local triggerSourceLabel = "Trigger source"
local function isTriggerSource(group)
	return group.triggerSource or group.label == triggerSourceLabel
end

-- Skill gems with an effect outside of their own damage (auras and other persistent buffs, curses,
-- marks, ...) that the character doesn't use yet
local function auxCandidates(ctx)
	local build = ctx.build
	local used = { }
	for _, group in ipairs(build.skillsTab.socketGroupList) do
		for _, gemInstance in ipairs(group.gemList) do
			if gemInstance.gemData then
				used[gemInstance.gemData.id] = true
			end
		end
	end
	-- An enemy can only carry one mark. The engine doesn't apply that limit to every mark gem, so
	-- it is enforced here: once the character has a mark, no further marks are offered
	local haveMark = false
	for _, group in ipairs(build.skillsTab.socketGroupList) do
		for _, gemInstance in ipairs(group.gemList) do
			if group.enabled and gemInstance.gemData and gemInstance.gemData.tags.mark then
				haveMark = true
			end
		end
	end
	local list = { }
	for _, gemData in pairs(build.data.gems) do
		local grantedEffect = gemData.grantedEffect
		if not grantedEffect.support and not grantedEffect.fromItem and not grantedEffect.fromTree and not grantedEffect.hideFromSideBar
		and grantedEffect.hasGlobalEffect and not used[gemData.id] and not (haveMark and gemData.tags.mark) then
			local levelReq = grantedEffect.levels and grantedEffect.levels[1] and grantedEffect.levels[1].levelRequirement or 1
			if levelReq <= build.characterLevel then
				t_insert(list, gemData)
			end
		end
	end
	t_sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- Give an auxiliary skill the supports that raise the score (more curse effect, and so on)
local function supportAuxGroup(ctx, group, cur)
	local gemList = group.gemList
	local relevant = { }
	local candidates = { }
	for _, gemData in pairs(ctx.build.data.gems) do
		local grantedEffect = gemData.grantedEffect
		-- Lineage supports are left to the main skill; each can only be used once
		if grantedEffect.support and not grantedEffect.fromItem and not grantedEffect.fromTree and not grantedEffect.legacy and not grantedEffect.isLineage then
			local levelReq = grantedEffect.levels and grantedEffect.levels[1] and grantedEffect.levels[1].levelRequirement or 1
			if levelReq <= ctx.build.characterLevel then
				t_insert(candidates, gemData)
			end
		end
	end
	t_sort(candidates, function(a, b) return a.id < b.id end)
	for _, gemData in ipairs(candidates) do
		gemList[2] = makeGemInstance(ctx, gemData)
		if eval(ctx) ~= cur then
			t_insert(relevant, gemData)
		end
		gemList[2] = nil
	end
	while #gemList - 1 < ctx.opts.maxSupports do
		local best, bestScore = nil, cur
		for _, gemData in ipairs(relevant) do
			local conflict = false
			for index = 2, #gemList do
				if gemList[index].gemData and sharesFamily(gemList[index].gemData.grantedEffect, gemData.grantedEffect) then
					conflict = true
					break
				end
			end
			if not conflict then
				gemList[#gemList + 1] = makeGemInstance(ctx, gemData)
				local score = eval(ctx)
				gemList[#gemList] = nil
				if better(ctx, score, bestScore) then
					best, bestScore = gemData, score
				end
			end
		end
		if not best then
			break
		end
		t_insert(gemList, makeGemInstance(ctx, best))
		cur = bestScore
	end
	ctx.build.skillsTab:ProcessSocketGroup(group)
	return cur
end

-- Add the skills whose buff or debuff raises the main skill's damage, one at a time, best first.
-- The engine applies the curse and mark limits itself; Spirit is enforced by the scoring. A buff
-- that would help but doesn't fit into the available Spirit gets one chance: the body armour or
-- amulet is crafted again with the buff in place, which makes a Spirit affix worth its slot
local function optimizeAuxSkills(ctx)
	local skillsTab = ctx.build.skillsTab
	local groups = skillsTab.socketGroupList
	local cur = eval(ctx)
	for index = #groups, 1, -1 do
		local group = groups[index]
		if isAuxGroup(ctx, group) and not isTriggerSource(group) then
			t_remove(groups, index)
			sync(ctx)
			local score = eval(ctx)
			if score >= cur then
				log(ctx, "  %s no longer contributes, removed", group.gemList[1] and group.gemList[1].nameSpec or "skill")
				cur = score
			else
				t_insert(groups, index, group)
				sync(ctx)
			end
		end
	end
	local function skillCount()
		local count = 0
		for _, group in ipairs(groups) do
			if group == ctx.group or isAuxGroup(ctx, group) then
				count = count + 1
			end
		end
		return count
	end
	local function newGroup(gemData)
		return { label = "", enabled = true, gemList = { makeGemInstance(ctx, gemData) } }
	end
	local rejected = { }
	local added = { }
	while skillCount() < ctx.opts.maxSkills do
		local best, bestScore = nil, cur
		local blocked, blockedScore = nil, cur
		for _, gemData in ipairs(auxCandidates(ctx)) do
			if not rejected[gemData.id] then
				t_insert(groups, newGroup(gemData))
				local score = eval(ctx)
				if score < 0 then
					ctx.ignoreSpirit = true
					score = eval(ctx)
					ctx.ignoreSpirit = false
					if better(ctx, score, blockedScore) then
						blocked, blockedScore = gemData, score
					end
				elseif better(ctx, score, bestScore) then
					best, bestScore = gemData, score
				end
				t_remove(groups)
			end
		end
		if blocked and better(ctx, blockedScore, bestScore) then
			local group = newGroup(blocked)
			t_insert(groups, group)
			local kept = false
			for _, slotName in ipairs({ "Body Armour", "Amulet" }) do
				local item, score = bestItemForSlot(ctx, slotName, ctx.allowUniques)
				if item and better(ctx, score, bestScore) then
					skillsTab:ProcessSocketGroup(group)
					equip(ctx, slotName, item)
					cur = score
					kept = true
					t_insert(added, group)
					log(ctx, "  + %s, with Spirit from a new %s -> %.1f", blocked.name, slotName, cur)
					break
				end
			end
			if not kept then
				t_remove(groups)
				rejected[blocked.id] = true
			end
		elseif best then
			local group = newGroup(best)
			t_insert(groups, group)
			skillsTab:ProcessSocketGroup(group)
			cur = bestScore
			t_insert(added, group)
			log(ctx, "  + %s -> %.1f", best.name, cur)
		else
			break
		end
	end
	for _, group in ipairs(added) do
		local score = supportAuxGroup(ctx, group, cur)
		if better(ctx, score, cur) then
			local names = { }
			for index = 2, #group.gemList do
				t_insert(names, group.gemList[index].nameSpec)
			end
			log(ctx, "  %s supported by %s -> %.1f", group.gemList[1].nameSpec, t_concat(names, ", "), score)
		end
		cur = score
	end
	sync(ctx)
	return cur
end

local utilitySlots = { "Flask 1", "Flask 2", "Charm 1", "Charm 2", "Charm 3" }

-- Flasks and charms count while they are active, so every flask and charm slot is switched on and
-- gets the item (magic or unique) that adds the most; slots where nothing helps stay empty
local function optimizeUtility(ctx, allowUniques)
	local itemsTab = ctx.build.itemsTab
	for _, slotName in ipairs(utilitySlots) do
		local slot = itemsTab.slots[slotName]
		if slot then
			slot.active = true
			if itemsTab.activeItemSet and itemsTab.activeItemSet[slotName] then
				itemsTab.activeItemSet[slotName].active = true
			end
			if slot.controls and slot.controls.activate then
				slot.controls.activate.state = true
			end
		end
	end
	local cur = eval(ctx)
	for _, slotName in ipairs(utilitySlots) do
		if itemsTab.slots[slotName] then
			local item, score = bestItemForSlot(ctx, slotName, allowUniques)
			if item and better(ctx, score, cur) then
				equip(ctx, slotName, item)
				cur = score
				log(ctx, "  %s: %s -> %.1f", slotName, item.name, cur)
			end
		end
	end
	return cur
end

-----------------------------------------------------------------------------------------------
-- Passive tree
-----------------------------------------------------------------------------------------------

local function passiveBudget(ctx)
	if ctx.opts.points then
		return ctx.opts.points
	end
	local build = ctx.build
	local questPoints = 0
	for _, act in ipairs(build.acts or { }) do
		if act.level <= build.characterLevel then
			questPoints = act.questPoints
		end
	end
	local extra = build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
	return build.characterLevel - 1 + questPoints + extra
end

local function remainingPoints(ctx, ascendancy)
	local used, ascUsed, _, _, set1Used, set2Used = ctx.build.spec:CountAllocNodes()
	if ascendancy then
		return ctx.opts.ascendancyPoints - ascUsed
	end
	-- A weapon-set point is spent once for both sets
	return passiveBudget(ctx) - (used - m_min(set1Used or 0, set2Used or 0))
end

local function isTreeCandidate(node, ascendancy)
	if node.alloc or not node.path or (node.pathDist or 1000) >= 1000 then
		return false
	end
	if node.type == "ClassStart" or node.type == "AscendClassStart" or node.type == "Mastery" or node.type == "OnlyImage" then
		return false
	end
	if node.isFreeAllocate ~= nil then
		return false
	end
	if ascendancy then
		return node.ascendancyName ~= nil
	end
	return node.ascendancyName == nil
end

-- Spend the available points. Every step values each reachable node on its own, estimates the
-- value of whole paths (and of whole node clusters) per point from that, verifies the most
-- promising ones with a real calculation and allocates the winner.
local function growTree(ctx, ascendancy)
	local spec = ctx.build.spec
	local steps = 0
	local exponent = not ascendancy and ctx.treeExponent or 1
	local function weight(cost)
		return exponent == 1 and cost or cost ^ exponent
	end
	while true do
		local remaining = remainingPoints(ctx, ascendancy)
		if remaining <= 0 then
			break
		end
		local base = eval(ctx)
		local value, cache = { }, { }
		local nodes = { }
		for id, node in pairs(spec.nodes) do
			if isTreeCandidate(node, ascendancy) and node.pathDist <= remaining then
				t_insert(nodes, node)
				local key = node.type == "Socket" and ("socket" .. id) or node.modKey
				if key and key ~= "" then
					if cache[key] == nil then
						cache[key] = eval(ctx, { addNodes = { [node] = true } }) - base
					end
					value[node] = cache[key]
				else
					value[node] = 0
				end
			end
		end
		t_sort(nodes, function(a, b) return a.id < b.id end)

		local candidates = { }
		local groups = { }
		for _, node in ipairs(nodes) do
			if value[node] > 0 then
				local gain = 0
				for _, pathNode in ipairs(node.path) do
					gain = gain + (value[pathNode] or 0)
				end
				t_insert(candidates, { targets = { node }, nodes = node.path, cost = #node.path, estimate = gain / weight(#node.path) })
				if node.group then
					groups[node.group] = groups[node.group] or { }
					t_insert(groups[node.group], node)
				end
			end
		end
		-- Whole clusters: all useful nodes of a group and the travel nodes needed to reach them
		for _, groupNodes in pairs(groups) do
			if #groupNodes > 1 then
				local set, list, gain = { }, { }, 0
				for _, node in ipairs(groupNodes) do
					for _, pathNode in ipairs(node.path) do
						if not set[pathNode] then
							set[pathNode] = true
							t_insert(list, pathNode)
							gain = gain + (value[pathNode] or 0)
						end
					end
				end
				if #list <= remaining then
					t_sort(groupNodes, function(a, b)
						if a.pathDist ~= b.pathDist then
							return a.pathDist < b.pathDist
						end
						return a.id < b.id
					end)
					t_insert(candidates, { targets = groupNodes, nodes = list, cost = #list, estimate = gain / weight(#list) })
				end
			end
		end
		-- Passives that do nothing alone are tested as one group. If the group does something, the
		-- few nodes responsible are pinned down and offered, with the travel they need, as a candidate
		if ctx.opts.combos and not ctx.treeComboFailed then
			local idle = { }
			for _, node in ipairs(nodes) do
				if value[node] == 0 and node.modKey and node.modKey ~= "" and node.type ~= "Socket" then
					t_insert(idle, node)
				end
			end
			local function gainOf(list)
				local addNodes = { }
				for _, node in ipairs(list) do
					addNodes[node] = true
				end
				return eval(ctx, { addNodes = addNodes }) - base
			end
			local all = #idle > 1 and gainOf(idle) or 0
			if all > math.abs(base) * 1e-4 then
				-- The combination found in the previous step is usually still the answer
				local combo
				if ctx.treeCombo then
					local previous, isIdle = { }, { }
					for _, node in ipairs(idle) do
						isIdle[node.id] = node
					end
					for _, id in ipairs(ctx.treeCombo) do
						if isIdle[id] then
							t_insert(previous, isIdle[id])
						end
					end
					if #previous == #ctx.treeCombo and gainOf(previous) >= all * 0.5 then
						combo = previous
					end
				end
				if not combo then
					-- With survivability in the score the idle passives nearly always move the build as a
					-- group: Evasion, Life, Mana and the like are whole numbers, so many small nodes are worth
					-- nothing alone and something together (and +Mana pays off with Mana before Life, ...).
					-- The part responsible is then large and pinning it down takes a quadratic number of
					-- calculations, so it gets a budget, and the group test is left out for the rest of this
					-- tree when that runs out.
					-- ponytail: fixed budget of 100 calculations; upgrade path = test idle nodes in groups of one stat
					combo = shrink(idle, function(list) return gainOf(list) >= all * 0.5 end, not ctx.skipEHP and 100 or nil)
					if not combo then
						ctx.treeComboFailed = true
						combo = { }
					end
					ctx.treeCombo = { }
					for _, node in ipairs(combo) do
						t_insert(ctx.treeCombo, node.id)
					end
				end
				local set, list = { }, { }
				for _, node in ipairs(combo) do
					for _, pathNode in ipairs(node.path) do
						if not set[pathNode] then
							set[pathNode] = true
							t_insert(list, pathNode)
						end
					end
				end
				if #list > 0 and #list <= remaining then
					t_sort(combo, function(a, b)
						if a.pathDist ~= b.pathDist then
							return a.pathDist < b.pathDist
						end
						return a.id < b.id
					end)
					local gain = gainOf(list)
					t_insert(candidates, { targets = combo, nodes = list, cost = #list, estimate = gain / weight(#list), combo = true })
				end
			end
		end
		if #candidates == 0 then
			break
		end
		t_sort(candidates, function(a, b)
			if a.estimate ~= b.estimate then
				return a.estimate > b.estimate
			elseif a.cost ~= b.cost then
				return a.cost < b.cost
			end
			return a.targets[1].id < b.targets[1].id
		end)

		local best, bestRate = nil, 0
		for index = 1, m_min(#candidates, ctx.opts.treeVerify) do
			local candidate = candidates[index]
			local gain
			if candidate.cost == 1 then
				gain = value[candidate.nodes[1]]
			else
				local addNodes = { }
				for _, node in ipairs(candidate.nodes) do
					addNodes[node] = true
				end
				gain = eval(ctx, { addNodes = addNodes }) - base
			end
			local rate = gain / weight(candidate.cost)
			if rate > bestRate then
				best, bestRate = candidate, rate
			end
		end
		if not best or bestRate <= math.abs(base) * ctx.opts.epsilon then
			break
		end
		if best.combo and ctx.opts.debug then
			local names = { }
			for _, node in ipairs(best.targets) do
				t_insert(names, node.dn)
			end
			log(ctx, "      passive combination: %s", t_concat(names, " + "))
		end
		for _, node in ipairs(best.targets) do
			-- Allocation rebuilds the node tables when attribute nodes are switched, so look the node up again
			local target = spec.nodes[node.id]
			if target and not target.alloc and target.path and #target.path <= remainingPoints(ctx, ascendancy) then
				spec:AllocNode(target)
			end
		end
		steps = steps + 1
	end
	return steps
end

-- Local search on the finished tree: give back the least valuable removable branch and let the
-- greedy allocation spend the points again; keep the result only if the build got better
local function refineTree(ctx)
	local spec = ctx.build.spec
	local tried = { }
	local fails = 0
	local cur = eval(ctx)
	-- (the node that grants the main skill, and what only connects to it, is never given back)
	local pinNode = ctx.opts.pin and ctx.opts.pin.nodeId and spec.nodes[ctx.opts.pin.nodeId]
	while fails < ctx.opts.treeRefineFails do
		local worst, worstRate
		for id, node in pairs(spec.allocNodes) do
			local pinned = pinNode and (id == pinNode.id or isValueInArray(node.depends or { }, pinNode))
			if not pinned and not tried[id] and not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.depends and #node.depends > 0 and #node.depends <= 8 then
				local removeNodes = { }
				for _, depNode in ipairs(node.depends) do
					removeNodes[depNode] = true
				end
				local loss = cur - eval(ctx, { removeNodes = removeNodes })
				local rate = loss / #node.depends
				if not worstRate or rate < worstRate or (rate == worstRate and id < worst.id) then
					worst, worstRate = node, rate
				end
			end
		end
		if not worst then
			break
		end
		tried[worst.id] = true
		local state = spec:CreateUndoState()
		spec:DeallocNode(worst)
		growTree(ctx, false)
		local score = eval(ctx)
		if better(ctx, score, cur) then
			cur = score
			fails = 0
			tried = { }
		else
			spec:RestoreUndoState(state)
			fails = fails + 1
		end
	end
	sync(ctx)
	return cur
end

local function allocatedNodeIds(spec)
	local ids = { }
	for id in pairs(spec.allocNodes) do
		t_insert(ids, id)
	end
	t_sort(ids)
	return ids
end

-- Build the main tree. One greedy allocation follows a single idea of what a point is worth, so
-- the tree is built once per exponent in treeExponents, each followed by the local search, and the
-- best one is kept. Variants can be handed to worker processes; the rest are built here
local function searchTree(ctx)
	local spec = ctx.build.spec
	local exponents = { }
	for index = 1, m_min(#ctx.opts.treeExponents, m_max(ctx.opts.treeWidth, 1)) do
		t_insert(exponents, ctx.opts.treeExponents[index] * (ctx.treeScale or 1))
	end
	if #exponents <= 1 then
		ctx.treeExponent = exponents[1] or 1
		growTree(ctx, false)
		sync(ctx)
		local score = refineTree(ctx)
		ctx.treeExponent = nil
		return score
	end
	local base = spec:CreateUndoState()
	local handles = { }
	if ctx.opts.spawnWorker and ctx.opts.workers > 0 then
		local xmlText = ctx.build:SaveDB("job")
		-- The last variants go to the workers, the first ones (plain value per point first) stay here
		while #exponents > 1 and #handles < ctx.opts.workers do
			local exponent = t_remove(exponents)
			local ok, handle = pcall(ctx.opts.spawnWorker, { xml = xmlText, exponent = exponent })
			if ok and handle then
				t_insert(handles, { handle = handle, exponent = exponent })
			else
				log(ctx, "  could not start a worker (%s); building that tree here instead", tostring(handle))
				t_insert(exponents, exponent)
				break
			end
		end
	end
	local best
	for _, exponent in ipairs(exponents) do
		spec:RestoreUndoState(base)
		sync(ctx)
		ctx.treeExponent = exponent
		ctx.treeCombo, ctx.treeComboFailed = nil, nil
		growTree(ctx, false)
		sync(ctx)
		local score = refineTree(ctx)
		log(ctx, "  tree with exponent %.2f -> %.1f", exponent, score)
		if not best or better(ctx, score, best.score) then
			best = { score = score, state = spec:CreateUndoState(), exponent = exponent }
		end
	end
	ctx.treeExponent = nil
	for _, entry in ipairs(handles) do
		local ok, result = pcall(entry.handle.wait, entry.handle)
		if ok and type(result) == "table" and result.nodes and result.score then
			log(ctx, "  tree with exponent %.2f -> %.1f (worker)", entry.exponent, result.score)
			if better(ctx, result.score, best.score) then
				-- Check the worker's tree in this process before trusting its score
				local state = copyTable(base, true)
				state.hashList = result.nodes
				state.hashOverrides = { }
				spec:RestoreUndoState(state)
				sync(ctx)
				local score = eval(ctx)
				if better(ctx, score, best.score) then
					best = { score = score, state = spec:CreateUndoState(), exponent = entry.exponent }
				end
			end
		else
			log(ctx, "  worker for exponent %.2f failed: %s", entry.exponent, tostring(result))
		end
	end
	spec:RestoreUndoState(best.state)
	sync(ctx)
	return best.score
end

-- Entry point for a worker process: build one tree variant on a build that is ready for it
-- (as saved by searchTree) and return its score and the allocated node ids
function optimizer.RunTreeVariant(build, options, exponent)
	local ctx, errMsg = optimizer.NewContext(build, options)
	if not ctx then
		return nil, errMsg
	end
	sync(ctx)
	ctx.treeExponent = exponent
	growTree(ctx, false)
	sync(ctx)
	local score = refineTree(ctx)
	return score, allocatedNodeIds(build.spec)
end

local function optimizeAscendancy(ctx)
	local spec = ctx.build.spec
	if not spec.curAscendClassId or spec.curAscendClassId == 0 then
		return eval(ctx)
	end
	local before = eval(ctx)
	local state = spec:CreateUndoState()
	local hadNodes = false
	for id, node in pairs(spec.allocNodes) do
		if node.ascendancyName and node.type ~= "AscendClassStart" then
			node.alloc = false
			spec.allocNodes[id] = nil
			hadNodes = true
		end
	end
	if hadNodes then
		spec:BuildAllDependsAndPaths()
		-- the node that grants the main skill (and its path) goes back first
		local pinned = ctx.opts.pin and ctx.opts.pin.nodeId and spec.nodes[ctx.opts.pin.nodeId]
		if pinned and pinned.ascendancyName and pinned.path then
			spec:AllocNode(pinned)
		end
	end
	growTree(ctx, true)
	local score = eval(ctx)
	if hadNodes and not better(ctx, score, before) then
		spec:RestoreUndoState(state)
		score = before
	end
	sync(ctx)
	return score
end

-- Try every ascendancy of the class with its own greedy allocation and keep the best one
local function chooseAscendancy(ctx)
	local spec = ctx.build.spec
	local best, bestScore
	local ids = { }
	for id in pairs(spec.curClass.classes) do
		if id ~= 0 then
			t_insert(ids, id)
		end
	end
	t_sort(ids)
	for _, id in ipairs(ids) do
		spec:SelectAscendClass(id)
		sync(ctx)
		growTree(ctx, true)
		local score = eval(ctx)
		log(ctx, "  ascendancy %s: %.1f", spec.curAscendClassName, score)
		if not best or better(ctx, score, bestScore) then
			best, bestScore = id, score
		end
		spec:ResetNodes()
		spec:BuildAllDependsAndPaths()
	end
	if best then
		spec:SelectAscendClass(best)
		sync(ctx)
	end
end

-- Set an attribute node to Strength (1), Dexterity (2) or Intelligence (3). This does what
-- PassiveSpec:SwitchAttributeNode does, but with a shallow copy of the tree node: the deep copy
-- made there gets bigger every time a node is switched, and switching nodes as often as the
-- attribute pass does ends with copies of hundreds of megabytes
local function switchAttributeNode(spec, id, attributeIndex)
	local treeNode = spec.tree.nodes[id]
	if not treeNode or not treeNode.isAttribute then
		return
	end
	local newNode = setmetatable(copyTable(treeNode, true), getmetatable(treeNode))
	spec:ReplaceNode(newNode, newNode.options[attributeIndex])
	spec.tree:ProcessStats(newNode)
	spec.hashOverrides[id] = newNode
end

-- Meet the attribute requirements of gems and gear with the allocated attribute nodes, and point
-- the rest of them at whichever attribute does the most for the build
local function assignAttributes(ctx)
	local spec = ctx.build.spec
	local ids = { }
	for id in pairs(spec.allocNodes) do
		if spec.tree.nodes[id] and spec.tree.nodes[id].isAttribute then
			t_insert(ids, id)
		end
	end
	if #ids == 0 then
		return
	end
	t_sort(ids)
	local assignment, applied = { }, { }
	local function apply()
		for _, id in ipairs(ids) do
			if applied[id] ~= assignment[id] then
				switchAttributeNode(spec, id, assignment[id])
				applied[id] = assignment[id]
			end
		end
		spec:BuildAllDependsAndPaths()
	end
	local function setAll(attributeIndex)
		for _, id in ipairs(ids) do
			assignment[id] = attributeIndex
		end
		apply()
	end
	-- Largest shortfall and largest surplus over the requirements, as attribute indices
	local function balance(output)
		local short, shortBy, spare, spareBy
		for index, attr in ipairs(attributeNames) do
			local margin = (output[attr] or 0) - (output["Req" .. attr] or 0)
			if margin < 0 and (not short or margin < shortBy) then
				short, shortBy = index, margin
			end
			if not spare or margin > spareBy then
				spare, spareBy = index, margin
			end
		end
		return short, spare, spareBy
	end

	-- Start with every node on the attribute that scores best; ties go to the most required one
	local reference = calcOutput(ctx)
	local order = { 1, 2, 3 }
	t_sort(order, function(a, b)
		local reqA, reqB = reference["Req" .. attributeNames[a]] or 0, reference["Req" .. attributeNames[b]] or 0
		if reqA ~= reqB then
			return reqA > reqB
		end
		return a < b
	end)
	local bestIndex, bestScore
	for _, index in ipairs(order) do
		setAll(index)
		local score = eval(ctx)
		if not bestIndex or better(ctx, score, bestScore) then
			bestIndex, bestScore = index, score
		end
	end
	setAll(bestIndex)

	-- Then move nodes, one at a time, from the attribute with the most to spare to the one that is
	-- short, for as long as that doesn't open a new shortfall
	for _ = 1, #ids do
		local short, spare, spareBy = balance(calcOutput(ctx))
		if not short or spare == short or spareBy <= 0 then
			break
		end
		local moved
		for _, id in ipairs(ids) do
			if assignment[id] == spare then
				moved = id
				break
			end
		end
		if not moved then
			-- Nothing left on the attribute with the surplus; take from the other one
			for _, id in ipairs(ids) do
				if assignment[id] ~= short then
					moved = id
					break
				end
			end
			if not moved then
				break
			end
		end
		local previous = assignment[moved]
		assignment[moved] = short
		apply()
		local output = calcOutput(ctx)
		local margin = (output[attributeNames[previous]] or 0) - (output["Req" .. attributeNames[previous]] or 0)
		if margin < 0 then
			-- Would trade one unmet requirement for another
			assignment[moved] = previous
			apply()
			break
		end
	end
	sync(ctx)
end

-- Supporting skills are picked for their effect, not for what they demand. If the character can't
-- meet the attribute requirement of one of them after the attribute nodes are assigned, its gem
-- level is lowered until it can be used, and it is dropped if that isn't enough; the least
-- valuable skills (the ones added last) give way first
local function repairGemRequirements(ctx)
	local skillsTab = ctx.build.skillsTab
	local groups = skillsTab.socketGroupList
	local changed = false
	local function shortfall()
		local output = calcOutput(ctx)
		local short = { }
		local any = false
		for _, attr in ipairs(attributeNames) do
			if (output["Req" .. attr] or 0) > (output[attr] or 0) then
				short[attr] = output[attr] or 0
				any = true
			end
		end
		return any and short or nil
	end
	local short = shortfall()
	for index = #groups, 1, -1 do
		if not short then
			break
		end
		local group = groups[index]
		if isAuxGroup(ctx, group) then
			local touched = false
			for gemIndex = #group.gemList, 1, -1 do
				local gemInstance = group.gemList[gemIndex]
				local function unmet()
					for attr, have in pairs(short) do
						if (gemInstance["req" .. attr] or 0) > have then
							return true
						end
					end
				end
				while unmet() and (gemInstance.level or 1) > 1 do
					gemInstance.level = gemInstance.level - 1
					skillsTab:ProcessSocketGroup(group)
					touched = true
				end
				if unmet() then
					touched = true
					if gemIndex == 1 then
						log(ctx, "  %s removed: its attribute requirements can't be met", gemInstance.nameSpec or "skill")
						t_remove(groups, index)
						break
					else
						t_remove(group.gemList, gemIndex)
						skillsTab:ProcessSocketGroup(group)
					end
				elseif touched and gemIndex == 1 then
					log(ctx, "  %s lowered to level %d to meet its attribute requirements", gemInstance.nameSpec or "skill", gemInstance.level)
				end
			end
			if touched then
				changed = true
				sync(ctx)
				short = shortfall()
			end
		end
	end
	return changed
end

-----------------------------------------------------------------------------------------------
-- Jewels
-----------------------------------------------------------------------------------------------

local function socketNodes(ctx, allocatedOnly)
	local list = { }
	for id, node in pairs(ctx.build.spec.nodes) do
		if node.type == "Socket" and not node.charmSocket and not node.containJewelSocket and ctx.build.itemsTab.sockets[id] and (not allocatedOnly or node.alloc) then
			t_insert(list, node)
		end
	end
	t_sort(list, function(a, b)
		if (a.pathDist or 0) ~= (b.pathDist or 0) then
			return (a.pathDist or 0) < (b.pathDist or 0)
		end
		return a.id < b.id
	end)
	return list
end

local function setSocketJewel(ctx, node, item)
	local itemsTab = ctx.build.itemsTab
	local slot = itemsTab.sockets[node.id]
	local old = itemsTab.items[slot.selItemId]
	if old then
		slot:SetSelItemId(0)
		itemsTab.items[old.id] = nil
		for index, id in ipairs(itemsTab.itemOrderList) do
			if id == old.id then
				t_remove(itemsTab.itemOrderList, index)
				break
			end
		end
		countUnique(ctx, old, -1)
		old.id = nil
	end
	if item then
		item.id = nil
		itemsTab:AddItem(item, true)
		slot:SetSelItemId(item.id)
		countUnique(ctx, item, 1)
	end
end

-- Before the tree is allocated every socket gets a copy of a generic jewel crafted for this build,
-- so that jewel sockets are valued by what can be put into them
local function placeTemplateJewels(ctx)
	local sockets = socketNodes(ctx, false)
	local reference
	for _, node in ipairs(sockets) do
		if not node.alloc and node.path then
			reference = node
			break
		end
	end
	if not reference then
		return
	end
	local slotName = "Jewel " .. reference.id
	local extra = { addNodes = { [reference] = true } }
	local best, bestScore
	for _, name in ipairs(itemBaseList(ctx)) do
		local base = ctx.build.data.itemBases[name]
		if base.type == "Jewel" and base.subType == nil then
			local item = makeRare(ctx, name, "Optimised Jewel")
			if item and ctx.build.itemsTab:IsItemValidForSlot(item, slotName) then
				local score = craftAffixes(ctx, item, slotName, extra)
				if not best or better(ctx, score, bestScore) then
					best, bestScore = item, score
				end
			end
		end
	end
	if not best then
		return
	end
	local raw = best:BuildRaw()
	for _, node in ipairs(sockets) do
		if not ctx.build.itemsTab.items[ctx.build.itemsTab.sockets[node.id].selItemId] then
			setSocketJewel(ctx, node, new("Item"):Item(raw))
		end
	end
	ctx.build.itemsTab:PopulateSlots()
	sync(ctx)
	log(ctx, "  template jewel: %s", best.name)
end

-- Craft the jewel for every allocated socket in place
local function optimizeJewels(ctx, allowUniques)
	local cur = eval(ctx)
	for _, node in ipairs(socketNodes(ctx, false)) do
		if node.alloc then
			local slotName = "Jewel " .. node.id
			local item, score = bestItemForSlot(ctx, slotName, allowUniques, nil, "Optimised Jewel")
			if item and better(ctx, score, cur) then
				setSocketJewel(ctx, node, item)
				ctx.build.itemsTab:PopulateSlots()
				sync(ctx)
				cur = score
				log(ctx, "  socket %d: %s -> %.1f", node.id, item.name, cur)
			end
		end
	end
	return cur
end

-- Remove the jewels that were only placed to value sockets which ended up unallocated
local function clearUnusedSockets(ctx)
	for _, node in ipairs(socketNodes(ctx, false)) do
		if not node.alloc then
			setSocketJewel(ctx, node, nil)
		end
	end
	ctx.build.itemsTab:PopulateSlots()
	sync(ctx)
end

-----------------------------------------------------------------------------------------------
-- Second weapon set
-----------------------------------------------------------------------------------------------

-- Second weapon set. The main skill stays in set 1. A supporting skill that is assigned to set 2
-- only is cast with the weapons and weapon-set passives of that set, and its buff or debuff still
-- applies to the main skill, so set 2 can be built purely for the supporting skills:
--  1. supporting skills move to set 2 where that doesn't cost anything,
--  2. the swap weapon slots get the items that add the most,
--  3. passives that only help the main skill are turned into set 1 passives, which frees the same
--     number of points for set 2 passives that strengthen the supporting skills.
-- Everything is undone again if the build doesn't end up better
local function optimizeWeaponSets(ctx, allowUniques)
	local build = ctx.build
	local spec = build.spec
	local groups = build.skillsTab.socketGroupList
	local start = eval(ctx)
	local cur = start
	local aux = { }
	for _, group in ipairs(groups) do
		local gemData = group.gemList[1] and group.gemList[1].gemData
		-- Persistent buffs have to stay available in the set the main skill is used in, so only
		-- skills that are cast (curses, marks, offerings, ...) are candidates for set 2
		if group.enabled and isAuxGroup(ctx, group) and not isTriggerSource(group) and gemData and not gemData.tags.persistent then
			t_insert(aux, group)
		end
	end
	if #aux == 0 then
		return cur
	end
	local function inSet2(group)
		return group.set2 ~= false and group.set1 == false
	end
	local function assign(group, set)
		group.set1 = set ~= 2
		group.set2 = set ~= 1
	end
	local savedSets = { }
	for _, group in ipairs(aux) do
		savedSets[group] = { group.set1, group.set2 }
	end
	local savedMain = { ctx.group.set1, ctx.group.set2 }
	local savedSwap = { equippedItem(ctx, "Weapon 1 Swap"), equippedItem(ctx, "Weapon 2 Swap") }
	local savedTree = spec:CreateUndoState()
	assign(ctx.group, 1)

	local function moveGroups(strict)
		local moved = 0
		for _, group in ipairs(aux) do
			if not inSet2(group) then
				assign(group, 2)
				local score = eval(ctx)
				if (strict and better(ctx, score, cur)) or (not strict and score >= cur - math.abs(cur) * 1e-9) then
					cur = m_max(cur, score)
					moved = moved + 1
				else
					assign(group, nil)
				end
			end
		end
		return moved
	end
	moveGroups(false)
	local anyInSet2 = false
	for _, group in ipairs(aux) do
		anyInSet2 = anyInSet2 or inSet2(group)
	end
	if anyInSet2 then
		sync(ctx)
		for _, slotName in ipairs({ "Weapon 1 Swap", "Weapon 2 Swap" }) do
			if slotFor(ctx, slotName) then
				local item, score = bestItemForSlot(ctx, slotName, allowUniques, nil, "Optimised Swap Weapon")
				if item and better(ctx, score, cur) then
					equip(ctx, slotName, item)
					cur = score
					log(ctx, "  %s: %s -> %.1f", slotName, item.name, cur)
				end
			end
		end
		-- Skills that needed a weapon to be worth moving
		moveGroups(true)

		-- Weapon-set passives
		local limit = build.maxWeaponSets or 24
		local failed = { }
		local function convertToSet1(count)
			-- Leaves first: a normal passive may not hang off a weapon-set passive
			local converted = 0
			local progress = true
			while converted < count and progress do
				progress = false
				local ids = allocatedNodeIds(spec)
				for _, id in ipairs(ids) do
					local node = spec.allocNodes[id]
					if converted < count and node and (node.allocMode or 0) == 0 and not failed[id] and not node.ascendancyName and not node.isAttribute
					and (node.type == "Normal" or node.type == "Notable") and not node.containJewelSocket then
						local leaf = true
						for _, depNode in ipairs(node.depends or { }) do
							if depNode ~= node and depNode.allocMode ~= 1 then
								leaf = false
								break
							end
						end
						if leaf then
							node.allocMode = 1
							local score = eval(ctx)
							if score >= cur - math.abs(cur) * 1e-9 then
								converted = converted + 1
								progress = true
							else
								node.allocMode = 0
								failed[id] = true
							end
						end
					end
				end
			end
			spec:BuildAllDependsAndPaths()
			return converted
		end
		while true do
			local _, _, _, _, set1Used, set2Used = spec:CountAllocNodes()
			local room = limit - set2Used
			if room <= 0 then
				break
			end
			local base = eval(ctx)
			spec.allocMode = 2
			local cache = { }
			local candidates = { }
			for id, node in pairs(spec.nodes) do
				if isTreeCandidate(node, false) and node.modKey and node.modKey ~= "" and (node.type == "Normal" or node.type == "Notable") and not node.containJewelSocket then
					local path = spec:GetEffectiveAllocationPath(node)
					local usable = path and #path > 0 and #path <= room
					if usable then
						for _, pathNode in ipairs(path) do
							if pathNode.type == "Keystone" or pathNode.type == "Socket" or pathNode.containJewelSocket or pathNode.ascendancyName then
								usable = false
								break
							end
						end
					end
					if usable then
						if cache[node.modKey] == nil then
							node.allocMode = 2
							cache[node.modKey] = eval(ctx, { addNodes = { [node] = true } }) - base
							node.allocMode = 0
						end
						if cache[node.modKey] > 0 then
							t_insert(candidates, { node = node, path = path, estimate = cache[node.modKey] / #path })
						end
					end
				end
			end
			spec.allocMode = 0
			t_sort(candidates, function(a, b)
				if a.estimate ~= b.estimate then
					return a.estimate > b.estimate
				end
				return a.node.id < b.node.id
			end)
			local best, bestRate = nil, 0
			for index = 1, m_min(#candidates, ctx.opts.treeVerify) do
				local candidate = candidates[index]
				local addNodes = { }
				for _, pathNode in ipairs(candidate.path) do
					pathNode.allocMode = 2
					addNodes[pathNode] = true
				end
				local gain = eval(ctx, { addNodes = addNodes }) - base
				for _, pathNode in ipairs(candidate.path) do
					pathNode.allocMode = 0
				end
				if gain / #candidate.path > bestRate then
					best, bestRate = candidate, gain / #candidate.path
				end
			end
			if not best or bestRate <= math.abs(base) * ctx.opts.epsilon then
				break
			end
			-- Every set 2 point has to be matched by a passive that moves to set 1
			local needed = m_max(0, (set2Used + #best.path) - set1Used)
			local undo = spec:CreateUndoState()
			if needed > 0 and convertToSet1(needed) < needed then
				spec:RestoreUndoState(undo)
				break
			end
			local target = spec.nodes[best.node.id]
			spec.allocMode = 2
			if target and target.path then
				spec:AllocNode(target)
			end
			spec.allocMode = 0
			sync(ctx)
			local score = eval(ctx)
			if remainingPoints(ctx, false) < 0 or not better(ctx, score, cur) then
				spec:RestoreUndoState(undo)
				sync(ctx)
				break
			end
			cur = score
			if ctx.opts.debug then
				log(ctx, "      set 2 passive: %s -> %.1f", best.node.dn or "?", cur)
			end
		end
	end

	if not better(ctx, cur, start) then
		-- The second set bought nothing; leave the build as a single-set build
		for group, sets in pairs(savedSets) do
			group.set1, group.set2 = sets[1], sets[2]
		end
		ctx.group.set1, ctx.group.set2 = savedMain[1], savedMain[2]
		spec:RestoreUndoState(savedTree)
		equip(ctx, "Weapon 1 Swap", savedSwap[1])
		equip(ctx, "Weapon 2 Swap", savedSwap[2])
		sync(ctx)
		return eval(ctx)
	end
	sync(ctx)
	local _, _, _, _, set1Used, set2Used = spec:CountAllocNodes()
	log(ctx, "  second weapon set: %d passives in set 1, %d in set 2 -> %.1f", set1Used, set2Used, cur)
	return cur
end

-----------------------------------------------------------------------------------------------
-- Configuration awareness
-----------------------------------------------------------------------------------------------

-- Conditions from the Configuration tab that a build maintains simply by using its skill on an
-- enemy, each with the test that decides whether this build does. Used by assume = "sustained".
-- Deliberately short: anything that needs a kill, another player, a specific enemy or luck is
-- left to the user (--config) and only shows up in the sensitivity report
local function ailmentChance(output, name)
	return m_max(output[name .. "Chance"] or 0, output[name .. "ChanceOnHit"] or 0, (output[name .. "ChanceOnCrit"] or 0) * (output.CritChance or 0) / 100)
end

optimizer.sustainedConditions = {
	{ var = "conditionEnemyShocked", why = "shock chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Shock") >= 20 end },
	{ var = "conditionEnemyIgnited", why = "ignite chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Ignite") >= 20 end },
	{ var = "conditionEnemyChilled", why = "chill chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Chill") >= 20 end },
	{ var = "conditionEnemyBleeding", why = "bleed chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Bleed") >= 20 end },
	{ var = "conditionEnemyPoisoned", why = "poison chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Poison") >= 20 end },
	{ var = "conditionCritRecently", why = "critical hit chance of 20% or more", when = function(output) return (output.CritChance or 0) >= 20 end },
	{ var = "conditionSkillCritRecently", why = "critical hit chance of 20% or more", when = function(output) return (output.CritChance or 0) >= 20 end },
	{ var = "conditionNonCritRecently", why = "critical hit chance of 80% or less", when = function(output) return (output.CritChance or 0) <= 80 end },
	{ var = "conditionHitRecently", why = "the skill hits", when = function(output) return (output.TotalDPS or 0) > 0 end },
	{ var = "conditionUsedSkillRecently", why = "the skill is used continuously", when = function() return true end },
	{ var = "conditionShockedEnemyRecently", why = "shock chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Shock") >= 20 end },
	{ var = "conditionIgnitedEnemyRecently", why = "ignite chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Ignite") >= 20 end },
	{ var = "conditionChilledEnemyRecently", why = "chill chance of 20% or more per hit", when = function(output) return ailmentChance(output, "Chill") >= 20 end },
}

local configOptionList
local function configOptions()
	if not configOptionList then
		configOptionList = { }
		local section = ""
		for _, option in ipairs(LoadModule("Modules/ConfigOptions")) do
			if option.section then
				section = option.section
			end
			if option.var then
				t_insert(configOptionList, { var = option.var, type = option.type, label = option.label, section = section,
					hasDefault = option.defaultState ~= nil or option.defaultPlaceholderState ~= nil })
			end
		end
	end
	return configOptionList
end

local function plainLabel(label)
	if type(label) ~= "string" then
		return ""
	end
	return (label:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end

local function setConfig(ctx, var, value)
	ctx.build.configTab.input[var] = value
	ctx.build.configTab:BuildModList()
end

-- How much every yes/no option of the Configuration tab would change the score if it were flipped.
-- Returns a list of { var, label, section, enabled, change } (change is relative), largest first
local function configSensitivity(ctx)
	local input = ctx.build.configTab.input
	local base = eval(ctx)
	local list = { }
	if base <= 0 then
		return list
	end
	for _, option in ipairs(configOptions()) do
		if option.type == "check" then
			local old = input[option.var]
			input[option.var] = not old
			ctx.build.configTab:BuildModList()
			local score = eval(ctx)
			input[option.var] = old
			if score >= 0 and math.abs(score - base) > base * 0.002 then
				t_insert(list, { var = option.var, label = plainLabel(option.label), section = option.section, enabled = old and true or false, change = score / base - 1 })
			end
		elseif option.type == "count" and (input[option.var] or 0) == 0 and option.var:match("^multiplier") and not option.hasDefault then
			-- Only plain "how many" counters that start at zero: for overrides, distances and
			-- options with a default, 1/5/10 isn't "more of it" and the result would mislead
			local old = input[option.var]
			local counts = { }
			local valid = true
			for _, n in ipairs({ 1, 5, 10 }) do
				input[option.var] = n
				ctx.build.configTab:BuildModList()
				local score = eval(ctx)
				valid = valid and score >= 0
				counts[n] = score / base - 1
			end
			input[option.var] = old
			if valid and math.abs(counts[1]) > 0.002 then
				t_insert(list, { var = option.var, label = plainLabel(option.label), section = option.section, enabled = false, change = counts[10], counts = counts })
			end
		end
	end
	ctx.build.configTab:BuildModList()
	t_sort(list, function(a, b)
		if a.change ~= b.change then
			return a.change > b.change
		end
		return a.var < b.var
	end)
	return list
end

-- Switch on the conditions the build keeps up by itself (or the ones the user named), keeping
-- only those that raise the score. Returns true if anything was switched on
local function applyAssumptions(ctx)
	local assume = ctx.opts.assume
	if not assume or assume == "none" then
		return false
	end
	local input = ctx.build.configTab.input
	local known = { }
	for _, option in ipairs(configOptions()) do
		known[option.var] = option
	end
	local candidates = { }
	if assume == "sustained" then
		local output = calcOutput(ctx)
		local detail = output.Minion or output
		for _, entry in ipairs(optimizer.sustainedConditions) do
			if known[entry.var] and (entry.when(output) or entry.when(detail)) then
				t_insert(candidates, { var = entry.var, why = entry.why })
			end
		end
	elseif type(assume) == "table" then
		for _, var in ipairs(assume) do
			if known[var] then
				t_insert(candidates, { var = var, why = "requested" })
			else
				log(ctx, "  unknown configuration option '%s' ignored", tostring(var))
			end
		end
	end
	local changed = false
	local cur = eval(ctx)
	for _, entry in ipairs(candidates) do
		if not input[entry.var] then
			setConfig(ctx, entry.var, true)
			local score = eval(ctx)
			if better(ctx, score, cur) then
				ctx.assumed[entry.var] = { label = plainLabel(known[entry.var].label), why = entry.why, change = cur > 0 and (score / cur - 1) or 0 }
				log(ctx, "  assuming \"%s\" (%s): %+.1f%%", ctx.assumed[entry.var].label, entry.why, ctx.assumed[entry.var].change * 100)
				cur = score
				changed = true
			else
				setConfig(ctx, entry.var, nil)
			end
		end
	end
	if changed then
		sync(ctx)
	end
	return changed
end

-----------------------------------------------------------------------------------------------
-- Coverage: what the calculation engine doesn't understand
-----------------------------------------------------------------------------------------------

local function lineUnsupported(modLine)
	if modLine.extra then
		return true
	end
	return (not modLine.modList or #modLine.modList == 0) and not (modLine.line or ""):match("^Grants Skill")
end

local function unmappedGemStats(grantedEffect)
	local missing = { }
	local seen = { }
	for _, statSet in ipairs(grantedEffect.statSets or { }) do
		local function check(name)
			if type(name) == "string" and not seen[name] and not (statSet.statMap and statSet.statMap[name]) and not (data.skillStatMap and data.skillStatMap[name]) and not (data.skillStatNoCalc and data.skillStatNoCalc[name]) then
				seen[name] = true
				t_insert(missing, name)
			end
		end
		for _, name in ipairs(statSet.stats or { }) do
			check(name)
		end
		for _, entry in ipairs(statSet.constantStats or { }) do
			-- A constant of 0 changes nothing, mapped or not
			if entry[2] ~= 0 then
				check(entry[1])
			end
		end
	end
	t_sort(missing)
	return missing
end

-- Text report of the modifiers in the program's data that the calculation engine can't read, i.e.
-- that are worth nothing to the optimizer no matter how strong they are in the game. With a build,
-- the unsupported parts of that build are listed first
function optimizer.CoverageReport(build)
	local lines = { }
	local function add(fmt, ...)
		t_insert(lines, s_format(fmt, ...))
	end
	if build and build.spec then
		add("== Parts of this build the engine does not calculate ==")
		local any = false
		for _, slot in ipairs(build.itemsTab.orderedSlots) do
			local item = build.itemsTab.items[slot.selItemId]
			local node = slot.nodeId and build.spec.nodes[slot.nodeId]
			if item and (not slot.nodeId or (node and node.alloc)) then
				for _, list in ipairs({ item.runeModLines, item.implicitModLines, item.explicitModLines }) do
					for _, modLine in ipairs(list or { }) do
						if item:CheckModLineVariant(modLine) and lineUnsupported(modLine) then
							add("%s (%s): %s", slot.slotName, item.name, modLine.line or "")
							any = true
						end
					end
				end
			end
		end
		local nodes = { }
		for _, node in pairs(build.spec.allocNodes) do
			if (node.unknown or node.extra) and node.sd and #node.sd > 0 then
				t_insert(nodes, s_format("Passive %s: %s", node.dn or "?", t_concat(node.sd, " / ")))
			end
		end
		t_sort(nodes)
		for _, text in ipairs(nodes) do
			add("%s", text)
			any = true
		end
		for _, group in ipairs(build.skillsTab.socketGroupList) do
			if group.enabled then
				for _, gemInstance in ipairs(group.gemList) do
					local grantedEffect = gemInstance.gemData and gemInstance.gemData.grantedEffect
					-- Active skills carry many cosmetic stats; for supports a missing stat is usually a missing effect
					local missing = grantedEffect and grantedEffect.support and unmappedGemStats(grantedEffect) or { }
					if #missing > 0 then
						add("Gem %s: %d stats without a calculation (%s%s)", gemInstance.nameSpec or "?", #missing, t_concat(missing, ", ", 1, m_min(#missing, 4)), #missing > 4 and ", ..." or "")
						any = true
					end
				end
			end
		end
		if not any then
			add("-")
		end
		add("")
	end

	add("== Coverage of the program's data (entries with at least one modifier the engine can't read) ==")
	if build and build.spec then
		local counts = { }
		for _, node in pairs(build.spec.tree.nodes) do
			if node.sd and #node.sd > 0 then
				local kind = node.ascendancyName and "Ascendancy passives" or node.type == "Keystone" and "Keystones" or node.type == "Notable" and "Notables" or node.type == "Normal" and "Small passives" or nil
				if kind then
					counts[kind] = counts[kind] or { 0, 0 }
					counts[kind][1] = counts[kind][1] + 1
					if node.unknown or node.extra then
						counts[kind][2] = counts[kind][2] + 1
					end
				end
			end
		end
		for _, kind in ipairs({ "Keystones", "Ascendancy passives", "Notables", "Small passives" }) do
			if counts[kind] then
				add("%-28s %5d of %5d (%2.0f%%)", kind, counts[kind][2], counts[kind][1], counts[kind][2] / counts[kind][1] * 100)
			end
		end
	end
	if main.uniqueDB and main.uniqueDB.list then
		local items, affected = 0, 0
		for _, item in pairs(main.uniqueDB.list) do
			items = items + 1
			local any = false
			for _, list in ipairs({ item.implicitModLines, item.explicitModLines }) do
				for _, modLine in ipairs(list or { }) do
					if lineUnsupported(modLine) then
						any = true
					end
				end
			end
			if any then
				affected = affected + 1
			end
		end
		add("%-28s %5d of %5d (%2.0f%%)", "Unique items", affected, items, items > 0 and affected / items * 100 or 0)
	end
	for _, entry in ipairs({ { "Item", "Item affixes" }, { "Jewel", "Jewel affixes" }, { "Flask", "Flask affixes" }, { "Charm", "Charm affixes" }, { "Desecrated", "Desecrated affixes" }, { "Corruption", "Corruption modifiers" } }) do
		local total, bad = 0, 0
		for _, mod in pairs(data.itemMods[entry[1]] or { }) do
			total = total + 1
			for _, line in ipairs(mod) do
				local list, extra = modLib.parseMod(itemLib.applyRange(line, 1))
				if not list or extra then
					bad = bad + 1
					break
				end
			end
		end
		if total > 0 then
			add("%-28s %5d of %5d (%2.0f%%)", entry[2], bad, total, bad / total * 100)
		end
	end
	do
		local total, bad = 0, 0
		for _, rune in pairs(data.itemMods.Runes or { }) do
			for _, mod in pairs(rune) do
				total = total + 1
				for _, line in ipairs(mod) do
					local list, extra = modLib.parseMod(line)
					if not list or extra then
						bad = bad + 1
						break
					end
				end
			end
		end
		add("%-28s %5d of %5d (%2.0f%%)", "Rune / soul core effects", bad, total, total > 0 and bad / total * 100 or 0)
	end
	do
		local skills, skillsBad, supports, supportsBad = 0, 0, 0, 0
		for _, gemData in pairs(data.gems) do
			local grantedEffect = gemData.grantedEffect
			if not grantedEffect.fromItem and not grantedEffect.fromTree then
				local missing = #unmappedGemStats(grantedEffect) > 0
				if grantedEffect.support then
					supports = supports + 1
					supportsBad = supportsBad + (missing and 1 or 0)
				else
					skills = skills + 1
					skillsBad = skillsBad + (missing and 1 or 0)
				end
			end
		end
		add("%-28s %5d of %5d (%2.0f%%)  (a stat without a calculation; many of these are cosmetic)", "Skill gems", skillsBad, skills, skills > 0 and skillsBad / skills * 100 or 0)
		add("%-28s %5d of %5d (%2.0f%%)  (same)", "Support gems", supportsBad, supports, supports > 0 and supportsBad / supports * 100 or 0)
	end
	return t_concat(lines, "\n")
end

-- Strong-looking uniques, passives and support gems that carry something the engine can't read, so
-- the optimizer valued them by their readable part only. Leaves the build as it found it
function optimizer.BlindSpotReport(build, options)
	local ctx = optimizer.NewContext(build, options); if not ctx then return "" end
	local lines = { }
	local function add(fmt, ...)
		t_insert(lines, s_format(fmt, ...))
	end
	add("== Strong options the engine could not fully evaluate ==")
	local any = false
	local cur = eval(ctx)

	-- A line is worth showing if it reads like it concerns damage or the main skill
	local words = { "damage", "critical", "speed", "penetrat", "more ", "exposure", "extra" }
	if ctx.opts.survivability > 0 then
		for _, word in ipairs({ "life", "energy shield", "armour", "evasion", "resist", "block", "taken", "recover", "regenerat", "leech" }) do
			t_insert(words, word)
		end
	end
	local mainGem = ctx.group.gemList[1].gemData
	for tag in pairs(mainGem and mainGem.tags or { }) do
		if type(tag) == "string" and #tag >= 4 and tag ~= "grants_active_skill" and tag ~= "support" then
			t_insert(words, tag)
		end
	end
	local function isRelevant(text)
		text = text:lower()
		for _, word in ipairs(words) do
			if text:find(word, 1, true) then
				return true
			end
		end
		return false
	end

	-- Unique items
	local kept = { }
	local seenUnique = { }
	local slots = { "Weapon 1", "Weapon 2" }
	for _, slotName in ipairs(gearSlots) do
		if slotAvailable(ctx, slotName) then
			t_insert(slots, slotName)
		end
	end
	if cur > 0 then
		for _, slotName in ipairs(slots) do
			local equipped = equippedItem(ctx, slotName)
			for _, item in ipairs(uniquesForSlot(ctx, slotName)) do
				local unsupported = { }
				for _, list in ipairs({ item.implicitModLines, item.explicitModLines }) do
					for _, modLine in ipairs(list or { }) do
						if item:CheckModLineVariant(modLine) and lineUnsupported(modLine) and isRelevant(modLine.line or "") then
							t_insert(unsupported, modLine.line or "")
						end
					end
				end
				if #unsupported > 0 and not seenUnique[item.title] and not (equipped and equipped.title == item.title) then
					local score = evalItem(ctx, slotName, item)
					if score >= cur * 0.75 then
						seenUnique[item.title] = true
						t_insert(kept, { slot = slotName, item = item, ratio = score / cur, lines = unsupported })
					end
				end
			end
		end
	end
	t_sort(kept, function(a, b)
		if a.ratio ~= b.ratio then
			return a.ratio > b.ratio
		end
		return a.slot .. a.item.name < b.slot .. b.item.name
	end)
	for index = 1, m_min(#kept, 12) do
		local entry = kept[index]
		add("%s: %s — readable part alone: %+.1f%% vs current", entry.slot, entry.item.name, (entry.ratio - 1) * 100)
		for _, text in ipairs(entry.lines) do
			add("      %s", text)
		end
		any = true
	end

	-- Passives
	local nodes = { }
	if cur > 0 then
		for _, node in pairs(build.spec.nodes) do
			if (isTreeCandidate(node, false) or isTreeCandidate(node, true)) and (node.unknown or node.extra) and node.sd and #node.sd > 0
			and (node.type == "Notable" or node.type == "Keystone" or node.ascendancyName) and node.pathDist <= 8 then
				local relevant = false
				for _, text in ipairs(node.sd) do
					relevant = relevant or isRelevant(text)
				end
				if relevant then
					t_insert(nodes, node)
				end
			end
		end
	end
	t_sort(nodes, function(a, b)
		if a.pathDist ~= b.pathDist then
			return a.pathDist < b.pathDist
		end
		return a.id < b.id
	end)
	for index = 1, m_min(#nodes, 15) do
		local node = nodes[index]
		local gain = eval(ctx, { addNodes = { [node] = true } }) - cur
		add("%s (%s, %d points away) — readable part: %+.1f%%", node.dn or "?", node.ascendancyName or node.type, node.pathDist, gain / cur * 100)
		for _, text in ipairs(node.sd) do
			add("      %s", text)
		end
		any = true
	end

	-- Support gems
	local gems = { }
	if cur > 0 then
		local linked = { }
		for _, gemInstance in ipairs(ctx.group.gemList) do
			if gemInstance.gemData and gemInstance.gemData.grantedEffect and gemInstance.gemData.grantedEffect.support then
				t_insert(linked, gemInstance.gemData.grantedEffect)
			end
		end
		for _, gemData in ipairs(supportCandidates(ctx)) do
			local fresh = #unmappedGemStats(gemData.grantedEffect) > 0
			for _, other in ipairs(linked) do
				fresh = fresh and not sharesFamily(gemData.grantedEffect, other)
			end
			if fresh then
				t_insert(ctx.group.gemList, makeGemInstance(ctx, gemData))
				local score = eval(ctx)
				t_remove(ctx.group.gemList)
				if score >= cur * 0.97 then
					t_insert(gems, { gemData = gemData, score = score })
				end
			end
		end
	end
	t_sort(gems, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.gemData.id < b.gemData.id
	end)
	for index = 1, m_min(#gems, 8) do
		local gemData = gems[index].gemData
		local missing = unmappedGemStats(gemData.grantedEffect)
		add("%s — readable part as a sixth link: %+.1f%%; stats without a calculation: %s", gemData.name, (gems[index].score / cur - 1) * 100, t_concat(missing, ", ", 1, m_min(#missing, 3)))
		any = true
	end

	if not any then
		add("-")
	end
	return t_concat(lines, "\n")
end

-- Text report of the configuration the build was scored with: the conditions that were assumed,
-- and what every other yes/no condition would be worth
function optimizer.ConfigReport(build, options)
	local ctx = optimizer.NewContext(build, options)
	if not ctx then
		return ""
	end
	local lines = { }
	local function add(fmt, ...)
		t_insert(lines, s_format(fmt, ...))
	end
	local sensitivity = configSensitivity(ctx)
	local input = build.configTab.input
	-- With survivability in the score, a condition is worth what it does to damage and EHP together
	local what = ctx.opts.survivability > 0 and "score" or "damage"
	add("== Configuration ==")
	add("Approximations: %s   [useApproximations]", input.useApproximations and s_format("on, %s kills per second [approxKillsPerSecond]", tostring(input.approxKillsPerSecond or 1)) or "off")
	add("Recovery in the survivability score: %s", ctx.opts.survivability > 0 and ctx.opts.recoveryHorizon > 0 and s_format("on, %g seconds of recovery [recoveryHorizon]", ctx.opts.recoveryHorizon) or "off")
	local on = { }
	for _, entry in ipairs(sensitivity) do
		if entry.enabled then
			t_insert(on, entry)
		end
	end
	if #on > 0 then
		add("Assumed conditions (the build was scored with these on; without one, the %s changes by):", what)
		for _, entry in ipairs(on) do
			add("  %-52s %+6.1f%%   [%s]", entry.label, entry.change * 100, entry.var)
		end
	else
		add("No conditions are assumed beyond the defaults of a new build.")
	end
	local shown = 0
	for _, entry in ipairs(sensitivity) do
		if not entry.enabled and entry.change > 0 then
			if shown == 0 then
				add("Conditions that would raise the %s if you can keep them up (--config <name>=true, or <name>=<number> for counts):", what)
			end
			shown = shown + 1
			if shown <= 15 then
				if entry.counts then
					add("  %-52s %+.1f%% at 1, %+.1f%% at 5, %+.1f%% at 10   [%s]", entry.label, entry.counts[1] * 100, entry.counts[5] * 100, entry.counts[10] * 100, entry.var)
				else
					add("  %-52s %+6.1f%%   [%s]", entry.label, entry.change * 100, entry.var)
				end
			end
		end
	end
	return t_concat(lines, "\n")
end

-----------------------------------------------------------------------------------------------
-- Driver
-----------------------------------------------------------------------------------------------

local function newContext(build, options)
	local opts = { }
	for key, value in pairs(optimizer.defaultOptions) do
		opts[key] = value
	end
	for key, value in pairs(options or { }) do
		opts[key] = value
	end
	opts.survivability = m_max(0, m_min(1, tonumber(opts.survivability) or 0))
	opts.recoveryHorizon = m_max(0, tonumber(opts.recoveryHorizon) or 0)
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if not group or not group.gemList[1] then
		return nil, "The build has no main skill"
	end
	return {
		build = build,
		opts = opts,
		calcs = build.calcsTab.calcs,
		group = group,
		evals = 0,
		errors = 0,
		uniqueCount = { },
		assumed = { },
		-- The effective hit pool is only calculated when it is part of the score
		skipEHP = not (opts.survivability > 0),
	}
end
optimizer.NewContext = newContext
optimizer.CalcOutput = calcOutput -- for specs: one evaluation with an override

local function gearStep(ctx, round, allowUniques)
	local score
	log(ctx, "[round %d] equipment%s", round, allowUniques and " (uniques allowed)" or "")
	score = optimizeGear(ctx, allowUniques)
	if allowUniques and ctx.opts.combos and round == 1 then
		score = optimizeUniquePairs(ctx)
	end
	if ctx.opts.flasks then
		score = optimizeUtility(ctx, allowUniques)
	end
	log(ctx, "  -> %.1f", score)
end

local function treeStep(ctx, round)
	local spec = ctx.build.spec
	local score
	log(ctx, "[round %d] passive tree", round)
	local used = spec:CountAllocNodes()
	if spec.curAscendClassId == 0 and ctx.autoAscendancy and used == 0 then
		chooseAscendancy(ctx)
	end
	ctx.treeComboFailed = nil
	optimizeAscendancy(ctx)
	placeTemplateJewels(ctx)
	if used == 0 then
		-- A fresh tree gets the wide search; an existing one is only refined
		score = searchTree(ctx)
	else
		growTree(ctx, false)
		sync(ctx)
		score = refineTree(ctx)
	end
	log(ctx, "  -> %.1f", score)
end

-- Meta skills trigger the Spell that is socketed in their group, and the optimiser only filled support sockets: such a main skill had no
-- damage. Try every Spell that can be triggered as that Spell (the engine rejects the ones a meta skill can't trigger with a score of 0),
-- socket the best one at index 2 and select it as the group's active skill, so that the supports found next support it. Then more
-- Spells are added while the group's Full DPS rises (the Energy they need is summed: the engine gives a group that needs more than the
-- meta skill can hold no triggers, and a Spell that costs more Energy than it adds damage lowers the rate of the others), at most
-- opts.maxMetaSpells. A group with one Spell is scored by the selected skill as before; with several, by the group's Full DPS
-- (addGroupTotal), which the group's "Include in Full DPS" shows in the program too
local function optimizeMetaSpell(ctx)
	local group = ctx.group
	local meta = group.displaySkillList and group.displaySkillList[1]
	if not (meta and meta.activeEffect.grantedEffect.skillTypes[SkillType.Meta]) then
		return
	end
	local gemList = group.gemList
	local function select(skillId)
		for index, skill in ipairs(group.displaySkillList) do
			if skill.activeEffect.grantedEffect.id == skillId then
				group.mainActiveSkill, group.mainActiveSkillCalcs = index, index
				return
			end
		end
	end
	local build = ctx.build
	local candidates = { }
	for _, gemData in pairs(build.data.gems) do
		local grantedEffect = gemData.grantedEffect
		local types = grantedEffect and grantedEffect.skillTypes
		if types and not grantedEffect.support and not grantedEffect.fromItem and not grantedEffect.fromTree and not grantedEffect.hideFromSideBar
			and types[SkillType.Spell] and types[SkillType.Triggerable] and not types[SkillType.Meta]
			and (grantedEffect.levels and grantedEffect.levels[1] and grantedEffect.levels[1].levelRequirement or 1) <= build.characterLevel then
			t_insert(candidates, gemData)
		end
	end
	t_sort(candidates, function(a, b) return a.id < b.id end)
	-- more Spells: the group's Full DPS decides; one Spell is scored by the selected skill
	local function addSpells()
		local function show()
			build.skillsTab:ProcessSocketGroup(group)
			build.buildFlag = true
			runCallback("OnFrame")
			select(gemList[2].skillId)
		end
		if metaSpellCount(group) >= ctx.opts.maxMetaSpells then
			return
		end
		local added = false
		group.includeInFullDPS = true
		local cur = eval(ctx)
		while metaSpellCount(group) < ctx.opts.maxMetaSpells do
			local at = metaSpellCount(group) + 2
			local taken = { }
			for index = 2, at - 1 do
				taken[gemList[index].gemData] = true
			end
			local best, bestScore = nil, cur
			for _, gemData in ipairs(candidates) do
				if not taken[gemData] then
					t_insert(gemList, at, makeGemInstance(ctx, gemData))
					local score = eval(ctx)
					t_remove(gemList, at)
					if better(ctx, score, bestScore) then
						best, bestScore = gemData, score
					end
				end
			end
			if not best then
				break
			end
			t_insert(gemList, at, makeGemInstance(ctx, best))
			cur, added = bestScore, true
			log(ctx, "  + %s as a second Spell of %s: group Full DPS %.1f", best.name, gemList[1].nameSpec or "the meta skill", cur)
		end
		group.includeInFullDPS = (added or metaSpellCount(group) > 1) or nil
		show()
	end
	if metaSpellCount(group) > 0 then
		select(gemList[2].skillId)
		addSpells()
		sync(ctx)
		return
	elseif #gemList > 1 then
		return
	end
	local best, bestScore = nil, 0
	for _, gemData in ipairs(candidates) do
		gemList[2] = makeGemInstance(ctx, gemData)
		build.skillsTab:ProcessSocketGroup(group)
		-- (the group's skill list has the new gem after a frame only)
		build.buildFlag = true
		runCallback("OnFrame")
		select(gemData.grantedEffectId)
		local score = eval(ctx)
		if score > bestScore then
			best, bestScore = gemData, score
		end
	end
	gemList[2] = best and makeGemInstance(ctx, best) or nil
	build.skillsTab:ProcessSocketGroup(group)
	if best then
		select(best.grantedEffectId)
		log(ctx, "  %s triggers %s: %.1f", gemList[1].nameSpec or "the meta skill", best.name, bestScore)
		addSpells()
	else
		group.mainActiveSkill, group.mainActiveSkillCalcs = 1, 1
	end
	sync(ctx)
end

-- A skill that a passive node or an item triggers on an event of the whole build (Elemental Storm: Critical Hits with Spells) has a
-- rule with a `source` in CalcTriggers.lua (supportTriggerEvents): the source is any skill of the build that the rule accepts. The
-- optimiser built around the triggered skill alone, so the build had no source and the skill never triggered. This adds a socket
-- group for the source: every gem the rule's `source` filter accepts is tried in it and scored by the MAIN skill, the best stays and
-- gets its supports like an auxiliary skill (supportAuxGroup, the main skill's score decides). A candidate only counts when it raises
-- the trigger rate (Speed of the triggered skill): a curse or an aura raises the score without being a source, and the auxiliary
-- step is the one to add those. A tie goes to the higher rate, because a skill whose damage doesn't depend on the rate yet scores the
-- same with every source.
-- The group is marked (triggerSource, and its label, which a saved build keeps) so the auxiliary and weapon set steps leave it alone.
-- ponytail: one source skill, the rule's filter is applied to the gem's skill types only (the calculation rejects one without hits);
-- upgrade path = a second source for a rule with two events, supports chosen for the trigger rate while the score doesn't depend on it
local function optimizeTriggerSource(ctx)
	local build = ctx.build
	local groups = build.skillsTab.socketGroupList
	for index = #groups, 1, -1 do
		if isTriggerSource(groups[index]) then
			t_remove(groups, index)
		end
	end
	-- (the rules only run with Use approximations on)
	if not build.configTab.input.useApproximations or ctx.opts.maxSkills < 2 then
		return
	end
	sync(ctx)
	local ok, _, env = pcall(calcOutput, ctx)
	local skillData = ok and env.player.mainSkill and env.player.mainSkill.skillData
	local rule
	for _, candidate in ipairs(ctx.calcs.supportTriggerEvents or { }) do
		if candidate.source and skillData and skillData[candidate.key] then
			rule = candidate
			break
		end
	end
	if not rule then
		return
	end
	local cur = eval(ctx)
	local curRate = ctx.lastOutput and ctx.lastOutput.Speed or 0
	local best, bestScore, bestRate = nil, 0, 0
	local group = { label = triggerSourceLabel, triggerSource = true, enabled = true, gemList = { } }
	t_insert(groups, group)
	local candidates = { }
	for _, gemData in pairs(build.data.gems) do
		local grantedEffect = gemData.grantedEffect
		local types = grantedEffect and grantedEffect.skillTypes
		if types and not grantedEffect.support and not grantedEffect.fromItem and not grantedEffect.fromTree and not grantedEffect.hideFromSideBar
			and not types[SkillType.Meta] and not types[SkillType.Triggered] and not types[SkillType.InbuiltTrigger] and not grantedEffect.triggered
			and (grantedEffect.levels and grantedEffect.levels[1] and grantedEffect.levels[1].levelRequirement or 1) <= build.characterLevel
			and rule.source({ skillTypes = types }, { hit = true }) then
			t_insert(candidates, gemData)
		end
	end
	t_sort(candidates, function(a, b) return a.id < b.id end)
	for _, gemData in ipairs(candidates) do
		group.gemList[1] = makeGemInstance(ctx, gemData)
		local score = eval(ctx)
		local rate = ctx.lastOutput and ctx.lastOutput.Speed or 0
		if rate > curRate * (1 + 1e-9) and not better(ctx, cur, score)
			and (better(ctx, score, bestScore) or (not better(ctx, bestScore, score) and rate > bestRate * (1 + 1e-9))) then
			best, bestScore, bestRate = gemData, score, rate
		end
	end
	if best then
		group.gemList[1] = makeGemInstance(ctx, best)
		build.skillsTab:ProcessSocketGroup(group)
		local score = supportAuxGroup(ctx, group, bestScore)
		log(ctx, "  %s is the source of %s's trigger (%s): %.1f", best.name, ctx.group.gemList[1].nameSpec or "the main skill", rule.name, score)
	else
		t_remove(groups)
	end
	sync(ctx)
end

-- A skill with several stat sets calculates the one that is selected (the program's "Stat set" choice, shown one at a time). When the
-- selected set deals nothing, the best of the others is selected: Volatile Dead's first set is the skill, its damage is in "Explosion"
-- and "Core". A set that already deals damage is left alone (the first one, unless the build says otherwise)
local function chooseStatSet(ctx)
	local group = ctx.group
	local active = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local effect = active and active.activeEffect
	local statSets = effect and effect.srcInstance and effect.grantedEffect.statSets
	if not statSets or #statSets < 2 or eval(ctx) > 0 then
		return
	end
	local instance, id = effect.srcInstance, effect.grantedEffect.id
	instance.statSet, instance.statSetCalcs = instance.statSet or { }, instance.statSetCalcs or { }
	local first = instance.statSet[id] or 1
	local best, bestScore = first, 0
	for index = 1, #statSets do
		instance.statSet[id], instance.statSetCalcs[id] = index, index
		local score = eval(ctx)
		if score > bestScore then
			best, bestScore = index, score
		end
	end
	instance.statSet[id], instance.statSetCalcs[id] = best, best
	if best ~= first then
		log(ctx, "  stat set \"%s\": %.1f (the selected one dealt nothing)", statSets[best].label or tostring(best), bestScore)
	end
	sync(ctx)
end

-- A skill that deals no damage itself but triggers the skills granted with it (The Stars Answer: Starfall, Apocalypse: three disasters,
-- Archon of Chayula: Chayula's Will, with Use approximations on the engine gives them a rate) has its damage in the group's other active
-- skills. When the selected skill deals nothing, select the group's best one; if none deals damage yet (an Attack without a weapon),
-- the first triggered one, so that the weapon step has something to compare. A skill that deals damage stays selected
local function chooseGroupSkill(ctx)
	local group = ctx.group
	local list = group.displaySkillList
	-- (a meta skill's group is handled by optimizeMetaSpell)
	if not list or #list < 2 or list[1].activeEffect.grantedEffect.skillTypes[SkillType.Meta] or eval(ctx) > 0 then
		return
	end
	local first = group.mainActiveSkill or 1
	local best, bestScore, triggered = first, 0, nil
	for index, skill in ipairs(list) do
		if index ~= first then
			group.mainActiveSkill, group.mainActiveSkillCalcs = index, index
			local score = eval(ctx)
			if score > bestScore then
				best, bestScore = index, score
			end
			triggered = triggered or skill.activeEffect.grantedEffect.skillTypes[SkillType.Triggered] and index or nil
		end
	end
	best = bestScore > 0 and best or triggered or first
	group.mainActiveSkill, group.mainActiveSkillCalcs = best, best
	if best ~= first then
		log(ctx, "  %s: %.1f (the selected skill dealt nothing)", list[best].activeEffect.grantedEffect.name, bestScore)
	end
	sync(ctx)
end

local function runRound(ctx, round, allowUniques)
	local score
	optimizeMetaSpell(ctx)
	if eval(ctx) <= 0 then
		chooseGroupSkill(ctx)
		-- Attacks do nothing without a weapon, so supports can't be compared before one is equipped
		log(ctx, "[round %d] weapons", round)
		optimizeWeapons(ctx, allowUniques)
		chooseGroupSkill(ctx)
		chooseStatSet(ctx)
	end
	optimizeTriggerSource(ctx)
	log(ctx, "[round %d] support gems", round)
	ctx.multiStart = round == 1
	if ctx.group.noSupports then
		log(ctx, "  the main skill can't be supported")
		score = eval(ctx)
	else
		score = optimizeSupports(ctx)
	end
	log(ctx, "  -> %.1f", score)

	if ctx.opts.auxSkills then
		log(ctx, "[round %d] auras, curses, marks and other supporting skills", round)
		score = optimizeAuxSkills(ctx)
		log(ctx, "  -> %.1f", score)
	end

	if ctx.treeFirst and round == 1 then
		treeStep(ctx, round)
		gearStep(ctx, round, allowUniques)
	else
		gearStep(ctx, round, allowUniques)
		treeStep(ctx, round)
	end

	log(ctx, "[round %d] jewels", round)
	score = optimizeJewels(ctx, allowUniques)
	if ctx.opts.weaponSets then
		log(ctx, "[round %d] second weapon set", round)
		score = optimizeWeaponSets(ctx, allowUniques)
		log(ctx, "  -> %.1f", score)
	end
	assignAttributes(ctx)
	if repairGemRequirements(ctx) then
		-- Lower requirements free attribute nodes for something better
		assignAttributes(ctx)
	end
	score = eval(ctx)
	log(ctx, "  -> %.1f", score)
	return score
end

-- A context for searching the build as it is now; perturb > 0 picks another path (see restarts)
local function startContext(build, options, perturb)
	local ctx, errMsg = newContext(build, options)
	if not ctx then
		return nil, errMsg
	end
	ctx.autoAscendancy = options and options.autoAscendancy
	ctx.treeFirst = perturb % 2 == 1
	ctx.treeScale = 1 - 0.05 * perturb
	if ctx.opts.approximations then
		-- Set in the build's Configuration tab, so the saved build is calculated the same way
		build.configTab.input.useApproximations = true
		setConfig(ctx, "approxKillsPerSecond", ctx.opts.killsPerSecond)
	end
	ctx.allowUniques = options and options.allowUniques or false
	for _, item in pairs(build.itemsTab.items) do
		for _, slot in pairs(build.itemsTab.slots) do
			if slot.selItemId == item.id then
				countUnique(ctx, item, 1)
			end
		end
	end
	sync(ctx)
	return ctx
end

-- Go back to a build saved with SaveDB. The build object stays the same, its tabs are made anew, so
-- a context has to be started again afterwards
local function reloadBuild(build, xmlText)
	loadBuildFromXML(xmlText, build.buildName)
end

-- One run of the search from the build as it is now, perturb as in startContext
local function search(build, options, perturb)
	local ctx, errMsg = startContext(build, options, perturb)
	if not ctx then
		return nil, errMsg
	end
	local allowUniques = ctx.allowUniques
	local score = eval(ctx)
	-- The best build after a round that another round follows, so that a round that makes it worse is undone
	local best
	for round = 1, ctx.opts.rounds do
		local before = score
		score = runRound(ctx, round, allowUniques)
		-- Conditions are switched on once the build exists to judge them by; the following round
		-- then builds around them
		local assumedNow = applyAssumptions(ctx)
		if assumedNow then
			score = eval(ctx)
			best = nil -- scored differently from here on
		elseif round > 1 and score <= before * 1.002 then
			break
		end
		if round < ctx.opts.rounds and loadBuildFromXML and (not best or better(ctx, score, best.score)) then
			best = { score = score, xml = build:SaveDB(build.buildName) }
		end
	end
	if best and better(ctx, best.score, score) then
		log(ctx, "Last round made the build worse (%.1f < %.1f), going back to the one before", score, best.score)
		local old = ctx
		reloadBuild(build, best.xml)
		ctx = startContext(build, options, perturb)
		ctx.evals, ctx.errors, ctx.lastError, ctx.assumed = old.evals, old.errors, old.lastError, old.assumed
	end
	clearUnusedSockets(ctx)
	removeDeadItems(ctx)
	score = eval(ctx)
	if score <= 0 then
		return nil, "The skill deals no damage in this setup" .. (ctx.lastError and (": " .. tostring(ctx.lastError)) or "")
	end
	return { score = score, evals = ctx.evals, errors = ctx.errors, lastError = ctx.lastError }
end

-- Optimise the build in place.
-- options: see optimizer.defaultOptions, plus
--   allowUniques   = true to let unique items compete with the crafted rares
--   autoAscendancy = true to pick the ascendancy when none is selected
-- With restarts > 1 the search is run that many times from the build as it was passed in, the best
-- result is kept (and ends up in the build). Returns a result table { score, evals, errors,
-- lastError }, or nil and an error message
function optimizer.Optimize(build, options)
	local restarts = m_max(1, m_floor(tonumber(options and options.restarts) or optimizer.defaultOptions.restarts))
	if restarts == 1 or not loadBuildFromXML then
		return search(build, options, 0)
	end
	local startXml = build:SaveDB(build.buildName)
	local best, bestXml, bestRun, lastErr, evals, errors = nil, nil, nil, nil, 0, 0
	for run = 0, restarts - 1 do
		if run > 0 then
			reloadBuild(build, startXml)
		end
		local logFn = options.log
		if logFn then
			logFn(s_format("[search %d of %d]", run + 1, restarts))
		end
		local result, errMsg = search(build, options, run)
		if result then
			evals, errors = evals + result.evals, errors + result.errors
			if not best or result.score > best.score then
				best, bestRun = result, run
				bestXml = run < restarts - 1 and build:SaveDB(build.buildName)
				if logFn then
					logFn(s_format("  best so far: %.1f", result.score))
				end
			end
		else
			lastErr = errMsg
		end
	end
	if not best then
		return nil, lastErr
	end
	if bestRun < restarts - 1 then
		reloadBuild(build, bestXml)
	end
	best.evals, best.errors = evals, errors
	return best
end

-- Plain text summary of the build: main skill links, equipment, tree and jewels
function optimizer.Describe(build, options)
	local lines = { }
	local function add(fmt, ...)
		t_insert(lines, s_format(fmt, ...))
	end
	local spec = build.spec
	local output = build.calcsTab.mainOutput or { }
	add("%s%s, level %d", spec.curClassName, spec.curAscendClassId ~= 0 and (" / " .. spec.curAscendClassName) or "", build.characterLevel)
	local detail = output.Minion or output
	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local minions = output.Minion and mainGroup and mainGroup.gemList[1] and mainGroup.gemList[1].count or 1
	if output.FullDPS and mainGroup and mainGroup.includeInFullDPS then
		add("Full DPS of the group's Spells (the score): %.0f", output.FullDPS)
	end
	add("Combined DPS: %.0f   (%shit DPS %.0f, crit chance %.1f%%, speed %.2f/s)", (output.CombinedDPS or 0) + (output.Minion and output.Minion.CombinedDPS or 0) * minions, output.Minion and "per minion: " or "", detail.TotalDPS or 0, detail.CritChance or 0, detail.Speed or 0)
	if output.Minion then
		add("Minions: %d (gem count; the engine's own figures are for one minion)", minions)
	end
	local unmet = { }
	for _, attr in ipairs(attributeNames) do
		if (output["Req" .. attr] or 0) > (output[attr] or 0) then
			t_insert(unmet, s_format("%s %d/%d", attr, output[attr] or 0, output["Req" .. attr]))
		end
	end
	add("Attributes: Str %d, Dex %d, Int %d%s", output.Str or 0, output.Dex or 0, output.Int or 0, #unmet > 0 and ("   UNMET REQUIREMENTS: " .. t_concat(unmet, ", ")) or "")

	add("")
	add("== Survivability ==")
	add("Survivability score (effective hit pool): %.0f", output.TotalEHP or 0)
	add("Life %d, Energy Shield %d, Armour %d, Evasion %d, Block %d%% (spells %d%%)", output.Life or 0, output.EnergyShield or 0, output.Armour or 0, output.Evasion or 0, output.BlockChance or 0, output.SpellBlockChance or 0)
	local resists, maxHits = { }, { }
	for _, damageType in ipairs({ "Fire", "Cold", "Lightning", "Chaos" }) do
		local missing = output["Missing" .. damageType .. "Resist"] or 0
		t_insert(resists, s_format("%s %d%%%s", damageType, output[damageType .. "Resist"] or 0, missing > 0 and s_format(" (%d below max)", missing) or ""))
	end
	for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
		t_insert(maxHits, s_format("%s %.0f", damageType, output[damageType .. "MaximumHitTaken"] or 0))
	end
	add("Resistances: %s", t_concat(resists, ", "))
	add("Maximum hit taken: %s", t_concat(maxHits, ", "))
	-- NetLifeRegen only exists when something degenerates Life; otherwise it is the plain recovery
	add("Net Life recovery: %.1f per second", output.NetLifeRegen or output.LifeRegenRecovery or 0)
	local horizon = tonumber(options and options.recoveryHorizon) or 0
	local env = build.calcsTab.mainEnv
	local survivability, rate = optimizer.Survivability(output, horizon, env)
	rate = horizon > 0 and rate or recoveryRate(output, env)
	add("Recovery: %.1f per second (Life and Energy Shield: regeneration, leech, on hit, recoup)", rate)
	if horizon > 0 then
		add("Survivability with %g seconds of recovery: %.0f (effective hit pool x %.2f)", horizon, survivability, survivability / m_max(tonumber(output.TotalEHP) or 1, 1))
	end

	add("")
	add("== Skill links ==")
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	for index, gemInstance in ipairs(group and group.gemList or { }) do
		local isSpell = index > 1 and index <= metaSpellCount(group) + 1
		add("%s %s (level %d, quality %d)", index == 1 and "Skill:  " or (isSpell and "Spell:  " or "Support:"), gemInstance.nameSpec or "?", gemInstance.level or 1, gemInstance.quality or 0)
	end

	local others = { }
	for index, other in ipairs(build.skillsTab.socketGroupList) do
		if index ~= build.mainSocketGroup and other.enabled and not other.source and other.gemList[1] then
			local names = { }
			for gemIndex = 2, #other.gemList do
				t_insert(names, other.gemList[gemIndex].nameSpec or "?")
			end
			local set2 = other.set1 == false and other.set2 ~= false
			t_insert(others, s_format("%s (level %d)%s%s", other.gemList[1].nameSpec or "?", other.gemList[1].level or 1, #names > 0 and (" + " .. t_concat(names, ", ")) or "", set2 and "   [cast with weapon set 2]" or (isTriggerSource(other) and "   [source of the main skill's trigger]" or "")))
		end
	end
	if #others > 0 then
		add("")
		add("== Auras, curses, marks and other supporting skills ==")
		for _, text in ipairs(others) do
			add("%s", text)
		end
		add("Spirit: %d of %d unreserved", output.SpiritUnreserved or 0, output.Spirit or 0)
	end

	add("")
	add("== Equipment ==")
	local function addItem(label, item)
		add("%s: %s [%s]%s", label, item.name, item.rarity, variantNote(item))
		local function addLines(list, prefix)
			for _, modLine in ipairs(list or { }) do
				if item:CheckModLineVariant(modLine) then
					add("      %s%s", prefix, (itemLib.formatModLine and itemLib.formatModLine(modLine) or modLine.line or ""):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
				end
			end
		end
		addLines(item.runeModLines, "(rune) ")
		addLines(item.implicitModLines, "(implicit) ")
		addLines(item.explicitModLines, "")
	end
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		local item = not slot.nodeId and build.itemsTab.items[slot.selItemId]
		if item then
			addItem(slot.slotName, item)
		end
	end

	add("")
	add("== Passive tree ==")
	local used, ascUsed, _, sockets, set1Used, set2Used = spec:CountAllocNodes()
	add("Points: %d passive, %d ascendancy, %d jewel sockets", used - m_min(set1Used or 0, set2Used or 0), ascUsed, sockets)
	if (set1Used or 0) > 0 or (set2Used or 0) > 0 then
		local set2Names = { }
		for _, node in pairs(spec.allocNodes) do
			if node.allocMode == 2 and node.type == "Notable" then
				t_insert(set2Names, node.dn)
			end
		end
		t_sort(set2Names)
		add("Weapon-set passives: %d only active in set 1, %d only active in set 2%s", set1Used, set2Used, #set2Names > 0 and (" (" .. t_concat(set2Names, ", ") .. ")") or "")
	end
	local keystones, notables, ascendancy = { }, { }, { }
	for _, node in pairs(spec.allocNodes) do
		if node.ascendancyName then
			if node.type == "Notable" then
				t_insert(ascendancy, node.dn)
			end
		elseif node.type == "Keystone" then
			t_insert(keystones, node.dn)
		elseif node.type == "Notable" then
			t_insert(notables, node.dn)
		end
	end
	t_sort(keystones)
	t_sort(notables)
	t_sort(ascendancy)
	add("Ascendancy notables: %s", #ascendancy > 0 and t_concat(ascendancy, ", ") or "-")
	add("Keystones: %s", #keystones > 0 and t_concat(keystones, ", ") or "-")
	add("Notables (%d): %s", #notables, t_concat(notables, ", "))

	add("")
	add("== Jewels ==")
	local anyJewel = false
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		local item = slot.nodeId and build.itemsTab.items[slot.selItemId]
		local node = slot.nodeId and spec.nodes[slot.nodeId]
		if item and node and node.alloc then
			anyJewel = true
			addItem("Socket " .. slot.nodeId, item)
		end
	end
	if not anyJewel then
		add("-")
	end
	return t_concat(lines, "\n")
end

return optimizer
