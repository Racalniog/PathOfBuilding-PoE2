-- Minion, companion, totem and Offering mechanics of docs/calculationGapsPlan.md (Phase 3): the exact ones that depend on the
-- skills in the build and the configuration, and the approximations (Use approximations) of the Minion death and revival events.
describe("TestMinionGaps", function()
	before_each(function()
		newBuild()
	end)

	-- Pastes the skills (one socket group each, the first is the main skill) once, then recalculates with the mods and config
	local pasted
	local function setup(customMods, config, skills)
		if skills then
			for _, skill in ipairs(skills) do
				build.skillsTab:PasteSocketGroup(skill .. " 20/0 1\n")
			end
		end
		build.configTab.input.customMods = customMods
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		build.buildFlag = true
		runCallback("OnFrame")
		return build.calcsTab.mainOutput, build.calcsTab.mainEnv
	end

	local function parse(line)
		local mods, extra = modLib.parseMod(line)
		assert.is_nil(extra, line)
		return mods
	end

	it("reads the Minion, Companion and Totem lines", function()
		assert.are.equals("TotemPlacementRange", parse("20% increased Totem Placement range")[1].name)
		assert.are.equals("ActiveTotemLimit", parse("Your Totem Limit is doubled")[1].name)
		assert.are.equals(100, parse("Your Totem Limit is doubled")[1].value)
		assert.are.equals("CompanionLimit", parse("You can have two Companions of different types")[1].name)
		assert.are.equals("UnlimitedCompanions", parse("You can have any number of Companions of different types")[1].name)
		assert.are.equals(-25, parse("Minions Revive 25% slower")[1].value)
		assert.are.equals(-20, parse("20% reduced Reservation Efficiency of Skills which create Undead Minions")[1].value)
		local gain = parse("Gain 3% of Damage as Chaos Damage per Undead Minion")[1]
		assert.are.equals("DamageAsChaos", gain.name)
		assert.are.equals("UndeadMinion", gain[1].var)
		-- Every five Rage: the multiplier tag of the minion's mod counts Rage Effect in fives
		local rage = parse("Every five Rage also grants you 2% increased Minion Attack Speed")[1].value.mod
		assert.are.equals(5, rage[1].div)
		assert.are.equals("RageEffect", rage[1].var)
		-- Companions in your Presence: the minion modifier also needs a Companion in your Presence
		local presence = parse("Companions in your Presence have -20% to all Elemental Resistances")[1]
		assert.are.equals("CompanionInPresence", presence[1].var)
		-- lines that stay unread: nothing models what kills Minions or Totems
		assert.is_not_nil(select(2, modLib.parseMod("Minions cannot Die while affected by a Life Flask")))
		assert.is_not_nil(select(2, modLib.parseMod("Totems Regenerate 3% of maximum Life per second")))
	end)

	it("doubles the Totem limit as a 100% more of the total", function()
		-- the skill needs a weapon
		build.itemsTab:CreateDisplayItemFromRaw("Rarity: NORMAL\nShortsword")
		build.itemsTab:AddDisplayItem()
		local output = setup("", nil, { "Shockwave Totem" })
		local limit = output.ActiveTotemLimit
		assert.are.equals(1, limit)
		assert.are.equals(2 * limit, setup("Your Totem Limit is doubled").ActiveTotemLimit)
		-- the doubling applies to the additional Totems as well: (limit + 2) x 2
		assert.are.equals(2 * (limit + 2), setup("Your Totem Limit is doubled\nCan have up to 2 additional Totems summoned at a time").ActiveTotemLimit)
	end)

	it("limits Companions to one unless a modifier allows more, and counts the different ones", function()
		local _, env = setup("15% increased Damage per each different Companion in your Presence", nil, { "Azmerian Wolf", "Rhoa Mount", "Wild Protector" })
		-- one Companion by default: the first one in the skill list
		assert.are.equals(1, env.player.modDB:GetMultiplier("CompanionTypes"))
		assert.are.equals(1, env.player.modDB:GetMultiplier("PersistentMinionTypes"))
		assert.are.equals(1, env.player.modDB:GetMultiplier("PersistentMinions"))
		assert.are.equals(15, env.player.modDB:Sum("INC", nil, "Damage"))
		-- the keystone and the unique: two, then any number (here three) of different types
		_, env = setup("15% increased Damage per each different Companion in your Presence\nYou can have two Companions of different types")
		assert.are.equals(2, env.player.modDB:GetMultiplier("CompanionTypes"))
		assert.are.equals(2, env.player.modDB:GetMultiplier("PersistentMinionTypes"))
		assert.are.equals(30, env.player.modDB:Sum("INC", nil, "Damage"))
		_, env = setup("15% increased Damage per each different Companion in your Presence\nYou can have any number of Companions of different types")
		assert.are.equals(3, env.player.modDB:GetMultiplier("CompanionTypes"))
		assert.are.equals(3, env.player.modDB:GetMultiplier("PersistentMinions"))
		assert.are.equals(45, env.player.modDB:Sum("INC", nil, "Damage"))
	end)

	it("counts the different active Offerings and gives Minion Damage with at least two", function()
		local line = "50% increased Minion Damage while you have at least two different active Offerings"
		local _, env = setup("", nil, { "Skeletal Warrior", "Bone Offering" })
		-- one Offering: nothing (the Offerings' own buffs are in the base)
		local base = env.minion.modDB:Sum("INC", nil, "Damage")
		assert.are.equals(1, env.player.modDB:GetMultiplier("ActiveOfferingTypes"))
		assert.are.equals(base, select(2, setup(line)).minion.modDB:Sum("INC", nil, "Damage"))
		-- a second Offering skill: 50% increased
		build.skillsTab:PasteSocketGroup("Pain Offering 20/0 1\n")
		_, env = setup("")
		base = env.minion.modDB:Sum("INC", nil, "Damage")
		_, env = setup(line)
		assert.are.equals(2, env.player.modDB:GetMultiplier("ActiveOfferingTypes"))
		assert.are.equals(base + 50, env.minion.modDB:Sum("INC", nil, "Damage"))
		-- the configuration overrides the count (the Offerings aren't always up)
		_, env = setup(line, { multiplierActiveOfferingTypes = 1 })
		assert.are.equals(base, env.minion.modDB:Sum("INC", nil, "Damage"))
		_, env = setup(line, { multiplierActiveOfferingTypes = 3 })
		assert.are.equals(base + 50, env.minion.modDB:Sum("INC", nil, "Damage"))
	end)

	it("counts Undead and Persistent Minions", function()
		-- the Skeleton skills have no limit in the data: each enabled skill is one Undead and Persistent Minion
		local line = "Gain 3% of Damage as Chaos Damage per Undead Minion"
		local _, env = setup(line, nil, { "Skeletal Warrior", "Skeletal Sniper" })
		assert.are.equals(2, env.player.modDB:GetMultiplier("UndeadMinion"))
		assert.are.equals(2, env.player.modDB:GetMultiplier("PersistentMinions"))
		assert.are.equals(6, env.player.modDB:Sum("BASE", nil, "DamageAsChaos"))
		-- the configuration sets the number of them
		_, env = setup(line, { multiplierUndeadMinion = 5 })
		assert.are.equals(15, env.player.modDB:Sum("BASE", nil, "DamageAsChaos"))
		-- a Companion adds one Persistent Minion, no Undead one
		build.configTab.input.multiplierUndeadMinion = nil
		_, env = setup(line, nil, { "Azmerian Wolf" })
		assert.are.equals(2, env.player.modDB:GetMultiplier("UndeadMinion"))
		assert.are.equals(3, env.player.modDB:GetMultiplier("PersistentMinions"))
	end)

	it("Minions revive faster if all of them are Companions", function()
		local line = "Minions Revive 35% faster if all your Minions are Companions"
		local _, env = setup(line, nil, { "Azmerian Wolf" })
		assert.are.equals(35, env.player.modDB:Sum("INC", nil, "MinionRevivalSpeed"))
		assert.is_true(env.player.modDB.conditions["AllMinionsAreCompanions"])
		-- a Skeleton is a persistent Minion that isn't a Companion
		_, env = setup(line, nil, { "Skeletal Warrior" })
		assert.are.equals(0, env.player.modDB:Sum("INC", nil, "MinionRevivalSpeed"))
		assert.is_nil(env.player.modDB.conditions["AllMinionsAreCompanions"])
	end)

	it("applies Minion lines that depend on configured state", function()
		-- Gigantic if they have Revived Recently: 20% more Life (and Damage) from the Gigantic flag
		local line = "Your Minions are Gigantic if they have Revived Recently"
		local _, env = setup(line, nil, { "Skeletal Warrior" })
		local more = env.minion.modDB:More(nil, "Life")
		assert.is_nil(env.minion.modDB:Flag(nil, "Gigantic") or nil)
		_, env = setup(line, { conditionMinionsRevivedRecently = true })
		assert.are.near(more * 1.2, env.minion.modDB:More(nil, "Life"), 1e-9)
		-- Surpassing chance for an additional Projectile
		_, env = setup("Minions have +50% Surpassing chance to fire an additional Projectile")
		assert.are.equals(50, env.minion.modDB:Sum("BASE", nil, "SurpassingProjectileChance"))
		-- Companions deal 10% more Damage for each different type of dead Companion: 2 types = one 20% more
		build.skillsTab:PasteSocketGroup("Azmerian Wolf 20/0 1\n")
		build.mainSocketGroup = #build.skillsTab.socketGroupList
		line = "Companions deal 10% more Damage for each different type of dead Companion you have"
		_, env = setup(line)
		local damage = env.minion.modDB:More(nil, "Damage")
		_, env = setup(line, { multiplierDeadCompanionTypes = 2 })
		assert.are.near(damage * 1.2, env.minion.modDB:More(nil, "Damage"), 1e-9)
		-- Companions in your Presence: resistances and Onslaught while Shapeshifted, only with the Companion in your Presence
		local resist = "Companions in your Presence have -20% to all Elemental Resistances\nCompanions in your Presence have Onslaught while you are Shapeshifted"
		_, env = setup(resist, { companionInPresence = true, conditionShapeshifted = true })
		assert.are.equals(-20, env.minion.modDB:Sum("BASE", nil, "ElementalResist"))
		assert.is_true(env.minion.modDB:Flag(nil, "Onslaught"))
		_, env = setup(resist, { companionInPresence = true, conditionShapeshifted = false })
		assert.is_falsy(env.minion.modDB:Flag(nil, "Onslaught"))
		_, env = setup(resist, { companionInPresence = false, conditionShapeshifted = true })
		assert.are.equals(0, env.minion.modDB:Sum("BASE", nil, "ElementalResist"))
		assert.is_falsy(env.minion.modDB:Flag(nil, "Onslaught"))
	end)

	it("Minions Break Armour lets the enemy's Armour be Broken, Culling Strike needs a Beast with a Companion", function()
		local _, env = setup("Minions Break Armour equal to 3% of Physical damage dealt", nil, { "Fireball" })
		assert.is_true(env.player.modDB:Flag(nil, "Condition:CanArmourBreak"))
		build.skillsTab:PasteSocketGroup("Azmerian Wolf 20/0 1\n")
		local line = "Culling Strike against Beasts while your Companion is in your Presence"
		local output = setup(line, { enemyIsBoss = "None" })
		assert.are.equals(0, output.CullPercent)
		output = setup(line, { enemyIsBoss = "None", conditionEnemyBeast = true, companionInPresence = true })
		assert.are.equals(data.gameConstants.CullingStrikeNormalThreshold, output.CullPercent)
		output = setup(line, { enemyIsBoss = "None", conditionEnemyBeast = true, companionInPresence = false })
		assert.are.equals(0, output.CullPercent)
	end)

	it("Minion death effects: the configuration is exact, approximations averages them over the death rate", function()
		local onslaught = "Gain Onslaught for 4 seconds when a Minion Dies"
		local surge = "Gain Arcane Surge when a Minion Dies"
		local _, env = setup(onslaught .. "\n" .. surge, { useApproximations = false, approxMinionDeathsPerSecond = 0.5 }, { "Skeletal Warrior" })
		local move = env.player.modDB:Sum("INC", nil, "MovementSpeed")
		local cast = env.player.modDB:Sum("INC", { flags = ModFlag.Cast }, "Speed")
		-- off: nothing, unless a Minion died recently (Onslaught 20% attack and cast speed, 10% movement speed; Arcane Surge 15% cast speed)
		_, env = setup(onslaught .. "\n" .. surge, { useApproximations = false, approxMinionDeathsPerSecond = 0.5 })
		assert.are.equals(move, env.player.modDB:Sum("INC", nil, "MovementSpeed"))
		assert.are.equals(cast, env.player.modDB:Sum("INC", { flags = ModFlag.Cast }, "Speed"))
		_, env = setup(onslaught .. "\n" .. surge, { useApproximations = false, conditionMinionsDiedRecently = true })
		assert.are.equals(move + 10, env.player.modDB:Sum("INC", nil, "MovementSpeed"))
		assert.are.equals(cast + 20 + 15, env.player.modDB:Sum("INC", { flags = ModFlag.Cast }, "Speed"))
		-- on, 0.5 deaths/s: Onslaught (4 s) is up 1 - e^-2 of the time, Arcane Surge (10 s) 1 - e^-5
		_, env = setup(onslaught .. "\n" .. surge, { useApproximations = true, conditionMinionsDiedRecently = false })
		assert.are.near(move + 10 * (1 - math.exp(-2)), env.player.modDB:Sum("INC", nil, "MovementSpeed"), 1e-9)
		assert.are.near(cast + 20 * (1 - math.exp(-2)) + 15 * (1 - math.exp(-5)), env.player.modDB:Sum("INC", { flags = ModFlag.Cast }, "Speed"), 1e-9)
		-- no deaths, no uptime
		_, env = setup(onslaught .. "\n" .. surge, { useApproximations = true, approxMinionDeathsPerSecond = 0 })
		assert.are.equals(move, env.player.modDB:Sum("INC", nil, "MovementSpeed"))
		assert.are.equals(cast, env.player.modDB:Sum("INC", { flags = ModFlag.Cast }, "Speed"))
	end)

	it("recovers Life when Minions are revived, at the rate persistent Minions that die come back", function()
		local line = "Recover 2% of maximum Life when one of your Minions is Revived"
		local output = setup(line, { useApproximations = false }, { "Azmerian Wolf", "Rhoa Mount" })
		assert.is_nil(output.LifeOnMinionReviveApproxRecovery)
		-- one Companion: it dies 0.1 times/s and is revived after the base revival time T, so 0.1 / (1 + 0.1 T) revivals/s.
		-- 2% of maximum Life is rounded up by PercentStat
		local T = data.misc.MinionRevivalTimeBase
		output = setup(line, { useApproximations = true, approxMinionDeathsPerSecond = 0.1 })
		assert.are.near(math.ceil(output.Life * 0.02) * 0.1 / (1 + 0.1 * T), output.LifeOnMinionReviveApproxRecovery, 1e-9)
		-- two Companions share the deaths: 2 x 0.05 / (1 + 0.05 T); revive speed shortens T
		output = setup(line .. "\nYou can have two Companions of different types\nMinions Revive 100% faster")
		assert.are.near(math.ceil(output.Life * 0.02) * 2 * 0.05 / (1 + 0.05 * T / 2), output.LifeOnMinionReviveApproxRecovery, 1e-9)
		-- it adds to the Life recovery per second
		local recovery = output.LifeRegenRecovery
		output = setup("You can have two Companions of different types\nMinions Revive 100% faster")
		assert.are.near(recovery - output.LifeRegenRecovery, math.ceil(output.Life * 0.02) * 2 * 0.05 / (1 + 0.05 * T / 2), 1e-6)
	end)
end)
