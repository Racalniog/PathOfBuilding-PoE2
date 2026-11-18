describe("TestAilmentGaps", function()
	before_each(function()
		newBuild()
	end)

	local function setup(customMods, config, skill)
		if skill then
			build.skillsTab:PasteSocketGroup(skill .. " 20/0 1\n")
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

	it("reads chance to Poison / inflict Bleeding and the base chance swaps", function()
		local output = setup("20% chance to Poison on Hit\n25% increased chance to Poison\n10% chance to inflict Bleeding on Hit\n50% increased chance to inflict Bleeding")
		assert.are.near(25, output.PoisonChance, 1e-9)
		assert.are.near(15, output.BleedChance, 1e-9)
		-- base_poison_chance_is_bleed_chance_instead: Poison uses the 10% base of Bleeding, still with its own 25% increased
		output = setup("20% chance to Poison on Hit\n25% increased chance to Poison\n10% chance to inflict Bleeding on Hit\nChance to Poison is calculated from your base chance to inflict Bleeding instead")
		assert.are.near(12.5, output.PoisonChance, 1e-9)
		assert.are.near(10, output.BleedChance, 1e-9)
		-- both swapped: each uses the other's base
		output = setup("20% chance to Poison on Hit\n10% chance to inflict Bleeding on Hit\nChance to Poison is calculated from your base chance to inflict Bleeding instead\nChance to inflict Bleeding is calculated from your base chance to Poison instead")
		assert.are.near(10, output.PoisonChance, 1e-9)
		assert.are.near(20, output.BleedChance, 1e-9)
	end)

	it("Magnitude of Elemental Ailments with Spells scales spell Ignite only", function()
		local line = "35% increased Magnitude of Elemental Ailments you inflict with Spells"
		local base = setup("Hits always Ignite", nil, "Fireball").IgniteMagnitudeEffect
		assert.are.near(base * 1.35, setup("Hits always Ignite\n" .. line).IgniteMagnitudeEffect, 1e-9)
		newBuild()
		-- the unarmed attack isn't a spell
		local attack = "Adds 10 to 20 Fire damage to Attacks\nHits always Ignite"
		base = setup(attack).IgniteMagnitudeEffect
		assert.are.near(base, setup(attack .. "\n" .. line).IgniteMagnitudeEffect, 1e-9)
	end)

	it("Elemental Ailment Application raises Ignite and Shock chance", function()
		local base = setup("", nil, "Fireball").IgniteChanceOnHit
		assert.is_true(base > 0 and base < 50)
		local line = "40% increased Elemental Ailment Application if you have Shapeshifted to an Animal form Recently"
		assert.are.near(base, setup(line).IgniteChanceOnHit, 1e-9)
		assert.are.near(base * 1.4, setup(line, { conditionShapeshiftToAnimal = true }).IgniteChanceOnHit, 1e-9)
		assert.are.near(base * 1.2, setup("20% increased Elemental Ailment Application", { conditionShapeshiftToAnimal = false }).IgniteChanceOnHit, 1e-9)
	end)

	it("Lightning Damage contributes to Flammability and Ignite Magnitudes", function()
		local mods = "Adds 1 to 100 Lightning damage to Attacks\nHits always Ignite"
		assert.are.equals(0, setup(mods).IgniteDPS or 0)
		assert.is_true(setup(mods .. "\nLightning Damage from Hits also Contributes to Flammability and Ignite Magnitudes").IgniteDPS > 0)
	end)

	it("Seconds of ignite on the enemy scale the permanent Fire Damage taken, up to its cap", function()
		local line = "Enemies Ignited by you permanently take 1% increased Fire Damage for each second they have ever been Ignited by you, up to a maximum of 10%"
		setup(line, { multiplierIgnitedByYouSeconds = 4 }, "Fireball")
		assert.are.equals(4, build.calcsTab.mainEnv.enemyDB:Sum("INC", nil, "FireDamageTaken"))
		setup(line, { multiplierIgnitedByYouSeconds = 30 })
		assert.are.equals(10, build.calcsTab.mainEnv.enemyDB:Sum("INC", nil, "FireDamageTaken"))
		setup("Enemies standing on Ignited Ground take 25% increased Cold Damage", { multiplierIgnitedByYouSeconds = 0, conditionEnemyOnIgnitedGround = true })
		assert.are.equals(25, build.calcsTab.mainEnv.enemyDB:Sum("INC", nil, "ColdDamageTaken"))
		assert.is_true(build.calcsTab.mainEnv.enemyDB:GetCondition("Ignited"))
	end)

	local bleed = "Adds 10 to 20 Physical damage to Attacks\n100% chance to inflict Bleeding on Hit"

	it("aggravating Bleeding on Hit does nothing with approximations off", function()
		local base = setup(bleed).BleedDPS
		assert.is_true(base > 0)
		local output = setup(bleed .. "\n20% chance to Aggravate Bleeding on targets you Hit with Attacks\nAttack Hits Aggravate any Bleeding on targets which is older than 4 seconds")
		assert.are.near(base, output.BleedDPS, 1e-9)
		assert.is_nil(output.BleedAggravatedApprox)
	end)

	it("estimates the aggravated share of Bleeding from aggravating hits", function()
		local approx = { useApproximations = true }
		local base = setup(bleed, approx)
		assert.is_nil(base.BleedAggravatedApprox)
		-- older than 4 seconds: a 5 s Bleeding is aggravated for its last second, 20% of the time, 100% more damage
		local output = setup(bleed .. "\nAttack Hits Aggravate any Bleeding on targets which is older than 4 seconds", approx)
		assert.are.equals(5, output.BleedDuration)
		assert.are.near(20, output.BleedAggravatedApprox, 1e-9)
		assert.are.near(base.BleedDPS * 1.2, output.BleedDPS, 1e-6)
		-- 20% chance on Hit: rate r = 0.2 x hits per second, aggravated for 5 - (1 - e^(-5r)) / r of 5 seconds
		output = setup(bleed .. "\n20% chance to Aggravate Bleeding on targets you Hit with Attacks", approx)
		local r = 0.2 * output.Speed * output.HitChance / 100
		local share = (5 - (1 - math.exp(-5 * r)) / r) / 5
		assert.are.near(share * 100, output.BleedAggravatedApprox, 1e-6)
		assert.are.near(base.BleedDPS * (1 + share), output.BleedDPS, 1e-6)
		-- both: the wait is capped at 4 seconds
		output = setup(bleed .. "\n20% chance to Aggravate Bleeding on targets you Hit with Attacks\nAttack Hits Aggravate any Bleeding on targets which is older than 4 seconds", approx)
		assert.are.near((5 - (1 - math.exp(-4 * r)) / r) / 5 * 100, output.BleedAggravatedApprox, 1e-6)
		-- a moving enemy's Bleeding already deals the extra damage
		output = setup(bleed .. "\nAttack Hits Aggravate any Bleeding on targets which is older than 4 seconds", { useApproximations = true, conditionEnemyMoving = true })
		assert.is_nil(output.BleedAggravatedApprox)
		assert.are.near(base.BleedDPS * 2, output.BleedDPS, 1e-6)
	end)

	local spread = "Ignites you inflict spread to other Enemies that stay within 1.5 metres for 1 second"

	it("Ignite spread is a pack value only", function()
		local base = setup("Hits always Ignite", { useApproximations = true, approxEnemiesNearTarget = 2 }, "Fireball")
		assert.is_true(base.IgniteDPS > 0)
		local output = setup("Hits always Ignite\n" .. spread)
		-- single-target DPS unchanged
		assert.are.near(base.IgniteDPS, output.IgniteDPS, 1e-9)
		assert.are.near(base.CombinedDPS, output.CombinedDPS, 1e-9)
		-- the target and 2 enemies near it
		assert.are.near(3 * output.IgniteDPS, output.IgnitePackDPSApprox, 1e-9)
		assert.is_nil(setup("Hits always Ignite\n" .. spread, { useApproximations = false }).IgnitePackDPSApprox)
	end)

	it("Shock spread estimates the Shocked enemies near the target", function()
		local approx = { useApproximations = true, approxEnemiesNearTarget = 3 }
		local line = "Hits always Shock\nShocking Hits have a 50% chance to also Shock enemies in a 1.5 metre radius"
		local base = setup("Hits always Shock", approx, "Spark")
		local output = setup(line)
		assert.are.near(base.CombinedDPS, output.CombinedDPS, 1e-9)
		local shocking = (output.HitSpeed or output.Speed) * output.HitChance / 100 * output.ShockChance / 100
		assert.are.near(3 * (1 - math.exp(-0.5 * shocking * output.ShockDuration)), output.ShockSpreadApprox, 1e-9)
		assert.is_nil(setup(line, { useApproximations = false }).ShockSpreadApprox)
	end)
end)
