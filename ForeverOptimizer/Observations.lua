-- Combat observations: what creatures actually do to (and take from) this character.
--
-- The combat log is closed to addons on WoW Forever (COMBAT_LOG_EVENT_UNFILTERED is restricted
-- and its payload function is secure-only), so observations come from what the client still
-- exposes:
--   * UNIT_COMBAT on "player" and "target": every hit, miss, dodge, parry, block, crit and crush,
--     with its amount and school, but not who caused it.
--   * The built-in damage meter (C_DamageMeter), readable once combat ends: damage taken per
--     creature and spell, damage done per spell, enemies' damage taken.
--   * Creatures seen by target or mouseover: level, classification, type, and whatever else the
--     client does not withhold.
--   * The death recap after a death.
--   * The addon restriction state at the start and end of each fight, so the server knows which
--     values were withheld and why.
-- Nothing here leaves the computer by itself: it is written to SavedVariables and uploaded by the
-- player. Other players' names are never stored.

local _, ns = ...

local Safe = ns.Safe

local Observations = {}
ns.Observations = Observations

local MAX_HITS_PER_FIGHT = 2000
local MAX_STORED_HITS = 100000
local MAX_FIGHTS = 1000
local MAX_ENEMY_SOURCES = 25
local MAX_RECAP_EVENTS = 20
local METER_READ_DELAY_S = 1.0
local UNIT_RESAMPLE_S = 30
local MAX_NAMEPLATES = 40
-- How long a scan of who is attacking the player is reused for the hits that follow.
local ATTACKER_SCAN_S = 0.5
local HIT_COLUMNS = { "ms", "event", "flags", "amount", "school_mask", "attackers", "attacker" }

-- Damage meter views read after each fight; the local player's spells are read for each, and
-- each enemy's for EnemyDamageTaken.
local METER_TYPES = { "DamageDone", "HealingDone", "Absorbs", "DamageTaken", "EnemyDamageTaken" }

local current -- the fight in progress, or nil
local lastScan -- { at, count, key } of the last attacker scan in this fight
local lastSampled = {} -- creature key -> GetTime() of the last sample, to throttle mouseover

local function db()
	return ns.db
end

local function now()
	return GetTime and GetTime() or 0
end

local function restrictionState(r)
	local state = {}
	local types = Enum and Enum.AddOnRestrictionType
	local isActive = Safe.api("C_RestrictedActions", "IsAddOnRestrictionActive")
	if type(types) == "table" then
		for name, value in pairs(types) do
			state[name] = r:call("C_RestrictedActions.IsAddOnRestrictionActive", isActive, value)
		end
	end
	state.CombatLog = r:call("C_CombatLog.IsCombatLogRestricted", Safe.api("C_CombatLog", "IsCombatLogRestricted"))
	return state
end

local function zone(r)
	local name, instanceType, difficultyID, _, _, _, _, instanceID = r:call("GetInstanceInfo", GetInstanceInfo)
	return {
		map_id = r:call("C_Map.GetBestMapForUnit", Safe.api("C_Map", "GetBestMapForUnit"), "player"),
		instance_name = name,
		instance_type = instanceType,
		difficulty_id = difficultyID,
		instance_id = instanceID,
	}
end

-- The creature ID is the sixth field of a creature or vehicle GUID.
function Observations.creatureIDFromGUID(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	if kind == "Creature" or kind == "Vehicle" then
		return tonumber(id)
	end
	return nil
end

-- What the character's defenses were just before a fight. Stats are secret in combat, so this is
-- refreshed whenever the player is out of combat and attached to each fight when it starts.
function Observations.refreshProfile()
	if InCombatLockdown and InCombatLockdown() then
		return
	end
	local r = Safe.report()
	local _, armor = r:call("UnitArmor", UnitArmor, "player")
	local defenseBase, defenseModifier = r:call("UnitDefenseSkill", UnitDefenseSkill, "player")
	local resistances = {}
	for index = 1, 6 do
		local _, total = r:call("UnitResistance", UnitResistance, "player", index)
		resistances[index] = total or ns.Json.null
	end
	Observations.profile = {
		level = r:call("UnitLevel", UnitLevel, "player"),
		health_max = r:call("UnitHealthMax", UnitHealthMax, "player"),
		armor = armor,
		defense = defenseBase and (defenseBase + (defenseModifier or 0)) or nil,
		dodge = r:call("GetDodgeChance", GetDodgeChance),
		parry = r:call("GetParryChance", GetParryChance),
		block = r:call("GetBlockChance", GetBlockChance),
		block_value = r:call("GetShieldBlock", GetShieldBlock),
		resistances = resistances,
		gaps = r:gapList(),
	}
end

-- Record a creature the player can see. Returns the creature's key, or nil when the unit is not
-- a creature or the client withholds everything that would identify it.
function Observations.sampleUnit(unit)
	local store = db()
	if store == nil or not store.collecting then
		return nil
	end
	local r = Safe.report()
	if not r:call("UnitExists", UnitExists, unit) or r:call("UnitIsPlayer", UnitIsPlayer, unit) then
		return nil
	end
	if r:call("UnitPlayerControlled", UnitPlayerControlled, unit) then
		return nil -- pets and minions
	end
	local creatureID = Observations.creatureIDFromGUID(r:call("UnitGUID", UnitGUID, unit))
	local name = r:call("UnitName", UnitName, unit)
	local level = r:call("UnitLevel", UnitLevel, unit)
	if creatureID == nil and name == nil then
		store.withheld_units = (store.withheld_units or 0) + 1
		return nil
	end
	local key = tostring(creatureID or name) .. ":" .. tostring(level)
	if lastSampled[key] and now() - lastSampled[key] < UNIT_RESAMPLE_S then
		return key
	end
	lastSampled[key] = now()

	local entry = store.creatures[key] or { sightings = 0, map_ids = {} }
	store.creatures[key] = entry
	entry.creature_id = creatureID or entry.creature_id
	entry.name = name or entry.name
	entry.level = level
	entry.classification = r:call("UnitClassification", UnitClassification, unit)
	entry.creature_type = r:call("UnitCreatureType", UnitCreatureType, unit)
	entry.family = r:call("UnitCreatureFamily", UnitCreatureFamily, unit)
	entry.can_attack = r:call("UnitCanAttack", UnitCanAttack, "player", unit)
	local healthMax = r:call("UnitHealthMax", UnitHealthMax, unit)
	if healthMax ~= nil then
		entry.health_max_min = math.min(entry.health_max_min or healthMax, healthMax)
		entry.health_max_max = math.max(entry.health_max_max or healthMax, healthMax)
	end
	local _, powerToken = r:call("UnitPowerType", UnitPowerType, unit)
	entry.power_type = powerToken or entry.power_type
	entry.power_max = r:call("UnitPowerMax", UnitPowerMax, unit) or entry.power_max
	local mainSpeed, offSpeed = r:call("UnitAttackSpeed", UnitAttackSpeed, unit)
	entry.attack_speed = mainSpeed or entry.attack_speed
	entry.attack_speed_off_hand = offSpeed or entry.attack_speed_off_hand
	local minDamage, maxDamage = r:call("UnitDamage", UnitDamage, unit)
	entry.damage_min = minDamage or entry.damage_min
	entry.damage_max = maxDamage or entry.damage_max
	local _, armor = r:call("UnitArmor", UnitArmor, unit)
	entry.armor = armor or entry.armor
	local mapID = r:call("C_Map.GetBestMapForUnit", Safe.api("C_Map", "GetBestMapForUnit"), "player")
	if mapID ~= nil then
		entry.map_ids[tostring(mapID)] = true
	end
	entry.sightings = entry.sightings + 1
	entry.last_seen = time and time() or nil
	entry.gaps = r:gapList()

	if current ~= nil and not current.target_keys[key] then
		current.target_keys[key] = true
		current.targets[#current.targets + 1] = key
	end
	return key
end

function Observations.startFight()
	local store = db()
	if store == nil or not store.collecting or current ~= nil then
		return
	end
	local r = Safe.report()
	current = {
		started_at = time and time() or nil,
		t0 = now(),
		zone = zone(r),
		group_size = r:call("GetNumGroupMembers", GetNumGroupMembers) or 0,
		player = Observations.profile,
		restrictions_start = restrictionState(r),
		row_columns = HIT_COLUMNS,
		hits_taken = {},
		hits_on_target = {},
		targets = {},
		target_keys = {},
		attackers = {},
		attacker_keys = {},
	}
	lastScan = nil
	Observations.sampleUnit("target")
end

-- Which creatures are attacking the player right now: hostile units on a nameplate (or the
-- target) that have the player as their tank (threat status 2 or 3). The client does not hide
-- threat between the player and a nameplate unit. Nameplates only exist for units the player
-- can see, and only while enemy nameplates are shown.
function Observations.scanAttackers()
	local r = Safe.report()
	local count, soleKey = 0, nil
	local seenGUIDs = {}
	local function consider(unit)
		if not r:call("UnitExists", UnitExists, unit) or not r:call("UnitCanAttack", UnitCanAttack, "player", unit) then
			return
		end
		local status = r:call("UnitThreatSituation", UnitThreatSituation, "player", unit)
		if status == nil or status < 2 then
			return
		end
		local guid = r:call("UnitGUID", UnitGUID, unit)
		if guid ~= nil then
			if seenGUIDs[guid] then
				return -- the target also has a nameplate
			end
			seenGUIDs[guid] = true
		end
		count = count + 1
		local key = Observations.sampleUnit(unit)
		soleKey = count == 1 and key or nil
		if current ~= nil and key ~= nil and not current.attacker_keys[key] then
			current.attacker_keys[key] = true
			current.attackers[#current.attackers + 1] = key
		end
	end
	for index = 1, MAX_NAMEPLATES do
		consider("nameplate" .. index)
	end
	consider("target")
	return count, soleKey
end

local function attackersNow()
	if lastScan == nil or now() - lastScan.at >= ATTACKER_SCAN_S then
		local count, key = Observations.scanAttackers()
		lastScan = { at = now(), count = count, key = key }
	end
	return lastScan.count, lastScan.key
end

-- Since login: how many UNIT_COMBAT amounts arrived readable or secret (for /optimizer check).
Observations.unitCombatSeen = { plain = 0, secret = 0 }

-- UNIT_COMBAT: one row per hit or avoided hit, laid out as HIT_COLUMNS. Secret payload values
-- are stored as null. For hits on the player, `attackers` is how many creatures were attacking
-- the player at that moment and `attacker` is the creature key when there was exactly one; a hit
-- with one attacker can be credited to that creature.

function Observations.onUnitCombat(unit, event, flagText, amount, schoolMask)
	if unit ~= "player" and unit ~= "target" then
		return
	end
	local seen = Observations.unitCombatSeen
	if Safe.isSecret(amount) then
		seen.secret = seen.secret + 1
	else
		seen.plain = seen.plain + 1
	end
	if current == nil then
		return
	end
	local list = unit == "player" and current.hits_taken or current.hits_on_target
	if #list >= MAX_HITS_PER_FIGHT then
		current.truncated = true
		return
	end
	local null = ns.Json.null
	local function clean(value)
		local scrubbed = Safe.scrub(value)
		if scrubbed == nil then
			return null
		end
		return scrubbed
	end
	local attackers, attacker = null, null
	if unit == "player" then
		local count, key = attackersNow()
		attackers, attacker = count, key or null
	end
	list[#list + 1] = {
		math.floor((now() - current.t0) * 1000 + 0.5),
		clean(event),
		clean(flagText),
		clean(amount),
		clean(schoolMask),
		attackers,
		attacker,
	}
end

local function spellRows(r, source, includeNames)
	local rows = {}
	for _, spell in ipairs(source and source.combatSpells or {}) do
		local details = spell.combatSpellDetails
		local targets = {}
		-- Documented as one record; accept a list too.
		local list = (type(details) == "table" and details[1] ~= nil) and details or { details }
		for _, detail in ipairs(list) do
			if type(detail) == "table" then
				targets[#targets + 1] = {
					-- Only creatures keep their name; players are reduced to their class.
					name = (detail.isMob or includeNames) and detail.unitName or nil,
					class = detail.unitClassFilename,
					classification = detail.classification,
					is_mob = detail.isMob,
					is_pet = detail.isPet,
					amount = detail.amount,
				}
			end
		end
		rows[#rows + 1] = {
			spell_id = spell.spellID,
			total = spell.totalAmount,
			per_second = spell.amountPerSecond,
			creature_name = spell.creatureName,
			overkill = spell.overkillAmount,
			avoidable = spell.isAvoidable,
			deadly = spell.isDeadly,
			targets = targets,
		}
	end
	return rows
end

local function readMeterType(r, meterType, sessionType, playerGUID)
	local fromType = Safe.api("C_DamageMeter", "GetCombatSessionFromType")
	local sourceFromType = Safe.api("C_DamageMeter", "GetCombatSessionSourceFromType")
	local label = "C_DamageMeter." .. meterType
	local session = r:call(label, fromType, sessionType, Enum.DamageMeterType[meterType])
	if type(session) ~= "table" then
		return nil
	end
	local view = {
		duration = session.durationSeconds,
		total = session.totalAmount,
		sources = {},
	}
	local enemies = 0
	for _, source in ipairs(session.combatSources or {}) do
		local isCreature = source.sourceCreatureID ~= nil
		local row = {
			creature_id = source.sourceCreatureID,
			-- Only creatures keep their name: never another player's, nor the player's own.
			name = isCreature and source.name or nil,
			is_local_player = source.isLocalPlayer,
			class = source.classFilename,
			classification = source.classification,
			total = source.totalAmount,
			per_second = source.amountPerSecond,
			died_at = (source.deathTimeSeconds or 0) > 0 and source.deathTimeSeconds or nil,
		}
		if source.isLocalPlayer and playerGUID ~= nil then
			local detail = r:call(label .. ".source", sourceFromType, sessionType, Enum.DamageMeterType[meterType], playerGUID, nil)
			row.spells = spellRows(r, detail, false)
		elseif meterType == "EnemyDamageTaken" and isCreature and enemies < MAX_ENEMY_SOURCES then
			enemies = enemies + 1
			local detail = r:call(label .. ".source", sourceFromType, sessionType, Enum.DamageMeterType[meterType], nil, source.sourceCreatureID)
			row.spells = spellRows(r, detail, false)
		end
		view.sources[#view.sources + 1] = row
	end
	return view
end

-- The built-in meter's view of the fight that just ended. Its values are secret during combat,
-- so this runs after combat ends.
function Observations.readMeter(r)
	local available, reason = r:call("C_DamageMeter.IsDamageMeterAvailable", Safe.api("C_DamageMeter", "IsDamageMeterAvailable"))
	local meter = {
		available = available,
		unavailable_reason = reason ~= "" and reason or nil,
		enabled = r:call("GetCVarBool", Safe.api("C_CVar", "GetCVarBool"), "damageMeterEnabled"),
		views = {},
	}
	if not available or not (Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType) then
		return meter
	end
	-- The meter's "current" session can span several fights that follow each other closely, so
	-- its totals are not per fight. The session list (id, name, duration) lets the importer see
	-- which fights a view covers; the per-hit rows are the per-fight record.
	meter.sessions = r:call(
		"C_DamageMeter.GetAvailableCombatSessions",
		Safe.api("C_DamageMeter", "GetAvailableCombatSessions")
	)
	local playerGUID = r:call("UnitGUID", UnitGUID, "player")
	for _, meterType in ipairs(METER_TYPES) do
		if Enum.DamageMeterType[meterType] ~= nil then
			meter.views[meterType] = readMeterType(r, meterType, Enum.DamageMeterSessionType.Current, playerGUID)
		end
	end
	return meter
end

local function readDeathRecap(r)
	local events = r:call("C_DeathRecap.GetRecapEvents", Safe.api("C_DeathRecap", "GetRecapEvents"))
	if type(events) ~= "table" then
		return nil
	end
	local kept = {}
	for index = math.max(1, #events - MAX_RECAP_EVENTS + 1), #events do
		local event = events[index]
		if type(event) == "table" then
			-- Undocumented fields: keep plain values, drop names of anything but the killer's spell.
			local row = {}
			for key, value in pairs(event) do
				local kind = type(value)
				if (kind == "number" or kind == "boolean" or kind == "string") and not tostring(key):find("[Nn]ame") then
					row[key] = value
				end
			end
			row.spellName = event.spellName
			kept[#kept + 1] = row
		end
	end
	return {
		events = kept,
		max_health = r:call("C_DeathRecap.GetRecapMaxHealth", Safe.api("C_DeathRecap", "GetRecapMaxHealth")),
	}
end

function Observations.onPlayerDead()
	if current == nil then
		return
	end
	local r = Safe.report()
	current.death = readDeathRecap(r)
	current.died_at_ms = math.floor((now() - current.t0) * 1000 + 0.5)
end

local function storedHits(fight)
	return #fight.hits_taken + #fight.hits_on_target
end

local function trim(store)
	while #store.fights > MAX_FIGHTS or (store.hits_stored or 0) > MAX_STORED_HITS do
		local dropped = table.remove(store.fights, 1)
		store.hits_stored = (store.hits_stored or 0) - storedHits(dropped)
		store.fights_dropped = (store.fights_dropped or 0) + 1
	end
end

local function finish(fight, r)
	local store = db()
	fight.meter = Observations.readMeter(r)
	fight.gaps = r:gapList()
	local meterHasData = false
	for _ in pairs(fight.meter.views) do
		meterHasData = true
	end
	if storedHits(fight) == 0 and not meterHasData and fight.death == nil then
		return
	end
	store.next_fight_id = (store.next_fight_id or 0) + 1
	fight.id = store.next_fight_id
	store.fights[#store.fights + 1] = fight
	store.hits_stored = (store.hits_stored or 0) + storedHits(fight)
	trim(store)
end

function Observations.endFight()
	if current == nil then
		return
	end
	local fight = current
	current = nil
	fight.duration_ms = math.floor((now() - fight.t0) * 1000 + 0.5)
	fight.t0 = nil
	fight.target_keys = nil
	fight.attacker_keys = nil
	local r = Safe.report()
	fight.restrictions_end = restrictionState(r)
	Observations.refreshProfile()
	local delay = Safe.api("C_Timer", "After")
	if delay ~= nil then
		delay(METER_READ_DELAY_S, function()
			finish(fight, r)
		end)
	else
		finish(fight, r)
	end
end

function Observations.inFight()
	return current ~= nil
end
