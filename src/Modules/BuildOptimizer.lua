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
	-- Equip flasks and charms where they add damage (they are assumed to be active)
	flasks = true,
	-- Look for combinations whose parts do nothing on their own (supports, affixes, passives, uniques)
	combos = true,
	-- Number of rejected uniques per slot that are tried as one half of a unique pair
	uniquePairAnchors = 4,
	-- Check every unique as one half of a pair instead (slow)
	thorough = false,
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
	-- Full passes over supports -> equipment -> tree -> jewels
	rounds = 2,
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

local function calcOutput(ctx, override)
	local env = ctx.calcs.initEnv(ctx.build, "CALCULATOR", override)
	ctx.calcs.perform(env, true)
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
		if output.Minion and type(output.Minion[metric]) == "number" then
			value = value + output.Minion[metric] * minions
		end
	end
	if type(value) ~= "number" or value ~= value or value == m_huge or value == -m_huge then
		return 0
	end
	return value
end

-- Score the build as it currently is, with an optional calculation override applied
local function eval(ctx, override)
	ctx.evals = ctx.evals + 1
	local ok, output, env = pcall(calcOutput, ctx, override)
	if not ok then
		ctx.errors = ctx.errors + 1
		ctx.lastError = output
		return -1
	end
	return scoreOutput(ctx, output, env)
end

local function better(ctx, new, old)
	return new > old + math.abs(old) * ctx.opts.epsilon and new > old
end

-- Reduce a list to a small sub-list for which keeps(list) still holds (delta debugging). Used to
-- pin down which members of a large group are responsible for an effect the group has as a whole
local function shrink(items, keeps)
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

-- Configure class, ascendancy, level and the main skill on a (fresh) build.
-- setup = { class = "Ranger", ascendancy = "Deadeye" | nil, skill = "Lightning Arrow", level = 100, gemLevel = nil, config = { } }
-- Returns true, or nil and an error message
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
		else
			return nil, "'" .. tostring(setup.skill) .. "' is not an active skill gem"
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

	local function conflicts(gemData, skipIndex)
		for index = 2, #gemList do
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
		for index = #gemList, 2, -1 do
			gemList[index] = nil
		end
		for _, gemData in ipairs(links) do
			t_insert(gemList, makeGemInstance(ctx, gemData))
		end
	end
	local function getLinks()
		local links = { }
		for index = 2, #gemList do
			if gemList[index].gemData then
				t_insert(links, gemList[index].gemData)
			end
		end
		return links
	end
	-- Complete and polish the links that are currently set
	local function finish()
		cur = eval(ctx)
		while #gemList - 1 < ctx.opts.maxSupports do
			local best, bestScore = bestForIndex(#gemList + 1)
			if not best then
				break
			end
			t_insert(gemList, makeGemInstance(ctx, best))
			cur = bestScore
		end
		for _ = 1, 3 do
			local improved = false
			for index = 2, #gemList do
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
			gemList[2] = makeGemInstance(ctx, gemData)
			t_insert(ranked, { gemData = gemData, score = eval(ctx) })
		end
		gemList[2] = nil
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
	item:UpdateRunes()
	item:BuildAndParseRaw()
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

local function rollUnique(ctx, source)
	local item = new("Item"):Item(source:BuildRaw())
	if not item.base then
		return nil
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
			local item = rollUnique(ctx, source)
			if item then
				t_insert(list, item)
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

local function unequip(ctx, slotName)
	local itemsTab = ctx.build.itemsTab
	local slot = slotFor(ctx, slotName)
	local old = slot and itemsTab.items[slot.selItemId]
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
		if isAuxGroup(ctx, group) then
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
	local used, ascUsed = ctx.build.spec:CountAllocNodes()
	if ascendancy then
		return ctx.opts.ascendancyPoints - ascUsed
	end
	return passiveBudget(ctx) - used
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
				t_insert(candidates, { targets = { node }, nodes = node.path, cost = #node.path, estimate = gain / #node.path })
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
					t_insert(candidates, { targets = groupNodes, nodes = list, cost = #list, estimate = gain / #list })
				end
			end
		end
		-- Passives that do nothing alone are tested as one group. If the group does something, the
		-- few nodes responsible are pinned down and offered, with the travel they need, as a candidate
		if ctx.opts.combos then
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
					combo = shrink(idle, function(list) return gainOf(list) >= all * 0.5 end)
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
				if #list <= remaining then
					t_sort(combo, function(a, b)
						if a.pathDist ~= b.pathDist then
							return a.pathDist < b.pathDist
						end
						return a.id < b.id
					end)
					local gain = gainOf(list)
					t_insert(candidates, { targets = combo, nodes = list, cost = #list, estimate = gain / #list, combo = true })
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
			local rate = gain / candidate.cost
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
	while fails < ctx.opts.treeRefineFails do
		local worst, worstRate
		for id, node in pairs(spec.allocNodes) do
			if not tried[id] and not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.depends and #node.depends > 0 and #node.depends <= 8 then
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
				t_insert(configOptionList, { var = option.var, type = option.type, label = option.label, section = section })
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
			if type(name) == "string" and not seen[name] and not (statSet.statMap and statSet.statMap[name]) and not (data.skillStatMap and data.skillStatMap[name]) then
				seen[name] = true
				t_insert(missing, name)
			end
		end
		for _, name in ipairs(statSet.stats or { }) do
			check(name)
		end
		for _, entry in ipairs(statSet.constantStats or { }) do
			check(entry[1])
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
	add("== Configuration ==")
	local on = { }
	for _, entry in ipairs(sensitivity) do
		if entry.enabled then
			t_insert(on, entry)
		end
	end
	if #on > 0 then
		add("Assumed conditions (the build was scored with these on; without one, the damage changes by):")
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
				add("Conditions that would raise the damage if you can keep them up (--config <name>=true):")
			end
			shown = shown + 1
			if shown <= 15 then
				add("  %-52s %+6.1f%%   [%s]", entry.label, entry.change * 100, entry.var)
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
	}
end
optimizer.NewContext = newContext

local function runRound(ctx, round, allowUniques)
	local spec = ctx.build.spec
	local score
	if eval(ctx) <= 0 then
		-- Attacks do nothing without a weapon, so supports can't be compared before one is equipped
		log(ctx, "[round %d] weapons", round)
		optimizeWeapons(ctx, allowUniques)
	end
	log(ctx, "[round %d] support gems", round)
	ctx.multiStart = round == 1
	score = optimizeSupports(ctx)
	log(ctx, "  -> %.1f", score)

	if ctx.opts.auxSkills then
		log(ctx, "[round %d] auras, curses, marks and other supporting skills", round)
		score = optimizeAuxSkills(ctx)
		log(ctx, "  -> %.1f", score)
	end

	log(ctx, "[round %d] equipment%s", round, allowUniques and " (uniques allowed)" or "")
	score = optimizeGear(ctx, allowUniques)
	if allowUniques and ctx.opts.combos and round == 1 then
		score = optimizeUniquePairs(ctx)
	end
	if ctx.opts.flasks then
		score = optimizeUtility(ctx, allowUniques)
	end
	log(ctx, "  -> %.1f", score)

	log(ctx, "[round %d] passive tree", round)
	local used = spec:CountAllocNodes()
	if spec.curAscendClassId == 0 and ctx.autoAscendancy and used == 0 then
		chooseAscendancy(ctx)
	end
	optimizeAscendancy(ctx)
	placeTemplateJewels(ctx)
	growTree(ctx, false)
	sync(ctx)
	score = refineTree(ctx)
	log(ctx, "  -> %.1f", score)

	log(ctx, "[round %d] jewels", round)
	score = optimizeJewels(ctx, allowUniques)
	assignAttributes(ctx)
	if repairGemRequirements(ctx) then
		-- Lower requirements free attribute nodes for something better
		assignAttributes(ctx)
	end
	score = eval(ctx)
	log(ctx, "  -> %.1f", score)
	return score
end

-- Optimise the build in place.
-- options: see optimizer.defaultOptions, plus
--   allowUniques   = true to let unique items compete with the crafted rares
--   autoAscendancy = true to pick the ascendancy when none is selected
-- Returns a result table { score, evals, errors, lastError }, or nil and an error message
function optimizer.Optimize(build, options)
	local ctx, errMsg = newContext(build, options)
	if not ctx then
		return nil, errMsg
	end
	ctx.autoAscendancy = options and options.autoAscendancy
	ctx.allowUniques = options and options.allowUniques or false
	local allowUniques = options and options.allowUniques or false
	for _, item in pairs(build.itemsTab.items) do
		for _, slot in pairs(build.itemsTab.slots) do
			if slot.selItemId == item.id then
				countUnique(ctx, item, 1)
			end
		end
	end
	sync(ctx)

	local score = eval(ctx)
	for round = 1, ctx.opts.rounds do
		local before = score
		score = runRound(ctx, round, allowUniques)
		-- Conditions are switched on once the build exists to judge them by; the following round
		-- then builds around them
		local assumedNow = applyAssumptions(ctx)
		if assumedNow then
			score = eval(ctx)
		elseif round > 1 and score <= before * 1.002 then
			break
		end
	end
	clearUnusedSockets(ctx)
	removeDeadItems(ctx)
	score = eval(ctx)
	if score <= 0 then
		return nil, "The skill deals no damage in this setup" .. (ctx.lastError and (": " .. tostring(ctx.lastError)) or "")
	end
	return { score = score, evals = ctx.evals, errors = ctx.errors, lastError = ctx.lastError }
end

-- Plain text summary of the build: main skill links, equipment, tree and jewels
function optimizer.Describe(build)
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
	add("== Skill links ==")
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	for index, gemInstance in ipairs(group and group.gemList or { }) do
		add("%s %s (level %d, quality %d)", index == 1 and "Skill:  " or "Support:", gemInstance.nameSpec or "?", gemInstance.level or 1, gemInstance.quality or 0)
	end

	local others = { }
	for index, other in ipairs(build.skillsTab.socketGroupList) do
		if index ~= build.mainSocketGroup and other.enabled and not other.source and other.gemList[1] then
			local names = { }
			for gemIndex = 2, #other.gemList do
				t_insert(names, other.gemList[gemIndex].nameSpec or "?")
			end
			t_insert(others, s_format("%s (level %d)%s", other.gemList[1].nameSpec or "?", other.gemList[1].level or 1, #names > 0 and (" + " .. t_concat(names, ", ")) or ""))
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
		add("%s: %s [%s]", label, item.name, item.rarity)
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
	local used, ascUsed, _, sockets = spec:CountAllocNodes()
	add("Points: %d passive, %d ascendancy, %d jewel sockets", used, ascUsed, sockets)
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
