describe("TestRecentlyConsumed", function()
	before_each(function()
		newBuild()
	end)

	local function setup(skill, weapon, customMods)
		build.skillsTab:PasteSocketGroup(skill .. " 20/0 1\n")
		if weapon then
			build.itemsTab:CreateDisplayItemFromRaw("New Item\n" .. weapon .. "\n")
			build.itemsTab:AddDisplayItem()
		end
		build.configTab.input.customMods = customMods
		build.configTab:BuildModList()
		runCallback("OnFrame")
	end

	local function recalc(input)
		for key, value in pairs(input or { }) do
			build.configTab.input[key] = value
		end
		build.configTab:BuildModList()
		build.buildFlag = true
		runCallback("OnFrame")
		return build.calcsTab.mainOutput
	end

	it("scales with charges consumed recently only once the count is configured", function()
		setup("Fireball", nil, "20% increased Fire Damage per Endurance Charge consumed Recently")
		local base = recalc().TotalDPS
		local withThree = recalc({ multiplierEnduranceChargesConsumedRecently = 3 }).TotalDPS
		assert.is_true(base > 0)
		-- 3 x 20% increased, with nothing else increasing the damage
		assert.is_true(math.abs(withThree / base - 1.6) < 0.01)
	end)

	it("applies infusion, spell variety and Glory conditions", function()
		setup("Fireball", nil, "40% increased Fire Damage if you've collected a Fire Infusion in the last 8 seconds\n10% increased Cast Speed for each different Spell you've Cast in the last eight seconds\nDamage Penetrates 10% Elemental Resistances for each time you've used a Skill that Requires Glory in the past 6 seconds")
		local base = recalc().TotalDPS
		local infusion = recalc({ conditionCollectedFireInfusionRecently = true }).TotalDPS
		assert.is_true(infusion > base * 1.3)
		local spells = recalc({ multiplierDifferentSpellsCastRecently = 2 }).TotalDPS
		assert.is_true(spells > infusion * 1.15)
		local glory = recalc({ multiplierGlorySkillsUsedRecently = 2 }).TotalDPS
		assert.is_true(glory > spells)
	end)

	it("caps attack damage from consumed Glory at the stated maximum", function()
		setup("Lightning Arrow", "Crude Bow", "Consuming Glory grants you 3% increased Attack damage per Glory consumed for 6 seconds, up to 60%")
		local base = recalc().TotalDPS
		local ten = recalc({ multiplierGloryConsumedRecently = 10 }).TotalDPS
		local thirty = recalc({ multiplierGloryConsumedRecently = 30 }).TotalDPS
		-- Damage on a starter bow is small enough for rounding to show, hence the loose bounds
		assert.is_true(math.abs(ten / base - 1.3) < 0.03)
		assert.is_true(math.abs(thirty / base - 1.6) < 0.03)
	end)

	it("counts an additional Aftershock as one more hit for Slams only", function()
		setup("Rolling Slam", "Felled Greatclub", nil)
		local base = recalc().TotalDPS
		build.configTab.input.customMods = "Slam Skills you use yourself cause an additional Aftershock"
		local doubled = recalc().TotalDPS
		assert.is_true(base > 0)
		assert.is_true(math.abs(doubled / base - 2) < 0.01)
		build.configTab.input.customMods = "50% chance for Slam Skills you use yourself to cause an additional Aftershock"
		assert.is_true(math.abs(recalc().TotalDPS / base - 1.5) < 0.01)
	end)

	it("leaves non-Slam skills alone when Aftershocks are added", function()
		setup("Fireball", nil, nil)
		local base = recalc().TotalDPS
		build.configTab.input.customMods = "Slam Skills you use yourself cause an additional Aftershock"
		assert.are.equals(base, recalc().TotalDPS)
	end)
end)
