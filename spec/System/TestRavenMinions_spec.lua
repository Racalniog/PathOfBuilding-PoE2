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
end)
