describe("TestTriggers", function()
	before_each(function()
		newBuild()
	end)

	-- Pastes the groups and calculates with main group `main` (the Spell socketed in the meta skill of group 1 by default)
	local function calc(groups, customMods, config, main)
		for _, group in ipairs(groups) do
			build.skillsTab:PasteSocketGroup(group)
		end
		runCallback("OnFrame")
		build.configTab.input.customMods = customMods or ""
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.mainSocketGroup = main or 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 2
		build.buildFlag = true
		runCallback("OnFrame")
		return build.calcsTab.mainOutput, build.calcsTab.mainEnv.player.mainSkill
	end

	-- Fireball's base cast time is 1.2 s: a meta skill needs 1 Energy per 10 ms of it to trigger Fireball
	local fireballEnergy = 120

	it("triggers Cast on Critical from the Critical Hits of the build's own skill (exact)", function()
		assert.are.equals(1.2, data.skills.FireballPlayer.castTime)
		local groups = { "Cast on Critical 20/0  1\nFireball 20/0  1", "Spark 20/0  1" }
		local mods = "+50% to Critical Hit Chance"
		local spark = copyTable(calc(groups, mods, nil, 2), true)
		newBuild()
		local output, skill = calc(groups, mods)
		assert.are.equals("FireballPlayer", skill.activeEffect.grantedEffect.id)
		assert.are.equals("Fireball's Trigger: Cast on Critical", skill.infoMessage)
		-- Energy per Critical Hit: 1 (100 centienergy) x Power 20 (the default Pinnacle boss) x 157% (gem level 20: 57% increased
		-- Energy) x the percentage of the Ailment Threshold the Critical Hit deals, at most what one trigger needs
		local critAverage = 0
		for _, damageType in ipairs({ "Physical", "Lightning", "Cold", "Fire", "Chaos" }) do
			critAverage = critAverage + (spark[damageType .. "CritAverage"] or 0)
		end
		assert.is_true(critAverage > 0)
		local perCrit = math.min(1 * 20 * 1.57 * 100 * critAverage / spark.EnemyAilmentThreshold, fireballEnergy)
		local critsPerSecond = spark.Speed * spark.CritChance / 100
		local expected = critsPerSecond * perCrit / fireballEnergy
		assert.is_true(expected > 0)
		assert.are.near(expected, output.Speed, expected * 1e-6)
		assert.are.near(output.AverageDamage * output.Speed, output.TotalDPS, 1e-6)
	end)

	it("keeps the self-cast rate with a message when no skill gives the meta skill Energy", function()
		local output, skill = calc({ "Cast on Critical 20/0  1\nFireball 20/0  1" })
		assert.are.equals("Cast on Critical: no Energy source PoB can calculate", skill.infoMessage)
		assert.are.near(1 / 1.2, output.Speed, 1e-6)
	end)

	it("triggers Cast on Melee Kill from kills only with approximations on", function()
		local groups = { "Cast on Melee Kill 20/0  1\nFireball 20/0  1", "Boneshatter 20/0  1" }
		local output, skill = calc(groups)
		assert.are.equals("Cast on Melee Kill: no Energy source PoB can calculate (needs approximations)", skill.infoMessage)
		assert.are.near(1 / 1.2, output.Speed, 1e-6)
		-- 2 kills/s x 3 Energy (300 centienergy, Power 1 for pack monsters, no increased Energy on the gem) / 120
		newBuild()
		output, skill = calc(groups, "", { useApproximations = true, approxKillsPerSecond = 2 })
		assert.are.equals("Fireball's Trigger: Cast on Melee Kill", skill.infoMessage)
		assert.are.near(2 * 3 / fireballEnergy, output.Speed, 1e-9)
		-- 100% more Energy, and a 25% chance to refund half of a trigger's Energy (costs 1 - 0.25 / 2 of it)
		newBuild()
		output = calc(groups, "Energy Generation is doubled\n25% chance for Trigger skills to refund half of Energy Spent", { useApproximations = true, approxKillsPerSecond = 2 })
		assert.are.near(2 * 6 / (fireballEnergy * 0.875), output.Speed, 1e-9)
	end)

	it("caps a trigger at one per event and at the triggered Spell's cooldown", function()
		-- 3 x 101 = 303 Energy per kill, more than the 120 one trigger needs: the rest is lost, one trigger per kill
		local groups = { "Cast on Melee Kill 20/0  1\nFireball 20/0  1", "Boneshatter 20/0  1" }
		local output = calc(groups, "Meta Skills gain 10000% increased Energy", { useApproximations = true, approxKillsPerSecond = 2 })
		assert.are.near(2, output.Speed, 1e-9)
		-- Frost Bomb's 6 s cooldown plus the 0.2 s trigger cooldown Cast on Melee Kill adds, rounded up to server ticks:
		-- 100 kills/s trigger it once per 6.2 s
		newBuild()
		output = calc({ "Cast on Melee Kill 20/0  1\nFrost Bomb 20/0  1", "Boneshatter 20/0  1" }, "Meta Skills gain 10000% increased Energy", { useApproximations = true, approxKillsPerSecond = 100 })
		assert.are.equals(6, data.skills.FrostBombPlayer.levels[20].cooldown)
		local cap = 1 / (math.ceil((6 + 0.2) * data.misc.ServerTickRate) / data.misc.ServerTickRate)
		assert.are.near(cap, output.Speed, 1e-9)
	end)
end)
