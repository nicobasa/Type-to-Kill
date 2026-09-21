--!strict
--[[
	The round: one Replica, one state machine, one thread that drives it.

	RoundService is the ONLY writer of the round replica. Everything else reads
	it -- clients through Replica, services through the getters below -- and
	asks this file to write on its behalf (writePlayer, writeScores,
	writeVote). One writer is what keeps the replica's shape reviewable in one
	place instead of it being whatever nine services happened to Set().

	WHY NOBODY IS RESET BY NAME

	This file does not know that ScoreService, CodeService, SpawnService or
	LoadoutService exist, and it must not learn. Each of them subscribes to
	onStateChanged in its own Init() and reacts to the phase it cares about. A
	loop that reached into eight services by name is a loop nobody can add a
	ninth service to -- and every one of those edges would be a require cycle
	waiting to happen, because most of those services already read getState().

	WHY THE LOOP IS IN Start() AND THE REST IN Init()

	Init() must not yield (Loader.luau:130) and the loop is nothing but
	yielding. So Init() does only the two things that must be in place before
	anyone else's Start() runs -- resolve the deferred VoteService require and
	connect PlayerRemoving -- and Start() runs the machine forever.

	WHY endRound() DOES NOT CHANGE THE STATE ITSELF

	It moves the deadline and lets the loop thread make the move, so
	RoundActive -> RoundResults has exactly one caller no matter how many kills
	land in the same frame. A cross-thread transition would need the loop to be
	woken and cancelled, which Luau gives you no safe way to do, and buys
	nothing: the phase ends within PHASE_POLL_INTERVAL either way.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local MapService = require(script.Parent.MapService)
local Match = require(ReplicatedStorage.Shared.Match)
local Replica = require(ServerStorage.ReplicaServer)

--[[
	Deferred on purpose. VoteService requires RoundService directly -- it reads
	getState() before accepting a vote -- so a plain require here would be a
	cycle, and Luau throws on those at load. The annotation is erased at
	runtime, so the types resolve and the cycle does not exist
	(ARCHITECTURE.md, "Using another module").
]]
local VoteService: typeof(require(script.Parent.VoteService)) = nil :: any

local log = Log.new("RoundService")

--[[
	How long the loop may oversleep a deadline. Deadlines are absolute, so this
	is only the granularity of NOTICING one. 0.1s is ~6000 wake-ups across a
	ten-minute round, which costs nothing, and it buys a results screen that
	appears on the winning kill rather than whenever a full-length task.wait
	happened to be scheduled to end.
]]
local PHASE_POLL_INTERVAL = 0.1

-- Pause after a cycle errors. Without it, a fault that reproduces immediately
-- turns the restart below into a hot loop that takes the server with it.
local ERROR_BACKOFF = 1

--[[
	Fired after a transition has been written and replicated, never before.
	`previous` is the state held before the move.
]]
export type StateListener = (state: Match.MatchState, previous: Match.MatchState) -> ()

type RoundData = {
	State: Match.MatchState,
	ModeId: Match.GameModeId,
	MapId: string,
	PhaseEndsAt: number,
	Scores: { Red: number, Blue: number },
	Vote: {
		MapChoices: { string },
		MapVotes: { [string]: number },
		ModeVotes: { [string]: number },
	},
	Players: { [string]: Match.RoundPlayer },
}

-- One token per replica kind, at module scope: Replica.Token errors on a
-- duplicate string (ReplicaServer.luau:260), and a module body runs exactly
-- once where a function makes no such promise.
local ROUND_TOKEN = Replica.Token(Match.REPLICA_TOKEN)

--[[
	The replica holds a REFERENCE to this table, not a copy (ARCHITECTURE.md
	line 133). So roundData IS what the clients are looking at: the getters
	read it directly with full types, and every write goes through
	roundReplica so that it also replicates. One copy of the truth, rather than
	a typed server-side mirror that drifts from the wire the first time someone
	forgets one of the two writes.
]]
local roundData: RoundData = {
	State = "Lobby",
	ModeId = Match.DEFAULT_MODE,
	MapId = "",
	PhaseEndsAt = 0,
	Scores = { Red = 0, Blue = 0 },
	Vote = { MapChoices = {}, MapVotes = {}, ModeVotes = {} },
	Players = {},
}

local roundReplica = Replica.New({
	-- Replica.Token() returns the correct object at runtime; ReplicaServer's
	-- bundled annotation asks for its internal token class rather than the
	-- returned instance, so the compatibility cast stays at this one call site
	-- (DataService.luau does the same for the same reason).
	Token = ROUND_TOKEN :: any,
	Data = roundData,
})

--[[
	Replicate(), not Subscribe(). This is the PUBLIC half of the game state and
	every present and future player needs all of it: someone who joins eight
	minutes into a round gets the timer, the mode, the scores and the
	scoreboard through the identical code path a founding player took. That is
	the whole reason the round is a replica and not a stream of packets
	(Net.luau, "WHAT IS NOT IN HERE").
]]
roundReplica:Replicate()

local stateListeners: { StateListener } = {}

-- Cleared on entering RoundActive, set by endRound(). Guards against a second
-- win check in the same round spending another replication packet on a
-- deadline that is already in the past.
local endRequested = false

local RoundService = {
	--[[
		Ordering insurance rather than a hard requirement: the getters and
		onStateChanged work from the module body onward, so a subscriber's
		Init() is safe whenever it runs. 60 keeps this above
		ParticipantService (40), which touches the player rows from its own
		Init(), and below DataService (100).
	]]
	Priority = 60,
}

local function writeDeadline(endsAt: number)
	roundReplica:Set({ "PhaseEndsAt" }, endsAt)
end

--[[
	Move to `state` and give the new phase `duration` seconds, or no deadline
	at all when `duration` is nil. Returns false if the move was refused.
]]
local function enter(state: Match.MatchState, duration: number?): boolean
	-- Annotated, not inferred: an inferred local widens MatchState's six
	-- singletons to plain `string`, and canTransition and every StateListener
	-- below take the union.
	local previous: Match.MatchState = roundData.State

	if not Match.canTransition(previous, state) then
		--[[
			Unreachable while runCycle is the only caller, which is exactly the
			point: this catches an edit that reorders the loop into a sequence
			Match's TRANSITIONS table does not describe, rather than
			replicating it to every client and leaving the reader to work out
			which of the two is wrong. The caller abandons the cycle; the next
			one starts at Lobby, which is reachable from every state.
		]]
		log.error(`refusing illegal transition {previous} -> {state}`)
		return false
	end

	--[[
		0 means "no deadline" to the client, never "already over". Anything
		with a duration carries an ABSOLUTE server time: a remaining-seconds
		field would cost a packet a second and still drift, while every client
		can subtract its own GetServerTimeNow() from this one (Match.luau).
	]]
	local endsAt = if duration ~= nil then workspace:GetServerTimeNow() + duration else 0

	--[[
		State and PhaseEndsAt in ONE packet. Two Set() calls would let a client
		observe the new state beside the previous phase's deadline for a frame
		-- a results screen counting down to a time that has already passed. An
		empty path walks zero keys and writes straight into Data
		(ReplicaServer.luau:371-378), the same trick LevelService uses to keep
		Level and Experience atomic on the wire.
	]]
	roundReplica:SetValues({}, { State = state, PhaseEndsAt = endsAt })

	if state == "RoundActive" then
		endRequested = false
	end

	log.debug(`{previous} -> {state}`)

	--[[
		AFTER the write, so a listener that calls getState() sees the state it
		was just told about. Spawned, so a listener that yields or errors
		cannot stall the thread that drives the entire match. Ordering between
		listeners is undefined by design -- a listener that needs another one
		to have run first has a dependency, not a subscription.
	]]
	for _, listener in stateListeners do
		task.spawn(listener, state, previous)
	end

	return true
end

--[[
	Sleep until roundData.PhaseEndsAt, re-reading it on every tick.

	The re-read is what lets endRound() work from another thread with no
	handoff at all: it moves the deadline, this notices. The alternative -- one
	task.wait(duration) plus something that wakes this thread early -- needs a
	way to cancel an already-scheduled resumption, which Luau does not offer,
	and the failure mode is a thread resumed twice for one phase.
]]
local function sleepUntilPhaseEnd()
	while true do
		local remaining = roundData.PhaseEndsAt - workspace:GetServerTimeNow()
		if remaining <= 0 then
			return
		end
		task.wait(math.min(remaining, PHASE_POLL_INTERVAL))
	end
end

function RoundService.getState(): Match.MatchState
	return roundData.State
end

function RoundService.getModeId(): Match.GameModeId
	return roundData.ModeId
end

--[[
	The mode definition. Fork on `UsesTeams`, never on the id: a third mode
	then needs no edit at the call site (Match.luau).
]]
function RoundService.getMode(): Match.GameMode
	return Match.MODES[roundData.ModeId]
end

-- "" while no map is loaded, which includes the whole of Lobby and Voting.
function RoundService.getMapId(): string
	return roundData.MapId
end

function RoundService.isRoundActive(): boolean
	return roundData.State == "RoundActive"
end

-- Absolute server time. 0 means the current phase has no deadline.
function RoundService.getPhaseEndsAt(): number
	return roundData.PhaseEndsAt
end

--[[
	Subscribe to phase changes. Call this from your Init(), never Start():
	Start()s are spawned in parallel (Loader.luau:143) and the round loop
	begins inside one of them, so a listener registered in a Start() can miss
	the first transition and nothing replays it.

	No unsubscribe, deliberately, for the reason LevelService.onLevelUp gives:
	every subscriber is a *Service -- a module-scope singleton that outlives
	every player -- so there is nothing to leak.
]]
function RoundService.onStateChanged(listener: StateListener)
	table.insert(stateListeners, listener)
end

--[[
	Merge `values` into one player's scoreboard row. This is how everything
	except this file writes a row.

	A missing row is normal, not an error: a kill that lands in the same frame
	a player leaves arrives here after removePlayerEntry already ran. SetValues
	would walk the path and index nil (ReplicaServer.luau:372), throwing inside
	Replica and aborting whatever gameplay code was mid-write, so the row is
	checked first and a write for a departed player is dropped.
]]
function RoundService.writePlayer(player: Player, values: { [string]: any })
	local key = Match.playerKey(player.UserId)
	if roundData.Players[key] == nil then
		return
	end
	roundReplica:SetValues({ "Players", key }, values)
end

--[[
	Create this player's scoreboard row with defaults. Idempotent -- a second
	call must not wipe the Kills a player already has.

	Level is seeded at 1 and is NOT this file's to keep current -- the spine is
	the last file that should grow requires, because every edge added here is
	an edge the whole graph has to route around. ParticipantService owns it: it
	already owns every write to a player's row, and it refreshes Level through
	writePlayer on each phase change and on LevelService.onLevelUp.
]]
function RoundService.addPlayerEntry(player: Player)
	local key = Match.playerKey(player.UserId)
	if roundData.Players[key] ~= nil then
		return
	end

	local entry: Match.RoundPlayer = {
		DisplayName = player.DisplayName,
		Level = 1,
		-- "" until TeamService assigns one, and "" for the whole round in
		-- Free For All.
		Team = "",
		Phase = "Menu",
		Kills = 0,
		Deaths = 0,
		Alive = false,
		LastKillAt = 0,
	}
	roundReplica:Set({ "Players", key }, entry)
end

--[[
	Delete the row.

	nil DELETES the key rather than writing nil: Replica sends the value as a
	positional RemoteEvent argument (ReplicaServer.luau:356) and the client
	binds it as a named parameter (ReplicaClient.luau:718), so an explicit nil
	and a dropped trailing one are indistinguishable there -- both delete.
	SetValues cannot express this at all, because `{ [key] = nil }` IS `{}` at
	construction and its pairs() loop never sees the key.
]]
function RoundService.removePlayerEntry(player: Player)
	local key = Match.playerKey(player.UserId)
	if roundData.Players[key] == nil then
		return
	end
	roundReplica:Set({ "Players", key }, nil)
end

--[[
	This player's row, or nil when they have none -- they left, or nothing has
	added them yet.

	READ-ONLY. This is the live table the replica holds, so a caller that
	mutates a field changes what the server believes while sending nothing, and
	every client keeps the old value forever. Write through writePlayer.
]]
function RoundService.getPlayerEntry(player: Player): Match.RoundPlayer?
	return roundData.Players[Match.playerKey(player.UserId)]
end

--[[
	Team scores, merged: { Red = 12 }. ScoreService owns the arithmetic, this
	owns the wire -- that split is the whole of "one writer".
]]
function RoundService.writeScores(values: { [string]: number })
	roundReplica:SetValues({ "Scores" }, values)
end

--[[
	Vote tallies, merged: { MapChoices = {...} }, { MapVotes = {...} }.

	VoteService publishes whole tally tables rather than per-vote deltas
	because a vote that MOVES is two changes -- one map down, another up -- and
	a client that received only one of them would draw a total that never
	existed on the server.
]]
function RoundService.writeVote(values: { [string]: any })
	roundReplica:SetValues({ "Vote" }, values)
end

--[[
	End the round early: the win condition was reached. Safe from any thread,
	and a second call in the same round does nothing.

	The state check is not redundant with the flag. A kill processed one frame
	after the timer already expired arrives while the loop is in RoundResults
	or Lobby, and collapsing THAT phase's deadline would skip a phase on the
	strength of a stale win check.

	The deadline goes to now rather than 0, because 0 means "no deadline" to
	the client and would blank the match timer for the tick before the results
	screen arrives.
]]
function RoundService.endRound()
	if roundData.State ~= "RoundActive" or endRequested then
		return
	end
	endRequested = true
	log.info("round ending early -- win condition reached")
	writeDeadline(workspace:GetServerTimeNow())
end

--[[
	One pass of the match loop, Lobby to RoundResults.

	Every `return` here abandons the cycle; Start() then begins the next one at
	Lobby, which Match's transition table makes reachable from every state. So
	"give up" is always a complete recovery and never leaves the machine
	wedged.
]]
local function runCycle()
	if not enter("Lobby", Config.Round.IntermissionDuration) then
		--[[
			The only abandon point that has not yielded yet, and Start() paces
			the ERROR path only -- so without this wait, a refusal here would
			respawn the same refusal on the very next line of the while loop,
			flat out, forever. That is a frozen server plus an unreadable log,
			which is a far worse outcome than the illegal transition it is
			reporting. Every other `return` below is downstream of a
			sleepUntilPhaseEnd or a MapService.load and has already yielded.
		]]
		task.wait(ERROR_BACKOFF)
		return
	end

	--[[
		The previous round's map goes NOW, not when its results went up:
		players are still standing on it through RoundResults, and deleting the
		floor under them is a fall into the void for the last five seconds of a
		match they just won.
	]]
	MapService.unload()
	roundReplica:Set({ "MapId" }, "")
	sleepUntilPhaseEnd()

	--[[
		An empty server idles here instead of cycling maps for nobody.
		PhaseEndsAt goes to 0 -- "no deadline" -- because a countdown that is
		not counting down to anything is worse than none: the first player
		through the door would sit watching a timer their arrival already
		invalidated.
	]]
	while #Players:GetPlayers() < Config.Round.MinPlayers do
		writeDeadline(0)
		repeat
			task.wait(1)
		until #Players:GetPlayers() >= Config.Round.MinPlayers

		--[[
			The arriving player gets the intermission too, rather than landing
			in a vote that opens within a second of their join. That dwell is
			what IntermissionDuration is FOR (Config.luau: the results overlay
			finishing, the menu camera settling), and the player who ends the
			hold is the one player who would otherwise never receive it.

			Re-checked by the `while` rather than fallen through, because a
			player who joins and immediately leaves would otherwise commit the
			server to a full empty round.
		]]
		writeDeadline(workspace:GetServerTimeNow() + Config.Round.IntermissionDuration)
		sleepUntilPhaseEnd()
	end

	if not enter("Voting", Config.Round.VotingDuration) then
		return
	end
	VoteService.beginVote()
	sleepUntilPhaseEnd()
	VoteService.endVote()

	local mapId, modeId = VoteService.getResult()

	--[[
		getMode() indexes Match.MODES with this on every UsesTeams fork in the
		game, so a mode id that is not one would not fail here -- it would fail
		eight services away, indexing nil, with nothing in the log pointing
		back at the vote that produced it.
	]]
	if not Match.isModeId(modeId) then
		log.error(`vote returned unknown mode "{modeId}" -- falling back to {Match.DEFAULT_MODE}`)
		modeId = Match.DEFAULT_MODE
	end

	if not enter("MapLoading", Config.Round.MapLoadingMinDuration) then
		return
	end

	-- Published before the map is up, not after: the client chooses its team
	-- screen off ModeId and gets the whole load to build it.
	roundReplica:Set({ "ModeId" }, modeId)

	if not MapService.load(mapId) then
		--[[
			Back to Lobby rather than on into a round nobody can spawn into.
			MapService has already logged what is actually wrong; the cost of
			retrying is one intermission, and the cost of continuing is ten
			minutes of players pressing PLAY and landing nowhere.
		]]
		log.error(`map "{mapId}" failed to load -- abandoning this round`)
		return
	end
	roundReplica:Set({ "MapId" }, mapId)

	-- MapLoadingMinDuration is a floor under the phase, not a promise about
	-- it: a load that overran has already pushed the deadline into the past,
	-- and this returns immediately.
	sleepUntilPhaseEnd()

	if not enter("WaitingToPlay", Config.Round.WaitingToPlayDuration) then
		return
	end
	sleepUntilPhaseEnd()

	if not enter("RoundActive", Config.Round.Duration) then
		return
	end
	-- Ends on Config.Round.Duration or on endRound(), which is the same thing
	-- from here: both are a deadline in roundData.PhaseEndsAt.
	sleepUntilPhaseEnd()

	if not enter("RoundResults", Config.Round.ResultsDuration) then
		return
	end
	sleepUntilPhaseEnd()
end

function RoundService.Init()
	VoteService = require(script.Parent.VoteService)

	--[[
		A safety net, not the main path -- ParticipantService removes the row
		as part of its own leave flow. It is here because the Players table
		belongs to this file and replicates to every client, so a row that
		outlives its player is both a scoreboard entry nobody can clear and a
		leak that grows for the life of the server. removePlayerEntry is
		idempotent, so both paths running is a no-op, and the nil guard in
		writePlayer is what makes ParticipantService's cleanup safe to arrive
		after this one.
	]]
	Players.PlayerRemoving:Connect(function(player: Player)
		RoundService.removePlayerEntry(player)
	end)
end

function RoundService.Start()
	log.info("ready")

	while true do
		--[[
			The loop is the spine: if this thread dies, the server never runs
			another round, every player sits in a menu whose PLAY button leads
			nowhere, and the log says nothing after the one error. A cycle
			yields into MapService and VoteService, either of which can throw
			for a reason this file cannot foresee, so a failed cycle is
			restarted rather than lost -- with a pause, so a fault that
			reproduces instantly cannot spin.

			The locals are annotated for the reason Loader.luau:144 and
			ParticipantService give: the checker models xpcall's result as
			(boolean, <the protected function's returns>) and cannot see the
			handler, so runCycle returning nothing makes an unannotated
			destructure "a one-value call, but 2 are required". `err` is the
			traceback on failure, nil on success.
		]]
		local ok: boolean, err: string? = xpcall(runCycle, debug.traceback)
		if not ok then
			log.error(`round cycle errored -- restarting from Lobby\n{err}`)
			task.wait(ERROR_BACKOFF)
		end
	end
end

return RoundService
