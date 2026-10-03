-- /optimizer check: what this client actually lets the addon read, right now.
--
-- The API documentation says which values *may* be secret, not when. This runs the open
-- questions (docs/addon.md, "Must be checked in game") against the live client and stores the
-- answers, so a tester can run it in different places (open world, dungeon, with an NPC
-- targeted) and send the file back.

local _, ns = ...

local Safe = ns.Safe

local Check = {}
ns.Check = Check

local MAX_CHECKS = 50

local function restrictions()
	-- Every type is listed, false included, so "not restricted" is distinguishable from "unknown".
	local state = ns.Json.object()
	local types = Enum and Enum.AddOnRestrictionType
	local isActive = Safe.api("C_RestrictedActions", "IsAddOnRestrictionActive")
	if type(types) == "table" and isActive then
		for name, value in pairs(types) do
			local ok, active = pcall(isActive, value)
			if ok and not Safe.isSecret(active) then
				state[name] = active == true
			end
		end
	end
	return state
end

local function targetProbes(unit)
	if not (UnitExists and UnitExists(unit)) then
		return nil
	end
	return {
		is_player = Safe.probe(UnitIsPlayer, unit),
		guid = Safe.probe(UnitGUID, unit),
		name = Safe.probe(UnitName, unit),
		level = Safe.probe(UnitLevel, unit),
		classification = Safe.probe(UnitClassification, unit),
		creature_type = Safe.probe(UnitCreatureType, unit),
		health = Safe.probe(UnitHealth, unit),
		health_max = Safe.probe(UnitHealthMax, unit),
		armor = Safe.probe(UnitArmor, unit),
		resistance_fire = Safe.probe(UnitResistance, unit, 2),
		attack_speed = Safe.probe(UnitAttackSpeed, unit),
		damage = Safe.probe(UnitDamage, unit),
		-- Is the player this unit's tank? Attribution of hits depends on it being readable.
		threat_on_player = Safe.probe(UnitThreatSituation, "player", unit),
	}
end

local function meterProbes()
	local probes = {
		available = Safe.probe(Safe.api("C_DamageMeter", "IsDamageMeterAvailable")),
		enabled_setting = Safe.probe(Safe.api("C_CVar", "GetCVarBool"), "damageMeterEnabled"),
		sessions = Safe.probe(Safe.api("C_DamageMeter", "GetAvailableCombatSessions")),
	}
	local fromType = Safe.api("C_DamageMeter", "GetCombatSessionFromType")
	if Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType and fromType then
		local ok, session = pcall(fromType, Enum.DamageMeterSessionType.Current, Enum.DamageMeterType.DamageTaken)
		if ok and type(session) == "table" then
			local clean, anySecret = Safe.scrub(session)
			probes.last_damage_taken = {
				any_secret = anySecret,
				sources = clean and clean.combatSources and #clean.combatSources or 0,
				total = clean and clean.totalAmount,
			}
		end
	end
	return probes
end

-- Field names of the latest death recap event: they are undocumented.
local function deathRecapFields()
	local get = Safe.api("C_DeathRecap", "GetRecapEvents")
	if get == nil then
		return { status = "missing" }
	end
	local ok, events = pcall(get)
	if not ok or type(events) ~= "table" or #events == 0 then
		return { status = ok and "no_recap" or "error" }
	end
	local fields = {}
	for key, value in pairs(events[#events]) do
		fields[#fields + 1] = tostring(key) .. ":" .. (Safe.isSecret(value) and "secret" or type(value))
	end
	table.sort(fields)
	return { status = "ok", fields = fields }
end

function Check.run()
	local snapshot, reason = ns.Character.snapshot(ns.db.appearance)
	local talentNodes = {}
	for i, node in ipairs(snapshot and snapshot.talents.nodes or {}) do
		if i > 10 then
			break
		end
		talentNodes[i] = { node_id = node.node_id, spell_id = node.spell_id, rank = node.rank }
	end
	local result = {
		checked_at = time and time() or nil,
		addon_version = ns.VERSION,
		build = snapshot and snapshot.client.build or nil,
		in_combat = InCombatLockdown and InCombatLockdown() or false,
		restrictions = restrictions(),
		zone = { instance = Safe.probe(GetInstanceInfo), map = Safe.probe(Safe.api("C_Map", "GetBestMapForUnit"), "player") },
		snapshot = snapshot and { gap_count = #snapshot.gaps, gaps = snapshot.gaps } or { refused = reason },
		talent_nodes = talentNodes,
		target = targetProbes("target"),
		mouseover = targetProbes("mouseover"),
		unit_combat_since_login = ns.Observations.unitCombatSeen,
		nameplate1 = targetProbes("nameplate1"),
		enemy_nameplates_shown = Safe.probe(Safe.api("C_CVar", "GetCVarBool"), "nameplateShowEnemies"),
		damage_meter = meterProbes(),
		death_recap = deathRecapFields(),
		encoding = {
			serialize_json = Safe.api("C_EncodingUtil", "SerializeJSON") ~= nil,
			compress = Safe.api("C_EncodingUtil", "CompressString") ~= nil,
			base64 = Safe.api("C_EncodingUtil", "EncodeBase64") ~= nil,
		},
		combat_log_restricted = Safe.probe(Safe.api("C_CombatLog", "IsCombatLogRestricted")),
	}
	local checks = ns.db.checks
	checks[#checks + 1] = result
	while #checks > MAX_CHECKS do
		table.remove(checks, 1)
	end
	return result
end
