-- Equipment seen: its item level and the level it requires, as far as the client tells.
--
-- WoW Forever shows an item's level but may leave out the level it requires. What the client
-- does give is kept, item by item, in `items` of the saved file:
--   * `min_level`: the requirement the item's info gives (0 or 1 means none given);
--   * `tooltip_level`: the requirement its tooltip shows ("Requires Level 25"), if it shows one;
--   * `worn_at`: the lowest level the player was seen wearing it at. An item worn at level 20
--     needs 20 or less: that much is known even where the requirement itself is withheld.
-- Items are seen in the bags, worn, in the bank, at a merchant, in a loot window and in any item
-- tooltip the game shows. The addon never equips or tries an item to find anything out, and
-- reads nothing the client withholds (a withheld value is a gap, as everywhere).

local _, ns = ...

local Safe = ns.Safe

local Items = {}
ns.Items = Items

local MAX_ITEMS = 5000
local FIRST_WORN_SLOT, LAST_WORN_SLOT = 1, 19
local LAST_BAG = 4
-- The bank's own slots (-1) and its bags.
local BANK_CONTAINERS = { -1, 5, 6, 7, 8, 9, 10, 11 }
-- Equip locations of things that are not worn gear.
local NOT_GEAR = { [""] = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true }

-- Items already read this session at this player level: a bag update rereads every slot.
local readThisSession = {}

local function db()
	local store = ns.db
	if store == nil or not store.collecting then
		return nil
	end
	store.items = store.items or {}
	return store
end

-- The tooltip's "Requires Level %d", in the client's own language, as a pattern.
local function requiredPattern()
	local text = type(ITEM_MIN_LEVEL) == "string" and ITEM_MIN_LEVEL or "Requires Level %d"
	text = text:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	return "^" .. (text:gsub("%%d", "(%%d+)")) .. "$"
end

-- The level the tooltip says the item requires, or nil.
function Items.tooltipLevel(data)
	if Safe.isSecret(data) or type(data) ~= "table" or type(data.lines) ~= "table" then
		return nil
	end
	local pattern = requiredPattern()
	for _, line in ipairs(data.lines) do
		local text = type(line) == "table" and line.leftText or nil
		if not Safe.isSecret(text) and type(text) == "string" then
			local level = text:match(pattern)
			if level ~= nil then
				return tonumber(level)
			end
		end
	end
	return nil
end

local function tooltipFor(r, ref)
	if type(ref) == "string" then
		return r:call("C_TooltipInfo.GetHyperlink", Safe.api("C_TooltipInfo", "GetHyperlink"), ref)
	end
	return r:call("C_TooltipInfo.GetItemByID", Safe.api("C_TooltipInfo", "GetItemByID"), ref)
end

local function itemID(r, ref)
	if type(ref) == "number" then
		return ref
	end
	local parsed = ns.ItemLink.parse(ref)
	return parsed and parsed.item_id
end

local function count(store)
	local n = 0
	for _ in pairs(store.items) do
		n = n + 1
	end
	return n
end

-- Note an item the player sees. `ref` is its link or its ID; `source` says where it was seen;
-- `wornAt` is the player's level when it is worn; `tooltip` is tooltip data already at hand.
function Items.see(ref, source, wornAt, tooltip)
	local store = db()
	if store == nil or ref == nil or Safe.isSecret(ref) then
		return
	end
	local r = Safe.report()
	local id = itemID(r, ref)
	if id == nil then
		return
	end
	local entry = store.items[id]
	if entry == nil then
		local instant = Safe.api("C_Item", "GetItemInfoInstant") or GetItemInfoInstant
		local _, _, _, equipLoc = r:call("GetItemInfoInstant", instant, ref)
		if type(equipLoc) ~= "string" or NOT_GEAR[equipLoc] then
			return
		end
		if (store.items_count or count(store)) >= MAX_ITEMS then
			store.items_dropped = (store.items_dropped or 0) + 1
			return
		end
		entry = { equip_loc = equipLoc, seen = {} }
		store.items[id] = entry
		store.items_count = (store.items_count or 0) + 1
	end
	entry.seen[source] = true
	if type(wornAt) == "number" and (entry.worn_at == nil or wornAt < entry.worn_at) then
		entry.worn_at = wornAt
	end

	local playerLevel = r:call("UnitLevel", UnitLevel, "player")
	local key = tostring(id) .. ":" .. tostring(playerLevel)
	if readThisSession[key] then
		return -- a tooltip is shown again many times while the mouse rests on it
	end
	readThisSession[key] = true
	entry.last_seen = time and time() or nil
	local getInfo = Safe.api("C_Item", "GetItemInfo") or GetItemInfo
	local _, _, quality, _, minLevel = r:call("GetItemInfo", getInfo, ref)
	entry.quality = quality or entry.quality
	if type(minLevel) == "number" then
		entry.min_level = minLevel
	end
	local level = r:call("C_Item.GetDetailedItemLevelInfo", Safe.api("C_Item", "GetDetailedItemLevelInfo"), ref)
	if type(level) == "number" then
		entry.item_level = level
	end
	local shown = Items.tooltipLevel(tooltip or tooltipFor(r, ref))
	if shown ~= nil then
		entry.tooltip_level = shown
	end
	entry.gaps = r:gapList()
end

local function playerLevel()
	return Safe.scrub(UnitLevel and UnitLevel("player"))
end

function Items.scanWorn()
	if db() == nil then
		return
	end
	local level = playerLevel()
	for slot = FIRST_WORN_SLOT, LAST_WORN_SLOT do
		local r = Safe.report()
		local link = r:call("GetInventoryItemLink", GetInventoryItemLink, "player", slot)
		local id = r:call("GetInventoryItemID", GetInventoryItemID, "player", slot)
		Items.see(link or (id ~= 0 and id or nil), "worn", level)
	end
end

local function scanContainers(containers, source)
	if db() == nil then
		return
	end
	local slotCount = Safe.api("C_Container", "GetContainerNumSlots")
	local itemInfo = Safe.api("C_Container", "GetContainerItemInfo")
	local r = Safe.report()
	for _, bag in ipairs(containers) do
		for slot = 1, r:call("C_Container.GetContainerNumSlots", slotCount, bag) or 0 do
			local info = r:call("C_Container.GetContainerItemInfo", itemInfo, bag, slot)
			if type(info) == "table" then
				Items.see(info.hyperlink or info.itemID, source)
			end
		end
	end
end

function Items.scanBags()
	local bags = {}
	for bag = 0, LAST_BAG do
		bags[#bags + 1] = bag
	end
	scanContainers(bags, "bag")
end

function Items.scanBank()
	scanContainers(BANK_CONTAINERS, "bank")
end

function Items.scanMerchant()
	if db() == nil then
		return
	end
	local r = Safe.report()
	for index = 1, r:call("GetMerchantNumItems", GetMerchantNumItems) or 0 do
		Items.see(r:call("GetMerchantItemLink", GetMerchantItemLink, index), "merchant")
	end
end

-- Every item tooltip the game shows, wherever it comes from (a link in chat, a quest reward,
-- another player's gear): its data is read as it is, nothing is added to it.
function Items.watchTooltips()
	local processor = _G.TooltipDataProcessor
	local itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
	if type(processor) ~= "table" or type(processor.AddTooltipPostCall) ~= "function" or itemType == nil then
		return false
	end
	processor.AddTooltipPostCall(itemType, function(_, data)
		local ok = pcall(function()
			local id = type(data) == "table" and Safe.scrub(data.id) or nil
			if type(id) == "number" then
				Items.see(id, "tooltip", nil, data)
			end
		end)
		return ok
	end)
	return true
end
