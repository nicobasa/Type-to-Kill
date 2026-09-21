--!strict
--[[
	Where a player comes back, and how long they are safe once they get there.

	Three jobs that only look separable: picking a spawn point, scheduling the
	respawn that sends someone to one, and holding the protection window that
	starts the moment they land. They share one set of per-player tables and
	one cancellation problem, and splitting them across two services would mean
	two files racing to decide whether a player who left mid-killcam still has
	a timer pointed at them.

	EVERY DELAYED THREAD IS CANCELLABLE. THAT IS THE WHOLE DESIGN.

	`task.delay(5, function() spawnPlayer(player) end)` is a closure that holds
	a Player for five seconds no matter what those five seconds contain. The
	player leaves; the round ends; they press LEAVE MATCH and walk back to the
	menu -- and it fires anyway, into a nil character or a finished round. So
	every delayed thread is stored per player and cancelled by whichever comes
	first: death, respawn, despawn, round end, or leaving. Each thread clears
	its OWN table entry as its first statement, before it can yield, which is
	what keeps the tables' invariant true: a thread still in a table is
	suspended, so task.cancel on it is always legal.

	PROTECTION IS A DEADLINE, NOT A FLAG.

	isProtected() compares workspace:GetServerTimeNow() against a stored
	expiry; the timer's only job is to drop the entry. A boolean cleared by a
	timer is protection that lasts exactly as long as the scheduler is late,
	and KillService refuses kills on the strength of this answer -- the thing
	deciding whether a kill counts should be arithmetic, not scheduling luck.

	DEATHS THIS SERVICE DID NOT CAUSE.

	Most deaths arrive through onDeath(), called by KillService once a code
	lands. The rest -- a void fall, a dev command, anything that zeroes a
	Humanoid -- arrive through Humanoid.Died, and they need the identical
	cleanup: release the code, mark not alive, put the player back. Both
	funnel into one handler guarded by livingCharacter[player], which is
	cleared before any of the work happens. Whichever path arrives first does
	the cleanup and the second returns immediately, so one death can never
	hand out two respawn timers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CodeService = require(script.Parent.CodeService)
local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local MapService = require(script.Parent.MapService)
local Match = require(ReplicatedStorage.Shared.Match)
local RoundService = require(script.Parent.RoundService)
local TeamService = require(script.Parent.TeamService)

--[[
	Deferred, because ParticipantService calls spawnPlayer() on us: a direct
	require at the top of both files is a genuine cycle. The annotation is
	erased at runtime (ARCHITECTURE.md, "Using another module"), so the only
	require that exists is the one in Init(), by which point every module body
	has already run.
]]
local ParticipantService: typeof(require(script.Parent.ParticipantService)) = nil :: any

local log = Log.new("SpawnService")

--[[
	A spawn part's CFrame is its CENTRE, and the authoring contract
	(Shared/Tags.luau) lets a map use a thin plate or a full block for one. A
	pivot placed exactly on that CFrame puts the character's midpoint inside
	the geometry, where the physics solver resolves the overlap by flinging
	them somewhere unpredictable. Four studs up drops them onto the pad
	instead, and is small enough not to be read as a fall.
]]
local SPAWN_HEIGHT_OFFSET = 4

-- The character that is currently alive for this player, and the guard that
-- makes death handling idempotent across onDeath() and Humanoid.Died.
local livingCharacter: { [Player]: Model? } = {}
local diedConnections: { [Player]: RBXScriptConnection? } = {}

-- Absolute workspace:GetServerTimeNow() at which protection ends, and the
-- thread that drops the entry. Both are cleared together, always.
local protectedUntil: { [Player]: number } = {}
local protectionThreads: { [Player]: thread } = {}

local respawnThreads: { [Player]: thread } = {}

--[[
	Present only across the LoadCharacterAsync yield: `true` while that spawn is
	still wanted, `false` once something cancelled it mid-yield, absent when no
	spawn is in flight.

	Two jobs. The first is the re-entry guard -- two overlapping spawns for one
	player, a respawn timer firing while ParticipantService is spawning them by
	hand, would build two characters, leave a Died connection on the one Roblox
	discards, and grant protection twice.

	The second is why it is not a plain flag. LoadCharacterAsync is the only yield in
	this service, and a despawn, a leave or a round end landing inside it has no
	thread to cancel -- that spawn is a live call stack, not a task.delay. So
	the cancellation is recorded here and the half of spawnPlayer that runs
	after the yield reads it. Without that, LEAVE MATCH pressed while the
	character was still loading is answered by the player being spawned anyway,
	alive and Playing, a frame after they asked for the menu.
]]
local spawning: { [Player]: boolean } = {}

local SpawnService = {}

local function cancelProtection(player: Player)
	protectedUntil[player] = nil
	local thread = protectionThreads[player]
	if thread ~= nil then
		-- Removed before the cancel, not after: the table must never name a
		-- thread that is already finished.
		protectionThreads[player] = nil
		task.cancel(thread)
	end
end

local function cancelRespawn(player: Player)
	local thread = respawnThreads[player]
	if thread ~= nil then
		respawnThreads[player] = nil
		task.cancel(thread)
	end
end

--[[
	Withdraw a spawn that is currently inside its LoadCharacterAsync yield.

	Marked rather than removed: leaving the entry present keeps the re-entry
	guard refusing new spawns until the cancelled one has finished unwinding,
	so there is still never more than one LoadCharacterAsync in flight per player.
]]
local function cancelSpawn(player: Player)
	if spawning[player] ~= nil then
		spawning[player] = false
	end
end

--[[
	Forget the life a player is currently living: the death guard, the Died
	connection and the protection window. Called before every new spawn, on
	every death, on despawn and on leave -- the one place that knows the full
	list, so no caller has to remember it.

	Disconnecting explicitly rather than leaning on Destroy() matters here:
	LoadCharacterAsync() replaces the old character, and a Died that fires out of
	that teardown would otherwise be handled as a real death and schedule a
	respawn for a player who is already being spawned.
]]
local function clearLife(player: Player)
	livingCharacter[player] = nil

	local connection = diedConnections[player]
	if connection ~= nil then
		diedConnections[player] = nil
		connection:Disconnect()
	end

	cancelProtection(player)
end

--[[
	Everyone who could shoot back, as positions. Teammates are deliberately
	absent: in Team Deathmatch a teammate standing on a spawn is cover, not a
	reason to spawn somewhere else, and counting them would push players away
	from their own half of the map.
]]
local function livingEnemyPositions(player: Player): { Vector3 }
	local positions: { Vector3 } = {}
	local usesTeams = RoundService.getMode().UsesTeams
	local team = TeamService.getTeam(player)

	for _, other in ParticipantService.getPlaying() do
		if other == player then
			continue
		end
		if usesTeams and team ~= nil and TeamService.getTeam(other) == team then
			continue
		end

		local character = other.Character
		if character == nil then
			continue
		end
		-- A corpse that has not been cleaned up yet is not a threat, and
		-- treating it as one would make the spawn around it unusable for the
		-- whole killcam.
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil or humanoid.Health <= 0 then
			continue
		end

		table.insert(positions, character:GetPivot().Position)
	end

	return positions
end

local function isClear(spawnPart: BasePart, enemies: { Vector3 }): boolean
	local position = spawnPart.Position
	for _, enemy in enemies do
		if (enemy - position).Magnitude <= Config.Spawn.EnemyAvoidRadius then
			return false
		end
	end
	return true
end

--[[
	"Red" | "Blue" | "FFA", the vocabulary MapService.getSpawns speaks.

	A Team Deathmatch player with no team should not reach here --
	ParticipantService only spawns them after TeamService.assign succeeds --
	but FFA is the honest fallback rather than an error: MapService already
	falls back to FFA spawns for a map that tagged no team spawns, so this
	stays consistent with it, and a missing team must never mean "no spawn".
]]
local function spawnKind(player: Player): string
	if not RoundService.getMode().UsesTeams then
		return "FFA"
	end
	local team = TeamService.getTeam(player)
	return if team ~= nil then team else "FFA"
end

--[[
	Prefer a spawn with no living enemy inside Config.Spawn.EnemyAvoidRadius,
	but return SOMETHING whenever the map has any spawn at all. A crowded map
	will regularly have no clear spawn left, and refusing to spawn is a far
	worse outcome than spawning in view of someone.

	The fallback is random rather than "furthest from the nearest enemy",
	which would be the better-looking choice and the worse one: a deterministic
	rule is a rule the room learns, and a lobby that knows exactly which corner
	a contested spawn resolves to has been handed a camping spot by the
	algorithm. Random keeps it unguessable.
]]
local function selectSpawn(player: Player): BasePart?
	local spawns = MapService.getSpawns(spawnKind(player))
	if #spawns == 0 then
		return nil
	end

	local enemies = livingEnemyPositions(player)
	local clear: { BasePart } = {}
	for _, part in spawns do
		if isClear(part, enemies) then
			table.insert(clear, part)
		end
	end

	local pool = if #clear > 0 then clear else spawns
	return pool[math.random(#pool)]
end

--[[
	Declared here and defined below, because the three of them form a ring:
	spawnPlayer arms the Died connection that calls handleDeath, handleDeath
	asks scheduleRespawn for a timer, and that timer calls spawnPlayer again.
	One of the three has to be named before it exists; a local that is nil
	until the module body finishes is the cheap end of that ring, since the
	only thing that reads it is a signal handler, and no signal can fire while
	the body is still running.
]]
local handleDeath: (victim: Player, killer: Player?) -> ()

--[[
	Load a character, put it on a spawn, protect it, then make it killable.

	Returns false without touching the player when there is nothing to spawn
	onto. That refusal is deliberate: LoadCharacterAsync with no spawn to pivot to
	drops someone at the world origin, which on a map authored a kilometre
	away is an endless fall the player cannot escape without rejoining.
]]
function SpawnService.spawnPlayer(player: Player): boolean
	if player.Parent ~= Players then
		return false
	end
	if spawning[player] ~= nil then
		log.debug(`spawnPlayer({player.Name}) while a spawn is already in flight -- refused`)
		return false
	end
	if not MapService.isLoaded() then
		log.warn(`spawnPlayer({player.Name}) with no map loaded -- refused`)
		return false
	end

	-- Chosen before the character is built, so a map with no usable spawns
	-- costs nothing and leaves the player where they were.
	local spawnPart = selectSpawn(player)
	if spawnPart == nil then
		log.error(`no spawn points of kind {spawnKind(player)} in map {MapService.getActiveMapId()} -- cannot spawn`)
		return false
	end

	-- Retire the previous life BEFORE LoadCharacterAsync destroys its character,
	-- or the Died that teardown can raise is handled as a real death.
	cancelRespawn(player)
	clearLife(player)

	--[[
		LoadCharacterAsync yields, and a player who leaves inside that window
		makes it raise. Luau has no finally, so the in-flight flag is released
		immediately after the pcall on both paths (quality-gate.md, Gate 2).
	]]
	spawning[player] = true
	local ok = pcall(function()
		player:LoadCharacterAsync()
	end)
	-- Read before the entry is dropped: whatever cancelled this spawn while it
	-- was yielding left its answer in the table, and the table is about to go.
	local cancelled = spawning[player] ~= true
	spawning[player] = nil

	if not ok then
		log.warn(`LoadCharacterAsync() failed for {player.Name} -- spawn abandoned`)
		return false
	end

	if cancelled then
		--[[
			The character LoadCharacterAsync just built belongs to nobody. Left
			standing it is a body in the map with no code, no protection and no
			Died connection: unkillable, unscorable, and invisible to every
			sweep this service does, because livingCharacter never learned
			about it.
		]]
		local orphan = player.Character
		if orphan ~= nil then
			orphan:Destroy()
			player.Character = nil
		end
		log.debug(`spawn for {player.Name} was cancelled while its character loaded -- discarded`)
		return false
	end

	local character = player.Character
	if character == nil or player.Parent ~= Players then
		log.warn(`{player.Name} left while their character was loading -- spawn abandoned`)
		return false
	end

	-- The part's CFrame carries the facing as well as the position (Tags.luau
	-- authoring contract), so the offset is added to the translation and the
	-- rotation is kept exactly as the map author dragged it.
	character:PivotTo(spawnPart.CFrame + Vector3.new(0, SPAWN_HEIGHT_OFFSET, 0))

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		diedConnections[player] = humanoid.Died:Connect(function()
			handleDeath(player, nil)
		end)
	else
		-- Nothing else in the game notices a death, so say so loudly rather
		-- than leaving a player who can never respawn.
		log.error(`{player.Name} spawned with no Humanoid -- deaths will not be detected`)
	end
	livingCharacter[player] = character

	--[[
		Protection first, THEN the code. Until CodeService has assigned one
		there is nothing for a killer to type, so this ordering closes the
		window between a character existing and being covered. The reverse
		order opens one, and it opens it at exactly the moment the player is
		least able to react -- still loading in.
	]]
	protectedUntil[player] = workspace:GetServerTimeNow() + Config.Spawn.ProtectionDuration
	protectionThreads[player] = task.delay(Config.Spawn.ProtectionDuration, function()
		protectionThreads[player] = nil
		protectedUntil[player] = nil
	end)

	CodeService.assign(player)
	RoundService.writePlayer(player, { Alive = true })
	ParticipantService.setPhase(player, "Playing")
	return true
end

local function scheduleRespawn(player: Player)
	cancelRespawn(player)

	--[[
		Config.Killcam.Duration, not a local constant: KillService puts this
		same number into the `respawnAt` of the Net.killed packet the victim's
		countdown is drawn from. Two copies of it is a countdown that reaches
		zero while the player is still watching a corpse.
	]]
	respawnThreads[player] = task.delay(Config.Killcam.Duration, function()
		-- First statement, before anything that can yield: a running thread
		-- must not be reachable from the table that cancel() reads.
		respawnThreads[player] = nil

		if player.Parent ~= Players then
			return
		end
		-- Re-checked rather than trusted: the round can end and a player can
		-- walk back to the menu inside the killcam, and the listener that
		-- cancels for the first of those cannot see the second.
		if RoundService.getState() ~= "RoundActive" or not ParticipantService.isInRound(player) then
			return
		end

		SpawnService.spawnPlayer(player)
	end)
end

--[[
	The single death path. `killer` is used for the log line and nothing else
	-- KillService has already recorded the kill, paid the reward and sent the
	kill card by the time it calls us, so if Humanoid.Died happens to win the
	race and arrives with no killer, the only thing lost is a name in a debug
	line, not attribution.
]]
function handleDeath(victim: Player, killer: Player?)
	if livingCharacter[victim] == nil then
		-- Already handled through the other entry point. Returning here is
		-- what stops one death producing two respawn timers.
		return
	end
	clearLife(victim)

	-- The code dies with the character. A code left live is one a killer can
	-- keep submitting at a corpse, and it holds an entry out of CodeService's
	-- pool for a player who is about to be issued a fresh one anyway.
	CodeService.release(victim)
	RoundService.writePlayer(victim, { Alive = false })

	local attribution = if killer ~= nil then killer.Name else "no killer"
	if victim.Parent ~= Players or not ParticipantService.isInRound(victim) then
		log.debug(`{victim.Name} died ({attribution}) while out of the round -- no respawn`)
		return
	end
	if RoundService.getState() ~= "RoundActive" then
		log.debug(`{victim.Name} died ({attribution}) outside RoundActive -- no respawn`)
		return
	end

	-- Killcam, not Menu: they are still in the round, still hold a scoreboard
	-- row and are still owed the respawn scheduled on the next line.
	ParticipantService.setPhase(victim, "Killcam")
	scheduleRespawn(victim)
end

--[[
	Take a player out of the world without scheduling anything.

	Deliberately does NOT touch the phase. ParticipantService.leaveMatch owns
	that transition and calls this as one of its steps; a despawn that also
	wrote a phase would be a second writer fighting the owner, and would be
	plain wrong for any future caller that despawns without ending the match.
]]
function SpawnService.despawn(player: Player)
	cancelRespawn(player)
	-- Before clearLife, because a spawn caught inside LoadCharacterAsync has no
	-- thread to cancel and would otherwise finish and undo everything below it.
	cancelSpawn(player)
	clearLife(player)
	CodeService.release(player)

	local character = player.Character
	if character ~= nil then
		-- Destroy, not Parent = nil: a parked character keeps its connections
		-- and its Humanoid alive, so it stays in every GetPlayers-style sweep
		-- as a living body nobody can see (quality-gate.md, Gate 2).
		character:Destroy()
		-- Roblox leaves Player.Character pointing at the destroyed model.
		-- Anything that asks "do they have a character?" -- CodeService does --
		-- would get a yes about a model that is not in the world.
		player.Character = nil
	end

	RoundService.writePlayer(player, { Alive = false })
end

function SpawnService.isProtected(player: Player): boolean
	local expiry = protectedUntil[player]
	return expiry ~= nil and workspace:GetServerTimeNow() < expiry
end

--[[
	Called by KillService once a submitted code has actually landed. Every
	other death reaches the same handler through Humanoid.Died.
]]
function SpawnService.onDeath(victim: Player, killer: Player?)
	handleDeath(victim, killer)
end

function SpawnService.Init()
	ParticipantService = require(script.Parent.ParticipantService)

	--[[
		The subscription side of onStateChanged. RoundService does not know
		this service exists, which is the point: a round loop that reached into
		eight services by name is one nobody can add a ninth to.

		Leaving RoundActive drops every timer. Nobody respawns into
		RoundResults, and protection in a round that is over protects against
		nothing -- but the thread would still fire, into a player who may have
		left in between. The in-flight spawn is withdrawn for the same reason
		and one more: MapService.unload is about to destroy the very part that
		spawn already picked to pivot onto.
	]]
	RoundService.onStateChanged(function(state: Match.MatchState, previous: Match.MatchState)
		if previous ~= "RoundActive" or state == "RoundActive" then
			return
		end
		-- Over GetPlayers() rather than over the timer tables themselves:
		-- both cancels clear the key they are handed, and clearing a table
		-- while iterating it is the kind of thing that works until the day a
		-- rehash moves something. Nobody can hold a timer without being in
		-- Players, since PlayerRemoving drops them.
		for _, player in Players:GetPlayers() do
			cancelRespawn(player)
			cancelProtection(player)
			cancelSpawn(player)
		end
	end)

	--[[
		Every per-player table this service owns is cleared here:
		livingCharacter and diedConnections (via clearLife), protectedUntil and
		protectionThreads (via cancelProtection inside it), respawnThreads and
		spawning. A {[Player]: T} that outlives the player is a reference to
		everyone who was ever in the server.

		`spawning` is dropped outright rather than marked through cancelSpawn:
		there is nothing left to guard against a second spawn for a player who
		is gone, and the entry must not survive on the chance that the spawn
		thread never resumes to clear it itself. An absent entry still reads as
		cancelled to that thread, which is the answer we want either way.
	]]
	Players.PlayerRemoving:Connect(function(player: Player)
		cancelRespawn(player)
		clearLife(player)
		spawning[player] = nil
	end)
end

function SpawnService.Start()
	log.info("ready")
end

return SpawnService
