--!strict
--[[
	ProfileStore (persistence) + Replica (replication).

	The split, in one line each:
	  ProfileStore  = the disk. Survives rejoins. Nobody but the server sees it.
	  Replica       = the wire. Pushes profile.Data to the owning client only.

	The trick that makes this simple: Replica.New{ Data = profile.Data } does NOT
	copy the table -- the replica holds a reference to the SAME table. So one
	`replica:Set(...)` call mutates the profile AND replicates. There is no
	"write it twice and hope they stay in sync" problem, because there is only
	one table.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local ProfileStore = require(ServerStorage.ServerPackages.ProfileStore)
local Replica = require(ServerStorage.ReplicaServer)

local log = Log.new("DataService")

--[[
	The template. Adding a field here is the entire workflow for new data --
	it persists, it replicates, and Reconcile() backfills it onto existing
	profiles automatically.

	Version drives migrations. Bump it on any breaking shape change.
	Reconcile() only ADDS missing keys -- it cannot rename, reshape or split.
	Without a Version already saved in every profile, you cannot tell "old
	shape" from "new shape with defaults", and you are left choosing between a
	data wipe and a permanent hack. It costs one integer. Do it now.

	WARNING (from Replica's own docs): no gaps in numeric tables, and no keys
	that aren't strings or numbers. Those cannot be replicated.
]]
local DATA_VERSION = 1

local TEMPLATE = {
	Version = DATA_VERSION,
	Coins = 0,
	Level = 1,
	Experience = 0,
	-- Nested tables are fine -- this is the whole reason Replica exists.
	Inventory = {} :: { [string]: number },
	Settings = {
		MusicEnabled = true,
	},
}

export type PlayerData = typeof(TEMPLATE)

-- Index N migrates version N -> N+1. Never delete or renumber one.
local MIGRATIONS: { (data: any) -> () } = {}

local PROFILE_STORE_NAME = "PlayerData_v1"

local DataService = {
	-- Loads before anything that reads player data.
	Priority = 100,
}

-- One token per replica kind. Replica.Token errors if you create the same
-- string twice, so it lives at module scope, not inside a function.
local PLAYER_DATA_TOKEN = Replica.Token("PlayerData")

--[[
	Mock in Studio. Without this, Studio testing with API services enabled writes
	to LIVE player keys -- and a bad migration tested in Studio corrupts real
	players' data.

	This lives in the module body, not Init(), deliberately. `store.Mock` is a
	plain field on the store table and the Mock table has no `.Mock` of its own,
	so `store = store.Mock` run twice yields nil. Module bodies run exactly once
	(require caches), so doing it here is idempotent by construction; doing it in
	Init() is only correct as long as nothing ever calls Init() twice.
]]
local liveStore = ProfileStore.New(PROFILE_STORE_NAME, TEMPLATE)
-- Both branches expose the same persistence methods. Typing the result as the
-- mock interface also accepts the live store, whose extra `.Mock` field is not
-- needed below.
local store: typeof(liveStore.Mock) = if RunService:IsStudio() then liveStore.Mock else liveStore

local profiles: { [Player]: any } = {}
local replicas: { [Player]: any } = {}

local function runMigrations(data: any)
	local from = data.Version or 0
	for version = from, DATA_VERSION - 1 do
		local migrate = MIGRATIONS[version]
		if migrate ~= nil then
			migrate(data)
		end
	end
	data.Version = DATA_VERSION
end

local function onPlayerAdded(player: Player)
	local profile = store:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		player:Kick("Data failed to load. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId) -- GDPR compliance
	runMigrations(profile.Data)
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		if replicas[player] ~= nil then
			replicas[player]:Destroy()
			replicas[player] = nil
		end
		player:Kick("Data session ended. Please rejoin.")
	end)

	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	profiles[player] = profile

	--[[
		Create the replica. Note `Data = profile.Data` -- same table, not a copy.
		Tags are immutable identifiers set once at creation; they ride along to
		the client so it can tell whose replica this is.
	]]
	local replica = Replica.New({
		-- Replica.Token() returns the correct object at runtime. ReplicaServer's
		-- bundled annotation mistakenly asks for its internal token class instead
		-- of the returned token instance, so keep this compatibility cast local.
		Token = PLAYER_DATA_TOKEN :: any,
		Tags = { UserId = player.UserId },
		Data = profile.Data,
	})
	replicas[player] = replica

	--[[
		Subscribe = "send this replica to this one player". This is what makes
		the data PRIVATE -- no other client ever receives it. (Replicate() would
		send it to everyone; that's not what we want for player data.)

		GOTCHA: you cannot Subscribe a player who isn't "ready" yet -- ready
		means their client has called Replica.RequestData(). Subscribing early
		is a no-op plus a warning, and the player silently gets no data. So
		check ReadyPlayers first, and wait on NewReadyPlayer if they aren't.
	]]
	if Replica.ReadyPlayers[player] then
		replica:Subscribe(player)
	else
		local connection
		connection = Replica.NewReadyPlayer:Connect(function(readyPlayer: Player)
			if readyPlayer ~= player then
				return
			end
			connection:Disconnect()
			if replicas[player] == replica and replica:IsActive() then
				replica:Subscribe(player)
			end
		end)
	end

	log.info(`loaded profile for {player.Name}`)
end

local function onPlayerRemoving(player: Player)
	local replica = replicas[player]
	if replica ~= nil then
		replica:Destroy()
		replicas[player] = nil
	end

	local profile = profiles[player]
	if profile ~= nil then
		profile:EndSession()
		profiles[player] = nil
	end
end

function DataService.Start()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			task.spawn(onPlayerRemoving, player)
		end
	end)
end

--[[
	THE WRITE PATH. Every mutation goes through a replica setter -- never touch
	profile.Data directly. A raw `profile.Data.Coins = 5` mutates the table but
	sends nothing, so the client silently drifts out of sync. The setters are
	the only thing that both mutate and replicate.

	`path` is a key branch into Data: {"Settings", "MusicEnabled"}.
]]
function DataService.set(player: Player, path: { string | number }, value: any)
	local replica = replicas[player]
	if replica == nil or not replica:IsActive() then
		log.warn(`set() on {player.Name} with no active replica -- dropped`)
		return
	end
	replica:Set(path, value)
end

-- Batch sibling keys under one path in a single replication packet.
function DataService.setValues(player: Player, path: { string | number }, values: { [string]: any })
	local replica = replicas[player]
	if replica == nil or not replica:IsActive() then
		log.warn(`setValues() on {player.Name} with no active replica -- dropped`)
		return
	end
	replica:SetValues(path, values)
end

function DataService.getData(player: Player): PlayerData?
	local profile = profiles[player]
	return if profile ~= nil then profile.Data else nil
end

function DataService.getReplica(player: Player): any?
	return replicas[player]
end

return DataService
