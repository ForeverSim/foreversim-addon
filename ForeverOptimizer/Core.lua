-- Saved data, events and the /optimizer command.

local addonName, ns = ...

ns.VERSION = "0.1.0"
-- Version of the snapshot payload. Bump it on any change the importer must know about.
ns.SNAPSHOT_FORMAT = "forever-optimizer/snapshot/1"
-- Version of the SavedVariables layout for observations. 2: hit rows gained `attackers` and
-- `attacker`, and each fight names its columns (`row_columns`). Fights recorded under 1 have no
-- `row_columns` and five columns.
ns.OBSERVATIONS_FORMAT = "forever-optimizer/observations/2"

local MAX_SNAPSHOTS = 5

local function print(message)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66bbffForever Optimizer|r: " .. message)
end

local function initDB()
	ForeverOptimizerDB = ForeverOptimizerDB or {}
	local store = ForeverOptimizerDB
	if store.format ~= ns.OBSERVATIONS_FORMAT then
		-- Fights are kept as recorded: each says its own layout through `row_columns`.
		store.format = ns.OBSERVATIONS_FORMAT
	end
	if store.collecting == nil then
		store.collecting = true
	end
	store.snapshots = store.snapshots or {}
	store.fights = store.fights or {}
	store.creatures = store.creatures or {}
	store.checks = store.checks or {}
	ns.db = store
end

-- The export as the site reads it from the SavedVariables file: gzip then base64 when the client
-- offers C_EncodingUtil, plain JSON otherwise. The encoding is named so the importer knows.
local function packForFile(text)
	local compress = ns.Safe.api("C_EncodingUtil", "CompressString")
	local base64 = ns.Safe.api("C_EncodingUtil", "EncodeBase64")
	local gzip = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Gzip
	if compress and base64 and gzip then
		local ok, packed = pcall(function()
			return base64(compress(text, gzip))
		end)
		if ok and type(packed) == "string" then
			return "gzip+base64", packed
		end
	end
	return "json", text
end

local function saveExport(snapshot, text)
	local encoding, data = packForFile(text)
	local character = snapshot.character
	ns.db.export = {
		format = ns.SNAPSHOT_FORMAT,
		created_at = snapshot.captured_at,
		character = tostring(character.name) .. "-" .. tostring(character.realm),
		encoding = encoding,
		bytes = #text,
		data = data,
	}
end

local function export()
	ns.Character.requestSpellData()
	-- Give the client a moment to load spell descriptions before they are read.
	C_Timer.After(1.0, function()
		local snapshot, reason = ns.Character.snapshot(ns.db.appearance)
		if snapshot == nil then
			print(reason == "in_combat" and "leave combat first: stats cannot be read in combat." or "could not read the character.")
			return
		end
		table.insert(ns.db.snapshots, snapshot)
		while #ns.db.snapshots > MAX_SNAPSHOTS do
			table.remove(ns.db.snapshots, 1)
		end
		local text = ns.Json.encode(snapshot)
		saveExport(snapshot, text)
		ns.UI.showExport(text)
		print("saved for upload; it is written to disk on logout or /reload.")
		if #snapshot.gaps > 0 then
			print(#snapshot.gaps .. " values were not available from the client; the site will show which.")
		end
	end)
end

local function status()
	local store = ns.db
	local creatures = 0
	for _ in pairs(store.creatures) do
		creatures = creatures + 1
	end
	print(string.format(
		"collecting %s. %d fights, %d hits, %d creatures recorded.",
		store.collecting and "on" or "paused",
		#store.fights,
		store.hits_stored or 0,
		creatures
	))
	local enabled = C_CVar and C_CVar.GetCVarBool and C_CVar.GetCVarBool("damageMeterEnabled")
	if not enabled then
		print("the built-in damage meter is off; turning it on (Options > Gameplay) records more per fight.")
	end
	local plates = C_CVar and C_CVar.GetCVarBool and C_CVar.GetCVarBool("nameplateShowEnemies")
	if not plates then
		print("enemy nameplates are off (V); with them on, each hit is matched to the creature that dealt it.")
	end
	print("data is saved in WTF/Account/<account>/SavedVariables/" .. addonName .. ".lua on logout or /reload.")
end

local COMMANDS = {
	[""] = export,
	export = export,
	status = status,
	check = function()
		local result = ns.Check.run()
		local target = result.target and result.target.guid.values[1] or "no target"
		print(string.format(
			"check saved. snapshot gaps: %s, target GUID: %s, hits seen plain/secret: %d/%d.",
			result.snapshot.gap_count or "refused",
			target,
			result.unit_combat_since_login.plain,
			result.unit_combat_since_login.secret
		))
		ns.UI.showExport(ns.Json.encode(result))
	end,
	pause = function()
		ns.db.collecting = false
		print("combat recording paused.")
	end,
	resume = function()
		ns.db.collecting = true
		print("combat recording on.")
	end,
	clear = function(argument)
		if argument ~= "confirm" then
			print("type /optimizer clear confirm to delete all recorded fights and creatures.")
			return
		end
		ns.db.fights, ns.db.creatures, ns.db.hits_stored, ns.db.fights_dropped = {}, {}, 0, 0
		print("recorded fights and creatures deleted.")
	end,
	help = function()
		print("/optimizer: export this character. /optimizer check | status | pause | resume | clear")
	end,
}

SLASH_FOREVEROPTIMIZER1 = "/optimizer"
SlashCmdList.FOREVEROPTIMIZER = function(text)
	local command, argument = (text or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	local handler = COMMANDS[command] or COMMANDS.help
	handler(argument)
end

local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= addonName then
		return
	end
	initDB()
	events:UnregisterEvent("ADDON_LOADED")
end

function handlers.PLAYER_ENTERING_WORLD()
	ns.Observations.refreshProfile()
end

function handlers.PLAYER_EQUIPMENT_CHANGED()
	ns.Observations.refreshProfile()
end

function handlers.PLAYER_LEVEL_UP()
	ns.Observations.refreshProfile()
end

function handlers.PLAYER_REGEN_DISABLED()
	ns.Observations.startFight()
end

function handlers.PLAYER_REGEN_ENABLED()
	ns.Observations.endFight()
end

function handlers.UNIT_COMBAT(unit, event, flagText, amount, schoolMask)
	ns.Observations.onUnitCombat(unit, event, flagText, amount, schoolMask)
end

function handlers.PLAYER_TARGET_CHANGED()
	ns.Observations.sampleUnit("target")
	ns.Observations.refreshProfile()
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
	ns.Observations.sampleUnit(unit)
end

function handlers.UPDATE_MOUSEOVER_UNIT()
	ns.Observations.sampleUnit("mouseover")
end

function handlers.PLAYER_DEAD()
	ns.Observations.onPlayerDead()
end

function handlers.BARBER_SHOP_OPEN()
	ns.db.appearance = ns.Character.readAppearance() or ns.db.appearance
end

function handlers.BARBER_SHOP_CLOSE()
	ns.db.appearance = ns.Character.readAppearance() or ns.db.appearance
end

for event in pairs(handlers) do
	-- pcall: an event this client does not know must not stop the others from registering.
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
	if ns.db == nil and event ~= "ADDON_LOADED" then
		return
	end
	handlers[event](...)
end)
