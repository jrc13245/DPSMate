-- DPSMate_CombatPatterns.lua
-- Pattern-based combat log matching using WoW global format strings.
-- Automatically adapts to server-specific combat log format changes (e.g., TWoW).
-- Field mappings are auto-detected from format string context, not hardcoded.

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
	str = string.gsub(str, "\002", "(%d+)")
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

-- Auto-detect field names for each format specifier based on surrounding text context.
-- Returns a table mapping field_name -> capture_index, or nil if format is empty/invalid.
-- overrides: optional table mapping detected_name -> desired_name (e.g., {target="source"})
function CP:DetectFields(fmt, overrides)
	if not fmt then return nil end

	-- Parse specifiers and the text segments between them
	local specs = {}
	local n = 0
	local pos = 1
	while true do
		local i, j, specType = strfind(fmt, "%%([sd])", pos)
		if not i then break end
		n = n + 1
		specs[n] = {
			type = specType,
			before = strsub(fmt, pos, i - 1),
		}
		pos = j + 1
	end
	if n == 0 then return nil end

	-- Set "after" text for each spec (text between this spec and the next, or trailing)
	for i = 1, n - 1 do
		specs[i].after = specs[i + 1].before
	end
	specs[n].after = strsub(fmt, pos)

	-- Detect field name for each specifier based on surrounding text
	local fields = {}

	for i = 1, n do
		local s = specs[i]
		local field

		if s.type == "d" then
			field = "amount"
		else
			local before = s.before
			local after = s.after

			-- Rule 1: After "Your/your " -> ability (e.g., "Your %s hits")
			if strfind(before, "Your ?$") or strfind(before, "your ?$") then
				field = "ability"
			-- Rule 2: After "'s " -> ability (e.g., "Source's %s hits")
			elseif strfind(before, "'s ?$") or strfind(before, "' s ?$") then
				field = "ability"
			-- Rule 3: Before "'s" -> source (e.g., "%s's Ability", "%s 's Ability")
			elseif strfind(after, "^'s") or strfind(after, "^' s") or strfind(after, "^ 's") then
				field = "source"
			-- Rule 4: Before " damage" -> school (e.g., "%d %s damage")
			elseif strfind(after, "^ damage") then
				field = "school"
			-- Rule 5: Before " suffers" -> target (e.g., "%s suffers %d")
			elseif strfind(after, "^ suffers") then
				field = "target"
			-- Rule 6: Before action verbs -> source (e.g., "%s hits", "%s critically hits")
			elseif strfind(after, "^ hits") or strfind(after, "^ crits") or
			       strfind(after, "^ misses") or strfind(after, "^ attacks") or
			       strfind(after, "^ reflects") or strfind(after, "^ critically") then
				field = "source"
			-- Rule 7: Before reaction verbs -> target (e.g., "%s parries", "%s is immune")
			elseif strfind(after, "^ parries") or strfind(after, "^ dodges") or
			       strfind(after, "^ blocks") or strfind(after, "^ absorbs") or
			       strfind(after, "^ is immune") then
				field = "target"
			-- Rule 8: Before " for " -> target (e.g., "hits %s for %d")
			elseif strfind(after, "^ for ") then
				field = "target"
			-- Rule 9: After " to " -> target (e.g., "damage to %s")
			elseif strfind(before, " to ?$") then
				field = "target"
			-- Rule 10: After " by " -> target (e.g., "dodged by %s")
			elseif strfind(before, " by ?$") then
				field = "target"
			-- Rule 11: After " from " -> source (e.g., "damage from %s")
			elseif strfind(before, " from ?$") then
				field = "source"
			-- Rule 12: "You <verb> %s" -> target (e.g., "You miss %s")
			elseif strfind(before, "^You %a+ ?$") then
				field = "target"
			-- Rule 13: End of message -> target (fallback for last %s)
			elseif strfind(after, "^%.?$") then
				field = "target"
			else
				field = "target"
			end
		end

		-- Apply overrides (e.g., env damage: detected "target" -> call it "source")
		if overrides and overrides[field] then
			field = overrides[field]
		end

		fields[field] = i
	end

	return fields
end

-- Flag indicating patterns have been built
CP.ready = false

-- Helper: add a pattern entry from a WoW global string name.
-- Field mappings are auto-detected from format string content.
-- overrides: optional table mapping detected_name -> desired_name
local function addP(tbl, globalName, hitType, overrides)
	local str = getglobal(globalName)
	if str then
		local fields = CP:DetectFields(str, overrides)
		if fields then
			tinsert(tbl, {CP:Sanitize(str), hitType, fields})
		end
	end
end

-- Build all patterns from WoW globals.
-- MUST be called AFTER InitParser modifies the globals (adds space before 's).
function CP:BuildPatterns()
	-- =================== SELF MELEE HITS ===================
	-- "You hit Target for Amount [School damage]."
	self.selfMeleeHit = {}
	addP(self.selfMeleeHit, "COMBATHITCRITSCHOOLSELFOTHER", "crit")
	addP(self.selfMeleeHit, "COMBATHITSCHOOLSELFOTHER", "hit")
	addP(self.selfMeleeHit, "COMBATHITCRITSELFOTHER", "crit")
	addP(self.selfMeleeHit, "COMBATHITSELFOTHER", "hit")

	-- =================== OTHER MELEE HITS ===================
	-- "Source hits Target for Amount [School damage]."
	self.otherMeleeHit = {}
	addP(self.otherMeleeHit, "COMBATHITCRITSCHOOLOTHEROTHER", "crit")
	addP(self.otherMeleeHit, "COMBATHITSCHOOLOTHEROTHER", "hit")
	addP(self.otherMeleeHit, "COMBATHITCRITOTHEROTHER", "crit")
	addP(self.otherMeleeHit, "COMBATHITOTHEROTHER", "hit")

	-- =================== SELF SPELL HITS ===================
	-- "Your Ability hits Target for Amount [School damage]."
	self.selfSpellHit = {}
	addP(self.selfSpellHit, "SPELLLOGCRITSCHOOLSELFOTHER", "crit")
	addP(self.selfSpellHit, "SPELLLOGSCHOOLSELFOTHER", "hit")
	addP(self.selfSpellHit, "SPELLLOGCRITSELFOTHER", "crit")
	addP(self.selfSpellHit, "SPELLLOGSELFOTHER", "hit")
	addP(self.selfSpellHit, "SPELLLOGCRITSCHOOLSELFSELF", "crit")
	addP(self.selfSpellHit, "SPELLLOGSCHOOLSELFSELF", "hit")
	addP(self.selfSpellHit, "SPELLLOGCRITSELFSELF", "crit")
	addP(self.selfSpellHit, "SPELLLOGSELFSELF", "hit")

	-- =================== OTHER SPELL HITS ===================
	-- "Source's Ability hits Target for Amount [School damage]."
	self.otherSpellHit = {}
	addP(self.otherSpellHit, "SPELLLOGCRITSCHOOLOTHEROTHER", "crit")
	addP(self.otherSpellHit, "SPELLLOGSCHOOLOTHEROTHER", "hit")
	addP(self.otherSpellHit, "SPELLLOGCRITOTHEROTHER", "crit")
	addP(self.otherSpellHit, "SPELLLOGOTHEROTHER", "hit")

	-- =================== PERIODIC DAMAGE ===================
	-- "Target suffers Amount School damage from Source's Ability."
	self.periodicDmg = {}
	addP(self.periodicDmg, "PERIODICAURADAMAGEOTHEROTHER", "dot")
	addP(self.periodicDmg, "PERIODICAURADAMAGESELFOTHER", "dot")
	addP(self.periodicDmg, "PERIODICAURADAMAGEOTHERSELF", "dot")
	addP(self.periodicDmg, "PERIODICAURADAMAGESELFSELF", "dot")

	-- =================== DAMAGE SHIELDS ===================
	self.dmgShield = {}
	addP(self.dmgShield, "DAMAGESHIELDSELFOTHER", "shield")
	addP(self.dmgShield, "DAMAGESHIELDOTHERSELF", "shield")
	addP(self.dmgShield, "DAMAGESHIELDOTHEROTHER", "shield")

	-- =================== ENVIRONMENTAL DAMAGE ===================
	-- Entity "suffering" env damage is called "source" in the data model
	local envOverride = {target = "source"}

	self.envDmgSelf = {}
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_FALLING_SELF", "falling")
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_DROWNING_SELF", "drowning")
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_LAVA_SELF", "lava")
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_SLIME_SELF", "slime")
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_FIRE_SELF", "fire")
	addP(self.envDmgSelf, "VSENVIRONMENTALDAMAGE_FATIGUE_SELF", "fatigue")

	self.envDmgOther = {}
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_FALLING_OTHER", "falling", envOverride)
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_DROWNING_OTHER", "drowning", envOverride)
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_LAVA_OTHER", "lava", envOverride)
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_SLIME_OTHER", "slime", envOverride)
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_FIRE_OTHER", "fire", envOverride)
	addP(self.envDmgOther, "VSENVIRONMENTALDAMAGE_FATIGUE_OTHER", "fatigue", envOverride)

	-- =================== SELF SPELL MISSES ===================
	self.selfSpellMiss = {}
	addP(self.selfSpellMiss, "SPELLMISSSELFOTHER", "miss")
	addP(self.selfSpellMiss, "SPELLRESISTSELFOTHER", "resist")
	addP(self.selfSpellMiss, "SPELLPARRIEDSELFOTHER", "parry")
	addP(self.selfSpellMiss, "SPELLDODGEDSELFOTHER", "dodge")
	addP(self.selfSpellMiss, "SPELLLOGABSORBSELFOTHER", "absorb")
	addP(self.selfSpellMiss, "SPELLBLOCKEDSELFOTHER", "block")
	addP(self.selfSpellMiss, "SPELLIMMUNESELFOTHER", "immune")

	-- =================== OTHER SPELL MISSES ===================
	self.otherSpellMiss = {}
	addP(self.otherSpellMiss, "SPELLMISSOTHEROTHER", "miss")
	addP(self.otherSpellMiss, "SPELLRESISTOTHEROTHER", "resist")
	addP(self.otherSpellMiss, "SPELLPARRIEDOTHEROTHER", "parry")
	addP(self.otherSpellMiss, "SPELLDODGEDOTHEROTHER", "dodge")
	addP(self.otherSpellMiss, "SPELLLOGABSORBOTHEROTHER", "absorb")
	addP(self.otherSpellMiss, "SPELLBLOCKEDOTHEROTHER", "block")
	addP(self.otherSpellMiss, "SPELLIMMUNEOTHEROTHER", "immune")
	addP(self.otherSpellMiss, "SPELLEVADEDOTHEROTHER", "evade")

	-- =================== SELF MELEE MISSES ===================
	self.selfMeleeMiss = {}
	addP(self.selfMeleeMiss, "MISSEDSELFOTHER", "miss")
	addP(self.selfMeleeMiss, "VSPARRYSELFOTHER", "parry")
	addP(self.selfMeleeMiss, "VSDODGESELFOTHER", "dodge")
	addP(self.selfMeleeMiss, "VSBLOCKSELFOTHER", "block")
	addP(self.selfMeleeMiss, "VSABSORBSELFOTHER", "absorb")

	-- =================== OTHER MELEE MISSES ===================
	self.otherMeleeMiss = {}
	addP(self.otherMeleeMiss, "MISSEDOTHEROTHER", "miss")
	addP(self.otherMeleeMiss, "VSPARRYOTHEROTHER", "parry")
	addP(self.otherMeleeMiss, "VSDODGEOTHEROTHER", "dodge")
	addP(self.otherMeleeMiss, "VSBLOCKOTHEROTHER", "block")
	addP(self.otherMeleeMiss, "VSABSORBOTHEROTHER", "absorb")

	self.ready = true
end

-- Debug: dump all detected patterns and their field mappings to chat.
-- Usage in-game: /script DPSMate.CombatPatterns:DebugDump()
function CP:DebugDump()
	local function dump(name, tbl)
		if not tbl or not tbl[1] then return end
		DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00=== " .. name .. " ===|r")
		for i, entry in ipairs(tbl) do
			local hitType = entry[2] or "nil"
			local fields = entry[3]
			local fieldStr = ""
			if fields then
				for k, v in pairs(fields) do
					if fieldStr ~= "" then fieldStr = fieldStr .. ", " end
					fieldStr = fieldStr .. k .. "=" .. v
				end
			end
			DEFAULT_CHAT_FRAME:AddMessage("  " .. hitType .. ": {" .. fieldStr .. "}")
		end
	end

	DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00--- CombatPatterns Debug Dump ---|r")
	dump("selfMeleeHit", self.selfMeleeHit)
	dump("otherMeleeHit", self.otherMeleeHit)
	dump("selfSpellHit", self.selfSpellHit)
	dump("otherSpellHit", self.otherSpellHit)
	dump("periodicDmg", self.periodicDmg)
	dump("dmgShield", self.dmgShield)
	dump("envDmgSelf", self.envDmgSelf)
	dump("envDmgOther", self.envDmgOther)
	dump("selfSpellMiss", self.selfSpellMiss)
	dump("otherSpellMiss", self.otherSpellMiss)
	dump("selfMeleeMiss", self.selfMeleeMiss)
	dump("otherMeleeMiss", self.otherMeleeMiss)
	DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00CP.ready = " .. tostring(self.ready) .. "|r")
end

-- Debug: test auto-detection on a specific WoW global and show the result.
-- Usage: /script DPSMate.CombatPatterns:DebugGlobal("PERIODICAURADAMAGEOTHERSELF")
function CP:DebugGlobal(globalName, overrides)
	local str = getglobal(globalName)
	if not str then
		DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000" .. globalName .. " = nil|r")
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00" .. globalName .. "|r = \"" .. str .. "\"")
	local fields = self:DetectFields(str, overrides)
	if fields then
		local fieldStr = ""
		for k, v in pairs(fields) do
			if fieldStr ~= "" then fieldStr = fieldStr .. ", " end
			fieldStr = fieldStr .. k .. "=" .. v
		end
		DEFAULT_CHAT_FRAME:AddMessage("  Fields: {" .. fieldStr .. "}")
	else
		DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF0000No fields detected|r")
	end
	DEFAULT_CHAT_FRAME:AddMessage("  Pattern: " .. (self:Sanitize(str) or "nil"))
end
