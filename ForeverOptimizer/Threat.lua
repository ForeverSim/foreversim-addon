-- Threat: every enemy fighting the player or anyone in the party or raid, who it is on, and the
-- player's own threat on it. For a tank: an enemy not on the player is listed first in red and
-- its nameplate is marked, and the moment one that was on the player turns away a warning shows
-- in the middle of the screen, with a sound.
--
-- The client tells, for a group member and an enemy (UnitThreatSituation):
--   3  it is attacking them, and nobody is close to taking it;
--   2  it is attacking them, but someone else has more threat: it is about to turn;
--   1  it is attacking someone else, though they have more threat than that one;
--   0  it is attacking someone else;
--   nil  it is not fighting them.
-- And, where it does not withhold it, how much threat they have as a share of what it takes to
-- pull it (UnitDetailedThreatSituation). Enemies are found on nameplates, as the target and as
-- each group member's target. Whatever the client withholds is simply not shown.
--
-- It only shows: nothing is targeted, cast or said for the player, and nothing is recorded, so
-- it works with recording off too. Its settings are on the control panel (Panel.lua).

local _, ns = ...

local Safe = ns.Safe

local Threat = {}
ns.Threat = Threat

local MAX_NAMEPLATES = 40
local MAX_ROW_FRAMES = 20
local ROW_HEIGHT = 18
local HEADER = 22
local ALERT_SECONDS = 2.5
-- In a raid every enemy is asked about every member: not more often than this.
local RAID_REFRESH_S = 0.25

Threat.STATES = {
	you = { label = "on you", color = { 0.3, 0.9, 0.35 } },
	slipping = { label = "slipping", color = { 1.0, 0.82, 0.1 } },
	other = { label = "on %s", color = { 1.0, 0.15, 0.15 } },
	loose = { label = "loose", color = { 1.0, 0.45, 0.1 } },
}

-- key (GUID, else the unit) -> the enemy as seen last time.
local known = {}
Threat.rows = {}
Threat.lastAlert = nil
Threat.previewing = false

local frame, alertFrame
local markers = {}
local lastRefresh, refreshQueued = nil, false

local function setting(name)
	return ns.Options.get("threat." .. name)
end

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

-- A unit's name as the client gives it: shown, never read, so a secret name still shows.
local function rawName(unit)
	if type(UnitName) ~= "function" then
		return nil
	end
	local ok, name = pcall(UnitName, unit)
	return ok and name or nil
end

function Threat.setting()
	return setting("mode")
end

function Threat.enabled()
	local mode = setting("mode")
	if mode == "on" then
		return true
	elseif mode == "off" then
		return false
	end
	return read(UnitGroupRolesAssigned, "player") == "TANK"
end

-- The player and the group: party1-4, or raid1-40 (the player is one of them in a raid).
function Threat.members()
	local count = read(GetNumGroupMembers) or 0
	if read(IsInRaid) then
		local members = {}
		for index = 1, count do
			members[#members + 1] = "raid" .. index
		end
		return members
	end
	local members = { "player" }
	for index = 1, math.min(math.max(count - 1, 0), 4) do
		members[#members + 1] = "party" .. index
	end
	return members
end

local function percentOf(member, unit)
	if type(UnitDetailedThreatSituation) ~= "function" then
		return nil
	end
	local ok, _, _, scaled = pcall(UnitDetailedThreatSituation, member, unit)
	if not ok or Safe.isSecret(scaled) or type(scaled) ~= "number" then
		return nil
	end
	return scaled
end

local function scan()
	local members = Threat.members()
	local found, order = {}, {}
	local function consider(unit)
		if not read(UnitExists, unit) or read(UnitIsPlayer, unit) or read(UnitIsDead, unit) then
			return
		end
		if not read(UnitCanAttack, "player", unit) then
			return
		end
		local key = read(UnitGUID, unit) or unit
		if found[key] ~= nil then
			-- Seen again (the target also has a nameplate): keep the nameplate, it can be marked.
			if unit:find("^nameplate") and not found[key].unit:find("^nameplate") then
				found[key].unit = unit
			end
			return
		end
		local mine = nil
		local holder, holderStatus, engaged = nil, -1, false
		for _, member in ipairs(members) do
			local status = read(UnitThreatSituation, member, unit)
			if type(status) == "number" then
				engaged = true
				if read(UnitIsUnit, member, "player") or member == "player" then
					mine = status
				end
				if status >= 2 and status > holderStatus then
					holder, holderStatus = member, status
				end
			end
		end
		if not engaged then
			return
		end
		found[key] = {
			seen = #order + 1,
			unit = unit,
			name = rawName(unit),
			status = mine,
			holder = holder,
			holder_is_player = holder ~= nil and (holder == "player" or read(UnitIsUnit, holder, "player") == true),
			holder_name = holder and rawName(holder) or nil,
			percent = percentOf("player", unit),
		}
		order[#order + 1] = key
	end
	for index = 1, MAX_NAMEPLATES do
		consider("nameplate" .. index)
	end
	consider("target")
	for _, member in ipairs(members) do
		consider(member == "player" and "target" or member .. "target")
	end
	return found, order
end

-- How the row reads, from the player's side: "you", "slipping", "other" or "loose".
function Threat.state(entry)
	if entry.holder_is_player then
		return entry.status == 2 and "slipping" or "you"
	end
	return entry.holder ~= nil and "other" or "loose"
end

-- The row's words: "on you", "slipping", "loose" or "on <who has it>".
function Threat.stateText(row)
	local key = Threat.state(row)
	if key ~= "other" then
		return Threat.STATES[key].label
	end
	local holder = row.holder_name
	if Safe.isSecret(holder) or type(holder) ~= "string" then
		return "on another"
	end
	return string.format(Threat.STATES.other.label, holder)
end

-- What is wrong comes first: enemies on someone else, then loose ones, slipping, then the rest.
local ORDER = { other = 0, loose = 1, slipping = 2, you = 3 }

-- Everything the window draws. Its size and look come from the settings.
local function showTooltip(line)
	local row = line.row
	if row == nil or GameTooltip == nil then
		return
	end
	GameTooltip:SetOwner(line, "ANCHOR_LEFT")
	GameTooltip:AddLine(row.name or "?")
	for _, member in ipairs(Threat.members()) do
		local status = read(UnitThreatSituation, member, row.unit)
		if type(status) == "number" then
			local percent = percentOf(member, row.unit)
			local value = percent and string.format("%d%%", percent) or (status >= 2 and "has it" or "")
			GameTooltip:AddDoubleLine(rawName(member) or member, value)
		end
	end
	GameTooltip:Show()
end

local function build()
	frame = CreateFrame("Frame", "ForeverOptimizerThreatFrame", UIParent, "BackdropTemplate")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
	end
	-- The title is the handle the window is dragged by.
	frame.handle = CreateFrame("Frame", nil, frame)
	frame.handle:SetPoint("TOPLEFT")
	frame.handle:SetPoint("TOPRIGHT")
	frame.handle:SetHeight(HEADER)
	frame.handle:RegisterForDrag("LeftButton")
	frame.handle:SetScript("OnDragStart", function()
		if not setting("locked") then
			frame:StartMoving()
		end
	end)
	frame.handle:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, relativePoint, x, y = frame:GetPoint()
		ns.Options.set("threat.position", { point, relativePoint, x, y })
	end)
	frame.title = frame.handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.title:SetPoint("LEFT", 8, 0)
	frame.title:SetText("Threat")
	frame.lines = {}
	for index = 1, MAX_ROW_FRAMES do
		local line = CreateFrame("Frame", nil, frame)
		line:SetHeight(ROW_HEIGHT - 2)
		line:SetPoint("TOPLEFT", 4, -HEADER - (index - 1) * ROW_HEIGHT)
		line:SetPoint("TOPRIGHT", -4, -HEADER - (index - 1) * ROW_HEIGHT)
		line:EnableMouse(true)
		line:SetScript("OnEnter", showTooltip)
		line:SetScript("OnLeave", function()
			if GameTooltip then
				GameTooltip:Hide()
			end
		end)
		line.band = line:CreateTexture(nil, "BACKGROUND")
		line.band:SetAllPoints()
		line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line.name:SetPoint("LEFT", 4, 0)
		line.name:SetJustifyH("LEFT")
		line.percent = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line.percent:SetPoint("RIGHT", -4, 0)
		line.state = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		line.state:SetPoint("RIGHT", -44, 0)
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
	Threat.layout()
end

-- Size, place and look from the settings.
function Threat.layout()
	if frame == nil then
		return
	end
	local rows = math.max(1, math.min(setting("rows"), MAX_ROW_FRAMES))
	frame:SetScale(setting("scale"))
	frame:SetSize(setting("width"), HEADER + ROW_HEIGHT * rows + 6)
	frame:ClearAllPoints()
	local position = setting("position")
	if type(position) == "table" and position[1] ~= nil then
		frame:SetPoint(position[1], UIParent, position[2], position[3], position[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	end
	if frame.SetBackdropColor then
		frame:SetBackdropColor(0, 0, 0, setting("opacity"))
		frame:SetBackdropBorderColor(1, 1, 1, setting("opacity"))
	end
	frame.handle:EnableMouse(not setting("locked"))
	for index, line in ipairs(frame.lines) do
		line.name:SetWidth(setting("width") - 120)
		if index > rows then
			line:Hide()
		else
			line:Show()
		end
	end
end

local function render()
	if frame == nil then
		build()
	end
	local shown = math.min(setting("rows"), MAX_ROW_FRAMES)
	for index, line in ipairs(frame.lines) do
		local row = index <= shown and Threat.rows[index] or nil
		line.row = row
		if row == nil then
			line.band:SetColorTexture(0, 0, 0, 0)
			line.name:SetText("")
			line.state:SetText("")
			line.percent:SetText("")
		else
			local key = Threat.state(row)
			local state = Threat.STATES[key]
			local r, g, b = unpack(state.color)
			-- Not on the player: the whole row is coloured, not just its words.
			line.band:SetColorTexture(r, g, b, (key == "other" or key == "loose") and 0.55 or 0.15)
			line.name:SetText(row.name or "?")
			line.state:SetText(Threat.stateText(row))
			line.state:SetTextColor(r, g, b)
			line.percent:SetText(row.percent and string.format("%d%%", row.percent) or "")
		end
	end
	if #Threat.rows > 0 then
		frame:Show()
	else
		frame:Hide()
	end
end

-- Nameplates of enemies not on the player get "NOT ON YOU" above them.
local function marker(index)
	if markers[index] == nil then
		local mark = CreateFrame("Frame", nil, UIParent)
		mark:SetSize(140, 24)
		mark.text = mark:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		mark.text:SetPoint("CENTER")
		mark.text:SetTextColor(1, 0.15, 0.15)
		mark.text:SetText("NOT ON YOU")
		mark:Hide()
		markers[index] = mark
	end
	return markers[index]
end

local function mark()
	local used = 0
	local plateFor = Safe.api("C_NamePlate", "GetNamePlateForUnit")
	if setting("markers") and plateFor ~= nil and not Threat.previewing then
		for _, row in ipairs(Threat.rows) do
			local key = Threat.state(row)
			if (key == "other" or key == "loose") and row.unit:find("^nameplate") then
				local ok, plate = pcall(plateFor, row.unit)
				if ok and plate ~= nil and not Safe.isSecret(plate) then
					used = used + 1
					local mark = marker(used)
					mark:ClearAllPoints()
					if pcall(mark.SetPoint, mark, "BOTTOM", plate, "TOP", 0, 2) then
						mark:Show()
						Threat.marked = used
					end
				end
			end
		end
	end
	for index = used + 1, #markers do
		markers[index]:Hide()
	end
	Threat.marked = used
end

local alertSerial = 0

local function alert(entry)
	Threat.lastAlert = { name = entry.name, unit = entry.unit }
	if alertFrame == nil then
		build()
	end
	if setting("alert") then
		alertFrame.name:SetText(entry.name or "")
		alertFrame:Show()
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
	local sound = _G.SOUNDKIT and _G.SOUNDKIT.RAID_WARNING
	if setting("sound") and sound ~= nil and type(PlaySound) == "function" then
		pcall(PlaySound, sound, "Master")
	end
end

local function refreshNow()
	lastRefresh, refreshQueued = GetTime and GetTime() or 0, false
	if Threat.previewing then
		return
	end
	if not Threat.enabled() then
		Threat.reset()
		return
	end
	local found, order = scan()
	local lost
	for key, entry in pairs(found) do
		local before = known[key]
		if before ~= nil and before.holder_is_player and not entry.holder_is_player then
			lost = lost or entry
		end
	end
	known = found
	local rows = {}
	for _, key in ipairs(order) do
		rows[#rows + 1] = found[key]
	end
	table.sort(rows, function(a, b)
		local first, second = ORDER[Threat.state(a)], ORDER[Threat.state(b)]
		if first ~= second then
			return first < second
		end
		return a.seen < b.seen
	end)
	Threat.rows = rows
	render()
	mark()
	if lost ~= nil then
		alert(lost)
	end
end

function Threat.refresh()
	local members = #Threat.members()
	local now = GetTime and GetTime() or 0
	if members > 5 and lastRefresh ~= nil and now - lastRefresh < RAID_REFRESH_S then
		local after = Safe.api("C_Timer", "After")
		if after ~= nil and not refreshQueued then
			refreshQueued = true
			after(RAID_REFRESH_S, refreshNow)
		end
		return
	end
	refreshNow()
end

-- Out of combat: the fight is over, and nothing from it is kept.
function Threat.reset()
	known, Threat.rows = {}, {}
	if frame ~= nil and not Threat.previewing then
		frame:Hide()
	end
	for _, mark in ipairs(markers) do
		mark:Hide()
	end
	Threat.marked = 0
end

-- Made-up rows to place and size the window out of combat; off again with `false`.
function Threat.preview(on)
	Threat.previewing = on and true or false
	if on then
		Threat.rows = {
			{ unit = "preview", name = "Enemy on a healer", holder = "party1", holder_name = "Healer", status = 0, percent = 64 },
			{ unit = "preview", name = "Enemy about to turn", holder = "player", holder_is_player = true, status = 2, percent = 100 },
			{ unit = "preview", name = "Enemy on you", holder = "player", holder_is_player = true, status = 3, percent = 100 },
		}
		render()
		frame:Show()
	else
		Threat.rows = {}
		if frame ~= nil then
			frame:Hide()
		end
		refreshNow()
	end
end

function Threat.command(argument)
	if argument == "on" or argument == "off" or argument == "auto" then
		ns.Options.set("threat.mode", argument)
	end
	local says = {
		on = "the threat window is always on in a fight. /optimizer threat auto: only as a group's tank; off: never.",
		off = "the threat window is off. /optimizer threat on turns it on; auto: only as a group's tank.",
		auto = "the threat window shows when you are a group's tank. /optimizer threat on: always; off: never.",
	}
	return says[setting("mode")]
end

function Threat.init()
	ns.Options.listen("threat", function(name)
		if name == "mode" or name == nil then
			refreshNow()
		end
		Threat.layout()
		if name == "markers" then
			mark()
		end
	end)
end
