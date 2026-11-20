describe("TestEventTriggers", function()
	-- Skills of items and tree nodes whose trigger rate comes from the approximation inputs (CalcTriggers.lua, supportTrigger;
	-- CalcOffence.lua for Runic Tempering): Valako's Charge, Void Illusion, Elemental Expression, Runic Tempering. The optimizer's
	-- setup puts the skill's item / node in a fresh build; `statSet` / `active` select the stat set / skill of the group to calculate
	local optimizer
	before_each(function()
		newBuild()
		optimizer = LoadModule("Modules/BuildOptimizer")
	end)

	local function calc(setup, config, customMods)
		assert.is_true(optimizer.SetupCharacter(build, setup))
		local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
		if setup.active then
			group.mainActiveSkill, group.mainActiveSkillCalcs = setup.active, setup.active
		end
		if setup.statSet then
			local effect = build.calcsTab.mainEnv.player.mainSkill.activeEffect
			local instance, id = effect.srcInstance, effect.grantedEffect.id
			instance.statSet, instance.statSetCalcs = instance.statSet or { }, instance.statSetCalcs or { }
			instance.statSet[id], instance.statSetCalcs[id] = setup.statSet, setup.statSet
		end
		build.configTab.input.customMods = customMods or ""
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.buildFlag = true
		runCallback("OnFrame")
		return copyTable(build.calcsTab.mainOutput, true), build.calcsTab.mainEnv.player.mainSkill
	end
	local approx = { useApproximations = true }
	local function with(config, extra)
		local merged = copyTable(config)
		for var, val in pairs(extra) do
			merged[var] = val
		end
		return merged
	end

	describe("Valako's Charge", function()
		local setup = { class = "Witch", skill = "Valako's Charge", skillSource = "item", level = 95, statSet = 2 }
		-- the damage that fills the charge, in the first stat set (the Bolt set holds 0)
		local function threshold(skill)
			return skill.activeEffect.grantedEffect.statSets[1].levels[skill.activeEffect.level][1]
		end

		it("keeps the untriggered numbers with approximations off", function()
			local output, skill = calc(setup)
			assert.is_nil(skill.infoMessage)
			assert.is_nil(skill.skillData.triggered)
			assert.are.equals(0, output.Speed)
			assert.are.equals(0, output.TotalDPS)
			assert.is_true(output.AverageDamage > 0)
			assert.are.equals(100, skill.skillData.supportTriggerChance)
		end)

		it("triggers at the enemy Hits that deal Lightning damage and fill the charge, capped by its cooldown", function()
			-- 0.5 Hits per second, 50% of them Lightning, an enemy hit of 100 against the character's Lightning resistance
			local config = with(approx, { approxEnemyHitsOnYouPerSecond = 0.5, approxEnemyLightningHitShare = 50, enemyLightningDamage = 100 })
			local output, skill = calc(setup, config)
			local filled = math.min(100 * (1 - output.LightningResist / 100) / threshold(skill), 1)
			assert.is_true(filled > 0 and filled < 1)
			assert.are.equals("Valako's Charge Trigger", skill.infoMessage)
			assert.are.near(0.25 * filled, output.Speed, 1e-9)
			assert.are.near(output.Speed * output.AverageDamage, output.TotalDPS, 1e-6)
			-- a hit that fills the whole charge: one trigger per Lightning Hit
			newBuild()
			output = calc(setup, with(config, { enemyLightningDamage = 1000000 }))
			assert.are.near(0.25, output.Speed, 1e-9)
			-- many Hits: the 1 s cooldown caps it (server ticks make it slightly less than 1 per second)
			newBuild()
			output = calc(setup, with(config, { enemyLightningDamage = 1000000, approxEnemyHitsOnYouPerSecond = 10, approxEnemyLightningHitShare = 100 }))
			assert.is_true(output.Speed > 0.5 and output.Speed <= 1 and output.Speed <= output.TriggerRateCap)
		end)

		it("doesn't trigger without Lightning Hits", function()
			local output, skill = calc(setup, with(approx, { approxEnemyLightningHitShare = 0 }))
			assert.are.equals(0, output.Speed)
			assert.are.equals("No Lightning damage taken to trigger Valako's Charge: no triggers", skill.infoMessage2)
		end)
	end)

	describe("Runic Tempering", function()
		local setup = { class = "Warrior", skill = "Runic Tempering", skillSource = "item", level = 95 }
		local function dps(config, mods)
			return (calc(setup, with(approx, config), mods))
		end

		it("deals nothing with approximations off", function()
			local output, skill = calc(setup)
			assert.are.equals(0, output.TotalDPS)
			assert.is_nil(output.BacklashDPS)
			assert.is_nil(skill.infoMessage2)
			assert.are.equals(0.4, skill.skillData.runicTemperingBacklashCooldown)
		end)

		it("backlashes with the Thorns damage at the enemy Hit rate, at most once per cooldown", function()
			local output, skill = calc(setup, with(approx, { approxEnemyHitsOnYouPerSecond = 1 }))
			local thornsHit = output.BacklashDPS
			assert.is_true(thornsHit > 0)
			assert.are.equals(thornsHit, output.TotalDPS)
			assert.are.equals(thornsHit, output.CombinedDPS)
			assert.is_truthy(skill.infoMessage2:find("Approximation: 1.00 backlashes per second", 1, true))
			-- fewer Hits: linear
			newBuild()
			assert.are.near(thornsHit / 2, dps({ approxEnemyHitsOnYouPerSecond = 0.5 }).BacklashDPS, 1e-9)
			-- many Hits: one backlash per cooldown, rounded up to server ticks
			newBuild()
			local tick = data.misc.ServerTickRate
			assert.are.near(thornsHit * tick / math.ceil(0.4 * tick), dps({ approxEnemyHitsOnYouPerSecond = 100 }).BacklashDPS, 1e-6)
			newBuild()
			assert.are.equals(0, dps({ approxEnemyHitsOnYouPerSecond = 0 }).BacklashDPS)
		end)

		it("holds the plates' maximum unless the plates are set", function()
			local output = calc(setup, with(approx, { approxEnemyHitsOnYouPerSecond = 1 }))
			local full = output.BacklashDPS
			newBuild()
			-- (Thorns per plate, so about half; the game's 4-plate Thorns skill isn't exactly twice its 2-plate one)
			output = calc(setup, with(approx, { approxEnemyHitsOnYouPerSecond = 1, multiplierRunicPlate = 2 }))
			assert.are.near(full / 2, output.BacklashDPS, full * 0.01)
			assert.is_true(output.BacklashDPS < full / 2)
		end)
	end)
end)
