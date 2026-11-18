describe("TestCharges", function()
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

	it("applies per-charge effects and maximum changes at the configured count", function()
		local output = setup("+1 to Maximum Power Charges", { usePowerCharges = true })
		assert.are.equals(4, output.PowerChargesMax)
		assert.are.equals(4, output.PowerCharges)
		output = setup("+1 to Maximum Power Charges", { usePowerCharges = true, overridePowerCharges = 2 })
		assert.are.equals(2, output.PowerCharges)
		-- Redflare Conduit: reaching the maximum loses them all, so at most maximum - 1
		assert.are.equals(3, setup("+1 to Maximum Power Charges\nLose all Power Charges on reaching maximum Power Charges", { usePowerCharges = true, overridePowerCharges = 4 }).PowerCharges)
		-- Conduit and its rune versions: the charges go to allies
		output = setup("If you would gain a Frenzy Charge, Allies in your Presence gain that Charge instead", { useFrenzyCharges = true, useEnduranceCharges = true })
		assert.are.equals(0, output.FrenzyCharges)
		assert.are.equals(3, output.EnduranceCharges)
		assert.are.equals(0, setup("If you would gain a Charge, Allies in your Presence gain that Charge instead", { useEnduranceCharges = true }).EnduranceCharges)
	end)

	local nebuloch = "Attacks consume an Endurance Charge to Critically Hit"

	it("Attacks consume an Endurance Charge to Critically Hit only with a charge to consume", function()
		-- the unarmed default attack
		assert.is_true(setup(nebuloch).CritChance < 100)
		assert.are.equals(100, setup(nebuloch, { useEnduranceCharges = true, overrideEnduranceCharges = 1 }).CritChance)
	end)

	it("with approximations on, Nebuloch's crits spend the estimated Endurance Charges instead of always critting", function()
		local output = setup(nebuloch.."\n30% chance to gain an Endurance Charge on kill", { useApproximations = true, approxKillsPerSecond = 1 })
		-- the unarmed attack consumes them, so the kill estimate (4.5 capped at 3) doesn't become the charge count
		assert.are.equals(0, output.EnduranceCharges)
		assert.is_true(output.CritChance < 100)
		-- 0.3 charges/s over the attack rate, at most 100%
		assert.are.near(math.min(1, 0.3 / output.Speed) * 100, output.EnduranceCritShareApprox, 1e-9)
		-- the configured count keeps the exact rule
		assert.are.equals(100, setup(nebuloch, { useEnduranceCharges = true, overrideEnduranceCharges = 1 }).CritChance)
	end)

	it("Spells don't consume Endurance Charges to Critically Hit", function()
		assert.is_true(setup(nebuloch, { useEnduranceCharges = true }, "Fireball").CritChance < 100)
	end)

	local gain = "30% chance to gain a Frenzy Charge on kill"

	it("charge generation does nothing with approximations off", function()
		local output = setup(gain.."\n20% chance to gain a Power Charge on Hit", { approxKillsPerSecond = 0.5 }, "Fireball")
		assert.are.equals(0, output.FrenzyCharges)
		assert.are.equals(0, output.PowerCharges)
		assert.is_nil(output.FrenzyChargesApprox)
		assert.is_nil(output.PowerChargesApprox)
	end)

	it("estimates the average charges from kills with approximations on", function()
		local approx = { useApproximations = true, approxKillsPerSecond = 0.5 }
		local base = setup("", approx, "Fireball")
		assert.are.equals(0, base.FrenzyCharges)
		-- 0.5 kills/s x 30% = 0.15 charges/s, x 15 s duration = 2.25 (at most 3)
		local output = setup(gain, approx)
		assert.are.near(2.25, output.FrenzyCharges, 1e-9)
		-- 50% chance to gain an additional one: 0.225/s x 15 s = 3.375, capped at 3
		assert.are.equals(3, setup(gain.."\n50% chance when you gain a Frenzy Charge to gain an additional Frenzy Charge", approx).FrenzyCharges)
		-- 40% reduced duration: 0.15 x 9 s = 1.35 (PoB floors charge durations to whole seconds)
		assert.are.near(1.35, setup(gain.."\n40% reduced Frenzy Charge Duration", approx).FrenzyCharges, 1e-9)
		-- a random one of the three: 0.5 x 30% / 3 = 0.05/s each, x 15 s = 0.75
		output = setup("30% chance to gain a Power, Frenzy, or Endurance Charge on kill", approx)
		assert.are.near(0.75, output.PowerCharges, 1e-9)
		assert.are.near(0.75, output.EnduranceCharges, 1e-9)
		-- Resonance: Frenzy Charges come as Power Charges
		output = setup(gain.."\nGain Power Charges instead of Frenzy Charges", approx)
		assert.are.equals(0, output.FrenzyCharges)
		assert.are.near(2.25, output.PowerCharges, 1e-9)
		-- Redflare Conduit: the count cycles 0..2, about (3 - 1) / 2 = 1
		assert.are.near(1, setup("90% chance to gain a Power Charge on kill\nLose all Power Charges on reaching maximum Power Charges", approx).PowerCharges, 1e-9)
		-- the estimate feeds per-charge modifiers, which count whole charges (2 of 2.25): 20% increased
		local damage = setup("10% increased Damage per Frenzy Charge", approx).TotalDPS
		assert.are.near(damage * 1.2, setup(gain.."\n10% increased Damage per Frenzy Charge", approx).TotalDPS, damage * 0.001)
	end)

	it("an explicit charge count wins over the estimate", function()
		local approx = { useApproximations = true, approxKillsPerSecond = 0.5, useFrenzyCharges = true }
		-- "Do you use Frenzy Charges?" without a count means the maximum
		local output = setup(gain, approx, "Fireball")
		assert.are.equals(3, output.FrenzyCharges)
		assert.is_nil(output.FrenzyChargesApprox)
		assert.are.equals(1, setup(gain, { overrideFrenzyCharges = 1 }).FrenzyCharges)
	end)

	it("reports hit-based generation and consumption after offence", function()
		local approx = { useApproximations = true, approxKillsPerSecond = 0 }
		local output = setup("5% chance to gain a Power Charge on Hit", approx, "Fireball")
		-- hits are only known after offence: the count stays 0 and the estimate is reported
		assert.are.equals(0, output.PowerCharges)
		assert.are.near(math.min(3, 0.05 * output.Speed * 15), output.PowerChargesApprox, 1e-9)
		-- critical hits: the spell always hits, so crits per second = casts x crit chance
		output = setup("10% chance to gain a Power Charge on Critical Hit", approx)
		assert.are.near(math.min(3, 0.1 * output.Speed * output.CritChance / 100 * 15), output.PowerChargesApprox, 1e-9)
	end)

	it("doesn't report an estimate for minimum charges or converted charge types", function()
		local approx = { useApproximations = true, approxKillsPerSecond = 1 }
		local output = setup("+1 to Minimum Endurance Charges", approx, "Fireball")
		assert.are.equals(1, output.EnduranceCharges)
		assert.is_nil(output.EnduranceChargesApprox)
		assert.is_nil(setup("30% chance to gain an Endurance Charge on Hit\nGain Brutal Charges instead of Endurance Charges", approx).EnduranceChargesApprox)
	end)

	it("a main skill that consumes the charges leaves the count alone and reports charges per use", function()
		build.itemsTab:CreateDisplayItemFromRaw("New Item\nWrapped Quarterstaff\n")
		build.itemsTab:AddDisplayItem()
		local mods = "20% chance to gain a Power Charge on kill\nSkills have 10% chance to not remove Charges but still count as consuming them"
		local output = setup(mods, { useApproximations = true, approxKillsPerSecond = 1 }, "Falling Thunder")
		assert.is_true(output.Speed > 0)
		assert.are.equals(0, output.PowerCharges)
		-- 0.2 charges/s; 90% of uses remove them, so a use finds the charges of 1 / (0.9 x speed) seconds
		local perUse = math.min(3, 0.2 * math.min(15, 1 / (0.9 * output.Speed)))
		assert.are.near(perUse, output.PowerChargesApprox, 1e-9)
		-- every use counts as consuming them: consumed in the past 4 seconds
		assert.are.near(output.Speed * perUse * 4, output.PowerChargesConsumedRecentlyApprox, 1e-9)
	end)
end)
