-- Threat: the enemies around the player that are fighting, and whether each is on the player.
-- For a tank: the moment one that was on the player turns to someone else, it is shown in red
-- and a warning appears in the middle of the screen, with a sound.
--
-- The client tells, for each enemy with a nameplate (and the target), where the player stands
-- with it (UnitThreatSituation, not secret between the player and a nameplate unit):
--   3  it is attacking the player, and nobody is close to taking it;
--   2  it is attacking the player, but someone else has more threat: it is about to turn;
--   1  it is attacking someone else, though the player has more threat than they do;
--   0  it is attacking someone else;
--   nil  it is not fighting the player's side at all (not listed).
-- It only shows: nothing is targeted, cast or said for the player, and nothing is recorded.
-- Shown for a player in the tank role of a group, or always/never: /optimizer threat on | off.

local _, ns = ...

local Safe = ns.Safe

local Threat = {}
ns.Threat = Threat

local MAX_NAMEPLATES = 40
local MAX_ROWS = 10
local ROW_HEIGHT = 18
local WIDTH = 230
local ALERT_SECONDS = 2.5

Threat.STATES = {
	[3] = { label = "on you", color = { 0.3, 0.9, 0.35 } },
	[2] = { label = "slipping", color = { 1.0, 0.82, 0.1 } },
	[1] = { label = "not on you", color = { 1.0, 0.45, 0.1 } },
	[0] = { label = "NOT ON YOU", color = { 1.0, 0.15, 0.15 } },
}

-- key (GUID, else the unit) -> { unit, status, name, held } for the enemies seen last time.
local known = {}
-- The rows as last shown, in order, and the last warning: what the tests and the frame read.
Threat.rows = {}
Threat.lastAlert = nil

local frame, alertFrame

local function read(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	if not ok then
		return nil
	end
	return (Safe.scrub(value))
end

-- The unit's name as the client gives it: shown, never read, so a secret name still shows.
local function rawName(unit)
	if type(UnitName) ~= "function" then
		return nil
	end
	local ok, name = pcall(UnitName, unit)
	return ok and name or nil
end

function Threat.setting()
	return ns.db and ns.db.threat or "auto"
end

function Threat.enabled()
	local setting = Threat.setting()
	if setting == "on" then
		return true
	elseif setting == "off" then
		return false
	end
	return read(UnitGroupRolesAssigned, "player") == "TANK"
end

local function scan()
	local found, order = {}, {}
	local function consider(unit)
		if not read(UnitExists, unit) or read(UnitIsPlayer, unit) or read(UnitIsDead, unit) then
			return
		end
		if not read(UnitCanAttack, "player", unit) then
			return
		end
		local status = read(UnitThreatSituation, "player", unit)
		if type(status) ~= "number" then
			return
		end
		local key = read(UnitGUID, unit) or unit
		if found[key] ~= nil then
			return -- the target also has a nameplate
		end
		found[key] = { unit = unit, status = status, name = rawName(unit) }
		order[#order + 1] = key
	end
	for index = 1, MAX_NAMEPLATES do
		consider("nameplate" .. index)
	end
	consider("target")
	return found, order
end

-- What is wrong comes first: enemies not on the player, then the ones slipping, then the rest.
local function urgency(entry)
	if entry.status <= 1 then
		return entry.held and 0 or 1
	end
	return entry.status == 2 and 2 or 3
end

local function build()
	frame = CreateFrame("Frame", "ForeverOptimizerThreatFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, 24 + ROW_HEIGHT * MAX_ROWS)
	frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
		frame:SetBackdropColor(0, 0, 0, 0.6)
	end
	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.title:SetPoint("TOPLEFT", 8, -6)
	frame.title:SetText("Threat")
	frame.lines = {}
	for index = 1, MAX_ROWS do
		local line = {}
		line.band = frame:CreateTexture(nil, "BACKGROUND")
		line.band:SetPoint("TOPLEFT", 4, -20 - (index - 1) * ROW_HEIGHT)
		line.band:SetSize(WIDTH - 8, ROW_HEIGHT - 2)
		line.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line.name:SetPoint("TOPLEFT", 8, -22 - (index - 1) * ROW_HEIGHT)
		line.name:SetWidth(WIDTH - 100)
		line.name:SetJustifyH("LEFT")
		line.state = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line.state:SetPoint("TOPRIGHT", -8, -22 - (index - 1) * ROW_HEIGHT)
		frame.lines[index] = line
	end

	alertFrame = CreateFrame("Frame", "ForeverOptimizerThreatAlert", UIParent)
	alertFrame:SetSize(600, 80)
	alertFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
	alertFrame:SetFrameStrata("HIGH")
	alertFrame.label = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	alertFrame.label:SetPoint("TOP")
	alertFrame.label:SetTextColor(1, 0.15, 0.15)
	alertFrame.label:SetText("LOST AGGRO")
	alertFrame.name = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	alertFrame.name:SetPoint("TOP", alertFrame.label, "BOTTOM", 0, -4)
	alertFrame:Hide()
end

local function render()
	if frame == nil then
		build()
	end
	for index, line in ipairs(frame.lines) do
		local row = Threat.rows[index]
		if row == nil then
			line.band:SetColorTexture(0, 0, 0, 0)
			line.name:SetText("")
			line.state:SetText("")
		else
			local state = Threat.STATES[row.status] or Threat.STATES[0]
			local r, g, b = unpack(state.color)
			-- Not on the player: the whole row is red, not just its words.
			line.band:SetColorTexture(r, g, b, row.status <= 1 and 0.55 or 0.15)
			line.name:SetText(row.name or "?")
			line.state:SetText(state.label)
			line.state:SetTextColor(r, g, b)
		end
	end
	if #Threat.rows > 0 then
		frame:Show()
	else
		frame:Hide()
	end
end

local alertSerial = 0

local function alert(entry)
	Threat.lastAlert = { name = entry.name, unit = entry.unit }
	if alertFrame == nil then
		build()
	end
	alertFrame.name:SetText(entry.name or "")
	alertFrame:Show()
	local sound = _G.SOUNDKIT and _G.SOUNDKIT.RAID_WARNING
	if sound ~= nil and type(PlaySound) == "function" then
		pcall(PlaySound, sound, "Master")
	end
	alertSerial = alertSerial + 1
	local mine = alertSerial
	local after = Safe.api("C_Timer", "After")
	if after ~= nil then
		after(ALERT_SECONDS, function()
			if mine == alertSerial then
				alertFrame:Hide()
			end
		end)
	end
end

function Threat.refresh()
	if not Threat.enabled() then
		known, Threat.rows = {}, {}
		if frame ~= nil then
			frame:Hide()
		end
		return
	end
	local found, order = scan()
	local lost
	for key, entry in pairs(found) do
		local before = known[key]
		entry.held = (before ~= nil and before.held) or entry.status >= 2
		if before ~= nil and before.status >= 2 and entry.status <= 1 then
			lost = lost or entry
		end
	end
	known = found
	local rows = {}
	for _, key in ipairs(order) do
		rows[#rows + 1] = found[key]
	end
	table.sort(rows, function(a, b)
		return urgency(a) < urgency(b)
	end)
	while #rows > MAX_ROWS do
		table.remove(rows)
	end
	Threat.rows = rows
	render()
	if lost ~= nil then
		alert(lost)
	end
end

-- Out of combat: the fight is over, and nothing from it is kept.
function Threat.reset()
	known, Threat.rows = {}, {}
	if frame ~= nil then
		frame:Hide()
	end
end

function Threat.command(argument)
	if argument == "on" or argument == "off" or argument == "auto" then
		ns.db.threat = argument
		Threat.refresh()
	end
	local says = {
		on = "the threat window is always on in a fight. /optimizer threat auto: only as a group's tank; off: never.",
		off = "the threat window is off. /optimizer threat on turns it on; auto: only as a group's tank.",
		auto = "the threat window shows when you are a group's tank. /optimizer threat on: always; off: never.",
	}
	return says[Threat.setting()]
end
