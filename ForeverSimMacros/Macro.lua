-- A macro's text from what the player picked, checked against the game's macro rules
-- (Reference.lua), and what it does in plain words. The same rules and the same words as the
-- website's macro maker (backend/apps/macros/services.py): tests run both on the same cases.
--
-- A macro here is { showTooltip, showArgument, lines = { { command, reset = { ... },
-- clauses = { { unit, argument, conditions = { { name, negate, values = { ... } } } } } } } }.
-- The addon only writes the text: the player copies it into the game's macro window.

local _, ns = ...

local Macro = {}
ns.Macro = Macro

local function trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function byName(kind)
	local found = {}
	for _, entry in ipairs(ns.Reference[kind]) do
		found[entry.name] = entry
		for _, alias in ipairs(entry.aliases or {}) do
			found[alias] = entry
		end
	end
	return found
end

local function contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then
			return true
		end
	end
	return false
end

local function hasAny(text, characters)
	for index = 1, #characters do
		if text:find(characters:sub(index, index), 1, true) then
			return true
		end
	end
	return false
end

-- A unit token split into its base, its number and how many "target"s follow.
local function splitUnit(unit)
	local token = trim(unit):lower()
	local targets = 0
	while #token > 6 and token:sub(-6) == "target" do
		token = token:sub(1, -7)
		targets = targets + 1
	end
	local base, number = token:match("^(%a+)(%d*)$")
	return base, number, targets
end

local function units()
	local found = {}
	for _, entry in ipairs(ns.Reference.units) do
		found[entry.token] = entry
	end
	return found
end

-- Why `unit` is not a target a macro can name, or nil when it is one.
function Macro.unitProblem(unit)
	local token = trim(unit):lower()
	if token == "cursor" then
		return nil
	end
	local base, number, targets = splitUnit(unit)
	if base == nil then
		return "@" .. unit .. " is not a unit the game knows."
	end
	if contains(ns.Reference.not_targetable, base) then
		return "@" .. unit .. ": nameplates cannot be targeted by macros."
	end
	local entry = units()[base]
	if entry == nil then
		return "@" .. unit .. " is not a unit the game knows."
	end
	if entry.range then
		local low, high = entry.range[1], entry.range[2]
		local n = tonumber(number)
		if n == nil or n < low or n > high then
			return string.format("@%s: %s goes from %s%d to %s%d.", unit, base, base, low, base, high)
		end
	elseif number ~= "" then
		return "@" .. unit .. " is not a unit the game knows."
	end
	if (base == "cursor" or base == "none") and targets > 0 then
		return "@" .. unit .. " has no target to follow."
	end
	return nil
end

local function unitWords(unit)
	local base, number, targets = splitUnit(unit)
	local entry = base and units()[base]
	if entry == nil then
		return unit
	end
	local words = entry.summary
	if number ~= "" then
		words = words .. " " .. number
	end
	for _ = 1, targets do
		words = "the target of " .. words
	end
	return words
end

local function cleanValues(values)
	local kept = {}
	for _, value in ipairs(values or {}) do
		if trim(value) ~= "" then
			kept[#kept + 1] = trim(value)
		end
	end
	return kept
end

local function conditionText(condition)
	local entry = byName("conditions")[condition.name] or { name = condition.name }
	local text = (condition.negate and "no" or "") .. entry.name
	local values = {}
	for _, value in ipairs(condition.values or {}) do
		values[#values + 1] = trim(value)
	end
	if #values > 0 then
		text = text .. ":" .. table.concat(values, "/")
	end
	return text
end

local function problem(list, severity, message)
	list[#list + 1] = { severity = severity, message = message }
end

local function conditionProblems(condition, problems)
	local entry = byName("conditions")[condition.name]
	if entry == nil then
		problem(problems, "error", "[" .. tostring(condition.name) .. "] is not a condition the game knows.")
		return
	end
	local values = cleanValues(condition.values)
	local kind = entry.argument
	if kind == "none" and #values > 0 then
		problem(problems, "error", "[" .. entry.name .. "] takes no value.")
	end
	if kind ~= "none" and #values == 0 and not entry.optional_values then
		problem(problems, "error", "[" .. entry.name .. "] needs a value.")
	end
	if kind == "numbers" then
		for _, value in ipairs(values) do
			if not value:match("^%d+$") then
				problem(problems, "error", "[" .. entry.name .. "] takes numbers, like 1/2.")
				break
			end
		end
	end
	if entry.values and #entry.values > 0 and kind == "keys" then
		for _, value in ipairs(values) do
			if not contains(entry.values, value:lower()) then
				problem(problems, "error", "[" .. entry.name .. "] takes " .. table.concat(entry.values, ", ") .. ".")
				break
			end
		end
	end
	for _, value in ipairs(values) do
		if hasAny(value, "[];,/") then
			problem(problems, "error", "A value of [" .. entry.name .. "] cannot hold [ ] ; , or /.")
			break
		end
	end
	if entry.unconfirmed then
		problem(problems, "warning", entry.unconfirmed)
	end
end

local function conditionWords(condition)
	local entry = byName("conditions")[condition.name]
	local words = entry.summary
	if condition.values and #condition.values > 0 then
		words = words .. " (" .. table.concat(condition.values, " or ") .. ")"
	end
	return condition.negate and ("not: " .. words) or words
end

local function clauseText(clause, argument)
	local parts = {}
	if trim(clause.unit) ~= "" then
		parts[#parts + 1] = "@" .. trim(clause.unit):lower()
	end
	for _, condition in ipairs(clause.conditions or {}) do
		parts[#parts + 1] = conditionText(condition)
	end
	local brackets = #parts > 0 and ("[" .. table.concat(parts, ",") .. "]") or ""
	argument = trim(argument == nil and clause.argument or argument)
	if brackets == "" then
		return argument
	end
	return trim(brackets .. " " .. argument)
end

local function lineProblems(line, command, problems)
	local name = command.name
	if #line.clauses == 0 then
		line.clauses = { { unit = "", argument = "", conditions = {} } }
	end
	if not command.conditions then
		local some = #line.clauses > 1
		for _, clause in ipairs(line.clauses) do
			some = some or #(clause.conditions or {}) > 0 or trim(clause.unit) ~= ""
		end
		if some then
			problem(problems, "error", "/" .. name .. " takes no conditions: the game would ignore them.")
		end
	end
	for index, clause in ipairs(line.clauses) do
		clause.conditions = clause.conditions or {}
		local argument = trim(clause.argument)
		if command.required and argument == "" then
			problem(problems, "error", string.format("/%s needs a %s (part %d).", name, command.argument, index))
		end
		if command.argument == "none" and argument ~= "" then
			problem(problems, "error", "/" .. name .. " takes nothing after it.")
		end
		if hasAny(argument, "[];\n") then
			problem(problems, "error", "/" .. name .. ": what it acts on cannot hold [ ] ; or a new line.")
		end
		if trim(clause.unit) ~= "" then
			local why = Macro.unitProblem(clause.unit)
			if why then
				problem(problems, "error", why)
			end
		end
		for _, condition in ipairs(clause.conditions) do
			conditionProblems(condition, problems)
		end
		if #clause.conditions == 0 and trim(clause.unit) == "" and index < #line.clauses then
			problem(problems, "warning", string.format(
				"/%s: part %d has no condition, so the parts after it are never reached.", name, index))
		end
	end
	local reset = line.reset or {}
	if name == "castsequence" then
		local resets = ns.Reference.castsequence_resets
		for _, value in ipairs(reset) do
			if not (value:match("^%d%d?%d?%d?$") or contains(resets, value)) then
				problem(problems, "error", "reset=" .. value .. ": use seconds, or " .. table.concat(resets, "/") .. ".")
			end
		end
	elseif #reset > 0 then
		problem(problems, "error", "reset= is only for /castsequence.")
	end
end

local function lineText(line, command)
	local name = command.name
	local reset = line.reset or {}
	local parts = {}
	for _, clause in ipairs(line.clauses) do
		if name == "castsequence" and #reset > 0 then
			local head = clauseText(clause, "")
			local body = "reset=" .. table.concat(reset, "/") .. " " .. trim(clause.argument)
			parts[#parts + 1] = trim(head .. " " .. body)
		else
			parts[#parts + 1] = clauseText(clause)
		end
	end
	return (("/" .. name .. " " .. table.concat(parts, "; ")):gsub("%s+$", ""))
end

local function lineWords(line, command)
	local known = byName("conditions")
	local parts = {}
	for _, clause in ipairs(line.clauses) do
		local conditions = {}
		for _, condition in ipairs(clause.conditions or {}) do
			if known[condition.name] then
				conditions[#conditions + 1] = conditionWords(condition)
			end
		end
		local what = trim("/" .. command.name .. " " .. trim(clause.argument))
		if trim(clause.unit) ~= "" then
			what = what .. " on " .. unitWords(clause.unit)
		end
		if #conditions > 0 then
			parts[#parts + 1] = "if " .. table.concat(conditions, " and ") .. ": " .. what
		else
			parts[#parts + 1] = what
		end
	end
	return table.concat(parts, "; otherwise ")
end

-- { text, length, maxLength, problems = { { severity, message } }, explanation = { ... } }
function Macro.build(macro)
	local commands = byName("commands")
	local problems, texts, words = {}, {}, {}
	if macro.showTooltip then
		texts[#texts + 1] = (("#showtooltip " .. trim(macro.showArgument)):gsub("%s+$", ""))
		words[#words + 1] = "Its icon and tooltip follow the spell or item it would use now."
	end
	local once, onceOrder = {}, {}
	local lines = macro.lines or {}
	for number, line in ipairs(lines) do
		line.clauses = line.clauses or {}
		local command = commands[trim(line.command):lower():gsub("^/", "")]
		if command == nil then
			problem(problems, "error", string.format("Line %d: /%s is not a macro command.", number, tostring(line.command)))
		else
			lineProblems(line, command, problems)
			if command.summary:sub(-#"Only once per macro.") == "Only once per macro." then
				if once[command.name] == nil then
					onceOrder[#onceOrder + 1] = command.name
				end
				once[command.name] = (once[command.name] or 0) + 1
			end
			texts[#texts + 1] = lineText(line, command)
			words[#words + 1] = lineWords(line, command)
		end
	end
	for _, name in ipairs(onceOrder) do
		if once[name] > 1 then
			problem(problems, "error", "/" .. name .. " works only once per macro.")
		end
	end
	if #lines == 0 then
		problem(problems, "error", "A macro needs at least one line.")
	end
	local text = table.concat(texts, "\n")
	local limit = ns.Reference.max_length
	if #text > limit then
		problem(problems, "error", string.format("%d characters: the game keeps only %d in a macro.", #text, limit))
	end
	return { text = text, length = #text, maxLength = limit, problems = problems, explanation = words }
end
