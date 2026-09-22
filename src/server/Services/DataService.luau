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
local DATA_VERSION = 2

local TEMPLATE = {
	Version = DATA_VERSION,
	--[[
		The currency, named for what the game calls it on screen. It was
		`Coins` in v1; see MIGRATIONS below for why that rename needed a
		version bump and a one-time move rather than just editing this line.
	]]
	Cash = 0,
	Level = 1,
	Experience = 0,
	-- Nested tables are fine -- this is the whole reason Replica exists.
	-- Counted stacks only (InventoryService); cases live here as "TitleCase".
	Inventory = {} :: { [string]: number },
	--[[
		Owned titles, as a set: { [titleId] = true }. Its own field, NOT under
		Inventory -- Inventory is { [id]: count } and InventoryService would
		read a nested table as a count of 0, or overwrite it with a number.
		Seeded here because Replica's Set throws on a missing parent table.
		Written only by CosmeticsService.
	]]
	Titles = {} :: { [string]: boolean },
	-- The title shown on the player's card, or "" for none. Always one the
	-- player owns (CosmeticsService checks before writing).
	EquippedTitle = "",
	Settings = {
		MusicEnabled = true,
		--[[
			Accessibility, and the reason it is a persisted setting rather than
			a client-side toggle: a player who needs the dark flash needs it on
			every device and every session, and a preference that has to be
			re-set after each rejoin is one that fails exactly the people it
			exists for. Default false -- the white flash is the designed effect;
			this replaces it, it is not a lesser mode.
		]]
		DarkFlashEffect = false,
	},
}

export type PlayerData = typeof(TEMPLATE)

--[[
	Index N migrates version N -> N+1. Never delete or renumber one.

	v1 -> v2 renames Coins to Cash. Reconcile() could not do this alone: it
	only ADDS missing keys (ARCHITECTURE.md, "Adding vs. reshaping"), so
	without this step every existing player would have been handed a brand new
	Cash = 0 while their real balance sat in an orphaned Coins key, draining
	DataStore bytes forever and looking exactly like a wipe from the player's
	side.

	`or 0` rather than a bare copy: a v0 profile predating the Version field
	has no Coins either, and arithmetic on nil here would abort the load for
	that player and kick them.
]]
local MIGRATIONS: { (data: any) -> () } = {
	[1] = function(data)
		data.Cash = data.Coins or 0
		-- Delete the old key. Leaving it costs space in a 4MB-capped profile
		-- and leaves two plausible answers to "what is their balance?".
		data.Coins = nil
	end,
}

local PROFILE_STORE_NAME = "PlayerData_v1"
-- Studio's own store: real and persistent, but never the live players' keys.
local STUDIO_STORE_SUFFIX = "_Studio"

local DataService = {
	-- Loads before anything that reads player data.
	Priority = 100,
}

-- One token per replica kind. Replica.Token errors if you create the same
-- string twice, so it lives at module scope, not inside a function.
local PLAYER_DATA_TOKEN = Replica.Token("PlayerData")

--[[
	A separate store in Studio. Studio testing with API services enabled must
	never write to LIVE player keys -- a bad migration tested in Studio would
	corrupt real players' data. So Studio gets its own store name.

	It is a REAL store, not ProfileStore's Mock. The Mock keeps data in memory
	only, so everything earned in a Studio test vanished when Play stopped --
	which looks exactly like a data-loss bug and hides real ones. With a
	separate real store, Studio sessions persist like the live game does and
	still cannot touch it. With API services off, ProfileStore falls back to
	its in-memory mode on its own (and says so in the output).
]]
local store = ProfileStore.New(
	if RunService:IsStudio() then PROFILE_STORE_NAME .. STUDIO_STORE_SUFFIX else PROFILE_STORE_NAME,
	TEMPLATE
)

local profiles: { [Player]: any } = {}
local replicas: { [Player]: any } = {}

-- Applies a queued profile message (see DataService.setMessageHandler).
local messageHandler: ((player: Player, message: any) -> ())? = nil

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

	--[[
		Admin edits queued for this profile while the player was offline or in
		another server (DataService.sendMessage). Registered LAST, after the
		replica exists: ProfileStore runs the handler immediately for every
		message already waiting, and the handler writes through the replica so
		the client sees the change like any other write.

		processed() is called for every message the handler has looked at,
		applied or refused, so a malformed message cannot sit in the queue
		forever. ProfileStore removes it in the same save that stores the data
		change, so "applied" and "consumed" cannot come apart.
	]]
	profile:MessageHandler(function(message: any, processed: () -> ())
		local handler = messageHandler
		if handler == nil then
			-- Nobody to apply it yet; leave it queued rather than lose it.
			return
		end
		if replicas[player] ~= replica or not replica:IsActive() then
			return
		end
		-- Widened return, so the checker sees pcall's error value (the same
		-- move RoundService.Start makes for xpcall).
		local run: (Player, any) -> ...any = handler
		local ok, err = pcall(run, player, message)
		if not ok then
			log.warn(`profile message for {player.Name} failed: {err}`)
		end
		processed()
	end)

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
	profile.Data directly. A raw `profile.Data.Cash = 5` mutates the table but
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

--========================================================================
-- PLAYERS WHO ARE NOT IN THIS SERVER (the admin panel)
--========================================================================

--[[
	WHY THERE IS NO "WRITE SOMEONE ELSE'S PROFILE" HERE

	ProfileStore's view-profile SetAsync overwrites the whole profile AND
	clears the session lock. For a player online in another server that is
	two failures at once: everything they earned since that server's last
	save is lost, and that server kicks them at its next save when it finds it
	no longer owns the profile. So an edit to a player who is not in THIS
	server is never written directly. It is queued with MessageAsync:

	  - online in another server: that server is told over MessagingService to
	    save, which delivers the message to its MessageHandler within seconds;
	  - offline everywhere: it waits in the profile and applies on next join;
	  - in this server: MessageAsync saves the local profile, which runs the
	    handler above immediately (callers use set() instead, which is simpler).

	The message is applied by whoever registered setMessageHandler
	(AdminService), with the same validation as a live edit.
]]

-- Registers the one function that applies queued profile messages.
function DataService.setMessageHandler(handler: (player: Player, message: any) -> ())
	messageHandler = handler
end

export type Peek = {
	-- The stored data, migrated to the current version for display. A copy the
	-- caller may read freely; writing to it changes nothing.
	data: any,
	-- Where the player's live session is, if one holds the lock right now.
	session: { PlaceId: number, JobId: string }?,
}

--[[
	Reads a player's saved profile without starting a session. YIELDS (a
	DataStore read, retried by ProfileStore). Nil if the player has never
	played -- a UserId with no profile is not somebody to edit.
]]
function DataService.peek(userId: number): Peek?
	local profile = store:GetAsync(tostring(userId))
	if profile == nil then
		return nil
	end
	local data = profile.Data
	runMigrations(data)
	return { data = data, session = profile.Session }
end

--[[
	Queues `message` on a player's saved profile (see the section header).
	YIELDS. False if ProfileStore gave up (the server is closing). The caller
	must have confirmed the profile exists (peek): MessageAsync on a key that
	was never used creates one.

	The message must be JSON-safe: strings, numbers, booleans, plain tables.
]]
function DataService.sendMessage(userId: number, message: { [string]: any }): boolean
	return store:MessageAsync(tostring(userId), message)
end

return DataService
