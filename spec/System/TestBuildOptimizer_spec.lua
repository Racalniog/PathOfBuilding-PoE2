describe("BuildOptimizer", function()
	local optimizer

	before_each(function()
		newBuild()
		optimizer = LoadModule("Modules/BuildOptimizer")
	end)

	local function score()
		local output = build.calcsTab.mainOutput
		return (output.CombinedDPS or 0) + (output.Minion and output.Minion.CombinedDPS or 0)
	end

	-- Small search space so the test stays fast
	local quickOptions = {
		rounds = 1,
		points = 8,
		ascendancyPoints = 2,
		maxSupports = 2,
		supportStarts = 1,
		baseCandidates = 1,
		weaponCombos = 1,
		treeVerify = 3,
		treeRefineFails = 1,
		runes = false,
		auxSkills = false,
		flasks = false,
		uniquePairAnchors = 1,
	}

	it("rejects unknown classes, ascendancies and skills", function()
		local ok, errMsg = optimizer.SetupCharacter(build, { class = "Bard", skill = "Spark" })
		assert.is_nil(ok)
		assert.is_truthy(errMsg:match("Unknown class"))

		ok, errMsg = optimizer.SetupCharacter(build, { class = "Sorceress", ascendancy = "Deadeye", skill = "Spark" })
		assert.is_nil(ok)
		assert.is_truthy(errMsg:match("Unknown ascendancy"))

		ok, errMsg = optimizer.SetupCharacter(build, { class = "Sorceress", skill = "Not A Real Skill Gem" })
		assert.is_nil(ok)
		assert.is_truthy(errMsg)
	end)

	it("sets up class, ascendancy, level and main skill", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Sorceress", ascendancy = "Stormweaver", skill = "Spark", level = 90 }))
		assert.are.equals("Sorceress", build.spec.curClassName)
		assert.are.equals("Stormweaver", build.spec.curAscendClassName)
		assert.are.equals(90, build.characterLevel)
		local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
		assert.are.equals("Spark", group.gemList[1].nameSpec)
		assert.is_true(score() > 0)
	end)

	it("improves a spell build within its budgets", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Sorceress", ascendancy = "Stormweaver", skill = "Spark" }))
		local before = score()
		local result, errMsg = optimizer.Optimize(build, quickOptions)
		assert.is_nil(errMsg)
		assert.is_true(result.score > before)
		assert.are.equals(0, result.errors)
		-- The reported score is what the build actually calculates to
		assert.is_true(math.abs(result.score - score()) <= result.score * 1e-6)

		local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
		assert.is_true(#group.gemList - 1 <= quickOptions.maxSupports)
		assert.is_true(#group.gemList > 1)
		local used, ascUsed = build.spec:CountAllocNodes()
		assert.is_true(used > 0 and used <= quickOptions.points)
		assert.is_true(ascUsed <= quickOptions.ascendancyPoints)
		assert.is_truthy(build.itemsTab.items[build.itemsTab.slots["Weapon 1"].selItemId])
		-- Jewels are only left in sockets that are allocated
		for nodeId, slot in pairs(build.itemsTab.sockets) do
			if slot.selItemId ~= 0 then
				assert.is_true(build.spec.nodes[nodeId].alloc)
			end
		end
	end)

	it("finds a weapon for an attack skill and never gets worse when uniques are allowed", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Ranger", ascendancy = "Deadeye", skill = "Lightning Arrow" }))
		assert.are.equals(0, score())
		local rares = optimizer.Optimize(build, quickOptions)
		assert.is_true(rares.score > 0)
		assert.are.equals("Bow", build.itemsTab.items[build.itemsTab.slots["Weapon 1"].selItemId].base.type)
		for _, item in pairs(build.itemsTab.items) do
			assert.are_not.equals("UNIQUE", item.rarity)
		end

		local options = copyTable(quickOptions)
		options.allowUniques = true
		local uniques = optimizer.Optimize(build, options)
		assert.is_true(uniques.score >= rares.score)
	end)

	it("adds supporting skills without overspending Spirit, and at most one mark", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Ranger", ascendancy = "Deadeye", skill = "Lightning Arrow" }))
		local options = copyTable(quickOptions)
		options.auxSkills = true
		options.flasks = true
		local plain = optimizer.Optimize(build, quickOptions)
		local result = optimizer.Optimize(build, options)
		assert.is_true(result.score > plain.score)
		assert.is_true((build.calcsTab.mainOutput.SpiritUnreserved or 0) >= 0)
		local marks, others = 0, 0
		for index, group in ipairs(build.skillsTab.socketGroupList) do
			if index ~= build.mainSocketGroup and not group.source then
				others = others + 1
				if group.gemList[1].gemData.tags.mark then
					marks = marks + 1
				end
			end
		end
		assert.is_true(others > 0 and others < 9)
		assert.is_true(marks <= 1)
		-- The main skill is still the one being measured
		assert.are.equals("Lightning Arrow", build.skillsTab.socketGroupList[build.mainSocketGroup].gemList[1].nameSpec)
	end)

	it("survives a save and reload with the same result", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Monk", ascendancy = "Invoker", skill = "Ice Strike" }))
		local result = optimizer.Optimize(build, quickOptions)
		local xmlText = build:SaveDB("Optimizer Test")
		loadBuildFromXML(xmlText, "Optimizer Test")
		assert.is_true(math.abs(result.score - score()) <= result.score * 1e-6)
	end)
end)
