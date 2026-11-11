-- The macro maker's window. Three pages:
--   * Make a macro: start from an example or from nothing, pick what each line does, and read
--     the macro, what is wrong with it and what it does, ready to copy;
--   * Getting started: what a macro is and how to put one on an action bar, for new players;
--   * Words explained: every command, condition and target the maker offers, in plain words.
-- The addon only writes text: the player copies it into the game's own macro window.

local _, ns = ...

local Window = {}
ns.Window = Window

local WIDTH, HEIGHT = 980, 600
local LEFT, RIGHT = 210, 300
local EDITOR = WIDTH - LEFT - RIGHT - 70

local frame
local pages, tabs = {}, {}
Window.current = nil

-- --- The macro being made ------------------------------------------------------------------------

local function clause(argument, unit, conditions)
	return { argument = argument or "", unit = unit or "", conditions = conditions or {} }
end

local function condition(name, values, negate)
	return { name = name, values = values or {}, negate = negate or false }
end

local function line(command, clauses, reset)
	return { command = command, clauses = clauses or { clause() }, reset = reset or {} }
end

-- Examples to start from: what each does, and how to use it once it is on a button.
Window.PRESETS = {
	{
		label = "Mouseover heal",
		what = "Heals whoever your mouse is over, without changing your target. With nobody under the mouse, it heals your target.",
		use = "Point at a player's portrait or character and press the button.",
		macro = { showTooltip = true, lines = { line("cast", {
			clause("Flash Heal", "mouseover", { condition("help"), condition("dead", nil, true) }),
			clause("Flash Heal"),
		}) } },
	},
	{
		label = "Focus interrupt",
		what = "Stops your own cast and interrupts your focus if you have one, else your target.",
		use = "Make an enemy your focus (right-click its portrait, Set Focus), then press it when it casts.",
		macro = { showTooltip = true, lines = {
			line("stopcasting"),
			line("cast", {
				clause("Counterspell", "focus", { condition("harm"), condition("dead", nil, true) }),
				clause("Counterspell"),
			}),
		} },
	},
	{
		label = "Shift for another spell",
		what = "One button, two spells: the second one while you hold Shift.",
		use = "Press it for the first spell; hold Shift and press it for the second.",
		macro = { showTooltip = true, lines = { line("cast", {
			clause("Frost Nova", "", { condition("mod", { "shift" }) }),
			clause("Frostbolt"),
		}) } },
	},
	{
		label = "Attack and cast",
		what = "Starts your weapon attack along with a spell, so you never stand idle.",
		use = "Target an enemy and press it.",
		macro = { showTooltip = true, lines = { line("startattack"), line("cast", { clause("Heroic Strike") }) } },
	},
	{
		label = "Spell at cursor",
		what = "Drops a ground spell where your mouse cursor is, without the targeting circle.",
		use = "Point at the ground and press it.",
		macro = { showTooltip = true, lines = { line("cast", { clause("Blizzard", "cursor") }) } },
	},
	{
		label = "Spell sequence",
		what = "Casts spells one after another, one per press, and starts over on a new target or after combat.",
		use = "Press it again and again; it moves on only when a spell is cast.",
		macro = { showTooltip = true, lines = { line("castsequence", { clause("Rend, Heroic Strike, Heroic Strike") }, { "target", "combat" }) } },
	},
	{
		label = "Empty",
		what = "Start from nothing.",
		use = "",
		macro = { showTooltip = true, lines = { line("cast") } },
	},
}

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local function db()
	ForeverSimMacrosDB = ForeverSimMacrosDB or {}
	return ForeverSimMacrosDB
end

function Window.macro()
	local store = db()
	if type(store.draft) ~= "table" then
		store.draft = copy(Window.PRESETS[1].macro)
	end
	return store.draft
end

function Window.usePreset(index)
	local preset = Window.PRESETS[index]
	if preset == nil then
		return
	end
	db().draft = copy(preset.macro)
	Window.chosenPreset = index
	Window.render()
end

-- --- Lookups -------------------------------------------------------------------------------------

local function commands()
	local found = {}
	for _, entry in ipairs(ns.Reference.commands) do
		found[entry.name] = entry
	end
	return found
end

local function conditions()
	local found = {}
	for _, entry in ipairs(ns.Reference.conditions) do
		found[entry.name] = entry
	end
	return found
end

local function unitEntries()
	local entries = { { value = "", label = "Your target", about = "the default: whatever you have targeted" } }
	local extra = {
		{ token = "targettarget", summary = "the target of your target" },
		{ token = "focustarget", summary = "the target of your focus" },
	}
	for _, unit in ipairs(ns.Reference.units) do
		if unit.range then
			for number = unit.range[1], math.min(unit.range[2], unit.range[1] + 4) do
				entries[#entries + 1] = { value = unit.token .. number, label = "@" .. unit.token .. number, about = unit.summary .. " " .. number }
			end
		elseif unit.token ~= "target" then
			entries[#entries + 1] = { value = unit.token, label = "@" .. unit.token, about = unit.summary }
		end
	end
	for _, unit in ipairs(extra) do
		entries[#entries + 1] = { value = unit.token, label = "@" .. unit.token, about = unit.summary }
	end
	return entries
end

local function unitLabel(value)
	for _, entry in ipairs(unitEntries()) do
		if entry.value == value then
			return entry.label .. "  (" .. entry.about .. ")"
		end
	end
	return "@" .. value
end

local function commandEntries()
	local entries = {}
	for _, entry in ipairs(ns.Reference.commands) do
		entries[#entries + 1] = { value = entry.name, label = "/" .. entry.name .. "   " .. entry.group, about = entry.summary }
	end
	return entries
end

local function conditionEntries()
	local entries = {}
	for _, entry in ipairs(ns.Reference.conditions) do
		entries[#entries + 1] = { value = entry.name, label = entry.summary, about = "[" .. entry.name .. "]" .. (entry.unconfirmed and "  may not work in WoW Forever" or "") }
	end
	return entries
end

local function spellEntries()
	local entries = {}
	for _, name in ipairs(ns.Spells.known()) do
		entries[#entries + 1] = { value = name, label = name, about = "" }
	end
	if #entries == 0 then
		entries[1] = { value = nil, label = "No spells read", about = "type the spell's name instead" }
	end
	return entries
end

-- --- Widgets, reused on every redraw -------------------------------------------------------------

local pools, used = {}, {}

local function acquire(kind, parent, make)
	pools[kind] = pools[kind] or {}
	used[kind] = (used[kind] or 0) + 1
	local widget = pools[kind][used[kind]]
	if widget == nil then
		widget = make(parent)
		pools[kind][used[kind]] = widget
	end
	widget:ClearAllPoints()
	widget:Show()
	return widget
end

local function releaseAll()
	for kind, list in pairs(pools) do
		for _, widget in ipairs(list) do
			widget:Hide()
		end
		used[kind] = 0
	end
end

local function label(parent, text, x, y, width, font)
	local made = acquire(font or "label", parent, function(owner)
		local words = owner:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
		words:SetJustifyH("LEFT")
		words:SetJustifyV("TOP")
		return words
	end)
	made:SetPoint("TOPLEFT", x, y)
	made:SetWidth(width or EDITOR)
	made:SetText(text)
	return made
end

local function button(parent, text, x, y, width, onClick)
	local made = acquire("button", parent, function(owner)
		return CreateFrame("Button", nil, owner, "UIPanelButtonTemplate")
	end)
	made:SetPoint("TOPLEFT", x, y)
	made:SetSize(width, 22)
	made:SetText(text)
	made:SetScript("OnClick", onClick)
	return made
end

local function edit(parent, text, x, y, width, onChange)
	local made = acquire("edit", parent, function(owner)
		local box = CreateFrame("EditBox", nil, owner, "InputBoxTemplate")
		box:SetAutoFocus(false)
		box:SetHeight(22)
		return box
	end)
	made:SetPoint("TOPLEFT", x + 6, y)
	made:SetWidth(width)
	made:SetScript("OnTextChanged", nil)
	made:SetText(text or "")
	made:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			onChange(self:GetText())
		end
	end)
	return made
end

local function check(parent, checked, x, y, onClick)
	local made = acquire("check", parent, function(owner)
		return CreateFrame("CheckButton", nil, owner, "UICheckButtonTemplate")
	end)
	made:SetPoint("TOPLEFT", x, y + 2)
	made:SetSize(22, 22)
	made:SetChecked(checked)
	made:SetScript("OnClick", function(self)
		onClick(self:GetChecked() and true or false)
	end)
	return made
end

-- --- The result ----------------------------------------------------------------------------------

local function splitList(text)
	local values = {}
	for part in tostring(text or ""):gmatch("[^/]+") do
		local value = part:gsub("^%s+", ""):gsub("%s+$", "")
		if value ~= "" then
			values[#values + 1] = value
		end
	end
	return values
end

local function showResult()
	if frame == nil then
		return
	end
	local built = ns.Macro.build(copy(Window.macro()))
	Window.built = built
	local result = pages.make.result
	result.text:SetText(built.text)
	local over = built.length > built.maxLength
	result.count:SetText(string.format("%d / %d characters", built.length, built.maxLength))
	result.count:SetTextColor(over and 1 or 0.7, over and 0.25 or 0.7, over and 0.25 or 0.7)
	local errors, warnings = {}, {}
	for _, item in ipairs(built.problems) do
		if item.severity == "error" then
			errors[#errors + 1] = "|cffff5050" .. item.message .. "|r"
		else
			warnings[#warnings + 1] = "|cffffd040" .. item.message .. "|r"
		end
	end
	local said = {}
	for _, item in ipairs(errors) do
		said[#said + 1] = item
	end
	for _, item in ipairs(warnings) do
		said[#said + 1] = item
	end
	result.problems:SetText(#said > 0 and table.concat(said, "\n") or "|cff60d070Ready to copy.|r")
	local steps = {}
	for index, words in ipairs(built.explanation) do
		steps[#steps + 1] = index .. ". " .. words
	end
	result.explain:SetText(table.concat(steps, "\n"))
end

-- --- The editor ----------------------------------------------------------------------------------

local function renderEditor()
	local page = pages.make
	local content = page.content
	releaseAll()
	local macro = Window.macro()
	local known, knownConditions = commands(), conditions()
	local y = 0
	local tooltip = check(content, macro.showTooltip, 0, y, function(on)
		macro.showTooltip = on
		showResult()
	end)
	Window.controls.tooltip = tooltip
	label(content, "Show the spell's icon and tooltip on the button (#showtooltip)", 26, y - 4)
	y = y - 30
	Window.controls.lines = {}
	for li, entry in ipairs(macro.lines) do
		local command = known[entry.command]
		local controls = { parts = {} }
		Window.controls.lines[li] = controls
		label(content, "Line " .. li, 0, y - 4, 50, "GameFontNormal")
		controls.command = button(content, "/" .. entry.command, 56, y, 220, function(self)
			ns.Picker.open(self, commandEntries(), function(value)
				entry.command = value
				Window.render()
			end)
		end)
		button(content, "Remove line", 284, y, 100, function()
			if #macro.lines > 1 then
				table.remove(macro.lines, li)
				Window.render()
			end
		end)
		y = y - 26
		if command then
			label(content, command.summary, 0, y, EDITOR)
			y = y - 30
		end
		for ci, part in ipairs(entry.clauses) do
			local partControls = { conditions = {} }
			controls.parts[ci] = partControls
			label(content, ci == 1 and "If" or "Otherwise, if", 10, y, 120, "GameFontNormal")
			y = y - 18
			if command == nil or command.conditions then
				label(content, "On", 10, y - 4, 30)
				partControls.unit = button(content, part.unit == "" and "Your target (the default)" or unitLabel(part.unit), 40, y, 340, function(self)
					ns.Picker.open(self, unitEntries(), function(value)
						part.unit = value or ""
						Window.render()
					end)
				end)
				y = y - 26
				for ki, one in ipairs(part.conditions) do
					local about = knownConditions[one.name]
					check(content, one.negate, 10, y, function(on)
						one.negate = on
						showResult()
					end)
					label(content, "not", 34, y - 4, 24)
					partControls.conditions[ki] = button(content, about and about.summary or one.name, 60, y, 230, function(self)
						ns.Picker.open(self, conditionEntries(), function(value)
							part.conditions[ki] = condition(value)
							Window.render()
						end)
					end)
					if about and about.argument ~= "none" then
						edit(content, table.concat(one.values or {}, "/"), 296, y, 80, function(text)
							one.values = splitList(text)
							showResult()
						end)
					end
					button(content, "x", 384, y, 24, function()
						table.remove(part.conditions, ki)
						Window.render()
					end)
					y = y - 26
				end
				partControls.addCondition = button(content, "+ Condition", 10, y, 110, function()
					part.conditions[#part.conditions + 1] = condition(ns.Reference.conditions[1].name)
					Window.render()
				end)
				y = y - 28
			end
			if command and command.argument ~= "none" then
				local words = (command.argument == "sequence" or command.argument == "list") and "Spells, separated by commas" or command.argument == "text" and "Text" or "Spell or item"
				label(content, words, 10, y)
				partControls.argument = edit(content, part.argument, 10, y - 14, 250, function(text)
					part.argument = text
					showResult()
				end)
				if command.argument ~= "text" then
					button(content, "Your spells", 272, y - 14, 108, function(self)
						ns.Picker.open(self, spellEntries(), function(value)
							if value ~= nil then
								if command.argument == "sequence" or command.argument == "list" then
									part.argument = part.argument == "" and value or (part.argument .. ", " .. value)
								else
									part.argument = value
								end
								Window.render()
							end
						end)
					end)
				end
				y = y - 42
			end
			if ci > 1 then
				button(content, "Remove this part", 10, y, 140, function()
					table.remove(entry.clauses, ci)
					Window.render()
				end)
				y = y - 26
			end
		end
		if entry.command == "castsequence" then
			label(content, "Start over after (seconds, or " .. table.concat(ns.Reference.castsequence_resets, ", ") .. "; several with /)", 10, y)
			edit(content, table.concat(entry.reset or {}, "/"), 10, y - 14, 250, function(text)
				entry.reset = splitList(text)
				showResult()
			end)
			y = y - 42
		end
		if command and command.conditions then
			controls.otherwise = button(content, "+ Otherwise...", 0, y, 120, function()
				entry.clauses[#entry.clauses + 1] = clause()
				Window.render()
			end)
			y = y - 30
		end
		y = y - 10
	end
	Window.controls.addLine = button(content, "+ Add a line", 0, y, 140, function()
		macro.lines[#macro.lines + 1] = line("cast")
		Window.render()
	end)
	y = y - 30
	content:SetHeight(-y)
end

-- --- Pages ---------------------------------------------------------------------------------------

local function makePage(page)
	-- Examples, on the left.
	local intro = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	intro:SetPoint("TOPLEFT", 0, 0)
	intro:SetText("Start from")
	page.presets = {}
	for index, preset in ipairs(Window.PRESETS) do
		local pick = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
		pick:SetSize(LEFT - 10, 22)
		pick:SetPoint("TOPLEFT", 0, -18 - (index - 1) * 26)
		pick:SetText(preset.label)
		pick:SetScript("OnClick", function()
			Window.usePreset(index)
		end)
		page.presets[index] = pick
	end
	page.about = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	page.about:SetPoint("TOPLEFT", 0, -26 - #Window.PRESETS * 26)
	page.about:SetWidth(LEFT - 10)
	page.about:SetJustifyH("LEFT")
	page.about:SetJustifyV("TOP")

	-- The editor, in the middle, scrolling.
	page.scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
	page.scroll:SetPoint("TOPLEFT", LEFT + 10, 0)
	page.scroll:SetPoint("BOTTOMLEFT", LEFT + 10, 0)
	page.scroll:SetWidth(EDITOR + 10)
	page.content = CreateFrame("Frame", nil, page.scroll)
	page.content:SetSize(EDITOR, 400)
	page.scroll:SetScrollChild(page.content)

	-- The macro, on the right.
	local result = CreateFrame("Frame", nil, page)
	result:SetPoint("TOPRIGHT", 0, 0)
	result:SetPoint("BOTTOMRIGHT", 0, 0)
	result:SetWidth(RIGHT)
	page.result = result
	result.title = result:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	result.title:SetPoint("TOPLEFT", 0, 0)
	result.title:SetText("Your macro")
	result.box = CreateFrame("Frame", nil, result, "BackdropTemplate")
	result.box:SetPoint("TOPLEFT", 0, -18)
	result.box:SetSize(RIGHT, 110)
	if result.box.SetBackdrop then
		result.box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		result.box:SetBackdropColor(0, 0, 0, 0.5)
		result.box:SetBackdropBorderColor(1, 1, 1, 0.25)
	end
	result.text = CreateFrame("EditBox", nil, result.box)
	result.text:SetPoint("TOPLEFT", 6, -6)
	result.text:SetPoint("BOTTOMRIGHT", -6, 6)
	result.text:SetMultiLine(true)
	result.text:SetAutoFocus(false)
	result.text:SetFontObject(ChatFontNormal)
	-- Read-only: a typed change puts the macro back, so what is copied is what was checked.
	result.text:SetScript("OnTextChanged", function(self, userInput)
		if userInput and Window.built then
			self:SetText(Window.built.text)
			self:HighlightText()
		end
	end)
	result.text:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	result.count = result:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	result.count:SetPoint("TOPLEFT", result.box, "BOTTOMLEFT", 0, -6)
	result.select = CreateFrame("Button", nil, result, "UIPanelButtonTemplate")
	result.select:SetSize(130, 22)
	result.select:SetPoint("TOPRIGHT", result.box, "BOTTOMRIGHT", 0, -2)
	result.select:SetText("Select to copy")
	result.select:SetScript("OnClick", function()
		result.text:SetFocus()
		result.text:HighlightText()
		result.hint:SetText("Selected: press Ctrl+C to copy (Cmd+C on a Mac).")
	end)
	result.hint = result:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	result.hint:SetPoint("TOPLEFT", result.box, "BOTTOMLEFT", 0, -28)
	result.hint:SetWidth(RIGHT)
	result.hint:SetJustifyH("LEFT")
	result.hint:SetText("Then put it in the game's macro window: see Getting started.")
	result.problems = result:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	result.problems:SetPoint("TOPLEFT", result.hint, "BOTTOMLEFT", 0, -10)
	result.problems:SetWidth(RIGHT)
	result.problems:SetJustifyH("LEFT")
	result.whatTitle = result:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	result.whatTitle:SetPoint("TOPLEFT", result.problems, "BOTTOMLEFT", 0, -12)
	result.whatTitle:SetText("What it does")
	result.explain = result:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	result.explain:SetPoint("TOPLEFT", result.whatTitle, "BOTTOMLEFT", 0, -4)
	result.explain:SetWidth(RIGHT)
	result.explain:SetJustifyH("LEFT")
	result.explain:SetJustifyV("TOP")
end

-- For new players: what a macro is, how to put one in the game, how to use it. It says where to
-- click in the game's own menus; nothing has to be typed but the macro itself.
Window.GUIDE = table.concat({
	"|cffffd100What is a macro?|r",
	"A macro is a button you make yourself. It holds a few lines of text that tell the game what to do when you press it: cast a spell, cast it on someone in particular, or choose between two spells.",
	"Each line starts with a / and a word, like /cast. That is how the game reads macros; this addon writes those lines for you.",
	"",
	"|cffffd100Make one here|r",
	"1. On Make a macro, pick an example on the left, or Empty.",
	"2. Change what you like: click a line's command to pick another, type the spell's name or pick it from Your spells.",
	"3. On the right you see the finished macro, and in plain words what it does. Red lines are mistakes the game would not accept; fix them first.",
	"4. Click Select to copy, then press Ctrl+C (Cmd+C on a Mac).",
	"",
	"|cffffd100Put it in the game|r",
	"1. Press Escape to open the Game Menu and choose Macros.",
	"2. Click New. Pick the question mark icon: the game then shows the spell's own icon.",
	"3. Give it a name, click Okay.",
	"4. Click in the big text box at the bottom and press Ctrl+V (Cmd+V) to paste.",
	"5. Close the window: the macro is saved.",
	"6. Drag the macro's icon from the window onto one of your action bars. Press it like any spell.",
	"",
	"|cffffd100Words you will meet|r",
	"If / Otherwise, if: a line can try several things in order. The first one whose conditions are true is done; the rest are skipped.",
	"On (@target, @focus, @mouseover...): who the spell goes to. Without it, it goes to your target.",
	"Conditions: checks like 'the unit is hostile' or 'you hold Shift'. Tick 'not' to turn one around.",
	"Mouseover: the unit your mouse pointer is on, a player's portrait or a character in the world.",
	"Focus: a second target you keep. Right-click a portrait and choose Set Focus.",
	"",
	"|cffffd100Good to know|r",
	"A macro can hold 255 characters. The counter turns red when it is too long.",
	"Macros cannot do anything you could not do by pressing buttons yourself, and one press does one spell.",
	"The rules come from World of Warcraft's macro language; WoW Forever's client may differ in places.",
}, "\n")

local function textPage(page, words)
	page.scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
	page.scroll:SetPoint("TOPLEFT", 0, 0)
	page.scroll:SetPoint("BOTTOMRIGHT", -26, 0)
	page.content = CreateFrame("Frame", nil, page.scroll)
	page.content:SetSize(WIDTH - 90, 1200)
	page.scroll:SetScrollChild(page.content)
	page.text = page.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	page.text:SetPoint("TOPLEFT", 0, 0)
	page.text:SetWidth(WIDTH - 100)
	page.text:SetJustifyH("LEFT")
	page.text:SetJustifyV("TOP")
	page.text:SetSpacing(3)
	page.text:SetText(words)
end

-- Every command, condition and target, from the rules themselves.
function Window.glossary()
	local said = { "|cffffd100Commands|r (what a line does)" }
	for _, entry in ipairs(ns.Reference.commands) do
		said[#said + 1] = "/" .. entry.name .. ": " .. entry.summary
	end
	said[#said + 1] = ""
	said[#said + 1] = "|cffffd100Conditions|r (checks in [ ]; 'no' in front turns one around)"
	for _, entry in ipairs(ns.Reference.conditions) do
		said[#said + 1] = "[" .. entry.name .. "]: " .. entry.summary .. (entry.unconfirmed and (" (" .. entry.unconfirmed .. ")") or "")
	end
	said[#said + 1] = ""
	said[#said + 1] = "|cffffd100Targets|r (who it goes to, written @name)"
	for _, entry in ipairs(ns.Reference.units) do
		local range = entry.range and (" (" .. entry.token .. entry.range[1] .. " to " .. entry.token .. entry.range[2] .. ")") or ""
		said[#said + 1] = "@" .. entry.token .. range .. ": " .. entry.summary
	end
	said[#said + 1] = "Add 'target' to any of them for its target: @focustarget is the target of your focus."
	said[#said + 1] = ""
	said[#said + 1] = "Source: " .. ns.Reference.source
	return table.concat(said, "\n")
end

local PAGES = {
	{ key = "make", title = "Make a macro", build = makePage },
	{ key = "guide", title = "Getting started", build = function(page)
		textPage(page, Window.GUIDE)
	end },
	{ key = "words", title = "Words explained", build = function(page)
		textPage(page, Window.glossary())
	end },
}

-- --- The window ----------------------------------------------------------------------------------

function Window.render()
	if frame == nil then
		return
	end
	Window.controls = {}
	renderEditor()
	local preset = Window.PRESETS[Window.chosenPreset or 0]
	pages.make.about:SetText(preset and (preset.what .. (preset.use ~= "" and ("\n\n|cffffd100Using it:|r " .. preset.use) or "")) or "Pick an example to start from, or change the one below.")
	showResult()
	db().draft = Window.macro()
end

function Window.select(key)
	for name, page in pairs(pages) do
		if name == key then
			page:Show()
			tabs[name]:LockHighlight()
		else
			page:Hide()
			tabs[name]:UnlockHighlight()
		end
	end
	Window.current = key
	ns.Picker.close()
end

local function build()
	frame = CreateFrame("Frame", "ForeverSimMacrosWindow", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetScript("OnHide", function()
		ns.Picker.close()
	end)
	tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it
	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	frame.title:SetPoint("TOP", 0, -6)
	frame.title:SetText("ForeverSim Macros")
	for index, spec in ipairs(PAGES) do
		local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		tab:SetSize(150, 24)
		tab:SetPoint("TOPLEFT", 14 + (index - 1) * 156, -30)
		tab:SetText(spec.title)
		tab:SetScript("OnClick", function()
			Window.select(spec.key)
		end)
		tabs[spec.key] = tab
		local page = CreateFrame("Frame", nil, frame)
		page:SetPoint("TOPLEFT", 18, -64)
		page:SetPoint("BOTTOMRIGHT", -18, 14)
		spec.build(page)
		page:Hide()
		pages[spec.key] = page
	end
	Window.pages = pages
	Window.render()
	-- A first visit starts with the guide.
	Window.select(db().seenGuide and "make" or "guide")
	db().seenGuide = true
end

function Window.open(key)
	if frame == nil then
		build()
	end
	frame:Show()
	if key then
		Window.select(key)
	end
end

function Window.toggle()
	if frame ~= nil and frame:IsShown() then
		frame:Hide()
	else
		Window.open()
	end
end
