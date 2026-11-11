-- The spells in the player's own spellbook, by name, to pick from in the macro maker. Passive
-- ones are left out: they cannot be cast. Whatever the client withholds is left out too.

local _, ns = ...

local Safe = ns.Safe

local Spells = {}
ns.Spells = Spells

function Spells.known()
	local lines = Safe.api("C_SpellBook", "GetNumSpellBookSkillLines")
	local lineInfo = Safe.api("C_SpellBook", "GetSpellBookSkillLineInfo")
	local itemInfo = Safe.api("C_SpellBook", "GetSpellBookItemInfo")
	local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
	local r = Safe.report()
	local names, seen = {}, {}
	for lineIndex = 1, r:call("C_SpellBook.GetNumSpellBookSkillLines", lines) or 0 do
		local info = r:call("C_SpellBook.GetSpellBookSkillLineInfo", lineInfo, lineIndex)
		if type(info) == "table" and type(info.numSpellBookItems) == "number" then
			local first = (info.itemIndexOffset or 0) + 1
			for slot = first, first + info.numSpellBookItems - 1 do
				local item = r:call("C_SpellBook.GetSpellBookItemInfo", itemInfo, slot, bank)
				local name = type(item) == "table" and item.name or nil
				if type(name) == "string" and not item.isPassive and not seen[name] then
					seen[name] = true
					names[#names + 1] = name
				end
			end
		end
	end
	table.sort(names)
	return names
end
