-- The player's settings, kept in the saved file under `settings`, with their defaults. The
-- control panel (Panel.lua) changes them; whatever shows them listens for changes.

local _, ns = ...

local Options = {}
ns.Options = Options

Options.DEFAULTS = {
	threat = {
		-- "auto": shown in a fight when in a group; "on": in every fight; "off": never.
		mode = "auto",
		-- "auto": the role the group gave the player; or "tank", "damage", "healer".
		role = "auto",
		scale = 1.0,
		width = 260,
		rows = 10,
		-- Pixels per row (14 to 32).
		rowHeight = 18,
		-- Threat bars behind the rows, and the current target in large print above them.
		bars = true,
		focus = true,
		-- Background darkness, 0 (none) to 1.
		opacity = 0.6,
		locked = false,
		-- The warning in the middle of the screen, and its sound, when an enemy turns away.
		alert = true,
		sound = true,
		-- Mark the nameplate of an enemy that is not on the player.
		markers = true,
		-- Where the window is: { point, relativePoint, x, y }; nil: its first place.
		position = nil,
	},
}

local listeners = {}

local function copyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			target[key] = type(target[key]) == "table" and target[key] or {}
			copyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

-- Fill in what the saved file lacks. Addon 0.3.0 kept the threat window's mode as `threat`.
function Options.load(store)
	store.settings = type(store.settings) == "table" and store.settings or {}
	if type(store.threat) == "string" then
		store.settings.threat = store.settings.threat or {}
		store.settings.threat.mode = store.settings.threat.mode or store.threat
		store.threat = nil
	end
	copyDefaults(store.settings, Options.DEFAULTS)
end

local function split(path)
	local section, name = path:match("^(%w+)%.(%w+)$")
	return section, name
end

function Options.get(path)
	local section, name = split(path)
	local settings = ns.db and ns.db.settings
	local values = settings and settings[section]
	if values ~= nil and values[name] ~= nil then
		return values[name]
	end
	return Options.DEFAULTS[section] and Options.DEFAULTS[section][name]
end

function Options.set(path, value)
	local section, name = split(path)
	if ns.db == nil or Options.DEFAULTS[section] == nil then
		return
	end
	ns.db.settings[section][name] = value
	for _, listener in ipairs(listeners[section] or {}) do
		pcall(listener, name, value)
	end
end

-- Back to the defaults for one section ("threat").
function Options.reset(section)
	if ns.db == nil or Options.DEFAULTS[section] == nil then
		return
	end
	ns.db.settings[section] = {}
	copyDefaults(ns.db.settings[section], Options.DEFAULTS[section])
	for _, listener in ipairs(listeners[section] or {}) do
		pcall(listener, nil, nil)
	end
end

function Options.listen(section, listener)
	listeners[section] = listeners[section] or {}
	table.insert(listeners[section], listener)
end
