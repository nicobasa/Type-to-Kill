--!strict
--[[
	Client side of the round.

	DataController's twin, pointed at the other replica: that one carries the
	private profile, this one carries the PUBLIC round -- state, phase
	deadline, scores, vote tallies and the scoreboard row for every player
	(Match.luau, "THE ROUND REPLICA"). Every other controller reads the round
	through the getters below and none of them touches the replica itself, so
	the answers a client needs BEFORE the replica lands -- "Lobby", "Menu",
	zero seconds -- are written once, here, instead of being guessed at a dozen
	call sites. Those pre-arrival answers are not a corner case either: the
	main menu is on screen for the whole of the join, which is exactly the
	window in which the replica has not arrived yet.

	The machinery -- observe(), await(), and the OnNew-in-Init rule -- is
	DataController's, deliberately. Same problems, same solutions, and a second
	set of answers to them would be a second set of bugs. The comments below
	are the condensed form; DataController.luau carries the long argument for
	each, and that is the file to change if one of them turns out to be wrong.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local Replica = require(ReplicatedStorage.ReplicaClient)

local log = Log.new("MatchController")

local player = Players.LocalPlayer

--[[
	Our own key in Round.Players. Computed once because it cannot change, and
	spelled through Match.playerKey because that is the only spelling of it
	anywhere -- Match.luau explains why it is not a bare tostring(userId).
]]
local SELF_KEY = Match.playerKey(player.UserId)

--[[
	Ceiling on how long anything here waits for the round replica. Bounded for
	the same reason HUDController bounds its WaitForChild: a missing round is a
	warning you can read, never a thread parked forever with nothing to show
	for it.
]]
local REPLICA_TIMEOUT = 30

--[[
	`previous` is nil on the FIRST call to a listener and only there -- the
	same "this is a read, not a transition" signal DataController.observe gives
	through its `old`. A listener that treats nil as a change plays its
	entrance animation at every player the moment they join.
]]
export type StateListener = (state: Match.MatchState, previous: Match.MatchState?) -> ()
export type PhaseListener = (phase: Match.PlayerPhase, previous: Match.PlayerPhase?) -> ()

local MatchController = {
	--[[
		Priority orders Init() and nothing else, and nothing in this file needs
		another controller's Init() to have run first. 90 states the intent --
		the round layer sits just below the profile layer (DataController, 100)
		and above the screens that read it -- rather than buying a guarantee it
		depends on.
	]]
	Priority = 90,
}

local roundReplica: any = nil
local readyWaiters: { thread } = {}

local stateListeners: { StateListener } = {}
local phaseListeners: { PhaseListener } = {}

-- Last values actually handed to listeners. nil means "nothing fired yet",
-- which is what makes the nil `previous` above mean what it says.
local lastState: Match.MatchState? = nil
local lastPhase: Match.PlayerPhase? = nil

local function readPath(root: any, path: { string | number }): any
	local current: any = root
	for _, key in path do
		if current == nil then
			return nil
		end
		current = current[key]
	end
	return current
end

--[[
	True when one path is a prefix of the other, in either direction -- a write
	AT or ABOVE us replaced our value wholesale, a write BELOW us changed our
	table's contents. DataController.observe carries the full argument.

	The empty path is the case worth naming here: RoundService writes State and
	PhaseEndsAt together as SetValues({}, {...}) so no client ever sees a new
	state beside the old deadline (RoundService.luau, enter()). That arrives as
	changedPath = {}, the loop below runs zero times, and every observer is
	consulted -- which is precisely right, because an empty path is a write to
	the root and could have touched anything.
]]
local function pathsIntersect(a: { string | number }, b: { string | number }): boolean
	for i = 1, math.min(#a, #b) do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

--[[
	Both normalisers are total: every caller of getState()/getPhase() is a
	screen that must draw something, so "the replica is not here" and "the
	field held something unexpected" have to collapse to the same usable
	answer rather than to nil.
]]
local function normalizeState(value: any): Match.MatchState
	if not Match.isState(value) then
		return "Lobby"
	end
	return value :: Match.MatchState
end

--[[
	No whitelist check for the phase, unlike the state above, because Match
	publishes isState and isModeId and deliberately publishes no isPhase. A
	list of the four phases written out here would be a second copy of an enum
	the server owns -- the exact drift Match.luau's header warns about -- so a
	string is taken at its word and only the absence of one is corrected.

	That absence is a real state, not an error: no row in Round.Players means
	the player is not in the match, and "Menu" is the honest reading of it.
]]
local function normalizePhase(value: any): Match.PlayerPhase
	if type(value) ~= "string" then
		return "Menu"
	end
	return value :: Match.PlayerPhase
end

--[[
	Both fan-outs suppress a repeat of the value they last delivered. That is
	not the same suppression observe() does: normalisation maps several raw
	readings onto one answer, so the row appearing with Phase = "Menu" right
	after "no row at all" is one genuine replica change that means nothing new
	to a listener. Firing it would hand a screen a transition it must then
	work out was not one.

	Spawned, for RoundService.enter()'s reason: a listener that yields or
	errors must not stall the fan-out to the ones behind it. Ordering between
	listeners is undefined -- a listener that needs another to have run first
	has a dependency, not a subscription.
]]
local function fireState(state: Match.MatchState)
	if state == lastState then
		return
	end

	-- Annotated, here and in firePhase below: an unannotated local taking a
	-- value under refinement loses the singleton union and reaches the
	-- listener as a plain string, which fails strict analysis against
	-- StateListener. The annotation is the whole fix.
	local previous: Match.MatchState? = lastState
	lastState = state

	for _, listener in stateListeners do
		task.spawn(listener, state, previous)
	end
end

local function firePhase(phase: Match.PlayerPhase)
	if phase == lastPhase then
		return
	end

	local previous: Match.PlayerPhase? = lastPhase
	lastPhase = phase

	for _, listener in phaseListeners do
		task.spawn(listener, phase, previous)
	end
end

--[[
	Yields until the round replica has arrived. Returns false on timeout.

	Unlike DataController.await this is rarely the gate you want: the getters
	all answer without it, and a screen that waits for the round before drawing
	anything is a screen the player stares at an empty version of. Use it when
	you genuinely cannot proceed, and observe() otherwise.
]]
function MatchController.await(timeout: number?): boolean
	if roundReplica ~= nil then
		return true
	end

	local thread = coroutine.running()
	table.insert(readyWaiters, thread)

	local timedOut = false
	if timeout ~= nil then
		task.delay(timeout, function()
			if roundReplica ~= nil then
				return -- already resumed by OnNew; must not resume twice
			end
			local index = table.find(readyWaiters, thread)
			if index ~= nil then
				table.remove(readyWaiters, index)
				timedOut = true
				task.spawn(thread)
			end
		end)
	end

	coroutine.yield()
	return not timedOut
end

-- The replicated round table. nil until the replica arrives. Read it; every
-- write to it belongs to RoundService and a client write replicates nowhere.
function MatchController.getRound(): any?
	return if roundReplica ~= nil then roundReplica.Data else nil
end

--[[
	Fires when a path under the round changes, AND immediately with the current
	value, so a binding is one call with no separate "populate on join" path:

		MatchController.observe({ "Scores", "Red" }, function(score)
			label.Text = `{score}`
		end)

	Built on OnChange, NOT OnSet, and that is load-bearing. OnSet is keyed on
	an exact concatenated path and is fired only by Replica:Set; SetValues,
	TableInsert and TableRemove fire the changed listeners and nothing else. An
	OnSet observer is therefore blind to three of the four write actions and to
	every nested write under the path it watches -- silently, with no error.

	The round makes that failure mode certain rather than likely: RoundService
	writes the state through SetValues({}, ...), every scoreboard row through
	SetValues({"Players", key}, ...), and the tallies through SetValues under
	{"Vote"}. An OnSet-based observer of this replica would essentially never
	fire. Do not "optimise" this into a hash lookup.
]]
function MatchController.observe(path: { string | number }, listener: (value: any, old: any?) -> ())
	task.spawn(function()
		if not MatchController.await(REPLICA_TIMEOUT) then
			log.warn(`observe({table.concat(path :: any, ".")}) timed out waiting for the round`)
			return
		end

		local last: any = readPath(roundReplica.Data, path)

		roundReplica:OnChange(function(_action: string, changedPath: { string | number })
			if not pathsIntersect(path, changedPath) then
				return
			end

			local current: any = readPath(roundReplica.Data, path)

			--[[
				Suppress no-op fires for scalars -- a sibling write intersects
				us but leaves our value alone.

				Tables are deliberately exempt: an in-place child write keeps
				the same table object, so `current == last` is true even though
				the contents just changed. {"Players"} and {"Vote"} are both
				watched as whole tables by other controllers, and comparing
				identity there would leave the scoreboard and the vote tally
				permanently stale.
			]]
			if current == last and type(current) ~= "table" then
				return
			end

			local old: any = last
			last = current
			listener(current, old)
		end)

		listener(last, nil)
	end)
end

-- "Lobby" until the replica lands, which is also what the server holds
-- between rounds -- so a client that is merely early shows the same screen as
-- one that is correct, rather than a blank one.
function MatchController.getState(): Match.MatchState
	if roundReplica == nil then
		return "Lobby"
	end
	return normalizeState(roundReplica.Data.State)
end

function MatchController.getModeId(): Match.GameModeId
	if roundReplica == nil or not Match.isModeId(roundReplica.Data.ModeId) then
		return Match.DEFAULT_MODE
	end
	return roundReplica.Data.ModeId :: Match.GameModeId
end

--[[
	The TDM/FFA fork, for everything that has one: team select, the score HUD,
	how a teammate's code is drawn. Fork on this, never on the mode id -- a
	third mode then needs no edit at any call site (Match.luau).

	getModeId only ever returns a key Match.MODES holds, so the index below
	cannot come back nil.
]]
function MatchController.usesTeams(): boolean
	return Match.MODES[MatchController.getModeId()].UsesTeams
end

--[[
	Our own scoreboard row, or nil when we do not have one.

	nil is the normal case, not an edge: a player sitting in the menu has no
	row until ParticipantService gives them one, and they are in the menu for
	most of their first minute on the server.
]]
function MatchController.getSelfEntry(): Match.RoundPlayer?
	if roundReplica == nil then
		return nil
	end

	local players = roundReplica.Data.Players
	if players == nil then
		return nil
	end
	return players[SELF_KEY]
end

-- Where WE are, independent of the match: a late joiner walks
-- Menu -> TeamSelect -> Playing while the state sits in RoundActive
-- throughout (Match.luau, PlayerPhase).
function MatchController.getPhase(): Match.PlayerPhase
	local entry = MatchController.getSelfEntry()
	if entry == nil then
		return "Menu"
	end
	return normalizePhase(entry.Phase)
end

--[[
	Seconds left in the current phase, for every countdown on the client.

	PhaseEndsAt is an ABSOLUTE server time, never a countdown, so the
	subtraction happens here once instead of in each of the four screens that
	draw a clock (Match.luau explains why a remaining-seconds field would cost
	a packet a second and still drift).

	Two values both mean "no countdown" and both return 0:

	  PhaseEndsAt == 0   the phase has no deadline at all -- Lobby, or a
	                     WaitingToPlay that is waiting on players rather than
	                     on a clock. Never "the deadline already passed".
	  deadline passed    the clamp. RoundService notices an expired deadline
	                     within PHASE_POLL_INTERVAL and the new state then has
	                     to replicate, so every client spends a fraction of a
	                     second past zero on every single phase change. Without
	                     the clamp that fraction is a timer reading "-0:01",
	                     and math.min elsewhere turns it into a bar that grows
	                     backwards.

	NaN is rejected before the clamp, not after: math.max(0, 0/0) is NaN, so a
	single garbage write would otherwise escape through it and poison every
	comparison downstream (quality-gate.md trap #8).
]]
function MatchController.secondsRemaining(): number
	if roundReplica == nil then
		return 0
	end

	local endsAt = roundReplica.Data.PhaseEndsAt
	if type(endsAt) ~= "number" or endsAt ~= endsAt or endsAt == 0 then
		return 0
	end

	return math.max(0, endsAt - workspace:GetServerTimeNow())
end

--[[
	Subscribe to match state changes. Register from Init() and you are
	guaranteed the first fire, because the replica cannot arrive before
	Replica.RequestData(), which Main.client.luau calls after every Init() has
	run.

	Registering later still works -- the listener is primed with the current
	state on its own thread, so early and late registration differ in timing
	and never in what the listener sees. The branch is exclusive with the
	fan-out's first fire: while roundReplica is nil there is nothing to prime
	with, and the fan-out has already primed by the time it is not.

	No unsubscribe, for RoundService.onStateChanged's reason: every subscriber
	is a controller, a module-scope singleton that outlives every player, so
	there is nothing here to leak.
]]
function MatchController.onStateChanged(listener: StateListener)
	table.insert(stateListeners, listener)

	if roundReplica ~= nil then
		local state: Match.MatchState = MatchController.getState()
		task.spawn(function()
			listener(state, nil)
		end)
	end
end

function MatchController.onPhaseChanged(listener: PhaseListener)
	table.insert(phaseListeners, listener)

	if roundReplica ~= nil then
		local phase: Match.PlayerPhase = MatchController.getPhase()
		task.spawn(function()
			listener(phase, nil)
		end)
	end
end

function MatchController.Init()
	--[[
		Init, NOT Start. OnNew does not replay a replica that already arrived
		-- miss it and you miss it permanently and silently, with the whole
		match UI left sitting in Lobby and nothing in the output to say why.
		The Init/Start split exists for exactly this ordering.
	]]
	Replica.OnNew(Match.REPLICA_TOKEN, function(replica)
		if roundReplica ~= nil then
			--[[
				Keep the FIRST and say so. Every observer holds an OnChange
				connection on the replica it saw, so swapping this reference
				would leave all of them listening to a table nobody writes --
				a client frozen at the moment of the swap, with no error. One
				warning beats that by a distance.

				RoundService creates exactly one and never destroys it, so this
				is a guard against a future second writer, not against today.
			]]
			log.warn(`a second "{Match.REPLICA_TOKEN}" replica arrived -- keeping the first`)
			return
		end

		roundReplica = replica
		log.info("round state received")

		for _, thread in readyWaiters do
			task.spawn(thread)
		end
		table.clear(readyWaiters)
	end)

	--[[
		The two fan-outs. They are observers like anyone else's, which is the
		point: onStateChanged and onPhaseChanged are a convenience over
		observe(), not a second mechanism that could disagree with it.

		Registered here so they are attached before the replica lands, and
		their first fire is what primes every listener that subscribed during
		Init().
	]]
	MatchController.observe({ "State" }, function(value)
		fireState(normalizeState(value))
	end)

	--[[
		Our phase is a field on our own scoreboard row, so this watches the
		full path rather than {"Players"} -- a kill anywhere on the server
		rewrites some row every few seconds, and a screen does not want to be
		woken for all of them.

		The row not existing is covered: pathsIntersect matches
		{"Players", key} against this path, so the write that creates the row
		fires it, and the write that removes it fires it back to "Menu".
	]]
	MatchController.observe({ "Players", SELF_KEY, "Phase" }, function(value)
		firePhase(normalizePhase(value))
	end)
end

function MatchController.Start()
	--[[
		Diagnostics only. Every getter above answers without the replica, so a
		client that never receives one keeps running and simply shows a
		permanent Lobby -- a failure that is silent by construction, which is
		exactly why it is worth one line of output.
	]]
	if not MatchController.await(REPLICA_TIMEOUT) then
		log.warn(`no round state after {REPLICA_TIMEOUT}s -- the match UI will sit in Lobby. Is RoundService running?`)
	end
end

return MatchController
