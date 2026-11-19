describe("TestApproxSecondPass", function()
	before_each(function()
		newBuild()
	end)

	local function setup(skill, customMods, config)
		if skill then
			build.skillsTab:PasteSocketGroup(skill)
			build.mainSocketGroup = 1
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

	-- Number of extra passes calcs.perform runs: offence calculations of the player's main skill beyond the first
	local function extraPasses()
		local calcs = build.calcsTab.calcs
		local env = calcs.initEnv(build, "CALCULATOR")
		local offence, count = calcs.offence, -1
		calcs.offence = function(env, actor, ...)
			if actor == env.player then
				count = count + 1
			end
			return offence(env, actor, ...)
		end
		calcs.perform(env)
		calcs.offence = offence
		return count, env.player.output
	end

	local charges = "20% chance to gain a Power Charge on Hit\n10% increased Damage per Power Charge"

	it("runs a single pass with approximations off, and a second one only when an estimate needs it", function()
		setup("Fireball 20/0  1", charges)
		local count, output = extraPasses()
		assert.are.equals(0, count)
		assert.is_nil(output.ApproxSecondPass)
		assert.are.equals(0, output.PowerCharges)
		-- approximations on, but nothing that needs the main skill's rates
		setup(nil, "", { useApproximations = true })
		assert.are.equals(0, (extraPasses()))
		setup(nil, charges)
		count, output = extraPasses()
		assert.are.equals(1, count)
		assert.is_true(output.ApproxSecondPass)
	end)

	it("restores the environment exactly for the second pass", function()
		-- item Spirit and charm slots are set up by initEnv; a weapon set context (Elemental Weakness on set 2) pairs two environments
		for _, raw in ipairs({ "New Item\nRattling Sceptre\n", "Rarity: Rare\nNew Item\nLinen Belt\nImplicits: 1\nHas 2 Charm Slots\n" }) do
			build.itemsTab:CreateDisplayItemFromRaw(raw)
			build.itemsTab:AddDisplayItem()
		end
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.skillsTab:PasteSocketGroup("Elemental Weakness 20/0  1")
		local curse = build.skillsTab.socketGroupList[2]
		curse.set1, curse.set2 = false, true
		build.mainSocketGroup = 1
		local off = setup(nil, "20% chance to gain a Power Charge on Hit")
		local calcs = build.calcsTab.calcs
		local charmLimit = build.calcsTab.mainEnv.modDB:Sum("BASE", nil, "CharmLimit")
		assert.is_true(off.Spirit > 0)
		assert.is_true(charmLimit > 0)
		-- perform, restore, perform gives the same output, with the weapon set context
		local env = calcs.initEnv(build, "CALCS")
		assert.is_true(env.weaponSetEnvs ~= nil)
		local restore = calcs.snapshotEnv(env)
		calcs.perform(env)
		local first = copyTable(env.player.output, true)
		restore()
		calcs.perform(env)
		local count = 0
		for key, value in pairs(env.player.output) do
			if type(value) ~= "table" then
				count = count + 1
				assert.are.equals(first[key], value)
			end
		end
		for key, value in pairs(first) do
			if type(value) ~= "table" then
				assert.are.equals(value, env.player.output[key])
			end
		end
		assert.is_true(count > 500)
		-- a snapshot can be restored more than once (Full DPS restores it before every skill)
		restore()
		calcs.perform(env)
		restore()
		calcs.perform(env)
		for key, value in pairs(first) do
			if type(value) ~= "table" then
				assert.are.equals(value, env.player.output[key])
			end
		end
		-- with approximations on the second pass sees the same items
		local on = setup(nil, "20% chance to gain a Power Charge on Hit", { useApproximations = true })
		assert.is_true(on.ApproxSecondPass)
		assert.are.near(2.5, on.PowerCharges, 1e-9)
		assert.are.equals(off.Spirit, on.Spirit)
		assert.are.equals(off.Life, on.Life)
		assert.are.equals(charmLimit, build.calcsTab.mainEnv.modDB:Sum("BASE", nil, "CharmLimit"))
	end)

	it("feeds the estimated infusions to per-infusion effects", function()
		-- Inhibitor: 4% more damage per infusion type you have. Cold Remnants 0.1/s x 20 s = 2 Cold Infusions (Fireball doesn't
		-- consume them), estimated in the first pass, which used none
		local base = setup("Fireball 20/0  1\nInhibitor 1/0  1", "", { approxColdRemnantsPerSecond = 0.1 })
		local output = setup(nil, "", { useApproximations = true })
		assert.is_true(output.ApproxSecondPass)
		assert.are.near(2, output.ColdInfusions, 1e-9)
		assert.are.near(2, build.calcsTab.mainEnv.modDB:GetMultiplier("ColdInfusion"), 1e-9)
		assert.are.near(base.AverageHit * 1.04, output.AverageHit, 0.5) -- damage rolls are whole numbers
		-- the configured count wins
		output = setup(nil, "", { multiplierColdInfusion = 1 })
		assert.are.equals(1, output.ColdInfusions)
		assert.are.equals(1, build.calcsTab.mainEnv.modDB:GetMultiplier("ColdInfusion"))
	end)

	it("feeds hit-based charges to the charge count", function()
		local approx = { useApproximations = true, approxKillsPerSecond = 0 }
		local base = setup("Fireball 20/0  1", "20% chance to gain a Power Charge on Hit", approx)
		-- 0.2 x 0.8333 hits per second (the first pass's) x 15 s = 2.5, at most 3
		assert.are.near(math.min(3, 0.2 * base.Speed * 15), base.PowerCharges, 1e-9)
		assert.are.near(2.5, base.PowerCharges, 1e-9)
		-- per-charge modifiers count the whole charges: 2 x 10% increased
		assert.are.near(base.TotalDPS * 1.2, setup(nil, charges).TotalDPS, base.TotalDPS * 0.001)
		-- "Do you use Power Charges?" with a count wins, and needs no second pass
		local output = setup(nil, charges, { usePowerCharges = true, overridePowerCharges = 1 })
		assert.are.equals(1, output.PowerCharges)
		assert.is_nil(output.ApproxSecondPass)
	end)

	it("feeds Nebuloch's crit share to the crit chance", function()
		local nebuloch = "Attacks consume an Endurance Charge to Critically Hit\n30% chance to gain an Endurance Charge on kill"
		-- the unarmed default attack; without approximations it has no charge to consume and crits at its own chance
		local base = setup(nil, nebuloch, { approxKillsPerSecond = 1 })
		local crit, preCrit = base.CritChance, base.PreEffectiveCritChance
		assert.is_true(crit < 100)
		local output = setup(nil, nebuloch, { useApproximations = true })
		-- 0.3 charges per second over the attack rate: that share always crits, the rest at the attack's own chance
		local share = math.min(1, 0.3 / output.Speed)
		assert.are.near(share * 100, output.EnduranceCritShareApprox, 1e-9)
		assert.are.near(share * 100 + (1 - share) * crit, output.CritChance, 1e-9)
		assert.are.near(share * 100 + (1 - share) * preCrit, output.PreEffectiveCritChance, 1e-9)
		assert.are.equals(0, output.EnduranceCharges)
		-- a configured charge keeps the exact rule: every attack crits
		assert.are.equals(100, setup(nil, nebuloch, { useEnduranceCharges = true, overrideEnduranceCharges = 1 }).CritChance)
	end)

	it("gives Arbiter's Ignition an Archon uptime that waits for the next Ignite", function()
		local grant = "Archon Buffs also grant +20% to all Elemental Resistances\n100% chance to Ignite"
		local approx = { useApproximations = true, approxArchonRecovery = 10 }
		local output = setup("Fireball 20/0  1\nArbiter's Ignition 1/0  1", grant, approx)
		assert.are.equals(100, output.IgniteChancePerHit)
		-- every cast ignites: 0.8333 Ignites per second, so after 10 s of Elemental Archon and 10 s of recovery the next one comes
		-- 1.2 s later on average: 10 / (10 + 10 + 1.2) = 47.2%
		assert.are.near(100 * 10 / (20 + 1 / output.Speed), output.ArchonEffectMod, 1e-9)
		-- after spending 100% of maximum mana as well: both events count, the wait is 1 / (sum of the rates)
		output = setup(nil, grant.."\nGain Elemental Archon after spending 100% of your Maximum Mana")
		assert.are.near(100 * 10 / (20 + 1 / (output.Speed + output.ManaPerSecondCost / output.Mana)), output.ArchonEffectMod, 1e-9)
		-- a source without a known rate (Energy Shield Recharge) fires as soon as the recovery period ends: 10 / (10 + 10)
		assert.are.near(50, setup(nil, grant.."\nGain Elemental Archon when your Energy Shield Recharge begins").ArchonEffectMod, 1e-9)
		-- "Are you affected by an Archon Buff?" wins
		assert.are.equals(100, setup(nil, grant, { conditionAffectedByArchon = true }).ArchonEffectMod)
	end)
end)
