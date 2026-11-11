-- Minimal, deterministic JSON encoder (the game client has no JSON library for addons).
--
-- Tables whose keys are exactly 1..n encode as arrays; everything else as objects with keys
-- sorted, so the same data always gives the same text. An empty table encodes as [] unless it
-- was created with Json.object().

local _, ns = ...

local Json = {}
ns.Json = Json

local OBJECT = {}

-- Encodes as null; use it to keep a position in an array where the value is unknown.
Json.null = setmetatable({}, { __metatable = "null" })

function Json.object(values)
	return setmetatable(values or {}, OBJECT)
end

local ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(value)
	return '"' .. value:gsub('[%c"\\]', function(char)
		return ESCAPES[char] or string.format("\\u%04x", char:byte())
	end) .. '"'
end

local function encodeNumber(value)
	-- NaN and infinities have no JSON form.
	if value ~= value or value == math.huge or value == -math.huge then
		return "null"
	end
	if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
		-- Not %d: the client refuses it for whole numbers beyond 32 bits.
		return string.format("%.0f", value)
	end
	return string.format("%.14g", value)
end

local function isArray(value)
	if getmetatable(value) == OBJECT then
		return false
	end
	local count = 0
	for _ in pairs(value) do
		count = count + 1
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true
end

local encode

local function encodeTable(value, seen)
	if seen[value] then
		error("Json.encode: cyclic table")
	end
	seen[value] = true
	local parts = {}
	if isArray(value) then
		for i = 1, #value do
			parts[i] = encode(value[i], seen)
		end
		seen[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in pairs(value) do
		local kind = type(key)
		if kind == "string" or kind == "number" then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for i, key in ipairs(keys) do
		parts[i] = encodeString(tostring(key)) .. ":" .. encode(value[key], seen)
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

encode = function(value, seen)
	local kind = type(value)
	if kind == "nil" or value == Json.null then
		return "null"
	elseif kind == "boolean" then
		return value and "true" or "false"
	elseif kind == "number" then
		return encodeNumber(value)
	elseif kind == "string" then
		return encodeString(value)
	elseif kind == "table" then
		return encodeTable(value, seen)
	end
	return "null"
end

function Json.encode(value)
	return encode(value, {})
end
