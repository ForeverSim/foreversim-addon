-- What has been recorded, and what the player got while recording: kept in `stats` of the
-- saved file and shown on the control panel. Counted only while recording is on.
--
--   seconds          time spent recording (`since`: when recording was first turned on)
--   fights, kills, deaths
--   money_looted     copper gained while a loot window was open (or just after it closed)
--   money_sold       copper gained at a merchant
--   items_looted     item ID -> how many were taken from loot windows; by_quality: per quality
--   items_sold       item ID -> how many left the bags at a merchant as the money came in
--   xp, levels       experience and levels gained
-- Nothing here reads chat: money is the player's own purse, items are the loot window's slots
-- and the bags, experience the player's own bar.

local _, ns = ...

local Safe = ns.Safe

local Stats = {}
ns.Stats = Stats

-- Money that arrives this soon after a loot window closed came from it (auto loot closes the
-- window before the purse is updated).
local LOOT_MONEY_GRACE_S = 1.5

local lastMoney, lastXP, lastXPMax, lastLevel
local lootSlots, lootOpen, lootClosedAt = {}, false, nil
local merchantOpen, bagsAtMerchant, saleMoneyPending = false, nil, false
local countingSince

local function now()
	return GetTime and GetTime() or 0
end

local function clock()
	return time and time() or 0
end

local function read(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	return ok and (Safe.scrub(value)) or nil
end

local function stats()
	local store = ns.db
	if store == nil or not store.collecting then
		return nil
	end
	local kept = store.stats
	if type(kept) ~= "table" then
		kept = {}
		store.stats = kept
	end
	kept.items_looted = kept.items_looted or {}
	kept.items_sold = kept.items_sold or {}
	kept.by_quality = kept.by_quality or {}
	kept.since = kept.since or clock()
	return kept
end

local function add(kept, name, amount)
	kept[name] = (kept[name] or 0) + amount
end

-- Add the time since the clock last ran to `seconds`, and restart it when recording is on.
function Stats.tick()
	local kept = stats()
	if kept ~= nil and countingSince ~= nil then
		add(kept, "seconds", math.max(clock() - countingSince, 0))
	end
	countingSince = kept ~= nil and clock() or nil
end

-- The seconds recorded, the running stretch included.
function Stats.seconds()
	local kept = ns.db and ns.db.stats
	local seconds = type(kept) == "table" and kept.seconds or 0
	if countingSince ~= nil then
		seconds = seconds + math.max(clock() - countingSince, 0)
	end
	return seconds
end

function Stats.start()
	lastMoney = read(GetMoney)
	lastXP, lastXPMax = read(UnitXP, "player"), read(UnitXPMax, "player")
	lastLevel = read(UnitLevel, "player")
	Stats.tick()
end

function Stats.onFight(fight)
	local kept = stats()
	if kept == nil then
		return
	end
	add(kept, "fights", 1)
	add(kept, "kills", type(fight.kills) == "table" and #fight.kills or 0)
	if fight.death ~= nil then
		add(kept, "deaths", 1)
	end
end

local function bagCounts()
	local counts = {}
	local slotCount = Safe.api("C_Container", "GetContainerNumSlots")
	local itemInfo = Safe.api("C_Container", "GetContainerItemInfo")
	for bag = 0, 4 do
		for slot = 1, read(slotCount, bag) or 0 do
			local info = read(itemInfo, bag, slot)
			if type(info) == "table" and type(info.itemID) == "number" then
				counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
			end
		end
	end
	return counts
end

function Stats.onMoney()
	local money = read(GetMoney)
	if type(money) ~= "number" then
		return
	end
	local gained = lastMoney ~= nil and money - lastMoney or 0
	lastMoney = money
	local kept = stats()
	if kept == nil or gained <= 0 then
		return
	end
	if merchantOpen then
		add(kept, "money_sold", gained)
		saleMoneyPending = true
		Stats.onBagsChanged()
	elseif lootOpen or (lootClosedAt ~= nil and now() - lootClosedAt <= LOOT_MONEY_GRACE_S) then
		add(kept, "money_looted", gained)
	end
end

function Stats.onLootOpened()
	lootOpen, lootSlots = true, {}
	for slot = 1, read(GetNumLootItems) or 0 do
		local link = read(GetLootSlotLink, slot)
		local item = ns.ItemLink.parse(link)
		if item ~= nil then
			local _, _, _, quantity, _, quality = pcall(GetLootSlotInfo, slot)
			lootSlots[slot] = {
				item_id = item.item_id,
				count = type(quantity) == "number" and not Safe.isSecret(quantity) and quantity or 1,
				quality = type(quality) == "number" and not Safe.isSecret(quality) and quality or nil,
			}
		end
	end
end

-- A slot of the loot window was taken.
function Stats.onLootSlotCleared(slot)
	local taken = lootSlots[slot]
	lootSlots[slot] = nil
	local kept = stats()
	if kept == nil or taken == nil then
		return
	end
	add(kept.items_looted, taken.item_id, taken.count)
	add(kept, "items_looted_count", taken.count)
	if taken.quality ~= nil then
		add(kept.by_quality, tostring(taken.quality), taken.count)
	end
end

function Stats.onLootClosed()
	lootOpen, lootSlots, lootClosedAt = false, {}, now()
end

function Stats.onMerchantShow()
	merchantOpen, saleMoneyPending = true, false
	bagsAtMerchant = bagCounts()
end

function Stats.onMerchantClosed()
	merchantOpen, bagsAtMerchant, saleMoneyPending = false, nil, false
end

-- At a merchant, after money came in: what left the bags was sold.
function Stats.onBagsChanged()
	if not merchantOpen or bagsAtMerchant == nil then
		return
	end
	local counts = bagCounts()
	local kept = stats()
	if saleMoneyPending and kept ~= nil then
		for id, before in pairs(bagsAtMerchant) do
			local gone = before - (counts[id] or 0)
			if gone > 0 then
				add(kept.items_sold, id, gone)
				add(kept, "items_sold_count", gone)
				saleMoneyPending = false
			end
		end
	end
	bagsAtMerchant = counts
end

function Stats.onXP()
	local xp, xpMax = read(UnitXP, "player"), read(UnitXPMax, "player")
	local level = read(UnitLevel, "player")
	if type(xp) ~= "number" then
		return
	end
	local kept = stats()
	if kept ~= nil and type(lastXP) == "number" then
		local gained
		if type(level) == "number" and type(lastLevel) == "number" and level > lastLevel then
			gained = (type(lastXPMax) == "number" and lastXPMax - lastXP or 0) + xp
			add(kept, "levels", level - lastLevel)
		else
			gained = xp - lastXP
		end
		if gained > 0 then
			add(kept, "xp", gained)
		end
	end
	lastXP, lastXPMax, lastLevel = xp, xpMax, level
end

-- The figures the control panel shows, worked out from the saved file and `stats`.
function Stats.summary()
	local store = ns.db or {}
	local kept = type(store.stats) == "table" and store.stats or {}
	local creatures = 0
	for _ in pairs(store.creatures or {}) do
		creatures = creatures + 1
	end
	local distinctLooted, distinctSold = 0, 0
	for _ in pairs(kept.items_looted or {}) do
		distinctLooted = distinctLooted + 1
	end
	for _ in pairs(kept.items_sold or {}) do
		distinctSold = distinctSold + 1
	end
	return {
		recording = store.collecting == true,
		since = kept.since,
		seconds = Stats.seconds(),
		fights = kept.fights or 0,
		fights_kept = #(store.fights or {}),
		kills = kept.kills or 0,
		deaths = kept.deaths or 0,
		hits = store.hits_stored or 0,
		creatures = creatures,
		loot_windows = #(store.loots or {}),
		gear_seen = store.items_count or 0,
		money_looted = kept.money_looted or 0,
		money_sold = kept.money_sold or 0,
		items_looted = kept.items_looted_count or 0,
		items_looted_kinds = distinctLooted,
		by_quality = kept.by_quality or {},
		items_sold = kept.items_sold_count or 0,
		items_sold_kinds = distinctSold,
		xp = kept.xp or 0,
		levels = kept.levels or 0,
	}
end

-- Copper as the game writes it: "12g 3s 40c".
function Stats.money(copper)
	copper = math.floor(copper or 0)
	local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = gold .. "g"
	end
	if silver > 0 or gold > 0 then
		parts[#parts + 1] = silver .. "s"
	end
	parts[#parts + 1] = (copper % 100) .. "c"
	return table.concat(parts, " ")
end

function Stats.duration(seconds)
	seconds = math.floor(seconds or 0)
	local hours, minutes = math.floor(seconds / 3600), math.floor(seconds / 60) % 60
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	return string.format("%dm", minutes)
end
