-- The export window: the snapshot as text, selected, ready to copy into the website.
-- Addons cannot make web requests, so copy and paste is how a snapshot leaves the game.

local _, ns = ...

local UI = {}
ns.UI = UI

local frame

local function build()
	frame = CreateFrame("Frame", "ForeverOptimizerExportFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(560, 420)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	frame.title:SetPoint("TOP", 0, -6)
	frame.title:SetText("Forever Optimizer")

	frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.hint:SetPoint("TOPLEFT", 14, -32)
	frame.hint:SetPoint("TOPRIGHT", -14, -32)
	frame.hint:SetJustifyH("LEFT")
	frame.hint:SetText("Press Ctrl+C to copy, then paste it into the import page on the website.")

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -52)
	scroll:SetPoint("BOTTOMRIGHT", -32, 14)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(true)
	edit:SetFontObject(ChatFontSmall)
	edit:SetWidth(500)
	edit:SetScript("OnEscapePressed", function()
		frame:Hide()
	end)
	-- Read-only: any edit puts the export text back.
	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(frame.text or "")
			self:HighlightText()
		end
	end)
	scroll:SetScrollChild(edit)
	frame.edit = edit
end

function UI.showExport(text)
	if frame == nil then
		build()
	end
	frame.text = text
	frame.edit:SetText(text)
	frame:Show()
	frame.edit:SetFocus()
	frame.edit:HighlightText()
end
