-- The control panel: the character export, the threat window's settings, statistics, recording
-- (when the recording addon is installed) and help. /foreversim panel opens it, and so does its
-- entry in the game's AddOns options. New pages are added to PAGES; each starts by saying what
-- it is for.

local _, ns = ...

local Panel = {}
ns.Panel = Panel

local WIDTH, HEIGHT = 560, 760
local TAB_WIDTH = 102
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

-- A paragraph that says what a page or a setting is for.
local function explain(page, words, height)
	local paragraph = text(page, "GameFontHighlightSmall", words)
	paragraph:SetWidth(WIDTH - 60)
	paragraph:SetJustifyV("TOP")
	return stack(page, paragraph, height or 40)
end

-- --- Pages --------------------------------------------------------------------------------------

local function characterPage(page)
	explain(page, "Export reads your character as it is now (gear, talents, professions, stats and spellbook) and shows it as text. Copy it and paste it on the site's dashboard: that is how your character gets onto the site. Nothing leaves the game by itself.", 56)
	stack(page, button(page, "Export character", 180, function()
		ns.export()
	end), 40)
	explain(page, "Leave combat first: the game hides stats during a fight. The same export is /foreversim.", 30)
end

-- The recording addon's page: only there when ForeverSim Recorder is installed.
local function recorder()
	local api = _G.ForeverSimRecorder
	return type(api) == "table" and api or nil
end

local function recordingPage(page)
	explain(page, "ForeverSim Recorder is installed: it records how creatures fight, what drops and the gear you see, for the site's simulator. It only records while it is on, and nothing leaves your computer until you upload its file on the site's recording page.", 56)
	page.status = stack(page, text(page, "GameFontNormalLarge"), 30)
	page.toggle = stack(page, button(page, "", 180, function()
		local api = recorder()
		if api ~= nil then
			api.setRecording(not api.isRecording())
		end
		Panel.refresh()
	end), 34)
	Panel.controls["recording"] = page.toggle
	page.counts = stack(page, text(page, "GameFontHighlight"), 110)
	page.counts:SetWidth(WIDTH - 60)
	page.counts:SetJustifyV("TOP")
	explain(page, "The game writes the file when you log out or type /reload: WTF/Account/<account>/SavedVariables/ForeverSimRecorder.lua. Upload it, then empty it here so the next file only holds what is new (fights already uploaded are counted once anyway).", 56)
	-- Emptying the file takes two clicks.
	local armed = false
	page.clear = stack(page, button(page, "Delete recorded data", 180, function(self)
		local api = recorder()
		if armed and api ~= nil then
			api.clear()
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
		local api = recorder()
		if api == nil then
			return
		end
		local on = api.isRecording()
		page.status:SetText(on and "Recording is on" or "Recording is off")
		page.toggle:SetText(on and "Stop recording" or "Start recording")
		local kept = api.summary()
		page.counts:SetText(table.concat({
			string.format("Time recorded: %s", ns.Stats.duration(kept.seconds)),
			string.format("Fights: %d (%d in the file)", kept.fights, kept.fights_kept),
			string.format("Hits: %d   Creatures: %d", kept.hits, kept.creatures),
			string.format("Loot windows: %d   Gear seen: %d", kept.loot_windows, kept.gear_seen),
		}, "\n"))
	end
end

local function threatPage(page)
	explain(page, table.concat({
		"Every enemy fighting you or your group, who it is on, and your threat on it.",
		"A tank is warned when an enemy leaves them: red rows, NOT ON YOU on its nameplate, LOST AGGRO.",
		"Damage and healers are warned before they pull (SLOW DOWN: ease off, or use something like Fade)",
		"and when they do (AGGRO ON YOU). Hover a row for everyone's threat; click a nameplate to target.",
	}, " "), 70)
	stack(page, choice(page, "Show the threat window", "threat.mode", {
		{ value = "auto", label = "In a group" },
		{ value = "on", label = "Always" },
		{ value = "off", label = "Never" },
	}), 46)
	stack(page, choice(page, "Your role (it decides what you are warned about)", "threat.role", {
		{ value = "auto", label = "The group's choice" },
		{ value = "tank", label = "Tank" },
		{ value = "damage", label = "Damage or healer" },
	}), 46)
	stack(page, slider(page, "Size", "threat.scale", 0.5, 2.0, 0.05, function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end), 44)
	stack(page, slider(page, "Width", "threat.width", 160, 440, 10, function(v)
		return tostring(v)
	end), 44)
	stack(page, slider(page, "Rows", "threat.rows", 3, 20, 1, function(v)
		return tostring(v)
	end), 44)
	stack(page, slider(page, "Row height", "threat.rowHeight", 14, 32, 1, function(v)
		return tostring(v) .. " px"
	end), 44)
	stack(page, slider(page, "Background", "threat.opacity", 0, 1, 0.05, function(v)
		return string.format("%d%%", math.floor(v * 100 + 0.5))
	end), 48)
	stack(page, check(page, "Threat bars (100% is where an enemy turns)", "threat.bars"), 26)
	stack(page, check(page, "Your target in large print at the top", "threat.focus"), 26)
	stack(page, check(page, "Lock its place", "threat.locked"), 26)
	stack(page, check(page, "Warning in the middle of the screen when an enemy turns away", "threat.alert"), 26)
	stack(page, check(page, "Sound with the warning", "threat.sound"), 26)
	stack(page, check(page, "Mark the nameplates of enemies not on you", "threat.markers"), 32)
	explain(page, "Preview shows made-up rows so you can place and size the window out of combat; drag it by its title.", 28)
	local preview = button(page, "Preview", 130, function()
		ns.Threat.preview(not ns.Threat.previewing)
		Panel.refresh()
	end)
	preview.refresh = function()
		preview:SetText(ns.Threat.previewing and "End preview" or "Preview")
	end
	stack(page, preview, 0)
	Panel.controls["preview"] = preview
	local reset = button(page, "Reset", 130, function()
		ns.Threat.preview(false)
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
		{ "Counting since", since },
		{ "Time played", ns.Stats.duration(s.seconds) },
		{ "Fights", tostring(s.fights) },
		{ "Deaths", tostring(s.deaths) },
		{ "Gold looted", ns.Stats.money(s.money_looted) },
		{ "Items looted", string.format("%d (%d kinds)%s", s.items_looted, s.items_looted_kinds, #qualities > 0 and ": " .. table.concat(qualities, ", ") or "") },
		{ "Items sold", string.format("%d (%d kinds) for %s", s.items_sold, s.items_sold_kinds, ns.Stats.money(s.money_sold)) },
		{ "Experience gained", string.format("%d (%d level%s)", s.xp, s.levels, s.levels == 1 and "" or "s") },
	}
end

local function statisticsPage(page)
	explain(page, "What you got while playing with the addon on: counted from your own purse, loot windows, bags and experience bar. It stays on your computer.", 40)
	page.top = 40
	page.lines = {}
	page.refresh = function()
		ns.Stats.tick()
		for index, line in ipairs(Panel.statistics()) do
			local shown = page.lines[index]
			if shown == nil then
				shown = { label = text(page, "GameFontNormal"), value = text(page, "GameFontHighlight") }
				shown.label:SetPoint("TOPLEFT", 0, -page.top - (index - 1) * 22)
				shown.value:SetPoint("TOPLEFT", 170, -page.top - (index - 1) * 22)
				shown.value:SetWidth(WIDTH - 210)
				page.lines[index] = shown
			end
			shown.label:SetText(line[1])
			shown.value:SetText(line[2])
		end
	end
end

local HELP = table.concat({
	"/foreversim  export your character (the Character page)",
	"/foreversim panel  this window",
	"/foreversim threat on | off | auto  when the threat window shows",
	"",
	"What this addon keeps: your settings, your last exports and your statistics, in its own saved file on your computer. It sends nothing anywhere: the game does not let addons use the network.",
	"",
	"Threat comes from the game itself. Where the game withholds a number (another player's threat in some places), the window leaves it out rather than guess.",
	"",
	"Something wrong or missing? Use the feedback button on the site.",
}, "\n")

local function helpPage(page)
	local words = stack(page, text(page, "GameFontHighlight", HELP), 300)
	words:SetWidth(WIDTH - 60)
	words:SetJustifyV("TOP")
end

-- ForeverSim Macros' page: only there when that addon is installed.
local function macros()
	local api = _G.ForeverSimMacros
	return type(api) == "table" and api or nil
end

local function macrosPage(page)
	explain(page, "ForeverSim Macros is installed: make macros by picking what they should do, with every part explained. Copy the result into the game's macro window (Game Menu, Macros).", 56)
	Panel.controls["macros"] = stack(page, button(page, "Open the macro maker", 200, function()
		local api = macros()
		if api ~= nil then
			api.open()
		end
	end), 34)
	stack(page, button(page, "How macros work", 200, function()
		local api = macros()
		if api ~= nil then
			api.open("guide")
		end
	end), 34)
end

local PAGES = {
	{ key = "character", title = "Character", build = characterPage },
	{ key = "threat", title = "Threat window", build = threatPage },
	{ key = "statistics", title = "Statistics", build = statisticsPage },
	{ key = "recording", title = "Recording", build = recordingPage, available = recorder },
	{ key = "macros", title = "Macros", build = macrosPage, available = macros },
	{ key = "help", title = "Help", build = helpPage },
}

-- --- The window ---------------------------------------------------------------------------------

function Panel.select(key)
	if key ~= "threat" then
		ns.Threat.preview(false) -- the preview belongs to the threat page
	end
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
	frame = CreateFrame("Frame", "ForeverSimPanel", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it
	frame.title = text(frame, "GameFontHighlight", "ForeverSim")
	frame.title:SetPoint("TOP", 0, -6)
	local placed = 0
	for _, spec in ipairs(PAGES) do
		if spec.available == nil or spec.available() then
			placed = placed + 1
			local tab = button(frame, spec.title, TAB_WIDTH, function()
				Panel.select(spec.key)
			end)
			tab:SetPoint("TOPLEFT", 12 + (placed - 1) * (TAB_WIDTH + 4), -30)
			tabs[spec.key] = tab
			local page = CreateFrame("Frame", nil, frame)
			page:SetPoint("TOPLEFT", 20, -66)
			page:SetPoint("BOTTOMRIGHT", -20, 16)
			spec.build(page)
			page:Hide()
			pages[spec.key] = page
		end
	end
	-- Closing the panel ends the preview: the made-up rows never stay on screen.
	frame:SetScript("OnHide", function()
		ns.Threat.preview(false)
		Panel.refresh()
	end)
	-- While open, the statistics keep up with what is happening.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + (delta or 0)
		if elapsed >= 1 and Panel.current == "statistics" then
			elapsed = 0
			pages.statistics.refresh()
		end
	end)
	Panel.select("character")
end

function Panel.show(key)
	if frame == nil then
		build()
	end
	frame:Show()
	Panel.select(key or Panel.current or "character")
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
		local about = text(canvas, "GameFontHighlight", "The character export, the threat window, your statistics and help.")
		about:SetPoint("TOPLEFT", 16, -16)
		local open = button(canvas, "Open the control panel", 200, function()
			Panel.show()
		end)
		open:SetPoint("TOPLEFT", 16, -44)
		local category = settings.RegisterCanvasLayoutCategory(canvas, "ForeverSim")
		settings.RegisterAddOnCategory(category)
	end)
end

