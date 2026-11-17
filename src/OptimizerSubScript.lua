-- Path of Building
--
-- Background job of the Optimizer tab (Classes/OptimizerTab.lua), run with LaunchSubScript.
-- The subscript is a separate Lua state, so it loads its own headless copy of the program and
-- optimises a fresh build there; the build open in the window is never touched.
-- Arguments: setup and options of Modules/BuildOptimizer as Lua table source, the script path and
-- the job's token. Reports through OptimizerProgress(token, kind, ...) on the main thread:
--   "log", text
--   "result", variant, score, buildXML, summary
-- Cancel stops the job with AbortSubScript. Returns nil on success, or an error message.
local setupText, optionsText, scriptPath, token = ...
-- The headless program loads Classes/OptimizerTab.lua too, which defines a global of the same name
local sendProgress = OptimizerProgress
local function OptimizerProgress(...)
	sendProgress(token, ...)
end

-- The headless program opens its files relative to the script folder, but a subscript shares the
-- process's working directory, which is wherever the program was started from
if scriptPath and scriptPath ~= "" then
	scriptPath = scriptPath:gsub("\\", "/"):gsub("/?$", "/")
	local function resolve(path)
		if type(path) == "string" and not path:match("^/") and not path:match("^%a:") then
			return scriptPath .. path
		end
		return path
	end
	local l_loadfile, l_dofile, l_open, l_lines = loadfile, dofile, io.open, io.lines
	loadfile = function(path, ...) return l_loadfile(resolve(path), ...) end
	dofile = function(path) return l_dofile(resolve(path)) end
	io.open = function(path, ...) return l_open(resolve(path), ...) end
	io.lines = function(path, ...) return l_lines(resolve(path), ...) end
	package.path = scriptPath .. "?.lua;" .. package.path
end

local function run()
	local setup = assert(loadstring("return " .. setupText))()
	local options = assert(loadstring("return " .. optionsText))()

	-- The headless program prints start-up chatter and waits for a key after a start-up error
	local realPrint = print
	print = function() end
	io.read = function() end
	-- The program reads its command line from the global arg, which a subscript doesn't have
	arg = { }
	dofile("HeadlessWrapper.lua")
	print = realPrint
	ConPrintf = function() end
	if __mainObject__.promptMsg then
		-- Keep only the message of the start-up error prompt
		error(__mainObject__.promptMsg:match("^%^1Error:%s*%^0([^\n]*)") or __mainObject__.promptMsg, 0)
	end

	local optimizer = LoadModule("Modules/BuildOptimizer")
	newBuild()
	local ok, errMsg = optimizer.SetupCharacter(build, setup)
	if not ok then
		error(errMsg, 0)
	end
	options.log = function(text)
		OptimizerProgress("log", text)
	end

	local function finish(variant, result)
		build.buildName = setup.name .. " (" .. variant .. ")"
		local summary = optimizer.Describe(build)
		-- The extra reports must never cost the user the build that was just found
		for _, report in ipairs({ optimizer.ConfigReport, optimizer.BlindSpotReport }) do
			local reportOk, text = pcall(report, build, options)
			summary = summary .. "\n\n" .. (reportOk and text or ("(report failed: " .. tostring(text) .. ")"))
		end
		OptimizerProgress("result", variant, result.score, build:SaveDB(build.buildName), summary)
	end

	OptimizerProgress("log", "Optimising with rare items only")
	local result
	result, errMsg = optimizer.Optimize(build, options)
	if not result then
		error(errMsg, 0)
	end
	finish("rares", result)
	if options.uniques then
		OptimizerProgress("log", "Optimising with unique items allowed")
		options.allowUniques = true
		result, errMsg = optimizer.Optimize(build, options)
		if not result then
			error(errMsg, 0)
		end
		finish("uniques", result)
	end
end

local ok, errMsg = xpcall(run, debug.traceback)
if not ok then
	return tostring(errMsg)
end
