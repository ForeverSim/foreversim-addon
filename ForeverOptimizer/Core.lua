-- Saved data, events and the /optimizer command.

local addonName, ns = ...

ns.VERSION = "0.3.1"
-- Version of the snapshot payload. Bump it on any change the importer must know about.
ns.SNAPSHOT_FORMAT = "forever-optimizer/snapshot/1"
-- Version of the SavedVariables layout for observations. 2: hit rows gained `attackers` and
-- `attacker`, and each fight names its columns (`row_columns`). Fights recorded under 1 have no
-- `row_columns` and five columns. 3: hit rows gained `target` and `target_uid`; fights gained
-- `position`, `enemies` and `kills`, and their `player` what it hits with and its `build`
-- (a place in the new `builds`); creatures gained `seen_at`; `loots` is new. 4: `items` is new
-- (equipment seen, with the level it requires as far as the client tells; Items.lua).
ns.OBSERVATIONS_FORMAT = "forever-optimizer/observations/4"

local MAX_SNAPSHOTS = 5
local MAX_EXPORT_LOG = 20
-- From here on the saved file is several megabytes and worth emptying once it has been sent.
local LARGE_FILE_HITS = 50000

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
	-- Recording is the player's choice (`recording_choice`: "yes" or "no"), asked for in a
	-- window when the game starts. Until it is made nothing is recorded, also for someone who
	-- used a version that recorded without asking.
	if store.recording_choice ~= "yes" then
		store.collecting = false
	elseif store.collecting == nil then
		store.collecting = true
	end
	store.snapshots = store.snapshots or {}
	store.fights = store.fights or {}
	store.creatures = store.creatures or {}
	store.checks = store.checks or {}
	store.export_log = store.export_log or {}
	store.loots = store.loots or {}
	store.builds = store.builds or {}
	store.items = store.items or {}
	ns.Options.load(store)
	ns.db = store
end

-- Every /optimizer is noted in the saved file with how it ended ("ok", "in_combat", "unreadable"
-- or "error" with the message), so a file without the expected export says why.
local function logExport(outcome, detail)
	local log = ns.db.export_log
	local r = ns.Safe.report()
	local _, class = r:call("UnitClass", UnitClass, "player")
	log[#log + 1] = {
		at = time and time() or nil,
		class = class,
		level = r:call("UnitLevel", UnitLevel, "player"),
		outcome = outcome,
		detail = detail,
	}
	while #log > MAX_EXPORT_LOG do
		table.remove(log, 1)
	end
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

local function readAndShow()
	local snapshot, reason = ns.Character.snapshot(ns.db.appearance)
	if snapshot == nil then
		logExport(reason == "in_combat" and "in_combat" or "unreadable")
		print(reason == "in_combat" and "leave combat first: stats cannot be read in combat." or "could not read the character.")
		return
	end
	local text = ns.Json.encode(snapshot)
	table.insert(ns.db.snapshots, snapshot)
	while #ns.db.snapshots > MAX_SNAPSHOTS do
		table.remove(ns.db.snapshots, 1)
	end
	saveExport(snapshot, text)
	logExport("ok")
	ns.UI.showExport(text)
	print("exported. The file on disk only has it after /reload or logging out: do that before sending the file.")
	if #snapshot.gaps > 0 then
		print(#snapshot.gaps .. " values were not available from the client; the site will show which.")
	end
end

local function export()
	-- pcall: the client hides addon errors by default, and an export that stops halfway must
	-- say so instead of showing nothing.
	local function run()
		local ok, message = pcall(readAndShow)
		if not ok then
			logExport("error", tostring(message))
			print("the export failed: " .. tostring(message))
		end
	end
	pcall(ns.Character.requestSpellData)
	-- Give the client a moment to load spell descriptions before they are read.
	local delay = ns.Safe.api("C_Timer", "After")
	if delay ~= nil then
		delay(1.0, run)
	else
		run()
	end
end

-- The player's answer, from the window or from /optimizer pause and resume. It is remembered.
function ns.setRecording(on)
	ns.Stats.tick() -- the time recorded so far is added before the switch
	ns.db.recording_choice = on and "yes" or "no"
	ns.db.collecting = on
	ns.Stats.tick()
	if on then
		ns.Observations.markBuildChanged()
		ns.Observations.refreshProfile()
		print("recording is on. /optimizer pause stops it; /optimizer status shows what is kept.")
	else
		print("recording is off. /optimizer resume turns it on.")
	end
end

-- Once, when the game has started: ask, or say that recording is on.
local function greet()
	local store = ns.db
	if store.recording_choice == nil then
		local ok = pcall(ns.UI.askToRecord, ns.setRecording)
		if not ok then
			print("fights are not recorded yet. /optimizer resume turns recording on.")
		end
	elseif store.collecting then
		print(string.format("recording is on (%d fights kept). /optimizer pause stops it.", #store.fights))
		if (store.hits_stored or 0) > LARGE_FILE_HITS then
			print("the saved file has grown large. Once you have sent it, /optimizer clear confirm empties it.")
		end
	end
end

local function status()
	local store = ns.db
	local creatures = 0
	for _ in pairs(store.creatures) do
		creatures = creatures + 1
	end
	print(string.format(
		"collecting %s. %d fights, %d hits, %d creatures, %d loot windows, %d items recorded.",
		store.collecting and "on" or "paused",
		#store.fights,
		store.hits_stored or 0,
		creatures,
		#store.loots,
		store.items_count or 0
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

ns.export = export

-- Empty the saved file of everything recorded (the settings and the statistics stay).
function ns.clearRecorded()
	ns.db.fights, ns.db.creatures, ns.db.hits_stored, ns.db.fights_dropped = {}, {}, 0, 0
	ns.db.loots, ns.db.loots_dropped, ns.db.builds = {}, 0, {}
	ns.db.items, ns.db.items_count, ns.db.items_dropped = {}, 0, 0
	ns.Observations.markBuildChanged()
end

local function togglePanel()
	ns.Panel.toggle()
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
		ns.setRecording(false)
	end,
	resume = function()
		ns.setRecording(true)
	end,
	clear = function(argument)
		if argument ~= "confirm" then
			print("type /optimizer clear confirm to delete all recorded fights, creatures, loot and items.")
			return
		end
		ns.clearRecorded()
		print("recorded fights, creatures, loot and items deleted.")
	end,
	threat = function(argument)
		print(ns.Threat.command(argument))
	end,
	panel = togglePanel,
	options = togglePanel,
	settings = togglePanel,
	help = function()
		print("/optimizer: export this character. /optimizer panel | check | status | pause | resume | clear | threat")
	end,
}

SLASH_FOREVEROPTIMIZER1 = "/optimizer"
-- The other spelling: without it "/optimiser" does nothing and says nothing about this addon.
SLASH_FOREVEROPTIMIZER2 = "/optimiser"
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
	ns.Threat.init()
	events:UnregisterEvent("ADDON_LOADED")
end

-- Anything that can change talents or gear: the build is read again before the next fight.
local function buildMayHaveChanged()
	ns.Observations.markBuildChanged()
	ns.Observations.refreshProfile()
end

function handlers.PLAYER_LOGIN()
	greet()
	ns.Items.watchTooltips()
	ns.Panel.register()
end

function handlers.PLAYER_LOGOUT()
	ns.Stats.tick()
end

function handlers.PLAYER_MONEY()
	ns.Stats.onMoney()
end

function handlers.PLAYER_XP_UPDATE(unit)
	if unit == nil or unit == "player" then
		ns.Stats.onXP()
	end
end

function handlers.LOOT_SLOT_CLEARED(slot)
	ns.Stats.onLootSlotCleared(slot)
end

function handlers.LOOT_CLOSED()
	ns.Stats.onLootClosed()
end

function handlers.MERCHANT_CLOSED()
	ns.Stats.onMerchantClosed()
end

function handlers.PLAYER_ENTERING_WORLD()
	ns.Stats.start()
	buildMayHaveChanged()
	ns.Items.scanWorn()
	ns.Items.scanBags()
end

function handlers.PLAYER_EQUIPMENT_CHANGED()
	buildMayHaveChanged()
	ns.Items.scanWorn()
end
handlers.PLAYER_LEVEL_UP = buildMayHaveChanged
handlers.TRAIT_CONFIG_UPDATED = buildMayHaveChanged
handlers.PLAYER_TALENT_UPDATE = buildMayHaveChanged

function handlers.PLAYER_REGEN_DISABLED()
	ns.Observations.startFight()
	ns.Threat.refresh()
end

function handlers.PLAYER_REGEN_ENABLED()
	ns.Observations.endFight()
	ns.Threat.reset()
end

function handlers.UNIT_THREAT_SITUATION_UPDATE()
	ns.Threat.refresh()
end

handlers.UNIT_THREAT_LIST_UPDATE = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.NAME_PLATE_UNIT_REMOVED = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.GROUP_ROSTER_UPDATE = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.PLAYER_ROLES_ASSIGNED = handlers.UNIT_THREAT_SITUATION_UPDATE

function handlers.BAG_UPDATE_DELAYED()
	ns.Items.scanBags()
	ns.Stats.onBagsChanged()
end

function handlers.BANKFRAME_OPENED()
	ns.Items.scanBank()
end

function handlers.MERCHANT_SHOW()
	ns.Stats.onMerchantShow()
	ns.Items.scanMerchant()
end

function handlers.MERCHANT_UPDATE()
	ns.Items.scanMerchant()
end

function handlers.UNIT_COMBAT(unit, event, flagText, amount, schoolMask)
	ns.Observations.onUnitCombat(unit, event, flagText, amount, schoolMask)
end

function handlers.PLAYER_TARGET_CHANGED()
	ns.Observations.sampleUnit("target")
	ns.Observations.refreshProfile()
	ns.Threat.refresh()
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
	ns.Observations.sampleUnit(unit)
	ns.Threat.refresh()
end

function handlers.UPDATE_MOUSEOVER_UNIT()
	ns.Observations.sampleUnit("mouseover")
end

function handlers.PLAYER_DEAD()
	ns.Observations.onPlayerDead()
end

function handlers.UNIT_HEALTH(unit)
	if unit == "target" then
		ns.Observations.checkKill()
	end
end

function handlers.LOOT_OPENED()
	ns.Observations.onLootOpened()
	ns.Stats.onLootOpened()
end

function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)
	ns.Observations.onSpellcastSucceeded(unit, castGUID, spellID)
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
