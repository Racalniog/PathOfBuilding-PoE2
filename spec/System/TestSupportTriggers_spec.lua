describe("TestSupportTriggers", function()
	before_each(function()
		newBuild()
	end)

	-- Pastes `group` with `weapon` and calculates the skill with id `skillId` of group 1 as the main skill
	local function calc(weapon, group, skillId, config, customMods)
		build.itemsTab:CreateDisplayItemFromRaw("New Item\n" .. weapon .. "\n")
		build.itemsTab:AddDisplayItem()
		build.skillsTab:PasteSocketGroup(group)
		runCallback("OnFrame")
		build.configTab.input.customMods = customMods or ""
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.mainSocketGroup = 1
		local socketGroup = build.skillsTab.socketGroupList[1]
		for index, skill in ipairs(socketGroup.displaySkillList) do
			if skill.activeEffect.grantedEffect.id == skillId then
				socketGroup.mainActiveSkill = index
			end
		end
		build.buildFlag = true
		runCallback("OnFrame")
		local mainSkill = build.calcsTab.mainEnv.player.mainSkill
		assert.are.equals(skillId, mainSkill.activeEffect.grantedEffect.id)
		return copyTable(build.calcsTab.mainOutput, true), mainSkill
	end
	local approx = { useApproximations = true }

	it("keeps the self-cast rate with approximations off", function()
		-- Mana Flare self-cast: 1 s cast time, capped by its 1 s cooldown rounded up to server ticks
		local output, skill = calc("Wooden Club", "Spark 20/0  1\nMana Flare 1/0  1", "TriggeredManaFlarePlayer")
		assert.is_nil(skill.infoMessage)
		assert.is_nil(skill.skillData.triggered)
		assert.are.near(1 / (math.ceil(data.misc.ServerTickRate) / data.misc.ServerTickRate), output.Speed, 1e-9)
	end)

	it("triggers Mana Flare on the supported Spell's Critical Hits, with the cooldown's alignment", function()
		local group = "Spark 20/0  1\nMana Flare 1/0  1"
		-- fewer Critical Hits than one per cooldown: each one triggers, never more often than the events (the alignment simulation's
		-- 1000 events can count 1001 triggers)
		for _, crit in ipairs({ 10, 20, 30, 40, 45, 50 }) do
			newBuild()
			local mods = "+" .. crit .. "% to Critical Hit Chance"
			local spark = calc("Wooden Club", group, "SparkPlayer", approx, mods)
			local crits = spark.Speed * spark.HitChance / 100 * spark.CritChance / 100
			assert.is_true(crits > 0 and crits < 0.9)
			newBuild()
			local output, skill = calc("Wooden Club", group, "TriggeredManaFlarePlayer", approx, mods)
			assert.are.equals("Mana Flare's Trigger: Spark", skill.infoMessage)
			assert.is_true(output.Speed <= crits * (1 + 1e-12)) -- (the same product, in another order)
			assert.are.near(crits, output.Speed, crits * 1e-9)
			assert.are.near(output.AverageDamage * output.Speed, output.TotalDPS, 1e-6)
		end
		local output
		-- every Hit a Critical Hit, one per 0.7 s cast: the 1 s cooldown (31 server ticks) lets every second one trigger
		newBuild()
		output = calc("Wooden Club", group, "TriggeredManaFlarePlayer", approx, "+100% to Critical Hit Chance")
		assert.are.near(1 / 0.7 / 2, output.Speed, 1 / 0.7 / 2 * 2e-3)
	end)

	it("recalculates a support-triggered skill's Full DPS when only its source changes", function()
		calc("Wooden Club", "Spark 20/0  1\nMana Flare 1/0  1", "TriggeredManaFlarePlayer", approx, "+30% to Critical Hit Chance")
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.buildFlag = true
		runCallback("OnFrame")
		-- the per-skill Full DPS cache keys a skill on its own mod list: Mana Flare's doesn't change when Spark becomes Arc
		local calcFunc = build.calcsTab:GetMiscCalculator(build)
		local gem = build.skillsTab.socketGroupList[1].gemList[1]
		gem.gemData = data.gems[data.gemForBaseName["arc"]]
		local fast = calcFunc(nil, true, { nodeAlloc = true, requirementsItems = true, requirementsGems = true, skipEHP = true, fullDPSOnly = true })
		build.buildFlag = true
		runCallback("OnFrame")
		assert.are.equals("Mana Flare's Trigger: Arc", build.calcsTab.mainEnv.player.mainSkill.infoMessage)
		assert.are.near(build.calcsTab.mainOutput.FullDPS, fast.FullDPS, 1e-6)
	end)

	it("previews a hovered gem from the group's current state", function()
		-- the gem-sorting fast path reuses one environment: the source rates it caches must not outlive one call
		calc("Wooden Club", "Spark 20/0  1\nMana Flare 1/0  1", "TriggeredManaFlarePlayer", approx, "+30% to Critical Hit Chance")
		local calcFunc = build.calcsTab:GetMiscCalculator(build)
		local fastOptions = { nodeAlloc = true, requirementsItems = true, requirementsGems = true, skipEHP = true }
		local before = calcFunc(nil, false, fastOptions).Speed
		local gemData = data.gems[data.gemForBaseName["rapid casting i support"]]
		table.insert(build.skillsTab.socketGroupList[1].gemList, { level = 1, quality = 0, count = 1, enabled = true, gemId = gemData.id, nameSpec = gemData.name, skillId = gemData.grantedEffectId, gemData = gemData })
		local preview = calcFunc(nil, false, fastOptions).Speed
		local fresh = calcFunc({ }).Speed
		assert.is_true(fresh > before * 1.05)
		assert.are.near(fresh, preview, 1e-9)
	end)

	it("doesn't trigger from a triggered skill", function()
		-- Fireball triggered by Cast on Critical, supported by Mana Flare
		local output, skill = calc("Wooden Club", "Cast on Critical 20/0  1\nFireball 20/0  1\nMana Flare 1/0  1", "TriggeredManaFlarePlayer", approx)
		assert.are.equals(0, output.Speed)
		assert.are.equals("Supported skill is triggered: no triggers modelled", skill.infoMessage2)
	end)

	it("triggers Coursing Current on Shocks, capped at one per cooldown with stored uses", function()
		local group = "Spark 20/0  1\nCoursing Current 1/0  1"
		local mods = "+100% chance to Shock"
		local spark = calc("Wooden Club", group, "SparkPlayer", approx, mods)
		assert.are.equals(100, spark.ShockChance)
		newBuild()
		local output, skill = calc("Wooden Club", group, "TriggeredDeadlyCurrentPlayer", approx, mods)
		assert.are.equals("Coursing Current's Trigger: Spark", skill.infoMessage)
		assert.are.near(spark.Speed * spark.HitChance / 100, output.Speed, 1e-9)
		-- 8.6 Shocks per second, more than its 0.2 s cooldown allows: 6 stored uses smooth it to 1 / 0.2 (no tick rounding)
		newBuild()
		output = calc("Wooden Club", group, "TriggeredDeadlyCurrentPlayer", approx, mods .. "\n500% increased Cast Speed")
		assert.are.equals(0.2, data.skills.TriggeredDeadlyCurrentPlayer.levels[1].cooldown)
		assert.are.near(5, output.Speed, 1e-9)
	end)

	it("triggers Fan the Flames on Hits against Ignited enemies, from the Ignite uptime of the supported skill", function()
		local group = "Wind Blast 20/0  1\nFan The Flames 1/0  1"
		-- the enemy configured as Ignited: every Hit counts
		local wind = calc("Long Quarterstaff", group, "GaleStrikePlayer", approx)
		newBuild()
		local output, skill = calc("Long Quarterstaff", group, "TriggeredFanTheFlamesPlayer", { useApproximations = true, conditionEnemyIgnited = true })
		assert.are.equals("Fan The Flames's Trigger: Wind Blast", skill.infoMessage)
		local hits = wind.Speed * wind.HitChance / 100
		assert.is_true(hits > 0)
		assert.are.near(hits, output.Speed, 1e-9)
		-- otherwise its own Ignites: Hits x (1 - e^(-Ignites/s x Ignite duration))
		local mods = "Gain 100% of Physical Damage as Extra Fire Damage\n+50% chance to Ignite"
		newBuild()
		wind = calc("Long Quarterstaff", group, "GaleStrikePlayer", approx, mods)
		hits = wind.Speed * wind.HitChance / 100
		local ignites = hits * wind.IgniteChancePerHit / 100
		assert.is_true(ignites > 0 and wind.IgniteDuration > 0)
		local expected = hits * (1 - math.exp(-ignites * wind.IgniteDuration))
		newBuild()
		output = calc("Long Quarterstaff", group, "TriggeredFanTheFlamesPlayer", approx, mods)
		assert.are.near(expected, output.Speed, 1e-9)
		-- no Ignites, and no supported skill, trigger it 0 times
		for _, case in ipairs({ { group, "Fan The Flames's Trigger: Wind Blast" }, { "Fan The Flames 1/0  1", "Fan The Flames Trigger" } }) do
			newBuild()
			output, skill = calc("Long Quarterstaff", case[1], "TriggeredFanTheFlamesPlayer", approx)
			assert.are.equals(0, output.Speed)
			assert.are.equals(case[2], skill.infoMessage)
			assert.are.equals("No Hits against Ignited enemies to trigger Fan the Flames: no triggers", skill.infoMessage2)
		end
	end)

	it("triggers Fiery Death on kills of Ignited enemies and Doom Blast once per Curse duration (approximations)", function()
		-- 3 kills per second x 60% chance, the enemy configured as Ignited; no cooldown
		local output, skill = calc("Wooden Club", "Fireball 20/0  1\nFiery Death 1/0  1", "TriggeredFieryDeathPlayer", { useApproximations = true, conditionEnemyIgnited = true, approxKillsPerSecond = 3 })
		assert.are.equals("Fiery Death's Trigger: Fireball", skill.infoMessage)
		assert.are.near(3 * 0.6, output.Speed, 1e-9)
		-- "enemies it Ignites": a source that can't Ignite triggers it 0 times, whatever the configuration says
		newBuild()
		output, skill = calc("Wooden Club", "Spark 20/0  1\nFiery Death 1/0  1", "TriggeredFieryDeathPlayer", { useApproximations = true, conditionEnemyIgnited = true, approxKillsPerSecond = 3 })
		assert.are.equals(0, output.Speed)
		assert.are.equals("No Ignited enemies dying to trigger Fiery Death: no triggers", skill.infoMessage2)
		-- Impending Doom: "when the Curse expires", at most as often as the Curse is cast
		local group = "Vulnerability 20/0  1\nImpending Doom 1/0  1"
		newBuild()
		local curse = calc("Wooden Club", group, "VulnerabilityPlayer", approx)
		assert.is_true(curse.Duration > 1 / curse.Speed)
		newBuild()
		output, skill = calc("Wooden Club", group, "DoomBlastPlayer", approx)
		assert.are.equals("Impending Doom's Trigger: Vulnerability", skill.infoMessage)
		assert.are.near(1 / curse.Duration, output.Speed, 1e-9)
	end)
end)
