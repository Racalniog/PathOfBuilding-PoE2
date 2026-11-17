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
		weaponSets = false,
		treeWidth = 1,
	}

	it("leaves out legacy and unobtainable uniques unless asked to include them", function()
		local variants = optimizer.UniqueVariants
		assert.are.same({ false }, variants({ }, false))
		assert.are.same({ }, variants({ source = "No longer obtainable" }, false))
		assert.are.same({ false }, variants({ source = "No longer obtainable" }, true))
		local changed = { variantList = { "Pre 0.1.1", "Pre 0.4.0", "Current" }, variant = 3 }
		assert.are.same({ 3 }, variants(changed, false))
		assert.are.same({ 3, 1, 2 }, variants(changed, true))
		-- A legacy or test variant selected by default falls back to the newest current one
		assert.are.same({ 2 }, variants({ variantList = { "Fire (Pre 0.2.1 )", "Fire", "0.2.0" }, variant = 3 }, false))
		assert.are.same({ 1 }, variants({ variantList = { "Zealot's Oath", "Everything (QoL Test Variant)" }, variant = 2 }, true))
		-- Real alternatives are not legacy
		assert.are.same({ 1 }, variants({ variantList = { "Helmet", "Gloves" }, variant = 1 }, false))

		-- None of the database's uniques comes out as a legacy version or the test variant by default
		for _, source in pairs(main.uniqueDB.list) do
			for _, variant in ipairs(variants(source, false)) do
				local name = variant and source.variantList[variant] or ""
				assert.is_falsy(name:match("^Pre ") or name:match("%(Pre ") or name:match("^%d+%.%d+") or name:find("Test Variant", 1, true))
			end
		end
		assert.are.same({ }, variants(main.uniqueDB.list["Infernoclasp, Plate Belt"], false))
	end)

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

	it("scores a minion skill by the number of minions the Spirit pays for", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Witch", ascendancy = "Lich", skill = "Skeletal Sniper" }))
		local result = optimizer.Optimize(build, quickOptions)
		local gemInstance = build.skillsTab.socketGroupList[build.mainSocketGroup].gemList[1]
		local output = build.calcsTab.mainOutput
		assert.is_true(gemInstance.count > 1)
		assert.is_true((output.SpiritUnreserved or 0) >= 0)
		assert.is_true(math.abs(result.score - output.Minion.CombinedDPS * gemInstance.count) <= result.score * 1e-6)
	end)

	it("keeps the point budget when the second weapon set is used, and builds trees of different widths", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Sorceress", ascendancy = "Stormweaver", skill = "Spark" }))
		local options = copyTable(quickOptions)
		options.auxSkills = true
		options.weaponSets = true
		options.treeWidth = 2
		options.points = 30
		local result = optimizer.Optimize(build, options)
		assert.is_true(result.score > 0)
		local used, _, _, _, set1Used, set2Used = build.spec:CountAllocNodes()
		assert.is_true(used - math.min(set1Used, set2Used) <= options.points)
		assert.is_true(set2Used <= 24)
		assert.is_truthy(optimizer.ConfigReport(build, options):match("== Configuration =="))
		assert.is_truthy(optimizer.CoverageReport(build):match("Unique items"))
		assert.is_truthy(optimizer.BlindSpotReport(build, options):match("== Strong options the engine could not fully evaluate =="))
	end)

	it("survives a save and reload with the same result", function()
		assert.is_true(optimizer.SetupCharacter(build, { class = "Monk", ascendancy = "Invoker", skill = "Ice Strike" }))
		local result = optimizer.Optimize(build, quickOptions)
		local xmlText = build:SaveDB("Optimizer Test")
		loadBuildFromXML(xmlText, "Optimizer Test")
		assert.is_true(math.abs(result.score - score()) <= result.score * 1e-6)
	end)
end)
