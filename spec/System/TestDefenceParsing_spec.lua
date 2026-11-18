describe("TestDefenceParsing", function()
	-- parseMod results are cached (and ModCache.lua may hold older results), so drop the entries under test
	local function parse(line)
		modLib.parseModCache[line] = nil
		local list, extra = modLib.parseMod(line)
		assert.is_truthy(list, line)
		assert.is_nil(extra, line)
		return list
	end

	local function check(line, name, modType, value, tagType, tagVar)
		local list = parse(line)
		assert.are.equals(1, #list, line)
		local mod = list[1]
		assert.are.equals(name, mod.name, line)
		assert.are.equals(modType, mod.type, line)
		assert.are.equals(value, mod.value, line)
		assert.are.equals(tagType, mod[1] and mod[1].type, line)
		assert.are.equals(tagVar, mod[1] and mod[1].var, line)
	end

	it("parses 'Take N% less Damage from Hits' as an approximation active half the time", function()
		check("Take 30% less Damage from Hits", "DamageTakenWhenHit", "MORE", -15, "Condition", "UseApproximations")
	end)

	it("parses stun threshold and evasion while parrying / shield raised", function()
		check("20% increased Stun Threshold while Parrying", "StunThreshold", "INC", 20, "Condition", "Parrying")
		check("25% increased Evasion Rating while Parrying", "Evasion", "INC", 25, "Condition", "Parrying")
		check("100% increased Stun Threshold during Empowered Attacks", "StunThreshold", "INC", 100, "Condition", "Empowered")
		-- The generic "Double X" parse: MORE 100 that doesn't stack with other doubling, plus its limit counter
		local doubled = parse("Double Stun Threshold while Shield is Raised")[1]
		assert.are.equals("StunThreshold", doubled.name)
		assert.are.equals(100, doubled.value)
		assert.are.equals("ShieldRaised", doubled[1].var)
		assert.are.equals("StunThresholdDoubled", doubled[2].var)
		check("30% of Physical Damage taken as Lightning while your Shield is raised", "PhysicalDamageTakenAsLightning", "BASE", 30, "Condition", "ShieldRaised")
	end)

	it("parses block conditions that need a raised shield", function()
		check("25% increased Chance to Block if you've Blocked with a raised Shield Recently", "BlockChance", "INC", 25, "Condition", "ActiveBlockedRecently")
		check("+5% to maximum Block chance if you've Blocked with a raised Shield Recently", "BlockChanceMax", "BASE", 5, "Condition", "ActiveBlockedRecently")
	end)

	it("parses leech rate lines", function()
		check("Leech Mana 20% slower", "ManaLeechRate", "INC", -20)
		check("Leech Life 67% less quickly", "LifeLeechRate", "MORE", -67)
	end)

	it("parses recoup and flask recovery lines", function()
		check("15% of Damage taken during effect Recouped as Life", "LifeRecoup", "BASE", 15, "Condition", "UsingFlask")
		check("40% less Life Flask Recovery", "FlaskLifeRecovery", "MORE", -40)
	end)

	it("parses dodge roll conditions and ES regeneration", function()
		check("15% increased Mana Cost Efficiency if you haven't Dodge Rolled Recently", "ManaCostEfficiency", "INC", 15, "Condition", "DodgeRolledRecently")
		check("10% increased Mana Cost Efficiency if you have Dodge Rolled Recently", "ManaCostEfficiency", "INC", 10, "Condition", "DodgeRolledRecently")
		check("You cannot Recover Energy Shield from Regeneration", "NoEnergyShieldRegen", "FLAG", true)
	end)

	it("applies negative ranges (rolled negative 'reduced' becomes increased)", function()
		check(itemLib.applyRange("(-25-25)% reduced Flask Life Recovery rate", 0.1), "FlaskLifeRecoveryRate", "INC", 20)
		check(itemLib.applyRange("(-30-30)% reduced Life Regeneration rate", 0.9), "LifeRegen", "INC", -24)
		check(itemLib.applyRange("+(-30-30)% to Fire Resistance", 0.1), "FireResist", "BASE", -24)
		check(itemLib.applyRange("+(-30-30)% to Fire Resistance", 0.9), "FireResist", "BASE", 24)
	end)

	it("keeps the plus sign when a signed range rolls exactly zero", function()
		assert.are.equals("+0% to Fire Resistance", itemLib.applyRange("+(-30-30)% to Fire Resistance", 0.5))
		check(itemLib.applyRange("+(-40-40)% to Cold Resistance", 0.5), "ColdResist", "BASE", 0)
	end)
end)
