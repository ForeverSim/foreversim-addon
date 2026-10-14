-- The control panel: recording on and off, the threat window's settings, and what has been
-- recorded so far. /optimizer panel opens it, and so does its entry in the game's AddOns options.
-- New pages are added to PAGES.

local _, ns = ...

local Panel = {}
ns.Panel = Panel

local WIDTH, HEIGHT = 460, 470
local frame
local pages, tabs = {}, {}
-- Controls by name, so their state can be refreshed (and tested).
Panel.controls = {}

local QUALITY_NAMES = { [0] = "grey", [1] = "white", [2] = "green", [3] = "blue", [4] = "purple", [5] = "orange" }

-- --- Building blocks ----------------------------------------------------------------------------

local function text(parent, font, value)
	local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	label:SetJustifyH("LEFT")
	if value ~= nil then
		label:SetText(value)
	end
	return label
end

local function button(parent, label, width, onClick)
	local made = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	made:SetSize(width or 140, 22)
	made:SetText(label)
	made:SetScript("OnClick", onClick)
	return made
end

local function check(parent, label, path)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.label = text(parent, "GameFontHighlight", label)
	box.label:SetPoint("LEFT", box, "RIGHT", 4, 0)
	box:SetScript("OnClick", function(self)
		ns.Options.set(path, self:GetChecked() and true or false)
	end)
	box.refresh = function()
		box:SetChecked(ns.Options.get(path) and true or false)
	end
	Panel.controls[path] = box
	return box
end

-- A slider for a number setting, with its value written beside it.
local function slider(parent, label, path, low, high, step, shown)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(400, 40)
	holder.label = text(holder, "GameFontHighlight", label)
	holder.label:SetPoint("TOPLEFT")
	holder.value = text(holder, "GameFontNormal")
	holder.value:SetPoint("TOPRIGHT", -40, 0)
	local bar = CreateFrame("Slider", nil, holder, "BackdropTemplate")
	bar:SetOrientation("HORIZONTAL")
	bar:SetSize(300, 16)
	bar:SetPoint("TOPLEFT", 0, -18)
	bar:SetMinMaxValues(low, high)
	bar:SetValueStep(step)
	bar:SetObeyStepOnDrag(true)
	bar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	if bar.SetBackdrop then
		bar:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 } })
	end
	local quiet = false
	bar:SetScript("OnValueChanged", function(_, value)
		value = math.floor(value / step + 0.5) * step
		holder.value:SetText(shown(value))
		if not quiet then
			ns.Options.set(path, value)
		end
	end)
	holder.bar = bar
	holder.refresh = function()
		quiet = true
		bar:SetValue(ns.Options.get(path))
		holder.value:SetText(shown(ns.Options.get(path)))
		quiet = false
	end
	Panel.controls[path] = holder
	return holder
end

-- A row of buttons for a setting with a few values; the chosen one is marked.
local function choice(parent, label, path, options)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(420, 44)
	holder.label = text(holder, "GameFontHighlight", label)
	holder.label:SetPoint("TOPLEFT")
	holder.buttons = {}
	for index, option in ipairs(options) do
		local pick = button(holder, option.label, 130, function()
			ns.Options.set(path, option.value)
			holder.refresh()
		end)
		pick:SetPoint("TOPLEFT", (index - 1) * 136, -18)
		pick.value = option.value
		holder.buttons[index] = pick
	end
	holder.refresh = function()
		for _, pick in ipairs(holder.buttons) do
			if ns.Options.get(path) == pick.value then
				pick:LockHighlight()
			else
				pick:UnlockHighlight()
			end
		end
	end
	Panel.controls[path] = holder
	return holder
end

-- Lay controls out from the top of a page, one under the other.
local used = {}

local function stack(page, control, gap, indent)
	control:SetPoint("TOPLEFT", page, "TOPLEFT", indent or 0, -(used[page] or 0))
	used[page] = (used[page] or 0) + (gap or 30)
	return control
end

-- --- Pages --------------------------------------------------------------------------------------

local function recordingPage(page)
	page.status = stack(page, text(page, "GameFontNormalLarge"), 30)
	page.toggle = stack(page, button(page, "", 180, function()
		ns.setRecording(not (ns.db and ns.db.collecting))
		Panel.refresh()
	end), 34)
	Panel.controls["recording"] = page.toggle
	stack(page, button(page, "Export character", 180, function()
		ns.export()
	end), 40)
	local note = stack(page, text(page, "GameFontHighlightSmall"), 70)
	note:SetWidth(WIDTH - 60)
	note:SetText("Fights, creatures, loot and the gear you see are written to the saved file when you log out or type /reload. Send that file to have it added to the site: WTF/Account/<account>/SavedVariables/ForeverOptimizer.lua")
	-- Emptying the file takes two clicks.
	local armed = false
	page.clear = stack(page, button(page, "Delete recorded data", 180, function(self)
		if armed then
			ns.clearRecorded()
			armed = false
			self:SetText("Delete recorded data")
			Panel.refresh()
		else
			armed = true
			self:SetText("Click again to delete")
		end
	end), 30)
	Panel.controls["clear"] = page.clear
	page.refresh = function()
		local on = ns.db and ns.db.collecting
		page.status:SetText(on and "Recording is on" or "Recording is off")
		page.toggle:SetText(on and "Stop recording" or "Start recording")
	end
end

local function threatPage(page)
	stack(page, choice(page, "Show the threat window", "threat.mode", {
		{ value = "auto", label = "As a group's tank" },
		{ value = "on", label = "Always" },
		{ value = "off", label = "Never" },
	}), 50)
	stack(page, slider(page, "Size", "threat.scale", 0.5, 2.0, 0.05, function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end), 44)
	stack(page, slider(page, "Width", "threat.width", 160, 440, 10, function(v)
		return tostring(v)
	end), 44)
	stack(page, slider(page, "Rows", "threat.rows", 3, 20, 1, function(v)
		return tostring(v)
	end), 44)
	stack(page, slider(page, "Background", "threat.opacity", 0, 1, 0.05, function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end), 48)
	stack(page, check(page, "Lock its place", "threat.locked"), 26)
	stack(page, check(page, "Warning in the middle of the screen when an enemy turns away", "threat.alert"), 26)
	stack(page, check(page, "Sound with the warning", "threat.sound"), 26)
	stack(page, check(page, "Mark the nameplates of enemies not on you", "threat.markers"), 32)
	local preview = button(page, "Preview", 130, function(self)
		ns.Threat.preview(not ns.Threat.previewing)
		self:SetText(ns.Threat.previewing and "End preview" or "Preview")
	end)
	stack(page, preview, 0)
	Panel.controls["preview"] = preview
	local reset = button(page, "Reset", 130, function()
		ns.Options.reset("threat")
		Panel.refresh()
	end)
	reset:SetPoint("LEFT", preview, "RIGHT", 8, 0)
	Panel.controls["reset"] = reset
end

-- The lines of the statistics page: { label, value } each.
function Panel.statistics()
	local s = ns.Stats.summary()
	local qualities = {}
	for quality = 0, 5 do
		local count = s.by_quality[tostring(quality)]
		if count then
			qualities[#qualities + 1] = count .. " " .. QUALITY_NAMES[quality]
		end
	end
	local since = s.since and date and date("%d %b %Y", s.since) or "-"
	return {
		{ "Recording", s.recording and "on" or "off" },
		{ "Recording since", since },
		{ "Time recorded", ns.Stats.duration(s.seconds) },
		{ "Fights", string.format("%d (%d in the file)", s.fights, s.fights_kept) },
		{ "Kills", tostring(s.kills) },
		{ "Deaths", tostring(s.deaths) },
		{ "Hits recorded", tostring(s.hits) },
		{ "Creatures seen", tostring(s.creatures) },
		{ "Loot windows", tostring(s.loot_windows) },
		{ "Gear seen", tostring(s.gear_seen) },
		{ "Gold looted", ns.Stats.money(s.money_looted) },
		{ "Items looted", string.format("%d (%d kinds)%s", s.items_looted, s.items_looted_kinds, #qualities > 0 and ": " .. table.concat(qualities, ", ") or "") },
		{ "Items sold", string.format("%d (%d kinds) for %s", s.items_sold, s.items_sold_kinds, ns.Stats.money(s.money_sold)) },
		{ "Experience gained", string.format("%d (%d level%s)", s.xp, s.levels, s.levels == 1 and "" or "s") },
	}
end

local function statisticsPage(page)
	page.lines = {}
	page.refresh = function()
		ns.Stats.tick()
		for index, line in ipairs(Panel.statistics()) do
			local shown = page.lines[index]
			if shown == nil then
				shown = { label = text(page, "GameFontNormal"), value = text(page, "GameFontHighlight") }
				shown.label:SetPoint("TOPLEFT", 0, -(index - 1) * 22)
				shown.value:SetPoint("TOPLEFT", 170, -(index - 1) * 22)
				shown.value:SetWidth(WIDTH - 210)
				page.lines[index] = shown
			end
			shown.label:SetText(line[1])
			shown.value:SetText(line[2])
		end
	end
end

local PAGES = {
	{ key = "recording", title = "Recording", build = recordingPage },
	{ key = "threat", title = "Threat window", build = threatPage },
	{ key = "statistics", title = "Statistics", build = statisticsPage },
}

-- --- The window ---------------------------------------------------------------------------------

function Panel.select(key)
	for _, page in pairs(pages) do
		page:Hide()
	end
	for _, tab in pairs(tabs) do
		tab:UnlockHighlight()
	end
	if pages[key] ~= nil then
		pages[key]:Show()
		tabs[key]:LockHighlight()
		Panel.current = key
		Panel.refresh()
	end
end

function Panel.refresh()
	for _, control in pairs(Panel.controls) do
		if type(control) == "table" and control.refresh then
			control.refresh()
		end
	end
	for _, page in pairs(pages) do
		if page.refresh then
			page.refresh()
		end
	end
end

local function build()
	frame = CreateFrame("Frame", "ForeverOptimizerPanel", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it
	frame.title = text(frame, "GameFontHighlight", "Forever Optimizer")
	frame.title:SetPoint("TOP", 0, -6)
	for index, spec in ipairs(PAGES) do
		local tab = button(frame, spec.title, 140, function()
			Panel.select(spec.key)
		end)
		tab:SetPoint("TOPLEFT", 12 + (index - 1) * 146, -30)
		tabs[spec.key] = tab
		local page = CreateFrame("Frame", nil, frame)
		page:SetPoint("TOPLEFT", 20, -66)
		page:SetPoint("BOTTOMRIGHT", -20, 16)
		spec.build(page)
		page:Hide()
		pages[spec.key] = page
	end
	-- While open, the statistics keep up with what is happening.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + (delta or 0)
		if elapsed >= 1 and Panel.current == "statistics" then
			elapsed = 0
			pages.statistics.refresh()
		end
	end)
	Panel.select("recording")
end

function Panel.show(key)
	if frame == nil then
		build()
	end
	frame:Show()
	Panel.select(key or Panel.current or "recording")
end

function Panel.toggle()
	if frame ~= nil and frame:IsShown() then
		frame:Hide()
	else
		Panel.show()
	end
end

-- An entry in the game's own options (Options, AddOns) that opens the panel.
function Panel.register()
	local settings = _G.Settings
	if type(settings) ~= "table" or type(settings.RegisterCanvasLayoutCategory) ~= "function" then
		return false
	end
	return pcall(function()
		local canvas = CreateFrame("Frame")
		local about = text(canvas, "GameFontHighlight", "Recording, the threat window and what has been recorded so far.")
		about:SetPoint("TOPLEFT", 16, -16)
		local open = button(canvas, "Open the control panel", 200, function()
			Panel.show()
		end)
		open:SetPoint("TOPLEFT", 16, -44)
		local category = settings.RegisterCanvasLayoutCategory(canvas, "Forever Optimizer")
		settings.RegisterAddOnCategory(category)
	end)
end

