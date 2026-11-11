-- Threat: every enemy fighting the player or anyone in the party or raid, who it is on, and the
-- player's own threat on it. What matters depends on the player's role (the control panel's
-- setting, else the role the group gave them):
--   * a tank wants every enemy on them: one on someone else is listed first in red, its
--     nameplate is marked NOT ON YOU, and the moment one turns away LOST AGGRO shows in the
--     middle of the screen, with a sound;
--   * damage and healers want none on them: when their threat passes the tank's SLOW DOWN shows
--     (time to ease off, or to use something like Fade), and when an enemy turns to them AGGRO
--     ON YOU shows with a sound and its nameplate is marked ON YOU. Only in a group: alone,
--     everything is on the player anyway.
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
-- It only shows: nothing is targeted, cast or said for the player, and nothing is recorded.
-- Its settings are on the control panel (Panel.lua).

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

local GREEN, YELLOW, RED, ORANGE = { 0.3, 0.85, 0.4 }, { 1.0, 0.82, 0.1 }, { 1.0, 0.2, 0.2 }, { 1.0, 0.5, 0.1 }

-- How a row reads. `bad`: the whole row is coloured, not just its words.
Threat.STATES = {
	-- For a tank.
	you = { label = "on you", color = GREEN },
	slipping = { label = "slipping", color = YELLOW, bad = true },
	other = { label = "on %s", color = RED, bad = true },
	loose = { label = "loose", color = ORANGE, bad = true },
	-- For damage and healers.
	onme = { label = "ON YOU", color = RED, bad = true },
	pulling = { label = "slow down", color = YELLOW, bad = true },
	safe = { label = "on %s", color = GREEN },
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

-- "tank", "damage" or "healer": the setting, else the role the group gave the player (damage
-- when it gave none).
function Threat.role()
	local role = setting("role")
	if role == "tank" or role == "damage" or role == "healer" then
		return role
	end
	local assigned = read(UnitGroupRolesAssigned, "player")
	return assigned == "TANK" and "tank" or assigned == "HEALER" and "healer" or "damage"
end

function Threat.tanking()
	return Threat.role() == "tank"
end

function Threat.grouped()
	return (read(GetNumGroupMembers) or 0) > 0
end

-- "auto": in a group; "on": always in a fight; "off": never.
function Threat.enabled()
	local mode = setting("mode")
	if mode == "on" then
		return true
	elseif mode == "off" then
		return false
	end
	return Threat.grouped()
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
		-- The one closest to taking it from whoever has it, other than the player.
		local challenger, challengerPercent = nil, nil
		for _, member in ipairs(members) do
			local status = read(UnitThreatSituation, member, unit)
			if type(status) == "number" then
				engaged = true
				local isPlayer = member == "player" or read(UnitIsUnit, member, "player") == true
				if isPlayer then
					mine = status
				end
				if status >= 2 and status > holderStatus then
					holder, holderStatus = member, status
				end
				if not isPlayer and status < 2 then
					local percent = percentOf(member, unit)
					if percent ~= nil and (challengerPercent == nil or percent > challengerPercent) then
						challenger, challengerPercent = member, percent
					end
				end
			end
		end
		if not engaged then
			return
		end
		found[key] = {
			key = key,
			seen = #order + 1,
			unit = unit,
			name = rawName(unit),
			status = mine,
			holder = holder,
			holder_is_player = holder ~= nil and (holder == "player" or read(UnitIsUnit, holder, "player") == true),
			holder_name = holder and rawName(holder) or nil,
			percent = percentOf("player", unit),
			challenger = challenger,
			challenger_name = challenger and rawName(challenger) or nil,
			challenger_percent = challengerPercent,
		}
		order[#order + 1] = key
	end
	for index = 1, MAX_NAMEPLATES do
		consider("nameplate" .. index)
	end
	consider("target")
	Threat.targetKey = read(UnitGUID, "target")
	for _, member in ipairs(members) do
		consider(member == "player" and "target" or member .. "target")
	end
	return found, order
end

-- How the row reads from the player's side. A tank: "you", "slipping", "other" or "loose".
-- Damage and healers: "onme", "pulling" (above the one it is on, not yet on them), "safe" or
-- "loose".
function Threat.state(entry)
	if Threat.tanking() then
		if entry.holder_is_player then
			return entry.status == 2 and "slipping" or "you"
		end
		return entry.holder ~= nil and "other" or "loose"
	end
	if entry.holder_is_player then
		return "onme"
	end
	if entry.status == 1 then
		return "pulling"
	end
	return entry.holder ~= nil and "safe" or "loose"
end

-- The row's words: "on you", "slipping", "loose", "ON YOU", "slow down" or "on <who has it>".
function Threat.stateText(row)
	local key = Threat.state(row)
	if key ~= "other" and key ~= "safe" then
		return Threat.STATES[key].label
	end
	local holder = row.holder_name
	if Safe.isSecret(holder) or type(holder) ~= "string" then
		return "on another"
	end
	return string.format(Threat.STATES[key].label, holder)
end

-- The number a row shows, and whose it is: a tank holding an enemy sees how close the next one
-- is to taking it ("Healbot", 92); anyone else, their own threat on it (nil: the player's).
-- 100 is where it turns. nil when the client withholds it.
function Threat.shownPercent(row)
	if Threat.tanking() and row.holder_is_player then
		return row.challenger_percent, row.challenger_name
	end
	return row.percent, nil
end

-- How dangerous a number is: "calm", "warm", "hot" or "over".
function Threat.heat(percent)
	if percent == nil then
		return "calm"
	end
	if percent >= 100 then
		return "over"
	end
	return percent >= 90 and "hot" or percent >= 70 and "warm" or "calm"
end

local HEAT_COLORS = { calm = GREEN, warm = YELLOW, hot = ORANGE, over = RED }

-- What is wrong comes first, then what is about to go wrong, then the rest.
local ORDER = { other = 0, onme = 0, loose = 1, pulling = 1, slipping = 2, you = 3, safe = 3 }

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

-- The window: a title with the player's role, the current target in large print, then one bar
-- per enemy. A bar fills with the row's threat number (100% is where the enemy turns) and its
-- colour says how close that is; the row's words say who the enemy is on.
local ROLE_NAMES = { tank = "TANK", damage = "DAMAGE", healer = "HEALER" }
local FOCUS_HEIGHT = 34
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

local function rowHeight()
	return math.max(14, math.min(setting("rowHeight") or 18, 32))
end

local function focusHeight()
	return setting("focus") and FOCUS_HEIGHT or 0
end

-- A bar: a dark track, a fill as wide as the number, and words over it.
local function bar(parent, font)
	local made = CreateFrame("Frame", nil, parent)
	made.track = made:CreateTexture(nil, "BACKGROUND")
	made.track:SetAllPoints()
	made.track:SetColorTexture(1, 1, 1, 0.06)
	made.fill = made:CreateTexture(nil, "BORDER")
	made.fill:SetPoint("TOPLEFT")
	made.fill:SetPoint("BOTTOMLEFT")
	made.fill:SetTexture(BAR_TEXTURE)
	made.name = made:CreateFontString(nil, "OVERLAY", font)
	made.name:SetPoint("LEFT", 6, 0)
	made.name:SetJustifyH("LEFT")
	made.name:SetWordWrap(false)
	made.percent = made:CreateFontString(nil, "OVERLAY", font)
	made.percent:SetPoint("RIGHT", -6, 0)
	made.percent:SetJustifyH("RIGHT")
	made.state = made:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	made.state:SetPoint("RIGHT", made.percent, "LEFT", -8, 0)
	made.state:SetJustifyH("RIGHT")
	return made
end

-- Fill a bar to `percent` (of 100) in the colour of how hot it is; empty when unknown.
local function fill(made, percent, width)
	if percent == nil or not setting("bars") then
		made.fill:Hide()
		return
	end
	local r, g, b = unpack(HEAT_COLORS[Threat.heat(percent)])
	made.fill:SetVertexColor(r, g, b, 0.75)
	made.fill:SetWidth(math.max(1, width * math.min(percent, 100) / 100))
	made.fill:Show()
end

-- A player's name in their class colour, as the game's own frames show it.
local function inClassColour(name, unit)
	if type(name) ~= "string" or Safe.isSecret(name) or unit == nil then
		return name
	end
	local ok, _, class = pcall(UnitClass, unit)
	local colours = _G.RAID_CLASS_COLORS
	local known = ok and type(class) == "string" and not Safe.isSecret(class)
	local colour = known and type(colours) == "table" and colours[class] or nil
	if type(colour) == "table" and type(colour.colorStr) == "string" then
		return "|c" .. colour.colorStr .. name .. "|r"
	end
	return name
end
Threat.inClassColour = inClassColour

local function percentText(percent, whose, unit)
	if percent == nil then
		return "-"
	end
	local number = string.format("%d%%", math.min(math.floor(percent + 0.5), 999))
	if type(whose) == "string" and not Safe.isSecret(whose) then
		return number .. " " .. inClassColour(whose, unit)
	end
	return number
end
Threat.percentText = percentText

local function build()
	frame = CreateFrame("Frame", "ForeverSimThreatFrame", UIParent, "BackdropTemplate")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
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
	frame.title = frame.handle:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("LEFT", 8, 0)
	frame.title:SetText("Threat")
	frame.role = frame.handle:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.role:SetPoint("RIGHT", -8, 0)

	-- The current target, large.
	frame.focus = bar(frame, "GameFontNormalLarge")
	frame.focus:SetPoint("TOPLEFT", 4, -HEADER)
	frame.focus:SetPoint("TOPRIGHT", -4, -HEADER)

	frame.lines = {}
	for index = 1, MAX_ROW_FRAMES do
		local line = bar(frame, "GameFontHighlightSmall")
		line:EnableMouse(true)
		line:SetScript("OnEnter", showTooltip)
		line:SetScript("OnLeave", function()
			if GameTooltip then
				GameTooltip:Hide()
			end
		end)
		frame.lines[index] = line
	end

	alertFrame = CreateFrame("Frame", "ForeverSimThreatAlert", UIParent)
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
	local height, top = rowHeight(), HEADER + focusHeight()
	frame:SetScale(setting("scale"))
	frame:SetSize(setting("width"), top + (height + 2) * rows + 6)
	frame:ClearAllPoints()
	local position = setting("position")
	if type(position) == "table" and position[1] ~= nil then
		frame:SetPoint(position[1], UIParent, position[2], position[3], position[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	end
	if frame.SetBackdropColor then
		frame:SetBackdropColor(0.04, 0.05, 0.07, setting("opacity"))
		frame:SetBackdropBorderColor(1, 1, 1, setting("opacity") * 0.25)
	end
	frame.handle:EnableMouse(not setting("locked"))
	frame.focus:SetHeight(FOCUS_HEIGHT - 6)
	if setting("focus") then
		frame.focus:Show()
	else
		frame.focus:Hide()
	end
	for index, line in ipairs(frame.lines) do
		line:SetHeight(height)
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", 4, -top - (index - 1) * (height + 2))
		line:SetPoint("TOPRIGHT", -4, -top - (index - 1) * (height + 2))
		line.name:SetWidth(setting("width") - 150)
		if index > rows then
			line:Hide()
		else
			line:Show()
		end
	end
end

-- One bar's words and fill for a row (or empty for none).
local function show(line, row, width)
	line.row = row
	if row == nil then
		line.fill:Hide()
		line.name:SetText("")
		line.state:SetText("")
		line.percent:SetText("")
		line.track:SetColorTexture(1, 1, 1, 0.06)
		return
	end
	local key = Threat.state(row)
	local state = Threat.STATES[key]
	local r, g, b = unpack(state.color)
	local percent, whose = Threat.shownPercent(row)
	-- Not as it should be: the track itself takes the state's colour, so it shows at a glance.
	line.track:SetColorTexture(r, g, b, state.bad and 0.35 or 0.06)
	fill(line, percent, width)
	line.name:SetText(row.name or "?")
	line.state:SetText(Threat.stateText(row))
	line.state:SetTextColor(r, g, b)
	line.percent:SetText(percentText(percent, whose, whose and row.challenger or nil))
	line.percent:SetTextColor(unpack(percent and HEAT_COLORS[Threat.heat(percent)] or { 0.7, 0.7, 0.7 }))
end

local function render()
	if frame == nil then
		build()
	end
	local width = setting("width") - 8
	frame.role:SetText(ROLE_NAMES[Threat.role()] or "")
	-- The current target first, large: the one the player is acting on.
	local focused
	for _, row in ipairs(Threat.rows) do
		if Threat.targetKey ~= nil and row.key == Threat.targetKey then
			focused = row
		end
	end
	if setting("focus") then
		show(frame.focus, focused, width)
		if focused == nil then
			frame.focus.name:SetText("No target in the fight")
			frame.focus.name:SetTextColor(0.6, 0.6, 0.6)
		else
			frame.focus.name:SetTextColor(1, 1, 1)
		end
	end
	local shown = math.min(setting("rows"), MAX_ROW_FRAMES)
	for index, line in ipairs(frame.lines) do
		show(line, index <= shown and Threat.rows[index] or nil, width)
	end
	Threat.focused = focused
	if #Threat.rows > 0 then
		frame:Show()
	else
		frame:Hide()
	end
end

-- Words above a nameplate: a tank's enemies not on them get "NOT ON YOU"; for damage and
-- healers, enemies on them get "ON YOU".
local function marker(index)
	if markers[index] == nil then
		local mark = CreateFrame("Frame", nil, UIParent)
		mark:SetSize(140, 24)
		mark.text = mark:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		mark.text:SetPoint("CENTER")
		mark.text:SetTextColor(1, 0.15, 0.15)
		mark:Hide()
		markers[index] = mark
	end
	return markers[index]
end

-- What a row's nameplate says, or nil when it is not marked.
local function markFor(key)
	if key == "other" or key == "loose" then
		return Threat.tanking() and "NOT ON YOU" or nil
	end
	return key == "onme" and "ON YOU" or nil
end

local function mark()
	local used = 0
	local plateFor = Safe.api("C_NamePlate", "GetNamePlateForUnit")
	if setting("markers") and plateFor ~= nil and not Threat.previewing then
		for _, row in ipairs(Threat.rows) do
			local words = markFor(Threat.state(row))
			if words ~= nil and row.unit:find("^nameplate") then
				local ok, plate = pcall(plateFor, row.unit)
				if ok and plate ~= nil and not Safe.isSecret(plate) then
					used = used + 1
					local mark = marker(used)
					mark.text:SetText(words)
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

-- The warning in the middle of the screen: `title` ("LOST AGGRO", "AGGRO ON YOU", "SLOW DOWN"),
-- the enemy's name under it, and the sound when `loud`.
local function alert(entry, title, loud)
	Threat.lastAlert = { name = entry.name, unit = entry.unit, title = title }
	if alertFrame == nil then
		build()
	end
	if setting("alert") then
		alertFrame.label:SetText(title)
		alertFrame.label:SetTextColor(unpack(title == "SLOW DOWN" and YELLOW or RED))
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
	if loud and setting("sound") and sound ~= nil and type(PlaySound) == "function" then
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
	-- The warning to give, the most urgent first: (enemy, title, loud).
	local warning
	local tank, grouped = Threat.tanking(), Threat.grouped()
	for _, key in ipairs(order) do
		local entry, before = found[key], known[key]
		local wasOnMe = before ~= nil and before.holder_is_player
		if tank and wasOnMe and not entry.holder_is_player then
			warning = warning or { entry, "LOST AGGRO", true }
		elseif not tank and grouped and entry.holder_is_player and not wasOnMe then
			if warning == nil or not warning[3] then
				warning = { entry, "AGGRO ON YOU", true }
			end
		elseif not tank and grouped and entry.status == 1 and not entry.holder_is_player then
			if before == nil or (before.status or 0) < 1 then
				warning = warning or { entry, "SLOW DOWN", false }
			end
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
	if warning ~= nil then
		alert(warning[1], warning[2], warning[3])
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

-- Made-up rows to place and size the window out of combat, as the player's role sees them; off
-- again with `false`. It also ends when the control panel closes and when a fight starts.
function Threat.preview(on)
	on = on and true or false
	if on == Threat.previewing then
		return
	end
	Threat.previewing = on
	if on then
		local me = { holder = "player", holder_is_player = true }
		local function row(key, name, fields)
			fields.key, fields.unit, fields.name = key, "preview", name
			return fields
		end
		if Threat.tanking() then
			Threat.rows = {
				row("p1", "Defias Pillager", { holder = "party1", holder_name = "Healbot", status = 0, percent = 64 }),
				row("p2", "Defias Overseer", { holder = me.holder, holder_is_player = true, status = 2, percent = 100,
					challenger_name = "Stabby", challenger_percent = 97 }),
				row("p3", "Defias Taskmaster", { holder = me.holder, holder_is_player = true, status = 3, percent = 100,
					challenger_name = "Firebolt", challenger_percent = 74 }),
				row("p4", "Defias Miner", { holder = me.holder, holder_is_player = true, status = 3, percent = 100,
					challenger_name = "Healbot", challenger_percent = 31 }),
			}
		else
			Threat.rows = {
				row("p1", "Defias Overseer", { holder = me.holder, holder_is_player = true, status = 3, percent = 100 }),
				row("p2", "Defias Taskmaster", { holder = "party1", holder_name = "Tanky", status = 1, percent = 96 }),
				row("p3", "Defias Pillager", { holder = "party1", holder_name = "Tanky", status = 0, percent = 78 }),
				row("p4", "Defias Miner", { holder = "party1", holder_name = "Tanky", status = 0, percent = 35 }),
			}
		end
		Threat.targetKey = "p2"
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
		on = "the threat window is always on in a fight. /foreversim threat auto: only in a group; off: never.",
		off = "the threat window is off. /foreversim threat on turns it on; auto: only in a group.",
		auto = "the threat window shows in a fight when you are in a group. /foreversim threat on: always; off: never.",
	}
	return says[setting("mode")]
end

function Threat.init()
	ns.Options.listen("threat", function(name)
		if name == "mode" or name == "role" or name == nil then
			refreshNow()
		end
		Threat.layout()
		if frame ~= nil and #Threat.rows > 0 then
			render() -- bars, the focus line, sizes and the role show at once
		end
		if name == "markers" then
			mark()
		end
	end)
end
