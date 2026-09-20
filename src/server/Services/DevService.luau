--!strict
--[[
	Server authority for the developer console (the `developers` config below
	decides who, Controllers/DevConsoleController is the UI). Every mutation a developer
	makes goes through DataService.set -- the exact same write path a normal
	gameplay service uses -- so a dev edit persists, replicates, and can never
	touch profile.Data directly or produce a shape Replica can't send.

	Non-obvious tradeoffs:

	* The rate limit runs BEFORE the rank check, and before any logging. An
	  exploiter with no rank at all can still spam this packet, and the only
	  safe response to a flood from an unauthorised sender is to drop it with
	  no work done -- logging every drop would just move the DoS from the game
	  onto the output panel (or whatever ships logs to analytics).

	* Values cross the wire as a string plus a `kind` tag (see Net.luau) rather
	  than as live Luau values, so every write this service performs is
	  reconstructed from primitives it parsed and bounds-checked itself. There
	  is no path from a client packet straight into DataService.set.

	* Path keys are strings only, always. A dev console is exactly the kind of
	  tool that would otherwise let someone type `Inventory.5` into a text box
	  and end up with a numeric-keyed table with a gap in it, which Replica
	  cannot replicate (see ARCHITECTURE.md's Data section) -- a permanently
	  broken profile. Refusing that shape here is cheaper than ever debugging it.
]]

local ConfigService = game:GetService("ConfigService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("DevService")

--[[
	WHO is a developer now lives in the Creator Dashboard, not in this codebase.

	Configs page -> key `developers`, type JSON object:
		{ "userIds": [123, 456] }

	Add a UserId there and they have the console within seconds -- no code change,
	no republish. That is the entire reason this reads ConfigService rather than a
	hardcoded list.

	This replaced a group-rank check, and deliberately so. There is no IsStudio()
	bypass: Studio reads the STAGED value of the config, so Studio tests the same
	code path that ships. The old ALLOW_IN_STUDIO short-circuit is exactly what let
	a broken live gate look healthy in Studio for as long as it did.

	ConfigService is SERVER-ONLY -- "Attempting to call its methods from a client
	script results in an error" -- which is why the client is TOLD its status over
	Net.devAccess instead of computing it. That is not a weakening: authority was
	never the client's to hold, and checkAccess below still re-checks every packet.

	GetConfigAsync YIELDS and THROWS if the config has never loaded, so it lives in
	Start(), never Init() (the Loader hard-errors on a yielding Init). Every failure
	path leaves developerIds empty, which denies everyone -- fail closed, same as the
	old code did on a group-API blip.
]]
local DEVELOPERS_CONFIG_KEY = "developers"

local MAX_PATH_DEPTH = 6
local MAX_KEY_LENGTH = 64
local MAX_STRING_VALUE_LENGTH = 256
local MIN_COMMAND_INTERVAL = 0.1
local WARN_THROTTLE = 5

type SnapshotEntry = {
	path: { string },
	kind: string,
	value: string,
}

local lastCommandAt: { [Player]: number } = {}
local lastWarnAt: { [Player]: number } = {}

-- A set, not an array: checkAccess runs this lookup on EVERY packet, so a linear
-- scan of the list would be on the hot path. Empty until the config loads, and
-- empty means nobody is a developer -- that is the fail-closed default, and every
-- error path below deliberately leaves it that way.
local developerIds: { [number]: true } = {}

--[[
	Roblox does not document whether GetValue() on a JSON-object config hands back
	a decoded table or the raw JSON string -- the reference says only "Variant",
	and this could not be tested against a live Studio session. So both shapes are
	accepted. This is not defensive clutter; it is an undocumented API boundary,
	and guessing wrong would silently deny every developer with no error to read.
]]
local function decodeDevelopers(raw: any): { [number]: true }
	local ids: { [number]: true } = {}

	local decoded: any = raw
	if type(raw) == "string" then
		-- JSONDecode throws on malformed input.
		local ok, result = pcall(HttpService.JSONDecode, HttpService, raw)
		if not ok then
			log.warn(`config "{DEVELOPERS_CONFIG_KEY}" is not valid JSON -- nobody has console access`)
			return ids
		end
		decoded = result
	end

	if type(decoded) ~= "table" or type(decoded.userIds) ~= "table" then
		log.warn(`config "{DEVELOPERS_CONFIG_KEY}" is missing a userIds array -- nobody has console access`)
		return ids
	end

	for _, id in decoded.userIds do
		-- NaN defeats a range check (it fails every comparison), so it is rejected
		-- explicitly rather than left to `id > 0` -- quality-gate.md trap #8.
		if type(id) == "number" and id == id and id % 1 == 0 and id > 0 then
			ids[id] = true
		end
	end

	return ids
end

local function isDeveloper(player: Player): boolean
	return developerIds[player.UserId] == true
end

local function publishAccess(player: Player)
	Net.devAccess.sendTo({ allowed = isDeveloper(player) }, player)
end

local function withKey(prefix: { string }, key: string): { string }
	local path: { string } = {}
	for _, segment in prefix do
		table.insert(path, segment)
	end
	table.insert(path, key)
	return path
end

-- Walks a dotted path into the live tree. `data` is deliberately untyped --
-- this walks whatever shape PlayerData happens to be, same as DataService.set
-- treats `value: any` for the same reason.
local function readPath(data: any, path: { string }): any
	local current: any = data
	for _, key in path do
		if type(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

--[[
	Keys are strings ONLY -- numeric keys are deliberately unsupported. This
	function never coerces a key with tonumber, and that omission is the
	point: it's what stops a text box from ever writing a real numeric index
	into a table that started empty, which is exactly how a numeric table
	ends up with a gap (see the top comment).
]]
local function validatePath(data: any, path: { string }): boolean
	if #path < 1 or #path > MAX_PATH_DEPTH then
		return false
	end

	for _, key in path do
		if key == "" or #key > MAX_KEY_LENGTH then
			return false
		end
	end

	if type(data) ~= "table" or data[path[1]] == nil then
		-- path[1] must already be a key the template backfilled -- a dev can't
		-- invent a top-level field the template has never heard of.
		return false
	end

	local current: any = data
	for i = 1, #path - 1 do
		current = current[path[i]]
		if type(current) ~= "table" then
			return false
		end
	end

	return true
end

--[[
	kind + raw wire string -> a real Luau scalar, or rejection.

	NaN defeats a naive range check (n < 0 or n > MAX passes for 0/0), so it's
	rejected explicitly -- quality-gate.md trap #8. math.huge is rejected too:
	DataService.set would happily replicate it, and there is no sane save/load
	round trip for an infinite Coins.
]]
local function parseValue(kind: string, raw: string): (boolean, any)
	if kind == "number" then
		local value = tonumber(raw)
		if value == nil or value ~= value or value == math.huge or value == -math.huge then
			return false, nil
		end
		return true, value
	elseif kind == "boolean" then
		if raw == "true" then
			return true, true
		elseif raw == "false" then
			return true, false
		end
		return false, nil
	elseif kind == "string" then
		if #raw > MAX_STRING_VALUE_LENGTH then
			return false, nil
		end
		return true, raw
	end
	return false, nil
end

--[[
	If the path already holds a value, the new one must be the SAME Luau type.
	A table there means "pick a field inside it" -- overwriting a container
	would silently delete every sibling under it. Nothing at the path yet is
	allowed through: that's the "give myself anything" path, e.g. setting
	Inventory.Sword for the first time.
]]
local function typeMatches(existing: any, kind: string): boolean
	if existing == nil then
		return true
	end
	if typeof(existing) == "table" then
		return false
	end
	return typeof(existing) == kind
end

-- Flattens live player data into {path, kind, value} leaves for the console.
-- Tables recurse, scalars terminate, everything else (there is nothing else
-- in TEMPLATE today) is silently skipped rather than sent as a leaf the
-- console couldn't parse back anyway.
local function collectEntries(node: any, prefix: { string }, entries: { SnapshotEntry })
	for key, value in node do
		local path = withKey(prefix, key)
		local kind = typeof(value)

		if kind == "table" and #path < MAX_PATH_DEPTH then
			collectEntries(value, path, entries)
		elseif kind == "number" or kind == "boolean" or kind == "string" then
			table.insert(entries, { path = path, kind = kind :: string, value = tostring(value) })
		end
	end
end

local function sendSnapshot(target: Player, caller: Player)
	local data = DataService.getData(target)
	if data == nil then
		Net.devResult.sendTo({ ok = false, message = "target has no loaded data" }, caller)
		return
	end

	local entries: { SnapshotEntry } = {}
	collectEntries(data, {}, entries)

	-- Sorted so the console's row order is stable between refreshes instead
	-- of reshuffling under whatever a dict happens to iterate in.
	table.sort(entries, function(a, b)
		return table.concat(a.path, ".") < table.concat(b.path, ".")
	end)

	Net.devSnapshot.sendTo({ targetUserId = target.UserId, entries = entries }, caller)
end

--[[
	Rate limit FIRST, before any logging or the rank check -- see the top
	comment. Only once that passes do we spend a rank lookup and, on failure,
	a throttled warn plus a reply.
]]
local function checkAccess(player: Player): boolean
	local now = os.clock()
	local last = lastCommandAt[player]
	if last ~= nil and now - last < MIN_COMMAND_INTERVAL then
		return false
	end
	lastCommandAt[player] = now

	if isDeveloper(player) then
		return true
	end

	local lastWarn = lastWarnAt[player]
	if lastWarn == nil or now - lastWarn >= WARN_THROTTLE then
		lastWarnAt[player] = now
		log.warn(`{player.Name} ({player.UserId}) sent a dev command without being on the developers list -- denied`)
	end
	Net.devResult.sendTo({ ok = false, message = "not authorised" }, player)
	return false
end

-- Reading another player's data is privileged too, so this goes through the
-- same gate every other lookup does -- it just also has to resolve the
-- target from an untrusted UserId first.
local function resolveTarget(targetUserId: number, caller: Player): Player?
	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil then
		Net.devResult.sendTo({ ok = false, message = "target is not in this server" }, caller)
	end
	return target
end

local function onPlayerRemoving(player: Player)
	lastCommandAt[player] = nil
	lastWarnAt[player] = nil
end

local function onRequestSnapshot(data: { targetUserId: number }, player: Player)
	if not checkAccess(player) then
		return
	end

	local target = resolveTarget(data.targetUserId, player)
	if target == nil then
		return
	end

	sendSnapshot(target, player)
end

local function onSet(data: { targetUserId: number, path: { string }, kind: string, value: string }, player: Player)
	if not checkAccess(player) then
		return
	end

	local target = resolveTarget(data.targetUserId, player)
	if target == nil then
		return
	end

	local targetData = DataService.getData(target)
	if targetData == nil then
		Net.devResult.sendTo({ ok = false, message = "target has no loaded data" }, player)
		return
	end

	if not validatePath(targetData, data.path) then
		Net.devResult.sendTo({ ok = false, message = "invalid path" }, player)
		return
	end

	local parsed, value = parseValue(data.kind, data.value)
	if not parsed then
		Net.devResult.sendTo({ ok = false, message = "invalid value" }, player)
		return
	end

	local existing = readPath(targetData, data.path)
	if not typeMatches(existing, data.kind) then
		local message = if typeof(existing) == "table"
			then "that's a container -- pick a field inside it"
			else "type mismatch"
		Net.devResult.sendTo({ ok = false, message = message }, player)
		return
	end

	DataService.set(target, data.path :: { string | number }, value)

	-- A god-mode console must leave an audit trail: who, whose data, what.
	log.info(`{player.Name} set {target.Name}.{table.concat(data.path, ".")} = {data.value}`)

	Net.devResult.sendTo({ ok = true, message = `{table.concat(data.path, ".")} set` }, player)
	sendSnapshot(target, player)
end

local DevService = {}

function DevService.Init()
	Net.devRequestSnapshot.listen(function(data, player)
		if player ~= nil then
			onRequestSnapshot(data, player)
		end
	end)

	Net.devSet.listen(function(data, player)
		if player ~= nil then
			onSet(data, player)
		end
	end)

	Net.devRequestAccess.listen(function(_, player)
		if player == nil then
			return
		end

		--[[
			Rate limited like every other packet, and for the reason the top
			comment gives: anyone can send this, so a flood must cost us nothing.
			It shares lastCommandAt deliberately -- a separate table would be a
			third thing to remember to clear on PlayerRemoving.

			No auth check: the answer IS the player's auth state, and telling
			someone "no" reveals nothing they could not infer from the absence of
			an icon.
		]]
		local now = os.clock()
		local last = lastCommandAt[player]
		if last ~= nil and now - last < MIN_COMMAND_INTERVAL then
			return
		end
		lastCommandAt[player] = now

		publishAccess(player)
	end)
end

function DevService.Start()
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Players.PlayerAdded:Connect(publishAccess)

	--[[
		GetConfigAsync yields, and throws if the config has never loaded -- hence
		Start() and hence the pcall. A throw here is not fatal: developerIds stays
		empty, every check denies, and the game runs fine without a dev console.
	]]
	local ok, snapshot = pcall(function()
		return ConfigService:GetConfigAsync()
	end)

	if not ok then
		log.warn(`could not load configs ({snapshot}) -- nobody has console access this server`)
		return
	end

	local function reload()
		developerIds = decodeDevelopers(snapshot:GetValue(DEVELOPERS_CONFIG_KEY))

		local count = 0
		for _ in developerIds do
			count += 1
		end
		log.info(`{count} developer(s) on the list`)

		-- Re-tell everyone: this is what makes adding a UserId in the dashboard
		-- take effect on a running server instead of at the next restart.
		for _, player in Players:GetPlayers() do
			publishAccess(player)
		end
	end

	reload()

	--[[
		The snapshot is a point-in-time object -- UpdateAvailable announces that
		newer values exist but does NOT apply them, so Refresh() is ours to call.
		Miss this and the dashboard's "no republish" promise quietly becomes
		"no republish, but do restart the server".
	]]
	snapshot.UpdateAvailable:Connect(function()
		local refreshed = pcall(function()
			snapshot:Refresh()
		end)
		if refreshed then
			reload()
		end
	end)

	log.info("ready")
end

return DevService
