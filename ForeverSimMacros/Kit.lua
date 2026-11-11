-- The look and the layout every ForeverSim window shares: a flat dark window with a title bar,
-- a list of pages down its left side, and pages laid out top to bottom in a column.
--
-- A column places each element under the one before, measured: a paragraph is as tall as its
-- wrapped text really is (FontString:GetStringHeight), so nothing is placed on top of anything
-- else whatever the text or the window's width. `column.placed` keeps where everything went, so
-- tests can check that nothing overlaps.

local _, ns = ...

local Kit = {}
ns.Kit = Kit

-- Colours: the ground, panels, lines between things, text, quieter text, and the accent.
Kit.COLOURS = {
	ground = { 0.055, 0.063, 0.082, 0.97 },
	panel = { 0.098, 0.110, 0.137, 1 },
	raised = { 0.140, 0.155, 0.190, 1 },
	line = { 1, 1, 1, 0.10 },
	text = { 0.92, 0.93, 0.95 },
	muted = { 0.62, 0.65, 0.70 },
	accent = { 0.98, 0.78, 0.25 },
	good = { 0.40, 0.85, 0.50 },
	bad = { 1.00, 0.35, 0.32 },
	warn = { 1.00, 0.80, 0.25 },
}
local C = Kit.COLOURS

Kit.SPACE = 10
Kit.SMALL_SPACE = 4
local WHITE = "Interface\\Buttons\\WHITE8X8"

local function backdrop(frame, fill, border)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
		frame:SetBackdropColor(unpack(fill))
		frame:SetBackdropBorderColor(unpack(border or C.line))
	end
end
Kit.backdrop = backdrop

function Kit.text(parent, font, colour)
	local words = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	words:SetJustifyH("LEFT")
	words:SetJustifyV("TOP")
	words:SetTextColor(unpack(colour or C.text))
	return words
end

-- --- Buttons -------------------------------------------------------------------------------------

-- A flat button. `kind`: "primary" (the accent), "quiet" (outlined) or nil (raised).
function Kit.button(parent, label, width, onClick, kind)
	local made = CreateFrame("Button", nil, parent, "BackdropTemplate")
	made:SetSize(width or 140, 26)
	made.kind = kind
	made.label = made:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	made.label:SetPoint("CENTER")
	made.paint = function(self)
		local fill = self.selected and C.accent or (self.kind == "primary" and C.accent) or (self.kind == "quiet" and { 0, 0, 0, 0 }) or C.raised
		local alpha = self.hover and 1 or 0.9
		backdrop(self, { fill[1], fill[2], fill[3], (fill[4] or 1) * alpha }, (self.selected or self.kind == "primary") and C.accent or C.line)
		local dark = self.selected or self.kind == "primary"
		self.label:SetTextColor(unpack(dark and { 0.08, 0.08, 0.1 } or C.text))
	end
	made.SetText = function(self, value)
		self.text = value
		self.label:SetText(value)
	end
	made.GetText = function(self)
		return self.text
	end
	made.select = function(self, on)
		self.selected = on and true or false
		if on then
			self:LockHighlight()
		else
			self:UnlockHighlight()
		end
		self:paint()
	end
	made:SetScript("OnEnter", function(self)
		self.hover = true
		self:paint()
	end)
	made:SetScript("OnLeave", function(self)
		self.hover = false
		self:paint()
	end)
	made:SetScript("OnClick", onClick)
	made:SetText(label)
	made:paint()
	return made
end

-- --- The window ----------------------------------------------------------------------------------

-- A window: title bar to drag it by, a close button, Escape closes it. `pages` is a list of
-- { key, title }; the window shows them down its left side and `onSelect(key)` is called.
function Kit.window(name, title, width, height, pages, onSelect)
	local window = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
	window:SetSize(width, height)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	backdrop(window, C.ground, { 1, 1, 1, 0.16 })
	tinsert(UISpecialFrames, name) -- Escape closes it

	local bar = CreateFrame("Frame", nil, window, "BackdropTemplate")
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("TOPRIGHT", -1, -1)
	bar:SetHeight(34)
	backdrop(bar, C.panel, { 0, 0, 0, 0 })
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	bar:SetScript("OnDragStart", function()
		window:StartMoving()
	end)
	bar:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
	end)
	window.title = Kit.text(bar, "GameFontNormalLarge", C.accent)
	window.title:SetPoint("LEFT", 14, 0)
	window.title:SetText(title)
	window.close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
	window.close:SetPoint("RIGHT", -4, 0)
	window.close:SetScript("OnClick", function()
		window:Hide()
	end)

	-- The pages, down the left side.
	local nav = CreateFrame("Frame", nil, window, "BackdropTemplate")
	nav:SetPoint("TOPLEFT", 1, -35)
	nav:SetPoint("BOTTOMLEFT", 1, 1)
	nav:SetWidth(170)
	backdrop(nav, C.panel, { 0, 0, 0, 0 })
	window.nav = nav
	window.tabs = {}
	for index, page in ipairs(pages) do
		local tab = Kit.button(nav, page.title, 150, function()
			onSelect(page.key)
		end, "quiet")
		tab:SetPoint("TOPLEFT", 10, -12 - (index - 1) * 32)
		tab.label:ClearAllPoints()
		tab.label:SetPoint("LEFT", 12, 0)
		window.tabs[page.key] = tab
	end

	-- Where a page goes.
	window.body = CreateFrame("Frame", nil, window)
	window.body:SetPoint("TOPLEFT", nav, "TOPRIGHT", 18, -14)
	window.body:SetPoint("BOTTOMRIGHT", -14, 14)
	window.bodyWidth = width - 170 - 36
	window.bodyHeight = height - 35 - 28
	return window
end

-- Mark the tab of the page shown.
function Kit.selectTab(window, key)
	for name, tab in pairs(window.tabs) do
		tab:select(name == key)
	end
end

-- A page that scrolls, with a column to lay it out in.
function Kit.scrollPage(parent, width, height)
	local page = CreateFrame("Frame", nil, parent)
	page:SetAllPoints()
	page.scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
	page.scroll:SetPoint("TOPLEFT", 0, 0)
	page.scroll:SetPoint("BOTTOMRIGHT", -24, 0)
	page.content = CreateFrame("Frame", nil, page.scroll)
	page.content:SetSize(width - 28, height)
	page.scroll:SetScrollChild(page.content)
	page.column = Kit.column(page.content, width - 28)
	return page
end

-- --- The column ----------------------------------------------------------------------------------

local Column = {}
Column.__index = Column

function Kit.column(parent, width, x, y)
	return setmetatable({ parent = parent, width = width, x = x or 0, top = y or 0, y = y or 0, placed = {} }, Column)
end

-- Put `widget` at the next free place, `height` tall (measured when not given), and move on.
function Column:place(widget, height, indent, width)
	height = height or widget:GetHeight() or 0
	widget:ClearAllPoints()
	widget:SetPoint("TOPLEFT", self.parent, "TOPLEFT", self.x + (indent or 0), self.y)
	table.insert(self.placed, { widget = widget, top = -self.y, height = height, indent = indent or 0, width = width or self.width })
	self.y = self.y - height - Kit.SPACE
	if self.parent.SetHeight then
		self.parent:SetHeight(math.max(-self.y, 1))
	end
	return widget
end

function Column:gap(size)
	self.y = self.y - (size or Kit.SPACE)
end

-- How tall the column has grown.
function Column:height()
	return -self.y + self.top
end

local function measured(words, width)
	words:SetWidth(width)
	local height = words.GetStringHeight and words:GetStringHeight() or nil
	return math.max(height or 14, 12)
end

function Column:heading(text)
	local words = Kit.text(self.parent, "GameFontNormalLarge", C.accent)
	words:SetText(text)
	return self:place(words, measured(words, self.width))
end

function Column:subheading(text)
	local words = Kit.text(self.parent, "GameFontNormal", C.text)
	words:SetText(text)
	return self:place(words, measured(words, self.width))
end

-- A paragraph, wrapped to the column and as tall as it turns out.
function Column:paragraph(text, colour, indent)
	local width = self.width - (indent or 0)
	local words = Kit.text(self.parent, "GameFontHighlight", colour or C.muted)
	words:SetText(text)
	words:SetSpacing(2)
	return self:place(words, measured(words, width), indent, width)
end

-- A thin line across, between sections.
function Column:rule()
	local line = self.parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(unpack(C.line))
	line:SetSize(self.width, 1)
	return self:place(line, 1)
end

function Column:button(label, onClick, width, kind)
	local made = Kit.button(self.parent, label, width or 160, onClick, kind)
	return self:place(made, 26, nil, width or 160)
end

-- Several widgets side by side on one line; each is { widget, width }. Returns the widgets.
function Column:row(items, height)
	local x = 0
	local first
	for _, item in ipairs(items) do
		local widget, width = item[1], item[2]
		widget:ClearAllPoints()
		widget:SetPoint("TOPLEFT", self.parent, "TOPLEFT", self.x + x, self.y)
		first = first or widget
		x = x + width + 8
	end
	table.insert(self.placed, { widget = first, top = -self.y, height = height or 26, indent = 0, width = math.max(x - 8, 0) })
	self.y = self.y - (height or 26) - Kit.SPACE
	if self.parent.SetHeight then
		self.parent:SetHeight(math.max(-self.y, 1))
	end
	return items
end

-- A setting that is on or off: the box, its label beside it, and what it does under that.
function Column:check(label, help, get, set)
	local box = CreateFrame("CheckButton", nil, self.parent, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.label = Kit.text(self.parent, "GameFontHighlight", C.text)
	box.label:SetText(label)
	box:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)
	box.refresh = function()
		box:SetChecked(get() and true or false)
	end
	box.refresh()
	self:place(box, math.max(24, measured(box.label, self.width - 30) + 6))
	box.label:ClearAllPoints()
	box.label:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, -5)
	if help then
		self.y = self.y + Kit.SPACE - Kit.SMALL_SPACE
		self:paragraph(help, C.muted, 30)
	end
	return box
end

-- A choice of a few: a label, a row of buttons (the chosen one lit), and what it means.
function Column:choice(label, help, options, get, set)
	self:subheading(label)
	local holder = { buttons = {} }
	local items = {}
	for index, option in ipairs(options) do
		local pick = Kit.button(self.parent, option.label, option.width or 150, function()
			set(option.value)
			holder.refresh()
		end, "quiet")
		pick.value = option.value
		holder.buttons[index] = pick
		items[#items + 1] = { pick, option.width or 150 }
	end
	self:row(items)
	holder.refresh = function()
		for _, pick in ipairs(holder.buttons) do
			pick:select(get() == pick.value)
		end
	end
	holder.refresh()
	if help then
		self.y = self.y + Kit.SPACE - Kit.SMALL_SPACE
		self:paragraph(help)
	end
	return holder
end

-- A choice of several, one per line (the chosen one lit), and under them what the chosen one
-- means. Each option is { value, label, about }.
function Column:radio(options, get, set)
	local holder = { buttons = {} }
	for index, option in ipairs(options) do
		local pick = Kit.button(self.parent, option.label, self.width, function()
			set(option.value)
			holder.refresh()
		end, "quiet")
		pick.label:ClearAllPoints()
		pick.label:SetPoint("LEFT", 12, 0)
		pick.value = option.value
		holder.buttons[index] = pick
		self:place(pick, 26)
		self.y = self.y + Kit.SPACE - Kit.SMALL_SPACE
	end
	self.y = self.y - Kit.SPACE + Kit.SMALL_SPACE
	-- The longest description decides the room it takes, so nothing below moves when it changes.
	local about = Kit.text(self.parent, "GameFontHighlight", C.muted)
	local tallest = 14
	for _, option in ipairs(options) do
		about:SetText(option.about or "")
		tallest = math.max(tallest, measured(about, self.width))
	end
	self:place(about, tallest)
	holder.about = about
	holder.refresh = function()
		for index, pick in ipairs(holder.buttons) do
			local chosen = get() == pick.value
			pick:select(chosen)
			if chosen then
				about:SetText(options[index].about or "")
			end
		end
	end
	holder.refresh()
	return holder
end

-- A number: its label and value on one line, the slider under them, and what it does.
function Column:slider(label, help, low, high, step, get, set, shown)
	local holder = CreateFrame("Frame", nil, self.parent)
	local width = math.min(self.width, 360)
	holder:SetSize(width, 44)
	holder.label = Kit.text(holder, "GameFontHighlight", C.text)
	holder.label:SetPoint("TOPLEFT", 0, 0)
	holder.label:SetText(label)
	holder.value = Kit.text(holder, "GameFontHighlight", C.accent)
	holder.value:SetPoint("TOPRIGHT", 0, 0)
	holder.value:SetJustifyH("RIGHT")
	local bar = CreateFrame("Slider", nil, holder, "BackdropTemplate")
	bar:SetOrientation("HORIZONTAL")
	bar:SetSize(width, 14)
	bar:SetPoint("TOPLEFT", 0, -22)
	bar:SetMinMaxValues(low, high)
	bar:SetValueStep(step)
	bar:SetObeyStepOnDrag(true)
	bar:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	backdrop(bar, C.raised)
	local quiet = false
	bar:SetScript("OnValueChanged", function(_, value)
		value = math.floor(value / step + 0.5) * step
		holder.value:SetText(shown(value))
		if not quiet then
			set(value)
		end
	end)
	holder.bar = bar
	holder.refresh = function()
		quiet = true
		bar:SetValue(get())
		holder.value:SetText(shown(get()))
		quiet = false
	end
	holder.refresh()
	self:place(holder, 40, nil, width)
	if help then
		self.y = self.y + Kit.SPACE - Kit.SMALL_SPACE
		self:paragraph(help)
	end
	return holder
end

-- A line of text to type in, with its label above.
function Column:input(label, value, width, onChange)
	if label then
		self:subheading(label)
		self.y = self.y + Kit.SPACE - Kit.SMALL_SPACE
	end
	local box = CreateFrame("EditBox", nil, self.parent, "BackdropTemplate")
	box:SetSize(width or 260, 26)
	box:SetAutoFocus(false)
	box:SetFontObject(ChatFontNormal)
	box:SetTextInsets(8, 8, 0, 0)
	backdrop(box, { 0, 0, 0, 0.45 })
	box:SetText(value or "")
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			onChange(self:GetText())
		end
	end)
	return self:place(box, 26, nil, width or 260)
end

-- A box with a lighter ground, for what belongs together (a step, a result). Its own column.
function Column:card(height)
	local card = CreateFrame("Frame", nil, self.parent, "BackdropTemplate")
	card:SetSize(self.width, height or 40)
	backdrop(card, C.panel)
	self:place(card, height or 40)
	card.column = Kit.column(card, self.width - 24, 12, -12)
	-- Grows to what is put in it; the column under it moves down with it.
	card.fit = function()
		local grown = card.column:height() + 4
		card:SetHeight(grown)
		return grown
	end
	return card
end

-- After filling a card, move the column on to below it.
function Column:after(card)
	local grown = card.fit()
	local last = self.placed[#self.placed]
	if last and last.widget == card then
		self.y = self.y + last.height - grown
		last.height = grown
	end
	if self.parent.SetHeight then
		self.parent:SetHeight(math.max(-self.y, 1))
	end
end

-- For tests: every pair of things this column placed that overlap, as "a / b" descriptions.
function Column:overlaps()
	local found = {}
	for i = 1, #self.placed do
		for j = i + 1, #self.placed do
			local a, b = self.placed[i], self.placed[j]
			if a.top < b.top + b.height and b.top < a.top + a.height then
				found[#found + 1] = i .. " / " .. j
			end
		end
	end
	return found
end

