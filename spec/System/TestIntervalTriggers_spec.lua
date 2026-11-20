-- Skills from items and the tree that trigger a damage skill on an interval or on events of the build, with Use approximations on
-- (CalcTriggers.lua, intervalTrigger): The Stars Answer, Apocalypse, Archon of Chayula, Midnight Zenith, Inevitable Agony
describe("TestIntervalTriggers", function()
	local optimizer

	before_each(function()
		newBuild()
		optimizer = LoadModule("Modules/BuildOptimizer")
	end)

	-- Makes the skill the main skill through its item or node (the optimiser's setup), then applies `o`: socket group texts to paste
	-- (the build's other skills), a weapon, custom mods, configuration inputs, the group's active skill `index` and the stat set
	-- `statSet` of the skill `skillId`. Returns the output and the main skill
	local function calc(class, skillName, source, o)
		o = o or { }
		local ok, pin = optimizer.SetupCharacter(build, { class = class, skill = skillName, skillSource = source, level = 95 })
		assert.is_true(ok, tostring(pin))
		local mainGroup = build.mainSocketGroup
		if o.weapon then
			build.itemsTab:CreateDisplayItemFromRaw("New Item\n" .. o.weapon .. "\n")
			build.itemsTab:AddDisplayItem()
		end
		for _, text in ipairs(o.groups or { }) do
			build.skillsTab:PasteSocketGroup(text)
		end
		runCallback("OnFrame")
		local group = build.skillsTab.socketGroupList[mainGroup]
		group.mainActiveSkill, group.mainActiveSkillCalcs = o.index or 1, o.index or 1
		if o.skillId then
			local instance = group.gemList[1]
			instance.statSet, instance.statSetCalcs = { [o.skillId] = o.statSet or 1 }, { [o.skillId] = o.statSet or 1 }
		end
		build.configTab.input.customMods = o.mods or ""
		for var, val in pairs(o.config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.buildFlag = true
		runCallback("OnFrame")
		return copyTable(build.calcsTab.mainOutput, true), build.calcsTab.mainEnv.player.mainSkill, group
	end
	local approx = { useApproximations = true }
	-- Hits and Critical Hits per second of a skill (Spark), from its own calculation as the main skill
	local function rates(output)
		local hits = output.Speed * output.HitChance / 100
		return hits, hits * output.CritChance / 100
	end
	local function power()
		return build.calcsTab.mainEnv.player.modDB:GetMultiplier("EnemyPower")
	end
	-- a fresh build with Spark as the main skill, for its rates
	local function spark(mods)
		newBuild()
		local output = calc("Witch", "Spark", "gem", { mods = mods })
		local hits, crits = rates(output)
		local p = power()
		p = p > 0 and p or 1
		newBuild()
		return hits, crits, p
	end

	describe("The Stars Answer", function()
		local function starfall(config, statSet)
			return calc("Witch", "The Stars Answer", "item", { config = config, index = 2, skillId = "TheStarsAnswerCometPlayer", statSet = statSet })
		end

		it("keeps the self-cast numbers with approximations off", function()
			local output, skill = starfall({ approxEnemiesAroundYou = 5 })
			assert.are.equals("Starfall", skill.activeEffect.grantedEffect.name)
			assert.is_nil(skill.skillData.triggered)
			assert.are.equals(0, output.Speed)
			assert.are.near(output.AverageDamage / 0.3, output.TotalDPS, 1e-6)
		end)

		it("triggers a meteor every interval, small stars 14 in 15, more with enemies in the radius up to the cap", function()
			-- the data: a meteor every 300 ms, every 15th a large one; +50% per enemy after the first, at most +200%
			local output, skill = starfall(approx)
			assert.are.equals("Starfall's Trigger: The Stars Answer", skill.infoMessage)
			assert.are.near(1000 / 300 * 14 / 15, output.Speed, 1e-9)
			assert.are.near(output.AverageDamage * output.Speed, output.TotalDPS, 1e-6)
			assert.are.near(output.TotalDPS, output.CombinedDPS, 1e-6)
			local base = output.Speed
			newBuild()
			output = starfall({ useApproximations = true, approxEnemiesAroundYou = 3 })
			assert.are.near(base * 2, output.Speed, 1e-9)
			newBuild()
			output = starfall({ useApproximations = true, approxEnemiesAroundYou = 30 })
			assert.are.near(base * 3, output.Speed, 1e-9)
			-- the large star is the second stat set, 1 meteor in 15
			newBuild()
			local large = starfall(approx, 2)
			assert.are.near(1000 / 300 / 15, large.Speed, 1e-9)
			assert.are.near(large.AverageDamage * large.Speed, large.TotalDPS, 1e-6)
		end)

		it("is scored by the optimiser as the group's Starfall, the skill itself deals no damage", function()
			local ok, pin = optimizer.SetupCharacter(build, { class = "Witch", skill = "The Stars Answer", skillSource = "item", level = 95, config = approx })
			assert.is_true(ok)
			local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
			assert.are.equals("TheStarsAnswerPlayer", group.displaySkillList[1].activeEffect.grantedEffect.id)
			assert.are.equals(0, build.calcsTab.mainOutput.CombinedDPS or 0)
			local result = optimizer.Optimize(build, { rounds = 1, points = 4, ascendancyPoints = 0, maxSupports = 1, supportStarts = 1, baseCandidates = 1, weaponCombos = 1,
				treeVerify = 1, treeRefineFails = 1, runes = false, auxSkills = false, flasks = false, uniquePairAnchors = 1, weaponSets = false, treeWidth = 1,
				approximations = true, pin = pin })
			assert.is_true(result.score > 0)
			assert.are.equals("Starfall", build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name)
		end)
	end)

	describe("Apocalypse", function()
		-- Druid, Shaman: the node grants Apocalypse, whose Hailstorm, Meteor and Crash Lightning are the group's other skills
		local function disaster(index, groups, config, statSet)
			return calc("Druid", "Apocalypse", "tree", { groups = groups, config = config, index = index, skillId = statSet and "ApocalypseLightningPlayer", statSet = statSet })
		end

		it("keeps the self-cast numbers with approximations off", function()
			local output, skill = disaster(2, { "Spark 20/0  1" })
			assert.are.equals("Hailstorm", skill.activeEffect.grantedEffect.name)
			assert.is_nil(skill.skillData.triggered)
			assert.are.equals(0, output.Speed)
		end)

		it("triggers each disaster by a third of the interval's triggers, at the uptime of the Glory buff", function()
			local hits, _, p = spark()
			-- 100 Glory needed, 100% of the enemy's Power per Hit; the buff lasts 12 s, a trigger every 750 ms, one of three disasters
			local fill = 100 / (hits * p)
			local expected = 1000 / 750 * 12 / (12 + fill) / 3
			-- Hits per cast from the skills' data: Hailstorm 9 bolts, Meteor one impact, Crash Lightning's pulses 3 (its Final Strike set: one)
			local hitsPerCast = { Hailstorm = 9, Meteor = 1, ["Crash Lightning"] = 3 }
			for index, name in pairs({ [2] = "Hailstorm", [3] = "Meteor", [4] = "Crash Lightning" }) do
				newBuild()
				local output, skill = disaster(index, { "Spark 20/0  1" }, approx)
				assert.are.equals(name, skill.activeEffect.grantedEffect.name)
				assert.are.equals("Apocalypse's Trigger: Spark", skill.infoMessage)
				assert.are.near(expected, output.Speed, expected * 1e-9)
				assert.are.near(output.AverageDamage * output.Speed * hitsPerCast[name], output.TotalDPS, output.TotalDPS * 1e-9)
				assert.are.equals(hitsPerCast[name] > 1, skill.infoMessage2:find("Hits per cast", 1, true) ~= nil)
			end
			newBuild()
			local output = disaster(4, { "Spark 20/0  1" }, approx, 2)
			assert.are.near(expected, output.Speed, expected * 1e-9)
			assert.are.near(output.AverageDamage * output.Speed, output.TotalDPS, output.TotalDPS * 1e-9)
		end)

		it("needs a skill that Hits: nothing without one", function()
			local output, skill = disaster(2, { }, approx)
			assert.are.equals(0, output.Speed)
			assert.are.equals(0, output.TotalDPS)
		end)
	end)

	describe("Archon of Chayula", function()
		local function tornado(groups, config, mods)
			return calc("Monk", "Archon of Chayula", "tree", { groups = groups, config = config, index = 2, weapon = "Wooden Club", mods = mods })
		end
		local chaos = "Adds 10 to 20 Chaos Damage to Spells"

		it("keeps the self-cast numbers with approximations off", function()
			local output, skill = tornado({ "Spark 20/0  1" }, nil, chaos)
			assert.are.equals("Chayula's Will", skill.activeEffect.grantedEffect.name)
			assert.is_nil(skill.skillData.triggered)
			assert.are.equals(0, output.Speed)
		end)

		it("spawns its tornado every 3 s of the buff, at the uptime of the Glory buff from Chaos Hits", function()
			local hits, _, p = spark(chaos)
			-- the Archon Buff lasts 10 s
			local fill = 100 / (hits * p)
			local expected = 1000 / 3000 * 10 / (10 + fill)
			local output, skill = tornado({ "Spark 20/0  1" }, approx, chaos)
			assert.are.equals("Archon of Chayula's Trigger: Spark", skill.infoMessage)
			assert.are.near(expected, output.Speed, expected * 1e-9)
			-- the tornado hits every 200 ms for its 8 s
			assert.are.near(output.AverageDamage * output.Speed * 40, output.TotalDPS, output.TotalDPS * 1e-9)
			assert.is_truthy(skill.infoMessage2:find("40 Hits per cast", 1, true))
			newBuild()
			output = tornado({ "Spark 20/0  1" }, approx, chaos .. "\n20% increased Skill Effect Duration")
			assert.are.near(output.AverageDamage * output.Speed * 48, output.TotalDPS, output.TotalDPS * 1e-9)
		end)

		it("uses one uptime for the Archon Buff and the tornado's triggers: the Glory rule's", function()
			local hits, _, p = spark(chaos .. "\n20% increased Archon Buff duration")
			local fill = 100 / (hits * p)
			local uptime = 12 / (12 + fill)
			local output = tornado({ "Spark 20/0  1" }, approx, chaos .. "\n20% increased Archon Buff duration")
			-- the tornado every 3 s of the buff, the buff's effects (Archon of Chayula: 20% more Physical and Chaos damage) scaled by the same uptime
			assert.are.near(uptime / 3, output.Speed, 1e-9)
			assert.are.near(uptime * 100, output.ArchonEffectMod, 1e-6)
			assert.are.near(output.ArchonEffectMod / 100, output.Speed * 3, 1e-9)
			-- with approximations off there is no Archon Buff, and the numbers are the build's own
			newBuild()
			local off = tornado({ "Spark 20/0  1" }, nil, chaos)
			assert.is_nil(off.ArchonEffectMod)
			-- a configured Archon Buff wins: always up, and the tornado's rate keeps the Glory uptime
			newBuild()
			local up = tornado({ "Spark 20/0  1" }, { useApproximations = true, conditionAffectedByArchon = true, archonBuff = "ArchonOfChayula" }, chaos)
			assert.are.near(100, up.ArchonEffectMod, 1e-9)
		end)

		it("needs Hits that deal Chaos damage", function()
			local output = tornado({ "Spark 20/0  1" }, approx)
			assert.are.equals(0, output.Speed)
			assert.is_nil(output.ArchonEffectMod) -- no Glory source: no Archon Buff approximation either
		end)
	end)

	describe("Midnight Zenith", function()
		-- the skill's second stat set is the Ice Crystal that deals the damage
		local function crystal(groups, config, mods)
			return calc("Witch", "Midnight Zenith", "item", { groups = groups, config = config, mods = mods, skillId = "MidnightStarPlayer", statSet = 2 })
		end

		it("keeps the self-cast numbers with approximations off", function()
			local output, skill = crystal({ "Spark 20/0  1" })
			assert.is_nil(skill.skillData.triggered)
			assert.are.equals(1, output.Speed)
		end)

		it("makes Ice Crystals from the Arctic Petals of the build's Critical Hits, at most the limit per duration", function()
			local output, skill = crystal({ "Spark 20/0  1" }, approx)
			-- the Critical Hits of the Spark group in the same build (the amulet's implicit raises its Critical Hit Chance)
			local midnight = build.mainSocketGroup
			for index, group in ipairs(build.skillsTab.socketGroupList) do
				if group.gemList[1] and group.gemList[1].nameSpec == "Spark" then
					build.mainSocketGroup = index
				end
			end
			build.buildFlag = true
			runCallback("OnFrame")
			local hits, crits = rates(build.calcsTab.mainOutput)
			build.mainSocketGroup = midnight
			assert.are.equals("Midnight Zenith's Trigger: Spark", skill.infoMessage)
			local data = skill.skillData
			assert.are.equals(10, data.midnightSeedsPerAttempt)
			assert.are.equals(5, data.midnightCrystalsPerAttempt)
			-- the pinnacle boss is Rare or Unique: each Critical Hit gives its Petals; 1 kill per second, the Critical share of them,
			-- a Power 1 monster each
			local petals = crits * data.midnightSeedsOnRareCrit + math.min(1 * crits / hits, crits)
			local expected = math.min(petals / 10 * 5, data.midnightMaxCrystals / data.duration)
			assert.are.near(expected, output.Speed, expected * 1e-9)
			assert.are.near(output.AverageDamage * output.Speed, output.TotalDPS, output.TotalDPS * 1e-9)
			-- more Critical Hits (and more kills) never lower it, and it never passes the limit
			newBuild()
			local more = crystal({ "Spark 20/0  1" }, { useApproximations = true, approxKillsPerSecond = 100 })
			assert.is_true(more.Speed >= output.Speed)
			assert.is_true(more.Speed <= data.midnightMaxCrystals / data.duration + 1e-9)
		end)

		it("makes none without a skill that hits", function()
			local output = crystal({ }, approx)
			assert.are.equals(0, output.Speed)
		end)
	end)

	describe("Inevitable Agony", function()
		-- a skill that deals no damage: its debuff makes the enemy take the recorded share (25%) more from Hits, times the share of the
		-- debuff's duration the enemy survives
		local function withSpark(config, enabled)
			newBuild()
			local output, _, agony = calc("Sorceress", "Inevitable Agony", "tree", { groups = { "Spark 20/0  1" }, config = config })
			for index, group in ipairs(build.skillsTab.socketGroupList) do
				if group.gemList[1] and group.gemList[1].nameSpec == "Spark" then
					build.mainSocketGroup = index
				end
			end
			agony.enabled = enabled
			build.buildFlag = true
			runCallback("OnFrame")
			return copyTable(build.calcsTab.mainOutput, true)
		end

		it("changes nothing with approximations off or the skill disabled", function()
			local off = withSpark({ approxDebuffSurvival = 100 }, false)
			assert.is_true(off.TotalDPS > 0)
			assert.are.equals(off.TotalDPS, withSpark({ approxDebuffSurvival = 100 }, true).TotalDPS)
			assert.are.equals(off.TotalDPS, withSpark({ useApproximations = true, approxDebuffSurvival = 100 }, false).TotalDPS)
		end)

		it("is a MORE multiplier of the recorded share x the share of the duration the enemy survives", function()
			local base = withSpark({ useApproximations = true }, false).TotalDPS
			assert.are.near(base * 1.25, withSpark({ useApproximations = true }, true).TotalDPS, base * 1e-9)
			-- (the engine rounds a MORE multiplier to whole percent)
			assert.are.near(base * 1.10, withSpark({ useApproximations = true, approxDebuffSurvival = 40 }, true).TotalDPS, base * 1e-9)
			assert.are.near(base, withSpark({ useApproximations = true, approxDebuffSurvival = 0 }, true).TotalDPS, base * 1e-9)
		end)
	end)
end)
