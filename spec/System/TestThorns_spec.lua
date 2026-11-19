describe("TestThorns", function()
	before_each(function()
		newBuild()
	end)

	-- Without a skill the hidden Thorns skill (added when you have Thorns damage) is the main skill; with skill, it is the main skill
	local function setup(customMods, config, skill)
		if skill then
			build.skillsTab:PasteSocketGroup(skill .. "\n")
		end
		build.configTab.input.customMods = customMods
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.buildFlag = true
		runCallback("OnFrame")
		return build.calcsTab.mainOutput
	end
	-- this pastes a group with only the Punch Through support (the hidden Punch isn't a gem), so the main skill is PoB's default unarmed Punch
	local punch = "skillId:MeleeUnarmedPlayer Punch 1/0  1"

	it("reads Thorns damage from maximum Life and Runic Plates, and Lucky Thorns against Fully Broken Armour", function()
		-- 67 base Life (with Strength) + 33 = 100: 8 to 12 Physical Thorns damage
		local output = setup("+33 to maximum Life\nGain Physical Thorns damage equal to 8% - 12% of maximum Life")
		assert.are.equals(100, output.Life)
		assert.are.near(10, output.PhysicalStoredCombinedAvg, 1e-9)
		-- 45 to 90 per plate; at most 4 plates (runic_tempering_max_runes)
		local plates = "45 to 90 added Physical Thorns damage per Runic Plate"
		assert.are.near(2 * 67.5, setup(plates, { multiplierRunicPlate = 2 }).PhysicalStoredCombinedAvg, 1e-9)
		assert.are.near(4 * 67.5, setup(plates, { multiplierRunicPlate = 6 }).PhysicalStoredCombinedAvg, 1e-9)
		-- Lucky: 10 / 3 + 2 x 20 / 3
		local lucky = "10 to 20 Physical Thorns damage\nThorns Damage is Lucky against targets with Fully Broken Armour"
		assert.are.near(15, setup(lucky, { multiplierRunicPlate = 0 }).PhysicalStoredCombinedAvg, 1e-9)
		assert.are.near(50 / 3, setup(lucky, { conditionEnemyArmourBroken = true }).PhysicalStoredCombinedAvg, 1e-9)
	end)

	it("retaliates at the approximated rate of enemy Melee Hits only with approximations", function()
		local thorns = "10 to 20 Physical Thorns damage"
		local output = setup(thorns)
		-- PoB's placeholder of one Thorns hit per second
		assert.are.equals(1, output.Speed)
		assert.are.near(output.AverageDamage, output.TotalDPS, 1e-9)
		-- half of 3 enemy hits per second are Melee
		output = setup(thorns, { useApproximations = true, approxEnemyHitsOnYouPerSecond = 3 })
		assert.are.equals(1.5, output.Speed)
		assert.are.near(1.5 * output.AverageDamage, output.TotalDPS, 1e-9)
		output = setup(thorns .. "\nThorns can Retaliate against all Hits")
		assert.are.equals(3, output.Speed)
		assert.are.equals(0, setup(thorns, { approxEnemyHitsOnYouPerSecond = 0 }).TotalDPS)
	end)

	it("deals Thorns damage on melee Hits as part of the skill's Combined DPS and Full DPS", function()
		local thorns = "10 to 20 Physical Thorns damage"
		local thornsHit = setup(thorns).AverageDamage
		assert.is_true(thornsHit > 0)
		newBuild()
		local base = setup(thorns, nil, punch)
		-- no on-Hit line: no second calculation, even with approximations
		assert.is_nil(setup(thorns, { useApproximations = true }).ThornsOnHitDPS)
		local output = setup(thorns .. "\n50% chance to deal your Thorns Damage to Enemies you Hit with Melee Attacks", { useApproximations = false })
		local hits = output.Speed * output.HitChance / 100 * output.DpsMultiplier
		assert.are.near(thornsHit * 0.5 * hits, output.ThornsOnHitDPS, 1e-9)
		assert.are.near(base.CombinedDPS + output.ThornsOnHitDPS, output.CombinedDPS, 1e-9)
		-- approximations change nothing here (retaliation is the Thorns skill's own DPS)
		local approx = setup(thorns .. "\n50% chance to deal your Thorns Damage to Enemies you Hit with Melee Attacks", { useApproximations = true })
		assert.are.near(output.CombinedDPS, approx.CombinedDPS, 1e-9)
		-- on Critical Hit: the share of landed Hits that crit
		output = setup(thorns .. "\nDeal your Thorns damage to enemies you Critically Hit with Melee Attacks", { useApproximations = false })
		assert.is_true(output.CritChance > 0)
		assert.are.near(thornsHit * output.CritChance / output.AccuracyHitChance * hits, output.ThornsOnHitDPS, 1e-9)
		-- spells aren't Melee Attacks
		newBuild()
		assert.is_nil(setup(thorns .. "\n50% chance to deal your Thorns Damage to Enemies you Hit with Melee Attacks", nil, "Fireball 20/0  1").ThornsOnHitDPS)
	end)

	it("Full DPS counts on-Hit Thorns like Impale", function()
		-- Mace Strike needs a usable off hand too: two clubs
		for i = 1, 2 do
			build.itemsTab:CreateDisplayItemFromRaw("New Item\nWooden Club")
			build.itemsTab:AddDisplayItem()
			build.itemsTab.slots["Weapon " .. i]:SetSelItemId(build.itemsTab.items[i].id)
		end
		local mods = "10 to 20 Physical Thorns damage\n50% chance to deal your Thorns Damage to Enemies you Hit with Melee Attacks"
		local output = setup(mods, nil, "skillId:MeleeMaceMacePlayer Mace Strike 20/0  1")
		assert.are.equals("Mace Strike", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		assert.is_true(output.ThornsOnHitDPS > 0)
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		local fullDPS = build.calcsTab.calcs.calcFullDPS(build, "CALCULATOR", { }, { })
		assert.are.near(output.CombinedDPS, fullDPS.combinedDPS, 1e-6)
	end)

	it("the optimizer's evaluations see Thorns changes from an override, also when it brings the first Thorns damage", function()
		local optimizer = LoadModule("Modules/BuildOptimizer")
		local chance = "50% chance to deal your Thorns Damage to Enemies you Hit with Melee Attacks"
		local expected = setup("10 to 20 Physical Thorns damage\n" .. chance .. "\n100% increased Thorns damage", nil, punch).ThornsOnHitDPS
		local current = setup("10 to 20 Physical Thorns damage\n" .. chance).ThornsOnHitDPS
		assert.is_true(expected > current)
		local ctx = optimizer.NewContext(build, { })
		local ring = new("Item"):Item("Rarity: RARE\nThorns Test\nIron Ring\nImplicits: 0\n100% increased Thorns damage")
		assert.are.near(current, optimizer.CalcOutput(ctx).ThornsOnHitDPS, 1e-9)
		assert.are.near(expected, optimizer.CalcOutput(ctx, { repSlotName = "Ring 1", repItem = ring }).ThornsOnHitDPS, 1e-9)
		-- no Thorns damage in the build, so no Thorns group from a MAIN pass: the candidate ring brings both lines
		local fresh = current
		setup("")
		assert.is_nil(build.calcsTab.mainOutput.ThornsOnHitDPS)
		ctx = optimizer.NewContext(build, { })
		ring = new("Item"):Item("Rarity: RARE\nThorns Test\nIron Ring\nImplicits: 0\n10 to 20 Physical Thorns damage\n" .. chance)
		assert.are.near(fresh, optimizer.CalcOutput(ctx, { repSlotName = "Ring 1", repItem = ring }).ThornsOnHitDPS, 1e-9)
	end)

	it("reports Presence and Ignited Ground Ignites per enemy, outside Combined DPS", function()
		local config = { enemyFireResist = 0 }
		local base = setup("+33 to maximum Life", config, punch)
		local output = setup("+33 to maximum Life\nEnemies in your Presence are Ignited as though dealt 200 Base Fire Damage\n"
			.. "Drop Ignited Ground while moving, which lasts 8 seconds and Ignites as though dealing Fire Damage equal to 10% of your maximum Life\n25% increased Ignite Magnitude")
		-- 20% of the damage per second (IgniteHitDamagePercentPerMinute 1200), x 1.25 magnitude, no Fire resistance
		assert.are.near(200 * 0.2 * 1.25, output.PresenceIgniteDPS, 1e-9)
		assert.are.near(100 * 0.1 * 0.2 * 1.25, output.GroundIgniteDPS, 1e-9)
		assert.are.near(base.CombinedDPS, output.CombinedDPS, 1e-9)
		-- 50% Fire resistance halves it
		assert.are.near(200 * 0.2 * 1.25 * 0.5, setup("Enemies in your Presence are Ignited as though dealt 200 Base Fire Damage\n25% increased Ignite Magnitude", { enemyFireResist = 50 }).PresenceIgniteDPS, 1e-9)
	end)

	it("estimates Overkill damage on the pack only with approximations", function()
		local line = "Deal 30% of Overkill damage to enemies within 2 metres of the enemy killed"
		local base = setup("", nil, punch)
		assert.is_nil(setup(line).OverkillPackDPSApprox)
		local output = setup(line, { useApproximations = true, approxKillsPerSecond = 2, approxEnemiesNearTarget = 3 })
		-- 2 kills/s x half the landed hit x 30% x 3 enemies
		local hit = output.AverageDamage * 100 / output.HitChance
		assert.are.near(2 * hit / 2 * 0.3 * 3, output.OverkillPackDPSApprox, 1e-9)
		assert.are.near(base.CombinedDPS, output.CombinedDPS, 1e-9)
	end)
end)
