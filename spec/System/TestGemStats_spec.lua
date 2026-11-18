describe("TestGemStats", function()
	before_each(function()
		newBuild()
	end)

	local function recalculate()
		build.buildFlag = true
		runCallback("OnFrame")
	end

	local function equipMace()
		build.itemsTab:CreateDisplayItemFromRaw("New Item\nMarauding Mace")
		build.itemsTab:AddDisplayItem()
	end

	it("applies the more damage of Combo Finisher I through the skill stat map", function()
		equipMace()
		build.skillsTab:PasteSocketGroup("Leap Slam 1/0  1")
		recalculate()
		local base = build.calcsTab.mainOutput.AverageDamage
		assert.is_true(base > 0)

		newBuild()
		equipMace()
		build.skillsTab:PasteSocketGroup("Leap Slam 1/0  1\nCombo Finisher I 1/0  1")
		recalculate()
		assert.are.near(base * 1.25, build.calcsTab.mainOutput.AverageDamage, 0.01 * base)
	end)

	it("applies the damage and area penalties of Echoing Cry", function()
		build.skillsTab:PasteSocketGroup("Infernal Cry 1/0  1\nEchoing Cry 1/0  1")
		recalculate()
		local found
		for _, activeSkill in ipairs(build.calcsTab.calcsEnv.player.activeSkillList) do
			if activeSkill.activeEffect.grantedEffect.id == "InfernalCryPlayer" then
				found = true
				assert.are.near(0.6, activeSkill.skillModList:More(activeSkill.skillCfg, "Damage"), 0.001)
				assert.are.near(0.5, activeSkill.skillModList:More(activeSkill.skillCfg, "AreaOfEffect"), 0.001)
			end
		end
		assert.is_true(found)
	end)

	it("lists only stats without a calculation in the no-calculation list", function()
		local count = 0
		for stat in pairs(data.skillStatNoCalc) do
			count = count + 1
			assert.is_nil(data.skillStatMap[stat], stat)
		end
		assert.is_true(count > 0)
		for id, grantedEffect in pairs(data.skills) do
			for _, statSet in ipairs(grantedEffect.statSets or { }) do
				for stat in pairs(statSet.statMap or { }) do
					assert.is_nil(data.skillStatNoCalc[stat], id .. ": " .. stat)
				end
			end
		end
	end)
end)
