describe("TestInfusionArchon", function()
	before_each(function()
		newBuild()
	end)

	local function setup(customMods, config)
		build.configTab.input.customMods = customMods
		for var, val in pairs(config or { }) do
			build.configTab.input[var] = val
		end
		build.configTab:BuildModList()
		runCallback("OnFrame")
		return build.calcsTab.mainOutput
	end

	local grantRes = "Archon Buffs also grant +20% to all Elemental Resistances"
	local source = "Gain Elemental Archon when your Energy Shield Recharge begins"

	it("Archon Buff modifiers do nothing unless you are affected by one", function()
		local base = setup("").FireResist
		local output = setup(grantRes.."\nImmune to Shock while affected by an Archon Buff")
		assert.are.equals(base, output.FireResist)
		assert.is_nil(output.ArchonEffectMod)
		assert.is_true(not build.calcsTab.mainEnv.modDB:Flag(nil, "ShockImmune"))
	end)

	it("Archon Buffs also grant ..., scaled by the effect of Archon Buffs on you", function()
		local base = setup("").FireResist
		local on = { conditionAffectedByArchon = true }
		assert.are.equals(base + 20, setup(grantRes, on).FireResist)
		assert.are.equals(setup("", on).ColdResist + 20, setup(grantRes, on).ColdResist)
		-- with the "100% reduced" ceiling the buff adds nothing
		assert.are.equals(base, setup(grantRes.."\n100% reduced effect of Archon Buffs on you", on).FireResist)
		-- 20 x 1.10 = 22; 20 x 0.5 = 10
		assert.are.equals(base + 22, setup(grantRes.."\n10% increased effect of Archon Buffs on you", on).FireResist)
		assert.are.equals(base + 10, setup(grantRes.."\n50% reduced effect of Archon Buffs on you", on).FireResist)
		assert.are.near(110, setup(grantRes.."\n10% increased effect of Archon Buffs on you", on).ArchonEffectMod, 1e-9)
		-- "while affected by an Archon Buff" modifiers are conditions, not part of the buff
		setup("Immune to Shock while affected by an Archon Buff", on)
		assert.is_true(build.calcsTab.mainEnv.modDB:Flag(nil, "ShockImmune"))
	end)

	it("an Archon source gives an uptime only with approximations on", function()
		local base = setup("").FireResist
		-- approximations off: the source alone does nothing
		assert.are.equals(base, setup(source.."\n"..grantRes).FireResist)
		local approx = { useApproximations = true, approxArchonDuration = 10, approxArchonRecovery = 10 }
		-- no source: nothing to estimate
		assert.are.equals(base, setup(grantRes, approx).FireResist)
		-- uptime 10 / (10 + 10) = 0.5: 20 x 0.5 = 10
		local output = setup(source.."\n"..grantRes, approx)
		assert.are.equals(base + 10, output.FireResist)
		assert.are.equals(50, output.ArchonEffectMod)
		-- 100% increased duration: 20 / (20 + 10) = 2/3, 13.3 truncated to 13
		assert.are.equals(base + 13, setup(source.."\n"..grantRes.."\n100% increased Archon Buff duration", approx).FireResist)
		-- recovery expires 100% faster: 10 / (10 + 5) = 2/3
		assert.are.equals(base + 13, setup(source.."\n"..grantRes.."\nArchon recovery period expires 100% faster", approx).FireResist)
		-- 30% slower: 10 / (10 + 10 / 0.7) = 0.4118, 8.2 truncated to 8
		assert.are.equals(base + 8, setup(source.."\n"..grantRes.."\nArchon recovery period expires 30% slower", approx).FireResist)
		-- no recovery period: always up
		assert.are.equals(base + 20, setup(source.."\n"..grantRes.."\nArchon Buffs have no recovery period after you lose one", approx).FireResist)
		-- the config option means the buff is up: full effect, the estimate is not used
		approx.conditionAffectedByArchon = true
		assert.are.equals(base + 20, setup(source.."\n"..grantRes, approx).FireResist)
		-- uptime doesn't make an approximated immunity
		approx.conditionAffectedByArchon = false
		setup(source.."\nImmune to Shock while affected by an Archon Buff", approx)
		assert.is_true(not build.calcsTab.mainEnv.modDB:Flag(nil, "ShockImmune"))
	end)
end)
