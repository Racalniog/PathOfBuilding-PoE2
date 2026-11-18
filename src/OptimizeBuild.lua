#@
-- Path of Building
--
-- Headless command line front end for Modules/BuildOptimizer.
-- Builds a character around one skill gem and maximises its damage; see docs/buildOptimizer.md.
--
-- Run from the src directory with LuaJIT (or through OptimizeBuild.py, which uses the bundled runtime):
--   luajit OptimizeBuild.lua --class Ranger --ascendancy Deadeye --skill "Lightning Arrow"
--
local usage = [[
Usage: OptimizeBuild.lua --class <name> --skill <gem name> [options]

  --class <name>         Character class, e.g. Ranger
  --ascendancy <name>    Ascendancy, e.g. Deadeye. Omit (or "auto") to let the optimiser pick one
  --skill <name>         Active skill gem to build around, e.g. "Lightning Arrow"
  --level <n>            Character level (default 100)
  --points <n>           Passive points to spend (default: all points available at that level)
  --gem-level <n>        Level of the skill gem (default: highest the character can use)
  --rounds <n>           Optimisation passes per variant (default 2)
  --roll <0..1>          Roll quality of crafted affixes and unique ranges (default 1 = perfect)
  --item-level <n>       Highest affix tier level allowed on crafted items (default 82)
  --supports <n>         Number of support gems (default 5)
  --metric <stat>        Calc output to maximise (default CombinedDPS; e.g. TotalDPS, FullDPS)
  --survivability <0..1> Weight of survivability (effective hit pool) in the score, default 0 = damage
                         only: score = metric ^ (1 - w) * EHP ^ w, 0.5 weighs both alike
  --approx [kills/s]     Switch on the Configuration tab's approximations (recovery on kill and the
                         like, from a kill rate; default 1 kill per second) in the build
  --config <key=value>   Set a Configuration tab option, may be repeated (e.g. --config enemyIsBoss=Pinnacle)
  --assume <what>        Conditions to switch on: "sustained" = the ones the build keeps up by itself
                         (enemy shocked with enough shock chance, crit recently, ...), or a comma
                         separated list of Configuration option names. Default: none
  --coverage             Print what share of the program's data the calculation engine can't read, and exit
  --tree-width <n>       Number of differently-minded tree builds to compare (1-4, default 4)
  --jobs <n>             Processes to use in total (default 3). The extra ones build tree variants in
                         parallel; each needs up to about 1 GB of memory. 1 = everything in one process
  --no-lineage           Don't use lineage support gems
  --no-runes             Leave item sockets empty
  --no-aux               Don't add auras, curses, marks and other supporting skills
  --no-flasks            Don't equip flasks and charms
  --no-weapon-sets       Don't use the second weapon set for the supporting skills
  --no-combos            Skip the search for combinations whose parts do nothing on their own
  --thorough             Try every unique as one half of a unique pair (adds several minutes)
  --no-uniques           Only produce the rare-item build
  --legacy-uniques       Also try legacy uniques: older versions and uniques that are no longer obtainable
  --unique-variants      Also try every current version of uniques that come in several (slower)
  --only-uniques         Skip saving the rare-only build; only report the build with uniques allowed
  --out <dir>            Directory for the resulting build files (default: the user's build folder)
  --name <text>          Base name of the saved builds
  --debug                Log every crafted affix
  --quiet                Don't log progress
]]

local args = { config = { } }
do
	local flags = { ["no-lineage"] = true, ["no-runes"] = true, ["no-uniques"] = true, ["no-aux"] = true, ["no-flasks"] = true, ["no-weapon-sets"] = true, ["no-combos"] = true, thorough = true, ["legacy-uniques"] = true, ["unique-variants"] = true, ["only-uniques"] = true, debug = true, quiet = true, help = true, coverage = true }
	local index = 1
	while arg and arg[index] do
		local key = arg[index]:match("^%-%-(.+)$")
		if not key then
			io.stderr:write("Unexpected argument '" .. arg[index] .. "'\n\n" .. usage)
			os.exit(2)
		end
		if flags[key] then
			args[key] = true
		elseif key == "approx" then
			-- The kill rate is optional
			args.approx = tonumber(arg[index + 1]) or 1
			if tonumber(arg[index + 1]) then
				index = index + 1
			end
		else
			index = index + 1
			local value = arg[index]
			if value == nil then
				io.stderr:write("Missing value for --" .. key .. "\n\n" .. usage)
				os.exit(2)
			end
			if key == "config" then
				local name, setting = value:match("^([^=]+)=(.*)$")
				if not name then
					io.stderr:write("--config expects key=value\n")
					os.exit(2)
				end
				if setting == "true" then
					setting = true
				elseif setting == "false" then
					setting = false
				elseif tonumber(setting) then
					setting = tonumber(setting)
				end
				args.config[name] = setting
			else
				args[key] = value
			end
		end
		index = index + 1
	end
end
if args.help or ((not args.class or not args.skill) and not args.coverage and not args.worker) then
	io.stderr:write(usage)
	os.exit(args.help and 0 or 2)
end
if args.survivability and not tonumber(args.survivability) then
	io.stderr:write("--survivability expects a number from 0 to 1\n")
	os.exit(2)
end

-- Safety net: stop with a stack dump instead of running away if the search stops reporting
-- progress for a long time or its memory use explodes
local lastProgress = os.clock()
do
	local ok, profile = pcall(require, "jit.profile")
	local memoryLimitMB = tonumber(os.getenv("POB_OPTIMIZER_MEMORY_MB")) or 3000
	local silenceLimit = tonumber(os.getenv("POB_OPTIMIZER_SILENCE_S")) or 900
	if ok and profile then
		local fired = false
		profile.start("i500", function(thread)
			if fired then
				return
			end
			local memoryMB = collectgarbage("count") / 1024
			if memoryMB > memoryLimitMB or os.clock() - lastProgress > silenceLimit then
				fired = true
				io.stderr:write(string.format("\nOptimiser stopped by its watchdog (Lua memory %.0f MB, %.0f s since last progress). Stack:\n", memoryMB, os.clock() - lastProgress))
				io.stderr:write(profile.dumpstack(thread, "pl\n", 40), "\n")
				io.stderr:flush()
				os.exit(3)
			end
		end)
	end
end

-- The program prints its own start-up chatter; keep it out of the way unless something goes wrong
local realPrint = print
if not args.debug then
	print = function() end
end
dofile("HeadlessWrapper.lua")
print = realPrint
ConPrintf = function() end

local optimizer = LoadModule("Modules/BuildOptimizer")

-- Plain values of a table as Lua source, for handing options to a worker
local function serialise(value, indent)
	local kind = type(value)
	if kind == "table" then
		local parts = { }
		for key, entry in pairs(value) do
			local text = serialise(entry)
			if text then
				table.insert(parts, "[" .. (type(key) == "number" and tostring(key) or string.format("%q", tostring(key))) .. "] = " .. text)
			end
		end
		table.sort(parts)
		return "{ " .. table.concat(parts, ", ") .. " }"
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	end
end

if args.worker then
	-- Worker: build one tree variant for the job in the given file and write the result next to it
	local job = dofile(args.worker)
	loadBuildFromXML(job.xml, "job")
	job.options.log = function() lastProgress = os.clock() end
	local score, nodes = optimizer.RunTreeVariant(build, job.options, job.exponent)
	local file = assert(io.open(args.worker .. ".result", "w"))
	file:write("return " .. serialise({ score = score or -1, nodes = nodes or { } }) .. "\n")
	file:close()
	os.exit(0)
end
local startTime = os.clock()
local function say(text)
	lastProgress = os.clock()
	if not args.quiet then
		io.stdout:write(string.format("[%6.1fs] %s\n", os.clock() - startTime, text))
		io.stdout:flush()
	end
end

newBuild()
if args.coverage and not (args.class and args.skill) then
	io.stdout:write(optimizer.CoverageReport(build), "\n")
	os.exit(0)
end
local ok, errMsg = optimizer.SetupCharacter(build, {
	class = args.class,
	ascendancy = args.ascendancy,
	skill = args.skill,
	level = tonumber(args.level),
	gemLevel = tonumber(args["gem-level"]),
	config = args.config,
})
if not ok then
	io.stderr:write(errMsg .. "\n")
	os.exit(1)
end

local options = {
	log = say,
	debug = args.debug,
	points = tonumber(args.points),
	rounds = tonumber(args.rounds),
	affixRoll = tonumber(args.roll),
	itemLevel = tonumber(args["item-level"]),
	maxSupports = tonumber(args.supports),
	metric = args.metric,
	survivability = tonumber(args.survivability),
	approximations = args.approx ~= nil,
	killsPerSecond = args.approx,
	lineage = not args["no-lineage"],
	runes = not args["no-runes"],
	auxSkills = not args["no-aux"],
	flasks = not args["no-flasks"],
	weaponSets = not args["no-weapon-sets"],
	combos = not args["no-combos"],
	thorough = args.thorough,
	legacyUniques = args["legacy-uniques"],
	uniqueVariants = args["unique-variants"],
	autoAscendancy = not args.ascendancy or args.ascendancy:lower() == "auto",
	treeWidth = tonumber(args["tree-width"]),
}

-- Parallel workers: the launcher (or the user) says how to start another copy of this script in
-- POB_OPTIMIZER_WORKER, e.g. luajit OptimizeBuild.lua
local workerCommand = os.getenv("POB_OPTIMIZER_WORKER")
local jobs = math.max(1, math.floor(tonumber(args.jobs) or 3))
if workerCommand and workerCommand ~= "" and jobs > 1 and io.popen then
	local jobCount = 0
	local tempDir = (os.getenv("TEMP") or os.getenv("TMPDIR") or "."):gsub("\\", "/")
	options.workers = jobs - 1
	options.spawnWorker = function(job)
		jobCount = jobCount + 1
		-- Several optimiser runs can start in the same second; the address of a fresh table tells
		-- their job files apart
		local jobFile = string.format("%s/pob_optimizer_%d_%s_%d.job", tempDir, os.time(), tostring({ }):match("%x+$"), jobCount)
		local workerOptions = { }
		for key, value in pairs(options) do
			if type(value) ~= "function" and key ~= "workers" then
				workerOptions[key] = value
			end
		end
		local level = 1
		while job.xml:find("]" .. string.rep("=", level) .. "]", 1, true) do
			level = level + 1
		end
		local file = assert(io.open(jobFile, "w"))
		file:write("return { exponent = ", tostring(job.exponent), ", options = ", serialise(workerOptions), ", xml = [", string.rep("=", level), "[", job.xml, "]", string.rep("=", level), "] }\n")
		file:close()
		local command = workerCommand .. ' --worker "' .. jobFile .. '"'
		if package.config:sub(1, 1) == "\\" then
			-- cmd.exe strips the outermost pair of quotes
			command = '"' .. command .. '"'
		end
		local pipe = assert(io.popen(command, "r"))
		return {
			wait = function()
				pipe:read("*a")
				pipe:close()
				local chunk = loadfile(jobFile .. ".result")
				os.remove(jobFile)
				os.remove(jobFile .. ".result")
				if not chunk then
					error("the worker produced no result")
				end
				return chunk()
			end,
		}
	end
end
if args.assume and args.assume ~= "none" then
	if args.assume == "sustained" then
		options.assume = "sustained"
	else
		options.assume = { }
		for var in args.assume:gmatch("[^,%s]+") do
			table.insert(options.assume, var)
		end
	end
end

local outDir = args.out
if not outDir then
	outDir = main.buildPath
	if not outDir or outDir == "" or outDir == "/Builds/" then
		outDir = "./"
	end
end
outDir = outDir:gsub("\\", "/")
if not outDir:match("/$") then
	outDir = outDir .. "/"
end
local baseName = args.name or (args.skill .. " " .. build.spec.curClassName)

local function save(variant)
	local name = (baseName .. " (" .. variant .. ")"):gsub('[<>:"/\\|%?%*]', "_")
	build.buildName = name
	local xmlText = build:SaveDB(name)
	local summary = optimizer.Describe(build)
	-- The extra reports must never cost the user the build that was just found
	for _, report in ipairs({ optimizer.ConfigReport, optimizer.BlindSpotReport, optimizer.CoverageReport }) do
		local ok, text = pcall(report, build, options)
		summary = summary .. "\n\n" .. (ok and text or ("(report failed: " .. tostring(text) .. ")"))
	end
	local written = { }
	for extension, text in pairs({ xml = xmlText, txt = summary }) do
		local fileName = outDir .. name .. "." .. extension
		local file = io.open(fileName, "w+")
		if file then
			file:write(text)
			file:close()
			written[extension] = fileName
		else
			io.stderr:write("Couldn't write " .. fileName .. "\n")
		end
	end
	io.stdout:write("\n===== " .. name .. " =====\n" .. summary .. "\n\n")
	if written.xml then
		io.stdout:write("Saved build: " .. written.xml .. "\n\n")
	end
	io.stdout:flush()
end

say("Optimising with rare items only")
local result
result, errMsg = optimizer.Optimize(build, options)
if not result then
	io.stderr:write("Optimisation failed: " .. tostring(errMsg) .. "\n")
	os.exit(1)
end
say(string.format("Rare-only build: %.0f (%d calculations)", result.score, result.evals))
if not args["only-uniques"] then
	save("rares")
end

if not args["no-uniques"] then
	say("Optimising with unique items allowed")
	options.allowUniques = true
	result, errMsg = optimizer.Optimize(build, options)
	if not result then
		io.stderr:write("Optimisation failed: " .. tostring(errMsg) .. "\n")
		os.exit(1)
	end
	say(string.format("Build with uniques: %.0f (%d calculations)", result.score, result.evals))
	save("uniques")
end
