--!strict
--[[
	Thrown grenades: the physics, the fuse, and what detonation means.

	THE SERVER OWNS THE PROJECTILE FROM HAND TO DETONATION. The client
	contributes exactly one value -- a direction, because only it knows where
	the camera is looking -- and the server builds the part, launches it, and
	KEEPS network ownership (`:SetNetworkOwner(nil)`). Handing ownership to the
	thrower is the obvious optimisation and it is also the exploit: the owner of
	a part decides its CFrame, so a thrower would be able to walk a live
	flashbang into the enemy spawn from across the map and have the server
	replicate it for them. The cost of refusing is about one round-trip of lag on
	the thrower's own view of their own grenade. That is a good trade.

	GRENADES NEVER DEAL DAMAGE. Not a balance decision to revisit -- the only way
	to kill in this game is to type somebody's code, so nothing in this file
	touches a Humanoid's Health. A flashbang sends a packet; smoke puts a cloud
	in the world. Both change what a player can SEE, and seeing is what the
	whole game is played with.

	WHY THE SMOKE CLOUD IS AN INSTANCE AND NOT A PACKET

	Net.luau says it outright: a client that drew its own cloud from a packet
	would have its vision blocked in a place nobody else's smoke covers, and
	"I shot you through your own smoke" is unarguable and unfixable after the
	fact. One server-created part, replicated by Roblox, is the only shape in
	which every player agrees where the smoke actually is.

	WHAT THE CLIENT STILL DECIDES

	Whether a flash is inside its view cone. The server knows where a character
	FACES; it does not know where the camera LOOKS, and no server can force a
	client to render white pixels anyway. So the two checks that can be enforced
	-- close enough, and not behind a wall -- are enforced here, and the cone is
	the client's (FlashController). Ignoring the packet gains an exploiter
	nothing they could not already get by not rendering it.

	NO PER-PLAYER TABLE. Live grenades are keyed by the PART, not the thrower: a
	grenade in flight belongs to the world, not to a player, and it must still go
	off if its thrower leaves mid-fuse. The only per-player state here is the
	rate limiter's, and RateLimiter clears that on PlayerRemoving itself -- so
	there is nothing in this file for a PlayerRemoving handler to clean up.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Items = require(ReplicatedStorage.Shared.Items)
local LoadoutService = require(script.Parent.LoadoutService)
local Log = require(ReplicatedStorage.Shared.Log)
local MapService = require(script.Parent.MapService)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantService = require(script.Parent.ParticipantService)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)

local log = Log.new("GrenadeService")

local throwLimit = RateLimiter.new(Config.RateLimit.ItemAction)

--[[
	Where the grenade leaves the hand. Eye height, and far enough forward to
	clear the thrower's own collision box: spawned inside it, the solver
	resolves the overlap by shoving the grenade out sideways, and the throw
	lands at the thrower's feet no matter where they aimed. That reads as the
	item being broken rather than as physics.
]]
local EYE_OFFSET = Vector3.new(0, 1.5, 0)
local MUZZLE_OFFSET = 2.5

-- The fallback projectile, used only when no asset was authored for the item.
local PROJECTILE_SIZE = Vector3.new(0.9, 0.9, 0.9)

local CLOUD_COLOR = Color3.fromRGB(196, 200, 206)
local CLOUD_TRANSPARENCY = 0.35
-- The cloud blooms out from this. Roblox clamps a part below 0.05 studs, so a
-- literal zero would be a lie about where the animation starts.
local CLOUD_SEED_SIZE = Vector3.new(0.2, 0.2, 0.2)

--[[
	Below this magnitude `direction` is not a direction -- there is no unit
	vector to recover from it, and dividing by it produces either infinity or
	NaN. A real aim vector from the client is 1.0.
]]
local MIN_DIRECTION_MAGNITUDE = 1e-3

type GrenadeKind = {
	FuseDuration: number,
	ThrowSpeed: number,
	-- `scheduledGeneration` is the round generation the fuse was lit under; a
	-- detonation with deferred steps of its own must not run them into a round
	-- that has already been cleared.
	detonate: (position: Vector3, scheduledGeneration: number) -> (),
}

--[[
	Everything this service has put into the world and has not taken back:
	projectiles in flight and clouds still standing. Keyed by the instance
	because that is the identity that matters at cleanup -- who threw it is
	irrelevant by then, and holding the Player would pin a leaver in memory for
	the length of a smoke.
]]
local liveParts: { [BasePart]: true } = {}

--[[
	Bumped every time the world is cleared. Every deferred step captures the
	value it was scheduled under and returns if it no longer matches.

	Luau has no cancellable `task.delay`, and the alternative -- a table of
	threads to `task.cancel` -- has to stay correct across three separate timers
	per cloud. One integer compared at the top of each callback cannot get out
	of step, and it fails in the safe direction: a stale timer does nothing.
]]
local generation = 0

--[[
	Asset paths already complained about. A mis-authored template would
	otherwise warn once per throw, which is a flood the output window does not
	survive and which buries the one line that matters.
]]
local warnedAssets: { [string]: true } = {}

--[[
	A BasePart under ServerStorage.Assets, by path, or nil.

	A MISSING asset is not an error at any level: the game ships before the art
	does, and a content gap must not stop a round. Every caller has a built
	fallback, so the absence is silent on purpose.

	An asset that EXISTS but is not a BasePart is different -- almost always a
	Model, which is the natural way to build a grenade in Studio and which this
	service deliberately does not take (it would need a PrimaryPart contract
	nobody has fixed). Falling back silently there hands a designer a grey ball
	and nothing to explain it, so it is said once, the way CodeService says it
	for a mis-authored Headband.
]]
local function assetPart(path: { string }): BasePart?
	local current: Instance? = ServerStorage:FindFirstChild("Assets")
	for _, name in path do
		if current == nil then
			return nil
		end
		current = current:FindFirstChild(name)
	end

	if current == nil then
		return nil
	end
	if not current:IsA("BasePart") then
		local fullName = `ServerStorage.Assets.{table.concat(path, ".")}`
		if not warnedAssets[fullName] then
			warnedAssets[fullName] = true
			log.warn(`{fullName} is a {current.ClassName}, not a BasePart -- using the generated fallback`)
		end
		return nil
	end
	return current
end

--[[
	The flags that have to hold for a cloned template's WHOLE assembly, not just
	the one part this file happens to hold a reference to.

	`:Clone()` brings the template's children with it, and a welded child part is
	still a part. Left queryable it blocks the flashbang's own line-of-sight cast
	-- the one thing this service promises a grenade in flight cannot do. Left
	touchable it trips a pickup node on the way past. Left ANCHORED it makes
	SetNetworkOwner throw, so the thrower loses the grenade to a decoration
	somebody anchored in Studio. Setting these on the root alone makes the
	comments below true of one part and false of the object.

	`canCollide` is optional because the two callers disagree for a reason: a
	grenade's root IS its collision hull and its decorative children keep
	whatever was authored (forcing a glow sphere solid would change how the
	grenade bounces), while a cloud has to be non-solid all the way down -- a
	vision blocker that also stops bodies is a wall.
]]
local function applyAssemblyFlags(root: BasePart, anchored: boolean, canCollide: boolean?)
	local parts: { BasePart } = { root }
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	for _, part in parts do
		part.Anchored = anchored
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		if canCollide ~= nil then
			part.CanCollide = canCollide
		end
	end
end

--[[
	Grenades live INSIDE the map when there is one, so `MapService.unload()`
	takes them with it -- a flash cannot outlive the geometry it was thrown at.

	The contract's MapService API answers "is a map loaded" but does not hand out
	the model, so the instance is looked up by the name unload() destroys. Asking
	MapService first rather than trusting the name alone means a stray Workspace
	child called ActiveMap cannot become the parent of every grenade in the game.
]]
local function grenadeParent(): Instance
	if MapService.isLoaded() then
		local map = Workspace:FindFirstChild("ActiveMap")
		if map ~= nil then
			return map
		end
	end
	return Workspace
end

--[[
	The player's Humanoid if they are spawned and alive, else nil. Both throwing
	and being flashed require this, and "no character yet" and "ragdolled on the
	floor" are the same answer to both.
]]
local function livingHumanoid(player: Player): Humanoid?
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return humanoid
end

--[[
	Where this player's eyes are, for the line-of-sight test. The head, because
	that is what a player sees out of and what a waist-high crate should be able
	to hide from a blast at floor level; the root plus eye height only when a
	rig has no Head to find (R6 and R15 both do, custom rigs may not).
]]
local function eyePosition(player: Player): Vector3?
	local humanoid = livingHumanoid(player)
	if humanoid == nil then
		return nil
	end

	local character = humanoid.Parent
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if head ~= nil and head:IsA("BasePart") then
		return head.Position
	end

	local root = humanoid.RootPart
	return if root ~= nil then root.Position + EYE_OFFSET else nil
end

--[[
	`raw` as a unit vector, or nil if it is not a direction at all.

	THE ORDER IS THE POINT: components first, magnitude second. The magnitude of
	a vector holding a NaN is itself NaN, and every comparison against NaN is
	false -- so a `magnitude < MIN` guard would wave it straight through into a
	CFrame and take the throw handler down with it (quality-gate.md trap #8).
	An infinite component gives an infinite magnitude and a division that yields
	NaN, with the same ending.

	The magnitude is then re-checked for infinity even though the components are
	known finite, because a merely huge component squares to infinity: 1e200
	passes every check above, and 1e200/inf is 0, which would produce a "unit"
	vector of zero length and a grenade that drops out of the sky.
]]
local function unitDirection(raw: Vector3): Vector3?
	local x, y, z = raw.X, raw.Y, raw.Z
	if x ~= x or y ~= y or z ~= z then
		return nil
	end
	if math.abs(x) == math.huge or math.abs(y) == math.huge or math.abs(z) == math.huge then
		return nil
	end

	local magnitude = math.sqrt(x * x + y * y + z * z)
	if magnitude ~= magnitude or magnitude == math.huge or magnitude < MIN_DIRECTION_MAGNITUDE then
		return nil
	end

	return Vector3.new(x / magnitude, y / magnitude, z / magnitude)
end

local function createProjectile(itemId: string, definition: Items.ItemDefinition?): BasePart
	local template = assetPart({ "Items", itemId })
	local part: BasePart

	if template ~= nil then
		part = template:Clone()
	else
		-- A content gap must not eat the item. An ugly grey ball that flies and
		-- detonates correctly is diagnosable; a throw that silently produces
		-- nothing is blamed on the netcode for a week.
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Size = PROJECTILE_SIZE
		ball.Material = Enum.Material.Metal
		ball.Color = if definition ~= nil then definition.Color else Color3.fromRGB(120, 120, 120)
		part = ball
	end

	part.Name = itemId
	--[[
		Unanchored, and out of every raycast and every Touched event in the game,
		across the whole clone. Anchored is asserted rather than assumed because a
		designer who anchors the template in Studio would otherwise get a grenade
		that hangs in the air AND a thrown error out of SetNetworkOwner; the query
		and touch flags because a live grenade must not block the flashbang's own
		line-of-sight test and must not trip a pickup node on the way past.
	]]
	applyAssemblyFlags(part, false)
	-- Only the root: the template's own children keep the collision the designer
	-- gave them. See applyAssemblyFlags.
	part.CanCollide = true
	return part
end

--[[
	Tell every playing client that can actually see the blast.

	Two server-side rungs, in cost order: a range compare that costs nothing,
	then one raycast for the players who survived it. Characters are excluded
	from the cast because a teammate standing in the doorway is not cover -- the
	test is for WALLS, and a flash that a body absorbs is a flash whose
	behaviour depends on where somebody else happens to be standing.
]]
local function detonateFlash(position: Vector3, _scheduledGeneration: number)
	local filter: { Instance } = {}
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character ~= nil then
			table.insert(filter, character)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true

	for _, other in Players:GetPlayers() do
		if not ParticipantService.isPlaying(other) then
			continue
		end

		local eye = eyePosition(other)
		if eye == nil then
			continue
		end

		local offset = eye - position
		local distance = offset.Magnitude
		if distance > Config.Flash.MaxRange then
			continue
		end

		-- A blast inside somebody's head has no direction to cast along, and
		-- Workspace:Raycast with a zero vector answers nil anyway. Skipping the
		-- cast says why, instead of relying on that.
		if distance > MIN_DIRECTION_MAGNITUDE and Workspace:Raycast(position, offset, params) ~= nil then
			continue
		end

		--[[
			closeRange tells the client to skip its view-cone test: a flash at
			your feet blinds you whichever way you are facing (Config.Flash's
			own comment). Outside it, the cone is the client's call -- it owns
			the camera, and this server does not know where the player is
			looking.
		]]
		Net.flashDetonated.sendTo({
			position = position,
			closeRange = distance <= Config.Flash.CloseRange,
		}, other)
	end
end

--[[
	Stand a cloud up where the grenade went off, and take it down again.

	The timeline is GrowDuration in, a hold, then FadeDuration out, all INSIDE
	Config.Smoke.Duration rather than added to it -- so "a smoke lasts fifteen
	seconds" stays true no matter how the bloom is tuned.

	The tweens run on the SERVER, which replicates the resulting property values
	rather than the interpolation, so a distant client sees a slightly coarser
	bloom than a local one would. That is the price of everyone agreeing on the
	same cloud, and it is worth paying: a client-side animation would be a
	client-side decision about when vision is blocked.
]]
local function detonateSmoke(position: Vector3, scheduledGeneration: number)
	local template = assetPart({ "SmokeCloud" })
	local cloud: BasePart

	if template ~= nil then
		cloud = template:Clone()
	else
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Material = Enum.Material.SmoothPlastic
		ball.Color = CLOUD_COLOR
		cloud = ball
	end

	cloud.Name = "SmokeCloud"
	--[[
		A cloud is a vision blocker and nothing else, all the way down. Left
		queryable it would turn up as geometry in every raycast on the server --
		including the flashbang test above, where smoke would start acting as a
		wall, and including anything that asks "is this spawn point sheltered" --
		and left solid it would be an invisible wall players walk into.
	]]
	applyAssemblyFlags(cloud, true, false)
	cloud.Size = CLOUD_SEED_SIZE
	cloud.Transparency = 1
	cloud.CFrame = CFrame.new(position)
	cloud.Parent = grenadeParent()
	liveParts[cloud] = true

	local fullSize = Vector3.one * (Config.Smoke.Radius * 2)
	local grow = TweenService:Create(
		cloud,
		TweenInfo.new(Config.Smoke.GrowDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = fullSize, Transparency = CLOUD_TRANSPARENCY }
	)
	grow:Play()

	local fadeAt = math.max(Config.Smoke.Duration - Config.Smoke.FadeDuration, 0)
	task.delay(fadeAt, function()
		-- Cleared by a round end, or destroyed with the map underneath it.
		if generation ~= scheduledGeneration or cloud.Parent == nil then
			return
		end
		local fade = TweenService:Create(cloud, TweenInfo.new(Config.Smoke.FadeDuration), { Transparency = 1 })
		fade:Play()
	end)

	task.delay(Config.Smoke.Duration, function()
		-- No generation guard: Destroy on an already-destroyed instance is a
		-- no-op, and a cloud that somehow survived its round must go regardless.
		liveParts[cloud] = nil
		cloud:Destroy()
	end)
end

--[[
	What each throwable DOES. Items.luau is the catalog -- what exists, what it
	is called, what colour its slot is -- and this is the behaviour; an item in
	the catalog with no row here is simply not throwable, which is the branch
	Items.luau's header points at for adding a third grenade.
]]
local GRENADES: { [string]: GrenadeKind } = {
	Flashbang = {
		FuseDuration = Config.Flash.FuseDuration,
		ThrowSpeed = Config.Flash.ThrowSpeed,
		detonate = detonateFlash,
	},
	SmokeGrenade = {
		FuseDuration = Config.Smoke.FuseDuration,
		ThrowSpeed = Config.Smoke.ThrowSpeed,
		detonate = detonateSmoke,
	},
}

--[[
	Every grenade and cloud, gone. Called when the round leaves RoundActive.

	A flash from the previous round going off over the new one's spawn points is
	the bug this exists to prevent, and it is not hypothetical: the fuse is 1.6
	seconds and a round can end on any of them.
]]
local function clearWorld()
	generation += 1
	for part in liveParts do
		part:Destroy()
	end
	table.clear(liveParts)
end

local function onThrow(data: { slot: number, direction: Vector3 }, player: Player)
	-- First, before any other work and before any logging: the only safe
	-- response to a flood is to drop it having spent nothing (RateLimiter.luau).
	if not throwLimit.allow(player) then
		return
	end

	--[[
		isPlaying carries most of this, but the round state is checked in its own
		right: a grenade thrown on the last frame of a round would light a fuse
		that outlives the round, and clearWorld cannot reach a projectile that
		has not been created yet.
	]]
	if not RoundService.isRoundActive() or not ParticipantService.isPlaying(player) then
		return
	end

	local humanoid = livingHumanoid(player)
	local root = if humanoid ~= nil then humanoid.RootPart else nil
	if root == nil then
		return
	end

	--[[
		ByteNet's uint8 guarantees the SHAPE -- an integer in 0..255 -- and
		nothing at all about the meaning. Slot 0 and slot 7 both arrive perfectly
		well formed, and slot 0 would index nothing while slot 7 would read past
		the toolbar the player actually has.
	]]
	local slot = data.slot
	if slot ~= slot or math.floor(slot) ~= slot or slot < 1 or slot > Config.Toolbar.SlotCount then
		return
	end

	local direction = unitDirection(data.direction)
	if direction == nil then
		return
	end

	--[[
		Peek, validate, then consume. consume() is destructive and there is no
		put-back, so an empty slot -- or an item with no throw behaviour -- has to
		be rejected BEFORE it costs the player the item. Nothing between the peek
		and the consume yields, so a second packet cannot take the slot in
		between: the same read-modify-write discipline CashService.add applies to
		a balance, for the same reason.
	]]
	local slots = LoadoutService.getSlots(player)
	local itemId = slots[slot]
	local grenade = GRENADES[itemId]
	if grenade == nil then
		return
	end
	if LoadoutService.consume(player, slot) == nil then
		return
	end

	local part = createProjectile(itemId, Items.byId(itemId))
	part.CFrame = CFrame.new(root.Position + EYE_OFFSET + direction * MUZZLE_OFFSET)
	part.Parent = grenadeParent()
	liveParts[part] = true

	-- After parenting, not before: a part outside the world belongs to no
	-- assembly, and a velocity written to one that does not exist yet is
	-- discarded silently -- the grenade then simply drops.
	part.AssemblyLinearVelocity = direction * grenade.ThrowSpeed

	--[[
		THE LINE THIS SERVICE EXISTS FOR. nil means "the server simulates it",
		which is what stops the thrower from steering, stopping or teleporting
		their own grenade.

		pcall'd because SetNetworkOwner throws on an anchored assembly, and the
		one way that happens is a Studio-authored template welded to something
		anchored. Losing the grenade is the right outcome there -- what must not
		happen is the throw handler dying halfway and leaving a part in flight
		that the thrower owns.
	]]
	local owned = pcall(part.SetNetworkOwner, part, nil)
	if not owned then
		log.warn(`{itemId} could not be server-owned (an anchored asset?) -- destroyed instead of client-owned`)
		liveParts[part] = nil
		part:Destroy()
		return
	end

	local scheduledGeneration = generation
	task.delay(grenade.FuseDuration, function()
		if generation ~= scheduledGeneration then
			-- The round ended mid-flight; clearWorld already destroyed the part.
			return
		end
		if part.Parent == nil then
			-- The map was unloaded under it. Its position is meaningless now.
			liveParts[part] = nil
			return
		end

		-- The blast is where the part WAS: destroy first, so nothing about the
		-- detonation can see the grenade that caused it.
		local position = part.Position
		liveParts[part] = nil
		part:Destroy()

		grenade.detonate(position, scheduledGeneration)
	end)
end

local GrenadeService = {}

function GrenadeService.Init()
	Net.throwItem.listen(function(data, player)
		if player == nil then
			return
		end
		onThrow(data, player)
	end)

	--[[
		LEAVING RoundActive, not entering Lobby. The round can end into
		RoundResults or fall back to Lobby, and a live flash has to be gone in
		both -- the results screen is not a place to be blinded.
	]]
	RoundService.onStateChanged(function(state, previous)
		if previous == "RoundActive" and state ~= "RoundActive" then
			clearWorld()
		end
	end)
end

function GrenadeService.Start()
	log.info("ready")
end

return GrenadeService
