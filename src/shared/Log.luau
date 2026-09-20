--!strict
--[[
	Tagged, level-filtered logging.

	Once there are a dozen services, unattributed prints are noise. A tag per
	module plus a runtime filter means you can silence everything except the
	subsystem you're debugging, from the command bar, with no edits.

		local log = Log.new("UIController")
		log.info(`registered {count} screens`)
]]

local RunService = game:GetService("RunService")

export type Level = "debug" | "info" | "warn" | "error"

export type Logger = {
	debug: (message: string) -> (),
	info: (message: string) -> (),
	warn: (message: string) -> (),
	error: (message: string) -> (),
}

local LEVEL_ORDER: { [Level]: number } = {
	debug = 10,
	info = 20,
	warn = 30,
	error = 40,
}

local CONTEXT = if RunService:IsServer() then "S" else "C"

local Log = {}

-- Verbose in Studio, quiet in production.
local minLevel: Level = if RunService:IsStudio() then "debug" else "info"

-- nil = every tag enabled. Set a whitelist to silence everything else.
local tagFilter: { [string]: boolean }? = nil

local function shouldEmit(level: Level, tag: string): boolean
	if LEVEL_ORDER[level] < LEVEL_ORDER[minLevel] then
		return false
	end
	if tagFilter ~= nil and tagFilter[tag] ~= true then
		-- Errors ignore the tag filter; you always want to see those.
		return LEVEL_ORDER[level] >= LEVEL_ORDER.error
	end
	return true
end

local function emit(level: Level, tag: string, message: string)
	if not shouldEmit(level, tag) then
		return
	end

	local line = `[{CONTEXT}][{tag}] {message}`

	-- warn() routes to stderr: yellow in Studio, and captured by Roblox's
	-- error analytics in production. Never print() a problem.
	if LEVEL_ORDER[level] >= LEVEL_ORDER.warn then
		warn(line)
	else
		print(line)
	end
end

function Log.new(tag: string): Logger
	return {
		debug = function(message: string)
			emit("debug", tag, message)
		end,
		info = function(message: string)
			emit("info", tag, message)
		end,
		warn = function(message: string)
			emit("warn", tag, message)
		end,
		error = function(message: string)
			emit("error", tag, message)
		end,
	}
end

--[[
	Runtime tuning, callable from the Studio command bar mid-session:
		require(game.ReplicatedStorage.Shared.Log).setMinLevel("debug")
		require(game.ReplicatedStorage.Shared.Log).filterTags({ UIController = true })
]]
function Log.setMinLevel(level: Level)
	minLevel = level
end

function Log.filterTags(tags: { [string]: boolean }?)
	tagFilter = tags
end

return Log
