describe("OptimizerTab", function()
	local tab
	local viewPort = { x = 0, y = 0, width = 1280, height = 800 }

	before_each(function()
		newBuild()
		tab = build.optimizerTab
		tab:Draw(viewPort, { })
	end)

	local function select(control, label)
		for index, value in ipairs(control.list) do
			if (type(value) == "table" and value.label or value) == label then
				control:SetSel(index)
				return
			end
		end
		error("no entry " .. label)
	end

	local function start()
		local launched
		local realLaunch = LaunchSubScript
		LaunchSubScript = function(script, funcList, subList, setupText, optionsText, scriptPath, token)
			launched = { script = script, subList = subList, scriptPath = scriptPath, token = token,
				setup = loadstring("return " .. setupText)(), options = loadstring("return " .. optionsText)() }
			return "optimizer test job"
		end
		tab:Start()
		-- Results of an earlier run are only discarded after confirming
		local popup = main.popups[1]
		if popup then
			popup.controls.confirm:Click()
		end
		LaunchSubScript = realLaunch
		return launched
	end

	it("fills the form from the tree and the gem data", function()
		assert.is_true(#tab.controls.class.list >= 6)
		select(tab.controls.class, "Ranger")
		local ascendancies = { }
		for _, entry in ipairs(tab.controls.ascendancy.list) do
			ascendancies[entry.label] = true
		end
		assert.is_true(ascendancies["Auto (compare all)"])
		assert.is_true(ascendancies["Deadeye"])
		select(tab.controls.skill, "Lightning Arrow")
	end)

	it("hands the background job the same options as the command line", function()
		select(tab.controls.class, "Ranger")
		select(tab.controls.ascendancy, "Deadeye")
		select(tab.controls.skill, "Lightning Arrow")
		tab.controls.rounds:SetText("0")
		tab.controls.restarts:SetText("3")
		tab.checks.combos.state = false
		tab.checks.sustained.state = true
		tab.checks.approximations.state = true
		tab.controls.survivability:SetVal(0.5)
		local launched = start()

		assert.are.equal("OptimizerProgress", launched.subList)
		assert.is_truthy(launched.script:match("HeadlessWrapper"))
		assert.are.same({ class = "Ranger", ascendancy = "Deadeye", skill = "Lightning Arrow", level = 100, name = "Lightning Arrow Deadeye" }, launched.setup)
		local options = launched.options
		-- Out-of-range input is clamped: no rounds would mean no search
		assert.are.equal(1, options.rounds)
		assert.are.equal(3, options.restarts) -- --restarts 3
		assert.are.equal(1, options.affixRoll)
		assert.are.equal(82, options.itemLevel)
		assert.are.equal(5, options.maxSupports)
		assert.are.equal(4, options.treeWidth)
		assert.are.equal("CombinedDPS", options.metric)
		assert.are.equal("sustained", options.assume)
		assert.is_false(options.autoAscendancy)
		assert.is_false(options.combos)
		assert.is_true(options.uniques)
		assert.is_false(options.legacyUniques)
		assert.is_false(options.uniqueVariants)
		assert.is_nil(options.points)
		-- --survivability 0.5 --approx: the kill rate is left to the optimizer's default of 1, as on the command line
		assert.are.equal(0.5, options.survivability)
		assert.is_true(options.approximations)
		assert.is_nil(options.killsPerSecond)
		-- The form still fits a 1280x720 window (the tab gets the height below the 32 pixel top bar)
		local _, noteY = tab.controls.note:GetPos()
		assert.is_true(noteY + 28 <= 720 - 32)
	end)

	it("collects progress and results from the background job", function()
		select(tab.controls.skill, "Lightning Arrow")
		local token = start().token
		assert.is_false(tab.controls.run:IsEnabled())
		assert.is_false(tab.controls.result_raresOpen:IsEnabled())

		assert.is_nil(OptimizerProgress(token, "log", "[round 1] weapons"))
		assert.is_nil(OptimizerProgress(token, "result", "rares", 1234.5, "<PathOfBuilding/>", "Ranger\n== Skill links =="))
		launch.subScripts["optimizer test job"].callback(nil)
		tab:Draw(viewPort, { })

		assert.is_true(tab.controls.run:IsEnabled())
		assert.is_true(tab.controls.result_raresOpen:IsEnabled())
		assert.is_false(tab.controls.result_uniquesOpen:IsEnabled())
		assert.is_truthy(tab:StatusText():match("finished"))
		tab.controls.result_raresSummary:Click()
		tab:Draw(viewPort, { })
		assert.are.equal("^xE0C060== Skill links ==", tab.controls.text.list[2][1])
	end)

	it("reports a background job that fails or can't be started", function()
		select(tab.controls.skill, "Lightning Arrow")
		start()
		launch.subScripts["optimizer test job"].callback("'Spark' is not an active skill gem\nstack traceback: ...")
		assert.are.equal("^7Status: ^1failed^7 after 0:00: 'Spark' is not an active skill gem", tab:StatusText())

		local realLaunch = LaunchSubScript
		LaunchSubScript = function() error("compile error") end
		tab:Start()
		LaunchSubScript = realLaunch
		assert.is_truthy(tab:StatusText():match("could not be started"))
		assert.is_true(tab.controls.run:IsEnabled())
	end)

	it("ignores reports of a cancelled or replaced job", function()
		select(tab.controls.skill, "Lightning Arrow")
		local first = start().token
		local second = start().token
		OptimizerProgress(first, "result", "rares", 1, "<old/>", "old job")
		OptimizerProgress(second, "log", "new job")
		tab:Cancel()
		OptimizerProgress(second, "result", "uniques", 2, "<late/>", "after cancel")
		tab:Draw(viewPort, { })
		assert.is_false(tab.controls.result_raresOpen:IsEnabled())
		assert.is_false(tab.controls.result_uniquesOpen:IsEnabled())
		assert.is_truthy(tab.controls.text.list[3][1]:match("new job"))
		assert.is_truthy(tab:StatusText():match("cancelled"))
		-- The settings of the last run survive the tab being re-created with another build
		newBuild()
		build.optimizerTab:Draw(viewPort, { })
		assert.are.equal("Lightning Arrow", build.optimizerTab.controls.skill:GetSelValue())
	end)
end)
