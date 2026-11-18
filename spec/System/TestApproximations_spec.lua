describe("TestApproximations", function()
	before_each(function()
		newBuild()
	end)

	local function setup(customMods, useApprox, killsPerSecond)
		build.configTab.input.customMods = customMods
		build.configTab.input.useApproximations = useApprox
		build.configTab.input.approxKillsPerSecond = killsPerSecond
		build.configTab:BuildModList()
		runCallback("OnFrame")
		return build.calcsTab.mainOutput
	end

	local presenceLine = "Recover 5% of your maximum Life when an Enemy dies in your Presence"

	it("on-kill recovery contributes nothing while approximations are off", function()
		local base = setup("", false, 2).LifeRegenRecovery
		local output = setup(presenceLine, false, 2)
		assert.are.equals(base, output.LifeRegenRecovery)
		assert.is_nil(output.LifeOnKillApproxRecovery)
	end)

	it("on-kill recovery becomes amount per kill x kills per second when on", function()
		local base = setup("", true, 2).LifeRegenRecovery
		local output = setup(presenceLine, true, 2)
		-- 5% of maximum Life per kill x 2 kills per second = 10% of maximum Life per second;
		-- PercentStat rounds the per-kill amount up to a whole number (existing engine rule)
		local expected = math.ceil(output.Life * 5 / 100) * 2
		assert.is_true(output.Life > 0 and math.abs(expected - output.Life * 0.1) < 2)
		assert.are.equals(expected, output.LifeOnKillApproxRecovery)
		assert.are.equals(base + expected, output.LifeRegenRecovery)
		-- not scaled by regeneration or recovery rate modifiers
		output = setup(presenceLine.."\n100% increased Life Regeneration rate\n50% increased Life Recovery rate", true, 2)
		assert.are.equals(math.ceil(output.Life * 5 / 100) * 2, output.LifeOnKillApproxRecovery)
		-- 0 kills per second (single boss) gives nothing
		assert.is_nil(setup(presenceLine, true, 0).LifeOnKillApproxRecovery)
	end)

	it("flat and percent on-kill lines feed the same rate and respect cannot-gain flags", function()
		local output = setup("Gain 10 Mana per enemy killed\nRecover 4% of maximum Energy Shield on Kill\n+100 to maximum Energy Shield", true, 2)
		assert.are.equals(20, output.ManaOnKillApproxRecovery)
		assert.are.equals(math.ceil(output.EnergyShield * 4 / 100) * 2, output.EnergyShieldOnKillApproxRecovery)
		assert.is_nil(setup("Recover 4% of maximum Life on Killing a Poisoned Enemy", true, 2).LifeOnKillApproxRecovery)
		build.configTab.input.conditionEnemyPoisoned = true
		output = setup("Recover 4% of maximum Life on Killing a Poisoned Enemy", true, 2)
		assert.are.equals(math.ceil(output.Life * 4 / 100) * 2, output.LifeOnKillApproxRecovery)
		assert.is_nil(setup(presenceLine.."\nCannot Recover Life other than from Leech", true, 2).LifeOnKillApproxRecovery)
	end)

	it("top bar button flips the config option and its label", function()
		runCallback("OnFrame")
		local button = build.controls.approxToggle
		local check = build.configTab.varControls.useApproximations
		assert.are.equals("Approx: Off", button:GetProperty("label"))
		build.configTab.modFlag = false
		button.onClick()
		assert.is_true(build.configTab.input.useApproximations)
		assert.is_true(check.state)
		assert.is_true(build.configTab.modFlag)
		assert.are.equals("Approx: On", button:GetProperty("label"))
		runCallback("OnFrame")
		assert.is_true(build.calcsTab.mainEnv.modDB:Flag(nil, "Condition:UseApproximations"))
		-- ticking the checkbox updates the button
		check.changeFunc(false)
		assert.are.equals("Approx: Off", button:GetProperty("label"))
	end)
end)
