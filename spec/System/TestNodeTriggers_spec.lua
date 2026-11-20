describe("TestNodeTriggers", function()
	before_each(function()
		newBuild()
	end)

	-- Sorceress, Stormweaver, the node that grants Elemental Storm and triggers it on Critical Hits with Spells (found by its text)
	local function allocStormNode()
		local spec = build.spec
		spec:SelectClass(spec.tree.classNameMap.Sorceress)
		for ascendClassId, ascendClass in pairs(spec.curClass.classes) do
			if ascendClass.name == "Stormweaver" then
				spec:SelectAscendClass(ascendClassId)
			end
		end
		local found
		for _, node in pairs(spec.nodes) do
			if node.ascendancyName == "Stormweaver" and node.sd and node.sd[2] == "Grants Skill: Elemental Storm" then
				found = node
			end
		end
		assert.is_truthy(found)
		spec:AllocNode(found)
		assert.is_true(found.alloc)
	end

	-- Allocates the node, pastes `groups` (each a socket group text), and calculates the main skill of the socket group that
	-- has `skillId`; returns the output and the main skill
	local function calc(groups, skillId, config, customMods, statSet)
		allocStormNode()
		build.itemsTab:CreateDisplayItemFromRaw("New Item\nWooden Club\n")
		build.itemsTab:AddDisplayItem()
		for _, group in ipairs(groups) do
			build.skillsTab:PasteSocketGroup(group)
		end
		runCallback("OnFrame")
		build.configTab.input.customMods = customMods or ""
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		for index, socketGroup in ipairs(build.skillsTab.socketGroupList) do
			if socketGroup.gemList[1] and socketGroup.gemList[1].skillId == skillId then
				build.mainSocketGroup = index
			end
		end
		build.buildFlag = true
		runCallback("OnFrame")
		local mainSkill = build.calcsTab.mainEnv.player.mainSkill
		assert.are.equals(skillId, mainSkill.activeEffect.grantedEffect.id)
		if statSet then -- the storm's first stat set deals nothing, its damage is in the "Fire", "Cold" and "Lightning" ones
			local instance = mainSkill.activeEffect.srcInstance
			instance.statSet, instance.statSetCalcs = { [skillId] = statSet }, { [skillId] = statSet }
			build.buildFlag = true
			runCallback("OnFrame")
			mainSkill = build.calcsTab.mainEnv.player.mainSkill
		end
		return copyTable(build.calcsTab.mainOutput, true), mainSkill
	end
	local approx = { useApproximations = true }
	local function critRate(output)
		return output.Speed * output.HitChance / 100 * output.CritChance / 100
	end

	it("keeps the self-cast numbers with approximations off", function()
		local output, skill = calc({ "Spark 20/0  1" }, "ElementalStormPlayer")
		assert.is_nil(skill.infoMessage)
		assert.is_nil(skill.skillData.triggered)
		assert.are.equals(0, output.Speed)
		-- the node's two lines make one parsed modifier that marks the skill, and nothing else about it changes
		assert.is_true(skill.skillData.supportTriggerOnSpellCrit)
	end)

	it("triggers on the Critical Hits of the Spell, capped by the cooldown with its alignment", function()
		-- fewer Critical Hits than one per 3 s: each one triggers
		local spark = calc({ "Spark 20/0  1" }, "SparkPlayer", approx)
		local crits = critRate(spark)
		assert.is_true(crits > 0 and crits < 1 / 3)
		newBuild()
		local output, skill = calc({ "Spark 20/0  1" }, "ElementalStormPlayer", approx)
		assert.are.equals("Elemental Storm's Trigger: Spark", skill.infoMessage)
		assert.are.equals(3, skill.skillData.cooldown)
		assert.are.equals(1, skill.skillData.storedUses)
		assert.are.near(crits, output.Speed, crits * 1e-9)
		-- 0.62 Critical Hits per second, more than its 3 s cooldown (91 server ticks) allows: every second one triggers
		local mods = "+30% to Critical Hit Chance"
		newBuild()
		spark = calc({ "Spark 20/0  1" }, "SparkPlayer", approx, mods)
		crits = critRate(spark)
		assert.is_true(crits > 0.5 and crits < 1)
		newBuild()
		output = calc({ "Spark 20/0  1" }, "ElementalStormPlayer", approx, mods)
		assert.is_true(output.Speed <= crits * (1 + 1e-12) and output.Speed <= output.TriggerRateCap)
		assert.are.near(crits / 2, output.Speed, crits / 2 * 2e-3)
	end)

	it("takes the Spell with the most Critical Hits from any socket group", function()
		local rates = { }
		for _, spell in ipairs({ { "Spark", "SparkPlayer" }, { "Fireball", "FireballPlayer" } }) do
			newBuild()
			rates[spell[1]] = critRate(calc({ "Spark 20/0  1", "Fireball 20/0  1" }, spell[2], approx))
		end
		assert.is_true(rates.Spark > 0 and rates.Fireball > 0 and rates.Spark ~= rates.Fireball)
		local best = rates.Spark > rates.Fireball and "Spark" or "Fireball"
		newBuild()
		local output, skill = calc({ "Spark 20/0  1", "Fireball 20/0  1" }, "ElementalStormPlayer", approx)
		assert.are.equals("Elemental Storm's Trigger: " .. best, skill.infoMessage)
		assert.are.near(rates[best], output.Speed, rates[best] * 1e-9)
	end)

	it("scores the damage of the storms alive: triggers per second x duration, at most the limit", function()
		-- approximations off: the damage while one storm exists, a Hit every 250 ms
		local off = calc({ "Spark 20/0  1" }, "ElementalStormPlayer", nil, nil, 2)
		assert.are.near(off.AverageDamage * 4, off.TotalDPS, 1e-6)
		assert.is_nil(off.ObjectsAlive)
		-- on: x the storms alive on average, which follows the Critical Hits of the Spell (below the cooldown cap)
		local dps = { }
		for _, crit in ipairs({ 0, 10 }) do
			newBuild()
			local output = calc({ "Spark 20/0  1" }, "ElementalStormPlayer", approx, crit > 0 and "+" .. crit .. "% to Critical Hit Chance" or "", 2)
			assert.is_true(output.Speed > 0 and output.Speed < 1 / 3)
			assert.are.near(output.Speed * output.Duration, output.ObjectsAlive, 1e-9)
			assert.is_true(output.ObjectsAlive < 50)
			assert.are.near(off.AverageDamage * 4 * output.ObjectsAlive, output.TotalDPS, off.AverageDamage * 4e-9)
			dps[#dps + 1] = output
		end
		assert.is_true(dps[2].Speed > dps[1].Speed)
		assert.are.near(dps[2].Speed / dps[1].Speed, dps[2].TotalDPS / dps[1].TotalDPS, 1e-9)
		-- a long duration: capped at the 50 storms allowed
		newBuild()
		local capped = calc({ "Spark 20/0  1" }, "ElementalStormPlayer", approx, "10000% increased Skill Effect Duration", 2)
		assert.are.equals(50, capped.ObjectsAlive)
		assert.are.near(off.AverageDamage * 4 * 50, capped.TotalDPS, off.AverageDamage * 4e-9)
	end)

	it("scores no storm damage without a Spell", function()
		local output = calc({ }, "ElementalStormPlayer", approx, nil, 2)
		assert.are.equals(0, output.ObjectsAlive)
		assert.are.equals(0, output.TotalDPS)
		assert.are.equals(0, output.CombinedDPS)
	end)

	it("doesn't trigger without a Spell", function()
		local output, skill = calc({ }, "ElementalStormPlayer", approx)
		assert.are.equals(0, output.Speed)
		assert.are.equals("No Critical Hits with Spells to trigger Elemental Storm: no triggers", skill.infoMessage2)
	end)
end)
