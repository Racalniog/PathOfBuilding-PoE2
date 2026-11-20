-- Skills from items and the tree that are buffs for the main skill: the buff applies while its socket group is enabled
describe("TestBuffSkills", function()
	local optimizer

	before_each(function()
		newBuild()
		optimizer = LoadModule("Modules/BuildOptimizer")
	end)

	-- TotalDPS of `main` (a skill gem pasted as a second socket group, with `weapon`) with the buff skill's group enabled and not
	local function buffed(class, buff, source, main, weapon, config)
		assert.is_true(optimizer.SetupCharacter(build, { class = class, skill = buff, skillSource = source, level = 95 }))
		local buffGroup = build.mainSocketGroup
		if weapon then
			build.itemsTab:CreateDisplayItemFromRaw("New Item\n" .. weapon .. "\n")
			build.itemsTab:AddDisplayItem()
		end
		build.skillsTab:PasteSocketGroup(main)
		build.mainSocketGroup = #build.skillsTab.socketGroupList
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		local function dps(enabled)
			build.skillsTab.socketGroupList[buffGroup].enabled = enabled
			build.configTab:BuildModList()
			build.buildFlag = true
			runCallback("OnFrame")
			return build.calcsTab.mainOutput.TotalDPS
		end
		return dps(true), dps(false)
	end

	it("applies Sigil of Power's Spell damage per stage", function()
		-- 10% more Spell damage per stage, four stages at most
		local on, off = buffed("Witch", "Sigil of Power", "item", "Spark 20/0  1", nil, { sigilOfPowerStages = 4 })
		assert.is_true(off > 0)
		assert.are.near(off * 1.4, on, off * 0.01) -- (the level scales the 10%)
	end)

	it("applies Unbound Avatar's Elemental damage while Unbound, and nothing otherwise", function()
		local weapon = "Gothic Quarterstaff"
		local on, off = buffed("Monk", "Unbound Avatar", "tree", "Ice Strike 20/0  1", weapon, { Unbound = true })
		assert.is_true(off > 0)
		assert.is_true(on > off * 1.2)
		newBuild()
		on, off = buffed("Monk", "Unbound Avatar", "tree", "Ice Strike 20/0  1", weapon, { Unbound = false })
		assert.are.equals(off, on)
	end)
end)
