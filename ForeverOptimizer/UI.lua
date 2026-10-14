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

-- The question asked once, when the game starts: may fights be recorded? Nothing is recorded
-- before the player says yes. Closing the window without an answer asks again next time.
local question

local QUESTION = table.concat({
	"Forever Optimizer can record what happens as you play, to make the simulator more accurate:",
	"",
	"- how hard creatures hit you, and how much damage it takes to kill them",
	"- where on the map you met them, and what they and the nodes you gather from dropped",
	"- the talents and gear you fought with",
	"",
	"Nothing about other players is recorded. Nothing leaves your computer: it is kept in the addon's own saved file, which you can choose to send.",
	"",
	"You can change your mind at any time: /optimizer pause and /optimizer resume.",
}, "\n")

function UI.askToRecord(onAnswer)
	if question == nil then
		question = CreateFrame("Frame", "ForeverOptimizerQuestionFrame", UIParent, "BasicFrameTemplateWithInset")
		question:SetSize(460, 300)
		question:SetPoint("CENTER")
		question:SetFrameStrata("DIALOG")
		question:SetMovable(true)
		question:EnableMouse(true)
		question:RegisterForDrag("LeftButton")
		question:SetScript("OnDragStart", question.StartMoving)
		question:SetScript("OnDragStop", question.StopMovingOrSizing)

		question.title = question:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		question.title:SetPoint("TOP", 0, -6)
		question.title:SetText("Forever Optimizer")

		question.text = question:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		question.text:SetPoint("TOPLEFT", 18, -36)
		question.text:SetPoint("TOPRIGHT", -18, -36)
		question.text:SetJustifyH("LEFT")
		question.text:SetText(QUESTION)

		question.start = CreateFrame("Button", "ForeverOptimizerQuestionStart", question, "UIPanelButtonTemplate")
		question.start:SetSize(160, 26)
		question.start:SetPoint("BOTTOMLEFT", 40, 18)
		question.start:SetText("Start recording")

		question.decline = CreateFrame("Button", "ForeverOptimizerQuestionDecline", question, "UIPanelButtonTemplate")
		question.decline:SetSize(160, 26)
		question.decline:SetPoint("BOTTOMRIGHT", -40, 18)
		question.decline:SetText("Do not record")
	end
	question.start:SetScript("OnClick", function()
		question:Hide()
		onAnswer(true)
	end)
	question.decline:SetScript("OnClick", function()
		question:Hide()
		onAnswer(false)
	end)
	question:Show()
end
