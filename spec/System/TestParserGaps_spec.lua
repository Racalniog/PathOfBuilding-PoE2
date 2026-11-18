describe("TestParserGaps", function()
	before_each(function()
		newBuild()
	end)

	-- parseMod results are cached (and ModCache.lua may hold older results), so drop the entries under test
	local function parse(line)
		modLib.parseModCache[line] = nil
		local list, extra = modLib.parseMod(line)
		assert.is_truthy(list, line)
		assert.is_nil(extra, line)
		return list
	end

	it("detects a modifier wrapped over two lines", function()
		assert.is_true(modLib.wrapsInto("Life that would be lost by taking Damage is instead Reserved", "until you take no Damage to Life for 5 seconds"))
		assert.is_true(modLib.wrapsInto("10% chance to gain Onslaught for 3 seconds when you kill an", "Enemy"))
		assert.is_false(modLib.wrapsInto("+10% to Fire Resistance", "+10% to Cold Resistance"))
		assert.is_false(modLib.wrapsInto("+10% to Fire Resistance", nil))
		-- a pasted item's separator never belongs to a modifier
		assert.is_false(modLib.wrapsInto("Gain 10% of Damage as Extra Damage of a random Element per", "--------"))
	end)

	it("keeps the halves of a wrapped passive tree line together", function()
		local node = { id = "t", dn = "t", type = "Notable", sd = {
			"5% chance when collecting an Elemental Infusion to gain an",
			"additional Elemental Infusion of the same type",
			"+10 to Strength",
		} }
		build.spec.tree:ProcessStats(node)
		assert.are.equals("5% chance when collecting an Elemental Infusion to gain an additional Elemental Infusion of the same type", node.mods[1].text)
		assert.is_true(node.mods[2].combined)
		assert.are.equals(1, #node.mods[3].list)
		assert.is_nil(node.mods[3].text)
	end)

	it("keeps the halves of a wrapped item line together", function()
		local item = new("Item"):Item("Rarity: Rare\nName\nArcane Raiment\n10% chance to gain Onslaught for 3 seconds when you kill an\nEnemy\n+10 to Strength")
		assert.are.equals(2, #item.explicitModLines)
		assert.are.equals("10% chance to gain Onslaught for 3 seconds when you kill an\nEnemy", item.explicitModLines[1].line)
		assert.are.equals(1, #item.explicitModLines[2].modList)
	end)

	it("doesn't give up a line that is understood on its own for an unreadable continuation", function()
		-- Widow's Reign: the first line is a known mechanic, the second is not
		local item = new("Item"):Item("Rarity: Rare\nName\nArcane Raiment\nLife that would be lost by taking Damage is instead Reserved\nuntil you take no Damage to Life for 5 seconds")
		assert.are.equals("DamageInsteadReservesLife", item.explicitModLines[1].modList[1].name)
	end)

	local function check(line, name, modType, value, flags, keywordFlags)
		local mod = parse(line)[1]
		assert.are.equals(name, mod.name, line)
		assert.are.equals(modType, mod.type, line)
		assert.are.equals(value, mod.value, line)
		assert.are.equals(flags or 0, mod.flags, line)
		assert.are.equals(keywordFlags or 0, mod.keywordFlags, line)
		return mod
	end

	it("parses chain and fork lines", function()
		check("Lightning Skills Chain +1 times", "ChainCountMax", "BASE", 1, 0, KeywordFlag.Lightning)
		check("Projectiles from Spells Chain +2 times", "ChainCountMax", "BASE", 2, OR64(ModFlag.Spell, ModFlag.Projectile))
		local list = parse("Projectiles from Spells Fork")
		assert.are.equals(2, #list)
		assert.are.equals("ForkOnce", list[1].name)
		assert.are.equals("ForkCountMax", list[2].name)
		assert.are.equals(1, list[2].value)
		assert.are.equals(OR64(ModFlag.Spell, ModFlag.Projectile), list[2].flags)
	end)

	it("parses cost efficiency and attribute requirement lines", function()
		local efficiency = check("10% increased Mana Cost Efficiency of Spells", "ManaCostEfficiency", "INC", 10)
		assert.are.equals(SkillType.Spell, efficiency[1].skillType)
		-- only equipment: gems keep their requirements
		check("Equipment has no Attribute Requirements", "GlobalItemAttributeRequirements", "MORE", -100)
	end)

end)
