-- Saved settings and statistics, events and the /foreversim command.
--
-- This is the public addon: the character export, the threat window, statistics and the
-- control panel. It records nothing for the site; recording is the invite-only recording
-- addon's (ForeverSimRecorder). When that one is installed too, the control panel shows
-- its controls (ForeverSimRecorder.api).

local addonName, ns = ...

ns.VERSION = "0.4.1"
-- Version of the snapshot payload. Bump it on any change the importer must know about.
ns.SNAPSHOT_FORMAT = "forever-optimizer/snapshot/1"

local MAX_SNAPSHOTS = 5
local MAX_EXPORT_LOG = 20

local function print(message)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66bbffForeverSim|r: " .. message)
end
ns.print = print

local function initDB()
	ForeverSimDB = ForeverSimDB or {}
	local store = ForeverSimDB
	store.snapshots = store.snapshots or {}
	store.export_log = store.export_log or {}
	ns.Options.load(store)
	ns.db = store
end

-- Every /foreversim is noted in the saved file with how it ended ("ok", "in_combat", "unreadable"
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
	print("exported. Copy the text from the window and paste it on the site's dashboard.")
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

ns.export = export

local function togglePanel()
	ns.Panel.toggle()
end

local COMMANDS = {
	[""] = export,
	export = export,
	threat = function(argument)
		print(ns.Threat.command(argument))
	end,
	panel = togglePanel,
	options = togglePanel,
	settings = togglePanel,
	help = function()
		print("/foreversim: export this character for the site. /foreversim panel: settings, the threat window and your statistics. /foreversim threat on | off | auto.")
	end,
}

SLASH_FOREVERSIM1 = "/foreversim"
-- The other spelling: without it "/fsim" does nothing and says nothing about this addon.
SLASH_FOREVERSIM2 = "/fsim"
SlashCmdList.FOREVERSIM = function(text)
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

function handlers.PLAYER_LOGIN()
	ns.Panel.register()
end

function handlers.PLAYER_ENTERING_WORLD()
	ns.Stats.start()
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

function handlers.LOOT_OPENED()
	ns.Stats.onLootOpened()
end

function handlers.LOOT_SLOT_CLEARED(slot)
	ns.Stats.onLootSlotCleared(slot)
end

function handlers.LOOT_CLOSED()
	ns.Stats.onLootClosed()
end

function handlers.MERCHANT_SHOW()
	ns.Stats.onMerchantShow()
end

function handlers.MERCHANT_CLOSED()
	ns.Stats.onMerchantClosed()
end

function handlers.BAG_UPDATE_DELAYED()
	ns.Stats.onBagsChanged()
end

function handlers.PLAYER_DEAD()
	ns.Stats.onDeath()
end

function handlers.PLAYER_REGEN_DISABLED()
	ns.Stats.onFightStart()
	ns.Threat.preview(false) -- a fight is no time for made-up rows
	ns.Panel.refresh()
	ns.Threat.refresh()
end

function handlers.PLAYER_REGEN_ENABLED()
	ns.Threat.reset()
end

function handlers.UNIT_THREAT_SITUATION_UPDATE()
	ns.Threat.refresh()
end

handlers.UNIT_THREAT_LIST_UPDATE = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.NAME_PLATE_UNIT_ADDED = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.NAME_PLATE_UNIT_REMOVED = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.PLAYER_TARGET_CHANGED = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.GROUP_ROSTER_UPDATE = handlers.UNIT_THREAT_SITUATION_UPDATE
handlers.PLAYER_ROLES_ASSIGNED = handlers.UNIT_THREAT_SITUATION_UPDATE

function handlers.BARBER_SHOP_OPEN()
	ns.db.appearance = ns.Character.readAppearance() or ns.db.appearance
end

handlers.BARBER_SHOP_CLOSE = handlers.BARBER_SHOP_OPEN

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
