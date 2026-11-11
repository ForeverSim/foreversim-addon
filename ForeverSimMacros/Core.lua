-- ForeverSim Macros: a macro maker in the game. It opens from a small button on the screen (it
-- can be moved and hidden), from its entry in the game's Options under AddOns, and from
-- ForeverSim's control panel when that addon is installed. No command has to be typed.
--
-- It writes a macro's text and explains it; the player copies the text into the game's own macro
-- window. It never makes, changes or runs a macro itself.

local addonName, ns = ...

ns.VERSION = "0.1.0"

local launcher

local function db()
	ForeverSimMacrosDB = ForeverSimMacrosDB or {}
	local store = ForeverSimMacrosDB
	if store.launcherShown == nil then
		store.launcherShown = true
	end
	return store
end

-- The small round button that opens the window: click to open, drag to move.
local function buildLauncher()
	launcher = CreateFrame("Button", "ForeverSimMacrosLauncher", UIParent)
	launcher:SetSize(36, 36)
	launcher:SetFrameStrata("MEDIUM")
	launcher:SetClampedToScreen(true)
	launcher:SetMovable(true)
	launcher:RegisterForDrag("LeftButton")
	launcher.icon = launcher:CreateTexture(nil, "ARTWORK")
	launcher.icon:SetAllPoints()
	launcher.icon:SetTexture("Interface\\AddOns\\ForeverSimMacros\\Logo.tga")
	launcher:SetScript("OnClick", function()
		ns.Window.toggle()
	end)
	launcher:SetScript("OnDragStart", launcher.StartMoving)
	launcher:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint()
		db().launcherPosition = { point, relativePoint, x, y }
	end)
	launcher:SetScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:AddLine("ForeverSim Macros")
			GameTooltip:AddLine("Click to make a macro. Drag to move this button.", 1, 1, 1)
			GameTooltip:Show()
		end
	end)
	launcher:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	local position = db().launcherPosition
	if type(position) == "table" and position[1] then
		launcher:SetPoint(position[1], UIParent, position[2], position[3], position[4])
	else
		launcher:SetPoint("RIGHT", UIParent, "RIGHT", -24, 120)
	end
end

function ns.showLauncher(on)
	db().launcherShown = on and true or false
	if launcher == nil then
		buildLauncher()
	end
	if on then
		launcher:Show()
	else
		launcher:Hide()
	end
end

-- An entry in the game's own Options (AddOns): open the maker, show or hide the button.
local function register()
	local settings = _G.Settings
	if type(settings) ~= "table" or type(settings.RegisterCanvasLayoutCategory) ~= "function" then
		return false
	end
	return pcall(function()
		local canvas = CreateFrame("Frame")
		local about = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		about:SetPoint("TOPLEFT", 16, -16)
		about:SetWidth(560)
		about:SetJustifyH("LEFT")
		about:SetText("Make macros by picking what they should do, with every part explained. Copy the result into the game's macro window (Game Menu, Macros).")
		local open = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
		open:SetSize(200, 24)
		open:SetPoint("TOPLEFT", 16, -60)
		open:SetText("Open the macro maker")
		open:SetScript("OnClick", function()
			ns.Window.open()
		end)
		local shown = CreateFrame("CheckButton", nil, canvas, "UICheckButtonTemplate")
		shown:SetPoint("TOPLEFT", 16, -96)
		shown:SetChecked(db().launcherShown)
		shown:SetScript("OnClick", function(self)
			ns.showLauncher(self:GetChecked() and true or false)
		end)
		local words = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		words:SetPoint("LEFT", shown, "RIGHT", 4, 0)
		words:SetText("Show the macro maker's button on the screen")
		local category = settings.RegisterCanvasLayoutCategory(canvas, "ForeverSim Macros")
		settings.RegisterAddOnCategory(category)
	end)
end

-- What other addons may use: ForeverSim's control panel opens the maker with it.
ForeverSimMacros = {
	version = ns.VERSION,
	open = function(page)
		ns.Window.open(page)
	end,
}

local events = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
	if name == addonName then
		db()
	end
end

function handlers.PLAYER_LOGIN()
	register()
	ns.showLauncher(db().launcherShown)
end

for event in pairs(handlers) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)
