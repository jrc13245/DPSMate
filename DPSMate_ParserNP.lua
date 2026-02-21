-- DPSMate_ParserNP.lua
-- Nampower/SuperWoW structured event handlers for DPSMate
-- Replaces string-based CHAT_MSG_* parsing when Nampower+SuperWoW are available
-- Falls back to existing parser when not available
--
-- Nampower version history:
--   v2.24+  AUTO_ATTACK_SELF/OTHER (NP_EnableAutoAttackEvents CVar)
--   v2.30+  SPELL_HEAL_BY_SELF/OTHER (NP_EnableSpellHealEvents CVar)
--   v2.31+  SPELL_DAMAGE_EVENT_SELF/OTHER, SPELL_MISS_SELF/OTHER
--   v2.40+  Packed GUID parsing fix: targetGuid in all events now returns the
--           correct hex string for friendly player targets (previously was
--           "0x0000000000000000" for some players). Benefits AUTO_ATTACK,
--           SPELL_DAMAGE_EVENT, and SPELL_MISS events automatically — no code
--           change required; ResolveName() will now succeed where it previously
--           returned nil and dropped the event.

local DB = DPSMate.DB
local AAttack = "AutoAttack"
local floor = math.floor
local mod = math.mod

----------------------------------------------------------------------------------
--------------            Feature Detection                       --------------
----------------------------------------------------------------------------------

local hasNampower = false
local hasSuperWoW = false
local npMajor, npMinor, npPatch = 0, 0, 0

local function NPVersionAtLeast(major, minor, patch)
	if npMajor > major then return true end
	if npMajor == major and npMinor > minor then return true end
	if npMajor == major and npMinor == minor and npPatch >= patch then return true end
	return false
end

local function HasFlag(value, flag)
	return mod(floor(value / flag), 2) == 1
end

----------------------------------------------------------------------------------
--------------            Spell / GUID Resolution                 --------------
----------------------------------------------------------------------------------

-- Spell school mapping (Nampower numeric -> DPSMate string)
local schoolMap = {
	[0] = "physical",
	[1] = "holy",
	[2] = "fire",
	[3] = "nature",
	[4] = "frost",
	[5] = "shadow",
	[6] = "arcane",
}

-- Spell name cache
local spellNameCache = {}
local function GetSpellName(spellId)
	if not spellId or spellId == 0 then return "Unknown" end
	if type(spellId) ~= "number" then spellId = tonumber(spellId); if not spellId then return "Unknown" end end
	if spellNameCache[spellId] then return spellNameCache[spellId] end
	-- SpellInfo is from SuperWoW
	if SpellInfo then
		local ok, name = pcall(SpellInfo, spellId)
		if ok and name then
			spellNameCache[spellId] = name
			return name
		end
	end
	-- GetSpellRecField is from Nampower v2.8+
	if GetSpellRecField then
		local ok, name = pcall(GetSpellRecField, spellId, "name")
		if ok and name then
			spellNameCache[spellId] = name
			return name
		end
	end
	return "Unknown"
end

-- GUID to name resolution
-- Following SuperCleveRoidMacros pattern: build cache from unit tokens,
-- fall back to UnitName(guid) only as last resort with pcall safety
local guidCache = {}

local function NormalizeGUID(guid)
	if not guid then return nil end
	return tostring(guid)
end

-- Scan all known unit tokens and cache their GUIDs
local ownerCache = {}

local function RefreshGUIDCache()
	ownerCache = {}
	local name, _, guid
	-- Player
	_, guid = UnitExists("player")
	if guid then
		name = UnitName("player")
		if name then guidCache[NormalizeGUID(guid)] = name end
	end
	-- Pet
	_, guid = UnitExists("playerpet")
	if guid then
		name = UnitName("playerpet")
		if name then guidCache[NormalizeGUID(guid)] = name end
	end
	-- Target
	_, guid = UnitExists("target")
	if guid then
		name = UnitName("target")
		if name then guidCache[NormalizeGUID(guid)] = name end
	end
	-- Raid members
	local numRaid = GetNumRaidMembers()
	if numRaid > 0 then
		for i = 1, numRaid do
			local unit = "raid"..i
			_, guid = UnitExists(unit)
			if guid then
				name = UnitName(unit)
				if name then guidCache[NormalizeGUID(guid)] = name end
			end
			-- Raid pets
			local petUnit = "raidpet"..i
			_, guid = UnitExists(petUnit)
			if guid then
				name = UnitName(petUnit)
				if name then guidCache[NormalizeGUID(guid)] = name end
			end
		end
	else
		-- Party members
		local numParty = GetNumPartyMembers()
		for i = 1, numParty do
			local unit = "party"..i
			_, guid = UnitExists(unit)
			if guid then
				name = UnitName(unit)
				if name then guidCache[NormalizeGUID(guid)] = name end
			end
			local petUnit = "partypet"..i
			_, guid = UnitExists(petUnit)
			if guid then
				name = UnitName(petUnit)
				if name then guidCache[NormalizeGUID(guid)] = name end
			end
		end
	end
end

local function ResolveName(guid)
	if not guid then return nil end
	local key = NormalizeGUID(guid)
	if guidCache[key] then return guidCache[key] end

	-- Try matching against current target
	local _, targetGUID = UnitExists("target")
	if targetGUID and NormalizeGUID(targetGUID) == key then
		local name = UnitName("target")
		if name then
			guidCache[key] = name
			return name
		end
	end

	-- Last resort: SuperWoW UnitName(guid) with pcall
	if hasSuperWoW then
		local ok, name = pcall(UnitName, guid)
		if ok and name and name ~= "Unknown" then
			guidCache[key] = name
			return name
		end
	end

	return nil
end

local function ResolveOwner(guid)
	if not guid then return nil end
	local key = NormalizeGUID(guid)
	if ownerCache[key] ~= nil then return ownerCache[key] end
	local ok, exists, ownerGuid = pcall(UnitExists, guid .. "owner")
	if ok and exists and ownerGuid then
		local ownerName = ResolveName(ownerGuid)
		if ownerName then
			ownerCache[key] = ownerName
			return ownerName
		end
	end
	ownerCache[key] = false
	return nil
end

----------------------------------------------------------------------------------
--------------            HitInfo / VictimState Constants         --------------
----------------------------------------------------------------------------------

-- HitInfo bitmask flags (for AUTO_ATTACK events, from SMSG_ATTACKERSTATEUPDATE)
local HITINFO_MISS        = 16
local HITINFO_CRITICALHIT = 128
local HITINFO_GLANCING    = 16384
local HITINFO_CRUSHING    = 32768

-- Spell hit type flags (for SPELL_DAMAGE_EVENT, from SPELL_HIT_TYPE enum)
-- hitInfo = 2 for crits, 0 for normal hits
local SPELL_HIT_TYPE_CRIT = 2

-- VictimState values (not bitmask, plain enum)
local VICTIMSTATE_NORMAL    = 1
local VICTIMSTATE_DODGE     = 2
local VICTIMSTATE_PARRY     = 3
local VICTIMSTATE_BLOCKS    = 5
local VICTIMSTATE_EVADES    = 6
local VICTIMSTATE_IS_IMMUNE = 7
local VICTIMSTATE_DEFLECTS  = 8  -- attack was deflected; treat as miss

-- MissInfo values (not bitmask, plain enum) — SpellMissInfo server enum
local MISSINFO_MISS    = 1
local MISSINFO_RESIST  = 2
local MISSINFO_DODGE   = 3
local MISSINFO_PARRY   = 4
local MISSINFO_BLOCK   = 5
local MISSINFO_EVADE   = 6
local MISSINFO_IMMUNE  = 7
local MISSINFO_IMMUNE2 = 8  -- immune variant (same treatment as IMMUNE)
local MISSINFO_DEFLECT = 9  -- projectile deflected; count as miss
local MISSINFO_ABSORB  = 10
local MISSINFO_REFLECT = 11 -- spell reflected back to caster; count as miss

----------------------------------------------------------------------------------
--------------            Parser Frame & Events                   --------------
----------------------------------------------------------------------------------

local NPParser = CreateFrame("Frame", "DPSMate_ParserNP", UIParent)
local Player = ""
local TP -- TargetParty reference

-- Events to unregister from the string parser when Nampower handles them
local autoAttackEvents = {
	"CHAT_MSG_COMBAT_SELF_HITS",
	"CHAT_MSG_COMBAT_SELF_MISSES",
	"CHAT_MSG_COMBAT_PARTY_HITS",
	"CHAT_MSG_COMBAT_PARTY_MISSES",
	"CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS",
	"CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES",
	"CHAT_MSG_COMBAT_PET_HITS",
	"CHAT_MSG_COMBAT_PET_MISSES",
	"CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS",
	"CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES",
	"CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS",
	"CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
	"CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS",
	"CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES",
	"CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS",
	"CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES",
}

local spellDamageEvents = {
	"CHAT_MSG_SPELL_SELF_DAMAGE",
	"CHAT_MSG_SPELL_PARTY_DAMAGE",
	"CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PET_DAMAGE",
	"CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE",
	"CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE",
	"CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE",
}

local petStringEvents = {
	"CHAT_MSG_COMBAT_PET_HITS",
	"CHAT_MSG_COMBAT_PET_MISSES",
	"CHAT_MSG_SPELL_PET_DAMAGE",
}

local petRawEvents = {
	["CHAT_MSG_COMBAT_PET_HITS"] = "hits",
	["CHAT_MSG_COMBAT_PET_MISSES"] = "misses",
	["CHAT_MSG_SPELL_PET_DAMAGE"] = "spelldamage",
}

-- Remove event from DPSMate.Events table so Disable/Enable cycle stays consistent
local function RemoveFromEventsTable(eventName)
	for i, v in ipairs(DPSMate.Events) do
		if v == eventName then
			tremove(DPSMate.Events, i)
			return
		end
	end
end

local function UnregisterStringParserEvents(eventList)
	for _, ev in ipairs(eventList) do
		DPSMate.Parser:UnregisterEvent(ev)
		DPSMate.Parser[ev] = nil -- remove handler so re-registration is a no-op
		RemoveFromEventsTable(ev)
	end
end

----------------------------------------------------------------------------------
--------------            Friendly Check                          --------------
----------------------------------------------------------------------------------

local function IsFriendly(name)
	if not name then return false end
	if name == Player then return true end
	if TP and TP[name] then return true end
	return false
end

----------------------------------------------------------------------------------
--------------            AUTO_ATTACK Handlers                    --------------
----------------------------------------------------------------------------------

local function HandleAutoAttack(attackerGuid, targetGuid, totalDamage, hitInfo, victimState, subDamageCount, blockedAmount, totalAbsorb, totalResist)
	local attackerName = ResolveName(attackerGuid)
	local targetName = ResolveName(targetGuid)
	if not attackerName or not targetName then return end

	local ownerName = ResolveOwner(attackerGuid)
	if ownerName then
		DB:BuildUser(attackerName)
		DB:BuildUser(ownerName)
		DPSMateUser[attackerName][4] = true
		DPSMateUser[attackerName][6] = DPSMateUser[ownerName][1]
		DPSMateUser[ownerName][5] = attackerName
	end

	local attackerFriendly = IsFriendly(ownerName or attackerName)
	local targetOwnerName = ResolveOwner(targetGuid)
	local targetFriendly = IsFriendly(targetName) or IsFriendly(targetOwnerName)

	-- Determine hit type from hitInfo bitmask
	local hit, crit, glance, crush, block = 0, 0, 0, 0, 0
	local miss, parry, dodge = 0, 0, 0
	local amount = totalDamage or 0

	-- Check for miss via hitInfo flag
	if HasFlag(hitInfo, HITINFO_MISS) then
		miss = 1
		amount = 0
	-- Check for miss types via victimState
	elseif victimState == VICTIMSTATE_DODGE then
		dodge = 1
		amount = 0
	elseif victimState == VICTIMSTATE_PARRY then
		parry = 1
		amount = 0
	elseif victimState == VICTIMSTATE_BLOCKS then
		block = 1
		amount = 0
	elseif victimState == VICTIMSTATE_EVADES or victimState == VICTIMSTATE_IS_IMMUNE then
		return -- skip evade/immune (no meaningful stat to record)
	elseif victimState == VICTIMSTATE_DEFLECTS then
		miss = 1
		amount = 0
	elseif amount > 0 then
		-- Normal hit, check hit type
		if HasFlag(hitInfo, HITINFO_CRITICALHIT) then
			crit = 1
		elseif HasFlag(hitInfo, HITINFO_CRUSHING) then
			crush = 1
		elseif HasFlag(hitInfo, HITINFO_GLANCING) then
			glance = 1
		else
			hit = 1
		end
	end

	-- Partial block: record block=1 but keep hit type (damage still occurred)
	if (blockedAmount or 0) > 0 and amount > 0 then
		block = 1
	end
	local resist = (totalResist or 0) > 0 and 1 or 0

	if attackerFriendly then
		if not targetFriendly then
			-- Friendly attacker vs enemy target -> DamageDone + EDT
			DB:DamageDone(attackerName, AAttack, hit, crit, miss, parry, dodge, resist, amount, glance, block)
			DB:EnemyDamage(true, nil, attackerName, AAttack, hit, crit, miss, parry, dodge, resist, amount, targetName, block, crush)
		elseif amount > 0 then
			-- Friendly fire (e.g. AoE clipping own pet): log fail + death history only
			DB:BuildFail(1, targetName, attackerName, AAttack, amount)
			DB:DeathHistory(targetName, attackerName, AAttack, amount, hit, crit, 0, crush)
		end
	else
		-- Hostile attacker -> DamageTaken + EnemyDamage(false/nil=EDD)
		if targetFriendly then
			DB:DamageTaken(targetName, AAttack, hit, crit, miss, parry, dodge, resist, amount, attackerName, crush, blockedAmount or 0)
			DB:EnemyDamage(false, nil, targetName, AAttack, hit, crit, miss, parry, dodge, resist, amount, attackerName, block, crush)
			DB:DeathHistory(targetName, attackerName, AAttack, amount, hit, crit, 0, crush)
		end
	end

	-- Handle absorb
	if (totalAbsorb or 0) > 0 then
		if attackerFriendly then
			DB:SetUnregisterVariables(totalAbsorb, AAttack, attackerName)
		else
			if targetFriendly then
				DB:SetUnregisterVariables(totalAbsorb, AAttack, attackerName)
				DB:Absorb(AAttack, targetName, attackerName)
			end
		end
	end
end

NPParser.AUTO_ATTACK_SELF = function()
	HandleAutoAttack(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
end

NPParser.AUTO_ATTACK_OTHER = function()
	HandleAutoAttack(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
end

----------------------------------------------------------------------------------
--------------            SPELL_DAMAGE_EVENT Handlers             --------------
----------------------------------------------------------------------------------

-- Parse mitigationStr: comma-separated "absorb,block,resist" amounts
local function ParseMitigation(mitigationStr)
	local absorb, blocked, resisted = 0, 0, 0
	if not mitigationStr or mitigationStr == "" then return absorb, blocked, resisted end
	local idx = 0
	for val in string.gfind(mitigationStr, "([^,]+)") do
		idx = idx + 1
		local num = tonumber(val) or 0
		if idx == 1 then absorb = num
		elseif idx == 2 then blocked = num
		elseif idx == 3 then resisted = num
		end
	end
	return absorb, blocked, resisted
end

-- Parse effectAuraStr to determine if periodic
-- Format: "auraType,..." where non-zero 4th value = aura/periodic
local function IsPeriodic(effectAuraStr)
	if not effectAuraStr or effectAuraStr == "" then return false end
	local idx = 0
	for val in string.gfind(effectAuraStr, "([^,]+)") do
		idx = idx + 1
		if idx == 4 then
			local num = tonumber(val) or 0
			return num ~= 0
		end
	end
	return false
end

local function HandleSpellDamage(targetGuid, casterGuid, spellId, amount, mitigationStr, hitInfo, spellSchool, effectAuraStr)
	local casterName = ResolveName(casterGuid)
	local targetName = ResolveName(targetGuid)
	if not casterName or not targetName then return end

	local ownerName = ResolveOwner(casterGuid)
	if ownerName then
		DB:BuildUser(casterName)
		DB:BuildUser(ownerName)
		DPSMateUser[casterName][4] = true
		DPSMateUser[casterName][6] = DPSMateUser[ownerName][1]
		DPSMateUser[ownerName][5] = casterName
	end

	local ability = GetSpellName(spellId)
	if ability == "Unknown" then return end

	local casterFriendly = IsFriendly(ownerName or casterName)
	-- Resolve target's owner so pet targets (e.g. warlock's own pet hit by AoE)
	-- are correctly treated as friendly rather than as enemy damage targets
	local targetOwnerName = ResolveOwner(targetGuid)
	local targetFriendly = IsFriendly(targetName) or IsFriendly(targetOwnerName)

	-- Determine if periodic
	local periodic = IsPeriodic(effectAuraStr)
	if periodic then
		ability = ability.."(Periodic)"
	end

	-- Determine hit/crit
	-- SPELL_DAMAGE_EVENT uses SPELL_HIT_TYPE enum (bit 1 = 2 means crit)
	-- not the same bitmask as AUTO_ATTACK's hitInfo (where HITINFO_CRITICALHIT = 128)
	local hit, crit = 0, 0
	if HasFlag(hitInfo, SPELL_HIT_TYPE_CRIT) then
		crit = 1
	else
		hit = 1
	end

	-- Parse mitigation
	local absorb, blocked, resisted = ParseMitigation(mitigationStr)
	local block = 0
	local resist = 0
	if blocked > 0 then
		block = 1
		-- hit/crit preserved: damage occurred, it was just partially blocked
	end
	if resisted > 0 then
		resist = 1
	end

	-- Spell school
	local school = schoolMap[spellSchool]
	if school then
		DB:AddSpellSchool(ability, school)
	end

	-- Absorb tracking
	if absorb > 0 then
		DB:SetUnregisterVariables(absorb, ability, casterName)
	end

	local damageAmount = amount or 0

	if casterFriendly then
		if not targetFriendly then
			-- Friendly caster vs enemy target -> DamageDone + EDT
			DB:DamageDone(casterName, ability, hit, crit, 0, 0, 0, resist, damageAmount, 0, block)
			DB:EnemyDamage(true, nil, casterName, ability, hit, crit, 0, 0, 0, resist, damageAmount, targetName, block, 0)
		elseif damageAmount > 0 then
			-- Friendly fire (e.g. Hellfire hitting own pet): log fail + death history only
			DB:BuildFail(1, targetName, casterName, ability, damageAmount)
			DB:DeathHistory(targetName, casterName, ability, damageAmount, hit, crit, 0, 0)
		end
	else
		-- Hostile caster -> DamageTaken + EDD
		if targetFriendly then
			DB:DamageTaken(targetName, ability, hit, crit, 0, 0, 0, resist, damageAmount, casterName, 0, block)
			DB:EnemyDamage(false, nil, targetName, ability, hit, crit, 0, 0, 0, resist, damageAmount, casterName, block, 0)
			DB:DeathHistory(targetName, casterName, ability, damageAmount, hit, crit, 0, 0)
		end
	end
end

NPParser.SPELL_DAMAGE_EVENT_SELF = function()
	HandleSpellDamage(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
end

NPParser.SPELL_DAMAGE_EVENT_OTHER = function()
	HandleSpellDamage(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
end

----------------------------------------------------------------------------------
--------------            SPELL_MISS Handlers                     --------------
----------------------------------------------------------------------------------

local function HandleSpellMissSelf(targetGuid, spellId, missInfo)
	local casterName = Player
	local targetName = ResolveName(targetGuid)
	if not targetName then return end

	local ability = GetSpellName(spellId)
	if ability == "Unknown" then return end

	if not missInfo or missInfo == 0 then return end
	local miss, resist, dodge, parry, block = 0, 0, 0, 0, 0
	if missInfo == MISSINFO_MISS then miss = 1
	elseif missInfo == MISSINFO_RESIST then resist = 1
	elseif missInfo == MISSINFO_DODGE then dodge = 1
	elseif missInfo == MISSINFO_PARRY then parry = 1
	elseif missInfo == MISSINFO_BLOCK then block = 1
	elseif missInfo == MISSINFO_DEFLECT then miss = 1  -- deflected projectile
	elseif missInfo == MISSINFO_REFLECT then miss = 1  -- spell reflected back to caster
	elseif missInfo == MISSINFO_ABSORB then
		DB:Absorb(ability, targetName, casterName)
		return
	elseif missInfo == MISSINFO_IMMUNE or missInfo == MISSINFO_IMMUNE2 or missInfo == MISSINFO_EVADE then
		return
	end

	-- Self is always friendly caster
	DB:DamageDone(casterName, ability, 0, 0, miss, parry, dodge, resist, 0, 0, block)
	DB:EnemyDamage(true, nil, casterName, ability, 0, 0, miss, parry, dodge, resist, 0, targetName, block, 0)
end

local function HandleSpellMissOther(casterGuid, targetGuid, spellId, missInfo)
	local casterName = ResolveName(casterGuid)
	local targetName = ResolveName(targetGuid)
	if not casterName or not targetName then return end

	local ownerName = ResolveOwner(casterGuid)
	if ownerName then
		DB:BuildUser(casterName)
		DB:BuildUser(ownerName)
		DPSMateUser[casterName][4] = true
		DPSMateUser[casterName][6] = DPSMateUser[ownerName][1]
		DPSMateUser[ownerName][5] = casterName
	end

	local ability = GetSpellName(spellId)
	if ability == "Unknown" then return end

	local casterFriendly = IsFriendly(ownerName or casterName)
	local targetFriendly = IsFriendly(targetName)

	if not missInfo or missInfo == 0 then return end
	local miss, resist, dodge, parry, block = 0, 0, 0, 0, 0
	if missInfo == MISSINFO_MISS then miss = 1
	elseif missInfo == MISSINFO_RESIST then resist = 1
	elseif missInfo == MISSINFO_DODGE then dodge = 1
	elseif missInfo == MISSINFO_PARRY then parry = 1
	elseif missInfo == MISSINFO_BLOCK then block = 1
	elseif missInfo == MISSINFO_DEFLECT then miss = 1  -- deflected projectile
	elseif missInfo == MISSINFO_REFLECT then miss = 1  -- spell reflected back to caster
	elseif missInfo == MISSINFO_ABSORB then
		if casterFriendly or targetFriendly then
			DB:Absorb(ability, targetName, casterName)
		end
		return
	elseif missInfo == MISSINFO_IMMUNE or missInfo == MISSINFO_IMMUNE2 or missInfo == MISSINFO_EVADE then
		return
	end

	if casterFriendly then
		DB:DamageDone(casterName, ability, 0, 0, miss, parry, dodge, resist, 0, 0, block)
		DB:EnemyDamage(true, nil, casterName, ability, 0, 0, miss, parry, dodge, resist, 0, targetName, block, 0)
	else
		if targetFriendly then
			DB:DamageTaken(targetName, ability, 0, 0, miss, parry, dodge, resist, 0, casterName, 0, block)
			DB:EnemyDamage(false, nil, targetName, ability, 0, 0, miss, parry, dodge, resist, 0, casterName, block, 0)
		end
	end
end

NPParser.SPELL_MISS_SELF = function()
	-- arg1=casterGuid (always self, skip), arg2=targetGuid, arg3=spellId, arg4=missInfo
	HandleSpellMissSelf(arg2, arg3, arg4)
end

NPParser.SPELL_MISS_OTHER = function()
	HandleSpellMissOther(arg1, arg2, arg3, arg4)
end

----------------------------------------------------------------------------------
--------------            SPELL_HEAL Handlers                     --------------
----------------------------------------------------------------------------------

-- Dedup state: prevent double-counting when both NP and string parser fire
-- for the same heal event. NP handler records a count; the wrapped DB functions
-- consume it and skip when non-zero.
local origDBHealing = nil
local origDBHealingTaken = nil
local origDBDeathHistory = nil
local npHealDedup = {}

local function RecordNPHeal(key)
	npHealDedup[key] = (npHealDedup[key] or 0) + 1
end

local function ConsumeNPHeal(key)
	local count = npHealDedup[key]
	if not count or count <= 0 then return false end
	if count == 1 then npHealDedup[key] = nil
	else npHealDedup[key] = count - 1 end
	return true
end

-- Wrap DB healing functions so the string parser skips entries NP already recorded.
-- Only intercepts mode=1 for Healing and mode=0 for HealingTaken (raw totals);
-- mode=0 effective Healing and mode=1 effective HealingTaken still pass through
-- to the string parser (which has the correct overheal-adjusted amounts).
local function WrapDBHealingForNP()
	origDBHealing = DPSMate.DB.Healing
	DPSMate.DB.Healing = function(self, mode, arr, caster, name, hit, crit, amount)
		if mode == 1 then
			local key = (caster or "") .. "|H1|" .. (name or "") .. "|" .. (amount or 0)
			if ConsumeNPHeal(key) then return end
		end
		return origDBHealing(self, mode, arr, caster, name, hit, crit, amount)
	end
	origDBHealingTaken = DPSMate.DB.HealingTaken
	DPSMate.DB.HealingTaken = function(self, mode, arr, healed, name, hit, crit, amount, healer)
		if mode == 0 then
			local key = (healed or "") .. "|HT0|" .. (name or "") .. "|" .. (amount or 0)
			if ConsumeNPHeal(key) then return end
		end
		return origDBHealingTaken(self, mode, arr, healed, name, hit, crit, amount, healer)
	end
	origDBDeathHistory = DPSMate.DB.DeathHistory
	DPSMate.DB.DeathHistory = function(self, target, cause, ability, amount, hit, crit, type, crush)
		local key = (target or "") .. "|DH|" .. (cause or "") .. "|" .. (ability or "") .. "|" .. (amount or 0)
		if ConsumeNPHeal(key) then return end
		return origDBDeathHistory(self, target, cause, ability, amount, hit, crit, type, crush)
	end
end

local function HandleSpellHeal(targetGuid, casterGuid, spellId, amount, critical, periodic)
	if not targetGuid or targetGuid == "0x0000000000000000" then return end
	local casterName = ResolveName(casterGuid)
	local targetName = ResolveName(targetGuid)
	if not casterName or not targetName then return end

	local ownerName = ResolveOwner(casterGuid)
	if ownerName then
		DB:BuildUser(casterName)
		DB:BuildUser(ownerName)
		DPSMateUser[casterName][4] = true
		DPSMateUser[casterName][6] = DPSMateUser[ownerName][1]
		DPSMateUser[ownerName][5] = casterName
	end

	local ability = GetSpellName(spellId)
	if ability == "Unknown" then return end
	if periodic == 1 then ability = ability .. "(Periodic)" end

	-- Dhit=1 means regular hit, Dhit=0 means crit (DPSMate internal convention)
	local hit = (critical == 1) and 0 or 1
	local crit = (critical == 1) and 1 or 0
	local effectiveCaster = ownerName or casterName

	-- Record dedup counts before calling DB so string parser skips duplicates
	local hKey  = effectiveCaster .. "|H1|"  .. ability .. "|" .. amount
	local htKey = targetName      .. "|HT0|" .. ability .. "|" .. amount
	local dhKey = targetName .. "|DH|" .. effectiveCaster .. "|" .. ability .. "|" .. amount
	RecordNPHeal(hKey)
	RecordNPHeal(htKey)
	RecordNPHeal(dhKey)

	-- Call originals directly (bypassing wrappers) — NP is the authoritative source
	origDBHealing(DB, 1, nil, effectiveCaster, ability, hit, crit, amount)
	origDBHealingTaken(DB, 0, nil, targetName, ability, hit, crit, amount, effectiveCaster)
	origDBDeathHistory(DB, targetName, effectiveCaster, ability, amount, hit, crit, 1, 0)
end

NPParser.SPELL_HEAL_BY_SELF = function()
	HandleSpellHeal(arg1, arg2, arg3, arg4, arg5, arg6)
end

NPParser.SPELL_HEAL_BY_OTHER = function()
	HandleSpellHeal(arg1, arg2, arg3, arg4, arg5, arg6)
end

----------------------------------------------------------------------------------
--------------            UNIT_DIED Handler                       --------------
----------------------------------------------------------------------------------

NPParser.UNIT_DIED = function()
	-- arg1 = GUID of the unit that died
	local name = ResolveName(arg1)
	if not name then return end
	-- Confirm the death in DPSMate's death history: sets the "confirmed" flag,
	-- opens a new death slot for this player, and broadcasts to party.
	DB:UnregisterDeath(name)
end

----------------------------------------------------------------------------------
--------------            RAW_COMBATLOG Handler (SuperWoW only)   --------------
----------------------------------------------------------------------------------

local function ExtractFirstGUID(rawText)
	local _, _, g, n = string.find(rawText, "|Hunit:(0x%x+)|h([^|]+)|h")
	return g, n
end

local function StripGUIDLinks(rawText)
	return string.gsub(rawText, "|Hunit:0x%x+|h([^|]+)|h", "%1")
end

NPParser.RAW_COMBATLOG = function()
	local petType = petRawEvents[arg1]
	if not petType then return end

	local sourceGuid, sourceName = ExtractFirstGUID(arg2)
	local ownerName = sourceGuid and ResolveOwner(sourceGuid)
	local cleanText = StripGUIDLinks(arg2)

	if ownerName and sourceName then
		local replacement = sourceName .. " (" .. ownerName .. ")"
		local i, j = string.find(cleanText, sourceName, 1, true)
		if i then
			cleanText = string.sub(cleanText, 1, i - 1) .. replacement .. string.sub(cleanText, j + 1)
		end
	end

	if petType == "hits" then
		DPSMate.Parser:FriendlyPlayerHits(cleanText)
	elseif petType == "misses" then
		DPSMate.Parser:FriendlyPlayerMisses(cleanText)
	else
		DPSMate.Parser:FriendlyPlayerDamage(cleanText)
	end
end

----------------------------------------------------------------------------------
--------------            Initialization                          --------------
----------------------------------------------------------------------------------

NPParser:RegisterEvent("PLAYER_ENTERING_WORLD")

NPParser:SetScript("OnEvent", function()
	if event == "PLAYER_ENTERING_WORLD" then
		-- Get player name
		Player = UnitName("player")
		TP = DPSMate.Parser.TargetParty

		-- Detect Nampower
		if GetNampowerVersion then
			hasNampower = true
			npMajor, npMinor, npPatch = GetNampowerVersion()
		end

		-- Detect SuperWoW
		if SUPERWOW_VERSION or (SetAutoloot and SpellInfo) then
			hasSuperWoW = true
		end

		-- SuperWoW required for GUID resolution (owner detection)
		if not hasSuperWoW then
			return
		end

		-- Shared: GUID cache + roster events
		RefreshGUIDCache()
		NPParser:RegisterEvent("RAID_ROSTER_UPDATE")
		NPParser:RegisterEvent("PARTY_MEMBERS_CHANGED")
		NPParser:RegisterEvent("PLAYER_TARGET_CHANGED")
		NPParser:RegisterEvent("PLAYER_PET_CHANGED")

		if hasNampower then
			-- Nampower + SuperWoW: structured events with owner resolution

			-- v2.24+: Auto attack events
			if NPVersionAtLeast(2, 24, 0) then
				SetCVar("NP_EnableAutoAttackEvents", "1")
				NPParser:RegisterEvent("AUTO_ATTACK_SELF")
				NPParser:RegisterEvent("AUTO_ATTACK_OTHER")
				UnregisterStringParserEvents(autoAttackEvents)
			end

			-- v2.30+: Spell heal events (CVar-gated, not auto-enabled)
			if NPVersionAtLeast(2, 30, 0) then
				SetCVar("NP_EnableSpellHealEvents", "1")
				WrapDBHealingForNP()
				NPParser:RegisterEvent("SPELL_HEAL_BY_SELF")
				NPParser:RegisterEvent("SPELL_HEAL_BY_OTHER")
			end

			-- v2.31+: Spell damage + spell miss events
			if NPVersionAtLeast(2, 31, 0) then
				NPParser:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
				NPParser:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER")
				NPParser:RegisterEvent("SPELL_MISS_SELF")
				NPParser:RegisterEvent("SPELL_MISS_OTHER")
				UnregisterStringParserEvents(spellDamageEvents)
			end

			-- UNIT_DIED: available in all Nampower versions
			NPParser:RegisterEvent("UNIT_DIED")
		else
			-- SuperWoW only: RAW_COMBATLOG for pet event owner resolution
			UnregisterStringParserEvents(petStringEvents)
			NPParser:RegisterEvent("RAW_COMBATLOG")
		end

		NPParser:UnregisterEvent("PLAYER_ENTERING_WORLD")
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" or event == "PLAYER_PET_CHANGED" then
		RefreshGUIDCache()
		TP = DPSMate.Parser.TargetParty
	elseif event == "PLAYER_TARGET_CHANGED" then
		-- Cache target GUID on target change
		local _, guid = UnitExists("target")
		if guid then
			local name = UnitName("target")
			if name then guidCache[NormalizeGUID(guid)] = name end
		end
	else
		-- Dispatch Nampower events
		if NPParser[event] then
			NPParser[event]()
		end
	end
end)
