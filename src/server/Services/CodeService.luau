--!strict
--[[
	The kill code: the four digits a player types to kill someone, and the
	table that says whose they are.

	A CODE YOU CAN SEE CANNOT BE HIDDEN FROM YOU -- stated plainly, because
	every decision below depends on it. The four digits have to be legible on
	screen for a human to type them, so they have to reach that client, so a
	modified client can read them. There is no arrangement of this game in
	which that is false, and nobody should add something later under the
	impression that it would help.

	WHAT IS WORTH DOING, and what this module does: make sure a client is only
	ever GIVEN the codes it could already read. The code lives in one
	server-side table. It is not in the round replica (Match.luau, "PUBLIC
	means public") and -- since a previous version got this wrong -- it is not
	an attribute on the character either, because an attribute replicates to
	every client and handed an exploiter every code in the server from a single
	loop. It goes out through Net.codeVisibility, per client, only for the
	players within Config.Code.VisibleRange. sweepVisibility below is that.

	So the attack this removes is "kill the entire lobby instantly". What is
	left is "read the numbers near you slightly more conveniently than with
	your eyes", which the rate limit already bounds.

	WHAT STOPS CODE SPAM, since secrecy cannot: the rate limit
	(Config.RateLimit.CodeSubmit, which KillService applies BEFORE any other
	work) plus the server-side validation ladder, which re-checks the match
	state, both players' liveness and phase, the team relationship and spawn
	protection on every single submission. A player holding every code in range
	still gets roughly eight attempts a second, each of which has to pass all
	of that independently.

	A CODE IS A STRING, ALWAYS. "0047" and 47 are the same number and different
	codes, and the leading zeros are exactly what a player reads off a headband.
	Nothing in this file may round-trip a code through tonumber().
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Log = require(ReplicatedStorage.Shared.Log)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)

local log = Log.new("CodeService")

--[[
	Deferred, and deliberately the only service this file knows about.

	A code must not outlive the round it was drawn for, and the project rule is
	that RoundService calls "reset" on nobody -- each service subscribes to
	onStateChanged itself. The dependency table in the same contract draws
	CodeService as depending on nothing but shared, so this require is deferred
	rather than static: the static require graph stays exactly as that table
	draws it, and resolution happens in Init(), after every module body has
	already run, so no cycle can exist regardless of what RoundService itself
	ends up requiring. The annotation is erased at runtime and the types still
	resolve (ARCHITECTURE.md, "Using another module").
]]
local RoundService: typeof(require(script.Parent.RoundService)) = nil :: any

local DIGITS = Config.Code.Digits
local CODE_SPACE = 10 ^ DIGITS
-- Built from DIGITS rather than written as "%04d", so lowering Config.Code.Digits
-- cannot leave a five-character code in a four-digit game.
local CODE_FORMAT = `%0{DIGITS}d`

local DRAW_ATTEMPTS = 16

--[[
	Proximity broadcast state.

	`visibilityDirty` forces the next sweep to send even where the set looks
	unchanged. Set it whenever a code appears or disappears, because those are
	the two changes a distance test cannot notice on its own.

	`lastSent` is what each client was last told, joined into one string so
	"has this changed?" is a string compare rather than a table walk. Sending
	an identical set again is not harmful, just wasted bandwidth on every
	player every fifth of a second -- which over a ten minute round is the
	difference between this being free and this being a cost.
]]
local visibilityDirty = false
local lastSent: { [Player]: string } = {}
local HEADBAND_NAME = "KillCodeHeadband"

local random = Random.new()

--[[
	THE POOL. `codeOwners` is the whole of it -- a code is free exactly when it
	is absent from this table, so there is no second structure to keep in sync
	and no way for "free" and "taken" to disagree.

	Drawing is a random pick with a bounded retry, never a walk from "0000" to
	"9999". The walk is the obvious implementation and it is wrong twice: it
	costs O(code space) per spawn, and it hands out codes in ascending order, so
	reading one code tells a player roughly where the next ones are. The random
	draw has neither property and, at any occupancy this game can reach,
	finishes on the first attempt almost always: Roblox caps a server at 700
	players against 10^4 codes, so one collision is under 7% likely and
	DRAW_ATTEMPTS consecutive collisions about 1e-19. The bounded sweep drawCode
	falls back on only matters if Config.Code.Digits is lowered until the code
	space and the player cap are comparable, which Init() warns about at boot.
]]
local codeOwners: { [string]: Player? } = {}
local playerCodes: { [Player]: string } = {}

--[[
	The code each player held MOST RECENTLY, kept so the next draw cannot hand
	the same one back. Without it, a killer who just typed 0472 is holding a
	valid code for that player again the instant they respawn -- a second kill
	for no reading at all, which is the one thing a respawn has to cost them.
]]
local previousCodes: { [Player]: string } = {}
local characterConnections: { [Player]: RBXScriptConnection? } = {}

--[[
	The character a player's current code is actually written on.

	Not the same question as `player.Character`, and the difference is the whole
	reason this table exists: during a respawn there is a window in which those
	two are DIFFERENT instances, and a deferred CharacterRemoving handler lands
	squarely inside it. See watchCharacters for the failure that caused.

	It also makes release() clear the number off the body that wore it rather
	than off whatever body the player happens to own at the moment it runs,
	which is the more honest thing for it to mean in any case.
]]
local codeCharacters: { [Player]: Model? } = {}

-- Warned once, not once per spawn: a misconfigured asset is a fact about the
-- place, and repeating it every respawn just buries the rest of the log.
local headbandWarned = false

local CodeService = {}

--[[
	A free code that is not `excluded`, or nil only if there is genuinely no
	free code left in the space.

	The random draw is the whole of the normal path. The sweep below it exists
	because the alternative -- giving up after DRAW_ATTEMPTS collisions -- hands
	back nil, and a spawning player with no code is a player nobody can kill.
	SpawnService discards assign()'s return value (it has nothing useful to do
	with a failure), so that outcome would be silent and invisible. The sweep
	starts from a random offset and wraps, so even the degenerate case never
	hands out codes in ascending order; it only runs at an occupancy this game
	cannot reach with a sane Config.Code.Digits, and it is bounded by the code
	space, which is why it is a last resort rather than the implementation.
]]
local function drawCode(excluded: string?): string?
	for _ = 1, DRAW_ATTEMPTS do
		local code = string.format(CODE_FORMAT, random:NextInteger(0, CODE_SPACE - 1))
		if codeOwners[code] == nil and code ~= excluded then
			return code
		end
	end

	local offset = random:NextInteger(0, CODE_SPACE - 1)
	for i = 0, CODE_SPACE - 1 do
		local code = string.format(CODE_FORMAT, (offset + i) % CODE_SPACE)
		if codeOwners[code] == nil and code ~= excluded then
			return code
		end
	end
	return nil
end

--[[
	The physical band is OPTIONAL ART. A place with no ServerStorage.Assets.
	Headband plays correctly: the code lives in the character attribute, which
	is what the client actually reads, so a missing model costs cosmetics and
	nothing else. Hence the silent nil rather than a warning on every spawn.
]]
local function findHeadbandTemplate(): Instance?
	local assets = ServerStorage:FindFirstChild("Assets")
	if assets == nil then
		return nil
	end
	return assets:FindFirstChild("Headband")
end

--[[
	Accessory types that occupy the head. Hair is the one that actually matters
	-- a tall hairstyle sits exactly where the code plate goes -- but hats and
	face accessories cover it just as well.
]]
local HEAD_ACCESSORY_TYPES: { [Enum.AccessoryType]: boolean } = {
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Face] = true,
}

--[[
	Attachment names the engine uses to mount things to the head.

	Checked as well as AccessoryType because older accessories report
	AccessoryType.Unknown and are placed purely by which attachment they carry --
	and an old hat is still a hat sitting on top of the number.
]]
local HEAD_ATTACHMENT_NAMES: { [string]: boolean } = {
	HatAttachment = true,
	HairAttachment = true,
	FaceFrontAttachment = true,
	FaceCenterAttachment = true,
	LeftEarAttachment = true,
	RightEarAttachment = true,
}

local function isHeadAccessory(accessory: Accessory): boolean
	if HEAD_ACCESSORY_TYPES[accessory.AccessoryType] then
		return true
	end

	local handle = accessory:FindFirstChild("Handle")
	if handle == nil then
		return false
	end
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") and HEAD_ATTACHMENT_NAMES[child.Name] then
			return true
		end
	end
	return false
end

--[[
	Take the player's hair and hats off before putting the band on.

	Cosmetic-looking, load-bearing in fact: the code plate floats just above the
	head, and a tall hairstyle or a wide hat sits in exactly that space. A number
	nobody can read is a player nobody can kill, so an avatar choice would
	otherwise decide how hard someone is to kill -- which is the one thing this
	game must never let cosmetics do.

	Server-side and on the real character, so every client sees the same clear
	head. Destroying rather than hiding: a hidden accessory still has a Handle
	the plate can z-fight with.

	Only head slots. Backpacks, shoulder pets and anything on the torso are left
	alone -- they cover nothing that matters, and stripping a player's whole
	avatar would be a bigger decision than this one.
]]
local function stripHeadAccessories(character: Model)
	for _, child in character:GetChildren() do
		if not child:IsA("Accessory") then
			continue
		end
		-- Never our own band, whatever it reports itself as.
		if child.Name == HEADBAND_NAME then
			continue
		end
		if isHeadAccessory(child) then
			child:Destroy()
		end
	end
end

local function attachHeadband(character: Model)
	-- Before the template check, so a place with no headband asset still gets a
	-- clear head for the client's fallback label to sit over.
	stripHeadAccessories(character)

	local template = findHeadbandTemplate()
	if template == nil then
		return
	end

	if not template:IsA("Accessory") then
		if not headbandWarned then
			headbandWarned = true
			log.warn(`ServerStorage.Assets.Headband is a {template.ClassName}, not an Accessory -- not attached`)
		end
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local clone = template:Clone()
	clone.Name = HEADBAND_NAME

	-- Narrowed to BasePart at the lookup, not later: FindFirstChild answers
	-- Instance?, and everything below reads a CFrame off these two and welds
	-- them. A Handle or Sign that is not a BasePart is a malformed asset, and
	-- treating it as absent takes the same silent-cosmetic path a missing one
	-- does rather than throwing on a spawn.
	local handleChild = clone:FindFirstChild("Handle")
	local signChild = clone:FindFirstChild("Sign")
	local handle: BasePart? = if handleChild ~= nil and handleChild:IsA("BasePart") then handleChild else nil
	local sign: BasePart? = if signChild ~= nil and signChild:IsA("BasePart") then signChild else nil

	--[[
		THE SIGN IS HELD ASIDE ACROSS AddAccessory, and this is not defensive
		tidiness -- without it the sign simply vanishes.

		AddAccessory runs the engine's accessory fitting, which rebuilds the
		accessory around its Handle: it adds AccessoryRigidConstraint and
		OriginalSize, and it discards every other BasePart in there. Measured,
		not assumed -- an accessory that went in with Handle AND Sign came out
		with Handle alone, the weld gone with it, and the code plate nowhere on
		the character.

		Unparenting first keeps the sign out of that pass. We still hold the
		reference, so nothing collects it, and it goes back in afterwards.

		The offset is read off the TEMPLATE rather than written here as a
		constant: the arrangement is the designer's, authored in Studio, and a
		number copied into this file is one that silently stops matching the
		model the first time they nudge it.
	]]
	local signOffset: CFrame? = nil
	if sign ~= nil and handle ~= nil then
		signOffset = handle.CFrame:ToObjectSpace(sign.CFrame)
		sign.Parent = nil
	end

	--[[
		AddAccessory rather than a hand-rolled weld: it binds the Handle's
		Attachment to the like-named Attachment on the Head, which is the only
		placement that lands correctly on every head a player might be wearing.
		A weld at a fixed offset from Head.Position sits inside the skull on
		some bundles and floats above it on others.
	]]
	humanoid:AddAccessory(clone)

	if sign == nil or signOffset == nil or handle == nil or handle.Parent == nil then
		return
	end

	--[[
		A Weld, never a WeldConstraint. A WeldConstraint has no offset of its
		own -- it captures whatever relative CFrame the parts happen to hold
		when it activates -- and the first version of this put the sign 153
		studs from the head it belonged to for exactly that reason. A Weld
		carries the offset as data (Part0.CFrame * C0 == Part1.CFrame * C1), so
		activation order cannot change where the sign ends up.
	]]
	sign.CFrame = handle.CFrame * signOffset
	sign.Parent = clone

	local weld = Instance.new("Weld")
	weld.Name = "SignWeld"
	weld.Part0 = handle
	weld.Part1 = sign
	weld.C0 = signOffset
	weld.Parent = handle
end

-- Every match, not FindFirstChild's first one: release() can only clear a band
-- while player.Character still points at the body wearing it, so a character
-- that survived a missed release must not keep a dead number on its head.
local function removeHeadband(character: Model)
	for _, child in character:GetChildren() do
		if child.Name == HEADBAND_NAME then
			child:Destroy()
		end
	end
end

--[[
	Returns the player's code to the pool and takes it off their character.
	Idempotent: a player with no code is a no-op, which is what lets every
	caller that might be first -- death, respawn, leave, round end -- just call
	it without coordinating with the others.
]]
function CodeService.release(player: Player)
	local code = playerCodes[player]
	if code == nil then
		return
	end

	codeOwners[code] = nil
	playerCodes[player] = nil
	previousCodes[player] = code

	--[[
		Cleared on the character, not just in the table. The corpse survives the
		kill for Config.Killcam.Duration, and a corpse still wearing a live
		number is one a player will spend that whole time typing at.

		codeCharacters, not player.Character: those are the same instance
		everywhere except inside a respawn, and inside a respawn taking
		player.Character strips the number off the body that just received it.
	]]
	local character = codeCharacters[player]
	codeCharacters[player] = nil
	if character ~= nil then
		removeHeadband(character)
	end

	-- The visible sets everyone is holding now name a code that no longer
	-- exists. Pushed straight away rather than waiting for the next sweep:
	-- this is the corpse case, and a number left on screen for a fifth of a
	-- second after its owner died is a fifth of a second of players typing at
	-- nothing.
	visibilityDirty = true
end

--[[
	Draws a fresh code for a spawning player and writes it onto their
	character. Returns the code, or nil if they have no living character to
	write it on.

	A NEW code every spawn, never the one they just lost -- see previousCodes.
]]
function CodeService.assign(player: Player): string?
	local character = player.Character
	if character == nil then
		log.debug(`assign() for {player.Name} with no character -- dropped`)
		return nil
	end

	--[[
		A code on a corpse resolves to a player who is already dead, and
		KillService would spend its liveness check discovering that. Refusing
		here keeps codeOwners meaning what it says: the codes of LIVING players.

		The `Health ~= Health` half is the NaN case: every comparison against
		NaN is false, so `Health <= 0` on its own calls a NaN-health humanoid
		alive and writes a code onto a body that will never report a death.
	]]
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health ~= humanoid.Health or humanoid.Health <= 0 then
		log.debug(`assign() for {player.Name} with no living humanoid -- dropped`)
		return nil
	end

	-- Free whatever they are holding first, so a double assign cannot strand a
	-- code in the pool with no owner able to release it.
	CodeService.release(player)

	local code = drawCode(previousCodes[player])
	if code == nil then
		-- Every code in the space is taken, not a run of bad luck: the sweep in
		-- drawCode has already looked at all of them.
		log.error(`all {CODE_SPACE} codes are in use -- {player.Name} spawns unkillable. Raise Config.Code.Digits.`)
		return nil
	end

	codeOwners[code] = player
	playerCodes[player] = code
	-- Recorded alongside the code, never derived later: this is the instance
	-- release() must clear, and by the time it runs player.Character may
	-- already be a different body.
	codeCharacters[player] = character
	attachHeadband(character)

	-- A spawning player is invisible to everyone until the next sweep pushes
	-- them, so push on the next tick rather than up to VisibilityInterval
	-- later. Spawn protection covers the gap, but an unreadable enemy is still
	-- a confusing one.
	visibilityDirty = true

	return code
end

--[[
	Swaps a living player's code for a fresh one, on the body they already
	wear. KillService calls this for the killer after every kill: anyone who
	read the killer's number during the fight loses it, so a kill is also a
	way to shake off a player who had you read.

	Not assign(). That would take the headband off and put it back on, which
	is the AddAccessory dance attachHeadband documents, for a change that is
	only a new number. The number on the plate is drawn client-side from
	codeVisibility, so swapping the tables and pushing is the whole job.

	Returns the new code, or nil if the player holds none (they died in the
	same frame) or the space is full.
]]
function CodeService.reroll(player: Player): string?
	local old = playerCodes[player]
	if old == nil then
		return nil
	end

	-- Excluding the old code is what makes this a reroll and not, one time
	-- in ten thousand, a no-op.
	local code = drawCode(old)
	if code == nil then
		log.error(`all {CODE_SPACE} codes are in use -- {player.Name} keeps {old}. Raise Config.Code.Digits.`)
		return nil
	end

	codeOwners[old] = nil
	previousCodes[player] = old
	codeOwners[code] = player
	playerCodes[player] = code

	-- Pushed now: until the next sweep every viewer holds the old number,
	-- which already resolves to nobody.
	visibilityDirty = true

	return code
end

--[[ The player's current code, or nil if they do not hold one. ]]
function CodeService.getCode(player: Player): string?
	return playerCodes[player]
end

--[[
	Who owns this code right now, or nil if nobody does.

	Shape is NOT re-checked here: KillService runs Validate.code immediately
	before calling this, and doing it twice per submission buys nothing. The
	type guard is for the one thing a dictionary lookup cannot survive -- a
	non-string that arrived where the annotation promised a string.
]]
function CodeService.resolve(code: string): Player?
	if type(code) ~= "string" then
		return nil
	end
	return codeOwners[code]
end

local function releaseAll()
	-- Snapshot first: release() clears the very table being walked, and
	-- mutating a table under generalized iteration is not a behaviour to lean
	-- on. The list is at most one entry per player.
	local holders: { Player } = {}
	for player in playerCodes do
		table.insert(holders, player)
	end
	for _, player in holders do
		CodeService.release(player)
	end
end

local function watchCharacters(player: Player)
	--[[
		SpawnService already releases on Humanoid.Died, so this looks like a
		duplicate. It is not: CharacterRemoving fires for every way a character
		can go away -- a moderation action, some future script calling Destroy
		-- and release() is idempotent, so the overlap costs one table lookup
		and buys the invariant that codeOwners can never point at a player who
		has no body to read the code off.

		THE GUARD IS LOAD-BEARING. Without it this handler silently wiped the
		code off every respawn, and the reason is entirely in the ORDER, not in
		either function:

		  1. SpawnService.spawnPlayer calls player:LoadCharacter().
		  2. That removes the old character, which RAISES CharacterRemoving --
		     but Roblox runs signal handlers DEFERRED, so this callback does not
		     run yet.
		  3. LoadCharacter returns; spawnPlayer calls CodeService.assign, which
		     writes a fresh code onto the NEW character.
		  4. Only NOW does the deferred callback run. An unguarded
		     release(player) releases whatever the player holds -- which is no
		     longer the dead body's code, it is the one assigned one step ago --
		     and clears it straight back off the character that just got it.

		The player then respawns permanently codeless: invisible to the one
		mechanic the game has. Comparing the departing character against the one
		the code is actually on makes the late callback a no-op, which is what
		it should have been all along -- the dead body's code was already
		released by SpawnService before the respawn was ever scheduled.
	]]
	characterConnections[player] = player.CharacterRemoving:Connect(function(character: Model)
		if codeCharacters[player] == character then
			CodeService.release(player)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	CodeService.release(player)
	-- After release(), which is what WRITES previousCodes. Clearing first would
	-- leave a departed player's last code remembered for the life of the
	-- server, which is exactly the {[Player]: T} leak the cleanup rule targets.
	previousCodes[player] = nil
	-- release() clears this on every path it takes, but it returns early for a
	-- player holding no code -- and that player may still have an entry here if
	-- anything ever writes one without a code. Cleared unconditionally so this
	-- table cannot outlive the player under any ordering.
	codeCharacters[player] = nil
	lastSent[player] = nil

	local connection = characterConnections[player]
	if connection ~= nil then
		connection:Disconnect()
		characterConnections[player] = nil
	end
end

function CodeService.Init()
	RoundService = require(script.Parent.RoundService)

	RoundService.onStateChanged(function(state: Match.MatchState, previous: Match.MatchState)
		--[[
			Both halves matter. `previous == "RoundActive"` is the round ending;
			`state ~= "RoundActive"` is there because a service re-asserting its
			own state is legal (Match.canTransition allows from == to), and that
			must not strip the codes off a round still being played.
		]]
		if previous == "RoundActive" and state ~= "RoundActive" then
			releaseAll()
		end
	end)

	--[[
		A soft warning, not an error: the game is still playable with a cramped
		code space, it just starts refusing assignments near capacity. Said at
		boot because that is the only moment anyone is looking at the log for
		configuration problems.
	]]
	if CODE_SPACE < Players.MaxPlayers * 4 then
		log.warn(`{CODE_SPACE} codes for up to {Players.MaxPlayers} players -- raise Config.Code.Digits`)
	end

	-- GetPlayers() covers anyone who joined while the server was still booting;
	-- nothing between it and the Connect yields, so nobody is watched twice.
	for _, player in Players:GetPlayers() do
		watchCharacters(player)
	end
	Players.PlayerAdded:Connect(watchCharacters)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

--[[
	The root part a distance test should measure from, or nil for anyone who is
	not currently a body standing in the world.

	Deliberately reads codeCharacters rather than player.Character: the code IS
	the thing being made visible, so the body that holds it is the only body
	that matters here, and during a respawn those two disagree (release()
	explains why).
]]
local function visiblePosition(player: Player): Vector3?
	local character = codeCharacters[player]
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root.Position
end

--[[
	Reusable, because allocating a RaycastParams per pair would cost more than
	the casts do. FilterDescendantsInstances is rewritten once per sweep.
]]
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true
sightParams.RespectCanCollide = true

--[[
	A part at or past this transparency does not block a code. Invisible walls
	and map boundaries are collidable at Transparency 1, and a window is
	collidable glass. Both used to hide a number the player was looking
	straight at, which is the failure that costs a legitimate kill.
]]
local SEE_THROUGH_TRANSPARENCY = 0.5

-- Walls that can be seen through before a ray gives up and calls itself
-- blocked. A bound, not a tuning knob: it only stops a hall of glass panes
-- from costing unbounded casts.
local MAX_SEE_THROUGH = 4

-- Where the three sight rays land along the plate's long axis, as a fraction
-- of its half-length. Short of the very edge, because a ray that just clears
-- the last pixel of a plate does not make four digits readable.
local PLATE_SAMPLE_SPREAD = 0.8

local function isSeeThrough(part: BasePart): boolean
	return part.Transparency >= SEE_THROUGH_TRANSPARENCY or part.Material == Enum.Material.Glass
end

--[[
	One ray, allowed to pass through see-through parts. Each pass restarts
	just beyond the part it hit rather than excluding that part, so the shared
	filter is never touched mid-sweep.
]]
local function rayIsClear(from: Vector3, to: Vector3): boolean
	local origin = from
	for _ = 0, MAX_SEE_THROUGH do
		local delta = to - origin
		if delta.Magnitude < 0.1 then
			return true
		end
		local hit = Workspace:Raycast(origin, delta, sightParams)
		if hit == nil then
			return true
		end
		if not isSeeThrough(hit.Instance) then
			return false
		end
		origin = hit.Position + delta.Unit * 0.05
	end
	return false
end

--[[
	The plate the code is printed on, as the points a viewer has to be able to
	see at least one of: its centre and both ends along its long axis. nil
	for a body with no band, where the caller falls back to above the head.
]]
local function platePoints(character: Model): { Vector3 }?
	local headband = character:FindFirstChild(HEADBAND_NAME)
	local sign = if headband ~= nil then headband:FindFirstChild("Sign") else nil
	if sign == nil or not sign:IsA("BasePart") then
		return nil
	end

	-- The long axis read off the part rather than assumed, so re-rotating the
	-- Sign in Studio cannot quietly turn the spread into a vertical line.
	local size = sign.Size
	local cframe = sign.CFrame
	local axis: Vector3
	local half: number
	if size.X >= size.Y and size.X >= size.Z then
		axis, half = cframe.RightVector, size.X / 2
	elseif size.Y >= size.Z then
		axis, half = cframe.UpVector, size.Y / 2
	else
		axis, half = cframe.LookVector, size.Z / 2
	end

	local offset = axis * half * PLATE_SAMPLE_SPREAD
	local centre = cframe.Position
	return { centre, centre - offset, centre + offset }
end

--[[
	Can `viewer` actually SEE the code, or is there a wall in the way?

	Bodies are excluded from the cast, not just the two involved. A code is
	readable past someone standing between you and it -- the plate floats above
	their heads -- so letting characters block would withhold codes a player can
	plainly read, which is the one failure mode that costs a legitimate kill.
	Only world geometry blocks, and only geometry you cannot see through.

	Aimed at the plate itself, from the viewer's head. The code used to cast
	one ray between two fixed heights above the root parts, and anything
	crossing that single line hid the whole number: a lamp post, the edge of a
	doorway, a crate that covered one end of a plate the player could still
	read. Now any one of three points along the plate is enough.
]]
local function hasLineOfSight(fromEye: Vector3, points: { Vector3 }): boolean
	for _, point in points do
		if rayIsClear(fromEye, point) then
			return true
		end
	end
	return false
end

-- The viewer's eye. The camera is first person, so that is the head, with
-- the old root offset as a fallback for the frame a head is missing.
local function eyeOf(viewer: Player, rootPosition: Vector3): Vector3
	local character = codeCharacters[viewer]
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if head ~= nil and head:IsA("BasePart") then
		return head.Position
	end
	return rootPosition + Vector3.new(0, 1.5, 0)
end

--[[
	viewer -> code -> os.clock() of the last sweep that showed it, for
	Config.Code.SightGrace. Keyed by code rather than by holder so that a
	respawn, which is a new code on the same body, starts from nothing: grace
	must never hand out a number the viewer has not seen.

	Rebuilt from scratch every sweep, so nothing for a departed player or an
	expired code outlives one pass and there is no cleanup to forget.
]]
local lastSeen: { [Player]: { [string]: number } } = {}

--[[
	Tell every player the codes they can actually read, and nothing else.

	Two gates, cheapest first. Distance is a dot product; line of sight is a
	raycast, and it only runs for the pairs that already passed the distance
	test. At Roblox player counts the worst case is small -- 16 players is 240
	pairs, and only the ones within Config.Code.VisibleRange cost a cast, five
	times a second.

	Line of sight is what makes the range bound mean what the design says it
	means. Without it a player behind a wall is still handing you their number,
	and "break line of sight to hide your code" -- the same instinct as turning
	your back, which the front-only plate already rewards -- would do nothing.

	Squared distances, never magnitudes: one multiply against a constant
	instead of a square root per pair.
]]
local function sweepVisibility()
	local rangeSquared = Config.Code.VisibleRange * Config.Code.VisibleRange

	-- Snapshot once per sweep rather than per pair: every position below would
	-- otherwise be recomputed n times.
	local holders: { { player: Player, position: Vector3, code: string, plate: { Vector3 } } } = {}
	local bodies: { Instance } = {}
	for player, code in playerCodes do
		local position = visiblePosition(player)
		local character = codeCharacters[player]
		if position ~= nil then
			-- Above the head when the band is missing, which is roughly where
			-- the client's fallback billboard draws the number.
			local plate = if character ~= nil then platePoints(character) else nil
			table.insert(holders, {
				player = player,
				position = position,
				code = code,
				plate = plate or { position + Vector3.new(0, 2.6, 0) },
			})
		end
		if character ~= nil then
			table.insert(bodies, character)
		end
	end
	-- Rebuilt per sweep: players spawn and die between them, and a stale filter
	-- holding a destroyed character is a filter that stops excluding anything.
	sightParams.FilterDescendantsInstances = bodies

	local now = os.clock()
	local seenThisSweep: { [Player]: { [string]: number } } = {}

	for _, viewer in Players:GetPlayers() do
		local viewerPosition = visiblePosition(viewer)
		local previouslySeen = lastSeen[viewer]
		local seen: { [string]: number } = {}
		seenThisSweep[viewer] = seen

		--[[
			A viewer with no code of their own sees no codes at all, and that is
			a rule rather than a side effect. It covers a dead player in the
			killcam. Their code is released in the same step as the kill, and
			reroll gives the killer a new one, so this is what keeps the new
			number off the screen of the player who was just killed. Do not add
			spectating here without keeping that true.
		]]
		local entries: { { userId: number, code: string } } = {}
		if viewerPosition ~= nil then
			local eye = eyeOf(viewer, viewerPosition)

			for _, holder in holders do
				--[[
					Their own code is always included, and never raycast for.
					They cannot be killed by it, and the client needs it to know
					which headband is its own.
				]]
				if holder.player == viewer then
					table.insert(entries, { userId = holder.player.UserId, code = holder.code })
					continue
				end

				local delta = holder.position - viewerPosition
				if delta:Dot(delta) > rangeSquared then
					continue
				end

				-- The plate, not the body: see hasLineOfSight.
				local seenAt: number? = nil
				if hasLineOfSight(eye, holder.plate) then
					seenAt = now
				elseif previouslySeen ~= nil then
					--[[
						Blocked this sweep, but seen recently: keep the time it
						was last actually seen, not now, so grace runs out on
						schedule instead of renewing itself forever. Range was
						already checked above, so grace never reaches past it.
					]]
					local last: number? = previouslySeen[holder.code]
					if last ~= nil and now - last <= Config.Code.SightGrace then
						seenAt = last
					end
				end

				if seenAt ~= nil then
					seen[holder.code] = seenAt
					table.insert(entries, { userId = holder.player.UserId, code = holder.code })
				end
			end
		end

		-- Stable order, so an unchanged set produces an unchanged signature
		-- rather than resending on whatever order the dictionary iterated in.
		table.sort(entries, function(a, b)
			return a.userId < b.userId
		end)

		local parts: { string } = {}
		for _, entry in entries do
			table.insert(parts, `{entry.userId}:{entry.code}`)
		end
		local signature = table.concat(parts, ",")

		if visibilityDirty or lastSent[viewer] ~= signature then
			lastSent[viewer] = signature
			Net.codeVisibility.sendTo(entries, viewer)
		end
	end

	lastSeen = seenThisSweep
	visibilityDirty = false
end

function CodeService.Start()
	log.info(`ready ({DIGITS}-digit codes, visible within {Config.Code.VisibleRange} studs)`)

	--[[
		In Start, not Init: it loops and yields, which Init may not do
		(Loader.luau). One shared loop for every player rather than one per
		player -- the work is a single O(n^2) pass, and n timers would each
		redo most of it.
	]]
	--[[
		The same function, annotated only so the error value below is visible to
		the type checker. Luau models pcall's extra results as the WRAPPED
		function's returns, so a `() -> ()` is typed as handing back nothing but
		the boolean -- which is not what happens on the failure path, where pcall
		returns exactly one error value. Widening the return states that at the
		boundary instead of dropping `err` from the log.
	]]
	local sweep: () -> ...any = sweepVisibility

	while true do
		task.wait(Config.Code.VisibilityInterval)
		local ok, err = pcall(sweep)
		if not ok then
			-- Logged and continued: a sweep that throws must not end the loop,
			-- or every player silently stops seeing codes for the rest of the
			-- server's life.
			log.error(`visibility sweep failed: {err}`)
		end
	end
end

return CodeService
