--!strict
--[[
	Server authority for the admin panel (AdminController is the UI).

	WHO IS AN ADMIN: the UserIds in Modules/AdminList (always), plus any listed
	in the Creator Dashboard config `developers` ({ "userIds": [...] }), read
	live. The client is only told its status (Net.adminAccess) so it knows
	whether to draw the panel; EVERY admin packet is re-checked here, so a
	client that forges its access gets a UI that does nothing.

	ORDER IN EVERY HANDLER: the rate limit first, before the admin check and
	before any logging -- anyone can send these packets, and the only answer to
	a flood from a non-admin that costs less than the flood is to drop it
	having done nothing. Then the admin check, then validation, then the work.

	DATA EDITS go through one function, applyEdit, whether the target is here
	or not:
	  - in this server: applied now, through DataService (so it replicates);
	  - anywhere else: queued on their saved profile with MessageAsync and
	    applied by that same applyEdit when their profile loads or when the
	    server holding it receives the message (DataService explains why it
	    is never written directly).
	So an offline edit is validated exactly like a live one, just later.
	Every value arrives as a string and is parsed and bounded here; nothing a
	client sends reaches DataService as-is.

	EVERY ACTION IS LOGGED to the output and to a short in-memory log the panel
	shows, with the admin's name, so "who did this?" has an answer.
]]

local ConfigService = game:GetService("ConfigService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

local AdminList = require(ServerStorage.Modules.AdminList)
local CodeService = require(script.Parent.CodeService)
local Cosmetics = require(ReplicatedStorage.Shared.Cosmetics)
local DataService = require(script.Parent.DataService)
local GrenadeService = require(script.Parent.GrenadeService)
local Items = require(ReplicatedStorage.Shared.Items)
local LoadoutService = require(script.Parent.LoadoutService)
local Log = require(ReplicatedStorage.Shared.Log)
local MapCatalog = require(ReplicatedStorage.Shared.MapCatalog)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantService = require(script.Parent.ParticipantService)
local Progression = require(ReplicatedStorage.Shared.Progression)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)
local TeamService = require(script.Parent.TeamService)

local log = Log.new("AdminService")

local DEVELOPERS_CONFIG_KEY = "developers"

-- Floors on each kind of request. Separate limiters, so loading a profile
-- and then editing it at once are not the same budget. A lookup yields on
-- the web and the DataStore, so it gets the wider floor.
local actionLimit = RateLimiter.new(0.15)
local lookupLimit = RateLimiter.new(1)
local stateLimit = RateLimiter.new(0.5)

local MAX_CASH = 1e15
local MAX_EXPERIENCE = 1e12
local MAX_CASES = 1e6
local MAX_PATH_DEPTH = 6
local MAX_KEY_LENGTH = 64
local MAX_STRING_VALUE_LENGTH = 256
local MAX_ANNOUNCEMENT_LENGTH = 200
local MAX_KICK_REASON_LENGTH = 120
local MAX_STUN_SECONDS = 30
local LOG_SIZE = 60

local configIds: { [number]: true } = {}
local auditLog: { string } = {}

local AdminService = {}

local function isAdmin(player: Player): boolean
	return AdminList[player.UserId] == true or configIds[player.UserId] == true
end

local function publishAccess(player: Player)
	Net.adminAccess.sendTo({ allowed = isAdmin(player) }, player)
end

local function reply(player: Player, ok: boolean, message: string)
	Net.adminResult.sendTo({ ok = ok, message = message }, player)
end

-- One line in the output and in the panel's log, newest first.
local function audit(admin: Player, text: string)
	log.info(`[admin] {admin.Name}: {text}`)
	table.insert(auditLog, 1, `{os.date("!%H:%M:%S")} UTC  {admin.Name}: {text}`)
	if #auditLog > LOG_SIZE then
		table.remove(auditLog)
	end
end

-- Rate limit, then the admin check. Only a real admin who was not
-- rate-limited is told anything.
local function gate(player: Player, limiter: RateLimiter.Limiter): boolean
	if not limiter.allow(player) then
		return false
	end
	return isAdmin(player)
end

--========================================================================
-- PARSING (every client value is a string until here)
--========================================================================

-- A whole number in [min, max], or nil. NaN and infinity fail explicitly
-- (quality-gate.md trap #8).
local function parseInteger(raw: string, min: number, max: number): number?
	local n = tonumber(raw)
	if n == nil or n ~= n or n == math.huge or n == -math.huge or n % 1 ~= 0 then
		return nil
	end
	if n < min or n > max then
		return nil
	end
	return n
end

--[[
	A path for SetField: "Settings.MusicEnabled" -> { "Settings", "MusicEnabled" }.
	Keys are strings, always: a numeric key with a gap is a table Replica cannot
	send, and a permanently broken profile. The first key must already exist
	(only template fields), every step before the last must be a table, and
	containers are never overwritten.
]]
local function parsePath(data: any, raw: string): ({ string }?, string?)
	local path: { string } = {}
	for segment in string.gmatch(raw, "[^%.]+") do
		if #segment > MAX_KEY_LENGTH then
			return nil, "a key in that path is too long"
		end
		table.insert(path, segment)
	end
	if #path == 0 or #path > MAX_PATH_DEPTH then
		return nil, "that path is empty or too deep"
	end
	if data[path[1]] == nil then
		return nil, `"{path[1]}" is not a field of the profile`
	end
	local node: any = data
	for index = 1, #path - 1 do
		node = node[path[index]]
		if type(node) ~= "table" then
			return nil, `"{path[index]}" is not a table`
		end
	end
	if type(node[path[#path]]) == "table" then
		return nil, "that path is a whole table -- edit a value inside it"
	end
	return path, nil
end

--[[
	SetField's value: "true"/"false" is a boolean, a number is a number, and
	anything else is a string. It must match the type already at the path, if
	there is one, so a typo cannot turn Cash into text.
]]
local function parseScalar(raw: string, existing: any): (any, string?)
	local value: any
	if raw == "true" or raw == "false" then
		value = raw == "true"
	else
		local n = tonumber(raw)
		if n ~= nil then
			if n ~= n or n == math.huge or n == -math.huge then
				return nil, "that number is not finite"
			end
			value = n
		else
			if #raw > MAX_STRING_VALUE_LENGTH then
				return nil, "that text is too long"
			end
			value = raw
		end
	end
	if existing ~= nil and type(existing) ~= type(value) then
		return nil, `that field is a {type(existing)}, not a {type(value)}`
	end
	return value, nil
end

--========================================================================
-- DATA EDITS
--========================================================================

--[[
	Applies one edit to a player whose profile is loaded in THIS server.
	Returns ok and a message. The single place an edit's rules live -- both
	live edits and queued offline messages come through here.
]]
local function applyEdit(target: Player, op: string, key: string, raw: string): (boolean, string)
	local data = DataService.getData(target)
	if data == nil then
		return false, "their data is not loaded"
	end

	if op == "SetCash" then
		local n = parseInteger(raw, 0, MAX_CASH)
		if n == nil then
			return false, "cash must be a whole number from 0"
		end
		DataService.set(target, { "Cash" }, n)
		return true, `cash set to {n}`
	elseif op == "SetLevel" then
		local n = parseInteger(raw, Progression.MIN_LEVEL, Progression.MAX_LEVEL)
		if n == nil then
			return false, `level must be {Progression.MIN_LEVEL}-{Progression.MAX_LEVEL}`
		end
		DataService.set(target, { "Level" }, n)
		return true, `level set to {n}`
	elseif op == "SetExperience" then
		local n = parseInteger(raw, 0, MAX_EXPERIENCE)
		if n == nil then
			return false, "experience must be a whole number from 0"
		end
		DataService.set(target, { "Experience" }, n)
		return true, `experience set to {n}`
	elseif op == "SetCases" then
		local case = Cosmetics.case(key)
		if case == nil then
			return false, "no such case"
		end
		local n = parseInteger(raw, 0, MAX_CASES)
		if n == nil then
			return false, "the case count must be a whole number from 0"
		end
		-- 0 deletes the key, as InventoryService does: a stack of zero is
		-- not a stack.
		DataService.set(target, { "Inventory", case.Id }, if n == 0 then nil else n)
		return true, `{case.DisplayName} set to {n}`
	elseif op == "GrantTitle" then
		local title = Cosmetics.title(key)
		if title == nil then
			return false, "no such title"
		end
		DataService.set(target, { "Titles", title.Id }, true)
		return true, `granted {title.Text}`
	elseif op == "RevokeTitle" then
		local title = Cosmetics.title(key)
		if title == nil then
			return false, "no such title"
		end
		DataService.set(target, { "Titles", title.Id }, nil)
		-- Never leave a title equipped that is no longer owned.
		if data.EquippedTitle == title.Id then
			DataService.set(target, { "EquippedTitle" }, "")
		end
		return true, `revoked {title.Text}`
	elseif op == "EquipTitle" then
		if key ~= "" and (Cosmetics.title(key) == nil or data.Titles[key] ~= true) then
			return false, "they do not own that title"
		end
		DataService.set(target, { "EquippedTitle" }, key)
		return true, if key == "" then "title unequipped" else `equipped {key}`
	elseif op == "SetField" then
		local path, pathError = parsePath(data, key)
		if path == nil then
			return false, pathError or "bad path"
		end
		local node: any = data
		for index = 1, #path - 1 do
			node = node[path[index]]
		end
		local value, valueError = parseScalar(raw, node[path[#path]])
		if valueError ~= nil then
			return false, valueError
		end
		DataService.set(target, path, value)
		return true, `{key} set to {raw}`
	elseif op == "ResetData" then
		DataService.setValues(target, {}, { Cash = 0, Level = 1, Experience = 0, EquippedTitle = "" })
		DataService.set(target, { "Inventory" }, {})
		DataService.set(target, { "Titles" }, {})
		return true, "data reset"
	end

	return false, `unknown edit "{op}"`
end

-- The profile fields the panel shows, as JSON.
local function encodeProfile(data: any): string
	local ok, json = pcall(HttpService.JSONEncode, HttpService, {
		Cash = data.Cash,
		Level = data.Level,
		Experience = data.Experience,
		Inventory = data.Inventory,
		Titles = data.Titles,
		EquippedTitle = data.EquippedTitle,
		Settings = data.Settings,
	})
	return if ok then json else "{}"
end

-- A username or a UserId typed into the panel, as a UserId. YIELDS.
local function resolveUserId(query: string): number?
	local trimmed = string.match(query, "^%s*(.-)%s*$") or ""
	if trimmed == "" then
		return nil
	end
	local asNumber = parseInteger(trimmed, 1, 2 ^ 53)
	if asNumber ~= nil then
		return asNumber
	end
	local ok, userId = pcall(Players.GetUserIdFromNameAsync, Players, trimmed)
	return if ok then userId else nil
end

local function displayName(userId: number): string
	local here = Players:GetPlayerByUserId(userId)
	if here ~= nil then
		return here.Name
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	return if ok then name else tostring(userId)
end

-- Sends one player's profile to an admin. YIELDS for anyone not here.
local function sendProfile(admin: Player, userId: number)
	local name = displayName(userId)
	local here = Players:GetPlayerByUserId(userId)
	if here ~= nil then
		local data = DataService.getData(here)
		Net.adminProfile.sendTo({
			userId = userId,
			name = name,
			location = if data ~= nil then "Here" else "None",
			data = if data ~= nil then encodeProfile(data) else "{}",
		}, admin)
		return
	end

	local peek = DataService.peek(userId)
	if peek == nil then
		Net.adminProfile.sendTo({ userId = userId, name = name, location = "None", data = "{}" }, admin)
		return
	end
	local session = peek.session
	local elsewhere = session ~= nil and session.JobId ~= game.JobId
	Net.adminProfile.sendTo({
		userId = userId,
		name = name,
		location = if elsewhere then "Elsewhere" else "Offline",
		data = encodeProfile(peek.data),
	}, admin)
end

local function onLookup(admin: Player, query: string)
	if not gate(admin, lookupLimit) then
		return
	end
	task.spawn(function()
		local userId = resolveUserId(query)
		if userId == nil then
			reply(admin, false, `no player called "{string.sub(query, 1, 40)}"`)
			return
		end
		sendProfile(admin, userId)
	end)
end

local function onEdit(admin: Player, userId: number, op: string, key: string, raw: string)
	if not gate(admin, actionLimit) then
		return
	end

	local here = Players:GetPlayerByUserId(userId)
	if here ~= nil then
		local ok, message = applyEdit(here, op, key, raw)
		reply(admin, ok, message)
		if ok then
			audit(admin, `{here.Name}: {message}`)
			sendProfile(admin, userId)
		end
		return
	end

	-- Not here: queue it on their saved profile (DataService explains why
	-- it is never written directly). Both calls yield.
	task.spawn(function()
		if DataService.peek(userId) == nil then
			reply(admin, false, "that player has no saved data")
			return
		end
		local sent = DataService.sendMessage(userId, { op = op, key = key, value = raw, by = admin.UserId })
		if not sent then
			reply(admin, false, "could not queue the edit -- try again")
			return
		end
		audit(admin, `{userId} (not here): queued {op} {key} {raw}`)
		reply(admin, true, "queued -- it applies when their data next loads or saves")
	end)
end

-- A queued edit arriving on a profile that just loaded here (or was told to
-- save). Validated by the same applyEdit as a live edit.
local function onProfileMessage(player: Player, message: any)
	if type(message) ~= "table" then
		return
	end
	local op, key, value = message.op, message.key, message.value
	if type(op) ~= "string" or type(key) ~= "string" or type(value) ~= "string" then
		log.warn(`malformed queued edit for {player.Name} -- dropped`)
		return
	end
	local ok, result = applyEdit(player, op, key, value)
	log.info(
		`[admin] queued edit for {player.Name} by {tostring(message.by)}: {result}{if ok then "" else " (refused)"}`
	)
end

--========================================================================
-- PLAYER ACTIONS (target must be in this server)
--========================================================================

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function playerAction(admin: Player, target: Player, action: string, arg: string): (boolean, string)
	if action == "Kill" then
		local character = target.Character
		local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid == nil or humanoid.Health <= 0 then
			return false, "they are not alive"
		end
		-- Through the Humanoid, like a real kill: SpawnService's Died handler
		-- does the killcam and the respawn. No score, no reward.
		humanoid.Health = 0
		return true, "killed"
	elseif action == "ToMenu" then
		ParticipantService.leaveMatch(target)
		return true, "sent to the menu"
	elseif action == "Stun" then
		local seconds = parseInteger(arg, 1, MAX_STUN_SECONDS) or 3
		if not GrenadeService.stunPlayer(target, seconds) then
			return false, "they are not alive"
		end
		return true, `stunned for {seconds}s`
	elseif action == "Shock" then
		local seconds = parseInteger(arg, 1, MAX_STUN_SECONDS) or 3
		if not GrenadeService.shockPlayer(target, seconds) then
			return false, "they are not alive"
		end
		return true, `shocked for {seconds}s`
	elseif action == "GiveItem" then
		if not Items.exists(arg) then
			return false, "no such item"
		end
		if not LoadoutService.give(target, arg) then
			return false, "their toolbar is full (or they are not playing)"
		end
		return true, `gave {arg}`
	elseif action == "SetTeam" then
		local mode = RoundService.getTeamMode()
		if not mode.UsesTeams then
			return false, "this round has no teams"
		end
		if not Match.modeHasTeam(mode, arg) then
			return false, "that team is not in this round"
		end
		local team: Match.TeamId = arg :: Match.TeamId
		if not TeamService.assign(target, team, mode.Teams) then
			return false, "that would unbalance the teams"
		end
		RoundService.writePlayer(target, { Team = team })
		return true, `moved to {team}`
	elseif action == "Kick" then
		if target == admin then
			return false, "you cannot kick yourself"
		end
		local reason = string.sub(arg, 1, MAX_KICK_REASON_LENGTH)
		target:Kick(if reason ~= "" then `Kicked by an admin: {reason}` else "Kicked by an admin")
		return true, "kicked"
	elseif action == "Bring" or action == "GoTo" then
		local adminCharacter = admin.Character
		local targetCharacter = target.Character
		local adminRoot = rootOf(admin)
		local targetRoot = rootOf(target)
		if adminCharacter == nil or targetCharacter == nil or adminRoot == nil or targetRoot == nil then
			return false, "you both need to be spawned"
		end
		-- Four studs in front of the other one, facing the same way, so
		-- neither lands inside the other's collision box.
		if action == "Bring" then
			targetCharacter:PivotTo(adminRoot.CFrame * CFrame.new(0, 0, -4))
			return true, "brought to you"
		end
		adminCharacter:PivotTo(targetRoot.CFrame * CFrame.new(0, 0, -4))
		return true, "teleported to them"
	elseif action == "RerollCode" then
		if CodeService.reroll(target) == nil then
			return false, "they have no code right now"
		end
		return true, "code rerolled"
	end
	return false, `unknown action "{action}"`
end

local function onPlayerAction(admin: Player, userId: number, action: string, arg: string)
	if not gate(admin, actionLimit) then
		return
	end
	local target = Players:GetPlayerByUserId(userId)
	if target == nil then
		reply(admin, false, "they are not in this server")
		return
	end
	local ok, message = playerAction(admin, target, action, arg)
	reply(admin, ok, `{target.Name}: {message}`)
	if ok then
		audit(admin, `{target.Name}: {message}`)
	end
end

--========================================================================
-- SERVER ACTIONS
--========================================================================

local function sendState(admin: Player)
	local override = RoundService.getNextOverride()
	Net.adminState.sendTo({
		nextMap = if override ~= nil then override.mapId or "" else "",
		nextGameMode = if override ~= nil then override.gameModeId or "" else "",
		nextTeamMode = if override ~= nil then override.teamModeId or "" else "",
		nextSkipVote = override ~= nil and override.skipVote,
		log = auditLog,
	}, admin)
end

-- "" means "leave it to the vote"; anything else must be a real id.
local function parseOverride(
	mapId: string,
	gameMode: string,
	teamMode: string,
	skipVote: boolean
): (RoundService.NextOverride?, string?)
	if mapId ~= "" and MapCatalog.byId(mapId) == nil then
		return nil, "no such map"
	end
	if gameMode ~= "" and not Match.isGameModeId(gameMode) then
		return nil, "no such game mode"
	end
	if teamMode ~= "" and not Match.isTeamModeId(teamMode) then
		return nil, "no such team mode"
	end
	return {
		mapId = if mapId ~= "" then mapId else nil,
		gameModeId = if gameMode ~= "" then gameMode :: Match.GameModeId else nil,
		teamModeId = if teamMode ~= "" then teamMode :: Match.TeamModeId else nil,
		skipVote = skipVote,
	},
		nil
end

local function announce(admin: Player, text: string)
	local trimmed = string.sub(string.match(text, "^%s*(.-)%s*$") or "", 1, MAX_ANNOUNCEMENT_LENGTH)
	if trimmed == "" then
		reply(admin, false, "write something to announce")
		return
	end
	--[[
		Filtered, as all text one player writes for others to read must be:
		an admin is still a player to Roblox's text rules. Filtering yields,
		and a failed filter sends nothing rather than the unfiltered text.
	]]
	task.spawn(function()
		local ok, filtered = pcall(function()
			local result = TextService:FilterStringAsync(trimmed, admin.UserId, Enum.TextFilterContext.PublicChat)
			return result:GetNonChatStringForBroadcastAsync()
		end)
		if not ok then
			reply(admin, false, "the text filter is unavailable -- try again")
			return
		end
		Net.announcement.sendToAll({ message = filtered, from = admin.DisplayName })
		audit(admin, `announced "{filtered}"`)
		reply(admin, true, "announced")
	end)
end

local function onServerAction(admin: Player, action: string, a: string, b: string, c: string)
	if not gate(admin, actionLimit) then
		return
	end

	if action == "Announce" then
		announce(admin, a)
		return
	end

	local ok, message = false, `unknown action "{action}"`
	if action == "SkipPhase" then
		ok = RoundService.skipPhase()
		message = if ok then `skipped {RoundService.getState()}` else "this phase has nothing to skip"
	elseif action == "EndRound" then
		if RoundService.isRoundActive() then
			RoundService.endRound("ended by an admin")
			ok, message = true, "round ended"
		else
			message = "no round is running"
		end
	elseif action == "RestartRound" then
		RoundService.restartRound()
		ok, message = true, "round restarted"
	elseif action == "SetNext" or action == "ChangeNow" then
		local override, overrideError = parseOverride(a, b, c, action == "ChangeNow")
		if override == nil then
			message = overrideError or "bad override"
		else
			RoundService.setNextOverride(override)
			if action == "ChangeNow" then
				RoundService.restartRound()
				ok, message =
					true,
					`changing now: {a ~= "" and a or "random map"} / {b ~= "" and b or "same mode"} / {c ~= "" and c or "same teams"}`
			else
				ok, message =
					true,
					`next round forced: {a ~= "" and a or "vote"} / {b ~= "" and b or "vote"} / {c ~= "" and c or "vote"}`
			end
		end
	elseif action == "ClearNext" then
		RoundService.clearNextOverride()
		ok, message = true, "next round left to the vote"
	end

	reply(admin, ok, message)
	if ok then
		audit(admin, message)
	end
	sendState(admin)
end

--========================================================================
-- ACCESS LIST FROM THE DASHBOARD CONFIG
--========================================================================

--[[
	Roblox does not document whether GetValue() on a JSON-object config hands
	back a decoded table or the raw JSON string, so both are accepted. Every
	failure yields an empty set: the config can only ADD admins, never lock out
	the ones in AdminList.
]]
local function decodeConfigIds(raw: any): { [number]: true }
	local ids: { [number]: true } = {}
	local decoded: any = raw
	if type(raw) == "string" then
		local ok, result = pcall(HttpService.JSONDecode, HttpService, raw)
		if not ok then
			return ids
		end
		decoded = result
	end
	if type(decoded) ~= "table" or type(decoded.userIds) ~= "table" then
		return ids
	end
	for _, id in decoded.userIds do
		if type(id) == "number" and id == id and id % 1 == 0 and id > 0 then
			ids[id] = true
		end
	end
	return ids
end

local function loadConfig()
	-- Yields and throws if configs never loaded; AdminList still works.
	local ok, snapshot = pcall(function()
		return ConfigService:GetConfigAsync()
	end)
	if not ok then
		log.info("no dashboard config -- only AdminList admins this server")
		return
	end

	local function reload()
		configIds = decodeConfigIds(snapshot:GetValue(DEVELOPERS_CONFIG_KEY))
		for _, player in Players:GetPlayers() do
			publishAccess(player)
		end
	end
	reload()
	snapshot.UpdateAvailable:Connect(function()
		if pcall(function()
			snapshot:Refresh()
		end) then
			reload()
		end
	end)
end

function AdminService.Init()
	DataService.setMessageHandler(onProfileMessage)

	Net.adminRequestAccess.listen(function(_, player)
		if player ~= nil and stateLimit.allow(player) then
			publishAccess(player)
		end
	end)
	Net.adminLookup.listen(function(data, player)
		if player ~= nil then
			onLookup(player, data.query)
		end
	end)
	Net.adminEdit.listen(function(data, player)
		if player ~= nil then
			onEdit(player, data.userId, data.op, data.key, data.value)
		end
	end)
	Net.adminPlayerAction.listen(function(data, player)
		if player ~= nil then
			onPlayerAction(player, data.userId, data.action, data.arg)
		end
	end)
	Net.adminServerAction.listen(function(data, player)
		if player ~= nil then
			onServerAction(player, data.action, data.a, data.b, data.c)
		end
	end)
	Net.adminRequestState.listen(function(_, player)
		if player ~= nil and gate(player, stateLimit) then
			sendState(player)
		end
	end)
end

function AdminService.Start()
	-- Deferred so ByteNet's own PlayerAdded handler has run first.
	Players.PlayerAdded:Connect(function(player: Player)
		task.defer(publishAccess, player)
	end)
	loadConfig()
	log.info("ready")
end

return AdminService
