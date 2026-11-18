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
		local approx = { useApproximations = true, approxArchonRecovery = 10 }
		-- no source: nothing to estimate
		assert.are.equals(base, setup(grantRes, approx).FireResist)
		-- Elemental Archon lasts 10 s (data.archonBuffs); uptime 10 / (10 + 10) = 0.5: 20 x 0.5 = 10
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

	local function withSkill(skill, customMods, config)
		build.skillsTab:PasteSocketGroup(skill)
		build.mainSocketGroup = 1
		return setup(customMods, config)
	end

	it("exports the Archon Buff templates", function()
		assert.are.equals(10, data.archonBuffs.ArchonElemental.duration)
		assert.are.equals(25, data.archonBuffs.ArchonElemental.stats["elemental_damage_with_spell_skills_+%_final_from_archon_buff"])
		assert.are.equals(100, data.archonBuffs.ArchonCold.stats["archon_elemental_damage_with_spells_%_to_convert_to_cold"])
		assert.are.equals(200, data.archonBuffs.ArchonUndeath.stats["minion_command_skill_cooldown_speed_+%_final_from_archon_of_undeath"])
		assert.are.equals(3, data.gameConstants.BaseMaximumInfusionCount)
		assert.are.equals(20000, data.gameConstants.BaseInfusionDurationMs)
	end)

	it("applies each elemental Archon Buff's own effect to spells", function()
		local base = withSkill("Fireball 20/0  1")
		local hit, ignite = base.AverageHit, base.IgniteChanceOnHit
		-- Elemental Archon: 25% more Elemental Damage with Spells, 100% more Ignite chance (which also scales with the hit)
		local on = { conditionAffectedByArchon = true }
		local output = setup("", on)
		assert.are.near(hit * 1.25, output.AverageHit, 0.01)
		assert.are.near(ignite * 1.25 * 2, output.IgniteChanceOnHit, 1e-9)
		-- 10% increased effect: 25 x 1.1 = 27.5, truncated to 27% more; 100% more chance becomes 110%
		output = setup("10% increased effect of Archon Buffs on you", on)
		assert.are.near(hit * 1.27, output.AverageHit, 0.5) -- damage rolls are whole numbers
		assert.are.near(ignite * 1.27 * 2.1, output.IgniteChanceOnHit, ignite * 0.01)
		-- Ice Archon: Fireball's fire damage converts to cold and gets 25% more, so it no longer ignites but builds up freeze
		output = setup("", { conditionAffectedByArchon = true, archonBuff = "ArchonCold" })
		assert.are.near(hit * 1.25, output.AverageHit, 0.01)
		assert.are.equals(0, output.IgniteChanceOnHit)
		assert.is_true(output.FreezeBuildupAvg > 0)
		-- Archon of Chayula: more physical and chaos damage only, Fireball unchanged; 20% more from the skill's stats
		output = setup("", { conditionAffectedByArchon = true, archonBuff = "ArchonOfChayula" })
		assert.are.near(hit, output.AverageHit, 0.01)
		assert.are.near(1.2, build.calcsTab.mainEnv.modDB:More(nil, "PhysicalDamage"), 1e-9)
		assert.are.near(1.2, build.calcsTab.mainEnv.modDB:More(nil, "ChaosDamage"), 1e-9)
		assert.is_true(build.calcsTab.mainEnv.modDB:Flag(nil, "Condition:CanWither"))
	end)

	it("converts spell damage to the Archon's element", function()
		local base = withSkill("Spark 20/0  1")
		assert.is_true(base.LightningHitAverage > 0)
		local output = setup("", { conditionAffectedByArchon = true, archonBuff = "ArchonFire" })
		assert.are.equals(0, output.LightningHitAverage)
		assert.are.near(base.LightningHitAverage * 1.25, output.FireHitAverage, 0.5)
	end)

	it("applies Archon of Undeath to minions and Nature's Archon to plant skills", function()
		withSkill("Skeletal Sniper 20/0  1")
		local base = build.calcsTab.mainEnv.minion.modDB:More(nil, "Damage")
		setup("", { conditionAffectedByArchon = true, archonBuff = "ArchonUndeath" })
		assert.are.near(base * 1.25, build.calcsTab.mainEnv.minion.modDB:More(nil, "Damage"), 1e-9)
		setup("", { conditionAffectedByArchon = true, archonBuff = "ArchonNature" })
		local plant = { skillTypes = { [SkillType.Plant] = true } }
		assert.are.equals(25, build.calcsTab.mainEnv.modDB:Sum("INC", plant, "Damage"))
		assert.are.near(3, build.calcsTab.mainEnv.modDB:More(plant, "Duration"), 1e-9)
		assert.are.equals(0, build.calcsTab.mainEnv.modDB:Sum("INC", nil, "Damage"))
	end)

	it("takes the Archon Buff from its source, at its uptime with approximations", function()
		local base = withSkill("Fireball 20/0  1")
		local undeath = "15% chance to gain Archon of Undeath when you use a Command skill"
		-- an Archon of Undeath source: nothing for Fireball, even when you say you are affected
		assert.are.near(base.AverageHit, setup(undeath, { conditionAffectedByArchon = true }).AverageHit, 0.01)
		-- picking the Archon overrides the source
		assert.are.near(base.AverageHit * 1.25, setup(undeath, { archonBuff = "ArchonElemental" }).AverageHit, 0.01)
		-- Elemental Archon at uptime 0.5: 25 x 0.5 = 12.5, truncated to 12% more
		build.configTab.input.conditionAffectedByArchon = false
		local output = setup(source, { useApproximations = true, approxArchonRecovery = 10 })
		assert.are.near(base.AverageHit * 1.12, output.AverageHit, 0.5)
	end)

	it("counts infusions up to their maximum", function()
		local output = setup("")
		assert.are.equals(3, output.FireInfusionsMax)
		assert.are.equals(20, output.FireInfusionDuration)
		assert.is_nil(output.FireInfusions)
		output = setup("+1 to maximum number of Elemental Infusions\n+1 to maximum Fire Infusions\n30% increased Elemental Infusion duration")
		assert.are.equals(5, output.FireInfusionsMax)
		assert.are.equals(4, output.ColdInfusionsMax)
		assert.are.equals(26, output.FireInfusionDuration)
		-- the duration line is about infusions only
		assert.are.equals(0, build.calcsTab.mainEnv.modDB:Sum("INC", nil, "Duration"))
		output = setup("", { multiplierFireInfusion = 9, multiplierColdInfusion = 2 })
		assert.are.equals(3, output.FireInfusions)
		assert.are.equals(2, output.ColdInfusions)
		assert.are.equals(3, build.calcsTab.mainEnv.modDB:GetMultiplier("FireInfusion"))
		assert.are.equals(0, build.calcsTab.mainEnv.modDB:GetMultiplier("LightningInfusion"))
	end)

	it("gives Inhibitor its more damage per infusion type", function()
		local base = withSkill("Fireball 20/0  1\nInhibitor 1/0  1")
		-- 4% more per type you have: Fire and Cold, 1.04 x 1.04
		local output = setup("", { multiplierFireInfusion = 1, multiplierColdInfusion = 3 })
		assert.are.near(base.AverageHit * 1.04 * 1.04, output.AverageHit, 0.5)
	end)

	it("estimates infusions and the share of infused casts with approximations", function()
		-- Fireball consumes a Fire Infusion; 0.8333 casts per second
		local base = withSkill("Fireball 20/0  1", "", { approxFireRemnantsPerSecond = 0.5, approxColdRemnantsPerSecond = 0.1 })
		assert.is_nil(base.FireInfusions)
		assert.is_nil(base.FireInfusedShare)
		local output = setup("", { useApproximations = true })
		local speed = output.Speed
		assert.are.near(0.5, output.FireInfusionGeneration, 1e-9)
		-- 0.5 gained / 0.8333 used per second = 60% of casts infused; each lasts until the next cast, 1.2 s: 0.5 x 1.2 = 0.6
		assert.are.near(0.5 / speed * 100, output.FireInfusedShare, 1e-9)
		assert.are.near(0.5 / speed, output.FireInfusions, 1e-9)
		-- Cold isn't consumed: 0.1 per second x 20 s = 2
		assert.are.near(2, output.ColdInfusions, 1e-9)
		assert.is_nil(output.ColdInfusedShare)
		-- 50% chance to not remove: 0.4167 removed per second < 0.5 gained: all casts infused,
		-- 0.4167 x 2.4 s + (0.5 - 0.4167) x 20 s = 2.67
		output = setup("Skills have 50% chance to not remove Elemental Infusions but still count as consuming them")
		local consumption = speed * 0.5
		assert.are.near(100, output.FireInfusedShare, 1e-9)
		assert.are.near(consumption / consumption + (0.5 - consumption) * 20, output.FireInfusions, 1e-9)
		-- an additional infusion of the same type doubles the gain, a different one adds half of the others' remnants;
		-- Cold remnants become Fire remnants: fire (0.5 + 0.1) x 2 = 1.2, cold 0 x 2 + 0.6 / 2 = 0.3 (x 20 s, capped at 3)
		output = setup("When collecting an Elemental Infusion, gain an additional Elemental Infusion of the same type\nWhen collecting an Elemental Infusion, gain another different Elemental Infusion\nCreate Fire Infusion Remnants instead of Cold")
		assert.are.near(1.2, output.FireInfusionGeneration, 1e-9)
		assert.are.near(0.3, output.ColdInfusionGeneration, 1e-9)
		assert.are.near(0.3, output.LightningInfusionGeneration, 1e-9)
		assert.are.equals(3, output.ColdInfusions)
		-- a count in the configuration wins over the estimate; the share is still estimated
		output = setup("", { multiplierFireInfusion = 2 })
		assert.are.equals(2, output.FireInfusions)
		assert.are.near(0.5 / speed * 100, output.FireInfusedShare, 1e-9)
	end)

	it("estimates Remnants from Siphon Elements' chance on shocking a non-Shocked target", function()
		local output = withSkill("Spark 20/0  1", "", { useApproximations = true })
		build.skillsTab:PasteSocketGroup("Siphon Elements 20/0  1")
		output = setup("")
		local crit = output.CritChance / 100
		local shocks = (output.ShockChanceOnHit * (1 - crit) + output.ShockChanceOnCrit * crit) / 100 * output.Speed
		-- one Remnant chance per shock of an unshocked target: shocks / (1 + shocks x shock duration), 5% of them
		assert.is_true(shocks > 0)
		assert.are.near(0.05 * shocks / (1 + shocks * output.ShockDuration), output.LightningInfusionGeneration, 1e-12)
		assert.are.near(1, calcLib.approxRateWhileUnaffected(2, 0.5), 1e-12)
	end)
end)
