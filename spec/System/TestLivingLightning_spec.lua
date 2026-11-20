describe("TestLivingLightning", function()
	before_each(function()
		newBuild()
	end)

	local function calc(group, skillId, config, customMods)
		build.itemsTab:CreateDisplayItemFromRaw("New Item\nWooden Club\n")
		build.itemsTab:AddDisplayItem()
		build.skillsTab:PasteSocketGroup(group)
		runCallback("OnFrame")
		build.configTab.input.customMods = customMods or ""
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.mainSocketGroup = 1
		local socketGroup = build.skillsTab.socketGroupList[1]
		for index, skill in ipairs(socketGroup.displaySkillList) do
			if skill.activeEffect.grantedEffect.id == skillId then
				socketGroup.mainActiveSkill = index
			end
		end
		build.buildFlag = true
		runCallback("OnFrame")
		local mainSkill = build.calcsTab.mainEnv.player.mainSkill
		return copyTable(build.calcsTab.mainOutput, true), mainSkill, build.calcsTab.mainEnv
	end

	local approx = { useApproximations = true }
	local group = "Spark 20/0  1\nLiving Lightning II 1/0  1"
	local id = "TriggeredLivingLightningPlayerTwo"

	local function fullDPS()
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.buildFlag = true
		runCallback("OnFrame")
		return build.calcsTab.mainOutput.FullDPS
	end

	it("triggers on the Hits of a skill that deals Lightning damage, capped by its cooldown", function()
		local spark = calc(group, "SparkPlayer", approx)
		local hits = spark.Speed * spark.HitChance / 100
		assert.is_true(hits > 0)
		newBuild()
		local output, skill = calc(group, id, approx)
		assert.are.equals("Living Lightning II's Trigger: Spark", skill.infoMessage)
		-- 5 stored uses, 0.2 s cooldown: at most 5 per second
		assert.are.near(math.min(hits, 1 / 0.2), output.Speed, 1e-9)
		-- more Hits than the cooldown allows
		newBuild()
		output = calc(group, id, approx, "500% increased Cast Speed")
		assert.are.near(5, output.Speed, 1e-9)
		-- approximations off: the self-cast rate
		newBuild()
		output, skill = calc(group, id)
		assert.is_nil(skill.infoMessage)
		assert.are.equals(1, output.Speed)
	end)

	it("doesn't trigger from a skill that deals no Lightning damage, or from no skill", function()
		for _, case in ipairs({ "Fireball 20/0  1\nLiving Lightning II 1/0  1", "Living Lightning II 1/0  1" }) do
			newBuild()
			local output, skill = calc(case, id, approx)
			assert.are.equals(0, output.Speed)
			assert.are.equals("No Hits that deal Lightning damage to trigger Living Lightning: no triggers", skill.infoMessage2)
		end
	end)

	it("counts the Minions alive in Full DPS: triggers per second x duration, at most the limit", function()
		local spark = calc(group, "SparkPlayer", approx)
		local sparkDPS = spark.TotalDPS
		newBuild()
		local output, _, env = calc(group, id, approx)
		local perMinion = env.minion.output.TotalDPS
		assert.is_true(perMinion > 0 and math.abs(output.Duration - 30) < 0.1 and output.ActiveMinionLimit == 8)
		local alive = math.min(8, output.Speed * output.Duration)
		assert.is_true(alive >= 1)
		assert.are.near(sparkDPS + alive * perMinion, fullDPS(), 1e-6 * (sparkDPS + alive * perMinion))
		-- a slow trigger rate keeps fewer than the limit alive
		newBuild()
		local slowSpark = calc(group, "SparkPlayer", approx, "90% less Cast Speed")
		newBuild()
		output, _, env = calc(group, id, approx, "90% less Cast Speed")
		alive = math.min(8, output.Speed * output.Duration)
		assert.is_true(alive < 8)
		assert.are.near(slowSpark.TotalDPS + alive * env.minion.output.TotalDPS, fullDPS(), 1e-6 * fullDPS())
	end)
end)
