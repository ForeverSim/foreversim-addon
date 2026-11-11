-- Parse item links ("|cff...|Hitem:19019:1900:...|h[Name]|h|r") into their numeric fields.
--
-- The enchant field is the client's enchantment ID (SpellItemEnchantment), not the spell ID of
-- the enchanting spell; the backend maps between the two. The full item string is kept so that
-- fields this parser ignores (bonus IDs, modifiers) can be read later without a new snapshot.

local _, ns = ...

local ItemLink = {}
ns.ItemLink = ItemLink

local function toNumber(field)
	local number = tonumber(field)
	if number == nil or number == 0 then
		return nil
	end
	return number
end

-- Returns nil for anything that is not an item link.
function ItemLink.parse(link)
	if type(link) ~= "string" then
		return nil
	end
	local itemString = link:match("|H(item:[^|]+)|h") or link:match("^(item:[%-%d:]+)$")
	if itemString == nil then
		return nil
	end
	local fields = {}
	-- Keep empty fields: "item:1::::" has empty enchant and gem slots.
	for field in (itemString .. ":"):gmatch("([^:]*):") do
		fields[#fields + 1] = field
	end
	local itemID = toNumber(fields[2])
	if itemID == nil then
		return nil
	end
	local gems = {}
	for i = 4, 7 do
		local gem = toNumber(fields[i])
		if gem ~= nil then
			gems[#gems + 1] = gem
		end
	end
	return {
		item_id = itemID,
		enchant_id = toNumber(fields[3]),
		gem_ids = gems,
		suffix_id = tonumber(fields[8]) ~= 0 and tonumber(fields[8]) or nil,
		item_string = itemString,
	}
end
