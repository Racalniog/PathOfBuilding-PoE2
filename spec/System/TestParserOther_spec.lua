describe("TestParserOther", function()
	before_each(function()
		newBuild()
	end)

	-- parseMod results are cached (and ModCache.lua may hold older results), so drop the entry under test
	local function parse(line)
		modLib.parseModCache[line] = nil
		local list, extra = modLib.parseMod(line)
		assert.is_truthy(list, line)
		assert.is_nil(extra, line)
		return list
	end

	local function check(mod, name, modType, value, flags, keywordFlags)
		assert.are.equals(name, mod.name, name)
		assert.are.equals(modType, mod.type, name)
		assert.are.equals(value, mod.value, name)
		assert.are.equals(flags or 0, mod.flags, name)
		assert.are.equals(keywordFlags or 0, mod.keywordFlags, name)
		return mod
	end

	it("reads Armour Break sources as able to break armour", function()
		for _, line in ipairs({
			"Break Armour equal to 6% of Physical Damage dealt",
			"Breaks Armour equal to 40% of damage from Hits with this weapon",
			"Break 50% of Armour on Pinning an Enemy",
		}) do
			local list = parse(line)
			assert.are.equals(1, #list, line)
			check(list[1], "Condition:CanArmourBreak", "FLAG", true)
			assert.are.equals("ArmourBreak", list[1][1].effectName, line)
		end
		local list = parse("Hits Break 50 Armour")
		check(list[1], "Condition:CanArmourBreak", "FLAG", true)
		check(list[2], "ArmourBreakPerHit", "BASE", 50)
	end)

	it("reads Rage gained on any event as Rage generation", function()
		for _, line in ipairs({
			"Gain 10 Rage when Critically Hit by an Enemy",
			"Gain 1 Rage when your Hit Ignites a target",
			"Gain 8 Rage when you use a Life Flask",
		}) do
			local list = parse(line)
			assert.are.equals(1, #list, line)
			check(list[1], "Condition:CanGainRage", "FLAG", true)
		end
	end)

	it("scales damage and crit chance with times pierced", function()
		local list = parse("Projectiles deal 64% increased Damage with Hits for each time they have Pierced")
		local mod = check(list[1], "Damage", "INC", 64, 0, KeywordFlag.Hit)
		assert.are.equals("PiercedCount", mod[1].stat)
		assert.are.equals(SkillType.Projectile, mod[2].skillType)
		list = parse("Projectiles have 53% increased Critical Hit chance for each time they have Pierced")
		mod = check(list[1], "CritChance", "INC", 53)
		assert.are.equals("PiercedCount", mod[1].stat)
		assert.are.equals(SkillType.Projectile, mod[2].skillType)
	end)

	it("reads two additional Projectiles while moving", function()
		local list = parse("Projectile Attacks have a 12% chance to fire two additional Projectiles while moving")
		local mod = check(list[1], "TwoAdditionalProjectilesChance", "BASE", 12, ModFlag.Attack + ModFlag.Projectile)
		assert.are.equals("Moving", mod[1].var)
	end)

	it("splits Chaos damage taken as a random element three ways", function()
		local list = parse("15% of Chaos Damage from Hits taken as Damage of a random Element")
		assert.are.equals(3, #list)
		check(list[1], "ChaosDamageFromHitsTakenAsFire", "BASE", 5)
		check(list[2], "ChaosDamageFromHitsTakenAsCold", "BASE", 5)
		check(list[3], "ChaosDamageFromHitsTakenAsLightning", "BASE", 5)
	end)

	it("reads conditional evasion, stun and chill immunity", function()
		local mod = check(parse("Enemies which are on Full Life cannot Evade your Hits")[1], "CannotBeEvaded", "FLAG", true)
		assert.are.equals("FullLife", mod[1].var)
		assert.are.equals("enemy", mod[1].actor)
		mod = check(parse("You cannot be Light Stunned if you've been Stunned Recently")[1], "StunImmune", "FLAG", true)
		assert.are.equals("StunnedRecently", mod[1].var)
		mod = check(parse("Unaffected by Chill during Dodge Roll")[1], "ChillImmune", "FLAG", true)
		assert.are.equals("InDodgeRoll", mod[1].var)
	end)
end)
