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
		-- other groups of the build (setup.groups, socket group texts), with a Wooden Club for Attacks; the skill's group stays the main
		-- one unless setup.mainExtra selects the last of them
		local main = build.mainSocketGroup
		if setup.groups then
			build.itemsTab:CreateDisplayItemFromRaw("New Item\nWooden Club\n")
			build.itemsTab:AddDisplayItem()
			for _, text in ipairs(setup.groups) do
				build.skillsTab:PasteSocketGroup(text)
			end
			build.mainSocketGroup = setup.mainExtra and #build.skillsTab.socketGroupList or main
			build.buildFlag = true
			runCallback("OnFrame")
		end
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

	describe("Void Illusion", function()
		-- the explosion is the node's hidden second skill (the first is the buff that makes the copies)
		local setup = { class = "Monk", skill = "Void Illusion", skillSource = "tree", level = 95, active = 2 }

		it("keeps the cooldown-only rate with approximations off", function()
			local output, skill = calc(setup)
			assert.is_nil(skill.infoMessage)
			assert.are.equals("VoidIllusionSpawnPlayer", skill.activeEffect.grantedEffect.id)
			assert.are.equals(1 / 4, output.Speed)
			assert.are.equals(100, skill.skillData.supportTriggerOnCopyDestroyed)
		end)

		it("explodes once per copy that an enemy destroys: the lower of dodge rolls and enemy Hits", function()
			-- the default is one roll every 5 s
			local output, skill = calc(setup, approx)
			assert.are.equals("Void Illusion Trigger", skill.infoMessage)
			assert.are.near(0.2, output.Speed, 1e-9)
			assert.are.near(output.Speed * output.AverageDamage, output.TotalDPS, 1e-6)
			newBuild()
			assert.are.near(0.1, (calc(setup, with(approx, { approxEnemyHitsOnYouPerSecond = 0.1 }))).Speed, 1e-9)
			-- more rolls than the 4 s cooldown allows
			newBuild()
			assert.are.near(0.25, (calc(setup, with(approx, { approxDodgeRollsPerSecond = 5 }))).Speed, 1e-9)
		end)

		it("is scored by the optimizer through its explosion, which it selects in the node's group", function()
			local ok, pin = optimizer.SetupCharacter(build, { class = "Monk", skill = "Void Illusion", skillSource = "tree", level = 95 })
			assert.is_true(ok)
			local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
			assert.are.equals("VoidIllusionPlayer", group.displaySkillList[group.mainActiveSkill or 1].activeEffect.grantedEffect.id)
			local result = optimizer.Optimize(build, { rounds = 1, points = 4, ascendancyPoints = 1, maxSupports = 1, supportStarts = 1, baseCandidates = 1,
				weaponCombos = 1, treeVerify = 1, treeRefineFails = 1, runes = false, auxSkills = false, flasks = false, uniquePairAnchors = 1,
				weaponSets = false, treeWidth = 1, approximations = true, pin = pin })
			assert.is_true(result.score > 0)
			assert.are.equals("VoidIllusionSpawnPlayer", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.id)
		end)

		it("doesn't explode without dodge rolls", function()
			local output, skill = calc(setup, with(approx, { approxDodgeRollsPerSecond = 0 }))
			assert.are.equals(0, output.Speed)
			assert.are.equals(0, output.TotalDPS)
			assert.are.equals("No Illusions destroyed by enemies to trigger Void Illusion: no triggers", skill.infoMessage2)
		end)
	end)

	describe("Elemental Expression", function()
		-- Invoker: the node triggers it on the Critical Hits of the Melee Attack of the build with the most; the stat sets are the roll
		-- (1), Fiery Explosion (2, Strength), Icy Wave (3, Intelligence) and Arcing Bolt (4, Dexterity)
		local function setup(statSet, groups)
			return { class = "Monk", ascendancy = "Invoker", skill = "Elemental Expression", skillSource = "tree", level = 95, statSet = statSet, groups = groups }
		end
		local sunder = { "Sunder 20/0  1" }

		it("keeps the untriggered numbers with approximations off", function()
			local output, skill = calc(setup(1, sunder))
			assert.is_nil(skill.infoMessage)
			assert.is_nil(skill.skillData.triggered)
			assert.are.equals(0, output.Speed)
			assert.is_true(skill.skillData.supportTriggerOnMeleeCrit)
		end)

		it("triggers on the Melee Critical Hits, each stat set with its attribute's share", function()
			-- Sunder's Critical Hits per second, calculated as the main skill
			local main = setup(1, sunder)
			main.mainExtra = true
			local sunderOutput = calc(main)
			local crits = (sunderOutput.HitSpeed or sunderOutput.Speed) * sunderOutput.HitChance / 100 * math.min(sunderOutput.CritChance / sunderOutput.AccuracyHitChance, 1)
			assert.is_true(crits > 0 and crits < 1 / 0.25)
			local shares, total = { }, 0
			for set, attribute in pairs({ [2] = "Str", [3] = "Int", [4] = "Dex" }) do
				newBuild()
				local output, skill = calc(setup(set, sunder), approx)
				assert.are.equals("Elemental Expression's Trigger: Sunder", skill.infoMessage)
				shares[set] = output[attribute] / (output.Str + output.Dex + output.Int)
				assert.are.near(crits * shares[set], output.Speed, crits * 1e-9)
				total = total + output.Speed
			end
			-- the three outcomes together are every trigger
			assert.are.near(crits, total, crits * 1e-9)
			-- the roll itself (the first set) is every trigger
			newBuild()
			assert.are.near(crits, (calc(setup(1, sunder), approx)).Speed, crits * 1e-9)
		end)

		it("doesn't trigger without a Melee Attack", function()
			local output, skill = calc(setup(2), approx)
			assert.are.equals(0, output.Speed)
			assert.are.equals("No Critical Hits with Melee Attacks to trigger Elemental Expression: no triggers", skill.infoMessage2)
			-- a Spell isn't one
			newBuild()
			output = calc(setup(2, { "Spark 20/0  1" }), approx)
			assert.are.equals(0, output.Speed)
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
