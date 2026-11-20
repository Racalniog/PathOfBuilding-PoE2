describe("TestRavenMinions", function()
	before_each(function()
		newBuild()
	end)

	local function setup(class, skill)
		local optimizer = LoadModule("Modules/BuildOptimizer")
		assert.is_true(optimizer.SetupCharacter(build, { class = class, skill = skill, skillSource = "item", level = 95 }))
		return build.calcsTab.mainEnv, build.calcsTab.mainOutput
	end

	-- The Raven's Flock: the flock deals damage over time, so the minion's TotalDPS is 0 and its Combined DPS (what the optimiser scores) is the Dot
	it("counts the damage over time of Spiraling Conspiracy's flock", function()
		local env, output = setup("Witch", "Spiraling Conspiracy")
		assert.are.equals("Winged Entropy", env.minion.mainSkill.activeEffect.grantedEffect.name)
		assert.are.equals(2, #env.minion.activeSkillList)
		assert.are.equals(0, output.Minion.TotalDPS)
		assert.is_true(output.Minion.TotalDot > 0)
		assert.are.near(output.Minion.TotalDot, output.Minion.CombinedDPS, 1e-9)
	end)

	-- The Auspex: the raven's damage is its Command, Mad Flight (one use per cooldown); the flock's swarm aura isn't the raven's
	it("calculates Mist Raven's minion with the skill it is Commanded to use", function()
		local env, output = setup("Ranger", "Mist Raven")
		assert.is_truthy(env.minion)
		assert.are.equals(1, #env.minion.activeSkillList)
		assert.are.equals("Mad Flight", env.minion.mainSkill.activeEffect.grantedEffect.name)
		local minion = output.Minion
		assert.is_true(minion.CombinedDPS > 0)
		assert.are.near(minion.AverageDamage * minion.Speed, minion.CombinedDPS, 1e-9)
		assert.are.near(1 / minion.Cooldown, minion.Speed, 1e-9)
	end)

	-- Mad Flight's flock Hits every 120 ms for the mirrors' duration; PoB counts one Hit per use, the approximation scales it by the share of
	-- the duration the enemy stands between the mirrors (input approxMadFlightShare, default 25%, at least the one Hit)
	it("counts Mad Flight's repeated flock Hits with approximations on, by the share of the duration the enemy is in the mirrors", function()
		local env, output = setup("Ranger", "Mist Raven")
		local exact, duration = output.Minion.CombinedDPS, output.Minion.Duration
		local function with(config)
			for var, val in pairs(config) do
				build.configTab.input[var] = val
			end
			build.configTab:BuildModList()
			build.buildFlag = true
			runCallback("OnFrame")
			return build.calcsTab.mainOutput.Minion, build.calcsTab.mainEnv.minion.mainSkill
		end
		local minion = with({ useApproximations = true })
		assert.are.near(exact * duration * 1000 / 120 * 0.25, minion.CombinedDPS, exact * 1e-9) -- the default share, 25%
		minion = with({ approxMadFlightShare = 100 })
		assert.are.near(exact * duration * 1000 / 120, minion.CombinedDPS, exact * 1e-9)
		assert.are.near(minion.AverageDamage * minion.Speed * minion.DpsMultiplier, minion.CombinedDPS, 1e-6)
		local minion, skill = with({ approxMadFlightShare = 0 })
		assert.are.near(exact, minion.CombinedDPS, exact * 1e-9) -- never less than the one Hit PoB counts
		assert.is_truthy(skill.infoMessage2:match("Approximation"))
		minion = with({ useApproximations = false, approxMadFlightShare = 100 })
		assert.are.near(exact, minion.CombinedDPS, 1e-9) -- approximations off: the share changes nothing
	end)
end)
