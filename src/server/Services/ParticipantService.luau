--!strict
--[[
	Who is in the match, and how they got there.

	This service owns exactly one piece of state -- each player's
	Match.PlayerPhase -- and the three packets that move it: PLAY, pick a team,
	leave. Everything else it does is delegation: SpawnService puts a character
	in the world, TeamService decides which side may take it, CodeService and
	LoadoutService hand out and take back what a living player carries.

	WHY PHASE LIVES HERE AND NOWHERE ELSE

	Phase is per-player and the match state is global (Match.luau explains why
	TeamSelect is not a MatchState). A late joiner walks Menu -> TeamSelect ->
	Playing while the round sits in RoundActive throughout, so "is this player
	in the round" cannot be derived from the round -- it has to be stored. One
	writer stores it, and that same writer mirrors it into the round replica on
	the same line, because the client's menu, scoreboard row and PLAY button
	are all drawn from the replica: a phase that is correct in a server table
	and stale in the replica is a player looking at a menu the server left.

	WHY NOBODY SPAWNS UNTIL THEY PRESS PLAY

	Players.CharacterAutoLoads is turned off in Init(). With it on, a joining
	player is dropped into Workspace immediately -- into empty space when no map
	is loaded, or into a live round with no team, no kill code and no spawn
	protection, which is a free kill for whoever is standing there. PLAY is the
	only thing that puts a character in the world.

	WHY leaveMatch IS THE ONLY TEARDOWN PATH

	Leaving the menu, the round ending, a failed spawn and disconnecting all
	have to undo the same four things. Four copies of that list is three chances
	to forget the one that leaks -- a code never returned to the pool, or a team
	slot that stays counted forever and locks the other side out. There is one
	list, and it is idempotent, so calling it on a player who is already in the
	menu costs nothing and is never wrong.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CodeService = require(script.Parent.CodeService)
local Config = require(ReplicatedStorage.Shared.Config)
local LevelService = require(script.Parent.LevelService)
local LoadoutService = require(script.Parent.LoadoutService)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)
local SpawnService = require(script.Parent.SpawnService)
local TeamService = require(script.Parent.TeamService)

local log = Log.new("ParticipantService")

--[[
	Three limiters, not one shared table. PLAY and LEAVE are the same physical
	button in two states, so a single limiter across both would swallow the
	LEAVE of a player who just pressed PLAY by mistake -- the one moment they
	most want it to work. They are tuned from the same Config value because
	they cost the same to serve; sharing the NUMBER is the intent, sharing the
	timestamp is not.
]]
local playLimit = RateLimiter.new(Config.RateLimit.JoinRequest)
local leaveLimit = RateLimiter.new(Config.RateLimit.JoinRequest)
local teamLimit = RateLimiter.new(Config.RateLimit.TeamRequest)

--[[
	The states in which PLAY means something.

	Outside them there is either no map loaded (Lobby, Voting, MapLoading) or
	one about to be unloaded (RoundResults), so a spawn would either fail or
	drop the player through the world a second before the map is destroyed
	under them.
]]
local JOINABLE_STATES: { [Match.MatchState]: boolean } = {
	WaitingToPlay = true,
	RoundActive = true,
}

local ParticipantService = {
	--[[
		Init order only. Below RoundService (60), because addPlayerEntry and
		onStateChanged both need the round replica to already exist; above the
		services that read a phase, so nobody's Init sees an empty roster.
	]]
	Priority = 40,
}

local phases: { [Player]: Match.PlayerPhase } = {}

--[[
	Players with a spawn in flight. SpawnService.spawnPlayer yields on
	LoadCharacter, and the rate-limit floor (half a second) is shorter than
	that yield can be, so two accepted PLAY packets can overlap. Without this
	flag the second one spawns a character on top of the first, refunding spawn
	protection and teleporting the player out of a fight they were losing.

	It doubles as the cancellation token for a spawn that is overtaken by a
	leave or a disconnect -- see spawnInto.
]]
local spawning: { [Player]: boolean } = {}

--[[
	This player's phase. "Menu" for a player this service has not seen yet,
	which is the truthful answer rather than a fallback: CharacterAutoLoads is
	off, so a player with no entry here has no character and is looking at the
	menu.
]]
function ParticipantService.getPhase(player: Player): Match.PlayerPhase
	--[[
		`phases[player] or "Menu"` would type as PlayerPhase | string and fail
		the annotation: a string literal only keeps its singleton type where an
		expected type reaches it, and the branches of an if-expression are
		checked against the return type. Match.opposingTeam is spelled this way
		for the same reason.

		The local is annotated rather than inferred for the other half of it:
		refining an inferred PlayerPhase against nil widens it back to plain
		`string`, and the "Menu" branch then has nothing to keep it singleton.
	]]
	local phase: Match.PlayerPhase? = phases[player]
	return if phase ~= nil then phase else "Menu"
end

--[[
	The ONLY writer of PlayerPhase, server-side and in the replica both.

	Callers outside this file are the services that own the events a phase
	follows from -- SpawnService moving a killed player to "Killcam", for
	instance. They set the phase; they never write Players[key].Phase
	themselves, or the two would drift the first time one of them was skipped.
]]
--[[
	This player's level, or 1 if their profile has not loaded yet.

	RoundService.addPlayerEntry seeds the scoreboard row with a placeholder 1
	and says, correctly, that the spine is the wrong file to grow a LevelService
	require. This is the right file: ParticipantService already owns every write
	to a player's row, and LevelService is a leaf (it depends on DataService and
	nothing else), so the edge adds no cycle to route around.

	Without this, Level is 1 for everybody forever -- which is not a cosmetic
	miss. Net.killed carries the killer's level to the victim's kill card, so
	every card in the game would read "LEVEL 1" no matter who did the killing.

	Falling back to 1 rather than skipping the write is deliberate: getLevel is
	nil for the seconds between joining and the profile session starting, and
	the refresh on the next phase change corrects it. A skipped write would
	leave the same placeholder anyway, and cost a branch at every call site.
]]
local function currentLevel(player: Player): number
	return LevelService.getLevel(player) or 1
end

function ParticipantService.setPhase(player: Player, phase: Match.PlayerPhase)
	--[[
		The invariant `phases` has to hold is that it never outlives the player,
		and this is the one line that can break it: every interesting caller
		sets a phase on the far side of a yield (LoadCharacter here, the killcam
		timer in SpawnService), and PlayerRemoving may have run in between. The
		entry it cleared would be written straight back, and nothing clears it a
		second time -- a reference to a Player who left, held for the life of the
		server (rule 7).

		Enforced at the writer rather than at each call site, because a call
		site added next year is exactly the one that will forget. PlayerRemoving
		still gets its write: the Player is still parented to Players while that
		event runs, which is also why GetPlayers() still lists them there.
	]]
	if player.Parent ~= Players then
		return
	end

	if phases[player] == phase then
		-- Re-asserting a phase would cost a replication packet to change
		-- nothing, and the Lobby sweep below re-asserts "Menu" for everyone
		-- once a round.
		return
	end
	phases[player] = phase

	--[[
		A player who has already left has no row, and Replica's SetValues walks
		the path and indexes nil rather than no-opping. RoundService.writePlayer
		guards that case itself today, so this check is belt and braces -- kept
		because the case is real rather than theoretical (PlayerRemoving runs
		leaveMatch, which sets "Menu") and because reading the entry costs a
		table lookup, not a packet.
	]]
	if RoundService.getPlayerEntry(player) ~= nil then
		RoundService.writePlayer(player, { Phase = phase, Level = currentLevel(player) })
	end
end

function ParticipantService.isPlaying(player: Player): boolean
	return ParticipantService.getPhase(player) == "Playing"
end

--[[
	In the round in the sense that matters for scoring and respawning: a dead
	player watching the killcam still holds a scoreboard row and is owed a
	respawn, so they are emphatically not "in the menu". Use this, not
	isPlaying, to decide whether someone may be handed the PLAY button.
]]
function ParticipantService.isInRound(player: Player): boolean
	local phase = ParticipantService.getPhase(player)
	return phase == "Playing" or phase == "Killcam"
end

--[[
	Everyone in the "Playing" phase. Phase, not liveness -- a player between
	Humanoid.Died and the phase move to "Killcam" is still here, so a caller
	that needs a character checks for one itself.

	Built from Players:GetPlayers() rather than by iterating the phase table:
	that gives a stable order (pairs() over a table keyed by instances does
	not, and a scoreboard that reshuffles itself every frame is a bug), and it
	cannot return a player who has left.
]]
function ParticipantService.getPlaying(): { Player }
	local playing: { Player } = {}
	for _, player in Players:GetPlayers() do
		if phases[player] == "Playing" then
			table.insert(playing, player)
		end
	end
	return playing
end

--[[
	Take a player out of the match and back to the menu. Idempotent.

	Everything a living player holds is server-owned and must be handed back:
	the character, the kill code (it returns to the free pool), the toolbar,
	and the team slot that would otherwise stay counted and lock the other side
	out of joining.
]]
function ParticipantService.leaveMatch(player: Player)
	--[[
		Phase first, deliberately. Destroying a character can run SpawnService's
		Humanoid.Died path, and that path asks this service whether the player
		is still in the round before scheduling a respawn. Answering "Playing"
		there respawns the player we are in the middle of removing.
	]]
	ParticipantService.setPhase(player, "Menu")
	-- Also the cancellation signal for a spawn still inside LoadCharacter.
	spawning[player] = nil

	SpawnService.despawn(player)
	CodeService.release(player)
	LoadoutService.clear(player)
	TeamService.clear(player)
	-- The row's Team is a mirror of TeamService's roster, and each write to one
	-- needs the matching write to the other. A player who left and stayed
	-- counted in the replica would keep the team select screen showing a
	-- player who is gone.
	RoundService.writePlayer(player, { Team = "" })
end

--[[
	leaveMatch, with a throw from one of the four services it delegates to kept
	off the caller.

	Its two callers are a sweep over every player and the tail of a disconnect,
	and in both the work AFTER the call is the work that must not be skipped:
	the remaining players in the sweep, and the row and table deletions that
	stop a departed Player being referenced for the rest of the session. One
	player's bug stranding everyone else's code and team slot is a worse
	failure than the bug itself.

	Still loud, not swallowed: log.error goes to stderr, which is where an
	unhandled throw would have gone (Shared/Log.luau).

	xpcall rather than pcall, for the reason Loader.luau:144 uses it on the
	same shape: leaveMatch returns nothing, so `local ok, err = pcall(...)`
	asks a `(Player) -> ()` for a second value it does not have. The handler
	supplies one -- and a traceback is what makes a report like this worth
	reading anyway.

	The locals are annotated because the checker models xpcall's result as
	(boolean, <the protected function's returns>) and cannot see the handler:
	leaveMatch returns nothing, so unannotated it reports a one-value call
	being destructured into two. `err` is the traceback on failure, nil on
	success.
]]
local function leaveMatchSafely(player: Player)
	local ok: boolean, err: string? = xpcall(ParticipantService.leaveMatch, debug.traceback, player)
	if not ok then
		log.error(`leaveMatch failed for {player.Name} -- {err}`)
	end
end

--[[
	Put the player in the world and finish the join, or undo it and say why.

	Yielding here is safe -- ByteNet runs every listener on its own thread
	(bytenet/src/process/read.luau, runListener), so a yield blocks nothing but
	this packet. It is not safe to TRUST anything across it: LoadCharacter can
	take longer than the round has left, and the player may leave or press the
	menu button while it runs. Every condition the decision rested on is
	re-checked on the far side.
]]
local function spawnInto(player: Player)
	spawning[player] = true
	--[[
		pcall, and not for tidiness. Luau has no finally, so a throw anywhere
		inside LoadCharacter would leave this player's in-flight flag set for
		the rest of the session -- and that flag is what gates their PLAY
		button, so the one player who hit the bug could never join again. A
		spawn that threw and a spawn that returned false are handled
		identically: back to a menu they can press PLAY on.
	]]
	local ok, result = pcall(SpawnService.spawnPlayer, player)
	local spawned = ok and result
	if not ok then
		log.error(`spawnPlayer threw for {player.Name} -- {result}`)
	end

	--[[
		leaveMatch and PlayerRemoving both clear this flag. If it is gone, that
		teardown ran while we were yielding and this join is cancelled.

		The undo is the WHOLE teardown and not a bare despawn, because what
		spawnPlayer managed before we were resumed is not knowable from here:
		it finishes by assigning a kill code and setting the phase to
		"Playing", and whether it got that far -- or noticed the cancellation
		and unwound itself -- is the race we just lost. leaveMatch is
		idempotent, so running it over a teardown that already completed costs
		a handful of table writes. NOT running it over one that was overwritten
		leaves a characterless player reading "Playing" to everything that asks
		-- getPlaying, their scoreboard row, and the enemy positions the next
		player's spawn is chosen away from.

		A player who has LEFT takes the narrow path instead. Their phase entry
		is already gone (PlayerRemoving), their code was never issued, and the
		only thing that can still be outstanding is a character LoadCharacter
		built on the way out -- which is exactly and only what despawn removes.
	]]
	if spawning[player] == nil then
		if player.Parent == Players then
			ParticipantService.leaveMatch(player)
		else
			SpawnService.despawn(player)
		end
		return
	end
	spawning[player] = nil

	if player.Parent ~= Players then
		return
	end

	if not spawned then
		--[[
			A full teardown rather than just a phase reset: in Team Deathmatch
			the team slot has already been taken by the time we get here, and
			leaving it taken on a failed spawn is how a server ends up unable to
			start a round it has room for.
		]]
		log.warn(`spawn failed for {player.Name} -- returned to the menu`)
		ParticipantService.leaveMatch(player)
		Net.notice.sendTo({ kind = "Error", message = "COULD NOT FIND A SPAWN" }, player)
		return
	end

	if not JOINABLE_STATES[RoundService.getState()] then
		-- The round ended inside LoadCharacter. The Lobby sweep has already run
		-- for everyone else, so this player would be the only one left standing
		-- in a map that is about to be destroyed.
		ParticipantService.leaveMatch(player)
		return
	end

	--[[
		A no-op on the happy path: spawnPlayer sets this itself the moment the
		character is protected, which is the right moment -- a phase written
		here instead would be one yield late, and "Playing" is what tells
		KillService the player may be shot at. It is asserted anyway because
		this function, not SpawnService, is what the rest of the file reasons
		about: a join that reaches this line and is not "Playing" is a bug, and
		setPhase makes the assertion free when it is already true.
	]]
	ParticipantService.setPhase(player, "Playing")
end

local function onRequestPlay(player: Player)
	if not JOINABLE_STATES[RoundService.getState()] then
		--[[
			The client greys PLAY out in these states too, but that is
			presentation. This is the enforcement, and it answers rather than
			dropping: the player pressed a button and is owed a reason.
		]]
		Net.notice.sendTo({ kind = "Warn", message = "WAIT FOR THE NEXT ROUND" }, player)
		return
	end

	-- Already in, or already on the way in. Silent: a duplicate PLAY is a
	-- double-click or an exploiter, and neither is owed a packet back.
	if ParticipantService.isInRound(player) or spawning[player] then
		return
	end

	--[[
		The whole teams/FFA fork, read off the mode rather than compared against
		a mode id (Match.TeamMode.UsesTeams exists for exactly this). A team
		mode gets no character yet -- the client draws the team screen from
		this phase and answers with requestTeam.
	]]
	if RoundService.getTeamMode().UsesTeams then
		ParticipantService.setPhase(player, "TeamSelect")
		return
	end

	spawnInto(player)
end

local function onRequestTeam(player: Player, team: string)
	if not JOINABLE_STATES[RoundService.getState()] then
		Net.notice.sendTo({ kind = "Warn", message = "WAIT FOR THE NEXT ROUND" }, player)
		return
	end

	-- Free For All has no team screen, so nothing legitimate sends this.
	local mode = RoundService.getTeamMode()
	if not mode.UsesTeams then
		return
	end

	--[[
		Meaning, not shape: ByteNet has already proved `team` is a string, and
		this proves it is the player's turn to send one. Without it a player
		already Playing could re-pick a team mid-round and respawn at will,
		which is a teleport with extra steps.
	]]
	if ParticipantService.getPhase(player) ~= "TeamSelect" or spawning[player] then
		return
	end

	--[[
		One of THIS round's sides, not merely a team that exists. Green is a
		real team; in a two-team round it is still not one anybody may join,
		and a client without a Green button is no defence against a client that
		sends "Green" anyway. TeamService.assign checks the same list again.
	]]
	if not Match.modeHasTeam(mode, team) then
		return
	end
	-- modeHasTeam is a runtime guard, not a type predicate -- a boolean return
	-- narrows nothing in Luau, so the cast restates what the line above proved.
	-- The local is annotated as well, or the cast is discarded and teamId
	-- infers back to the `string` the packet handed us.
	local teamId: Match.TeamId = team :: Match.TeamId

	--[[
		assign re-runs the balance check itself, at this instant. Asking
		canJoin here and then assigning would be the classic check-then-act
		race: two players pressing RED in the same frame would both see room
		and both take it.
	]]
	if not TeamService.assign(player, teamId, mode.Teams) then
		Net.notice.sendTo({ kind = "Warn", message = `{Match.TEAMS[teamId].DisplayName} TEAM IS FULL` }, player)
		return
	end

	--[[
		player.Team is not enough. The team select screen counts sides from
		the round replica (TeamSelectController.countSides), and nothing else
		writes Team into it. Without this every row stayed at the "" that
		addPlayerEntry seeds, and both buttons read 0 PLAYERS however many
		people had picked.
	]]
	RoundService.writePlayer(player, { Team = teamId })

	spawnInto(player)
end

local function onRequestLeaveMatch(player: Player)
	-- Nothing to leave. The spawning check matters: in Free For All the phase
	-- is still "Menu" while LoadCharacter runs, and that is precisely the join
	-- a player wants to be able to cancel.
	if ParticipantService.getPhase(player) == "Menu" and spawning[player] == nil then
		return
	end
	ParticipantService.leaveMatch(player)
end

local function onPlayerAdded(player: Player)
	-- Start() sweeps players who were already here when Init() connected the
	-- signal, so a player who joins in that window arrives twice.
	if phases[player] ~= nil then
		return
	end

	--[[
		Row first, phase second: setPhase mirrors into the row and skips the
		write when there is none, so the reverse order would leave the replica
		saying whatever addPlayerEntry defaulted to. The redundant write that
		costs is deliberate -- reading a default out of another service is a
		coupling that breaks silently the day that default changes.
	]]
	--[[
		Shift lock OFF, per player, from the server -- the only side that may
		write it. A LocalScript attempting the same property throws "lacking
		capability RobloxScript".

		This is a gameplay decision, not a preference. Left Shift is the sprint
		key (UI/Binds.luau), so with shift lock available every sprint would
		also toggle the mouse into locked-centre third person: the camera mode
		flipping on and off in combat, bound to the one key a player holds most
		often. It also cannot coexist with the arms-only first person
		CameraController provides, since shift lock forces its own
		over-the-shoulder camera.
	]]
	player.DevEnableMouseLock = false

	RoundService.addPlayerEntry(player)
	ParticipantService.setPhase(player, "Menu")
end

local function onPlayerRemoving(player: Player)
	-- leaveMatch writes the row, so it has to run before the row is deleted.
	leaveMatchSafely(player)

	-- Our own tables before the replica row: these are the two that hold a
	-- reference to the departed Player, and nothing between here and the end
	-- of this function yields or reads a phase.
	phases[player] = nil
	spawning[player] = nil

	RoundService.removePlayerEntry(player)
end

function ParticipantService.Init()
	--[[
		In Init and not Start: Start()s are spawned in parallel and may yield,
		and a player who joins in that window with autoload still on has already
		been dropped into the world by the time we would have turned it off.
		Setting a property does not yield, so the no-yield rule is safe here.
	]]
	Players.CharacterAutoLoads = false

	--[[
		Keep the scoreboard row's Level honest when it changes mid-round.

		setPhase covers every other moment the number can go stale, because a
		phase change is the only other thing that happens to a player's row. The
		one gap left is a player who joins, never presses PLAY, and whose
		profile loads after their "Menu" phase was written: their row reads
		Level 1 until they play. Nothing in the UI draws a menu-only player's
		level, so that is a real but currently invisible gap rather than a bug
		being hidden -- and it closes itself the moment they enter a round.

		In Init, not Start: onLevelUp's own contract says listeners registered
		in a Start() can miss a level-up caused by a faster Start() elsewhere,
		and there is no replay (LevelService.luau).
	]]
	LevelService.onLevelUp(function(player: Player, level: number)
		if RoundService.getPlayerEntry(player) ~= nil then
			RoundService.writePlayer(player, { Level = level })
		end
	end)

	--[[
		The limiter runs before anything else in each handler, including the
		logging and the state read. A packet that is going to be dropped must
		cost the server nothing, or the limit is an amplifier rather than a
		defence (Modules/RateLimiter.luau).
	]]
	Net.requestPlay.listen(function(_, player)
		if player == nil then
			return
		end
		if not playLimit.allow(player) then
			return
		end
		onRequestPlay(player)
	end)

	Net.requestTeam.listen(function(data, player)
		if player == nil then
			return
		end
		if not teamLimit.allow(player) then
			return
		end
		onRequestTeam(player, data.team)
	end)

	Net.requestLeaveMatch.listen(function(_, player)
		if player == nil then
			return
		end
		if not leaveLimit.allow(player) then
			return
		end
		onRequestLeaveMatch(player)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	--[[
		Registered in Init, never Start: Start()s run in parallel, so a listener
		added there can miss a transition a faster Start() caused, and
		onStateChanged has no replay.
	]]
	RoundService.onStateChanged(function(state: Match.MatchState)
		if state ~= "Lobby" then
			return
		end
		--[[
			Lobby means the map is being unloaded. Everyone goes back to the
			menu -- unconditionally, including players already there, because
			leaveMatch is idempotent and a player who somehow still holds a code
			or a team slot is exactly the case a conditional sweep would skip.

			Per player and not one pcall around the loop: a throw on the third
			player must not strand the fourth in a round that no longer exists.
		]]
		for _, player in Players:GetPlayers() do
			leaveMatchSafely(player)
		end
	end)
end

function ParticipantService.Start()
	-- PlayerAdded does not fire for players already in Players when it was
	-- connected, which in Studio is every player in a solo test.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	log.info("ready")
end

return ParticipantService
