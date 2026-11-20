-- Path of Building
--
-- Module: Calc Triggers
-- Performs trigger rate calculations
--

---@class Calcs
local calcs = require("Modules.CalcBase")

local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local m_min = math.min
local m_max = math.max
local m_ceil = math.ceil
local m_floor = math.floor
local m_modf = math.modf
local s_format = string.format
local m_huge = math.huge
local bor = OR64 -- bit.bor
local band = AND64 -- bit.band

-- Add trigger-based damage modifiers
local function addTriggerIncMoreMods(activeSkill, sourceSkill)
	for _, value in ipairs(activeSkill.skillModList:Tabulate("INC", sourceSkill.skillCfg, "TriggeredDamage")) do
		activeSkill.skillModList:NewMod("Damage", "INC", value.mod.value, value.mod.source, value.mod.flags, value.mod.keywordFlags, unpack(value.mod))
	end
	for _, value in ipairs(activeSkill.skillModList:Tabulate("MORE", sourceSkill.skillCfg, "TriggeredDamage")) do
		activeSkill.skillModList:NewMod("Damage", "MORE", value.mod.value, value.mod.source, value.mod.flags, value.mod.keywordFlags, unpack(value.mod))
	end
end

local function slotMatch(env, skill)
	local fromItem = (env.player.mainSkill.activeEffect.grantedEffect.fromItem or skill.activeEffect.grantedEffect.fromItem)
	fromItem = fromItem or (env.player.mainSkill.activeEffect.srcInstance and env.player.mainSkill.activeEffect.srcInstance.fromItem) or (skill.activeEffect.srcInstance and skill.activeEffect.srcInstance.fromItem)
	local match1 = fromItem and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot
	local match2 = (not env.player.mainSkill.activeEffect.grantedEffect.fromItem) and skill.socketGroup == env.player.mainSkill.socketGroup
	return (match1 or match2)
end

function isTriggered(skill)
	return skill.skillData.triggeredByUnique or skill.skillData.triggered or skill.skillTypes[SkillType.InbuiltTrigger] or skill.skillTypes[SkillType.Triggered] or skill.activeEffect.grantedEffect.triggered or (skill.activeEffect.srcInstance and skill.activeEffect.srcInstance.triggered)
end

local function processAddedCastTime(skill, breakdown)
	if skill.skillModList:Flag(skill.skillCfg, "SpellCastTimeAddedToCooldownIfTriggered") then
		local baseCastTime = skill.skillData.castTimeOverride or skill.activeEffect.grantedEffect.castTime or 1
		local inc = skill.skillModList:Sum("INC", skill.skillCfg, "Speed")
		local more = skill.skillModList:More(skill.skillCfg, "Speed")
		local csi = round((1 + inc/100) * more, 2)
		local addsCastTime = baseCastTime / csi
		skill.skillFlags.addsCastTime = true
		if breakdown then
			breakdown.AddedCastTime = {
				s_format("%.2f ^8(base cast time of %s)", baseCastTime, skill.activeEffect.grantedEffect.name),
				s_format("%.2f ^8(increased/reduced)", 1 + inc/100),
				s_format("%.2f ^8(more/less)", more),
				s_format("= %.2f ^8cast time", addsCastTime)
			}
		end
		return addsCastTime, csi
	end
end

local function packageSkillDataForSimulation(skill, env)
	return { uuid = cacheSkillUUID(skill, env), cd = skill.skillData.cooldown, cdOverride = skill.skillModList:Override(skill.skillCfg, "CooldownRecovery"), addsCastTime = processAddedCastTime(skill), icdr = calcLib.mod(skill.skillModList, skill.skillCfg, "CooldownRecovery"), addedCooldown = skill.skillModList:Sum("BASE", skill.skillCfg, "CooldownRecovery")}
end

local function defaultComparer(env, uuid, source, triggerRate)
	local cachedSpeed = GlobalCache.cachedData[env.mode][uuid].HitSpeed or GlobalCache.cachedData[env.mode][uuid].Speed
	return (not source and cachedSpeed) or (cachedSpeed and cachedSpeed > (triggerRate or 0))
end

-- Identify the trigger action skill for trigger conditions, take highest Attack Per Second
local function findTriggerSkill(env, skill, source, triggerRate, comparer)
	local comparer = comparer or defaultComparer

	local uuid = cacheSkillUUID(skill, env)
	if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
		calcs.buildActiveSkill(env, env.mode, skill, uuid)
	end

	if GlobalCache.cachedData[env.mode][uuid] and comparer(env, uuid, source, triggerRate) and (skill.skillFlags and not skill.skillFlags.disable) and (skill.skillCfg and not skill.skillCfg.skillCond["usedByMirage"]) and not skill.skillTypes[SkillType.OtherThingUsesSkill] then
		return skill, GlobalCache.cachedData[env.mode][uuid].HitSpeed or GlobalCache.cachedData[env.mode][uuid].Speed, uuid
	end
	return source, triggerRate, source and cacheSkillUUID(source, env)
end

-- Calculate the impact other skills and source rate to trigger cooldown alignment have on the trigger rate
-- for more details regarding the implementation see comments of #4599 and #5428
function calcMultiSpellRotationImpact(env, skillRotation, sourceRate, triggerCD, chance, actor)
	local rotationIndex = 1
	local next_trigger = 0
	local triggerIncrement = 1 / sourceRate
	local SIM_TIME = triggerIncrement * 1000 -- Simulate 1000 attacks
	local chance = chance or 100
	local skillCount = #skillRotation
	local actor = actor or env.player

	for _, skill in ipairs(skillRotation) do
		skill.cd = m_max(skill.cdOverride or ( ((skill.cd or 0) + (skill.addedCooldown or 0)) / (skill.icdr or 1)), ( (triggerCD or 0) + (skill.addsCastTime or 0) ) / (skill.icdr or 1))
		skill.next_trig = 0
		skill.count = 0
	end

	while next_trigger < SIM_TIME do
		local currentIndex = rotationIndex
		repeat
			if skillRotation[currentIndex].next_trig <= next_trigger then -- Skill at current index off cooldown, Trigger it.
				skillRotation[currentIndex].count = skillRotation[currentIndex].count + 1
				-- Cooldown starts at the beginning of current tick and ends at the next tick after cooldown expiration
				skillRotation[currentIndex].next_trig = ceil_b(floor_b(next_trigger, data.misc.ServerTickTime) + skillRotation[currentIndex].cd, data.misc.ServerTickTime)
				break
			end
			currentIndex = (currentIndex % skillCount) + 1 -- Current skill on cooldown, try the next one.
		until(currentIndex == rotationIndex) -- All skills checked, trigger wasted
		rotationIndex = (rotationIndex % skillCount) + 1 -- Move on to the next skill in rotation
		next_trigger = next_trigger + triggerIncrement
	end

	local trigRateTable = { simTime = SIM_TIME, rates = {}, }
	local mainRate = 0
	for _, sd in ipairs(skillRotation) do
		-- Account for trigger chance. Adds the expected value of a geometric distribution where p = chance multiplied by triggerIncrement
		-- This allows for O(1) estimation of trigger chance impact on trigger rate as number of triggers approaches infinity
		-- Credit to Logik and Quickstick. More info in prs linked here: https://github.com/PathOfBuildingCommunity/PathOfBuilding/pull/7244 and on discord.
		t_insert(trigRateTable.rates, { name = sd.uuid, rate = 1 / (SIM_TIME / sd.count + (triggerIncrement / chance * 100) - triggerIncrement) })
		if cacheSkillUUID(actor.mainSkill, env) == sd.uuid then
			mainRate = trigRateTable.rates[#trigRateTable.rates].rate
		end
	end

	return mainRate, trigRateTable
end

local function helmetFocusHandler(env)
	if not env.player.mainSkill.skillFlags.minion and not env.player.mainSkill.skillFlags.disable and env.player.mainSkill.triggeredBy then
		local triggerName = "Focus"
		env.player.mainSkill.skillData.triggered = true
		---@class Output
		local output = env.player.output
		---@class Breakdown
		local breakdown = env.player.breakdown
		local triggerCD = env.player.mainSkill.triggeredBy.grantedEffect.levels[env.player.mainSkill.triggeredBy.level].cooldown
		local triggeredCD = env.player.mainSkill.skillData.cooldown

		local icdrFocus = calcLib.mod(env.player.mainSkill.skillModList, env.player.mainSkill.skillCfg, "FocusCooldownRecovery")
		local icdrSkill = calcLib.mod(env.player.mainSkill.skillModList, env.player.mainSkill.skillCfg, "CooldownRecovery")

		-- Skills trigger only on activation
		-- Next possible activation will be duration + cooldown
		-- cooldown is in milliseconds
		local skillFocus = env.data.skills["Focus"]
		local focusDuration = (skillFocus.constantStats[1][2] / 1000)
		local focusCD = (skillFocus.levels[1].cooldown / icdrFocus)
		local focusTotalCD = focusDuration + focusCD

		-- skill cooldown should still apply to focus triggers
		local modActionCooldown = m_max( triggeredCD or 0, (triggerCD or 0) / icdrSkill )
		local rateCapAdjusted = m_ceil(modActionCooldown * data.misc.ServerTickRate) / data.misc.ServerTickRate
		local triggerRate = m_huge
		if rateCapAdjusted ~= 0 then
			triggerRate = 1 / rateCapAdjusted
		end

		output.TriggerRateCap = triggerRate
		output.SkillTriggerRate = 1 / focusTotalCD

		if breakdown then
			if triggeredCD then
				breakdown.TriggerRateCap = {
					s_format("%.2f ^8(base cooldown of triggered skill)", triggeredCD),
					s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrSkill),
					s_format("= %.4f ^8(final cooldown of triggered skill)", triggeredCD / icdrSkill),
					"",
					s_format("%.2f ^8(base cooldown of trigger)", triggerCD),
					s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrSkill),
					s_format("= %.4f ^8(final cooldown of trigger)", triggerCD / icdrSkill),
					"",
					s_format("%.3f ^8(biggest of trigger cooldown and triggered skill cooldown)", modActionCooldown),
					"",
					(env.player.mainSkill.skillData.ignoresTickRate and "") or s_format("%.3f ^8(adjusted for server tick rate)", rateCapAdjusted),
					"",
					"Trigger rate:",
					s_format("1 / %.3f", rateCapAdjusted),
					s_format("= %.2f ^8per second", triggerRate),
				}
			else
				breakdown.TriggerRateCap = {
					"Triggered skill has no base cooldown",
					"",
					s_format("%.2f ^8(base cooldown of trigger)", triggerCD),
					s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrSkill),
					s_format("= %.4f ^8(final cooldown of trigger)", triggerCD / icdrSkill),
					"",
					(env.player.mainSkill.skillData.ignoresTickRate and "") or s_format("%.3f ^8(adjusted for server tick rate)", rateCapAdjusted),
					"",
					"Trigger rate:",
					s_format("1 / %.3f", rateCapAdjusted),
					s_format("= %.3f ^8per second", triggerRate),
				}
			end
			breakdown.SkillTriggerRate = {
				s_format("%.2f ^8(focus base cooldown)", skillFocus.levels[1].cooldown),
				s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdrFocus),
				s_format("+ %.2f ^8(skills are only triggered on activation thus we add focus duration)", focusDuration),
				s_format("= %.2f ^8(effective skill cooldown for trigger purposes)", focusTotalCD),
				"",
				s_format("%.3f casts per second ^8(Assuming player uses focus exactly when its cooldown of %.2fs expires)", 1 / focusTotalCD, focusTotalCD)
			}
		end

		-- Account for Trigger-related INC/MORE modifiers
		addTriggerIncMoreMods(env.player.mainSkill, env.player.mainSkill)
		env.player.mainSkill.infoMessage = "Assuming perfect focus Re-Use"
		env.player.mainSkill.infoTrigger = triggerName
		env.player.mainSkill.skillData.triggerRate = output.SkillTriggerRate
		env.player.mainSkill.skillFlags.globalTrigger = true
	end
end

local function CWCHandler(env)
	if not env.player.mainSkill.skillFlags.minion and not env.player.mainSkill.skillFlags.disable then
		local triggeredSkills = {}
		local trigRate = 0
		local source = nil
		local triggerName = "Cast While Channeling"
		local output = env.player.output
		---@class Breakdown
		local breakdown = env.player.breakdown
		for _, skill in ipairs(env.player.activeSkillList) do
			local match1 = env.player.mainSkill.activeEffect.grantedEffect.fromItem and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot
			local match2 = (not env.player.mainSkill.activeEffect.grantedEffect.fromItem) and skill.socketGroup == env.player.mainSkill.socketGroup
			if env.player.mainSkill.triggeredBy.gemData and calcLib.canGrantedEffectSupportActiveSkill(env.player.mainSkill.triggeredBy.gemData.grantedEffect, skill) and skill ~= env.player.mainSkill and (match1 or match2) and not isTriggered(skill) then
				source, trigRate = findTriggerSkill(env, skill, source, trigRate)
			end
			if skill.skillData.triggeredWhileChannelling and (match1 or match2) then
				t_insert(triggeredSkills, packageSkillDataForSimulation(skill, env))
			end
		end
		if not source or #triggeredSkills < 1 then
			env.player.mainSkill.skillData.triggered = nil
			env.player.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
			env.player.mainSkill.infoMessage = s_format("No %s Triggering Skill Found", triggerName)
			env.player.mainSkill.infoTrigger = ""
		else
			local triggeredName = env.player.mainSkill.activeEffect.grantedEffect.name or "Triggered"

			output.addsCastTime = processAddedCastTime(env.player.mainSkill, breakdown)

			local icdr = calcLib.mod(env.player.mainSkill.skillModList, env.player.mainSkill.skillCfg, "CooldownRecovery") or 1
			local adjTriggerInterval = m_ceil(source.skillData.triggerTime * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local triggerRateOfTrigger = 1/adjTriggerInterval
			local triggeredCD = env.player.mainSkill.skillData.cooldown
			local cooldownOverride = env.player.mainSkill.skillModList:Override(env.player.mainSkill.skillCfg, "CooldownRecovery")

			if cooldownOverride then
				env.player.mainSkill.skillFlags.hasOverride = true
			end

			local triggeredTotalCooldown = cooldownOverride or m_max(triggeredCD or 0, output.addsCastTime or 0) / icdr
			local triggeredCDAdjusted = m_ceil(triggeredTotalCooldown * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local effCDTriggeredSkill = m_ceil(triggeredCDAdjusted * triggerRateOfTrigger) / triggerRateOfTrigger

			local simBreakdown = nil
			output.TriggerRateCap = m_min(1 / effCDTriggeredSkill, triggerRateOfTrigger)
			output.SkillTriggerRate, simBreakdown = calcMultiSpellRotationImpact(env, triggeredSkills, triggerRateOfTrigger, 0)

			if breakdown then
				if triggeredCD or cooldownOverride then
					breakdown.TriggerRateCap = {
						s_format("Cast While Channeling triggers %s every %.2fs while channeling %s ", triggeredName, source.skillData.triggerTime, source.activeEffect.grantedEffect.name),
						s_format("%.3f ^8(adjusted for server tick rate)", adjTriggerInterval),
						"",
						s_format("%.2f ^8(base cooldown of triggered skill)", triggeredCD),
						s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr),
						s_format("= %.4f ^8(final cooldown of triggered skill)", triggeredCD / icdr),
						"",
					}
					if cooldownOverride ~= nil then
						breakdown.TriggerRateCap[4] = s_format("%.2f ^8(hard override of cooldown of %s)", cooldownOverride, triggeredName)
						t_remove(breakdown.TriggerRateCap, 5)
						t_remove(breakdown.TriggerRateCap, 5)
					end
				else
					breakdown.TriggerRateCap = {
						s_format("Cast While Channeling triggers %s every %.2fs while channeling %s ", triggeredName, source.skillData.triggerTime, source.activeEffect.grantedEffect.name),
						s_format("%.3f ^8(adjusted for server tick rate)", adjTriggerInterval),
						"",
						triggeredName .. " has no base cooldown or cooldown override",
						"",
					}
				end

				local function extraIncreaseNeeded(affectedCD)
					if not cooldownOverride then
						local nextBreakpoint = effCDTriggeredSkill - adjTriggerInterval
						local timeOverBreakpoint = triggeredTotalCooldown - nextBreakpoint
						local alreadyReducedTime = triggeredTotalCooldown * icdr - triggeredTotalCooldown
						if timeOverBreakpoint < affectedCD then
							local divNeeded = affectedCD / (affectedCD - timeOverBreakpoint - alreadyReducedTime)
							local incTotal = m_ceil(( divNeeded - 1 ) * 100)
							return incTotal - (icdr - 1) * 100
						end
					end
				end

				if output.addsCastTime then
					t_insert(breakdown.TriggerRateCap, "Cast While Channeling had no base cooldown")
					t_insert(breakdown.TriggerRateCap, s_format("+ %.2f ^8(%s adds cast time as cooldown to trigger)", output.addsCastTime, triggeredName))
					t_insert(breakdown.TriggerRateCap, s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr))
					t_insert(breakdown.TriggerRateCap, s_format("= %.4f ^8(final cooldown of triggered skill)", output.addsCastTime / icdr))
					t_insert(breakdown.TriggerRateCap, "")
					t_insert(breakdown.TriggerRateCap, s_format("%.3f ^8(adjusted for server tick rate)", triggeredCDAdjusted))
					t_insert(breakdown.TriggerRateCap, "")

					local extraCSINeeded = extraIncreaseNeeded(output.addsCastTime)
					local extraICDRNeeded = extraIncreaseNeeded(triggeredTotalCooldown*icdr)
					if extraICDRNeeded then
						t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICDR of %d%% would reach next breakpoint)", extraICDRNeeded))
					end
					if extraCSINeeded then
						t_insert(breakdown.TriggerRateCap, s_format("^8(extra Cast Rate Increase of %d%% would reach next breakpoint)", extraCSINeeded))
						t_insert(breakdown.TriggerRateCap,"")
					end
				else
					local extraICDRNeeded = extraIncreaseNeeded(triggeredTotalCooldown*icdr)
					if extraICDRNeeded then
						t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICDR of %d%% would reach next breakpoint)", extraICDRNeeded))
						t_insert(breakdown.TriggerRateCap,"")
					end
				end

				t_insert(breakdown.TriggerRateCap, "Trigger rate:")
				t_insert(breakdown.TriggerRateCap, s_format("1 / %.3f ^8(trigger rate adjusted for triggering interval)", 1 / output.TriggerRateCap))
				t_insert(breakdown.TriggerRateCap, s_format("= %.2f ^8 %s casts per second", output.TriggerRateCap, triggeredName))

				if #triggeredSkills > 1 then
					breakdown.SkillTriggerRate = {
						s_format("%.2f ^8(%s triggers per second)", triggerRateOfTrigger, triggerName),
						s_format("/ %.2f ^8(Estimated impact of linked spells)", (triggerRateOfTrigger / output.SkillTriggerRate) or 1),
						s_format("= %.2f ^8%s casts per second", output.SkillTriggerRate, triggeredName),
					}

					if simBreakdown.extraSimInfo then
						t_insert(breakdown.SkillTriggerRate, "")
						t_insert(breakdown.SkillTriggerRate, simBreakdown.extraSimInfo)
					end
					breakdown.SimData = {
						rowList = { },
						colList = {
							{ label = "Rate", key = "rate" },
							{ label = "Skill Name", key = "skillName" },
							{ label = "Slot Name", key = "slotName" },
							{ label = "Gem Index", key = "gemIndex" },
						},
					}
					for _, rateData in ipairs(simBreakdown.rates) do
						local t = { }
						for str in string.gmatch(rateData.name, "([^_]+)") do
							t_insert(t, str)
						end

						local row = {
							rate = round(rateData.rate,2),
							skillName = t[1],
							slotName = t[2],
							gemIndex = t[3],
						}
						t_insert(breakdown.SimData.rowList, row)
					end
				end
			end

			-- Account for Trigger-related INC/MORE modifiers
			addTriggerIncMoreMods(env.player.mainSkill, env.player.mainSkill)
			env.player.output.ChannelTimeToTrigger = source.skillData.triggerTime
			env.player.mainSkill.skillData.triggered = true
			env.player.mainSkill.skillFlags.globalTrigger = true
			env.player.mainSkill.skillData.triggerRate = output.SkillTriggerRate
			env.player.mainSkill.skillData.triggerSourceUUID = cacheSkillUUID(source, env)
			env.player.mainSkill.infoMessage = triggerName .."'s Trigger: ".. source.activeEffect.grantedEffect.name
			env.player.infoTrigger = env.player.mainSkill.infoTrigger or triggerName
		end
	end
end

local function defaultTriggerHandler(env, config)
	local actor = config.actor
	local output = config.actor.output
	---@class Breakdown
	local breakdown = config.actor.breakdown
	local source = config.source
	local triggeredSkills = config.triggeredSkills or {}
	local trigRate = config.trigRate
	local uuid

	-- Find trigger skill and triggered skills
	if config.triggeredSkillCond or config.triggerSkillCond then
		for _, skill in ipairs(env.player.activeSkillList) do
			if config.triggerSkillCond and config.triggerSkillCond(env, skill) and (not isTriggered(skill) or actor.mainSkill.skillFlags.globalTrigger or config.allowTriggered) and skill ~= actor.mainSkill then
				source, trigRate, uuid = findTriggerSkill(env, skill, source, trigRate, config.comparer)
			end
			if config.triggeredSkillCond and config.triggeredSkillCond(env,skill) then
				t_insert(triggeredSkills, packageSkillDataForSimulation(skill, env))
			end
		end
	end
	if #triggeredSkills > 0 or not config.triggeredSkillCond then
		if not source and not (actor.mainSkill.skillFlags.globalTrigger and config.triggeredSkillCond) then
			actor.mainSkill.skillData.triggered = nil
			actor.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
			actor.mainSkill.infoMessage = s_format("No %s Triggering Skill Found", config.triggerName)
			actor.mainSkill.infoTrigger = ""
		else
			actor.mainSkill.skillData.triggered = true

			-- Account for Arcanist Brand using activation frequency
			if breakdown and actor.mainSkill.skillData.triggeredByBrand then
				breakdown.EffectiveSourceRate = {
					s_format("%.2f ^8(base activation cooldown of %s)", actor.mainSkill.triggeredBy.mainSkill.skillData.repeatFrequency, config.triggerName),
					s_format("* %.2f ^8(more activation frequency)", actor.mainSkill.triggeredBy.activationFreqMore),
					s_format("* %.2f ^8(increased activation frequency)", actor.mainSkill.triggeredBy.activationFreqInc),
					s_format("= %.2f ^8(activation rate of %s)", trigRate, actor.mainSkill.triggeredBy.mainSkill.activeEffect.grantedEffect.name)
				}
			elseif breakdown then
				breakdown.EffectiveSourceRate = config.sourceRateBreakdown or {}
				if trigRate and source and not config.sourceRateBreakdown then
					if config.assumingEveryHitKills then
						t_insert(breakdown.EffectiveSourceRate, "Assuming every attack kills")
					end
					t_insert(breakdown.EffectiveSourceRate, s_format("%.2f ^8(%s %s)", trigRate, config.sourceName or source.activeEffect.grantedEffect.name, config.useCastRate and "cast rate" or "attack rate"))
				end
			end

			-- Dual wield triggers
			if trigRate and source and env.player.weaponData1.type and env.player.weaponData2.type and not source.skillData.combinesHitsWhenDualWielding and (source.skillTypes[SkillType.Melee] or source.skillTypes[SkillType.Attack]) and actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.support and actor.mainSkill.triggeredBy.grantedEffect.fromItem then
				trigRate = trigRate / 2
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, 2, s_format("/ 2 ^8(due to dual wielding)"))
				end
			end

			actor.mainSkill.skillData.ignoresTickRate = actor.mainSkill.skillData.ignoresTickRate or (actor.mainSkill.skillData.storedUses and actor.mainSkill.skillData.storedUses > 1)

			--Account for source unleash
			if source and GlobalCache.cachedData[env.mode][uuid] and source.skillModList:Flag(nil, "HasSeals") and source.skillModList:Flag(nil, "DamageSeal") then
				local unleashDpsMult = GlobalCache.cachedData[env.mode][uuid].ActiveSkill.skillData.dpsMultiplier or 1
				trigRate = trigRate * unleashDpsMult
				actor.mainSkill.skillFlags.HasSeals = true
				actor.mainSkill.skillData.ignoresTickRate = true
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("x %.2f ^8(multiplier from Unleash)", unleashDpsMult))
				end
			end

			--Account for skills that can hit multiple times per use
			if source and GlobalCache.cachedData[env.mode][uuid] and source.skillPartName and source.skillPartName:match("(.*)All(.*)Projectiles(.*)") and source.skillFlags.projectile then
				local multiHitDpsMult = GlobalCache.cachedData[env.mode][uuid].Env.player.output.ProjectileCount or 1
				trigRate = trigRate * multiHitDpsMult
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("x %.2f ^8(%d projectiles hit)", multiHitDpsMult, multiHitDpsMult))
				end
			end

			--Special handling for Kitava's Thirst
			-- Repeated hits do not consume mana and do not trigger Kitava's thirst
			if actor.mainSkill.skillData.triggeredByManaSpent then
				local repeats = 1 + source.skillModList:Sum("BASE", nil, "RepeatCount")
				trigRate = trigRate / repeats
				if breakdown and repeats > 1 then
					t_insert(breakdown.EffectiveSourceRate, s_format("/%d ^8(repeated attacks/casts do not count as they don't use mana)", repeats))
				end
			end

			-- Battlemage's Cry uptime
			if actor.mainSkill.skillData.triggeredByBattleMageCry and GlobalCache.cachedData[env.mode][uuid] and source and source.skillTypes[SkillType.Melee] then
				local battleMageExertsCount = GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleCryExertsCount
				local battleMageDuration = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleMageCryDuration, data.misc.ServerTickTime)
				local battleMageCastTime = GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleMageCryCastTime
				local battleMageCooldown = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattleMageCryCooldown, data.misc.ServerTickTime)

				-- Cap the number of hits that happen during the duration
				local battleMageHits = m_max(m_min(trigRate * battleMageDuration, battleMageExertsCount), 0)

				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("^8(min(%.2f * %.2f, %d) = %.2f average number of exerted attacks capped by exerted count)", trigRate, battleMageDuration, battleMageExertsCount, battleMageHits))
					t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f / (%.2f + %.2f) ^8(the calculated number of exerted attacks happens every cooldown + duration)", battleMageHits, battleMageCastTime, battleMageCooldown))
				end

				-- The hits happen every battlemage cooldown + duration
				trigRate = battleMageHits / (battleMageCastTime + battleMageCooldown)
			end

			-- Infernal Cry uptime
			if actor.mainSkill.activeEffect.grantedEffect.name == "Combust" and GlobalCache.cachedData[env.mode][uuid] and source and source.skillTypes[SkillType.Melee] then
				local infernalCryExertsCount = GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalEmpoweredCount
				local infernalCryDuration = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalCryDuration, data.misc.ServerTickTime)
				local infernalCryCastTime = GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalCryCastTime
				local infernalCryCooldown = ceil_b(GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalCryCooldown, data.misc.ServerTickTime)

				-- Cap the number of hits that happen during the duration
				local infernalCryHits = m_max(m_min(trigRate * infernalCryDuration, infernalCryExertsCount), 0)

				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("^8(min(%.2f * %.2f, %d) = %.2f average number of exerted attacks capped by exerted count)", trigRate, infernalCryDuration, infernalCryExertsCount, infernalCryHits))
					t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f / (%.2f + %.2f) ^8(the calculated number of exerted attacks happens every cooldown + duration)", infernalCryHits, infernalCryCastTime, infernalCryCooldown))
				end

				-- The hits happen every Infernal Cry cooldown + duration
				trigRate = infernalCryHits / (infernalCryCastTime + infernalCryCooldown)
			end

			-- Handling for mana spending rate for Manaforged Arrows Support
			if actor.mainSkill.skillData.triggeredByManaforged and trigRate > 0 then
				local triggeredUUID = cacheSkillUUID(actor.mainSkill, env)
				if not GlobalCache.cachedData[env.mode][triggeredUUID] then
					calcs.buildActiveSkill(env, env.mode, actor.mainSkill, triggeredUUID, {[triggeredUUID] = true})
				end
				local triggeredManaCost = GlobalCache.cachedData[env.mode][triggeredUUID].Env.player.output.ManaCostRaw or 0
				if triggeredManaCost > 0 then
					local manaSpentThreshold = triggeredManaCost * actor.mainSkill.skillData.ManaForgedArrowsPercentThreshold
					local sourceManaCost = GlobalCache.cachedData[env.mode][uuid].Env.player.output.ManaCostRaw or 0
					if sourceManaCost > 0 then
						if breakdown then
							breakdown.EffectiveSourceRate = {
								s_format("%.4f ^8(Mana cost of trigger source)", sourceManaCost),
								s_format(""),
								s_format("%.4f ^8(Mana Cost of triggered)", triggeredManaCost),
								s_format("%.2f ^8(Manaforged threshold multiplier)", actor.mainSkill.skillData.ManaForgedArrowsPercentThreshold),
								s_format("= %.4f ^8(Manaforged trigger threshold)", manaSpentThreshold),
								s_format(""),
								s_format("%.4f ^8(Manaforged trigger threshold)", manaSpentThreshold),
								s_format("/ %.4f ^8(Mana cost of trigger source)", sourceManaCost),
								s_format("= %.2f ^8(Skill usages required)", manaSpentThreshold / sourceManaCost),
								s_format(""),
								breakdown.EffectiveSourceRate[1],
								s_format("/ ceil(%.2f) ^8(%d Skill usages required)", manaSpentThreshold / sourceManaCost, m_ceil(manaSpentThreshold / sourceManaCost)),
							}
						end
						trigRate = trigRate / m_ceil(manaSpentThreshold / sourceManaCost)
					else
						if breakdown then
							t_insert(breakdown.EffectiveSourceRate, s_format("Source skill has no mana cost", output.EffectiveSourceRate))
						end
						trigRate = 0
					end
				end
			end

			local icdr = calcLib.mod(actor.mainSkill.skillModList, actor.mainSkill.skillCfg, "CooldownRecovery") or 1
			local addedCooldown = actor.mainSkill.skillModList:Sum("BASE", actor.mainSkill.skillCfg, "CooldownRecovery")
			addedCooldown = addedCooldown ~= 0 and addedCooldown or nil
			local cooldownOverride = actor.mainSkill.skillModList:Override(actor.mainSkill.skillCfg, "CooldownRecovery")
			local triggerCD = actor.mainSkill.triggeredBy and env.player.mainSkill.triggeredBy.grantedEffect.levels[env.player.mainSkill.triggeredBy.level].cooldown
			triggerCD = triggerCD or source.triggeredBy and source.triggeredBy.grantedEffect.levels[source.triggeredBy.level].cooldown
			local triggeredCD = actor.mainSkill.skillData.cooldown

			if actor.mainSkill.skillData.triggeredByBrand then
				triggerCD = actor.mainSkill.triggeredBy.mainSkill.skillData.repeatFrequency / actor.mainSkill.triggeredBy.activationFreqMore / actor.mainSkill.triggeredBy.activationFreqInc
				triggerCD = triggerCD * icdr -- cancels out division by icdr lower, brand activation rate is not affected by icdr
			end

			local triggeredName = (actor.mainSkill.activeEffect.grantedEffect and actor ~= env.minion and actor.mainSkill.activeEffect.grantedEffect.name) or "Triggered skill"
			local csi
			output.addsCastTime, csi = processAddedCastTime(env.player.mainSkill, breakdown)

			local triggeredCDAdjusted = ( (triggeredCD or 0) + (addedCooldown or 0) ) / icdr
			local triggerCDAdjusted = ( (triggerCD or 0) + (output.addsCastTime or 0) ) / icdr
			local triggeredCDTickRounded = actor.mainSkill.skillData and actor.mainSkill.skillData.ignoresTickRate and triggeredCDAdjusted or m_ceil(triggeredCDAdjusted * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local triggerCDTickRounded = actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.ignoresTickRate and triggerCDAdjusted or m_ceil(triggerCDAdjusted * data.misc.ServerTickRate) / data.misc.ServerTickRate
			local actionCooldown = cooldownOverride or m_max((triggerCD or 0) + (output.addsCastTime or 0), (triggeredCD or 0) + (addedCooldown or 0))
			local actionCooldownAdjusted = cooldownOverride or m_max(triggerCDAdjusted, triggeredCDAdjusted)
			local actionCooldownTickRounded = cooldownOverride and (m_ceil(cooldownOverride * data.misc.ServerTickRate) / data.misc.ServerTickRate) or m_max(triggerCDTickRounded, triggeredCDTickRounded)

			output.TriggerRateCap = source == actor.mainSkill and actor.mainSkill.skillData.triggerRateCapOverride or m_huge
			if actionCooldownTickRounded ~= 0 then
				output.TriggerRateCap = 1 / actionCooldownTickRounded
			end
			if config.triggerName == "Doom Blast" and env.build.configTab.input["doomBlastSource"] == "expiration" then
				local expirationRate = 1 / GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration
				if breakdown and breakdown.EffectiveSourceRate then
						breakdown.EffectiveSourceRate[1] = s_format("1 / %.2f ^8(source curse duration)", GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration)
				end
				if expirationRate > trigRate then
					env.player.modDB:NewMod("UsesCurseOverlaps", "FLAG", true, "Config")
					if breakdown and breakdown.EffectiveSourceRate then
						t_insert(breakdown.EffectiveSourceRate, 2, s_format("max(%.2f, %.2f) ^8(If a curse expires instantly curse expiration is equivalent to curse replacement)", expirationRate, trigRate))
						t_insert(breakdown.EffectiveSourceRate, 2, s_format("%.2f ^8(%s cast rate)", trigRate, source.activeEffect.grantedEffect.name))
					end
				else
					trigRate = expirationRate
				end
			elseif config.triggerName == "Doom Blast" and env.build.configTab.input["doomBlastSource"] == "hexblast" then
				local hexBlast, rate
				for _, skill in ipairs(env.player.activeSkillList) do
					if skill.activeEffect.grantedEffect.name == "Hexblast" and not isTriggered(skill) and skill ~= actor.mainSkill then
						hexBlast, rate, uuid = findTriggerSkill(env, skill, hexBlast, rate)
					end
				end
				if hexBlast then
					if breakdown then
						breakdown.EffectiveSourceRate[1] = s_format("1 / (%.2f + %.2f) ^8(sum of triggered curse and hexblast cast time)", 1/trigRate, 1/rate)
					end
					trigRate = 1/ (1/trigRate + 1/rate)
				end
			end

			if breakdown and not breakdown.TriggerRateCap then
				breakdown.TriggerRateCap = {}

				if cooldownOverride then
					t_insert(breakdown.TriggerRateCap, s_format("%.2f ^8(hard override of cooldown of %s)", cooldownOverride, triggeredName))
				elseif triggeredCDAdjusted == 0 then
					t_insert(breakdown.TriggerRateCap, triggeredName .. " has no base cooldown or cooldown override")
				else -- triggeredCDAdjusted ~= 0 triggered skill has some kind of cooldown
					if triggeredCD then
						t_insert(breakdown.TriggerRateCap, s_format("%.2f ^8(base cooldown of triggered skill)", triggeredCD))
					else
						t_insert(breakdown.TriggerRateCap, triggeredName .. " has no base cooldown or cooldown override")
					end
					if addedCooldown then
						t_insert(breakdown.TriggerRateCap, s_format("+ %.2f ^8(flat added cooldown)", addedCooldown))
					end
					t_insert(breakdown.TriggerRateCap, s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr))
					t_insert(breakdown.TriggerRateCap, s_format("= %.4f ^8(final cooldown of triggered skill)", triggeredCDAdjusted))
				end

				t_insert(breakdown.TriggerRateCap, "")

				if actor ~= env.minion then -- Minion triggers have internal triggers
					if triggerCDAdjusted == 0 then
						t_insert(breakdown.TriggerRateCap, s_format("Trigger rate based on %s cooldown", triggeredName))
					else -- triggerCDAdjusted ~= 0 trigger has some kind of cooldown
						if triggerCD then
							t_insert(breakdown.TriggerRateCap, s_format("%.2f ^8(base cooldown of %s)", triggerCD, config.triggerName))
						else
							t_insert(breakdown.TriggerRateCap, config.triggerName .. " has no base cooldown")
						end
						if output.addsCastTime then
							t_insert(breakdown.TriggerRateCap, s_format("+ %.2f ^8(this skill adds cast time to cooldown when triggered)", output.addsCastTime))
						end
						t_insert(breakdown.TriggerRateCap, s_format("/ %.2f ^8(increased/reduced cooldown recovery)", icdr))
						t_insert(breakdown.TriggerRateCap, s_format("= %.4f ^8(final cooldown of trigger)", triggerCDAdjusted))
					end
				end

				t_insert(breakdown.TriggerRateCap, "")

				if triggeredCDAdjusted ~= 0 and triggerCDAdjusted ~= 0 then
					t_insert(breakdown.TriggerRateCap, s_format("%.3f ^8(biggest of trigger cooldown and triggered skill cooldown)", actionCooldownAdjusted))
				end

				local displayCooldownRounding = (actor.mainSkill.skillData and not actor.mainSkill.skillData.ignoresTickRate and triggeredCDAdjusted ~= 0) or (actor.mainSkill.triggeredBy and not actor.mainSkill.triggeredBy.ignoresTickRate and triggerCDAdjusted ~= 0)
				if displayCooldownRounding then
					t_insert(breakdown.TriggerRateCap, s_format("%.3f ^8(adjusted for server tick rate)", actionCooldownTickRounded))
				end

				local function extraIncreaseNeeded(affectedCD)
					if not cooldownOverride then
						local nextBreakpoint = actionCooldownTickRounded - data.misc.ServerTickTime
						local timeOverBreakpoint = actionCooldownAdjusted - nextBreakpoint
						local alreadyReducedTime = actionCooldown - actionCooldownAdjusted
						if timeOverBreakpoint < affectedCD then
							local divNeeded = affectedCD / (affectedCD - timeOverBreakpoint - alreadyReducedTime)
							local incTotal = m_ceil(( divNeeded - 1 ) * 100)
							return incTotal - (icdr - 1) * 100
						end
					end
				end

				local extraICDRNeeded = extraIncreaseNeeded(actionCooldown)
				if extraICDRNeeded then
					t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICDR of %d%% would reach next breakpoint)", extraICDRNeeded))
				end

				local extraCSIncNeeded = output.addsCastTime and extraIncreaseNeeded(output.addsCastTime)
				if extraCSIncNeeded then
					t_insert(breakdown.TriggerRateCap, s_format("^8(extra ICS  of %d%% would reach next breakpoint)", extraCSIncNeeded))
				end

				t_insert(breakdown.TriggerRateCap, "")

				if not (triggeredCD or triggerCD or cooldownOverride) then
					t_insert(breakdown.TriggerRateCap, "Assuming cast on every kill/attack/hit")
				else
					t_insert(breakdown.TriggerRateCap, "Trigger rate:")
					t_insert(breakdown.TriggerRateCap, s_format("1 / %.3f", actionCooldownTickRounded))
					t_insert(breakdown.TriggerRateCap, s_format("= %.2f ^8per second", output.TriggerRateCap))
				end
			end

			-- (PoE1's Vixen's Entrapment; PoE2's data has no such skill, and Impending Doom's Doom Blast goes through supportTrigger)
			if env.player.mainSkill.activeEffect.grantedEffect.name == "Doom Blast" and env.build.configTab.input["doomBlastSource"] == "vixen" and env.data.skills["SupportUniqueCastCurseOnCurse"] then
				if not env.player.itemList["Gloves"] or env.player.itemList["Gloves"].title ~= "Vixen's Entrapment" then
					output.VixenModeNoVixenGlovesWarn = true
				end

				env.player.modDB:NewMod("UsesCurseOverlaps", "FLAG", true, "Config")
				local vixens = env.data.skills["SupportUniqueCastCurseOnCurse"]
				local vixensCD = vixens and vixens.levels[1].cooldown / icdr
				output.EffectiveSourceRate = calcMultiSpellRotationImpact(env, {{ uuid = cacheSkillUUID(env.player.mainSkill, env), icdr = icdr}}, trigRate, vixensCD)
				output.VixensTooMuchCastSpeedWarn = vixensCD > (1 / trigRate)
				if breakdown then
					t_insert(breakdown.EffectiveSourceRate, s_format("%.2f / %.2f = %.2f ^8(Vixen's trigger cooldown)", vixensCD * icdr, icdr, vixensCD))
					t_insert(breakdown.EffectiveSourceRate, s_format("%.2f ^8(Simulated trigger rate of a curse socketed in Vixen's given ^7%.2f ^8CD and ^7%.2f ^8source rate)", output.EffectiveSourceRate, vixensCD, trigRate))
				end
			elseif trigRate ~= nil and not actor.mainSkill.skillFlags.globalTrigger and not config.ignoreSourceRate then
				output.EffectiveSourceRate = trigRate
			else
				output.EffectiveSourceRate = output.TriggerRateCap
				actor.mainSkill.skillFlags.globalTrigger = true
			end

			if breakdown and not actor.mainSkill.skillData.sourceRateIsFinal then
				t_insert(breakdown.EffectiveSourceRate, s_format("= %.2f ^8(Effective source rate)", output.EffectiveSourceRate))
			end

			local skillName = (source and source.activeEffect.grantedEffect.name) or (actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.name) or actor.mainSkill.activeEffect.grantedEffect.name

			if output.EffectiveSourceRate ~= 0 then
				local triggerChance = 100
				local triggerChanceBreakdown = {}

				--Accuracy and crit chance
				if source and (source.skillTypes[SkillType.Melee] or source.skillTypes[SkillType.Attack]) and GlobalCache.cachedData[env.mode][uuid] and not config.triggerOnUse then

					local sourceHitChance = GlobalCache.cachedData[env.mode][uuid].HitChance or 0
					if sourceHitChance ~= 100 then
						-- Some skills hit with both weapons at the same time. Each weapon rolls accuracy and crit independently
						if source and env.player.weaponData1.type and env.player.weaponData2.type and source.skillData.combinesHitsWhenDualWielding then
							local mainHandHit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.MainHand.HitChance
							local offHandHit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.OffHand.HitChance
							local bothHit = mainHandHit * offHandHit / 100
							local mainHandMiss = (100 - mainHandHit)
							local offHandMiss = (100 - offHandHit)
							local effectiveHitChance = bothHit + mainHandHit * offHandMiss / 100 + mainHandMiss * offHandHit / 100
							triggerChance = triggerChance * effectiveHitChance / 100
							if breakdown then
								t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s effective hit chance for skills that hit with both weapons)", effectiveHitChance, source.activeEffect.grantedEffect.name))
							end
						else
							triggerChance = triggerChance * (sourceHitChance or 0) / 100
							if breakdown then
								t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s hit chance)", sourceHitChance, source.activeEffect.grantedEffect.name))
							end
						end
					end
					if actor.mainSkill.skillData.triggerOnCrit then
						local onCritChance = actor.mainSkill.skillData.chanceToTriggerOnCrit or (GlobalCache.cachedData[env.mode][uuid] and GlobalCache.cachedData[env.mode][uuid].Env.player.mainSkill.skillData.chanceToTriggerOnCrit)
						config.triggerChance = config.triggerChance or actor.mainSkill.skillData.chanceToTriggerOnCrit or onCritChance

						local sourceCritChance = GlobalCache.cachedData[env.mode][uuid].CritChance or 0
						if sourceCritChance ~= 100 then
							-- Some skills hit with both weapons at the same time. Each weapon rolls accuracy and crit independently
							if source and env.player.weaponData1.type and env.player.weaponData2.type and source.skillData.combinesHitsWhenDualWielding then
								local mainHandCrit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.MainHand.CritChance
								local offHandCrit = GlobalCache.cachedData[env.mode][uuid].Env.player.output.OffHand.CritChance
								local bothHit = mainHandCrit * offHandCrit / 100
								local mainHandMiss = (100 - mainHandCrit)
								local offHandMiss = (100 - offHandCrit)
								local effectiveCritChance = bothHit + mainHandCrit * offHandMiss / 100 + mainHandMiss * offHandCrit / 100
								triggerChance = triggerChance * effectiveCritChance / 100
								if breakdown then
									t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s effective crit chance for skills that hit with both weapons)", effectiveCritChance, source.activeEffect.grantedEffect.name))
								end
							else
								triggerChance = triggerChance * (sourceCritChance or 0) / 100
								if breakdown then
									t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(%s crit chance)", sourceCritChance, source.activeEffect.grantedEffect.name))
								end
							end
						end
					end
				end

				--Trigger chance
				if config.triggerChance and config.triggerChance ~= 100 then
					triggerChance = triggerChance * config.triggerChance / 100
					if breakdown then
						t_insert(triggerChanceBreakdown, s_format("x %.2f%% ^8(chance to trigger)", config.triggerChance))
					end
				end

				-- If the current triggered skill ignores tick rate and is the only triggered skill by this trigger use charge based calcs
				-- (and for a source that accumulates, like Energy: its rate capped by the cooldown, nothing to align)
				if (actor.mainSkill.skillData.ignoresTickRate or config.accumulatingSource) and ( not config.triggeredSkillCond or (triggeredSkills and #triggeredSkills == 1 and triggeredSkills[1] == packageSkillDataForSimulation(actor.mainSkill, env)) ) then
					local overlaps = config.stagesAreOverlaps and env.player.mainSkill.skillPart == config.stagesAreOverlaps and env.player.mainSkill.activeEffect.srcInstance.skillStageCount or config.overlaps
					output.SkillTriggerRate = m_min(output.TriggerRateCap, output.EffectiveSourceRate * (overlaps or 1))
					if breakdown then
						if overlaps then
							breakdown.SkillTriggerRate = {
								s_format("min(%.2f, %.2f *  %d) ^8(%d overlaps)", output.TriggerRateCap, output.EffectiveSourceRate, overlaps, overlaps)
							}
						else
							breakdown.SkillTriggerRate = {
								s_format("min(%.2f, %.2f)", output.TriggerRateCap, output.EffectiveSourceRate)
							}
						end
					end
				elseif actor.mainSkill.skillFlags.globalTrigger and not config.triggeredSkillCond then -- Trigger does not use source rate breakpoints for one reason or another
					output.SkillTriggerRate = output.EffectiveSourceRate
				else -- Triggers like Cast on Crit go through simulation to calculate the trigger rate of each skill in the trigger group
					output.SkillTriggerRate, simBreakdown = calcMultiSpellRotationImpact(env, config.triggeredSkillCond and triggeredSkills or {packageSkillDataForSimulation(actor.mainSkill, env)}, output.EffectiveSourceRate, (not actor.mainSkill.skillData.triggeredByBrand and ( triggerCD or triggeredCD ) or 0), triggerChance, actor)
					if actor.mainSkill.skillData.supportTriggerChance then
						-- the simulation's 1000 events can count 1001 triggers; one event triggers at most once
						output.SkillTriggerRate = m_min(output.SkillTriggerRate, output.EffectiveSourceRate)
					end
					local triggerBotsEffective = actor.modDB:Flag(nil, "HaveTriggerBots") and actor.mainSkill.skillTypes[SkillType.Spell]
					if triggerBotsEffective then
						output.SkillTriggerRate = 2 * output.SkillTriggerRate
					end

					-- stagesAreOverlaps is the skill part which makes the stages behave as overlaps
					local hits_per_cast = config.stagesAreOverlaps and env.player.mainSkill.skillPart == config.stagesAreOverlaps and env.player.mainSkill.activeEffect.srcInstance.skillStageCount or 1
					output.SkillTriggerRate = hits_per_cast * output.SkillTriggerRate
					if breakdown then
						breakdown.SkillTriggerRate = {
							s_format("%.2f ^8(%s)", output.EffectiveSourceRate, (actor.mainSkill.skillData.triggeredByBrand and s_format("%s activations per second", source.activeEffect.grantedEffect.name)) or (not trigRate and s_format("%s triggers per second", skillName)) or "Effective source rate"),
							s_format("/ %.2f ^8(Estimated impact of skill rotation, cooldown alignment and trigger chance)", m_max(output.EffectiveSourceRate / output.SkillTriggerRate, 1)),
							s_format("= %.2f ^8per second", output.SkillTriggerRate),
						}
						if triggerChance ~= 100 then
							t_insert(breakdown.SkillTriggerRate, 1, "")
							t_insert(breakdown.SkillTriggerRate, 1, s_format("= %.2f%% ^8(Effective chance to trigger)", triggerChance))
							for _, line in ipairs(triggerChanceBreakdown) do
								t_insert(breakdown.SkillTriggerRate, 1, line)
							end
							t_insert(breakdown.SkillTriggerRate, 1, "100% ^8(Base chance)")
						end
						if triggerBotsEffective then
							t_insert(breakdown.SkillTriggerRate, 3, "x 2 ^8(Trigger bots effectively cause the skill to trigger twice)")
						end
						if hits_per_cast > 1 then
							t_insert(breakdown.SkillTriggerRate, 3, s_format("x %.2f ^8(hits per triggered skill cast)", hits_per_cast))
						end
						if simBreakdown.extraSimInfo then
							t_insert(breakdown.SkillTriggerRate, "")
							t_insert(breakdown.SkillTriggerRate, simBreakdown.extraSimInfo)
						end
						breakdown.SimData = {
							rowList = { },
							colList = {
								{ label = "Rate", key = "rate" },
								{ label = "Skill Name", key = "skillName" },
								{ label = "Slot Name", key = "slotName" },
								{ label = "Gem Index", key = "gemIndex" },
							},
						}
						for _, rateData in ipairs(simBreakdown.rates) do
							local t = { }
							for str in string.gmatch(rateData.name, "([^_]+)") do
								t_insert(t, str)
							end

							local row = {
								rate = round(rateData.rate, 2),
								skillName = t[1],
								slotName = t[2],
								gemIndex = t[3],
							}
							t_insert(breakdown.SimData.rowList, row)
						end
						t_insert(breakdown.SimData, s_format("Simulation duration: %.2f ^8(In game source skill usage duration in seconds)", simBreakdown.simTime, simBreakdown.simTime))
					end
				end
			else
				if breakdown then
					breakdown.SkillTriggerRate = {
						s_format("The trigger needs to be triggered for any skill to be triggered."),
					}
				end
				output.SkillTriggerRate = 0
			end
			actor.mainSkill.skillData.triggerRate = output.SkillTriggerRate

			-- Account for Trigger-related INC/MORE modifiers
			output.Speed = actor.mainSkill.skillData.triggerRate
			addTriggerIncMoreMods(actor.mainSkill, source or actor.mainSkill)
			if source and source ~= actor.mainSkill then
				actor.mainSkill.skillData.triggerSourceUUID = cacheSkillUUID(source, env)
				actor.mainSkill.infoMessage = (config.customTriggerName or ((config.triggerName ~= source.activeEffect.grantedEffect.name and config.triggerName or triggeredName) .. ( actor == env.minion and "'s attack Trigger: " or "'s Trigger: "))) .. source.activeEffect.grantedEffect.name
			else
				actor.mainSkill.infoMessage = actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.name or config.triggerName .. " Trigger"
			end

			actor.mainSkill.infoTrigger = config.triggerName
		end
	end
end

local configTable = {
	["law of the wilds"] = function()
		return {
			triggerSkillCond = function(env, skill)
				return not skill.skillTypes[SkillType.SummonsTotem] and (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, ModFlag.Claw) > 0
			end
		}
	end,
	["the rippling thoughts"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Storm Cascade" then
			return {
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack])
				end
			}
		end
	end,
	["the surging thoughts"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Storm Cascade" then
			return {
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack])
				end
			}
		end
	end,
	["the hidden blade"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		env.player.mainSkill.skillData.triggerRateCapOverride = 2
		if env.player.modDB:Flag(nil, "Condition:Phasing") then
			if env.player.breakdown then
				env.player.breakdown.TriggerRateCap = {
					s_format("%.2f ^8(Unseen Strike from The Hidden Blade has no cooldown but is still triggered)", env.player.mainSkill.skillData.triggerRateCapOverride),
					s_format("= %.2f", env.player.mainSkill.skillData.triggerRateCapOverride),
				}
			end
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillFlags.disable = true
		env.player.mainSkill.disableReason = "This skill is requires you to be phasing"
	end,
	["replica eternity shroud"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill}
	end,
	["shroud of the lightless"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill}
	end,
	["limbsplit"] = function()
		return {triggerName = "Gore Shockwave", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["the cauteriser"] = function()
		return {triggerName = "Gore Shockwave", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["duskblight"] = function()
		return {triggerName = "Stalking Pustule", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["lioneye's paws"] = function(env)
		-- Due to the way the triggerExtraSkill function in mod parser works this trigger does not use the custom trigger skill (RainOfArrowsOnAttackingWithBow)
		-- the normal version is used here instead. The stats are the same but the normal version does not have cooldown.
		env.player.mainSkill.skillData.cooldown = 1
		return {triggerOnUse = true, triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] and band(skill.skillCfg.flags, ModFlag.Bow) > 0 end}
	end,
	["replica lioneye's paws"] = function(env)
		-- Due to the way the triggerExtraSkill function in mod parser works this trigger does not use the custom trigger skill (RainOfArrowsOnAttackingWithBow)
		-- the normal version is used here instead. The stats are the same but the normal version does not have cooldown.
		env.player.mainSkill.skillData.cooldown = 1
		return {triggerOnUse = true, triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] and band(skill.skillCfg.flags, ModFlag.Bow) > 0 end}
	end,
	["moonbender's wing"] = function(env)
		--Similar situation to "Replica Lioneye's Paws"
		env.player.mainSkill.skillData.cooldown = 1
		return {triggerName = "Lightning Warp", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["ngamahu's flame"] = function()
		return {triggerName = "Molten Burst", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Melee] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["cameria's avarice"] = function()
		return {triggerName = "Icicle Burst", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["uul-netol's embrace"] = function()
		return {triggerName = "Bone Nova", triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["rigwald's crest"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["jorrhast's blacksteel"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["ashcaller"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["arakaali's fang"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["sporeguard"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["mark of the elder"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["mark of the shaper"] = function()
		return {assumingEveryHitKills = true, triggerSkillCond = function(env, skill) return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) end}
	end,
	["poet's pen"] = function()
		return {triggerOnUse = true,
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, ModFlag.Wand) > 0
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot and skill.skillTypes[SkillType.Spell]
				end}
	end,
	["maloney's mechanism"] = function(env)
		local _, _, uniqueTriggerName = env.player.itemList[env.player.mainSkill.slotName].modSource:find(".*:.*:(.*),.*")
		local isReplica = uniqueTriggerName:match("Replica.")
		return {triggerOnUse = true, triggerName = uniqueTriggerName, useCastRate = isReplica,
				triggerSkillCond = function(env, skill)
					local attack = skill.skillTypes[SkillType.Attack] and (band(skill.skillCfg.flags, ModFlag.Bow) > 0) and not isReplica
					local spell = skill.skillTypes[SkillType.Spell] and isReplica
					return (attack or spell)
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot and skill.skillTypes[SkillType.RangedAttack]
				end}
	end,
	["asenath's chant"] = function()
		return {triggerOnUse = true,
				triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, ModFlag.Bow) > 0
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot and skill.skillTypes[SkillType.Spell]
				end}
	end,
	["vixen's entrapment"] = function()
		return {useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Hex]
				end}
	end,
	["flames of judgement"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerName = env.player.mainSkill.activeEffect.grantedEffect.name,
				triggerSkillCond = function(env, skill) return skill.activeEffect.grantedEffect.name == "Queen's Demand" end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot end}
	end,
	["storm of judgement"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerName = env.player.mainSkill.activeEffect.grantedEffect.name,
				triggerSkillCond = function(env, skill) return skill.activeEffect.grantedEffect.name == "Queen's Demand" end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByUnique and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot end}
	end,
	["trigger craft"] = function(env)
		if env.player.mainSkill.skillData.triggeredByCraft then
			local trigRate, source, uuid, useCastRate, triggeredSkills
			triggeredSkills = {}
			for _, skill in ipairs(env.player.activeSkillList) do
				if (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack] or skill.skillTypes[SkillType.Spell]) and not skill.skillFlags.aura and skill ~= env.player.mainSkill and not skill.skillData.triggeredByCraft and not skill.activeEffect.grantedEffect.fromItem and not isTriggered(skill) then
					source, trigRate, uuid = findTriggerSkill(env, skill, source, trigRate)
					if skill.skillFlags and (skill.skillFlags.totem or skill.skillFlags.golem or skill.skillFlags.banner or skill.skillFlags.ballista) and skill.activeEffect.grantedEffect.castTime then
						if skill.activeEffect.grantedEffect.levels ~= nil then
							trigRate = 1 / (skill.activeEffect.grantedEffect.castTime + (skill.activeEffect.grantedEffect.levels[skill.activeEffect.level].cooldown or 0))
						else
							trigRate = 1 / skill.activeEffect.grantedEffect.castTime
						end
						useCastRate = true
					end
				end
				if skill.skillData.triggeredByCraft and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot then
					t_insert(triggeredSkills, packageSkillDataForSimulation(skill, env))
				end
			end
			return {trigRate = trigRate, source = source, uuid = uuid, useCastRate = useCastRate, triggeredSkills = triggeredSkills}
		end
	end,
	["kitava's thirst"] = function(env)
		local requiredManaCost = env.player.modDB:Sum("BASE", nil, "KitavaRequiredManaCost")
		return {triggerChance = env.player.modDB:Sum("BASE", nil, "KitavaTriggerChance"),
				triggerName = "Kitava's Thirst",
				comparer = function(env, uuid, source, triggerRate)
					local cachedSpeed = GlobalCache.cachedData[env.mode][uuid].HitSpeed or GlobalCache.cachedData[env.mode][uuid].Speed
					local cachedManaCost = GlobalCache.cachedData[env.mode][uuid].ManaCost
					return ( (not source and cachedSpeed) or (cachedSpeed and cachedSpeed > (triggerRate or 0)) ) and ( (cachedManaCost or 0) > requiredManaCost )
				end,
				triggerSkillCond = function(env, skill)
					return true
					-- Filtering done by skill() in SkillStatMap, comparer and default excludes
				end}
	end,
	["mjolner"] = function()
		return {triggerSkillCond = function(env, skill)
					return (skill.skillTypes[SkillType.Damage] or skill.skillTypes[SkillType.Attack]) and band(skill.skillCfg.flags, bor(ModFlag.Mace, ModFlag.Weapon1H)) > 0 and not slotMatch(env, skill)
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredByMjolner and slotMatch(env, skill)
				end}
	end,
	["cospri's malice"] = function()
		return {triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Melee] and band(skill.skillCfg.flags, bor(ModFlag.Sword, ModFlag.Weapon1H)) > 0
				end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByCospris and env.player.mainSkill.socketGroup.slot == skill.socketGroup.slot end}
	end,
	["cast on critical strike"] = function()
		return {triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] and slotMatch(env, skill) end,
				triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByCoc and slotMatch(env, skill) end}
	end,
	["cast on melee kill"] = function(env)
		if env.player.modDB:Flag(nil, "Condition:KilledRecently") then
			return {assumingEveryHitKills = true,
					triggerSkillCond = function(env, skill)
						return skill.skillTypes[SkillType.Attack] and skill.skillTypes[SkillType.Melee] and slotMatch(env, skill)
					end,
					triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByMeleeKill and slotMatch(env, skill) end}
		else
			env.player.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
			env.player.mainSkill.infoMessage = "Cast on Melee Kill requires recent kills"
		end
	end,
	["nova"] = function(env)
		if env.minion and env.minion.mainSkill then
			return {triggerName = "Summon Holy Relic",
				   actor = env.minion,
				   triggeredSkills = {{ uuid = cacheSkillUUID(env.minion.mainSkill, env), cd = env.minion.mainSkill.skillData.cooldown}},
				   triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] end}
		end
	end,
	["cast when damage taken"] = function(env)
		if env.player.mainSkill.skillData.triggeredByDamageTaken then
			local thresholdMod = calcLib.mod(env.player.mainSkill.skillModList, nil, "CWDTThreshold")
			env.player.output.CWDTThreshold = env.player.mainSkill.skillData.triggeredByDamageTaken * thresholdMod
			if env.player.breakdown and env.player.output.CWDTThreshold ~= env.player.mainSkill.skillData.triggeredByDamageTaken then
				env.player.breakdown.CWDTThreshold = {
					s_format("%.2f ^8(base threshold)", env.player.mainSkill.skillData.triggeredByDamageTaken),
					s_format("x %.2f ^8(threshold modifier)", thresholdMod),
					s_format("= %.2f", env.player.output.CWDTThreshold),
				}
			end
			env.player.mainSkill.skillFlags.globalTrigger = true
			return  {source = env.player.mainSkill}
		end
	end,
	["cast when stunned"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {triggerChance =  env.player.mainSkill.skillData.chanceToTriggerOnStun,
				source = env.player.mainSkill}
	end,
	["automation"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Automation" then
			-- This calculated the trigger rate of the Automation gem it self
			env.player.mainSkill.skillFlags.globalTrigger = true
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true

		-- Trigger rate of the triggered skill is capped by the cooldown of Automation
		-- which will likely be different from the cooldown of the triggered skill
		-- and is affected by different cooldown modifiers
		env.player.mainSkill.skillData.ignoresTickRate = true

		-- This basically does min(trigger rate of steelskin assuming no trigger cooldown, trigger rate of Automation)
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Automation"
				end}
	end,
	["spellslinger"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Spellslinger" then
			return {triggerName = "Spellslinger",
				triggerOnUse = true,
				triggerSkillCond = function(env, skill)
					local isWandAttack = (not skill.weaponTypes or (skill.weaponTypes and skill.weaponTypes["Wand"])) and skill.skillTypes[SkillType.Attack]
					return isWandAttack and not skill.skillData.triggeredBySpellSlinger
				end}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Spellslinger"
				end}
	end,
	["call to arms"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Call to Arms" then
			env.player.mainSkill.skillFlags.globalTrigger = true
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		env.player.mainSkill.skillData.ignoresTickRate = true
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Call to Arms"
				end}
	end,
	["autoexertion"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name == "Autoexertion" then
			env.player.mainSkill.skillFlags.globalTrigger = true
			return {source = env.player.mainSkill}
		end
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		env.player.mainSkill.skillData.ignoresTickRate = true
		return {triggerOnUse = true,
				useCastRate = true,
				triggerSkillCond = function(env, skill)
					return skill.activeEffect.grantedEffect.name == "Autoexertion"
				end}
	end,
	["mark on hit"] = function()
		return {triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Attack] end}
	end,
	["hextouch"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Attack] and slotMatch(env, skill)
				end}
	end,
	["oskarm"] = function(env)
		env.player.mainSkill.skillData.sourceRateIsFinal = true
		return {triggerSkillCond = function(env, skill)
					return skill.skillTypes[SkillType.Attack]
				end}
	end,
	["tempest shield"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill}
	end,
	["shattershard"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		local uuid = cacheSkillUUID(env.player.mainSkill, env)
		if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
			calcs.buildActiveSkill(env, env.mode, env.player.mainSkill, uuid, {[uuid] = true})
		end
		env.player.mainSkill.skillData.triggerRateCapOverride = 1 / GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration
		if env.player.breakdown then
			env.player.breakdown.SkillTriggerRate = {
				s_format("Shattershard uses duration as pseudo cooldown"),
				s_format("1 / %.2f ^8(Shattershard duration)", GlobalCache.cachedData[env.mode][uuid].Env.player.output.Duration),
				s_format("= %.2f ^8per second", env.player.mainSkill.skillData.triggerRateCapOverride),
			}
		end
		return {source = env.player.mainSkill}
	end,
	["battlemage's cry"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name ~= "Battlemage's Cry" then
			return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Melee] end,
					comparer = function(env, uuid, source, triggerRate)
						-- Skills with no uptime ratio are not exerted by battlemage so should not be considered.
						local uptimeRatio = GlobalCache.cachedData[env.mode][uuid].Env.player.output.BattlemageUpTimeRatio
						return defaultComparer(env, uuid, source, triggerRate) and uptimeRatio
					end,
					triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByBattleMageCry and slotMatch(env, skill) end}
		end
	end,
	["arcanist brand"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name ~= "Arcanist Brand" then
			env.player.mainSkill.skillData.sourceRateIsFinal = true
			for _, skill in ipairs(env.player.activeSkillList) do
				if skill.activeEffect.grantedEffect.name == "Arcanist Brand" then
					env.player.mainSkill.triggeredBy.mainSkill = skill
					break
				end
			end

			local activationFreqInc = (100 + env.player.mainSkill.triggeredBy.mainSkill.skillModList:Sum("INC", env.player.mainSkill.skillCfg, "Speed", "BrandActivationFrequency")) / 100
			local activationFreqMore = env.player.mainSkill.triggeredBy.mainSkill.skillModList:More(env.player.mainSkill.skillCfg, "BrandActivationFrequency")
			env.player.mainSkill.triggeredBy.activationFreqInc = activationFreqInc
			env.player.mainSkill.triggeredBy.activationFreqMore = activationFreqMore
			env.player.mainSkill.triggeredBy.ignoresTickRate = true
			return {trigRate = env.player.mainSkill.triggeredBy.mainSkill.skillData.repeatFrequency * activationFreqInc * activationFreqMore,
					source = env.player.mainSkill.triggeredBy.mainSkill,
					triggeredSkillCond = function(env, skill) return skill.skillData.triggeredByBrand and slotMatch(env, skill) end}
		end
	end,
	["cast on death"] = function(env)
        env.player.mainSkill.skillFlags.globalTrigger = true
		env.player.mainSkill.skillData.triggered = true
		env.player.mainSkill.infoMessage = env.player.mainSkill.activeEffect.grantedEffect.name .. " Triggered on Death"
	end,
	["combust"] = function(env)
		return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Melee] end,
				comparer = function(env, uuid, source, triggerRate)
					-- Skills with no uptime ratio are not exerted by infernal cry so should not be considered.
					local uptimeRatio = GlobalCache.cachedData[env.mode][uuid].Env.player.output.InfernalUpTimeRatio
					return defaultComparer(env, uuid, source, triggerRate) and uptimeRatio
				end,}
	end,
	["prismatic burst"] = function(env)
		return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Attack] and slotMatch(env, skill) end}
	end,
	["shockwave"] = function(env)
		return {triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Melee] and slotMatch(env, skill) end}
	end,
	["manaforged arrows"] = function(env)
		return {triggerOnUse = true,
				triggerName = "Manaforged Arrows",
				triggerSkillCond = function(env, skill)	return skill.skillTypes[SkillType.Attack] and band(skill.skillCfg.flags, ModFlag.Bow) > 0 end}
	end,
	["doom blast"] = function(env)
		if env.build.configTab.input["doomBlastSource"] == "replacement" then
			env.player.modDB:NewMod("UsesCurseOverlaps", "FLAG", true, "Config")
		end
		env.player.mainSkill.skillData.ignoresTickRate = true
		return {useCastRate = true,
				overlaps = #env.player.modDB:Tabulate("BASE", nil, "Multiplier:CurseOverlaps") > 0 and m_max(env.player.modDB:Sum("BASE", nil, "Multiplier:CurseOverlaps"), 1),
				customTriggerName = "Doom Blast triggering Hex: ",
				triggerSkillCond = function(env, skill) return skill.skillTypes[SkillType.Hex] and slotMatch(env, skill) end}
	end,
	["cast while channelling"] = function()
		return {customHandler = CWCHandler}
	end,
	["focus"] = function()
		return {customHandler = helmetFocusHandler}
	end,
	["snipe"] = function(env)
		local snipeStages = m_min(env.player.modDB:Sum("BASE", nil, "Multiplier:SnipeStage"), env.player.modDB:Sum("BASE", nil, "Multiplier:SnipeStagesMax"))
		local snipeHitMulti = env.player.mainSkill.skillModList:Sum("BASE", env.player.mainSkill.skillCfg, "snipeHitMulti")
		local snipeAilmentMulti = env.player.mainSkill.skillModList:Sum("BASE", env.player.mainSkill.skillCfg, "snipeAilmentMulti")
		local triggeredSkills = {}

		for _, skill in ipairs(env.player.activeSkillList) do
			if skill.skillData.triggeredBySnipe and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot then
				t_insert(triggeredSkills, skill)
			end
		end

		if env.player.mainSkill.activeEffect.grantedEffect.name == "Snipe" then
			if (env.limitedSkills and env.limitedSkills[cacheSkillUUID(env.player.mainSkill, env)]) then
				-- Snipe is being used by some other skill. In this case snipe does not get more damage mods
				snipeStages = 0
			else
				-- max(1, snipeStages) makes it behave consistently with other channeled ranged skills (scourge arrow)
				env.player.mainSkill.skillData.hitTimeMultiplier = m_max(1, snipeStages) - 0.5 --First stage takes 0.5x time to channel compared to subsequent stages
			end
			if #triggeredSkills < 1 then
				-- Snipe is being used as a standalone skill
				if snipeStages then
					env.player.mainSkill.skillModList:NewMod("Multiplier:SnipeStages", "BASE", snipeStages, "Snipe")
					env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeHitMulti, "Snipe", ModFlag.Hit, 0, { type = "Multiplier", var = "SnipeStages" })
					env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeAilmentMulti, "Snipe", ModFlag.Ailment, 0, { type = "Multiplier", var = "SnipeStages" })
				end
			else
				-- Snipe is being used as a trigger source, it triggers other skills but does no damage it self
				env.player.mainSkill.skillModList:NewMod("DealNoLightning", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoCold", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoFire", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoChaos", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
				env.player.mainSkill.skillModList:NewMod("DealNoPhysical", "FLAG", true, { type = "SkillName", skillName = "Snipe", includeTransfigured = true })
			end
		else
			local currentSkillSnipeIndex
			for index, skill in ipairs(triggeredSkills) do
				if skill == env.player.mainSkill then
					currentSkillSnipeIndex = index
					break
				end
			end

			-- Does snipe have enough stages to trigger this skill?
			if currentSkillSnipeIndex and currentSkillSnipeIndex <= snipeStages then
				local source
				local trigRate
				env.player.mainSkill.skillModList:NewMod("Multiplier:SnipeStages", "BASE", snipeStages, "Snipe")
				env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeAilmentMulti, "Snipe", ModFlag.Ailment, 0, { type = "Multiplier", var = "SnipeStages" })
				env.player.mainSkill.skillModList:NewMod("Damage", "MORE", snipeHitMulti, "Snipe", ModFlag.Hit, 0, { type = "Multiplier", var = "SnipeStages" })
				for _, skill in ipairs(env.player.activeSkillList) do
					if skill.activeEffect.grantedEffect.name == "Snipe" and skill.socketGroup and skill.socketGroup.slot == env.player.mainSkill.socketGroup.slot then
						skill.skillData.hitTimeMultiplier = snipeStages - 0.5
						local uuid = cacheSkillUUID(skill, env)
						if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
							calcs.buildActiveSkill(env, env.mode, skill, uuid)
						end
						local cachedSpeed = GlobalCache.cachedData[env.mode][uuid].Env.player.output.HitSpeed
						if (skill.skillFlags and not skill.skillFlags.disable) and (skill.skillCfg and not skill.skillCfg.skillCond["usedByMirage"]) and not skill.skillTypes[SkillType.OtherThingUsesSkill] and ((not source and cachedSpeed) or (cachedSpeed and cachedSpeed > (trigRate or 0))) then
							trigRate = cachedSpeed
							env.player.output.ChannelTimeToTrigger = GlobalCache.cachedData[env.mode][uuid].Env.player.output.HitTime
							source = skill
						end
					end
				end

				return {trigRate = trigRate, source = source}
			else
				env.player.mainSkill.skillData.triggered = nil
				env.player.mainSkill.infoMessage2 = "DPS reported assuming Self-Cast"
				env.player.mainSkill.infoMessage = "Not enough Snipe stages to trigger this skill"
				env.player.mainSkill.infoTrigger = ""
			end
		end
	end,
	["avenging flame"]  = function(env)
		return {triggerSkillCond = function(env, skill) return skill.skillFlags.totem and slotMatch(env, skill) end,
				comparer = function(env, uuid, source, currentTotemLife)
					local totemLife = GlobalCache.cachedData[env.mode][uuid].Env.player.output.TotemLife
					return (not source and totemLife) or (totemLife and totemLife > (currentTotemLife or 0))
				end,
				ignoreSourceRate = true}
	end,
	["intuitive link"] = function(env)
		if env.player.mainSkill.activeEffect.grantedEffect.name ~= "Intuitive Link" then
			for _, skill in ipairs(env.player.activeSkillList) do
				if skill.activeEffect.grantedEffect.name == "Intuitive Link" then
					env.player.mainSkill.triggeredBy.mainSkill = skill
					break
				end
			end
			return {triggeredSkillCond = function(env, skill) return skill.skillTypes[SkillType.Spell] and slotMatch(env, skill) and skill ~= env.player.mainSkill.triggeredBy.mainSkill end,
					trigRate = env.modDB:Sum("BASE", nil, "IntuitiveLinkSourceRate"),
					source = env.player.mainSkill.triggeredBy.mainSkill,
					sourceName = "Custom source",
					useCastRate = true}
		end
	end,
	["supporttriggerelementalspellonblock"] = function(env) -- Svalinn Girded Tower Shield
		env.player.mainSkill.skillFlags.globalTrigger = true
		return {source = env.player.mainSkill,
				triggeredSkillCond = function(env, skill)
					return slotMatch(env, skill) and skill.triggeredBy and calcLib.canGrantedEffectSupportActiveSkill(skill.triggeredBy.grantedEffect, skill)
				end}
	end,
	["supporttriggerfirespellonhit"] = function(env)
		return {triggerSkillCond = function(env, skill)
					-- Skill is triggered only when the weapon with the enchant on it hits
					return skill.skillTypes[SkillType.Melee]
				end,
				triggeredSkillCond = function(env, skill)
					return skill.skillData.triggeredBySettlersEnchantTrigger and slotMatch(env, skill)
				end}
	end,
}

-- Find unique item trigger name
local function getUniqueItemTriggerName(skill)
	if skill.skillData.triggerSource then
		return skill.skillData.triggerSource
	elseif skill.supportList and #skill.supportList >= 1 then
		for _, gemInstance in ipairs(skill.supportList) do
			if gemInstance.grantedEffect and gemInstance.grantedEffect.fromItem and not gemInstance.grantedEffect.support then
				return gemInstance.grantedEffect.name
			end
		end
	end

	if skill.socketGroup and skill.socketGroup.source then
		local _, _, uniqueTriggerName = skill.socketGroup.source:find(".*:.*:(.*),.*")
		return uniqueTriggerName
	end
end

-- PoE2 meta skills (Cast on Critical, Cast on Elemental Ailment, the Invocations, ...) gain Energy from events and trigger the Spells
-- socketed in them. An approximation: CalcPerform only calls this with Use approximations on; off, a meta-triggered Spell keeps
-- PoB's self-cast rate. Rules, from the skill and stat descriptions:
-- * A trigger needs the Energy of all socketed Spells together: 1 per 10 ms of each Spell's base cast time
--   (generic_ongoing_trigger_1_maximum_energy_per_Xms_total_cast_time), and triggers all of them, so each Spell triggers at
--   Energy per second / that total. "Refund half of Energy spent" (chance r) makes a trigger cost 1 - r / 2 of it.
-- * Energy beyond the maximum is lost: an event adds at most the maximum. Meta skills whose maximum is that total
--   (triggers_at_maximum_energy) trigger at most once per event. Invocations store up to their maximum (500) and spend it when
--   used, triggering the Spells as often as the stored Energy pays for: at most floor(maximum / total) times per use, one use per
--   cooldown (0.2 s, tick-rounded); a total above the maximum never triggers.
-- * Energy per event = the gem's base x the enemy's Power (poe2db Monster_Power: 20 with the boss options, 5 for "Is the enemy
--   Rare?", 2 for "Is the enemy Magic?", else 1) x increased / more Energy, and for Critical Hits, Melee Hits and Ignites also x the
--   percentage of the enemy's Ailment Threshold the Hit (the Ignite) deals, as a number (a Hit for 5% of the threshold counts 5 times).
-- * Event rates come from the build's own skill with the highest hit rate, Full DPS skills first, in the main skill's weapon set,
--   an unused Default Attack never: Critical Hits, Shocks, Ignites, Melee Hits, Spells cast (Spellslinger: base x 10 ms steps of
--   the cast Spell's base cast time). Kills per second (pack monsters, Power 1) with a Melee Attack in the build; enemy hits on you
--   per second x block chance.
-- ponytail: the threshold factor's "percentage as a number" reading is unverified (no source states it); the in-game test that
-- settles it: Cast on Critical with one known Spell (e.g. Fireball, 120 Energy), Critical Hits of known damage against an enemy of
-- known Ailment Threshold, counting hits per trigger (plan Phase 6). Also assumptions: base (unmodified) cast time, the average
-- instead of the rounded-up number of events per trigger.
-- ponytail: each candidate source skill is a full calculation; one evaluation (its passes and its Full DPS pass share the override
-- table) calculates them once (cachedSourceRecord); upgrade path = reuse the Full DPS pass's own result for a source skill.
-- Not modelled (no event rate): Freeze, Stun, Dodge Roll, Charm use, Minion death, Energy Shield damage taken, mana spent.
local energyEvents = { "energyOnCrit", "energyOnShock", "energyOnIgnite", "energyOnMeleeHit", "energyPer10msCastTime", "energyOnMeleeKill", "energyOnBlock" }

-- What a trigger needs from a source skill's calculation, as plain numbers: the cache is weak-keyed by the override table, which
-- the calculation's environment references (a value referring to its key would keep the entry alive)
local function sourceRecord(cached)
	local output = cached.Env.player.output
	local passOutput, critAverage = output.MainHand or output, 0
	for _, damageType in ipairs({ "Physical", "Lightning", "Cold", "Fire", "Chaos" }) do
		critAverage = critAverage + (passOutput[damageType .. "CritAverage"] or 0)
	end
	-- the Hit's highest Elemental damage type (nil: it deals none)
	local element, most = nil, 0
	for _, damageType in ipairs({ "Fire", "Cold", "Lightning" }) do
		if (passOutput[damageType .. "CritAverage"] or 0) > most then
			element, most = damageType, passOutput[damageType .. "CritAverage"]
		end
	end
	-- percentage of the enemy's Ailment Threshold a hit of this size deals
	local threshold = output.EnemyAilmentThreshold or 0
	local function percent(damage)
		return threshold > 0 and 100 * damage / threshold or 0
	end
	return {
		name = cached.ActiveSkill.activeEffect.grantedEffect.name,
		rates = calcs.approxRates(cached.Env, output),
		speed = cached.Speed or 0,
		hitSpeed = cached.HitSpeed or cached.Speed,
		castTime = cached.ActiveSkill.activeEffect.grantedEffect.castTime or 0,
		shockChance = m_min(output.ShockChance or 0, 100),
		dealsLightning = (passOutput.LightningCritAverage or 0) > 0,
		dealsElemental = element ~= nil,
		element = element,
		dealsChaos = (passOutput.ChaosCritAverage or 0) > 0,
		igniteDuration = output.IgniteDuration or 0,
		duration = output.Duration or 0,
		critPercent = percent(critAverage),
		hitPercent = percent(output.AverageHit or 0),
		ignitePercent = percent((output.IgniteDPS or 0) * (output.IgniteDuration or 0)),
	}
end
-- A source skill's record, calculated once per evaluation: its passes and its Full DPS pass share the override table
local sourceRecords = setmetatable({ }, { __mode = "k" })
local function cachedSourceRecord(env, skill)
	local evaluation = env.override or env
	local cache = sourceRecords[evaluation] or { }
	sourceRecords[evaluation] = cache
	local uuid = cacheSkillUUID(skill, env)
	local key = uuid .. env.mode
	if cache[key] == nil then
		if not GlobalCache.cachedData[env.mode][uuid] or env.mode == "CALCULATOR" then
			calcs.buildActiveSkill(env, env.mode, skill, uuid)
		end
		local cached = GlobalCache.cachedData[env.mode][uuid]
		cache[key] = cached and cached.Env and (cached.HitSpeed or cached.Speed) and sourceRecord(cached) or false
	end
	return cache[key] or nil
end

-- Skills of the build that can cause an event: in the main skill's weapon set, not a Default Attack left out of Full DPS, never a
-- triggered skill. Anywhere in the build (a trigger from a passive node or a meta skill is not tied to one socket group)
local function sourceCandidates(env, cond, fullDPSOnly)
	local list = { }
	for _, skill in ipairs(env.player.activeSkillList) do
		local group = skill.socketGroup
		local flags = (env.mode == "CALCS" and skill.activeEffect.statSetCalcs or skill.activeEffect.statSet).skillFlags
		if group and flags and not flags.disable and not flags.minion and not flags.totem and not isTriggered(skill) and not skill.skillTypes[SkillType.Meta]
			and (group.usingSkillSet or env.weaponSet) == env.weaponSet and (group.source ~= "Default Attack" or group.includeInFullDPS)
			and (group.includeInFullDPS or not fullDPSOnly) and cond(skill, flags) then
			t_insert(list, skill)
		end
	end
	return list
end
-- The candidate with the highest rate (default: hit or use rate), Full DPS skills first: its record, then the skill. `recordCond`
-- (optional) leaves out the candidates whose calculation doesn't qualify (a Hit without Elemental damage, say)
local function eventSource(env, cond, rate, recordCond)
	rate = rate or function(record) return record.hitSpeed end
	for _, fullDPSOnly in ipairs({ true, false }) do
		local best, bestSkill
		for _, skill in ipairs(sourceCandidates(env, cond, fullDPSOnly)) do
			local record = cachedSourceRecord(env, skill)
			if record and (not recordCond or recordCond(record)) and (not best or rate(record) > rate(best)) then
				best, bestSkill = record, skill
			end
		end
		if best then
			return best, bestSkill
		end
	end
end

-- The enemy's Monster Power (poe2db Monster_Power: Normal 1, Magic 2, Rare 5, Unique 20): the boss options set 20, else "Is the enemy
-- Rare?" 5, "Is the enemy Magic?" 2, else 1. One place for every rule that takes the enemy's Power (the meta skills' Energy, Glory)
local function enemyPower(env)
	local power = env.player.modDB:GetMultiplier("EnemyPower")
	if power <= 0 then
		power = env.enemyDB:Flag(nil, "Condition:RareOrUnique") and 5 or env.enemyDB:Flag(nil, "Condition:Magic") and 2 or 1
	end
	return power
end

local function metaEnergyTrigger(env, actor)
	local mainSkill = actor.mainSkill
	local meta
	for _, skill in ipairs(env.player.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillTypes[SkillType.Meta] and skill.skillTypes[SkillType.GeneratesEnergy] then
			meta = skill
			break
		end
	end
	local metaData = meta and meta.skillData
	local modelled = false
	for _, key in ipairs(energyEvents) do
		modelled = modelled or (metaData and metaData[key] and true)
	end
	if not modelled then
		return
	end
	local metaName = meta.activeEffect.grantedEffect.name
	local required = 0
	for _, skill in ipairs(env.player.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillData.triggeredByMeta then
			required = required + (skill.activeEffect.grantedEffect.castTime or 0) * 1000 / (skill.skillData.energyPerCastTimeMs or 10)
		end
	end
	local refund = m_min(meta.skillModList:Sum("BASE", meta.skillCfg, "EnergyRefundChance"), 100)
	local cost = required * (1 - refund / 200)
	local maximum = metaData.maximumEnergyIsTotal and required or metaData.maximumEnergy and metaData.maximumEnergy * calcLib.mod(meta.skillModList, meta.skillCfg, "MaximumEnergy")
	local energyMod = calcLib.mod(meta.skillModList, meta.skillCfg, "EnergyGenerated")
	local power = enemyPower(env)

	local function hits(skill, flags) return flags.hit end
	local function meleeHits(skill, flags) return flags.hit and skill.skillTypes[SkillType.Melee] and skill.skillTypes[SkillType.Attack] end
	local function spells(skill) return skill.skillTypes[SkillType.Spell] and (skill.activeEffect.grantedEffect.castTime or 0) > 0 end

	local gain, events, lines = 0, 0, { }
	local function add(label, rate, perEvent, sourceName)
		perEvent = m_min(perEvent * energyMod, maximum or m_huge)
		gain = gain + rate * perEvent
		events = events + rate
		t_insert(lines, s_format("%.2f/s x %.1f Energy ^8(%s%s)", rate, perEvent, label, sourceName and " of " .. sourceName or ""))
	end
	if metaData.energyOnCrit or metaData.energyOnShock or metaData.energyOnIgnite then
		local source = eventSource(env, hits)
		if source then
			if metaData.energyOnCrit then
				add("Critical Hits", source.rates.crits, metaData.energyOnCrit * power * source.critPercent, source.name)
			end
			if metaData.energyOnShock then
				add("Shocks", source.rates.hits * source.shockChance / 100, metaData.energyOnShock * power, source.name)
			end
			if metaData.energyOnIgnite then
				add("Ignites", source.rates.ignites, metaData.energyOnIgnite * power * source.ignitePercent, source.name)
			end
		end
	end
	if metaData.energyOnMeleeHit then
		local source = eventSource(env, meleeHits)
		if source then
			add("Melee Hits", source.rates.hits, metaData.energyOnMeleeHit * power * source.hitPercent, source.name)
		end
	end
	if metaData.energyPer10msCastTime then
		local source = eventSource(env, spells)
		if source then
			add("Spells cast", source.speed, metaData.energyPer10msCastTime * source.castTime * 100, source.name)
		end
	end
	-- ponytail: every kill counts as a Melee kill of a Power 1 monster if the build has a Melee Attack; upgrade path = kill rate per skill
	if metaData.energyOnMeleeKill and #sourceCandidates(env, meleeHits) > 0 then
		add("kills", env.player.modDB:GetMultiplier("ApproxKillsPerSecond"), metaData.energyOnMeleeKill)
	end
	if metaData.energyOnBlock then
		add("Blocks: enemy hits on you x block chance", env.player.modDB:GetMultiplier("ApproxEnemyHitsOnYouPerSecond") * (env.player.output.BlockChance or 0) / 100, metaData.energyOnBlock)
	end

	local rate = cost > 0 and gain / cost or 0
	if #lines == 0 then
		t_insert(lines, s_format("No skill of the build gives %s Energy", metaName))
		mainSkill.infoMessage2 = s_format("No Energy source for %s: no triggers", metaName)
	else
		t_insert(lines, s_format("= %.1f ^8(Energy per second)", gain))
		t_insert(lines, s_format("/ %.1f ^8(Energy to trigger the socketed Spells: 1 per %d ms of their base cast time%s)", cost, mainSkill.skillData.energyPerCastTimeMs or 10, refund > 0 and s_format(", %d%% chance to refund half", refund) or ""))
	end
	if metaData.triggersAtMaximumEnergy and rate > events then
		rate = events
		t_insert(lines, s_format("= %.2f ^8(at most one trigger per event)", rate))
	end
	if maximum and required > maximum then
		rate = 0
		t_insert(lines, s_format("The socketed Spells need %.0f Energy, more than %s can hold (%.0f)", required, metaName, maximum))
	elseif maximum and not metaData.triggersAtMaximumEnergy and metaData.cooldown and required > 0 then
		local cooldown = m_ceil(metaData.cooldown / calcLib.mod(meta.skillModList, meta.skillCfg, "CooldownRecovery") * data.misc.ServerTickRate) / data.misc.ServerTickRate
		local perUse = m_floor(maximum / required)
		if rate > perUse / cooldown then
			rate = perUse / cooldown
			t_insert(lines, s_format("= %d / %.3f ^8(at most %d triggers per use of %s, one use per cooldown)", perUse, cooldown, perUse, metaName))
		end
	end
	return { source = meta, trigRate = rate, triggerName = metaName, sourceRateBreakdown = lines, accumulatingSource = true }
end

-- ===== Skills from items and the tree that trigger a damage skill on an interval or on events of the build =====
-- Like the supports' skills (supportTrigger), CalcPerform only calls this with Use approximations on (the triggered skill carries
-- supportTriggerChance, SkillStatMap.lua); off, PoB keeps the self-cast numbers. Everything here is an approximation: the interval or
-- Glory numbers are the game data's, but the events (enemies in a radius, Hits that fill Glory, Critical kills) are the build's own
-- rates or configured inputs. Rules, from the skill and stat descriptions:
-- * The Stars Answer (Starfall): a meteor every `walking_calamity_spawn_meteor_every_ms` (300 ms), +`..._per_enemy_in_..._radius`% (50%)
--   for each enemy in the radius after the first `..._ignore_first_x_enemies...` (1), at most +`..._cap`% (200%); every
--   `walking_calamity_large_meteor_every`th (15th) is a large one. The skill's two stat sets are the small and the large star: the
--   selected set gets its share of the meteors as its rate and the other set's damage per second (a calculation of its own, at its
--   share of the meteors) is added to Total DPS, so the total is the weighted average of both stars whichever set is selected. The
--   enemies in the radius are the configured count (default 1: no bonus).
-- * Apocalypse (Hailstorm, Meteor, Crash Lightning) and Archon of Chayula (Chayula's Will): Glory builds from Hits that deal Elemental
--   (Chaos) damage, `active_skill_generates_mp_%_glory_per_..._hit` % of the enemy's Power per Hit (the "mp" is read as Monster Power,
--   as for the meta skills' Energy), until `active_skill_requires_X_glory` (100). At full Glory the buff lasts its duration (Apocalypse's
--   12 s, Archon Buffs' 10 s, with increased Archon duration), then the Glory builds again: uptime = duration / (duration + time to
--   fill). During it, Apocalypse triggers one of three skills every `unleash_the_elements_base_trigger_frequency_ms` (750 ms, at
--   increased frequency), so each gets a third; Archon of Chayula spawns its tornado every `..._tornado_interval_ms` (3 s).
--   The Hits come from the build's skill with the most of them (eventSource), never a triggered skill.
-- * Midnight Zenith (Eventide Petals): Critical Hits with other skills that hit a Rare or Unique enemy give 2 to 7 Arctic Petals
--   (`midnight_star_gain_x_ice_seeds_when_you_critically_hit_a_rare_or_unique_enemy`), Critical Hits that kill give the dead enemy's
--   Power (pack monsters: 1);
--   10 Petals are consumed for 5 Ice Crystals ("Consumes {0} Arctic Petals to create {1} Ice Crystals"). Critical Hits per second
--   come from the build's skill with the most; the kills are the kills per second input x the share of Hits that are Critical.
--   Crystals made are at most the limit per Crystal duration.
-- ponytail: Glory is assumed to build only outside the buff, the enemy's Power per Hit is an unverified reading of "mp", the
-- Apocalypse picks its disaster evenly at random, and the damage of each triggered skill is the one PoB shows (a Hailstorm's bolts,
-- Crash Lightning's pulses, Chayula's Will's 200 ms hits for its 8 s are not multiplied by the Hits one cast makes); the large star's
-- 5 s duration isn't multiplied either (each star is one Hit of its stat set; the large star's lingering hits, if any, are missed);
-- upgrade path = in-game measurement (plan Phase 6) and a damage per cast for each of those skills.
-- The skill of the main skill's group that carries a stat's value (the parent skill, with the trigger's numbers)
local function groupSkillWith(env, mainSkill, key)
	for _, skill in ipairs(env.player.activeSkillList) do
		if skill.socketGroup == mainSkill.socketGroup and skill.skillData[key] then
			return skill
		end
	end
end
-- Average Damage of a skill's other stat set `index` (The Stars Answer's large star beside the small one), from a calculation of its own:
-- a copy of the skill with that set selected, in a new environment, as a self-cast (limited, so no trigger handler runs and nothing
-- recurses). A calculation caches itself under the skill's uuid, so the entry of the set being calculated is put back.
-- ponytail: one extra full calculation per calculation of the triggered skill (only with Use approximations on); upgrade path = share
-- the result per evaluation like cachedSourceRecord
local function statSetAverageDamage(env, skill, index)
	local effect = { }
	for key, value in pairs(skill.activeEffect) do
		effect[key] = value
	end
	effect[env.mode == "CALCS" and "statSetCalcs" or "statSet"] = { index = index }
	local newEnv = calcs.initEnv(env.build, env.mode, env.override)
	local newSkill = calcs.createActiveSkill(effect, skill.supportList, newEnv, newEnv.player, skill.socketGroup, skill.summonSkill)
	calcs.buildActiveSkillModList(newEnv, newSkill)
	newSkill.skillModList = new("ModList"):ModList(newSkill.baseSkillModList)
	local uuid = cacheSkillUUID(newSkill, newEnv)
	newEnv.limitedSkills = newEnv.limitedSkills or { }
	newEnv.limitedSkills[uuid] = true
	newEnv.player.mainSkill = newSkill
	local cache = GlobalCache.cachedData[env.mode]
	local saved = cache[uuid]
	calcs.perform(newEnv, true)
	cache[uuid] = saved
	return newEnv.player.output.AverageDamage or 0, newSkill.activeEffect.grantedEffect.statSets[index] and newSkill.activeEffect.grantedEffect.statSets[index].label
end
-- Share of time a Glory buff of `duration` seconds is up, from the Hits per second of the build's skill that deals the right damage
-- (record[dealsKey], sourceRecord): the Glory fills at Hits per second x percent of the enemy's Power per Hit. Returns the uptime
-- (0 without such Hits), the source skill and breakdown lines
local function gloryUptime(env, parent, percentKey, dealsKey, duration, damageName)
	local percent, required = parent.skillData[percentKey] or 0, parent.skillData.gloryRequired or 0
	local record, skill = eventSource(env, function(_, flags) return flags.hit end, function(record) return record[dealsKey] and record.rates.hits or 0 end)
	local hits = record and record[dealsKey] and record.rates.hits or 0
	local power = enemyPower(env)
	local glory = hits * percent / 100 * power
	if glory <= 0 or required <= 0 then
		return 0, nil, { s_format("No skill of the build Hits with %s damage to build Glory for %s", damageName, parent.activeEffect.grantedEffect.name) }
	end
	local fill = required / glory
	local uptime = duration / (duration + fill)
	return uptime, skill, {
		s_format("%.2f x %g%% x %g ^8(%s Hits per second of %s x %% of the enemy's Power as Glory per Hit x Power)", hits, percent, power, damageName, record.name),
		s_format("= %.2f ^8(Glory per second)", glory),
		s_format("%g / %.2f = %.1f s ^8(time to fill the Glory)", required, glory, fill),
		s_format("%.1f / (%.1f + %.1f) = %.3f ^8(uptime of the %.1f s buff)", duration, duration, fill, uptime, duration),
	}
end
local function intervalTrigger(env, actor)
	local mainSkill = actor.mainSkill
	local skillData = mainSkill.skillData
	local modDB = env.player.modDB
	local source, rate, lines, parent
	if skillData.intervalStarfall then
		parent = groupSkillWith(env, mainSkill, "walkingCalamityIntervalMs")
		if parent then
			local data = parent.skillData
			local enemies = m_max(modDB:GetMultiplier("ApproxEnemiesAroundYou"), 0)
			local more = m_min((data.walkingCalamityPerEnemy or 0) * m_max(enemies - (data.walkingCalamityIgnoreFirst or 0), 0), data.walkingCalamityCap or m_huge)
			local meteors = 1000 / data.walkingCalamityIntervalMs * (1 + more / 100)
			local every = m_max(data.walkingCalamityLargeEvery or 1, 1)
			-- the skill's second stat set is the large star (the first one is the small star)
			local effect = mainSkill.activeEffect
			local large = (env.mode == "CALCS" and effect.statSetCalcs or effect.statSet).index == 2
			local share = large and 1 / every or (every - 1) / every
			source, rate = parent, meteors * share
			lines = {
				s_format("1000 / %g ms x (1 + %g%%) = %.2f ^8(meteors per second; %g enemies around you, +%g%% for each after the first %g, at most +%g%%)", data.walkingCalamityIntervalMs, more, meteors, enemies, data.walkingCalamityPerEnemy or 0, data.walkingCalamityIgnoreFirst or 0, data.walkingCalamityCap or 0),
				s_format("x %.3f ^8(%s)", share, large and s_format("1 in %g meteors is a large star, this stat set", every) or "the other meteors are small stars, this stat set"),
			}
			-- Offence takes the Hit rate from the skill's own "hit time" (the meteor interval, 0.3 s, the large star's 2 s) and no mod can
			-- remove it, so the DPS multiplier turns that rate into the rate calculated here (Hit rate x hit time x rate / hit time)
			-- (from the skill's own multiplier each time: a second pass over the same skill must not compound it)
			local hitTime = skillData.hitTimeOverride
			if hitTime then
				skillData.baseDpsMultiplier = skillData.baseDpsMultiplier or skillData.dpsMultiplier or 1
				skillData.dpsMultiplier = skillData.baseDpsMultiplier * rate * hitTime
			end
			-- the other stat set's meteors (the large star's 1 in 15, or the small ones) deal their own damage: added to this skill's Total DPS
			-- (CalcOffence.lua, otherStatSetDps) at the full meteor rate, so the total is the weighted average of both sets per meteor
			local otherAverage, otherName = statSetAverageDamage(env, mainSkill, large and 1 or 2)
			skillData.otherStatSetDps = otherAverage * meteors * (1 - share)
			skillData.otherStatSetInfo = s_format("%.1f %s average damage x %.2f meteors per second x %.3f", otherAverage, otherName or "other stat set", meteors, 1 - share)
		end
	elseif skillData.intervalUnleash or skillData.intervalChayula then
		local unleash = skillData.intervalUnleash
		parent = groupSkillWith(env, mainSkill, unleash and "unleashIntervalMs" or "gloryPerChaosHit")
		if parent then
			local parentData = parent.skillData
			local duration, uptime, glorySkill, gloryLines
			local interval, count
			if unleash then
				duration = (parentData.duration or 0) * calcLib.mod(parent.skillModList, parent.skillCfg, "Duration")
				uptime, glorySkill, gloryLines = gloryUptime(env, parent, "gloryPerElementalHit", "dealsElemental", duration, "Elemental")
				interval = parentData.unleashIntervalMs / calcLib.mod(parent.skillModList, parent.skillCfg, "UnleashFrequency")
				count = 0
				for _, skill in ipairs(env.player.activeSkillList) do
					count = count + (skill.socketGroup == mainSkill.socketGroup and skill.skillData.intervalUnleash and 1 or 0)
				end
			else
				duration = data.archonBuffs.ArchonOfChayula.duration * calcLib.mod(modDB, nil, "ArchonDuration")
				uptime, glorySkill, gloryLines = gloryUptime(env, parent, "gloryPerChaosHit", "dealsChaos", duration, "Chaos")
				interval, count = 0, 1
				for _, stat in ipairs(parent.activeEffect.grantedEffect.statSets[1].constantStats) do
					if stat[1] == "archon_of_chayula_spawn_chaos_tornado_interval_ms" then
						interval = stat[2]
					end
				end
			end
			lines = gloryLines
			if uptime > 0 and interval > 0 then
				rate = 1000 / interval * uptime / m_max(count, 1)
				t_insert(lines, s_format("1000 / %.0f ms x %.3f%s = %.3f ^8(triggers of %s per second: every interval while the buff lasts, x uptime)", interval, uptime, count > 1 and s_format(" / %d", count) or "", rate, mainSkill.activeEffect.grantedEffect.name))
			end
			source = glorySkill or parent
		end
	elseif skillData.intervalMidnight then
		parent = mainSkill
		local record, skill = eventSource(env, function(skill, flags) return flags.hit and skill ~= mainSkill end, function(record) return record.rates.crits end)
		if record then
			local rare = env.enemyDB:Flag(nil, "Condition:RareOrUnique")
			local kills = modDB:GetMultiplier("ApproxKillsPerSecond")
			local critKills = m_min(kills * (record.rates.hits > 0 and record.rates.crits / record.rates.hits or 0), record.rates.crits)
			-- (the killed enemies are pack monsters of Power 1, as for the meta skills' kill Energy)
			local petals = (rare and record.rates.crits * (skillData.midnightSeedsOnRareCrit or 0) or 0) + critKills
			local perAttempt = skillData.midnightSeedsPerAttempt or 0
			local crystals = perAttempt > 0 and petals / perAttempt * (skillData.midnightCrystalsPerAttempt or 0) or 0
			local limit = (skillData.duration or 0) > 0 and (skillData.midnightMaxCrystals or m_huge) / skillData.duration or m_huge
			source, rate = skill, m_min(crystals, limit)
			lines = {
				s_format("%.2f ^8(Critical Hits per second of %s, the skill with the most)", record.rates.crits, record.name),
				s_format("%.2f x %g + %.2f = %.2f ^8(Arctic Petals per second: Critical Hits x Petals for a Rare or Unique enemy%s + Critical kills, Power 1 each)", rare and record.rates.crits or 0, skillData.midnightSeedsOnRareCrit or 0, critKills, petals, rare and "" or ", which the enemy isn't"),
				s_format("/ %g x %g = %.2f ^8(Ice Crystals per second: Petals per attempt, Crystals created per attempt)", perAttempt, skillData.midnightCrystalsPerAttempt or 0, crystals),
			}
			if crystals > limit then
				t_insert(lines, s_format("= %.2f ^8(at most %g Crystals per %.1f s Crystal duration)", limit, skillData.midnightMaxCrystals or 0, skillData.duration or 0))
			end
		end
	else
		return
	end
	if not parent then
		return
	end
	local name = parent.activeEffect.grantedEffect.name
	lines = lines or { }
	t_insert(lines, 1, "Approximation (Use approximations on): see the rules in CalcTriggers.lua, intervalTrigger")
	mainSkill.infoMessage2 = "Approximation: trigger rate from " .. (skillData.intervalMidnight and "the build's Critical Hits" or name .. "'s interval and events")
	return { source = source or mainSkill, trigRate = rate or 0, triggerName = name, sourceRateBreakdown = lines, accumulatingSource = true }
end
-- ===== end of the interval triggers =====

-- Supports that grant a skill of their own and trigger it on an event of the skill they support in the same group. Like the meta
-- skills' Energy, CalcPerform only calls this with Use approximations on; off, PoB keeps the granted skill's self-cast rate. Rules,
-- from the support and skill descriptions:
-- * The source is the supported skill of the group (it carries "triggerChance:<granted skill>", SkillStatMap.lua) with the most
--   triggering events per second, never a triggered skill. Chance per event = the support's chance (Fiery Death 60%, others 100%)
--   x the granted skill's own "triggered by" chance (100%).
-- * Mana Flare: the source's Critical Hits per second. Coursing Current, Static Shocks: its Hits x Shock chance.
--   Fan the Flames I / II, Volcanic Eruption: its Hits x the share of time the enemy is Ignited: 1 with "Is the enemy Ignited?",
--   else 1 - e^(-Ignites/s x Ignite duration) from the source's own Ignites (calcLib.approxUptime).
--   Fiery Death: kills per second x that share. Impending Doom's Doom Blast ("when the Curse expires"): one per Curse duration,
--   at most the curse's cast rate.
-- * A rule with `source` (Elemental Storm, a Stormweaver node's skill) takes the Spell of the whole build with the most events,
--   not the group's supported skill; the node line marks the skill through ExtraSkillMod (ModParser.lua).
-- * The granted skill's cooldown caps the rate (defaultTriggerHandler: server ticks; with stored uses min(rate, 1 / cooldown), with
--   one use the cooldown alignment simulation); without a cooldown each event triggers.
-- ponytail: Critical Hits and Shocks are random, the simulation spaces them evenly; Hits on the one target PoB calculates, all kills
-- by the supported skill, Ignites only from the source itself, and a Curse recast as it expires (its delay ignored); upgrade path =
-- the in-game checks of plan Phase 6.
local supportTriggerEvents = {
	{ key = "supportTriggerOnCrit", name = "Critical Hits", rate = function(env, source)
		return source.rates.crits, s_format("%.2f ^8(Critical Hits per second of %s)", source.rates.crits, source.name)
	end },
	{ key = "supportTriggerOnShock", name = "Shocks", rate = function(env, source)
		return source.rates.hits * source.shockChance / 100, s_format("%.2f x %.2f%% ^8(Hits per second x Shock chance of %s)", source.rates.hits, source.shockChance, source.name)
	end },
	{ key = "supportTriggerOnLightningHit", name = "Hits that deal Lightning damage", rate = function(env, source)
		local hits = source.dealsLightning and source.rates.hits or 0
		return hits, s_format("%.2f ^8(Hits per second of %s%s)", hits, source.name, source.dealsLightning and "" or ", which deals no Lightning damage")
	end },
	{ key = "supportTriggerOnHitVsIgnited", name = "Hits against Ignited enemies", rate = function(env, source, ignited, ignitedText)
		return source.rates.hits * ignited, s_format("%.2f x %.3f ^8(Hits per second of %s x %s)", source.rates.hits, ignited, source.name, ignitedText)
	end },
	{ key = "supportTriggerOnIgnitedKill", name = "Ignited enemies dying", rate = function(env, source, ignited, ignitedText)
		local kills = env.player.modDB:GetMultiplier("ApproxKillsPerSecond")
		return kills * ignited, s_format("%.2f x %.3f ^8(kills per second x %s)", kills, ignited, ignitedText)
	end },
	-- Elemental Storm (Stormweaver node, "Trigger Elemental Storm on Critical Hit with Spells"): a rule with `source` takes its source
	-- from the whole build, the Spell with the most Critical Hits per second, not from the group (a node is not tied to a socket group)
	-- "Hits which do not deal Elemental Damage will not Trigger the storm" (skill description, poe2db): `record` leaves out a Spell
	-- whose calculation deals no Elemental damage, `gem` is the same test on a gem's skill types for the optimiser's source search.
	-- ponytail: every Critical Hit of an elemental Spell counts (PoB's average Hit has all its damage types), and the storm's element
	-- (the Hit's highest Elemental type, named in the line) is the selected stat set's, not chosen from the source; upgrade path = the
	-- optimiser's chooseStatSet following record.element
	{ key = "supportTriggerOnSpellCrit", name = "Critical Hits with Spells that deal Elemental damage", source = function(skill, flags)
		return flags.hit and skill.skillTypes[SkillType.Spell]
	end, record = function(record)
		return record.dealsElemental
	end, gem = function(types)
		return types[SkillType.Fire] or types[SkillType.Cold] or types[SkillType.Lightning]
	end, rate = function(env, source)
		return source.rates.crits, s_format("%.2f ^8(Critical Hits per second of %s, the Spell with the most that deals Elemental damage; its highest type is %s)", source.rates.crits, source.name, source.element)
	end },
	{ key = "supportTriggerOnCurseExpiry", name = "Curse expiries", rate = function(env, source)
		local rate = m_min(source.speed, source.duration > 0 and 1 / source.duration or 0)
		return rate, s_format("min(%.2f, 1 / %.2f) ^8(cast rate of %s, once per Curse duration)", source.speed, source.duration, source.name)
	end },
}

-- Skills of items and nodes that trigger on what happens to you (rules with `build`: the rate comes from the approximation inputs,
-- not from a skill of the build; the skill is its own source). Only with Use approximations on, as above.
-- * Valako's Charge (Lightning Coil): "taking Lightning damage builds up charge ... Reaching full charge expends all charge to Trigger
--   this skill" (cast_on_damage_taken_threshold, in its first stat set: the damage that fills the charge; 100% chance). Rate = enemy
--   Hits on you per second x the share of them that deal Lightning damage x the share of the charge one such Hit fills (at most 1: all
--   charge is spent at once, so a Hit triggers at most once).
-- ponytail: a Lightning Hit deals the enemy Lightning damage of the configuration (the default enemy hit) less your Lightning
--   resistance, none of your other damage taken modifiers; upgrade path = the Lightning damage taken from the defence calculation
--   (the optimizer skips it by default).
t_insert(supportTriggerEvents, { key = "supportTriggerOnLightningDamageTaken", name = "Lightning damage taken", build = function(env, skill)
	local effect = skill.activeEffect
	local first = effect.grantedEffect.statSets[1]
	local threshold = 0
	for index, stat in ipairs(first.stats) do
		if stat == "cast_on_damage_taken_threshold" then
			threshold = first.levels[effect.level] and first.levels[effect.level][index] or 0
		end
	end
	local hits = env.player.modDB:GetMultiplier("ApproxEnemyHitsOnYouPerSecond")
	local share = env.player.modDB:GetMultiplier("ApproxEnemyLightningHitShare")
	local enemyDamage = tonumber(env.configInput.enemyLightningDamage) or tonumber(env.configPlaceholder.enemyLightningDamage) or 0
	local damage = enemyDamage * (1 - (env.player.output.LightningResist or 0) / 100)
	local filled = threshold > 0 and enemyDamage > 0 and m_min(damage / threshold, 1) or 1
	return hits * share / 100 * filled, {
		s_format("%.2f x %.0f%% ^8(enemy Hits on you per second x share of them that deal Lightning damage; an approximation)", hits, share),
		s_format("x %.2f ^8(share of the charge one Lightning Hit fills: %.0f Lightning damage taken / %.0f to fill it, at most 1)", filled, damage, threshold),
	}
end })
-- * Void Illusion (tree node): a copy of you is made on each dodge roll, and a copy an enemy destroys explodes (the node's hidden
--   skill VoidIllusionSpawnPlayer, one explosion per copy destroyed). Rate = the lower of dodge rolls and enemy Hits on you per
--   second (a copy has 1 Life and lasts 2 s, so an enemy Hit on it destroys it: every Hit on a copy counts as a Hit on you).
-- ponytail: every enemy Hit is taken to land on a copy while copies exist; upgrade path = copies alive (rolls x duration) x the share
--   of enemy attacks that pick a copy as target, measured in the game
t_insert(supportTriggerEvents, { key = "supportTriggerOnCopyDestroyed", name = "Illusions destroyed by enemies", build = function(env)
	local rolls = env.player.modDB:GetMultiplier("ApproxDodgeRollsPerSecond")
	local hits = env.player.modDB:GetMultiplier("ApproxEnemyHitsOnYouPerSecond")
	return m_min(rolls, hits), { s_format("min(%.2f, %.2f) ^8(dodge rolls per second, enemy Hits on you per second: one copy per roll, destroyed by an enemy Hit; an approximation)", rolls, hits) }
end })
-- * Elemental Expression (Invoker node, "Trigger Elemental Expression on Melee Critical Hit"): the Melee Attack of the whole build
--   with the most Critical Hits per second (a source rule, like Elemental Storm). The skill's stat sets are the three outcomes, each
--   with the chance proportional to an attribute: explosion (Fire) Strength, wave (Cold) Intelligence, bolt (Lightning)
--   Dexterity, as that attribute's share of Strength + Dexterity + Intelligence; the first set (the roll itself) takes them all.
-- ponytail: "proportional" is read as a plain share of the three attributes (the description gives no formula); upgrade path = the
--   game's formula, if one is found
local expressionAttributes = { ["Fiery Explosion"] = "Str", ["Arcing Bolt"] = "Dex", ["Icy Wave"] = "Int" }
t_insert(supportTriggerEvents, { key = "supportTriggerOnMeleeCrit", name = "Critical Hits with Melee Attacks", source = function(skill, flags)
	return flags.hit and skill.skillTypes[SkillType.Melee] and skill.skillTypes[SkillType.Attack]
end, rate = function(env, source)
	return source.rates.crits, s_format("%.2f ^8(Critical Hits per second of %s, the Melee Attack with the most)", source.rates.crits, source.name)
end, chance = function(env, skill)
	local effect = skill.activeEffect
	local set = effect.grantedEffect.statSets[(env.mode == "CALCS" and effect.statSetCalcs or effect.statSet).index]
	local attribute = expressionAttributes[set and set.label]
	if not attribute then
		return 1
	end
	local output = env.player.output
	local total = (output.Str or 0) + (output.Dex or 0) + (output.Int or 0)
	local share = total > 0 and (output[attribute] or 0) / total or 0
	return share, s_format("x %.1f%% ^8(%s of %.0f Strength + Dexterity + Intelligence: the chance for the %s is proportional to it; an approximation)", share * 100, attribute, total, set.label)
end })

-- (the optimiser reads the rules with a `source`: it adds a source skill for a skill marked with one; after all rules are added)
calcs.supportTriggerEvents = supportTriggerEvents
local function supportTrigger(env, actor)
	local mainSkill = actor.mainSkill
	-- skills of items and the tree with an interval or events of their own (above)
	local interval = intervalTrigger(env, actor)
	if interval then
		return interval
	end
	local event
	for _, rule in ipairs(supportTriggerEvents) do
		if mainSkill.skillData[rule.key] then
			event = rule
			break
		end
	end
	if not event then
		return
	end
	local triggeredName = mainSkill.activeEffect.grantedEffect.name
	local chanceKey = "triggerChance:" .. triggeredName
	local srcInstance = mainSkill.activeEffect.srcInstance
	local supportName = srcInstance and srcInstance.gemData and srcInstance.gemData.name or triggeredName
	local ignitedConfigured = env.enemyDB:Flag(nil, "Condition:Ignited")
	local source, rate, lines, triggeredSource = nil, 0, { }, nil
	if event.source then -- (the loop below then finds no group skill: nothing carries "triggerChance:" for this skill)
		local record, skill = eventSource(env, event.source, function(record) return record.rates.crits end, event.record)
		if record then
			local events, line = event.rate(env, record)
			source, rate, lines = skill, events, { line }
			if event.chance then
				local share, chanceLine = event.chance(env, mainSkill)
				rate = rate * share
				if chanceLine then
					t_insert(lines, chanceLine)
				end
			end
		end
	elseif event.build then
		-- (the rate comes from the approximation inputs, the skill is its own source)
		local events, eventLines = event.build(env, mainSkill)
		source, rate, lines = mainSkill, events, eventLines
	end
	for _, skill in ipairs(env.player.activeSkillList) do
		local flags = (env.mode == "CALCS" and skill.activeEffect.statSetCalcs or skill.activeEffect.statSet).skillFlags
		local chance = skill.skillData[chanceKey]
		if chance and skill ~= mainSkill and skill.socketGroup == mainSkill.socketGroup and flags and not flags.disable and isTriggered(skill) then
			triggeredSource = skill
		elseif chance and skill ~= mainSkill and skill.socketGroup == mainSkill.socketGroup and flags and not flags.disable then
			local record = cachedSourceRecord(env, skill)
			if record then
				local ignited, ignitedText = 1, "the enemy is Ignited"
				-- Fiery Death: "enemies it Ignites", so the configured Ignite only counts for a source that can Ignite
				if not ignitedConfigured or event.key == "supportTriggerOnIgnitedKill" and record.rates.ignites == 0 then
					ignited = calcLib.approxUptime(record.rates.ignites, record.igniteDuration)
					ignitedText = s_format("share of time Ignited, 1 - e^(-%.2f Ignites/s x %.2f s)", record.rates.ignites, record.igniteDuration)
				end
				local events, line = event.rate(env, record, ignited, ignitedText)
				chance = m_min(chance * (mainSkill.skillData.supportTriggerChance or 100) / 100, 100)
				if not source or events * chance / 100 > rate then
					source, rate = skill, events * chance / 100
					lines = { line }
					if chance < 100 then
						t_insert(lines, s_format("x %d%% ^8(chance to trigger %s)", chance, triggeredName))
					end
				end
			end
		end
	end
	-- no supported skill and a supported skill without the event both trigger 0 times; a triggered skill is never a source
	-- ponytail: a meta-triggered Spell's Critical Hits may trigger Mana Flare in the game (plan Phase 6); upgrade path = its trigger rate
	if not source and triggeredSource then
		lines = { s_format("%s is triggered: triggers by a triggered skill are not modelled", triggeredSource.activeEffect.grantedEffect.name) }
	elseif not source then
		lines = { event.source and s_format("No skill of the build has %s", event.name) or s_format("No skill in the group is supported by %s", supportName) }
	end
	if rate == 0 then
		mainSkill.infoMessage2 = not source and triggeredSource and "Supported skill is triggered: no triggers modelled" or s_format("No %s to trigger %s: no triggers", event.name, triggeredName)
	end
	-- nothing to align without a cooldown: every event triggers (the simulation would only add rounding)
	return { source = source or mainSkill, trigRate = rate, triggerName = supportName, sourceRateBreakdown = lines, accumulatingSource = not mainSkill.skillData.cooldown }
end

function calcs.triggers(env, actor)
	local skillFlags
	if env.mode == "CALCS" then
		skillFlags = actor.mainSkill.activeEffect.statSetCalcs.skillFlags
	else
		skillFlags = actor.mainSkill.activeEffect.statSet.skillFlags
	end
	if actor and not skillFlags.disable and not (env.limitedSkills and env.limitedSkills[cacheSkillUUID(actor.mainSkill, env)]) then
		local skillName = actor.mainSkill.activeEffect.grantedEffect.name
		local triggerName = actor.mainSkill.triggeredBy and actor.mainSkill.triggeredBy.grantedEffect.name
		local uniqueName = isTriggered(actor.mainSkill) and getUniqueItemTriggerName(actor.mainSkill)
		local skillNameLower = skillName and skillName:lower()
		local triggerNameLower = triggerName and triggerName:lower()
		local awakenedTriggerNameLower = triggerNameLower and triggerNameLower:gsub("^awakened ", "")
		local uniqueNameLower = uniqueName and uniqueName:lower()
		local config
		if actor == env.player then
			-- PoE2: CalcPerform calls this for the player only for Spells triggered by a meta skill's Energy and skills a support grants
			-- and triggers (the handlers use activeSkill.skillFlags, which PoE2 keeps per stat set)
			actor.mainSkill.skillFlags = actor.mainSkill.skillFlags or skillFlags
			config = actor.mainSkill.skillData.supportTriggerChance and supportTrigger(env, actor) or metaEnergyTrigger(env, actor)
		else
			config = skillNameLower and configTable[skillNameLower] and configTable[skillNameLower](env)
			config = config or triggerNameLower and configTable[triggerNameLower] and configTable[triggerNameLower](env)
			config = config or awakenedTriggerNameLower and configTable[awakenedTriggerNameLower] and configTable[awakenedTriggerNameLower](env)
			config = config or uniqueNameLower and configTable[uniqueNameLower] and configTable[uniqueNameLower](env)
		end
		if config then
		    config.actor = config.actor or actor
			config.triggerName = config.triggerName or triggerName or skillName or uniqueName
			config.triggerChance = config.triggerChance or (actor.mainSkill.activeEffect.srcInstance and actor.mainSkill.activeEffect.srcInstance.triggerChance)
			local triggerHandler = config.customHandler or defaultTriggerHandler
		    triggerHandler(env, config)
		else
			actor.mainSkill.skillData.triggered = nil
        end
	end
end
