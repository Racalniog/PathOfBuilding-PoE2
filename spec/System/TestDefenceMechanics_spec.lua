describe("TestDefenceMechanics", function()
	before_each(function()
		newBuild()
	end)

	-- 1000 physical melee damage per enemy hit; no other damage types
	local function setup(customMods, config)
		build.configTab.input.enemyDamageType = "Melee"
		build.configTab.input.enemyPhysicalDamage = "1000"
		build.configTab.input.enemyFireDamage = "0"
		build.configTab.input.enemyColdDamage = "0"
		build.configTab.input.enemyLightningDamage = "0"
		build.configTab.input.enemyChaosDamage = "0"
		build.configTab.input.customMods = "+2000 to maximum Life\n"..customMods
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		runCallback("OnFrame")
		return build.calcsTab.mainOutput
	end

	local function near(expected, actual, tol)
		assert.are.near(expected, actual, tol or 0.01)
	end

	it("Runic Ward can't stop a lethal hit when life loss prevention clamps the damage", function()
		local prevention = "25% of Life Loss from Hits is prevented, then that much Life is lost over 4 seconds instead"
		local without = setup(prevention).NumberOfMitigatedDamagingHits
		local with = setup(prevention .. "\n+1000 to maximum Runic Ward").NumberOfMitigatedDamagingHits
		-- 1000 Ward adds about one 1000 damage hit, not one hit per sliver of damage left after the clamp
		assert.is_true(with > without)
		assert.is_true(with < without + 2)
	end)

	it("recoups physical damage prevented by damage reduction", function()
		-- no armour: 50% additional reduction prevents half of each hit and lets half through
		local output = setup("50% additional Physical Damage Reduction\n50% of Physical Damage prevented Recouped as Life")
		assert.are.equals(0, output.Armour)
		near(output.PhysicalTakenDamage / 2, output.PhysicalTakenHit)
		near(output.PhysicalTakenDamage / 2, output.PhysicalPreventedHit)
		assert.are.equals(50, output.PhysicalDamagePreventedLifeRecoup)
		-- prevented damage equals the damage taken in those hits, half of it recouped over 8 seconds
		assert.is_true(output.PhysicalRecoupableDamageTaken > 0)
		near(output.PhysicalRecoupableDamageTaken * 0.5, output.TotalLifeRecoupRecovery)
		near(output.TotalLifeRecoupRecovery / 8, output.LifeRecoupRecoveryMax)
		near(output.TotalLifeRecoupRecovery / (output.EHPSurvivalTime + 8), output.LifeRecoupRecoveryAvg)
		-- the regeneration-style model stays separate and untouched
		assert.is_nil(output.PhysicalDamageMitigatedLifePseudoRecoup)
		-- with 75% reduction, 3 prevented for each 1 taken
		output = setup("75% additional Physical Damage Reduction\n10% of Physical Damage prevented Recouped as Life")
		near(output.PhysicalRecoupableDamageTaken * 3 * 0.1, output.TotalLifeRecoupRecovery)
		-- per enemy Power (20 for a boss) on Energy Shield
		output = setup("50% additional Physical Damage Reduction\n5% of Physical Damage prevented Recouped as Energy Shield per enemy Power", { enemyIsBoss = "Boss" })
		assert.are.equals(100, output.PhysicalDamagePreventedEnergyShieldRecoup)
		near(output.PhysicalRecoupableDamageTaken, output.TotalEnergyShieldRecoupRecovery)
	end)

	it("increased speed of Recoup Effects shortens every recoup", function()
		local output = setup("10% of Damage taken Recouped as Life\n25% increased speed of Recoup Effects")
		-- 8 seconds / 1.25 = 6.4 seconds, same total amount
		near(output.PhysicalRecoupableDamageTaken * 0.1, output.TotalLifeRecoupRecovery)
		near(output.TotalLifeRecoupRecovery / 6.4, output.LifeRecoupRecoveryMax)
		near(output.TotalLifeRecoupRecovery / (output.EHPSurvivalTime + 6.4), output.LifeRecoupRecoveryAvg)
		-- 4 second recoup at 100% increased speed: 2 seconds
		output = setup("10% of Damage taken Recouped as Mana\nRecoup Effects instead occur over 4 seconds\n100% increased speed of Recoup Effects")
		near(output.TotalManaRecoupRecovery / 2, output.ManaRecoupRecoveryMax)
	end)

	it("Guard takes hit damage before Life, from the largest source, capped at maximum Life", function()
		local base = setup("")
		-- nothing without the config
		assert.is_nil(setup("Also grants 300 Guard").sharedGuardAbsorb)
		local output = setup("Also grants 200 Guard\nAlso grants 300 Guard", { conditionHaveGuard = true })
		assert.are.equals(300, output.sharedGuardAbsorb)
		-- no armour or reduction: Guard adds its amount to the largest hit survived
		near(base.PhysicalMaximumHitTaken + 300, output.PhysicalMaximumHitTaken, 1)
		assert.is_true(output.TotalEHP > base.TotalEHP)
		near(360, setup("Also grants 300 Guard\n20% increased Guard gained", { conditionHaveGuard = true }).sharedGuardAbsorb)
		output = setup("Also grants 100000 Guard", { conditionHaveGuard = true })
		assert.are.equals(output.Life, output.sharedGuardAbsorb)
		output = setup("Also grants 100000 Guard\n+50 to maximum Energy Shield\nMaximum amount of Guard is based on maximum Energy Shield instead", { conditionHaveGuard = true })
		assert.are.equals(output.EnergyShield, output.sharedGuardAbsorb)
	end)

	it("event-based Guard sources need approximations", function()
		local combo = "Gain 500 Guard for 0.5 seconds per Combo expended when using Skills"
		assert.is_nil(setup(combo, { conditionHaveGuard = true, multiplierCombo = 3 }).sharedGuardAbsorb)
		-- 500 per Combo x 3 Combo
		assert.are.equals(1500, setup(combo, { conditionHaveGuard = true, multiplierCombo = 3, useApproximations = true }).sharedGuardAbsorb)
		-- sprinted to the 20% maximum
		local output = setup("When you stop Sprinting, gain Guard equal to 4% of maximum Life per second spent Sprinting, up to a maximum of 20%, for 4 seconds", { conditionHaveGuard = true, useApproximations = true })
		assert.is_true(math.abs(output.sharedGuardAbsorb - output.Life * 0.2) < 1)
	end)

	it("Guard from a used Mana Flask is a share of its recovery amount", function()
		build.itemsTab:CreateDisplayItemFromRaw([[
			Test Flask
			Ultimate Mana Flask
		]])
		build.itemsTab:AddDisplayItem()
		build.itemsTab.slots["Flask 2"]:SetSelItemId(build.itemsTab.items[1].id)
		build.itemsTab.slots["Flask 2"].active = true
		local manaTotal = build.itemsTab.items[1].flaskData.manaTotal
		local output = setup("Using a Mana Flask grants Guard equal to 50% of Flask's recovery amount for 4 seconds", { conditionHaveGuard = true })
		assert.is_true(manaTotal > 0)
		assert.is_true(math.abs(output.sharedGuardAbsorb - manaTotal * 0.5) < 1)
	end)

	it("recoups damage taken from deflected hits and damage blocked", function()
		local output = setup("+3000 to Deflection Rating\n15% of Damage taken from Deflected Hits Recouped as Life")
		local p, e = output.DeflectChance / 100, output.DeflectEffect / 100
		assert.is_true(p > 0 and p < 1 and e > 0)
		-- deflected hits deal (1-e) of a hit and happen with chance p; an average hit deals (1 - p*e)
		near(0.15 * output.PhysicalRecoupableDamageTaken * p * (1 - e) / (1 - p * e), output.TotalLifeRecoupRecovery)
		-- 50% block, blocked hits take nothing: as much damage is blocked as is taken
		output = setup("+50% to Block chance\nDamage Blocked is Recouped as Mana")
		assert.are.equals(50, output.EffectiveBlockChance)
		assert.are.equals(100, output.BlockedManaRecoup)
		near(output.PhysicalRecoupableDamageTaken, output.TotalManaRecoupRecovery)
		output = setup("+50% to Block chance\n30% of damage Blocked is Recouped as Mana")
		near(output.PhysicalRecoupableDamageTaken * 0.3, output.TotalManaRecoupRecovery)
	end)

	it("Avoid Death from Hits adds p/(1-p) lethal hits, only with approximations", function()
		local base = setup("")
		local output = setup("50% chance to Avoid Death from Hits")
		assert.are.equals(base.TotalNumberOfHits, output.TotalNumberOfHits)
		assert.is_nil(output.AvoidDeathExtraHits)
		output = setup("50% chance to Avoid Death from Hits", { useApproximations = true })
		-- p = 0.5: one extra lethal hit on average
		assert.are.equals(1, output.AvoidDeathExtraHits)
		near(base.TotalNumberOfHits + 1 / (1 - output.ConfiguredNotHitChance / 100), output.TotalNumberOfHits)
		assert.are.equals(base.PhysicalMaximumHitTaken, output.PhysicalMaximumHitTaken)
	end)
end)
