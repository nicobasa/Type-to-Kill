--!strict
--[[
	Server authority for sprint and stamina.

	The client sends an INTENT and nothing else (Net.setSprinting). This service
	decides whether to honour it, and it -- never the client -- writes
	Humanoid.WalkSpeed. That split is the whole point: a packet carrying a speed
	would be a packet worth forging, and `WalkSpeed = 500` would be a legal move.

	ONE HEARTBEAT FOR EVERYONE, AND NO PER-PLAYER CONNECTIONS

	A Heartbeat per player is a connection to create on join, disconnect on leave,
	and disconnect AGAIN on every respawn if it captured the character -- three
	places to leak a closure that pins a dead character in memory. This file makes
	exactly four connections, all once at boot, and a player who leaves is a row
	that is deleted.

	There is no CharacterAdded and no Humanoid.Died connection for the same
	reason. The loop already visits every player every frame, so "the Humanoid I
	can see is not the one I saw last frame" IS the spawn signal and "Health <= 0"
	IS the death signal. A condition that is read costs nothing to clean up; a
	connection that reports it costs a disconnect somebody will eventually forget.

	RATES ARE DERIVED FROM DURATIONS, NEVER WRITTEN OUT

	Config.Stamina is stated in durations ("four seconds of sprint from full"), so
	the rate is Max/DrainDuration, spelled that way in exactly two places: here,
	and the client's stamina bar, from the same constants. A rate hardcoded on
	either side is a bar that empties at a different moment from the sprint it is
	drawing, and the divergence shows up on the first balance tweak rather than in
	review.

	WHAT ACTUALLY GOES ON THE WIRE

	Net.sprintState is a CORRECTION, not a stream (Net.luau says so at the packet
	definition). It is sent only where this service's answer differs from the one
	the client already drew for itself: granted, refused, force-cancelled at zero.
	A normal release is not sent -- the client initiated it, so it has drawn it
	already, and confirming it would spend a packet to change nothing. Nothing
	below sends per frame; at sixty packets a second the shared arithmetic would
	have bought nothing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantService = require(script.Parent.ParticipantService)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)

local log = Log.new("SprintService")

--[[
	The round's ruleset decides the pace (Config.GameModes): how fast walking
	and sprinting are, and whether sprinting costs stamina at all. Read on
	every use rather than cached, because it changes between rounds.
]]
local function ruleset(): typeof(Config.GameModes.Standard)
	return Config.GameModes[RoundService.getGameModeId()]
end

-- A shocked player walks at Config.Shock.SlowSpeed and cannot sprint, whatever
-- the ruleset's pace.
local function speedFor(active: boolean, slowed: boolean): number
	if slowed then
		return Config.Shock.SlowSpeed
	end
	local rules = ruleset()
	return if active then rules.SprintSpeed else rules.WalkSpeed
end

local MAX_STAMINA = Config.Stamina.Max
local DRAIN_RATE = Config.Stamina.Max / Config.Stamina.DrainDuration
local REGEN_RATE = Config.Stamina.Max / Config.Stamina.FullRegenDuration
local REGEN_DELAY = Config.Stamina.RegenDelay
-- Absolute stamina, not the fraction: every comparison below is against a
-- stamina value, so converting once here means no call site can forget to.
local RESUME_STAMINA = Config.Stamina.Max * Config.Stamina.ResumeThreshold

--[[
	MoveDirection is the character's DESIRED direction, so it is a unit vector
	while a control is held and zero otherwise -- a player running into a wall
	still drains, which is correct, because a wall is not a rest. The epsilon is
	for a gamepad thumbstick sitting inside its deadzone, which reports a small
	non-zero magnitude indefinitely and would otherwise drain a stationary
	player's bar to empty.
]]
local MOVE_EPSILON = 0.1

--[[
	Minimum seconds between two CORRECTIONS sent in answer to one player's
	requests.

	The intent packet itself is deliberately NOT rate limited, unlike every other
	client packet in this codebase. A dropped `active = false` would leave a
	player sprinting until they pressed the key again -- a "security control"
	whose failure mode is granting the thing it guards. Processing an intent is a
	table lookup and at most one property write, so a flood of them costs nothing
	worth defending against.

	What a flood COULD buy is amplification: one request in, one correction
	packet out. Both request-driven replies are floored here, on their own
	limiters. The grant needs it as much as the refusal does -- alternating
	`false, true, false, true` walks straight past the "already active" early
	return and reaches the grant reply, so limiting only refusals would leave
	the cheaper amplifier open. Separate limiters because a granted reply must
	not spend a refusal's budget: the two answer different presses and a
	refusal the client never hears is a client that keeps drawing a sprint it
	does not have.

	Dropping a request-driven reply is safe in a way that dropping the intent is
	not: it only withholds a number the client is already deriving itself, and
	the client re-asks while the key is held. The force-cancel in step() is
	server-initiated and therefore NOT limited -- nothing on the client is
	waiting to re-ask for it.

	The interval is local rather than a Config.RateLimit entry because those are
	all floors on a HUMAN action, and this is a floor on a server reply.
]]
local REPLY_INTERVAL = 0.25

type SprintState = {
	stamina: number,
	-- The server's answer, which is the only one that exists. The client's
	-- prediction is a drawing of this, never an input to it.
	active: boolean,
	--[[
		os.clock() before which stamina may not regenerate. RegenDelay is a HOLD
		and not a ramp (Config.Stamina), so this is pushed forward on every
		DRAINING frame rather than stamped once when sprint ends -- otherwise a
		player who taps sprint repeatedly banks regen they never waited for.
	]]
	regenAt: number,
	--[[
		The character the humanoid below was found in, so the per-frame path can
		skip the child lookup entirely once both are known. Without it the
		"cache" would still search every character every frame and only save the
		reset work, which is the cheap half.
	]]
	character: Model?,
	-- See resolveHumanoid: an identity change here IS the spawn signal, and the
	-- reset that follows it is the whole of this service's respawn handling.
	humanoid: Humanoid?,
	-- os.clock() at which a frag stun ends, or 0 when not stunned. See
	-- SprintService.stun.
	stunnedUntil: number,
	-- os.clock() at which a shock slow ends, or 0 when not slowed. See
	-- SprintService.slow.
	slowedUntil: number,
}

local states: { [Player]: SprintState } = {}
local grantLimit = RateLimiter.new(REPLY_INTERVAL)
local refusalLimit = RateLimiter.new(REPLY_INTERVAL)

local SprintService = {}

local function ensureState(player: Player): SprintState
	local existing = states[player]
	if existing ~= nil then
		return existing
	end

	local state: SprintState = {
		stamina = MAX_STAMINA,
		active = false,
		regenAt = 0,
		character = nil,
		humanoid = nil,
		stunnedUntil = 0,
		slowedUntil = 0,
	}
	states[player] = state
	return state
end

local function isSlowedNow(state: SprintState): boolean
	return state.slowedUntil > os.clock()
end

--[[
	Frozen or free, applied to the three things that move a character: its
	pace, its jump, and turning to face the camera.

	AutoRotate is part of the freeze on purpose. In first person the body turns
	with the camera, and a stunned player who could still spin around would turn
	their back and hide their code, which is the one thing a stun in this game
	is for taking away. They can still look around; the body stays put.

	Jump comes back as StarterPlayer's values, which are what every character
	spawns with, so restoring never invents a jump the place did not author.
]]
local function applyFrozen(humanoid: Humanoid, frozen: boolean, active: boolean, slowed: boolean)
	if frozen then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		humanoid.AutoRotate = false
		return
	end
	humanoid.WalkSpeed = speedFor(active, slowed)
	humanoid.JumpPower = StarterPlayer.CharacterJumpPower
	humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
	humanoid.AutoRotate = true
end

--[[
	The live Humanoid, or nil, resetting the row when the character has been
	replaced.

	Lazy and non-yielding on purpose: this runs inside the shared loop, and a
	WaitForChild here would stall every other player's tick behind one player's
	slow spawn. FindFirstChildOfClass is typed as returning a plain Instance, so
	the IsA below NARROWS rather than casts -- a `:: Humanoid` would be a promise
	the type checker cannot keep and a `Decal` named Humanoid would keep it badly.
]]
local function resolveHumanoid(player: Player, state: SprintState): Humanoid?
	local character = player.Character

	--[[
		Same character as last frame, and its Humanoid is already in hand. This
		is the branch the loop takes for a living player on every frame but the
		first, and it is why the cache is worth having at all.

		Deliberately NOT taken when the humanoid is nil: a character whose
		Humanoid we have not found yet must be re-searched, not written off for
		the life of that character.
	]]
	if character ~= nil and character == state.character and state.humanoid ~= nil then
		return state.humanoid
	end

	local found = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local humanoid = if found ~= nil and found:IsA("Humanoid") then found else nil

	state.character = character

	if humanoid == state.humanoid then
		return humanoid
	end

	state.humanoid = humanoid
	if humanoid == nil then
		--[[
			The character just went away (SpawnService.despawn nils
			Player.Character after destroying it). Drop the sprint flag with it,
			so "active" can never mean "sprinting with no body to sprint" --
			the next spawn resets it anyway, but an invariant that holds only
			until something reads it early is not an invariant.
		]]
		state.active = false
		return nil
	end

	--[[
		A character this service has never seen is a fresh spawn. Full bar rather
		than carried over: respawning into an empty bar charges a player for the
		sprint that got them killed, which reads as the bar being broken rather
		than as a cost. WalkSpeed is asserted too, so the pace is ours from the
		first frame instead of whatever StarterPlayer happened to ship.
	]]
	state.stamina = MAX_STAMINA
	state.regenAt = 0
	state.active = false
	-- A stun or a shock belongs to the body it hit. Dying mid-stun must not
	-- carry the freeze (or the slow) into the next spawn.
	state.stunnedUntil = 0
	state.slowedUntil = 0
	humanoid.WalkSpeed = speedFor(false, false)

	return humanoid
end

--[[
	Written on the transition only. WalkSpeed replicates, so sixty identical
	writes a second would be sixty packets that change nothing.
]]
local function setActive(state: SprintState, humanoid: Humanoid, active: boolean)
	state.active = active
	humanoid.WalkSpeed = speedFor(active, isSlowedNow(state))
end

local function sendState(player: Player, state: SprintState)
	Net.sprintState.sendTo({ active = state.active, stamina = state.stamina }, player)
end

local function onSetSprinting(data: { active: boolean }, player: Player)
	local state = states[player]
	if state == nil then
		return
	end

	local humanoid = resolveHumanoid(player, state)
	if humanoid == nil or humanoid.Health <= 0 then
		-- Nothing to move and nothing to draw. Answering would hand an exploiter
		-- an outbound packet for a request no real client can make.
		return
	end

	if not data.active then
		if state.active then
			setActive(state, humanoid, false)
		end
		return
	end

	if state.active then
		-- A key-down repeat, not a change. Replying would restate what the client
		-- is already drawing.
		return
	end

	--[[
		The two things a client cannot be trusted to know: whether it is actually
		in the round (ParticipantService owns that), and whether the bar has
		climbed back far enough to re-engage.

		ResumeThreshold is checked at the GRANT, never during a sprint already
		running -- an active sprint carries on to zero. Gating only the grant is
		what stops the one-frame on/off flicker at the bottom of the bar that
		Config.Stamina describes, without cutting a sprint short at 15%.

		A refusal is final until the client asks again. There is deliberately no
		"re-arm the moment stamina recovers": that would be a state change the
		server invented, and the packet list above says corrections answer
		requests. The client can re-ask while the key is held precisely because it
		runs the identical curve and knows when the threshold is crossed.
	]]
	-- A stunned or shocked player is refused like one out of stamina, so the
	-- client's predicted sprint is corrected back instead of drawing a sprint
	-- that is not moving anybody.
	local stunned = state.stunnedUntil > os.clock()
	local slowed = isSlowedNow(state)
	if stunned or slowed or not ParticipantService.isPlaying(player) or state.stamina < RESUME_STAMINA then
		if refusalLimit.allow(player) then
			sendState(player, state)
		end
		-- Not logged. A refusal is client-triggered, so logging every one just
		-- relocates a flood into the output panel (RateLimiter.luau says so).
		return
	end

	--[[
		The grant itself is never dropped -- only the packet confirming it. The
		client predicted this sprint before it asked, so a withheld confirmation
		costs it nothing, while an unguarded one would hand a `false, true`
		flood an outbound packet per pair.
	]]
	setActive(state, humanoid, true)
	if grantLimit.allow(player) then
		sendState(player, state)
	end
end

--[[
	The one loop. Everything per-player is a row in `states`, iterated in place:
	Players:GetPlayers() would allocate a fresh array sixty times a second to
	answer a question this table already answers.
]]
local function step(deltaTime: number)
	local now = os.clock()
	-- Endless stamina (Adrenaline): sprinting costs nothing, so the bar never
	-- leaves full and never needs to regenerate.
	local drains = not ruleset().InfiniteStamina

	for player, state in states do
		local humanoid = resolveHumanoid(player, state)
		if humanoid == nil then
			-- No character: nothing to drain and nothing to speed up. Stamina is
			-- left where it is because the next spawn refills it anyway.
			continue
		end

		if humanoid.Health <= 0 then
			--[[
				Death, handled by reading rather than by a Humanoid.Died
				connection. No correction is sent: the client knows it died
				(Net.killed), and a sprint bar animating over a killcam is not
				something it needs to be told about.
			]]
			state.active = false
			continue
		end

		-- The stun runs out here rather than on a task.delay: there is no
		-- timer to cancel on death or respawn, and a new body has already
		-- reset stunnedUntil in resolveHumanoid.
		if state.stunnedUntil > 0 and now >= state.stunnedUntil then
			state.stunnedUntil = 0
			applyFrozen(humanoid, false, state.active, isSlowedNow(state))
		end

		-- The shock's slow runs out the same way. A frozen player stays frozen:
		-- the stun's own expiry restores the pace, reading the slow then.
		if state.slowedUntil > 0 and now >= state.slowedUntil then
			state.slowedUntil = 0
			if state.stunnedUntil == 0 then
				humanoid.WalkSpeed = speedFor(state.active, false)
			end
		end

		if drains and state.active and humanoid.MoveDirection.Magnitude > MOVE_EPSILON then
			state.stamina = math.max(state.stamina - DRAIN_RATE * deltaTime, 0)
			state.regenAt = now + REGEN_DELAY

			if state.stamina <= 0 then
				-- Force-cancelled. This one IS server-initiated, so it is the
				-- correction the client genuinely cannot predict a refusal for:
				-- it is still holding the key.
				setActive(state, humanoid, false)
				sendState(player, state)
			end
		elseif state.stamina < MAX_STAMINA and now >= state.regenAt then
			--[[
				Standing still with the key held regenerates, and that is
				intentional: the player is not sprinting, they are standing, and a
				bar that freezes while a key is held would reward letting go of a
				key nobody would think to let go of.
			]]
			state.stamina = math.min(state.stamina + REGEN_RATE * deltaTime, MAX_STAMINA)
		end
	end
end

--[[
	Freezes a living player in place for `duration` seconds: no walking, no
	sprinting, no jumping, no turning the body. Returns false, having done
	nothing, if they have no living body to freeze.

	Lives here and not in whoever caused it because this service is the only
	writer of WalkSpeed. A second writer would fight setActive: the next
	sprint key press would hand a stunned player their speed back.

	A second stun while frozen RESTARTS the timer at `duration`: a player with
	one second left who is hit again has exactly `duration` left, not
	`duration` plus the one. Stuns never stack.
]]
function SprintService.stun(player: Player, duration: number): boolean
	local state = states[player]
	if state == nil then
		return false
	end
	local humanoid = resolveHumanoid(player, state)
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end

	state.stunnedUntil = os.clock() + duration

	if state.active then
		-- Server-initiated, like the force-cancel at zero stamina, so the
		-- client is told: it is still holding the key and drawing a sprint.
		state.active = false
		sendState(player, state)
	end
	applyFrozen(humanoid, true, false, isSlowedNow(state))
	return true
end

--[[ Whether a frag stun is holding this player right now. ]]
function SprintService.isStunned(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.stunnedUntil > os.clock()
end

--[[
	Slows a living player to Config.Shock.SlowSpeed for `duration` seconds and
	takes their sprint away for as long: a running sprint is cancelled, and a
	new one is refused (onSetSprinting). Returns false, having done nothing, if
	they have no living body.

	Here for the reason stun() is: this service is the only writer of
	WalkSpeed. A second shock RESTARTS the timer at `duration`; slows never
	stack. A player frozen by a frag stays frozen -- the stun's expiry picks
	the slow up if it is still running.
]]
function SprintService.slow(player: Player, duration: number): boolean
	local state = states[player]
	if state == nil then
		return false
	end
	local humanoid = resolveHumanoid(player, state)
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end

	state.slowedUntil = os.clock() + duration

	if state.active then
		-- Server-initiated, so the client is told: it is still holding the key.
		state.active = false
		sendState(player, state)
	end
	if state.stunnedUntil == 0 then
		humanoid.WalkSpeed = speedFor(false, true)
	end
	return true
end

--[[ Whether a shock slow is holding this player right now. ]]
function SprintService.isSlowed(player: Player): boolean
	local state = states[player]
	return state ~= nil and isSlowedNow(state)
end

function SprintService.Init()
	Net.setSprinting.listen(function(data, player)
		if player ~= nil then
			onSetSprinting(data, player)
		end
	end)

	Players.PlayerAdded:Connect(ensureState)

	-- The whole of this service's per-player cleanup. There is nothing else to
	-- release because there is nothing else held: no connection, no timer, no
	-- thread. RateLimiter clears its own table for us.
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
end

function SprintService.Start()
	-- A player can join between Init() and here, and ensureState is idempotent,
	-- so seeding is safe rather than merely tidy.
	for _, player in Players:GetPlayers() do
		ensureState(player)
	end

	RunService.Heartbeat:Connect(step)

	log.info(`ready -- {DRAIN_RATE}/s drain, {REGEN_RATE}/s regen`)
end

return SprintService
