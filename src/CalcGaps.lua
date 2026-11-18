-- Census of the modifiers the calculation engine can't read, for tracking the work in
-- docs/calculationGapsPlan.md. Prints the coverage counts and a count per mechanic group; with a
-- file name, also writes every unreadable line as "source<TAB>group<TAB>text".
--   python OptimizeBuild.py --gaps [lines.tsv]
local outPath = arg and arg[1]
local realPrint = print
print = function() end
dofile("HeadlessWrapper.lua")
print = realPrint
newBuild()
local optimizer = LoadModule("Modules/BuildOptimizer")

-- First matching group wins, so the more specific mechanics come first
local groups = {
	{ "Infusion / Archon", { "infusion", "archon" } },
	{ "Thorns", { "thorns" } },
	{ "Charges", { "charge" } },
	{ "Minions, companions, totems", { "minion", "companion", "totem", "reviv", "skeleton", "zombie" } },
	{ "Recovery, leech, regeneration", { "leech", "regenerat", "recover", "recoup", "life flask", "mana flask", "energy shield recharge" } },
	{ "Flasks, charms", { "flask", "charm" } },
	{ "Ailments", { "ignit", "shock", "freez", "chill", "bleed", "poison", "electrocut", "ailment" } },
	{ "Stun, block, parry, Guard", { "stun", "daze", "block", "parry", "guard" } },
	{ "Curses, marks, exposure", { "curse", "mark ", "marked", "exposure", "hex" } },
	{ "Movement, sprint, dodge roll", { "movement", "sprint", "dodge roll", "while moving" } },
	{ "Ground surfaces", { "ground", "tailwind" } },
	{ "On kill, on hit, triggers", { "on kill", "when you kill", "on hit", "trigger", "when you", "every ", "chance to" } },
	{ "Spirit, reservation, auras, Presence", { "spirit", "reserv", "aura", "presence", "banner" } },
}
local function groupOf(text)
	local lower = text:lower()
	for _, group in ipairs(groups) do
		for _, word in ipairs(group[2]) do
			if lower:find(word, 1, true) then
				return group[1]
			end
		end
	end
	return "Other"
end

local lines, counts = { }, { }
local function record(source, text)
	text = text:gsub("[\r\n\t]", " ")
	local group = groupOf(text)
	counts[group] = (counts[group] or 0) + 1
	table.insert(lines, source .. "\t" .. group .. "\t" .. text)
end
local function unreadable(line)
	local list, extra = modLib.parseMod(line)
	return not list or extra
end
-- Affix and rune lines the game wraps over two lines are one modifier
local function joinWrapped(lines)
	local joined = { }
	for i, line in ipairs(lines) do
		if i > 1 and modLib.wrapsInto(joined[#joined], line) then
			joined[#joined] = joined[#joined] .. " " .. line:gsub("^%s+", "")
		else
			table.insert(joined, line)
		end
	end
	return joined
end

for _, item in pairs(main.uniqueDB.list) do
	for _, list in ipairs({ item.implicitModLines, item.explicitModLines }) do
		for _, modLine in ipairs(list or { }) do
			-- A line that rolls to 0 at the default range (e.g. +(-30-30)%) has no modifiers but is readable
			if modLine.extra or ((not modLine.modList or #modLine.modList == 0) and not (modLine.line or ""):match("^Grants Skill") and unreadable(itemLib.applyRange(modLine.line or "", 1))) then
				record("unique", modLine.line or "")
			end
		end
	end
end
for _, node in pairs(build.spec.tree.nodes) do
	if node.sd and (node.unknown or node.extra) then
		local source = node.ascendancyName and "ascendancy" or node.type == "Keystone" and "keystone" or node.type == "Notable" and "notable" or "passive"
		for i, line in ipairs(node.sd) do
			local mods = node.mods[i]
			if not mods.combined and (not mods.list or mods.extra) then
				record(source, mods.text or line)
			end
		end
	end
end
for _, kind in ipairs({ "Item", "Jewel", "Flask", "Charm", "Desecrated", "Corruption" }) do
	for _, mod in pairs(data.itemMods[kind] or { }) do
		for _, line in ipairs(joinWrapped(mod)) do
			if unreadable(itemLib.applyRange(line, 1)) then
				record("affix", line)
			end
		end
	end
end
for _, rune in pairs(data.itemMods.Runes or { }) do
	for _, mod in pairs(rune) do
		for _, line in ipairs(joinWrapped(mod)) do
			if unreadable(line) then
				record("rune", line)
			end
		end
	end
end

realPrint((optimizer.CoverageReport(build):match("== Coverage.-$")))
realPrint("== Unreadable modifier lines by mechanic ==")
local order = { }
for group, count in pairs(counts) do
	table.insert(order, { group, count })
end
table.sort(order, function(a, b) return a[2] > b[2] end)
for _, entry in ipairs(order) do
	realPrint(string.format("%-40s %5d", entry[1], entry[2]))
end
realPrint(string.format("%-40s %5d", "Total", #lines))

if outPath then
	table.sort(lines)
	local file = assert(io.open(outPath, "w"))
	file:write(table.concat(lines, "\n"), "\n")
	file:close()
	realPrint("Lines written to " .. outPath)
end
