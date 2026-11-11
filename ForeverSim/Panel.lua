-- The control panel: the character export, the threat window's settings, statistics, recording
-- (when ForeverSim Recorder is installed), macros (when ForeverSim Macros is) and help.
-- /foreversim panel opens it, and so does its entry in the game's AddOns options.
--
-- Laid out with the shared Kit (addon/shared/Kit.lua): pages down the left, and on each page a
-- heading, what the page is for, then its settings in sections, each with what it does.

local _, ns = ...

local Kit = ns.Kit
local C = Kit.COLOURS

local Panel = {}
ns.Panel = Panel

local WIDTH, HEIGHT = 760, 560
local frame
local pages = {}
-- Controls by name, so their state can be refreshed (and tested).
Panel.controls = {}

local QUALITY_NAMES = { [0] = "grey", [1] = "white", [2] = "green", [3] = "blue", [4] = "purple", [5] = "orange" }

local function setting(name)
	return function()
		return ns.Options.get(name)
	end, function(value)
		ns.Options.set(name, value)
	end
end

local function percent(value)
	return string.format("%d%%", math.floor(value * 100 + 0.5))
end

-- The other addons, when they are installed.
local function recorder()
	local api = _G.ForeverSimRecorder
	return type(api) == "table" and api or nil
end

local function macros()
	local api = _G.ForeverSimMacros
	return type(api) == "table" and api or nil
end

-- --- Pages ---------------------------------------------------------------------------------------

local function characterPage(column)
	column:heading("Your character")
	column:paragraph("Export reads your character as it is now (gear, talents, professions, stats and spellbook) and shows it as text. Copy it and paste it on the site's dashboard: that is how your character gets onto the site.")
	column:button("Export character", function()
		ns.export()
	end, 200, "primary")
	column:paragraph("Leave combat first: the game hides stats during a fight. Typing /foreversim does the same.")
end

local function threatPage(column)
	column:heading("Threat window")
	column:paragraph("In a fight it lists every enemy fighting you or your group, who it is on, and a bar of threat: at 100% the enemy turns. Hover a row for everyone's threat on it; click the enemy's nameplate to target it.")
	column:button(ns.Threat.previewing and "End preview" or "Preview", function()
		ns.Threat.preview(not ns.Threat.previewing)
		Panel.refresh()
	end, 160)
	local preview = column.placed[#column.placed].widget
	preview.refresh = function()
		preview:SetText(ns.Threat.previewing and "End preview" or "Preview")
	end
	Panel.controls["preview"] = preview
	column:paragraph("Preview shows made-up rows, so you can place and size the window out of combat. Drag it by its title.")
	column:rule()

	column:subheading("Who it is for")
	local get, set = setting("threat.mode")
	Panel.controls["threat.mode"] = column:choice("When it shows", "In a group: in every fight while you are in a party or raid.", {
		{ value = "auto", label = "In a group" },
		{ value = "on", label = "Always" },
		{ value = "off", label = "Never" },
	}, get, set)
	get, set = setting("threat.role")
	local roleHelp = "A tank is warned when an enemy leaves them (LOST AGGRO). Damage and healers are warned before they pull "
		.. "(SLOW DOWN: ease off, or use something like Fade) and when they do (AGGRO ON YOU). The group's choice is the role your group gave you."
	Panel.controls["threat.role"] = column:choice("Your role", roleHelp, {
		{ value = "auto", label = "The group's choice", width = 170 },
		{ value = "tank", label = "Tank", width = 110 },
		{ value = "damage", label = "Damage or healer", width = 170 },
	}, get, set)
	column:rule()

	column:subheading("Warnings")
	get, set = setting("threat.alert")
	Panel.controls["threat.alert"] = column:check("Warning in the middle of the screen", "LOST AGGRO, AGGRO ON YOU or SLOW DOWN, with the enemy's name, for a moment.", get, set)
	get, set = setting("threat.sound")
	Panel.controls["threat.sound"] = column:check("Sound with the warning", "The raid warning sound, when an enemy turns to you or away from you.", get, set)
	get, set = setting("threat.markers")
	Panel.controls["threat.markers"] = column:check("Mark nameplates", "NOT ON YOU over a tank's enemies on someone else; ON YOU over the enemies on a damage dealer or healer.", get, set)
	column:rule()

	column:subheading("Look")
	get, set = setting("threat.bars")
	Panel.controls["threat.bars"] = column:check("Threat bars", "Each row fills with its threat, from green to red as it nears 100%.", get, set)
	get, set = setting("threat.focus")
	Panel.controls["threat.focus"] = column:check("Your target, large, at the top", nil, get, set)
	get, set = setting("threat.scale")
	Panel.controls["threat.scale"] = column:slider("Size", nil, 0.5, 2.0, 0.05, get, set, percent)
	get, set = setting("threat.width")
	Panel.controls["threat.width"] = column:slider("Width", nil, 160, 440, 10, get, set, tostring)
	get, set = setting("threat.rows")
	Panel.controls["threat.rows"] = column:slider("Rows", "Enemies shown at once; what is most urgent comes first.", 3, 20, 1, get, set, tostring)
	get, set = setting("threat.rowHeight")
	Panel.controls["threat.rowHeight"] = column:slider("Row height", nil, 14, 32, 1, get, set, function(v)
		return v .. " px"
	end)
	get, set = setting("threat.opacity")
	Panel.controls["threat.opacity"] = column:slider("Background", nil, 0, 1, 0.05, get, set, percent)
	get, set = setting("threat.locked")
	Panel.controls["threat.locked"] = column:check("Lock its place", "It cannot be dragged by accident.", get, set)
	column:rule()
	Panel.controls["reset"] = column:button("Reset to the defaults", function()
		ns.Threat.preview(false)
		ns.Options.reset("threat")
		Panel.refresh()
	end, 200, "quiet")
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

local function statisticsPage(column, page)
	column:heading("Statistics")
	column:paragraph("What you got while playing with the addon on, counted from your own purse, loot windows, bags and experience bar. It stays on your computer.")
	local card = column:card(40)
	local inner = card.column
	page.lines = {}
	for index, line in ipairs(Panel.statistics()) do
		local label = Kit.text(card, "GameFontHighlight", C.muted)
		label:SetText(line[1])
		local value = Kit.text(card, "GameFontHighlight", C.text)
		value:SetWidth(inner.width - 170)
		inner:place(label, 16)
		value:SetPoint("TOPLEFT", label, "TOPLEFT", 170, 0)
		page.lines[index] = { label = label, value = value }
	end
	column:after(card)
	page.refresh = function()
		ns.Stats.tick()
		for index, line in ipairs(Panel.statistics()) do
			page.lines[index].label:SetText(line[1])
			page.lines[index].value:SetText(line[2])
		end
	end
end

local function recordingPage(column, page)
	column:heading("Recording")
	column:paragraph("ForeverSim Recorder is installed: it records how creatures fight, what drops and the gear you see, for the site's simulator. "
		.. "It only records while it is on, and nothing leaves your computer until you upload its file on the site's recording page.")
	page.status = column:subheading("")
	page.toggle = column:button("", function()
		local api = recorder()
		if api ~= nil then
			api.setRecording(not api.isRecording())
		end
		Panel.refresh()
	end, 200, "primary")
	Panel.controls["recording"] = page.toggle
	local card = column:card(40)
	page.counts = card.column:paragraph("", C.text)
	column:after(card)
	column:paragraph("The game writes the file when you log out or reload: WTF/Account/<account>/SavedVariables/ForeverSimRecorder.lua. Upload it on the site, then empty it here, so the next file only holds what is new.")
	local armed = false
	page.clear = column:button("Delete recorded data", function(self)
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
	end, 200, "quiet")
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
			"Time recorded: " .. ns.Stats.duration(kept.seconds),
			string.format("Fights: %d (%d in the file)", kept.fights, kept.fights_kept),
			string.format("Hits: %d    Creatures: %d", kept.hits, kept.creatures),
			string.format("Loot windows: %d    Gear seen: %d", kept.loot_windows, kept.gear_seen),
		}, "\n"))
	end
end

local function macrosPage(column)
	column:heading("Macros")
	column:paragraph("ForeverSim Macros is installed: make macros by answering a few questions, with every part explained. Copy the result into the game's macro window (Game Menu, Macros).")
	Panel.controls["macros"] = column:button("Open the macro maker", function()
		local api = macros()
		if api ~= nil then
			api.open()
		end
	end, 200, "primary")
	column:button("How macros work", function()
		local api = macros()
		if api ~= nil then
			api.open("guide")
		end
	end, 200, "quiet")
end

local function helpPage(column)
	column:heading("Help")
	column:subheading("Commands")
	column:paragraph("/foreversim: export your character.\n/foreversim panel: this window.\n/foreversim threat on, off or auto: when the threat window shows.", C.text)
	column:subheading("What it keeps")
	column:paragraph("Your settings, your last exports and your statistics, in the addon's own saved file on your computer. It sends nothing anywhere: the game does not let addons use the network.")
	column:subheading("Threat")
	column:paragraph("Threat comes from the game itself. Where the game withholds a number (another player's threat in some places), the window leaves it out rather than guess.")
	column:subheading("Something wrong?")
	column:paragraph("Use the feedback button on the site.")
end

local PAGES = {
	{ key = "character", title = "Character", build = characterPage },
	{ key = "threat", title = "Threat window", build = threatPage },
	{ key = "statistics", title = "Statistics", build = statisticsPage },
	{ key = "recording", title = "Recording", build = recordingPage, available = recorder },
	{ key = "macros", title = "Macros", build = macrosPage, available = macros },
	{ key = "help", title = "Help", build = helpPage },
}

-- --- The window ----------------------------------------------------------------------------------

function Panel.select(key)
	if key ~= "threat" then
		ns.Threat.preview(false) -- the preview belongs to the threat page
	end
	for name, page in pairs(pages) do
		if name == key then
			page:Show()
		else
			page:Hide()
		end
	end
	if pages[key] ~= nil then
		Kit.selectTab(frame, key)
		Panel.current = key
		Panel.refresh()
	end
end

function Panel.refresh()
	for _, control in pairs(Panel.controls) do
		if type(control) == "table" and type(rawget(control, "refresh")) == "function" then
			control.refresh()
		end
	end
	for _, page in pairs(pages) do
		if type(rawget(page, "refresh")) == "function" then
			page.refresh()
		end
	end
end

local function build()
	local shown = {}
	for _, spec in ipairs(PAGES) do
		if spec.available == nil or spec.available() then
			shown[#shown + 1] = spec
		end
	end
	frame = Kit.window("ForeverSimPanel", "ForeverSim", WIDTH, HEIGHT, shown, Panel.select)
	Panel.columns = {}
	for _, spec in ipairs(shown) do
		local page = Kit.scrollPage(frame.body, frame.bodyWidth, frame.bodyHeight)
		spec.build(page.column, page)
		page:Hide()
		pages[spec.key] = page
		Panel.columns[spec.key] = page.column
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
		local column = Kit.column(canvas, 520, 16, -16)
		column:paragraph("The character export, the threat window, your statistics and help.", C.text)
		column:button("Open the control panel", function()
			Panel.show()
		end, 220, "primary")
		local category = settings.RegisterCanvasLayoutCategory(canvas, "ForeverSim")
		settings.RegisterAddOnCategory(category)
	end)
end
