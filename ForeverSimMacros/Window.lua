-- The macro maker's window, laid out with the shared Kit. Pages down the left:
--   * Make a macro: five plain questions (what to cast, on whom, only when, a second spell with
--     a key held, extras), each a numbered card, or an example to start from;
--   * Advanced: every line of the macro by hand, for what the questions do not cover;
--   * Getting started: what a macro is and how to put one on an action bar, for new players;
--   * Words explained: every command, condition and target in plain words.
-- On the first two, the macro is on the right as it is built: its text to copy, whether the game
-- will take it, what it does, and the three steps to put it in the game. The addon only writes
-- text: the player copies it into the game's own macro window.

local _, ns = ...

local Kit = ns.Kit
local C = Kit.COLOURS

local Window = {}
ns.Window = Window

local WIDTH, HEIGHT = 1000, 640
local RESULT = 320

local frame, result
local pages = {}
Window.current = nil
Window.columns = {}
Window.controls = {}

-- --- Saved state ---------------------------------------------------------------------------------

local function db()
	ForeverSimMacrosDB = ForeverSimMacrosDB or {}
	return ForeverSimMacrosDB
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local made = {}
	for key, item in pairs(value) do
		made[key] = copy(item)
	end
	return made
end

-- --- The questions -------------------------------------------------------------------------------

Window.SIMPLE = {
	spell = "",
	who = "target",
	only = "any",
	skipDead = true,
	alt = false,
	altKey = "shift",
	altSpell = "",
	attack = false,
	interrupt = false,
	icon = true,
}

function Window.simple()
	local store = db()
	if type(store.simple) ~= "table" then
		store.simple = copy(Window.SIMPLE)
	end
	for key, value in pairs(Window.SIMPLE) do
		if store.simple[key] == nil then
			store.simple[key] = value
		end
	end
	return store.simple
end

-- Examples for the questions: what each does, and the answers it fills in.
Window.EXAMPLES = {
	{ label = "Mouseover heal", what = "Heals whoever your mouse is over, else your target.",
		answers = { spell = "Flash Heal", who = "mouseover", only = "friend" } },
	{ label = "Focus interrupt", what = "Stops your cast and interrupts your focus, else your target.",
		answers = { spell = "Counterspell", who = "focus", only = "enemy", interrupt = true } },
	{ label = "Shift for a second spell", what = "One button, two spells: the second with Shift held.",
		answers = { spell = "Frostbolt", alt = true, altKey = "shift", altSpell = "Frost Nova" } },
	{ label = "Attack and cast", what = "Starts your weapon attack along with a spell.",
		answers = { spell = "Heroic Strike", only = "enemy", attack = true } },
	{ label = "Spell at your cursor", what = "Drops a ground spell where your cursor is.",
		answers = { spell = "Blizzard", who = "cursor" } },
	{ label = "Heal yourself", what = "Always heals you, whoever you have targeted.",
		answers = { spell = "Flash Heal", who = "player" } },
}

function Window.useExample(index)
	local example = Window.EXAMPLES[index]
	if example == nil then
		return
	end
	local answers = copy(Window.SIMPLE)
	for key, value in pairs(example.answers) do
		answers[key] = value
	end
	db().simple = answers
	Window.refresh()
end

local WHO = {
	{ value = "target", label = "Your target", about = "Whoever you have targeted." },
	{ value = "mouseover", label = "Whoever your mouse is over, else your target", about = "Point at a player's portrait or at a character to cast on them without changing your target. With nobody under the mouse, it goes to your target." },
	{ value = "focus", label = "Your focus, else your target", about = "Your focus is a second target you keep: right-click a portrait and choose Set Focus. Without one, it goes to your target." },
	{ value = "player", label = "Yourself", about = "Always you, whoever you have targeted." },
	{ value = "cursor", label = "The ground under your cursor", about = "For spells cast on the ground: they land where your mouse points, with no targeting circle." },
}

local ONLY = {
	{ value = "any", label = "Always", about = "Whoever it is." },
	{ value = "enemy", label = "Only on an enemy", about = "Nothing happens on a friend; with Your focus or Your mouse, it falls back to your target instead." },
	{ value = "friend", label = "Only on a friend", about = "Nothing happens on an enemy; with Your focus or Your mouse, it falls back to your target instead." },
}

local function condition(name, values, negate)
	return { name = name, values = values or {}, negate = negate or false }
end

local function clause(argument, unit, conditions)
	return { argument = argument or "", unit = unit or "", conditions = conditions or {} }
end

local function line(command, clauses, reset)
	return { command = command, clauses = clauses or { clause() }, reset = reset or {} }
end

-- The macro the answers make, in the form Macro.build reads.
function Window.fromAnswers(s)
	local lines = {}
	if s.interrupt then
		lines[#lines + 1] = line("stopcasting")
	end
	if s.attack then
		lines[#lines + 1] = line("startattack")
	end
	local function checks(extra)
		local list = {}
		if extra then
			list[#list + 1] = extra
		end
		if s.only == "enemy" then
			list[#list + 1] = condition("harm")
		elseif s.only == "friend" then
			list[#list + 1] = condition("help")
		end
		if s.skipDead and s.who ~= "player" and s.who ~= "cursor" then
			list[#list + 1] = condition("dead", nil, true)
		end
		return list
	end
	local unit = s.who == "target" and "" or s.who
	local clauses = {}
	if s.alt and s.altSpell ~= "" then
		clauses[#clauses + 1] = clause(s.altSpell, unit, checks(condition("mod", { s.altKey })))
	end
	if s.who == "mouseover" or s.who == "focus" then
		local first = checks()
		if #first == 0 then
			first[1] = condition("exists")
		end
		clauses[#clauses + 1] = clause(s.spell, unit, first)
		clauses[#clauses + 1] = clause(s.spell, "", checks())
	else
		clauses[#clauses + 1] = clause(s.spell, unit, checks())
	end
	lines[#lines + 1] = line("cast", clauses)
	return { showTooltip = s.icon, lines = lines }
end

-- --- The advanced editor's macro -----------------------------------------------------------------

-- Examples for the editor, including what the questions cannot make.
Window.PRESETS = {
	{ label = "Spell sequence", macro = { showTooltip = true, lines = { line("castsequence", { clause("Rend, Heroic Strike, Heroic Strike") }, { "target", "combat" }) } } },
	{ label = "Assist the tank", macro = { showTooltip = false, lines = { line("assist", { clause("", "focus") }), line("startattack") } } },
	{ label = "Pet attack", macro = { showTooltip = false, lines = { line("petattack"), line("cast", { clause("Arcane Shot") }) } } },
	{ label = "Empty", macro = { showTooltip = true, lines = { line("cast") } } },
}

function Window.macro()
	local store = db()
	if type(store.draft) ~= "table" then
		store.draft = copy(Window.PRESETS[#Window.PRESETS].macro)
	end
	return store.draft
end

function Window.usePreset(index)
	local preset = Window.PRESETS[index]
	if preset ~= nil then
		db().draft = copy(preset.macro)
		Window.refresh()
	end
end

-- Take what the questions made into the editor, to change it by hand.
function Window.editAnswers()
	db().draft = Window.fromAnswers(Window.simple())
	Window.select("advanced")
end

-- --- Lists to pick from --------------------------------------------------------------------------

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
	for _, unit in ipairs(ns.Reference.units) do
		if unit.range then
			for number = unit.range[1], math.min(unit.range[2], unit.range[1] + 4) do
				entries[#entries + 1] = { value = unit.token .. number, label = "@" .. unit.token .. number, about = unit.summary .. " " .. number }
			end
		elseif unit.token ~= "target" then
			entries[#entries + 1] = { value = unit.token, label = "@" .. unit.token, about = unit.summary }
		end
	end
	entries[#entries + 1] = { value = "targettarget", label = "@targettarget", about = "the target of your target" }
	entries[#entries + 1] = { value = "focustarget", label = "@focustarget", about = "the target of your focus" }
	return entries
end

local function unitLabel(value)
	for _, entry in ipairs(unitEntries()) do
		if entry.value == value then
			return entry.label
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

-- --- The macro, on the right ---------------------------------------------------------------------

local NEXT_STEPS = table.concat({
	"1. Click Select to copy, then press Ctrl+C (Cmd+C on a Mac).",
	"2. In the game: Escape, Macros, New. Pick the question mark icon, name it, click Okay.",
	"3. Click in the big box, press Ctrl+V, close the window.",
	"4. Drag the macro's icon onto an action bar and press it like a spell.",
}, "\n")

local function buildResult(parent)
	result = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	result:SetPoint("TOPRIGHT", 0, 0)
	result:SetPoint("BOTTOMRIGHT", 0, 0)
	result:SetWidth(RESULT)
	Kit.backdrop(result, C.panel)
	result.title = Kit.text(result, "GameFontNormalLarge", C.accent)
	result.title:SetText("Your macro")
	result.box = CreateFrame("Frame", nil, result, "BackdropTemplate")
	result.box:SetSize(RESULT - 24, 118)
	Kit.backdrop(result.box, { 0, 0, 0, 0.55 })
	result.text = CreateFrame("EditBox", nil, result.box)
	result.text:SetPoint("TOPLEFT", 8, -8)
	result.text:SetPoint("BOTTOMRIGHT", -8, 8)
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
	result.count = Kit.text(result, "GameFontHighlightSmall", C.muted)
	result.select = Kit.button(result, "Select to copy", 140, function()
		result.text:SetFocus()
		result.text:HighlightText()
		result.status:SetText("Selected: press Ctrl+C (Cmd+C on a Mac).")
	end, "primary")
	result.status = Kit.text(result, "GameFontHighlight", C.text)
	result.whatTitle = Kit.text(result, "GameFontNormal", C.accent)
	result.whatTitle:SetText("What it does")
	result.explain = Kit.text(result, "GameFontHighlight", C.muted)
	result.nextTitle = Kit.text(result, "GameFontNormal", C.accent)
	result.nextTitle:SetText("Then put it in the game")
	result.next = Kit.text(result, "GameFontHighlight", C.muted)
	result.next:SetText(NEXT_STEPS)
end

-- Lay the result out again: its texts change length as the macro does.
local function layoutResult()
	local column = Kit.column(result, RESULT - 24, 12, -12)
	column:place(result.title, 20)
	column:place(result.box, 118)
	column:row({ { result.count, 140 }, { result.select, 140 } }, 26)
	result.status:SetWidth(column.width)
	column:place(result.status, math.max(result.status:GetStringHeight() or 14, 14))
	column:place(result.whatTitle, 16)
	result.explain:SetWidth(column.width)
	column:place(result.explain, math.max(result.explain:GetStringHeight() or 14, 14))
	column:place(result.nextTitle, 16)
	result.next:SetWidth(column.width)
	column:place(result.next, math.max(result.next:GetStringHeight() or 14, 14))
	Window.columns.result = column
end

local function showResult()
	if result == nil then
		return
	end
	local macro = Window.current == "advanced" and Window.macro() or Window.fromAnswers(Window.simple())
	local built = ns.Macro.build(copy(macro))
	Window.built = built
	result.text:SetText(built.text)
	local over = built.length > built.maxLength
	result.count:SetText(string.format("%d / %d characters", built.length, built.maxLength))
	result.count:SetTextColor(unpack(over and C.bad or C.muted))
	local said = {}
	for _, item in ipairs(built.problems) do
		if item.severity == "error" then
			said[#said + 1] = "|cffff5a52" .. item.message .. "|r"
		end
	end
	for _, item in ipairs(built.problems) do
		if item.severity == "warning" then
			said[#said + 1] = "|cffffcc40" .. item.message .. "|r"
		end
	end
	result.status:SetText(#said > 0 and table.concat(said, "\n") or "|cff66d980The game will take it. Ready to copy.|r")
	local steps = {}
	for index, words in ipairs(built.explanation) do
		steps[#steps + 1] = index .. ". " .. words
	end
	result.explain:SetText(table.concat(steps, "\n"))
	layoutResult()
end
Window.showResult = showResult

-- --- Make a macro: the questions -----------------------------------------------------------------

local function spellRow(column, get, set, label)
	column:subheading(label)
	column.y = column.y + Kit.SPACE - Kit.SMALL_SPACE
	local box = CreateFrame("EditBox", nil, column.parent, "BackdropTemplate")
	box:SetSize(column.width - 130, 26)
	box:SetAutoFocus(false)
	box:SetFontObject(ChatFontNormal)
	box:SetTextInsets(8, 8, 0, 0)
	Kit.backdrop(box, { 0, 0, 0, 0.45 })
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			set(self:GetText())
			showResult()
		end
	end)
	box.refresh = function()
		if box:GetText() ~= get() then
			box:SetText(get())
		end
	end
	local pick = Kit.button(column.parent, "Your spells", 120, function(self)
		ns.Picker.open(self, spellEntries(), function(value)
			if value ~= nil then
				set(value)
				box:SetText(value)
				showResult()
			end
		end)
	end, "quiet")
	column:row({ { box, column.width - 130 }, { pick, 120 } }, 26)
	box.refresh()
	return box, pick
end

local function simplePage(column)
	local answers = Window.simple
	local function setter(key)
		return function(value)
			answers()[key] = value
			showResult()
		end
	end
	local function getter(key)
		return function()
			return answers()[key]
		end
	end
	local controls = {}
	Window.controls.simple = controls

	column:heading("Make a macro")
	column:paragraph("Answer the questions below. The macro on the right follows as you go, with what it does in plain words. New to macros? Read Getting started first.")
	column:subheading("Start from an example")
	controls.examples = {}
	local row = {}
	for index, example in ipairs(Window.EXAMPLES) do
		local pick = Kit.button(column.parent, example.label, math.floor((column.width - 16) / 3), function()
			Window.useExample(index)
		end, "quiet")
		pick:SetScript("OnEnter", function(self)
			self.hover = true
			self:paint()
			if GameTooltip then
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(example.label)
				GameTooltip:AddLine(example.what, 1, 1, 1, true)
				GameTooltip:Show()
			end
		end)
		pick:SetScript("OnLeave", function(self)
			self.hover = false
			self:paint()
			if GameTooltip then
				GameTooltip:Hide()
			end
		end)
		controls.examples[index] = pick
		row[#row + 1] = { pick, math.floor((column.width - 16) / 3) }
		if #row == 3 or index == #Window.EXAMPLES then
			column:row(row, 26)
			column.y = column.y + Kit.SPACE - Kit.SMALL_SPACE
			row = {}
		end
	end
	column:gap(Kit.SPACE)

	local card = column:card()
	local inner = card.column
	inner:heading("1. What should the button cast?")
	controls.spell = spellRow(inner, getter("spell"), setter("spell"), "The spell (or item)")
	inner:paragraph("Type its name as the game writes it, or pick it from your spellbook.")
	column:after(card)

	card = column:card()
	inner = card.column
	inner:heading("2. On whom?")
	controls.who = inner:radio(WHO, getter("who"), setter("who"))
	column:after(card)

	card = column:card()
	inner = card.column
	inner:heading("3. Only when...")
	controls.only = inner:radio(ONLY, getter("only"), setter("only"))
	controls.skipDead = inner:check("Skip dead targets", "Then it never tries to cast on a corpse.", getter("skipDead"), setter("skipDead"))
	column:after(card)

	card = column:card()
	inner = card.column
	inner:heading("4. A second spell with a key held (optional)")
	controls.alt = inner:check("Cast another spell while I hold a key", nil, getter("alt"), setter("alt"))
	controls.altKey = inner:choice("The key", nil, {
		{ value = "shift", label = "Shift", width = 100 },
		{ value = "ctrl", label = "Ctrl", width = 100 },
		{ value = "alt", label = "Alt", width = 100 },
	}, getter("altKey"), setter("altKey"))
	controls.altSpell = spellRow(inner, getter("altSpell"), setter("altSpell"), "The other spell")
	column:after(card)

	card = column:card()
	inner = card.column
	inner:heading("5. Extras")
	controls.attack = inner:check("Start my weapon attack too", "Useful for melee: you never stand idle between spells.", getter("attack"), setter("attack"))
	controls.interrupt = inner:check("Stop the spell I am casting first", "For interrupts: it cuts your own cast short so this one goes off at once.", getter("interrupt"), setter("interrupt"))
	controls.icon = inner:check("Show the spell's icon on the button", "The button then looks like the spell it will cast, with its cooldown.", getter("icon"), setter("icon"))
	column:after(card)

	column:button("Change it line by line (Advanced)", function()
		Window.editAnswers()
	end, 260, "quiet")
end

-- --- Advanced: the lines by hand -----------------------------------------------------------------

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

local function words(column, text, font, colour, indent)
	local width = column.width - (indent or 0)
	local made = acquire(font .. "/" .. tostring(colour), column.parent, function(owner)
		return Kit.text(owner, font, colour)
	end)
	made:SetText(text)
	made:SetWidth(width)
	column:place(made, math.max(made:GetStringHeight() or 14, 14), indent, width)
	return made
end

local function flat(column, label, width, onClick, kind)
	local made = acquire("button/" .. tostring(kind), column.parent, function(owner)
		return Kit.button(owner, "", width, nil, kind)
	end)
	made:SetSize(width, 26)
	made:SetText(label)
	made:SetScript("OnClick", onClick)
	return made
end

local function field(column, text, width, onChange)
	local made = acquire("edit", column.parent, function(owner)
		local box = CreateFrame("EditBox", nil, owner, "BackdropTemplate")
		box:SetAutoFocus(false)
		box:SetFontObject(ChatFontNormal)
		box:SetTextInsets(8, 8, 0, 0)
		Kit.backdrop(box, { 0, 0, 0, 0.45 })
		box:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
		end)
		return box
	end)
	made:SetSize(width, 26)
	made:SetScript("OnTextChanged", nil)
	made:SetText(text or "")
	made:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			onChange(self:GetText())
		end
	end)
	return made
end

local function tick(column, checked, onClick)
	local made = acquire("check", column.parent, function(owner)
		return CreateFrame("CheckButton", nil, owner, "UICheckButtonTemplate")
	end)
	made:SetSize(24, 24)
	made:SetChecked(checked)
	made:SetScript("OnClick", function(self)
		onClick(self:GetChecked() and true or false)
	end)
	return made
end

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

local function renderAdvanced()
	local page = pages.advanced
	if page == nil then
		return
	end
	releaseAll()
	local column = Kit.column(page.content, page.column.width)
	Window.columns.advanced = column
	local macro = Window.macro()
	local known, knownConditions = commands(), conditions()
	local controls = { lines = {} }
	Window.controls.advanced = controls

	words(column, "Advanced", "GameFontNormalLarge", C.accent)
	words(column, "Every line of the macro by hand. Each line is a command; a command that takes conditions can try several things in order: the first whose conditions are true is done.", "GameFontHighlight", C.muted)
	-- The examples, two to a line, as wide as the page allows.
	local half = math.floor((column.width - 8) / 2)
	local row = {}
	for index, preset in ipairs(Window.PRESETS) do
		row[#row + 1] = { flat(column, preset.label, half, function()
			Window.usePreset(index)
		end, "quiet"), half }
		if #row == 2 or index == #Window.PRESETS then
			column:row(row, 26)
			column.y = column.y + Kit.SPACE - Kit.SMALL_SPACE
			row = {}
		end
	end
	column:gap(Kit.SMALL_SPACE)
	local iconWords = acquire("GameFontHighlight/icon", column.parent, function(owner)
		return Kit.text(owner, "GameFontHighlight", C.text)
	end)
	iconWords:SetText("Show the spell's icon on the button (#showtooltip)")
	column:row({ { tick(column, macro.showTooltip, function(on)
		macro.showTooltip = on
		showResult()
	end), 24 }, { iconWords, column.width - 32 } }, 24)

	for li, entry in ipairs(macro.lines) do
		local command = known[entry.command]
		local lineControls = { parts = {} }
		controls.lines[li] = lineControls
		column:gap(Kit.SMALL_SPACE)
		lineControls.command = flat(column, "/" .. entry.command, 200, function(self)
			ns.Picker.open(self, commandEntries(), function(value)
				entry.command = value
				Window.refresh()
			end)
		end)
		local remove = flat(column, "Remove line", 120, function()
			if #macro.lines > 1 then
				table.remove(macro.lines, li)
				Window.refresh()
			end
		end, "quiet")
		local number = acquire("GameFontNormalLarge/number", column.parent, function(owner)
			return Kit.text(owner, "GameFontNormalLarge", C.accent)
		end)
		number:SetText("Line " .. li)
		column:row({ { number, 70 }, { lineControls.command, 200 }, { remove, 120 } }, 26)
		if command then
			words(column, command.summary, "GameFontHighlight", C.muted)
		end
		for ci, part in ipairs(entry.clauses) do
			local partControls = { conditions = {} }
			lineControls.parts[ci] = partControls
			words(column, ci == 1 and "If" or "Otherwise, if", "GameFontNormal", C.text, 16)
			if command == nil or command.conditions then
				local on = acquire("GameFontHighlight/on", column.parent, function(owner)
					return Kit.text(owner, "GameFontHighlight", C.muted)
				end)
				on:SetText("On")
				partControls.unit = flat(column, part.unit == "" and "Your target (the default)" or unitLabel(part.unit), 260, function(self)
					ns.Picker.open(self, unitEntries(), function(value)
						part.unit = value or ""
						Window.refresh()
					end)
				end, "quiet")
				column.x = column.x + 16
				column:row({ { on, 30 }, { partControls.unit, 260 } }, 26)
				for ki, one in ipairs(part.conditions) do
					local about = knownConditions[one.name]
					local items = { { tick(column, one.negate, function(checked)
						one.negate = checked
						showResult()
					end), 24 } }
					local notWord = acquire("GameFontHighlight/not", column.parent, function(owner)
						return Kit.text(owner, "GameFontHighlight", C.muted)
					end)
					notWord:SetText("not")
					items[#items + 1] = { notWord, 26 }
					-- What is left of the line once the box, "not", the value and the x have theirs.
					local wide = column.width - 16 - 24 - 26 - 80 - 26 - 4 * 8
					partControls.conditions[ki] = flat(column, about and about.summary or one.name, wide, function(self)
						ns.Picker.open(self, conditionEntries(), function(value)
							part.conditions[ki] = condition(value)
							Window.refresh()
						end)
					end, "quiet")
					items[#items + 1] = { partControls.conditions[ki], wide }
					if about and about.argument ~= "none" then
						items[#items + 1] = { field(column, table.concat(one.values or {}, "/"), 80, function(text)
							one.values = splitList(text)
							showResult()
						end), 80 }
					end
					items[#items + 1] = { flat(column, "x", 26, function()
						table.remove(part.conditions, ki)
						Window.refresh()
					end, "quiet"), 26 }
					column:row(items, 26)
				end
				partControls.addCondition = flat(column, "+ Condition", 120, function()
					part.conditions[#part.conditions + 1] = condition(ns.Reference.conditions[1].name)
					Window.refresh()
				end, "quiet")
				column:row({ { partControls.addCondition, 120 } }, 26)
				column.x = column.x - 16
			end
			if command and command.argument ~= "none" then
				local label = (command.argument == "sequence" or command.argument == "list") and "Spells, separated by commas" or command.argument == "text" and "Text" or "Spell or item"
				words(column, label, "GameFontHighlight", C.muted, 16)
				partControls.argument = field(column, part.argument, 250, function(text)
					part.argument = text
					showResult()
				end)
				local items = { { partControls.argument, 250 } }
				if command.argument ~= "text" then
					items[#items + 1] = { flat(column, "Your spells", 110, function(self)
						ns.Picker.open(self, spellEntries(), function(value)
							if value ~= nil then
								if command.argument == "sequence" or command.argument == "list" then
									part.argument = part.argument == "" and value or (part.argument .. ", " .. value)
								else
									part.argument = value
								end
								Window.refresh()
							end
						end)
					end, "quiet"), 110 }
				end
				column.x = column.x + 16
				column:row(items, 26)
				column.x = column.x - 16
			end
			if ci > 1 then
				column.x = column.x + 16
				column:row({ { flat(column, "Remove this part", 150, function()
					table.remove(entry.clauses, ci)
					Window.refresh()
				end, "quiet"), 150 } }, 26)
				column.x = column.x - 16
			end
		end
		if entry.command == "castsequence" then
			words(column, "Start over after (seconds, or " .. table.concat(ns.Reference.castsequence_resets, ", ") .. "; several with /)", "GameFontHighlight", C.muted, 16)
			column.x = column.x + 16
			column:row({ { field(column, table.concat(entry.reset or {}, "/"), 250, function(text)
				entry.reset = splitList(text)
				showResult()
			end), 250 } }, 26)
			column.x = column.x - 16
		end
		if command and command.conditions then
			lineControls.otherwise = flat(column, "+ Otherwise...", 140, function()
				entry.clauses[#entry.clauses + 1] = clause()
				Window.refresh()
			end, "quiet")
			column:row({ { lineControls.otherwise, 140 } }, 26)
		end
		local rule = acquire("rule", column.parent, function(owner)
			local texture = owner:CreateTexture(nil, "ARTWORK")
			texture:SetColorTexture(unpack(C.line))
			return texture
		end)
		rule:SetSize(column.width, 1)
		column:place(rule, 1)
	end
	controls.addLine = flat(column, "+ Add a line", 160, function()
		macro.lines[#macro.lines + 1] = line("cast")
		Window.refresh()
	end, "primary")
	column:row({ { controls.addLine, 160 } }, 26)
end

-- --- Getting started and Words explained ---------------------------------------------------------

-- For new players: what a macro is, how to put one in the game, how to use it. It says where to
-- click in the game's own menus; nothing has to be typed but the macro itself.
Window.GUIDE = {
	{ "What is a macro?", table.concat({
		"A macro is a button you make yourself. It holds a few lines that tell the game what to do",
		"when you press it: cast a spell, cast it on someone in particular, or choose between two spells.",
		"Each line starts with a / and a word, like /cast: that is how the game reads macros, and this",
		"addon writes those lines for you.",
	}, " ") },
	{ "Make one here", table.concat({
		"1. On Make a macro, answer the five questions, or start from an example.",
		"2. On the right you see the finished macro and, in plain words, what it does. Red lines are mistakes the game would not accept: fix them first.",
		"3. Click Select to copy, then press Ctrl+C (Cmd+C on a Mac).",
	}, "\n") },
	{ "Put it in the game", table.concat({
		"1. Press Escape to open the Game Menu and choose Macros.",
		"2. Click New. Pick the question mark icon: the game then shows the spell's own icon.",
		"3. Give it a name and click Okay.",
		"4. Click in the big box at the bottom and press Ctrl+V (Cmd+V) to paste.",
		"5. Close the window: the macro is saved.",
		"6. Drag the macro's icon onto one of your action bars. Press it like any spell.",
	}, "\n") },
	{ "Words you will meet", table.concat({
		"If and Otherwise, if: a line can try several things in order. The first one whose conditions are true is done; the rest are skipped.",
		"On (@target, @focus, @mouseover): who the spell goes to. Without it, your target.",
		"Conditions: checks like 'the target is an enemy' or 'you hold Shift'. 'not' turns one around.",
		"Mouseover: whatever your mouse pointer is on, a portrait or a character.",
		"Focus: a second target you keep. Right-click a portrait and choose Set Focus.",
	}, "\n") },
	{ "Good to know", table.concat({
		"A macro can hold 255 characters: the counter turns red when it is too long.",
		"A macro cannot do anything you could not do by pressing buttons yourself, and one press casts one spell.",
		"The rules come from World of Warcraft's macro language; WoW Forever's client may differ in places.",
	}, " ") },
}

local function guidePage(column)
	column:heading("Getting started")
	column:paragraph("New to macros? This page is all you need. It takes two minutes.", C.text)
	for _, section in ipairs(Window.GUIDE) do
		local card = column:card()
		card.column:subheading(section[1])
		card.column:paragraph(section[2], C.text)
		column:after(card)
	end
	column:button("Make a macro", function()
		Window.select("simple")
	end, 200, "primary")
end

-- Every command, condition and target, from the rules themselves.
function Window.glossary()
	local said = {}
	local commandsSaid, conditionsSaid, targetsSaid = {}, {}, {}
	for _, entry in ipairs(ns.Reference.commands) do
		commandsSaid[#commandsSaid + 1] = "/" .. entry.name .. ": " .. entry.summary
	end
	for _, entry in ipairs(ns.Reference.conditions) do
		conditionsSaid[#conditionsSaid + 1] = "[" .. entry.name .. "]: " .. entry.summary .. (entry.unconfirmed and (" (" .. entry.unconfirmed .. ")") or "")
	end
	for _, entry in ipairs(ns.Reference.units) do
		local range = entry.range and (" (" .. entry.token .. entry.range[1] .. " to " .. entry.token .. entry.range[2] .. ")") or ""
		targetsSaid[#targetsSaid + 1] = "@" .. entry.token .. range .. ": " .. entry.summary
	end
	targetsSaid[#targetsSaid + 1] = "Add 'target' to any of them for its target: @focustarget is the target of your focus."
	said[1] = { "Commands (what a line does)", table.concat(commandsSaid, "\n") }
	said[2] = { "Conditions (checks in [ ]; 'no' in front turns one around)", table.concat(conditionsSaid, "\n") }
	said[3] = { "Targets (who it goes to, written @name)", table.concat(targetsSaid, "\n") }
	said[4] = { "Where this comes from", ns.Reference.source }
	return said
end

local function wordsPage(column)
	column:heading("Words explained")
	for _, section in ipairs(Window.glossary()) do
		local card = column:card()
		card.column:subheading(section[1])
		card.column:paragraph(section[2], C.text)
		column:after(card)
	end
end

-- --- The window ----------------------------------------------------------------------------------

local PAGES = {
	{ key = "simple", title = "Make a macro", build = simplePage, result = true },
	{ key = "advanced", title = "Advanced", result = true },
	{ key = "guide", title = "Getting started", build = guidePage },
	{ key = "words", title = "Words explained", build = wordsPage },
}

function Window.refresh()
	if frame == nil then
		return
	end
	for _, control in pairs(Window.controls.simple or {}) do
		if type(control) == "table" and type(rawget(control, "refresh")) == "function" then
			control.refresh()
		end
	end
	renderAdvanced()
	showResult()
end

function Window.select(key)
	for name, page in pairs(pages) do
		if name == key then
			page:Show()
		else
			page:Hide()
		end
	end
	Kit.selectTab(frame, key)
	Window.current = key
	ns.Picker.close()
	local withResult = key == "simple" or key == "advanced"
	if withResult then
		result:Show()
		Window.refresh()
	else
		result:Hide()
	end
end

local function build()
	frame = Kit.window("ForeverSimMacrosWindow", "ForeverSim Macros", WIDTH, HEIGHT, PAGES, Window.select)
	frame:SetScript("OnHide", function()
		ns.Picker.close()
	end)
	buildResult(frame.body)
	for _, spec in ipairs(PAGES) do
		local width = spec.result and (frame.bodyWidth - RESULT - 16) or frame.bodyWidth
		local holder = CreateFrame("Frame", nil, frame.body)
		holder:SetPoint("TOPLEFT")
		holder:SetSize(width, frame.bodyHeight)
		local page = Kit.scrollPage(holder, width, frame.bodyHeight)
		page.holder = holder
		if spec.build then
			spec.build(page.column)
		end
		Window.columns[spec.key] = page.column
		holder.content = page.content
		holder.column = page.column
		holder:Hide()
		pages[spec.key] = holder
	end
	Window.pages = pages
	-- A first visit starts with the guide.
	Window.select(db().seenGuide and "simple" or "guide")
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
