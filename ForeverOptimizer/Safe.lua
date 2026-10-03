-- Secret-safe access to the game API.
--
-- WoW Forever runs the Midnight (12.x) addon API: many functions return "secret values" that an
-- addon may hold but not read, compare or do arithmetic on, and that raise an error if it tries.
-- Which values are secret depends on the unit and on the restriction state (combat, encounter,
-- restricted map). Every read in this addon goes through a Report so that:
--   * a missing function, an error or a secret value never breaks the addon, and
--   * the payload says which values the client withheld ("gaps"), so we learn what this client
--     allows from real snapshots instead of guessing.

local _, ns = ...

local Safe = {}
ns.Safe = Safe

local MAX_DEPTH = 8

local function pack(...)
	return { n = select("#", ...), ... }
end

-- issecretvalue and issecrettable do not exist on clients without secret values.
function Safe.isSecret(value)
	local check = _G.issecretvalue
	if check ~= nil and check(value) then
		return true
	end
	if type(value) == "table" then
		local checkTable = _G.issecrettable
		return checkTable ~= nil and checkTable(value) or false
	end
	return false
end

-- Copy a value with every secret replaced by nil. Functions and userdata are dropped.
-- Returns the copy and whether anything was secret.
function Safe.scrub(value, depth)
	depth = depth or 0
	if Safe.isSecret(value) then
		return nil, true
	end
	local kind = type(value)
	if kind == "function" or kind == "userdata" or kind == "thread" then
		return nil, false
	end
	if kind ~= "table" then
		return value, false
	end
	if depth >= MAX_DEPTH then
		return nil, false
	end
	local copy, anySecret = {}, false
	for key, item in pairs(value) do
		if not Safe.isSecret(key) then
			local clean, secret = Safe.scrub(item, depth + 1)
			copy[key] = clean
			anySecret = anySecret or secret
		else
			anySecret = true
		end
	end
	return copy, anySecret
end

-- Look up C_Namespace.Function without erroring when the namespace is absent.
function Safe.api(namespace, name)
	local container = _G[namespace]
	if type(container) ~= "table" then
		return nil
	end
	local fn = container[name]
	return type(fn) == "function" and fn or nil
end

local Report = {}
Report.__index = Report

function Safe.report()
	return setmetatable({ gaps = {} }, Report)
end

-- Call fn(...) and return its results with secrets removed. The outcome for `label` is noted in
-- the report's gaps: "missing" (no such function), "error" (it raised) or "secret" (a returned
-- value was withheld). A label that is never noted was read in full.
function Report:call(label, fn, ...)
	if type(fn) ~= "function" then
		self.gaps[label] = "missing"
		return nil
	end
	local results = pack(pcall(fn, ...))
	if not results[1] then
		self.gaps[label] = "error"
		return nil
	end
	local anySecret = false
	for i = 2, results.n do
		local clean, secret = Safe.scrub(results[i])
		results[i] = clean
		anySecret = anySecret or secret
	end
	if anySecret then
		self.gaps[label] = "secret"
	end
	return unpack(results, 2, results.n)
end

-- For in-game checks: call fn(...) and describe each returned value without reading secrets.
-- Returns { status = "ok" | "missing" | "error", values = { "plain" | "secret" | "nil", ... },
-- sample = first plain value } so a tester can see exactly what the client withholds.
function Safe.probe(fn, ...)
	if type(fn) ~= "function" then
		return { status = "missing", values = {} }
	end
	local results = pack(pcall(fn, ...))
	if not results[1] then
		return { status = "error", values = {}, error = tostring(results[2]) }
	end
	local probe = { status = "ok", values = {} }
	for i = 2, results.n do
		local value = results[i]
		if Safe.isSecret(value) then
			probe.values[i - 1] = "secret"
		elseif value == nil then
			probe.values[i - 1] = "nil"
		else
			probe.values[i - 1] = "plain"
			if probe.sample == nil and type(value) ~= "table" and type(value) ~= "function" then
				probe.sample = value
			end
		end
	end
	return probe
end

-- A JSON-friendly list of the gaps, sorted for a stable payload.
function Report:gapList()
	local list = {}
	for label, reason in pairs(self.gaps) do
		list[#list + 1] = { field = label, reason = reason }
	end
	table.sort(list, function(a, b)
		return a.field < b.field
	end)
	return list
end
