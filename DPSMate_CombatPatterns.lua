-- DPSMate_CombatPatterns.lua
-- Pattern-based combat log matching using WoW global format strings.
-- Automatically adapts to server-specific combat log format changes (e.g., TWoW).

DPSMate.CombatPatterns = {}
local CP = DPSMate.CombatPatterns

local strfind = string.find
local strsub = string.sub
local tonumber = tonumber
local tinsert = table.insert

-- Convert a WoW format string (e.g., "You hit %s for %d.") to a Lua pattern
-- e.g., "You hit %s for %d." -> "^You hit (.+) for (%d+)%.$"
function CP:Sanitize(str)
	if not str then return nil end
	-- Replace format specifiers with placeholders before escaping
	str = string.gsub(str, "%%s", "\001")
	str = string.gsub(str, "%%d", "\002")
	-- Escape Lua pattern magic characters
	str = string.gsub(str, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
	-- Replace placeholders with capture groups
	str = string.gsub(str, "\001", "(.+)")
	str = string.gsub(str, "\002", "(%%d+)")
	return "^" .. str .. "$"
end

-- Strip combat log trailers: (X absorbed), (blocked), (glancing), (crushing), (X resisted)
-- Returns: cleaned_msg, absorbed_amount, blocked(0/1), glancing(bool), crushing(bool)
function CP:StripTrailers(msg)
	local absorbed, blocked, glancing, crushing = 0, 0, false, false
	local i, j, amt

	i, j, amt = strfind(msg, " %((%d+) absorbed%)")
	if i then absorbed = tonumber(amt); msg = strsub(msg, 1, i-1) .. strsub(msg, j+1) end

	i, j, amt = strfind(msg, " %((%d+) blocked%)")
	if i then blocked = 1; msg = strsub(msg, 1, i-1) .. strsub(msg, j+1) end
	if blocked == 0 then
		i, j = strfind(msg, " %(blocked%)")
		if i then blocked = 1; msg = strsub(msg, 1, i-1) .. strsub(msg, j+1) end
	end

	i, j = strfind(msg, " %(glancing%)")
	if i then glancing = true; msg = strsub(msg, 1, i-1) .. strsub(msg, j+1) end

	i, j = strfind(msg, " %(crushing%)")
	if i then crushing = true; msg = strsub(msg, 1, i-1) .. strsub(msg, j+1) end

	-- Strip resisted trailer to prevent pattern mismatch
	i, j = strfind(msg, " %((%d+) resisted%)")
	if i then msg = strsub(msg, 1, i-1) .. strsub(msg, j+1) end

	return msg, absorbed, blocked, glancing, crushing
end

-- Try matching a message against a list of pattern entries
-- Each entry: {pattern_string, hitType_string, {field=captureIndex, ...}}
-- Returns: hitType, result_table (with named fields) on match, or nil
function CP:TryMatch(msg, patterns)
	if not patterns then return nil end
	for _, entry in ipairs(patterns) do
		local pattern = entry[1]
		if pattern then
			local c = {strfind(msg, pattern)}
			if c[1] then
				local result = {}
				local fields = entry[3]
				for field, idx in pairs(fields) do
					result[field] = c[idx + 2] -- +2 to skip start/end positions
				end
				if result.amount then result.amount = tonumber(result.amount) end
				return entry[2], result
			end
		end
	end
	return nil
end

-- Flag indicating patterns have been built
CP.ready = false

-- Helper: add a pattern entry from a WoW global string name
local function addP(tbl, globalName, hitType, fields)
	local str = getglobal(globalName)
	if str then
		tinsert(tbl, {CP:Sanitize(str), hitType, fields})
	end
end

-- Build all patterns from WoW globals.
-- MUST be called AFTER InitParser modifies the globals (adds space before 's).
function CP:BuildPatterns()
	-- =================== SELF MELEE HITS ===================
	-- "You hit Target for Amount [School damage]."
	self.selfMeleeHit = {}
	addP(self.selfMeleeHit, "COMBATHITCRITSCHOOLSELFOTHER", "crit", {target=1, amount=2, school=3})
	addP(self.selfMeleeHit, "COMBATHITSCHOOLSELFOTHER", "hit", {target=1, amount=2, school=3})
	addP(self.selfMeleeHit, "COMBATHITCRITSELFOTHER", "crit", {target=1, amount=2})
	addP(self.selfMeleeHit, "COMBATHITSELFOTHER", "hit", {target=1, amount=2})

	-- =================== OTHER MELEE HITS ===================
	-- "Source hits Target for Amount [School damage]."
	self.otherMeleeHit = {}
	addP(self.otherMeleeHit, "COMBATHITCRITSCHOOLOTHEROTHER", "crit", {source=1, target=2, amount=3, school=4})
	addP(self.otherMeleeHit, "COMBATHITSCHOOLOTHEROTHER", "hit", {source=1, target=2, amount=3, school=4})
	addP(self.otherMeleeHit, "COMBATHITCRITOTHEROTHER", "crit", {source=1, target=2, amount=3})
	addP(self.otherMeleeHit, "COMBATHITOTHEROTHER", "hit", {source=1, target=2, amount=3})

	-- =================== SELF SPELL HITS ===================
	-- "Your Ability hits Target for Amount [School damage]."
	self.selfSpellHit = {}
	addP(self.selfSpellHit, "SPELLLOGCRITSCHOOLSELFOTHER", "crit", {ability=1, target=2, amount=3, school=4})
	addP(self.selfSpellHit, "SPELLLOGSCHOOLSELFOTHER", "hit", {ability=1, target=2, amount=3, school=4})
	addP(self.selfSpellHit, "SPELLLOGCRITSELFOTHER", "crit", {ability=1, target=2, amount=3})
	addP(self.selfSpellHit, "SPELLLOGSELFOTHER", "hit", {ability=1, target=2, amount=3})
	addP(self.selfSpellHit, "SPELLLOGCRITSCHOOLSELFSELF", "crit", {ability=1, amount=2, school=3})
	addP(self.selfSpellHit, "SPELLLOGSCHOOLSELFSELF", "hit", {ability=1, amount=2, school=3})
	addP(self.selfSpellHit, "SPELLLOGCRITSELFSELF", "crit", {ability=1, amount=2})
	addP(self.selfSpellHit, "SPELLLOGSELFSELF", "hit", {ability=1, amount=2})

	-- =================== OTHER SPELL HITS ===================
	-- "Source's Ability hits Target for Amount [School damage]."
	self.otherSpellHit = {}
	addP(self.otherSpellHit, "SPELLLOGCRITSCHOOLOTHEROTHER", "crit", {source=1, ability=2, target=3, amount=4, school=5})
	addP(self.otherSpellHit, "SPELLLOGSCHOOLOTHEROTHER", "hit", {source=1, ability=2, target=3, amount=4, school=5})
	addP(self.otherSpellHit, "SPELLLOGCRITOTHEROTHER", "crit", {source=1, ability=2, target=3, amount=4})
	addP(self.otherSpellHit, "SPELLLOGOTHEROTHER", "hit", {source=1, ability=2, target=3, amount=4})

	-- =================== PERIODIC DAMAGE ===================
	-- "Target suffers Amount School damage from Source's Ability."
	self.periodicDmg = {}
	addP(self.periodicDmg, "PERIODICAURADAMAGEOTHEROTHER", "dot", {target=1, amount=2, school=3, source=4, ability=5})
	addP(self.periodicDmg, "PERIODICAURADAMAGESELFOTHER", "dot", {amount=1, school=2, source=3, ability=4})
	addP(self.periodicDmg, "PERIODICAURADAMAGEOTHERSELF", "dot", {target=1, amount=2, school=3, ability=4})
	addP(self.periodicDmg, "PERIODICAURADAMAGESELFSELF", "dot", {amount=1, school=2, ability=3})

	-- =================== DAMAGE SHIELDS ===================
	self.dmgShield = {}
	addP(self.dmgShield, "DAMAGESHIELDSELFOTHER", "shield", {amount=1, school=2, target=3})
	addP(self.dmgShield, "DAMAGESHIELDOTHERSELF", "shield", {source=1, amount=2, school=3})
	addP(self.dmgShield, "DAMAGESHIELDOTHEROTHER", "shield", {source=1, amount=2, school=3, target=4})

	-- =================== ENVIRONMENTAL DAMAGE ===================
	self.envDmgSelf = {}
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_FALLING_SELF", "falling", {amount=1})
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_DROWNING_SELF", "drowning", {amount=1})
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_LAVA_SELF", "lava", {amount=1})
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_SLIME_SELF", "slime", {amount=1})
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_FIRE_SELF", "fire", {amount=1})
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_FATIGUE_SELF", "fatigue", {amount=1})

	self.envDmgOther = {}
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_FALLING_OTHER", "falling", {source=1, amount=2})
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_DROWNING_OTHER", "drowning", {source=1, amount=2})
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_LAVA_OTHER", "lava", {source=1, amount=2})
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_SLIME_OTHER", "slime", {source=1, amount=2})
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_FIRE_OTHER", "fire", {source=1, amount=2})
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_FATIGUE_OTHER", "fatigue", {source=1, amount=2})

	-- =================== SELF SPELL MISSES ===================
	self.selfSpellMiss = {}
	addP(self.selfSpellMiss, "SPELLMISSSELFOTHER", "miss", {ability=1, target=2})
	addP(self.selfSpellMiss, "SPELLRESISTSELFOTHER", "resist", {ability=1, target=2})
	addP(self.selfSpellMiss, "SPELLPARRIEDSELFOTHER", "parry", {ability=1, target=2})
	addP(self.selfSpellMiss, "SPELLDODGEDSELFOTHER", "dodge", {ability=1, target=2})
	addP(self.selfSpellMiss, "SPELLLOGABSORBSELFOTHER", "absorb", {ability=1, target=2})
	addP(self.selfSpellMiss, "SPELLBLOCKEDSELFOTHER", "block", {ability=1, target=2})
	addP(self.selfSpellMiss, "SPELLIMMUNESELFOTHER", "immune", {ability=1, target=2})

	-- =================== OTHER SPELL MISSES ===================
	self.otherSpellMiss = {}
	addP(self.otherSpellMiss, "SPELLMISSOTHEROTHER", "miss", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLRESISTOTHEROTHER", "resist", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLPARRIEDOTHEROTHER", "parry", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLDODGEDOTHEROTHER", "dodge", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLLOGABSORBOTHEROTHER", "absorb", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLBLOCKEDOTHEROTHER", "block", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLIMMUNEOTHEROTHER", "immune", {source=1, ability=2, target=3})
	addP(self.otherSpellMiss, "SPELLEVADEDOTHEROTHER", "evade", {source=1, ability=2, target=3})

	-- =================== SELF MELEE MISSES ===================
	self.selfMeleeMiss = {}
	addP(self.selfMeleeMiss, "MISSEDSELFOTHER", "miss", {target=1})
	addP(self.selfMeleeMiss, "VSPARRYSELFOTHER", "parry", {target=1})
	addP(self.selfMeleeMiss, "VSDODGESELFOTHER", "dodge", {target=1})
	addP(self.selfMeleeMiss, "VSBLOCKSELFOTHER", "block", {target=1})
	addP(self.selfMeleeMiss, "VSABSORBSELFOTHER", "absorb", {target=1})

	-- =================== OTHER MELEE MISSES ===================
	self.otherMeleeMiss = {}
	addP(self.otherMeleeMiss, "MISSEDOTHEROTHER", "miss", {source=1, target=2})
	addP(self.otherMeleeMiss, "VSPARRYOTHEROTHER", "parry", {source=1, target=2})
	addP(self.otherMeleeMiss, "VSDODGEOTHEROTHER", "dodge", {source=1, target=2})
	addP(self.otherMeleeMiss, "VSBLOCKOTHEROTHER", "block", {source=1, target=2})
	addP(self.otherMeleeMiss, "VSABSORBOTHEROTHER", "absorb", {source=1, target=2})

	self.ready = true
end
