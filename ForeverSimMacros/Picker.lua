-- A list to pick from: a button opens it next to itself, each entry says what it is, and
-- choosing one closes it. Made of plain frames, not the game's dropdown menus (which changed
-- between client versions).

local _, ns = ...

local Picker = {}
ns.Picker = Picker

local ROW_HEIGHT = 34
local WIDTH = 340
local MAX_SHOWN = 10

local frame
local rows = {}
-- What is offered now, and what to do with the choice (also read by the tests).
Picker.entries = {}
Picker.onPick = nil

local function build()
	frame = CreateFrame("Frame", "ForeverSimMacrosPicker", UIParent, "BackdropTemplate")
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		frame:SetBackdropColor(0.05, 0.06, 0.08, 0.97)
		frame:SetBackdropBorderColor(1, 1, 1, 0.2)
	end
	frame.scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	frame.scroll:SetPoint("TOPLEFT", 4, -4)
	frame.scroll:SetPoint("BOTTOMRIGHT", -26, 4)
	frame.list = CreateFrame("Frame", nil, frame.scroll)
	frame.list:SetWidth(WIDTH - 32)
	frame.scroll:SetScrollChild(frame.list)
	tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it
	frame:Hide()
end

local function row(index)
	if rows[index] == nil then
		local button = CreateFrame("Button", nil, frame.list)
		button:SetSize(WIDTH - 32, ROW_HEIGHT - 2)
		button:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
		button.hover = button:CreateTexture(nil, "BACKGROUND")
		button.hover:SetAllPoints()
		button.hover:SetColorTexture(1, 1, 1, 0.08)
		button.hover:Hide()
		button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		button.label:SetPoint("TOPLEFT", 6, -3)
		button.label:SetJustifyH("LEFT")
		button.about = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		button.about:SetPoint("BOTTOMLEFT", 6, 3)
		button.about:SetPoint("RIGHT", -6, 0)
		button.about:SetJustifyH("LEFT")
		button:SetScript("OnEnter", function(self)
			self.hover:Show()
		end)
		button:SetScript("OnLeave", function(self)
			self.hover:Hide()
		end)
		button:SetScript("OnClick", function(self)
			Picker.choose(self.index)
		end)
		rows[index] = button
	end
	return rows[index]
end

-- Open the list next to `anchor`. Each entry is { value, label, about }.
function Picker.open(anchor, entries, onPick)
	if frame == nil then
		build()
	end
	Picker.entries, Picker.onPick = entries, onPick
	for index, entry in ipairs(entries) do
		local button = row(index)
		button.index = index
		button.label:SetText(entry.label)
		button.about:SetText(entry.about or "")
		button:Show()
	end
	for index = #entries + 1, #rows do
		rows[index]:Hide()
	end
	frame.list:SetHeight(math.max(#entries, 1) * ROW_HEIGHT)
	frame:SetSize(WIDTH, math.min(#entries, MAX_SHOWN) * ROW_HEIGHT + 8)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	frame:Show()
end

function Picker.choose(index)
	local entry = Picker.entries[index]
	local onPick = Picker.onPick
	Picker.close()
	if entry ~= nil and onPick ~= nil then
		onPick(entry.value)
	end
end

function Picker.close()
	if frame ~= nil then
		frame:Hide()
	end
	Picker.onPick = nil
end

function Picker.isOpen()
	return frame ~= nil and frame:IsShown() == true
end
