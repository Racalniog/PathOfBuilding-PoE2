-- Path of Building
--
-- Module: Optimizer Tab
-- Front end for Modules/BuildOptimizer: builds a character around one skill gem and searches for
-- the setup with the most damage. The search runs in a background subscript
-- (OptimizerSubScript.lua) with its own copy of the program, so the window stays responsive and
-- the open build is untouched until the user opens a result. See docs/buildOptimizer.md.
--
local t_insert = table.insert
local t_sort = table.sort
local m_floor = math.floor
local s_format = string.format

-- The running/finished job lives outside the tab: opening a result replaces the build (and with
-- it this tab), and the other result must still be there afterwards
local job
local jobCount = 0
-- Form settings of the last run, so they survive the tab being re-created with a new build
local lastSettings

local variants = {
	{ key = "rares", label = "Rare items only" },
	{ key = "uniques", label = "Uniques allowed" },
}
local metrics = { "CombinedDPS", "TotalDPS", "FullDPS", "TotalDot", "AverageDamage" }

local function appendLog(text)
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		t_insert(job.log, s_format("^8[%s]^7 %s", job.clock(), line))
	end
end

-- Called from the subscript through launch:OnSubCall. Reports of a job that was cancelled or
-- replaced (an old token) are dropped
function OptimizerProgress(token, kind, ...)
	if not job or job.token ~= token or job.status ~= "running" then
		return
	end
	if kind == "log" then
		appendLog((...))
	elseif kind == "result" then
		local variant, score, xml, summary = ...
		job.results[variant] = { score = score, xml = xml, summary = summary, name = job.name .. " (" .. variant .. ")" }
		appendLog(s_format("^x33FF77Finished build (%s): %s %s", variant, formatNumSep(tostring(m_floor(score))), job.metric))
	end
end

local function luaSource(value)
	local parts = { }
	writeLuaTable({ write = function(_, ...) for _, text in ipairs({ ... }) do t_insert(parts, text) end end }, value)
	return table.concat(parts)
end

local function formatTime(seconds)
	return s_format("%d:%02d", m_floor(seconds / 60), m_floor(seconds % 60))
end

---@class OptimizerTab: ControlHost, Control
local OptimizerTabClass = newClass("OptimizerTab", "ControlHost", "Control")

function OptimizerTabClass:OptimizerTab(build)
	self:ControlHost()
	self:Control()
	self.build = build
	self.view = "log"

	local function label(anchor, y, text)
		return new("LabelControl"):LabelControl({ "TOPLEFT", anchor, "TOPLEFT" }, { 10, y + 2, 0, 16 }, "^7" .. text)
	end
	local function numberEdit(anchor, y, init, prompt, limit)
		return new("EditControl"):EditControl({ "TOPLEFT", anchor, "TOPLEFT" }, { 120, y, 80, 20 }, init, prompt, "%D", limit)
	end

	-- Character
	local char = new("SectionControl"):SectionControl({ "TOPLEFT", self, "TOPLEFT" }, { 10, 20, 350, 182 }, "Character")
	self.controls.charSection = char
	self.controls.classLabel = label(char, 14, "Class:")
	self.controls.class = new("DropDownControl"):DropDownControl({ "TOPLEFT", char, "TOPLEFT" }, { 120, 14, 220, 20 }, { }, function()
		self:RefreshAscendancies()
	end)
	self.controls.ascendLabel = label(char, 40, "Ascendancy:")
	self.controls.ascendancy = new("DropDownControl"):DropDownControl({ "TOPLEFT", char, "TOPLEFT" }, { 120, 40, 220, 20 }, { },
		nil, "\"Auto\" lets the optimiser build every ascendancy of the class and keep the best.")
	self.controls.skillLabel = label(char, 66, "Skill gem:")
	self.controls.skill = new("DropDownControl"):DropDownControl({ "TOPLEFT", char, "TOPLEFT" }, { 120, 66, 220, 20 }, { },
		nil, "The active skill the build is made for. Type while the list is open to search.")
	self.controls.skill.maxDroppedWidth = 300
	self.controls.levelLabel = label(char, 92, "Character level:")
	self.controls.level = numberEdit(char, 92, "100", nil, 3)
	self.controls.pointsLabel = label(char, 118, "Passive points:")
	self.controls.points = numberEdit(char, 118, "", nil, 3)
	self.controls.points:SetPlaceholder("Auto")
	self.controls.points.tooltipText = "Leave empty to spend every point available at the character level."
	self.controls.fromBuild = new("ButtonControl"):ButtonControl({ "TOPLEFT", char, "TOPLEFT" }, { 120, 148, 220, 20 }, "Use current build", function()
		self:LoadFromBuild()
	end)
	self.controls.fromBuild.tooltipText = "Take class, ascendancy, main skill and level from the build that is open."

	-- Search
	local search = new("SectionControl"):SectionControl({ "TOPLEFT", char, "BOTTOMLEFT" }, { 0, 20, 350, 168 }, "Search")
	self.controls.searchSection = search
	self.controls.metricLabel = label(search, 14, "Maximise:")
	self.controls.metric = new("DropDownControl"):DropDownControl({ "TOPLEFT", search, "TOPLEFT" }, { 120, 14, 220, 20 }, metrics,
		nil, "Calculation output the search maximises. CombinedDPS includes damage over time and minions.")
	self.controls.rollLabel = label(search, 40, "Roll quality:")
	self.controls.roll = new("SliderControl"):SliderControl({ "TOPLEFT", search, "TOPLEFT" }, { 120, 42, 160, 16 })
	self.controls.roll:SetVal(1)
	self.controls.rollValue = new("LabelControl"):LabelControl({ "LEFT", self.controls.roll, "RIGHT" }, { 8, 0, 0, 16 }, function()
		return s_format("^7%d%%", m_floor(self.controls.roll.val * 100 + 0.5))
	end)
	self.controls.roll.tooltipText = "Roll of crafted affixes and unique modifier ranges. 100% is a perfect roll, 50% an average one."
	self.controls.itemLevelLabel = label(search, 66, "Max affix level:")
	self.controls.itemLevel = numberEdit(search, 66, "82", nil, 3)
	self.controls.itemLevel.tooltipText = "Highest modifier tier level that may be crafted on items."
	self.controls.supportsLabel = label(search, 92, "Support gems:")
	self.controls.supports = numberEdit(search, 92, "5", nil, 1)
	self.controls.roundsLabel = label(search, 118, "Rounds:")
	self.controls.rounds = numberEdit(search, 118, "2", nil, 1)
	self.controls.rounds.tooltipText = "Passes over supports -> equipment -> tree -> jewels. More rounds let earlier choices react to later ones."
	self.controls.treeWidthLabel = label(search, 144, "Tree variants:")
	self.controls.treeWidth = new("DropDownControl"):DropDownControl({ "TOPLEFT", search, "TOPLEFT" }, { 120, 144, 80, 20 }, { "1", "2", "3", "4" },
		nil, "Number of differently-minded passive trees that are built and compared. Each one adds to the run time.")
	self.controls.treeWidth:SetSel(4)

	-- Include
	local include = new("SectionControl"):SectionControl({ "TOPLEFT", search, "BOTTOMLEFT" }, { 0, 20, 350, 136 }, "Include")
	self.controls.includeSection = include
	local checks = {
		{ "uniques", "Unique items", true, "After the rare-only build, run again with unique items allowed." },
		{ "lineage", "Lineage supports", true },
		{ "runes", "Runes / soul cores", true },
		{ "auxSkills", "Supporting skills", true, "Auras, curses, marks and other skills whose effect raises the main skill's damage." },
		{ "flasks", "Flasks and charms", true },
		{ "weaponSets", "Second weapon set", true, "Use weapon set 2 and its passives for the supporting skills." },
		{ "combos", "Combination search", true, "Look for supports, affixes and passives that only work together." },
		{ "thorough", "Thorough uniques", false, "Try every unique as one half of a unique pair. Adds several minutes." },
		{ "legacyUniques", "Legacy uniques", false, "Also try older versions of uniques and uniques that are no longer obtainable." },
		{ "sustained", "Assume sustained", false, "Switch on the Configuration conditions the build keeps up by itself (enemy shocked, crit recently, ...)." },
	}
	self.checks = { }
	for index, info in ipairs(checks) do
		local column, row = (index - 1) % 2, m_floor((index - 1) / 2)
		local check = new("CheckBoxControl"):CheckBoxControl({ "TOPLEFT", include, "TOPLEFT" }, { 14 + column * 168, 14 + row * 24, 18 }, info[2], nil, info[4], info[3])
		check.labelRight = true
		self.controls["check_" .. info[1]] = check
		self.checks[info[1]] = check
	end

	self.controls.run = new("ButtonControl"):ButtonControl({ "TOPLEFT", include, "BOTTOMLEFT" }, { 0, 14, 170, 24 }, "Run Optimizer", function()
		self:Start()
	end)
	self.controls.run.enabled = function()
		return not (job and job.status == "running")
	end
	self.controls.cancel = new("ButtonControl"):ButtonControl({ "LEFT", self.controls.run, "RIGHT" }, { 10, 0, 170, 24 }, "Cancel", function()
		self:Cancel()
	end)
	self.controls.cancel.enabled = function()
		return job and job.status == "running"
	end
	self.controls.note = new("LabelControl"):LabelControl({ "TOPLEFT", self.controls.run, "BOTTOMLEFT" }, { 0, 10, 0, 14 },
		"^8A full run takes 10-30 minutes. The open build is not changed;\nopen or save a result when it is done.")

	-- Status and results
	local right = { "TOPLEFT", char, "TOPRIGHT" }
	self.controls.status = new("LabelControl"):LabelControl({ "TOPLEFT", char, "TOPRIGHT" }, { 20, -12, 0, 16 }, function()
		return self:StatusText()
	end)
	local results = new("SectionControl"):SectionControl(right, { 20, 20, 0, 82 }, "Results")
	results.width = function()
		return self.width - 390
	end
	self.controls.resultsSection = results
	for index, variant in ipairs(variants) do
		local y = 12 + (index - 1) * 30
		local prefix = "result_" .. variant.key
		local function result()
			return job and job.results[variant.key]
		end
		self.controls[prefix .. "Label"] = new("LabelControl"):LabelControl({ "TOPLEFT", results, "TOPLEFT" }, { 10, y + 3, 0, 16 }, function()
			local res = result()
			if res then
				return s_format("^7%s:  ^x33FF77%s^7 %s", variant.label, formatNumSep(tostring(m_floor(res.score))), job.metric)
			end
			return s_format("^7%s:  ^8%s", variant.label, job and job.status == "running" and (variant.key == "rares" or job.options.uniques) and "pending" or "-")
		end)
		local open = new("ButtonControl"):ButtonControl({ "TOPRIGHT", results, "TOPRIGHT" }, { -10, y, 80, 20 }, "Open", function()
			self:OpenResult(result())
		end)
		open.enabled = function() return result() ~= nil end
		open.tooltipText = "Open this build in the window, replacing the current one."
		local save = new("ButtonControl"):ButtonControl({ "RIGHT", open, "LEFT" }, { -6, 0, 80, 20 }, "Save", function()
			self:SaveResult(result())
		end)
		save.enabled = open.enabled
		save.tooltipText = "Save this build to your builds folder."
		local summary = new("ButtonControl"):ButtonControl({ "RIGHT", save, "LEFT" }, { -6, 0, 80, 20 }, "Summary", function()
			self.view = variant.key
		end)
		summary.enabled = open.enabled
		summary.locked = function() return self.view == variant.key end
		self.controls[prefix .. "Open"] = open
		self.controls[prefix .. "Save"] = save
		self.controls[prefix .. "Summary"] = summary
	end
	self.controls.showLog = new("ButtonControl"):ButtonControl({ "TOPLEFT", results, "BOTTOMLEFT" }, { 0, 10, 110, 20 }, "Progress log", function()
		self.view = "log"
	end)
	self.controls.showLog.locked = function() return self.view == "log" end
	self.controls.text = new("TextListControl"):TextListControl({ "TOPLEFT", self.controls.showLog, "BOTTOMLEFT" }, { 0, 6, 0, 0 })
	self.controls.text.width = function()
		return results:GetProperty("width")
	end
	self.controls.text.height = function()
		local _, y = self.controls.text:GetPos()
		return self.y + self.height - y - 10
	end

	return self
end

function OptimizerTabClass:RefreshLists()
	local classList = { }
	for id, class in pairs(self.build.latestTree.classes) do
		t_insert(classList, { label = class.name, classId = id })
	end
	t_sort(classList, function(a, b) return a.label < b.label end)
	self.controls.class:SetList(classList)

	local names, seen = { }, { }
	for _, gem in pairs(self.build.data.gems) do
		local effect = gem.grantedEffect
		if not effect.support and not effect.fromItem and not effect.fromTree and not effect.hideFromSideBar and not seen[gem.name] then
			seen[gem.name] = true
			t_insert(names, gem.name)
		end
	end
	t_sort(names)
	self.controls.skill:SetList(names)
end

function OptimizerTabClass:RefreshAscendancies()
	local selected = self.controls.class:GetSelValue()
	local class = selected and self.build.latestTree.classes[selected.classId]
	local list = { { label = "Auto (compare all)" } }
	local ascendancies = { }
	for id, ascend in pairs(class and class.classes or { }) do
		if id ~= 0 then
			t_insert(ascendancies, { label = ascend.name, name = ascend.name })
		end
	end
	t_sort(ascendancies, function(a, b) return a.label < b.label end)
	for _, entry in ipairs(ascendancies) do
		t_insert(list, entry)
	end
	self.controls.ascendancy:SetList(list)
	self.controls.ascendancy:SetSel(1)
end

-- Fill the form from the open build
function OptimizerTabClass:LoadFromBuild()
	local spec = self.build.spec
	self.controls.class:SelByValue(spec.curClassName, "label")
	self:RefreshAscendancies()
	if spec.curAscendClassId and spec.curAscendClassId ~= 0 then
		self.controls.ascendancy:SelByValue(spec.curAscendClassName, "name")
	end
	local group = self.build.skillsTab.socketGroupList[self.build.mainSocketGroup]
	for _, gem in ipairs(group and group.gemList or { }) do
		if gem.gemData and not gem.gemData.grantedEffect.support then
			for index, name in ipairs(self.controls.skill.list) do
				if name == gem.gemData.name then
					self.controls.skill:SetSel(index)
				end
			end
			-- A new build is level 1; only a real build's level is worth copying
			if (self.build.characterLevel or 1) > 1 then
				self.controls.level:SetText(tostring(self.build.characterLevel))
			end
			break
		end
	end
end

function OptimizerTabClass:ApplySettings(settings)
	self.controls.class:SelByValue(settings.class, "label")
	self:RefreshAscendancies()
	if settings.ascendancy then
		self.controls.ascendancy:SelByValue(settings.ascendancy, "name")
	end
	self.controls.skill:SelByValue(settings.skill)
	for _, key in ipairs({ "level", "points", "itemLevel", "supports", "rounds" }) do
		self.controls[key]:SetText(settings[key])
	end
	self.controls.metric:SelByValue(settings.metric)
	self.controls.roll:SetVal(settings.roll)
	self.controls.treeWidth:SetSel(settings.treeWidth)
	for key, state in pairs(settings.checks) do
		self.checks[key].state = state
	end
end

function OptimizerTabClass:Start()
	if job and job.status ~= "running" and next(job.results) then
		main:OpenConfirmPopup("Optimizer", "Starting a new run discards the current results.\nSave the ones you want to keep first.", "Start", function()
			self:Launch()
		end)
	else
		self:Launch()
	end
end

function OptimizerTabClass:Launch()
	local class = self.controls.class:GetSelValue()
	local skill = self.controls.skill:GetSelValue()
	if not class or not skill then
		main:OpenMessagePopup("Optimizer", "Choose a class and a skill gem first.")
		return
	end
	local ascendancy = self.controls.ascendancy:GetSelValue()
	local function num(control, min, max)
		local value = tonumber(control.buf)
		return value and math.max(min, math.min(max, value))
	end
	local setup = {
		class = class.label,
		ascendancy = ascendancy and ascendancy.name,
		skill = skill,
		level = num(self.controls.level, 1, 100),
		name = skill .. " " .. (ascendancy and ascendancy.name or class.label),
	}
	local options = {
		points = num(self.controls.points, 0, 200),
		rounds = num(self.controls.rounds, 1, 9),
		affixRoll = self.controls.roll.val,
		itemLevel = num(self.controls.itemLevel, 1, 100),
		maxSupports = num(self.controls.supports, 0, 9),
		metric = self.controls.metric:GetSelValue(),
		treeWidth = self.controls.treeWidth.selIndex,
		autoAscendancy = ascendancy == nil or ascendancy.name == nil,
		assume = self.checks.sustained.state and "sustained" or nil,
	}
	for key, check in pairs(self.checks) do
		if key ~= "sustained" then
			options[key] = check.state
		end
	end
	local file = io.open(GetScriptPath() .. "/OptimizerSubScript.lua", "r") or io.open("OptimizerSubScript.lua", "r")
	if not file then
		main:OpenMessagePopup("Optimizer", "OptimizerSubScript.lua is missing from the program folder.")
		return
	end
	local script = file:read("*a")
	file:close()

	lastSettings = {
		class = class.label, ascendancy = setup.ascendancy, skill = skill, metric = options.metric,
		roll = self.controls.roll.val, treeWidth = options.treeWidth, checks = { },
	}
	for _, key in ipairs({ "level", "points", "itemLevel", "supports", "rounds" }) do
		lastSettings[key] = self.controls[key].buf
	end
	for key, check in pairs(self.checks) do
		lastSettings.checks[key] = check.state
	end

	local startTime = GetTime()
	jobCount = jobCount + 1
	job = {
		token = jobCount,
		status = "running",
		name = setup.name,
		metric = options.metric,
		options = options,
		startTime = startTime,
		log = { },
		results = { },
		clock = function()
			return formatTime((GetTime() - startTime) / 1000)
		end,
	}
	self.view = "log"
	appendLog(s_format("Starting: %s, %s%s, level %d", skill, class.label, setup.ascendancy and (" / " .. setup.ascendancy) or " (ascendancy: auto)", setup.level or 100))
	appendLog("Loading the program data in the background...")
	local thisJob = job
	local ok, id = pcall(LaunchSubScript, script, "", "OptimizerProgress", luaSource(setup), luaSource(options), GetScriptPath(), jobCount)
	if not ok or not id then
		job.status = "failed"
		job.errMsg = "the background job could not be started"
		job.endTime = GetTime()
		appendLog("^1Failed: " .. tostring(id or job.errMsg))
		return
	end
	job.id = id
	launch:RegisterSubScript(id, function(errMsg)
		thisJob.endTime = GetTime()
		if thisJob.status ~= "running" then
			return
		end
		if errMsg then
			thisJob.status = "failed"
			thisJob.errMsg = errMsg:match("^[^\n]*")
			if job == thisJob then
				appendLog("^1Failed: " .. errMsg)
			end
		else
			thisJob.status = "done"
			if job == thisJob then
				appendLog("^x33FF77Done.")
			end
		end
	end)
end

function OptimizerTabClass:Cancel()
	if job and job.status == "running" then
		-- AbortSubScript raises an error for a job that has just finished. The job's token keeps
		-- anything it still reports out of later runs
		pcall(AbortSubScript, job.id)
		job.status = "cancelled"
		job.endTime = GetTime()
		appendLog("^xFFAA33Cancelled.")
	end
end

function OptimizerTabClass:StatusText()
	if not job then
		return "^7Status: ^8idle"
	end
	local elapsed = formatTime(((job.endTime or GetTime()) - job.startTime) / 1000)
	if job.status == "running" then
		local last = job.log[#job.log] or ""
		return s_format("^7Status: ^x33AAFFrunning^7 for %s  ^8%s", elapsed, last:gsub("^%^8%[[^%]]*%]%^7 ", ""))
	elseif job.status == "done" then
		return s_format("^7Status: ^x33FF77finished^7 in %s", elapsed)
	elseif job.status == "cancelled" then
		return s_format("^7Status: ^xFFAA33cancelled^7 after %s", elapsed)
	end
	return s_format("^7Status: ^1failed^7 after %s: %s", elapsed, job.errMsg or "")
end

function OptimizerTabClass:OpenResult(result)
	if not result then
		return
	end
	local function open()
		main:SetMode("BUILD", false, result.name, result.xml)
	end
	if self.build.unsaved then
		main:OpenConfirmPopup("Open Build", "The current build has unsaved changes that will be lost.", "Open", open)
	else
		open()
	end
end

function OptimizerTabClass:SaveResult(result)
	if not result then
		return
	end
	local fileName = result.name:gsub('[<>:"/\\|%?%*]', "_")
	local path = main.buildPath .. fileName .. ".xml"
	local function write()
		local file = io.open(path, "w+")
		if not file then
			main:OpenMessagePopup("Save Build", "Couldn't write " .. path)
			return
		end
		file:write(result.xml)
		file:close()
		main:OpenMessagePopup("Save Build", "Saved to your builds folder as:\n" .. fileName .. ".xml")
	end
	local existing = io.open(path, "r")
	if existing then
		existing:close()
		main:OpenConfirmPopup("Save Build", "A build named \"" .. fileName .. "\" already exists. Overwrite it?", "Overwrite", write)
	else
		write()
	end
end

function OptimizerTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height
	-- The build file is loaded after the tabs are created, so the form is filled on first view
	if not self.formFilled then
		self.formFilled = true
		self:RefreshLists()
		if lastSettings then
			self:ApplySettings(lastSettings)
		else
			self:LoadFromBuild()
		end
	end

	-- launch:OnSubError drops a subscript that dies outside its own error handling without calling back
	if job and job.status == "running" and job.id and not launch.subScripts[job.id] then
		job.status = "failed"
		job.errMsg = "the background job stopped unexpectedly"
		job.endTime = GetTime()
	end

	local text = self.controls.text
	local lines = { }
	if self.view == "log" or not (job and job.results[self.view]) then
		self.view = "log"
		for _, line in ipairs(job and job.log or { "^8Choose a class and a skill gem, then press Run Optimizer." }) do
			t_insert(lines, { height = 16, line })
		end
	else
		for line in (job.results[self.view].summary .. "\n"):gmatch("([^\n]*)\n") do
			t_insert(lines, { height = 16, (line:match("^==") and "^xE0C060" or "^7") .. line })
		end
	end
	-- Follow the end of the log when it grows, unless the user scrolled up
	local scrollBar = text.controls.scrollBar
	local follow = self.view == "log" and #lines ~= self.lastLineCount and scrollBar.offset >= (scrollBar.offsetMax or 0)
	if self.view ~= self.lastView then
		scrollBar.offset = 0
		self.lastView = self.view
	end
	text.list = lines
	self.lastLineCount = #lines
	if follow then
		scrollBar.offset = math.huge
	end

	self:ProcessControlsInput(inputEvents, viewPort)
	main:DrawBackground(viewPort)
	self:DrawControls(viewPort)
end
