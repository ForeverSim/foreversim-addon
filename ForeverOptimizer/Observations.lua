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
--   * Where the player stands (map and position on it) when a fight starts and when a creature
--     is seen: the client gives no creature's position, so the player's stands in for it.
--   * Which creature each hit on the target landed on, and when a targeted creature died: the
--     damage a creature took from first hit to death is how its health is worked out, since its
--     health itself is secret.
--   * What a loot window held and what it came from (a creature, or a node or chest), with
--     the gathering spell cast just before it.
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
-- Rows of hits on the player fill `attackers` and `attacker`; rows of hits on the target fill
-- `target` (the creature key) and `target_uid` (which one of its kind: the spawn part of its GUID).
local HIT_COLUMNS = { "ms", "event", "flags", "amount", "school_mask", "attackers", "attacker", "target", "target_uid" }
local MAX_ENEMIES_PER_FIGHT = 60
local MAX_LOOTS = 5000
local MAX_SEEN_AT = 30
local MAX_BUILDS = 200
-- A loot window that opens this soon after a cast is taken to come from it (mining, skinning).
local LOOT_AFTER_CAST_S = 6

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

-- What a GUID says about a thing that is not a player: its kind ("creature" or "object"),
-- its ID, and `uid`, the part that tells one spawn of it from another. A player's GUID gives
-- kind "player" and nothing else: nothing that identifies a player is kept.
function Observations.sourceFromGUID(guid)
	if type(guid) ~= "string" then
		return nil
	end
	local kind, id, uid = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-(%x+)$")
	if kind == "Creature" or kind == "Vehicle" then
		return { kind = "creature", id = tonumber(id), uid = uid }
	elseif kind == "GameObject" then
		return { kind = "object", id = tonumber(id), uid = uid }
	end
	local other = guid:match("^(%a+)%-")
	return { kind = other == "Player" and "player" or (other and other:lower() or "unknown") }
end

-- Where the player is: the map the client shows them on and the position on it (0-1 across,
-- 0-1 down). nil where the client gives none (inside instances it does not).
function Observations.position(r)
	local mapID = r:call("C_Map.GetBestMapForUnit", Safe.api("C_Map", "GetBestMapForUnit"), "player")
	if mapID == nil then
		return nil
	end
	local point = r:call("C_Map.GetPlayerMapPosition", Safe.api("C_Map", "GetPlayerMapPosition"), mapID, "player")
	if type(point) ~= "table" or type(point.x) ~= "number" or type(point.y) ~= "number" then
		return { map_id = mapID }
	end
	return {
		map_id = mapID,
		x = math.floor(point.x * 10000 + 0.5) / 10000,
		y = math.floor(point.y * 10000 + 0.5) / 10000,
	}
end

-- What the character's defenses were just before a fight. Stats are secret in combat, so this is
-- refreshed whenever the player is out of combat and attached to each fight when it starts.
-- Talents and gear change rarely and every fight needs them, so each distinct set is stored
-- once in `builds` and a fight refers to it by its place there. Read again only after
-- something that can change it (Core says when).
local buildChanged, buildIndex = true, nil

function Observations.markBuildChanged()
	buildChanged = true
end

local function currentBuild(r)
	local store = db()
	if store == nil then
		return nil
	end
	if not buildChanged and buildIndex ~= nil and store.builds ~= nil and store.builds[buildIndex] ~= nil then
		return buildIndex
	end
	local build = ns.Character.build(r)
	local signature = ns.Json.encode(build)
	store.builds = store.builds or {}
	buildIndex = nil
	for index, known in ipairs(store.builds) do
		if ns.Json.encode(known) == signature then
			buildIndex = index
			break
		end
	end
	if buildIndex == nil and #store.builds < MAX_BUILDS then
		store.builds[#store.builds + 1] = build
		buildIndex = #store.builds
	end
	buildChanged = false
	return buildIndex
end

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
	}
	-- What the character hits with, for setting its real fights beside the simulator's.
	local profile = Observations.profile
	local apBase, apPositive, apNegative = r:call("UnitAttackPower", UnitAttackPower, "player")
	profile.attack_power = apBase and (apBase + (apPositive or 0) + (apNegative or 0)) or nil
	local minMain, maxMain = r:call("UnitDamage", UnitDamage, "player")
	profile.melee = { min = minMain, max = maxMain, speed = r:call("UnitAttackSpeed", UnitAttackSpeed, "player") }
	profile.crit = r:call("GetCritChance", GetCritChance)
	profile.hit = r:call("GetHitModifier", GetHitModifier)
	profile.spell_hit = r:call("GetSpellHitModifier", GetSpellHitModifier)
	profile.healing_power = r:call("GetSpellBonusHealing", GetSpellBonusHealing)
	-- Spell power and spell crit by school, in the client's order: holy, fire, nature, frost,
	-- shadow, arcane (school index 2 to 7).
	profile.spell_power, profile.spell_crit = {}, {}
	for index = 2, 7 do
		profile.spell_power[index - 1] = r:call("GetSpellBonusDamage", GetSpellBonusDamage, index) or ns.Json.null
		profile.spell_crit[index - 1] = r:call("GetSpellCritChance", GetSpellCritChance, index) or ns.Json.null
	end
	local _, powerToken = r:call("UnitPowerType", UnitPowerType, "player")
	profile.power = { type = powerToken, max = r:call("UnitPowerMax", UnitPowerMax, "player") }
	profile.build = currentBuild(r)
	profile.gaps = r:gapList()
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
	local where = Observations.position(r)
	if where ~= nil then
		entry.map_ids[tostring(where.map_id)] = true
		if where.x ~= nil then
			-- Where the player stood, to a hundredth of the map: near the creature, not on it.
			local cell = string.format("%d:%.2f:%.2f", where.map_id, where.x, where.y)
			entry.seen_at = entry.seen_at or {}
			if entry.seen_at[cell] ~= nil then
				entry.seen_at[cell] = entry.seen_at[cell] + 1
			elseif (entry.seen_at_cells or 0) < MAX_SEEN_AT then
				entry.seen_at[cell] = 1
				entry.seen_at_cells = (entry.seen_at_cells or 0) + 1
			end
		end
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
		position = Observations.position(r),
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
		enemies = {},
		enemy_uids = {},
		kills = {},
		killed_uids = {},
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

-- The creature the player has targeted, as its key and which one of its kind it is. The first
-- time one is met in a fight it is noted in `enemies`, with whether it was already fighting
-- (then part of its health was gone before we saw any of it).
local function targetIdentity(r)
	local source = Observations.sourceFromGUID(r:call("UnitGUID", UnitGUID, "target"))
	if source == nil or source.kind ~= "creature" then
		return nil, nil
	end
	local key = Observations.sampleUnit("target")
	if current ~= nil and key ~= nil and not current.enemy_uids[source.uid] and #current.enemies < MAX_ENEMIES_PER_FIGHT then
		current.enemy_uids[source.uid] = true
		current.enemies[#current.enemies + 1] = {
			uid = source.uid,
			key = key,
			first_ms = math.floor((now() - current.t0) * 1000 + 0.5),
			in_combat = r:call("UnitAffectingCombat", UnitAffectingCombat, "target"),
			health_percent = r:call("UnitHealthPercent", UnitHealthPercent, "target"),
		}
	end
	return key, source.uid
end

-- Note the targeted creature's death, once. Its health is secret, but that it is dead is not.
function Observations.checkKill()
	if current == nil then
		return
	end
	local r = Safe.report()
	if r:call("UnitIsDead", UnitIsDead, "target") ~= true then
		return
	end
	local key, uid = targetIdentity(r)
	if uid == nil or current.killed_uids[uid] then
		return
	end
	current.killed_uids[uid] = true
	current.kills[#current.kills + 1] = {
		uid = uid,
		key = key,
		ms = math.floor((now() - current.t0) * 1000 + 0.5),
	}
end

-- Since login: how many UNIT_COMBAT amounts arrived readable or secret (for /optimizer check).
Observations.unitCombatSeen = { plain = 0, secret = 0 }

-- UNIT_COMBAT: one row per hit or avoided hit, laid out as HIT_COLUMNS. Secret payload values
-- are stored as null. For hits on the player, `attackers` is how many creatures were attacking
-- the player at that moment and `attacker` is the creature key when there was exactly one; a hit
-- with one attacker can be credited to that creature. For hits on the target, `target` and
-- `target_uid` say which creature took it.

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
	local attackers, attacker, target, targetUID = null, null, null, null
	if unit == "player" then
		local count, key = attackersNow()
		attackers, attacker = count, key or null
	else
		local key, uid = targetIdentity(Safe.report())
		target, targetUID = key or null, uid or null
	end
	list[#list + 1] = {
		math.floor((now() - current.t0) * 1000 + 0.5),
		clean(event),
		clean(flagText),
		clean(amount),
		clean(schoolMask),
		attackers,
		attacker,
		target,
		targetUID,
	}
	if unit == "target" then
		Observations.checkKill()
	end
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
			-- GUIDs are dropped too (destGUID is the player's own, sourceGUID another player's in
			-- a duel or PvP); of the source only the creature ID is kept.
			local row = {}
			for key, value in pairs(event) do
				local kind = type(value)
				local label = tostring(key)
				if
					(kind == "number" or kind == "boolean" or kind == "string")
					and not label:find("[Nn]ame")
					and not label:find("GUID")
				then
					row[key] = value
				end
			end
			row.spellName = event.spellName
			row.source_creature_id = Observations.creatureIDFromGUID(event.sourceGUID)
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
	Observations.checkKill()
	fight.target_keys = nil
	fight.attacker_keys = nil
	fight.enemy_uids = nil
	fight.killed_uids = nil
	local r = Safe.report()
	fight.restrictions_end = restrictionState(r)
	fight.position_end = Observations.position(r)
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

-- The spell the player cast last (mining, herb gathering, skinning, opening): a loot window
-- right after it came from that.
local lastCast

function Observations.onSpellcastSucceeded(unit, _, spellID)
	if unit ~= "player" then
		return
	end
	local id = Safe.scrub(spellID)
	if type(id) == "number" then
		lastCast = { spell_id = id, at = now() }
	end
end

-- A loot window: what it holds and what each thing came from. A window can hold the loot of
-- several corpses at once; every item names its sources by their place in `sources`. Opening the
-- same corpse or node again is recorded again: its `uid` says it is the same one.
function Observations.onLootOpened()
	local store = db()
	if store == nil or not store.collecting then
		return
	end
	local r = Safe.report()
	local count = r:call("GetNumLootItems", GetNumLootItems) or 0
	local entry = {
		at = time and time() or nil,
		position = Observations.position(r),
		group_size = r:call("GetNumGroupMembers", GetNumGroupMembers) or 0,
		sources = {},
		items = {},
	}
	if lastCast ~= nil and now() - lastCast.at <= LOOT_AFTER_CAST_S then
		entry.after_spell_id = lastCast.spell_id
	end
	local sourceIndex = {}
	for slot = 1, count do
		local _, name, quantity, currencyID, quality, _, isQuestItem = r:call("GetLootSlotInfo", GetLootSlotInfo, slot)
		local link = r:call("GetLootSlotLink", GetLootSlotLink, slot)
		local item = ns.ItemLink.parse(link)
		if item ~= nil and ns.Items ~= nil then
			ns.Items.see(link, "loot")
		end
		local row = {
			slot_type = r:call("GetLootSlotType", GetLootSlotType, slot),
			item_id = item and item.item_id,
			suffix_id = item and item.suffix_id,
			-- Coins have no item: the client's own words for the amount are kept ("12 Copper").
			text = item == nil and name or nil,
			count = quantity,
			quality = quality,
			currency_id = currencyID,
			quest = isQuestItem or nil,
			from = {},
		}
		local info = { r:call("GetLootSourceInfo", GetLootSourceInfo, slot) }
		for index = 1, #info, 2 do
			local source = Observations.sourceFromGUID(info[index])
			if source ~= nil then
				local id = source.kind .. ":" .. tostring(source.id) .. ":" .. tostring(source.uid)
				if sourceIndex[id] == nil then
					entry.sources[#entry.sources + 1] = source
					sourceIndex[id] = #entry.sources
				end
				row.from[#row.from + 1] = { source = sourceIndex[id], count = info[index + 1] }
			end
		end
		entry.items[#entry.items + 1] = row
	end
	if #entry.items == 0 then
		return
	end
	entry.gaps = r:gapList()
	store.loots = store.loots or {}
	store.loots[#store.loots + 1] = entry
	while #store.loots > MAX_LOOTS do
		table.remove(store.loots, 1)
		store.loots_dropped = (store.loots_dropped or 0) + 1
	end
end
