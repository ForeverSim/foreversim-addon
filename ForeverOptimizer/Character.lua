-- The character snapshot: everything the import needs to rebuild Character State, read out of
-- combat (most stats are secret while combat restrictions are active).
--
-- The addon reports what the client says and nothing more. It never decides what is valid:
-- the server validates every ID, level and item (an addon payload is never trusted).

local _, ns = ...

local Safe = ns.Safe
local ItemLink = ns.ItemLink
local Json = ns.Json

local Character = {}
ns.Character = Character

-- Inventory slot IDs as the client numbers them (0 ammo ... 19 tabard). The backend maps them to
-- equipment slots; the addon sends the client's numbers unchanged.
local FIRST_INVENTORY_SLOT, LAST_INVENTORY_SLOT = 0, 19
local PRIMARY_STATS = { "strength", "agility", "stamina", "intellect", "spirit" }
-- UnitResistance index -> school; 0 is armor.
local RESISTANCE_SCHOOLS = { [0] = "physical", "holy", "fire", "nature", "frost", "shadow", "arcane" }
-- GetSpellBonusDamage / GetSpellCritChance school index -> school.
local SPELL_SCHOOLS = { [2] = "holy", [3] = "fire", [4] = "nature", [5] = "frost", [6] = "shadow", [7] = "arcane" }
-- Combat rating indices are read 1..N and sent as a list; the backend owns their meaning.
local COMBAT_RATING_COUNT = 32
-- Armor and attacker levels at which the client's own armor formula is sampled.
local ARMOR_SAMPLES = { 0, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 12000 }
local ATTACKER_LEVELS = { 1, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 61, 62, 63 }
local MAX_AURAS = 40

local function identity(r)
	local character = {}
	character.name = r:call("UnitName", UnitName, "player")
	character.realm = r:call("GetRealmName", GetRealmName)
	local raceName, raceFile, raceID = r:call("UnitRace", UnitRace, "player")
	character.race = { name = raceName, file = raceFile, id = raceID }
	local className, classFile, classID = r:call("UnitClass", UnitClass, "player")
	character.class = { name = className, file = classFile, id = classID }
	character.sex = r:call("UnitSex", UnitSex, "player")
	character.level = r:call("UnitLevel", UnitLevel, "player")
	return character
end

local function enchantText(r, slot)
	local data = r:call("C_TooltipInfo.GetInventoryItem", Safe.api("C_TooltipInfo", "GetInventoryItem"), "player", slot)
	if type(data) ~= "table" or type(data.lines) ~= "table" then
		return nil
	end
	local permanent = Enum and Enum.TooltipDataLineType and Enum.TooltipDataLineType.ItemEnchantmentPermanent
	for _, line in ipairs(data.lines) do
		if permanent ~= nil and line.type == permanent then
			return line.leftText
		end
	end
	return nil
end

local function equipment(r)
	local items = {}
	for slot = FIRST_INVENTORY_SLOT, LAST_INVENTORY_SLOT do
		local link = r:call("GetInventoryItemLink", GetInventoryItemLink, "player", slot)
		local item = ItemLink.parse(link)
		if item == nil then
			-- No link (item data not loaded yet, or withheld): the ID alone still says what is worn.
			local itemID = r:call("GetInventoryItemID", GetInventoryItemID, "player", slot)
			if itemID ~= nil and itemID ~= 0 then -- 0: the slot is empty
				item = { item_id = itemID, gem_ids = {}, link_missing = true }
			end
		end
		if item ~= nil then
			item.slot = slot
			item.item_level = r:call(
				"C_Item.GetDetailedItemLevelInfo",
				Safe.api("C_Item", "GetDetailedItemLevelInfo"),
				link or item.item_id
			)
			if item.enchant_id ~= nil then
				item.enchant_text = enchantText(r, slot)
			end
			items[#items + 1] = item
		end
	end
	return items
end

local function activeTalentConfig(r)
	local specGroup = r:call("C_SpecializationInfo.GetActiveSpecGroup", Safe.api("C_SpecializationInfo", "GetActiveSpecGroup"))
	local configID
	if specGroup ~= nil then
		-- The path Forever's own talent frame takes.
		configID = r:call(
			"C_SpecializationInfo.GetCombatConfigIDForSpecGroup",
			Safe.api("C_SpecializationInfo", "GetCombatConfigIDForSpecGroup"),
			specGroup
		)
	end
	if configID == nil then
		configID = r:call("C_ClassTalents.GetActiveConfigID", Safe.api("C_ClassTalents", "GetActiveConfigID"))
	end
	return configID, specGroup
end

local function talents(r)
	local configID, specGroup = activeTalentConfig(r)
	local result = { config_id = configID, spec_group = specGroup, nodes = {} }
	if configID == nil then
		return result
	end
	local config = r:call("C_Traits.GetConfigInfo", Safe.api("C_Traits", "GetConfigInfo"), configID)
	result.tree_ids = config and config.treeIDs or {}
	local getNodes = Safe.api("C_Traits", "GetTreeNodes")
	local getNode = Safe.api("C_Traits", "GetNodeInfo")
	local getEntry = Safe.api("C_Traits", "GetEntryInfo")
	local getDefinition = Safe.api("C_Traits", "GetDefinitionInfo")
	for _, treeID in ipairs(result.tree_ids) do
		for _, nodeID in ipairs(r:call("C_Traits.GetTreeNodes", getNodes, treeID) or {}) do
			local node = r:call("C_Traits.GetNodeInfo", getNode, configID, nodeID)
			if node and (node.activeRank or 0) > 0 then
				local entryID = node.activeEntry and node.activeEntry.entryID
				local entry = entryID and r:call("C_Traits.GetEntryInfo", getEntry, configID, entryID)
				local definition = entry and r:call("C_Traits.GetDefinitionInfo", getDefinition, entry.definitionID)
				result.nodes[#result.nodes + 1] = {
					tree_id = treeID,
					node_id = nodeID,
					rank = node.activeRank,
					max_ranks = node.maxRanks,
					entry_id = entryID,
					definition_id = entry and entry.definitionID,
					spell_id = definition and definition.spellID,
					overridden_spell_id = definition and definition.overriddenSpellID,
				}
			end
		end
	end
	return result
end

local function professions(r)
	local list = {}
	local indices = { r:call("GetProfessions", GetProfessions) }
	for i = 1, 5 do
		local index = indices[i]
		if index ~= nil then
			local name, _, rank, maxRank, _, _, skillLine, modifier = r:call("GetProfessionInfo", GetProfessionInfo, index)
			list[#list + 1] = { skill_line = skillLine, name = name, rank = rank, max_rank = maxRank, modifier = modifier }
		end
	end
	return list
end

-- Weapon skills, defense, languages and professions. Collapsed headers hide their lines, so they
-- are expanded for the read and collapsed again afterwards.
local function skills(r)
	local count = Safe.api("C_SkillInfo", "GetNumSkillLines")
	local info = Safe.api("C_SkillInfo", "GetSkillLineInfo")
	local expand = Safe.api("C_SkillInfo", "ExpandSkillHeader")
	local collapse = Safe.api("C_SkillInfo", "CollapseSkillHeader")
	local reopened = {}
	if expand ~= nil then
		for i = (r:call("C_SkillInfo.GetNumSkillLines", count) or 0), 1, -1 do
			local line = r:call("C_SkillInfo.GetSkillLineInfo", info, i)
			if line and line.isHeader and line.isCollapsed then
				reopened[line.skillID] = true
				r:call("C_SkillInfo.ExpandSkillHeader", expand, i)
			end
		end
	end
	local list, header = {}, nil
	local total = r:call("C_SkillInfo.GetNumSkillLines", count) or 0
	for i = 1, total do
		local line = r:call("C_SkillInfo.GetSkillLineInfo", info, i)
		if line and line.isHeader then
			header = line.name
		elseif line then
			list[#list + 1] = {
				skill_id = line.skillID,
				name = line.name,
				header = header,
				category_id = line.skillLineCategoryID,
				rank = line.rank,
				max_rank = line.maxRank,
				modifier = line.modifier,
			}
		end
	end
	if collapse ~= nil and next(reopened) ~= nil then
		for i = total, 1, -1 do
			local line = r:call("C_SkillInfo.GetSkillLineInfo", info, i)
			if line and line.isHeader and reopened[line.skillID] then
				r:call("C_SkillInfo.CollapseSkillHeader", collapse, i)
			end
		end
	end
	return list
end

local function stats(r)
	local s = {}
	s.health_max = r:call("UnitHealthMax", UnitHealthMax, "player")
	local _, powerToken = r:call("UnitPowerType", UnitPowerType, "player")
	s.power = { type = powerToken, max = r:call("UnitPowerMax", UnitPowerMax, "player") }

	s.primary = Json.object()
	for index, name in ipairs(PRIMARY_STATS) do
		local base, total, positive, negative = r:call("UnitStat", UnitStat, "player", index)
		s.primary[name] = { base = base, total = total, positive = positive, negative = negative }
	end

	local armorBase, armorEffective, _, armorPositive, armorNegative = r:call("UnitArmor", UnitArmor, "player")
	s.armor = { base = armorBase, effective = armorEffective, positive = armorPositive, negative = armorNegative }
	s.resistances = Json.object()
	for index = 1, #RESISTANCE_SCHOOLS do
		local base, total, bonus, minus = r:call("UnitResistance", UnitResistance, "player", index)
		s.resistances[RESISTANCE_SCHOOLS[index]] = { base = base, total = total, bonus = bonus, minus = minus }
	end

	local defenseBase, defenseModifier = r:call("UnitDefenseSkill", UnitDefenseSkill, "player")
	s.defense = { base = defenseBase, modifier = defenseModifier }
	s.dodge = r:call("GetDodgeChance", GetDodgeChance)
	s.parry = r:call("GetParryChance", GetParryChance)
	s.block = r:call("GetBlockChance", GetBlockChance)
	s.block_value = r:call("GetShieldBlock", GetShieldBlock)

	local apBase, apPositive, apNegative = r:call("UnitAttackPower", UnitAttackPower, "player")
	s.attack_power = { base = apBase, positive = apPositive, negative = apNegative }
	local rapBase, rapPositive, rapNegative = r:call("UnitRangedAttackPower", UnitRangedAttackPower, "player")
	s.ranged_attack_power = { base = rapBase, positive = rapPositive, negative = rapNegative }

	local minMain, maxMain, minOff, maxOff, bonusPositive, bonusNegative, percent = r:call("UnitDamage", UnitDamage, "player")
	local speedMain, speedOff = r:call("UnitAttackSpeed", UnitAttackSpeed, "player")
	s.melee = {
		main_hand = { min = minMain, max = maxMain, speed = speedMain },
		off_hand = { min = minOff, max = maxOff, speed = speedOff },
		bonus_positive = bonusPositive,
		bonus_negative = bonusNegative,
		damage_percent = percent,
	}
	local rangedSpeed, rangedMin, rangedMax = r:call("UnitRangedDamage", UnitRangedDamage, "player")
	s.ranged = { min = rangedMin, max = rangedMax, speed = rangedSpeed }

	s.crit = r:call("GetCritChance", GetCritChance)
	s.ranged_crit = r:call("GetRangedCritChance", GetRangedCritChance)
	s.hit = r:call("GetHitModifier", GetHitModifier)
	s.ranged_hit = r:call("GetRangedHitModifier", GetRangedHitModifier)
	s.spell_hit = r:call("GetSpellHitModifier", GetSpellHitModifier)
	s.haste = r:call("GetHaste", GetHaste)
	s.melee_haste = r:call("GetMeleeHaste", GetMeleeHaste)
	s.ranged_haste = r:call("GetRangedHaste", GetRangedHaste)
	s.spell_haste = r:call("UnitSpellHaste", UnitSpellHaste, "player")
	local expertise, offhandExpertise, rangedExpertise = r:call("GetExpertise", GetExpertise)
	s.expertise = { main_hand = expertise, off_hand = offhandExpertise, ranged = rangedExpertise }
	s.armor_penetration = r:call("GetArmorPenetration", GetArmorPenetration)
	s.spell_penetration = r:call("GetSpellPenetration", GetSpellPenetration)

	s.spell_power = Json.object()
	s.spell_crit = Json.object()
	for index, school in pairs(SPELL_SCHOOLS) do
		s.spell_power[school] = r:call("GetSpellBonusDamage", GetSpellBonusDamage, index)
		s.spell_crit[school] = r:call("GetSpellCritChance", GetSpellCritChance, index)
	end
	s.healing_power = r:call("GetSpellBonusHealing", GetSpellBonusHealing)
	local regenBase, regenCasting = r:call("GetManaRegen", GetManaRegen)
	s.mana_regen = { base = regenBase, casting = regenCasting }
	local powerRegen, powerRegenCombat = r:call("GetPowerRegen", GetPowerRegen)
	s.power_regen = { inactive = powerRegen, active = powerRegenCombat }

	s.combat_ratings = {}
	s.combat_rating_bonuses = {}
	for index = 1, COMBAT_RATING_COUNT do
		s.combat_ratings[index] = r:call("GetCombatRating", GetCombatRating, index) or Json.null
		s.combat_rating_bonuses[index] = r:call("GetCombatRatingBonus", GetCombatRatingBonus, index) or Json.null
	end
	local overall, equipped = r:call("GetAverageItemLevel", GetAverageItemLevel)
	s.average_item_level = { overall = overall, equipped = equipped }
	return s
end

-- The armor formula, read from the client itself: damage reduction for a grid of armor values
-- against attackers of each level. This replaces an assumed formula with measured points.
local function armorSamples(r)
	local effectiveness = Safe.api("C_PaperDollInfo", "GetArmorEffectiveness")
	local samples = {}
	if effectiveness == nil then
		r:call("C_PaperDollInfo.GetArmorEffectiveness", nil)
		return samples
	end
	for _, level in ipairs(ATTACKER_LEVELS) do
		for _, armor in ipairs(ARMOR_SAMPLES) do
			local value = r:call("C_PaperDollInfo.GetArmorEffectiveness", effectiveness, armor, level)
			if value ~= nil then
				samples[#samples + 1] = { armor = armor, attacker_level = level, reduction = value }
			end
		end
	end
	return samples
end

local function spellBankPlayer()
	return Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
end

-- Known spells and their ranks, with what the client says they cost and do at this level. The
-- descriptions carry the numbers the ability data is missing above the levels it reaches.
local function spellbook(r)
	local lineCount = r:call("C_SpellBook.GetNumSpellBookSkillLines", Safe.api("C_SpellBook", "GetNumSpellBookSkillLines")) or 0
	local lineInfo = Safe.api("C_SpellBook", "GetSpellBookSkillLineInfo")
	local itemInfo = Safe.api("C_SpellBook", "GetSpellBookItemInfo")
	local spellInfo = Safe.api("C_Spell", "GetSpellInfo")
	local powerCost = Safe.api("C_Spell", "GetSpellPowerCost")
	local description = Safe.api("C_Spell", "GetSpellDescription")
	local bank = spellBankPlayer()
	local spells = {}
	for line = 1, lineCount do
		local tab = r:call("C_SpellBook.GetSpellBookSkillLineInfo", lineInfo, line)
		if tab and not tab.isGuild then
			for slot = tab.itemIndexOffset + 1, tab.itemIndexOffset + tab.numSpellBookItems do
				local item = r:call("C_SpellBook.GetSpellBookItemInfo", itemInfo, slot, bank)
				if item and item.spellID then
					local info = r:call("C_Spell.GetSpellInfo", spellInfo, item.spellID) or {}
					local costs = {}
					for _, cost in ipairs(r:call("C_Spell.GetSpellPowerCost", powerCost, item.spellID) or {}) do
						costs[#costs + 1] = {
							power = cost.name,
							cost = cost.cost,
							cost_percent = cost.costPercent,
							cost_per_second = cost.costPerSec,
						}
					end
					spells[#spells + 1] = {
						spell_id = item.spellID,
						name = item.name,
						rank = item.subName,
						tab = tab.name,
						passive = item.isPassive,
						cast_time_ms = info.castTime,
						min_range = info.minRange,
						max_range = info.maxRange,
						costs = costs,
						description = Character.plainText(r:call("C_Spell.GetSpellDescription", description, item.spellID)),
					}
				end
			end
		end
	end
	return spells
end

-- Remove the client's escape sequences (|cAARRGGBB colour, |r reset) so text reads the same
-- in the file as in the copy window, where the edit box renders them away.
function Character.plainText(text)
	if type(text) ~= "string" then
		return text
	end
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Spell descriptions load on demand. Ask for all of them before the snapshot is read.
function Character.requestSpellData()
	local request = Safe.api("C_Spell", "RequestLoadSpellData")
	local r = Safe.report()
	local lineCount = r:call("lines", Safe.api("C_SpellBook", "GetNumSpellBookSkillLines")) or 0
	for line = 1, lineCount do
		local tab = r:call("line", Safe.api("C_SpellBook", "GetSpellBookSkillLineInfo"), line)
		if tab then
			for slot = tab.itemIndexOffset + 1, tab.itemIndexOffset + tab.numSpellBookItems do
				local item = r:call("item", Safe.api("C_SpellBook", "GetSpellBookItemInfo"), slot, spellBankPlayer())
				if item and item.spellID then
					r:call("request", request, item.spellID)
				end
			end
		end
	end
end

local function auras(r)
	local list = {}
	local get = Safe.api("C_UnitAuras", "GetAuraDataByIndex")
	for index = 1, MAX_AURAS do
		local aura = r:call("C_UnitAuras.GetAuraDataByIndex", get, "player", index, "HELPFUL")
		if aura == nil then
			break
		end
		list[#list + 1] = {
			spell_id = aura.spellId,
			name = aura.name,
			stacks = aura.applications,
			duration = aura.duration,
			values = aura.points,
		}
	end
	return list
end

local function client(r)
	local version, build, buildDate, interface = r:call("GetBuildInfo", GetBuildInfo)
	return {
		version = version,
		build = build,
		build_date = buildDate,
		interface = interface,
		locale = r:call("GetLocale", GetLocale),
		region = r:call("GetCurrentRegion", GetCurrentRegion),
	}
end

-- Customization choices are only readable while the barber shop is open; Core stores them then.
function Character.readAppearance()
	local r = Safe.report()
	local categories = r:call("C_BarberShop.GetAvailableCustomizations", Safe.api("C_BarberShop", "GetAvailableCustomizations"))
	if type(categories) ~= "table" then
		return nil
	end
	local choices = {}
	for _, category in ipairs(categories) do
		for _, option in ipairs(category.options or {}) do
			local choice = option.choices and option.currentChoiceIndex and option.choices[option.currentChoiceIndex]
			if choice ~= nil then
				choices[#choices + 1] = { option_id = option.id, choice_id = choice.id }
			end
		end
	end
	return choices
end

-- Returns the snapshot table, or nil and a reason when it cannot be read now.
function Character.snapshot(appearance)
	if InCombatLockdown and InCombatLockdown() then
		return nil, "in_combat"
	end
	local r = Safe.report()
	local snapshot = {
		format = ns.SNAPSHOT_FORMAT,
		addon_version = ns.VERSION,
		captured_at = time and time() or nil,
		client = client(r),
		character = identity(r),
		equipment = equipment(r),
		talents = talents(r),
		professions = professions(r),
		skills = skills(r),
		stats = stats(r),
		spells = spellbook(r),
		auras = auras(r),
		appearance = appearance,
		client_rules = { armor_effectiveness = armorSamples(r) },
	}
	snapshot.gaps = r:gapList()
	return snapshot
end
