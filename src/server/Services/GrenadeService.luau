--!strict
--[[
	Thrown grenades: the physics, the fuse, and what detonation means.

	THE SERVER OWNS THE PROJECTILE FROM HAND TO DETONATION. The client
	contributes two values -- a direction, because only it knows where the
	camera is looking, and how full the charge bar was -- and the server builds
	the part and flies it. The flight is SIMULATED, not physics
	(Modules/Ballistics.luau, Config.Throw): the part is anchored and moved
	here every Heartbeat to where the simulation says, so no client ever owns
	it. Client ownership would be the exploit: the owner of a part decides its
	CFrame, so a thrower could walk a live flashbang into the enemy spawn from
	across the map. The cost is about one round-trip of lag on the thrower's
	own view of their own grenade. That is a good trade.

	GRENADES NEVER DEAL DAMAGE. Not a balance decision to revisit -- the only way
	to kill in this game is to type somebody's code, so nothing in this file
	touches a Humanoid's Health. A flashbang sends a packet; smoke puts a cloud
	in the world. Both change what a player can SEE, and seeing is what the
	whole game is played with. The frag is the exception to "seeing": it
	freezes enemies in place (SprintService.stun), so they cannot run or turn
	their code away while somebody reads it. It still deals no damage.

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
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Ballistics = require(ServerStorage.Modules.Ballistics)
local Config = require(ReplicatedStorage.Shared.Config)
local Items = require(ReplicatedStorage.Shared.Items)
local LoadoutService = require(script.Parent.LoadoutService)
local Log = require(ReplicatedStorage.Shared.Log)
local MapService = require(script.Parent.MapService)
local Match = require(ReplicatedStorage.Shared.Match)
local Net = require(ReplicatedStorage.Shared.Net)
local ParticipantService = require(script.Parent.ParticipantService)
local RateLimiter = require(ServerStorage.Modules.RateLimiter)
local RoundService = require(script.Parent.RoundService)
local SpawnService = require(script.Parent.SpawnService)
local SprintService = require(script.Parent.SprintService)
local TeamService = require(script.Parent.TeamService)

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

--[[
	Who threw it, captured when the fuse was lit. The team is read at the throw
	rather than at the blast: the thrower can leave mid-fuse, and a grenade
	must still know whose side it was on when it goes off.
]]
type Thrower = {
	player: Player,
	-- nil in Free For All, where there are no sides to spare.
	team: Match.TeamId?,
}

type GrenadeKind = {
	FuseDuration: number,
	-- Stops dead on the first surface it touches instead of bouncing.
	Sticky: boolean,
	-- `scheduledGeneration` is the round generation the fuse was lit under; a
	-- detonation with deferred steps of its own must not run them into a round
	-- that has already been cleared.
	detonate: (position: Vector3, scheduledGeneration: number, thrower: Thrower) -> (),
}

--[[
	Everything this service has put into the world and has not taken back:
	projectiles in flight and clouds still standing. Keyed by the instance
	because that is the identity that matters at cleanup -- who threw it is
	irrelevant by then, and holding the Player would pin a leaver in memory for
	the length of a smoke.
]]
local liveParts: { [BasePart]: true } = {}

-- Grenades in flight, and the simulated body each one follows. A subset of
-- liveParts: a grenade leaves this at detonation, a cloud is never in it.
local flights: { [BasePart]: Ballistics.Body } = {}
-- The one Heartbeat that steps every flight; connected only while there is
-- something in flight (TitleStyle.luau makes the same choice).
local flightConnection: RBXScriptConnection? = nil

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
	touchable it trips a pickup node on the way past. Left ANCHORED, a child
	stays where it was cloned while the root flies. Setting these on the root
	alone makes the comments below true of one part and false of the object.

	`canCollide` is optional; both callers pass false today. A grenade's flight
	is simulated (Ballistics), so its parts are only a picture, and a cloud
	has to be non-solid all the way down -- a vision blocker that also stops
	bodies is a wall.
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
		Out of every raycast, every Touched event and all collision, across the
		whole clone: the flight is simulated (Ballistics), so the part is only
		the picture of where the grenade is. Queryable, it would block the
		flashbang's own line-of-sight test and the simulation's sweeps;
		touchable, it would trip a pickup node on the way past; solid, it would
		shove a player it is carried through.

		The ROOT is anchored and moved by CFrame each step. Its children are
		left unanchored so their welds carry them along with it -- an anchored
		child would stay behind where it was cloned.
	]]
	applyAssemblyFlags(part, false, false)
	part.Anchored = true
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
local function detonateFlash(position: Vector3, _scheduledGeneration: number, _thrower: Thrower)
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
local function detonateSmoke(position: Vector3, scheduledGeneration: number, _thrower: Thrower)
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

local STUN_EFFECT_NAME = "StunEffect"
-- Electric yellow: loud against every map palette, and not the cyan the UI
-- uses for "this is yours" or the red and blue the teams use.
local STUN_COLOR = Color3.fromRGB(255, 221, 64)

--[[
	What everyone else sees on a stunned player: yellow sparks crackling over
	the torso for as long as the stun lasts.

	On the torso, not the head, on purpose. The code plate hangs in front of
	the head, and a stun is exactly when enemies are trying to read it. An
	effect over the plate would make a stun protect the player it hit.

	Built on the SERVER and parented into the character, so it replicates to
	everyone with no packet, and it dies with the body if they die mid-stun.
	ServerStorage.Assets.StunEffect overrides the fallback when it is authored
	(any Instance; it is cloned into the HumanoidRootPart).
]]
local function attachStunEffect(character: Model, duration: number)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	-- One effect per body. A second frag extends the stun; it should not
	-- double the sparks.
	local existing = root:FindFirstChild(STUN_EFFECT_NAME)
	if existing ~= nil then
		existing:Destroy()
	end

	local assets = ServerStorage:FindFirstChild("Assets")
	local template = if assets ~= nil then assets:FindFirstChild(STUN_EFFECT_NAME) else nil
	local effect: Instance
	if template ~= nil then
		effect = template:Clone()
	else
		local sparks = Instance.new("ParticleEmitter")
		sparks.Color = ColorSequence.new(STUN_COLOR)
		sparks.LightEmission = 1
		sparks.LightInfluence = 0
		sparks.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparks.Lifetime = NumberRange.new(0.3, 0.6)
		sparks.Rate = 40
		sparks.Speed = NumberRange.new(3, 6)
		sparks.SpreadAngle = Vector2.new(180, 180)
		-- Spawned over the root part's surface, which is the torso's footprint.
		sparks.Shape = Enum.ParticleEmitterShape.Box
		sparks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		effect = sparks
	end

	effect.Name = STUN_EFFECT_NAME
	effect.Parent = root

	task.delay(duration, function()
		-- Only if it is still this effect: a second frag replaced it with one
		-- of its own that must run its full length.
		if effect.Parent == root then
			effect:Destroy()
		end
	end)
end

--[[
	Every enemy close enough, with a clear line to the blast, is frozen for
	Config.Frag.StunDuration.

	Never the thrower, and never the thrower's team. The team was read when the
	fuse was lit (Thrower). In a team mode with no team to read, nobody is
	stunned: refusing the whole blast is the side that cannot stun a teammate.

	Line of sight to the head OR the root: either is enough, so a waist-high
	crate between you and the blast does not save you, and a wall does. Bodies
	do not count as cover, for the same reason detonateFlash gives.

	A player still under spawn protection is skipped, as a kill would be
	(KillService). Freezing someone on the spawn for three seconds is a
	spawn-camp.
]]
local function enemiesInBlast(position: Vector3, radius: number, thrower: Thrower): { Player }
	local caught: { Player } = {}
	local usesTeams = RoundService.getTeamMode().UsesTeams
	if usesTeams and thrower.team == nil then
		log.debug(`blast from {thrower.player.Name} with no team -- hit nobody`)
		return caught
	end

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

	local function clearTo(point: Vector3): boolean
		local offset = point - position
		if offset.Magnitude <= MIN_DIRECTION_MAGNITUDE then
			return true
		end
		return Workspace:Raycast(position, offset, params) == nil
	end

	for _, other in Players:GetPlayers() do
		if other == thrower.player then
			continue
		end
		if usesTeams and TeamService.getTeam(other) == thrower.team then
			continue
		end
		if not ParticipantService.isPlaying(other) or SpawnService.isProtected(other) then
			continue
		end

		local humanoid = livingHumanoid(other)
		local root = if humanoid ~= nil then humanoid.RootPart else nil
		local eye = eyePosition(other)
		if root == nil or eye == nil then
			continue
		end

		-- The nearer of head and root, so a blast at someone's feet counts
		-- as a blast at their feet.
		local distance = math.min((eye - position).Magnitude, (root.Position - position).Magnitude)
		if distance > radius then
			continue
		end
		if not clearTo(eye) and not clearTo(root.Position) then
			continue
		end

		table.insert(caught, other)
	end
	return caught
end

local function detonateFrag(position: Vector3, _scheduledGeneration: number, thrower: Thrower)
	local endsAt = Workspace:GetServerTimeNow() + Config.Frag.StunDuration
	for _, other in enemiesInBlast(position, Config.Frag.Radius, thrower) do
		if SprintService.stun(other, Config.Frag.StunDuration) then
			local character = other.Character
			if character ~= nil then
				attachStunEffect(character, Config.Frag.StunDuration)
			end
			Net.stunned.sendTo({ endsAt = endsAt }, other)
		end
	end
end

local SHOCK_EFFECT_NAME = "ShockEffect"
-- Electric blue: the item's slot colour, and clearly not the frag's yellow.
local SHOCK_COLOR = Color3.fromRGB(90, 190, 255)
local SHOCK_CORE = Color3.fromRGB(225, 245, 255)
-- The blast: a sphere that grows to the Radius, then fades.
local SHOCK_BLAST_GROW = 0.3
local SHOCK_BLAST_FADE = 0.4

--[[
	Electricity on a shocked player, for everyone to see: fast blue-white
	arcs crackling off the torso and a steady blue glow. Built on the SERVER
	and parented into the character, so it replicates with no packet and dies
	with the body -- attachStunEffect's reasoning, and on the torso for the
	same reason (never over the code plate). ServerStorage.Assets.ShockEffect
	overrides the fallback when it is authored.

	The glow is steady, not flickering: a light that pulsed would flash
	(GAMEPLAY.md, the photosensitivity rule).
]]
local function attachShockEffect(character: Model, duration: number)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	-- One effect per body; a second shock restarts it.
	local existing = root:FindFirstChild(SHOCK_EFFECT_NAME)
	if existing ~= nil then
		existing:Destroy()
	end

	local assets = ServerStorage:FindFirstChild("Assets")
	local template = if assets ~= nil then assets:FindFirstChild(SHOCK_EFFECT_NAME) else nil
	local effect: Instance
	if template ~= nil then
		effect = template:Clone()
	else
		local folder = Instance.new("Folder")

		-- The arcs: short, fast, stretched streaks.
		local arcs = Instance.new("ParticleEmitter")
		arcs.Name = "Arcs"
		arcs.Color = ColorSequence.new(SHOCK_CORE, SHOCK_COLOR)
		arcs.LightEmission = 1
		arcs.LightInfluence = 0
		arcs.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 0),
		})
		arcs.Squash = NumberSequence.new(-1.5)
		arcs.Lifetime = NumberRange.new(0.08, 0.18)
		arcs.Rate = 90
		arcs.Speed = NumberRange.new(10, 18)
		arcs.SpreadAngle = Vector2.new(180, 180)
		arcs.Orientation = Enum.ParticleOrientation.VelocityParallel
		arcs.Shape = Enum.ParticleEmitterShape.Box
		arcs.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		arcs.Parent = folder

		-- Sparks: small bright points that hang a little longer.
		local sparks = Instance.new("ParticleEmitter")
		sparks.Name = "Sparks"
		sparks.Color = ColorSequence.new(SHOCK_COLOR)
		sparks.LightEmission = 1
		sparks.LightInfluence = 0
		sparks.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.18),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparks.Lifetime = NumberRange.new(0.25, 0.45)
		sparks.Rate = 35
		sparks.Speed = NumberRange.new(2, 5)
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks.Shape = Enum.ParticleEmitterShape.Box
		sparks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		sparks.Parent = folder

		local glow = Instance.new("PointLight")
		glow.Name = "Glow"
		glow.Color = SHOCK_COLOR
		glow.Brightness = 1.5
		glow.Range = 8
		glow.Parent = folder

		effect = folder
	end

	effect.Name = SHOCK_EFFECT_NAME
	effect.Parent = root

	task.delay(duration, function()
		if effect.Parent == root then
			effect:Destroy()
		end
	end)
end

--[[
	A blast everyone sees: an energy sphere of `color` that grows to `radius`
	in SHOCK_BLAST_GROW and fades out over SHOCK_BLAST_FADE. One swell, never a
	strobe. Tracked in liveParts so a round ending mid-blast takes it. The
	shock's is blue, the impulse's magenta.
]]
local function playBlast(position: Vector3, scheduledGeneration: number, name: string, radius: number, color: Color3)
	local sphere = Instance.new("Part")
	sphere.Name = name
	sphere.Shape = Enum.PartType.Ball
	sphere.Material = Enum.Material.ForceField
	sphere.Color = color
	sphere.Transparency = 0.1
	sphere.Size = Vector3.new(1, 1, 1)
	sphere.CFrame = CFrame.new(position)
	applyAssemblyFlags(sphere, true, false)
	sphere.Parent = grenadeParent()
	liveParts[sphere] = true

	local diameter = radius * 2
	TweenService:Create(sphere, TweenInfo.new(SHOCK_BLAST_GROW, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(diameter, diameter, diameter),
	}):Play()

	task.delay(SHOCK_BLAST_GROW, function()
		if generation ~= scheduledGeneration or sphere.Parent == nil then
			return
		end
		TweenService:Create(sphere, TweenInfo.new(SHOCK_BLAST_FADE), { Transparency = 1 }):Play()
		task.delay(SHOCK_BLAST_FADE, function()
			liveParts[sphere] = nil
			sphere:Destroy()
		end)
	end)
end

--[[
	Every enemy close enough, with a clear line to the blast, is slowed and
	loses their sprint for Config.Shock.SlowDuration -- the same targeting as
	the frag (enemiesInBlast), over the shock's wider radius.
]]
local function detonateShock(position: Vector3, scheduledGeneration: number, thrower: Thrower)
	playBlast(position, scheduledGeneration, "ShockBlast", Config.Shock.Radius, SHOCK_COLOR)

	local duration = Config.Shock.SlowDuration
	local endsAt = Workspace:GetServerTimeNow() + duration
	for _, other in enemiesInBlast(position, Config.Shock.Radius, thrower) do
		if SprintService.slow(other, duration) then
			local character = other.Character
			if character ~= nil then
				attachShockEffect(character, duration)
			end
			Net.shocked.sendTo({ endsAt = endsAt }, other)
		end
	end
end

local IMPULSE_COLOR = Color3.fromRGB(235, 90, 220)

--[[
	The launch one player gets from an impulse blast at `position`: along the
	line from the blast to their HumanoidRootPart, at a speed that falls off
	from Config.Impulse.MaxSpeed at the blast to MinSpeed at the edge of the
	Radius. Straight up when they are (almost) exactly on top of it.
]]
local function impulseVelocity(position: Vector3, rootPosition: Vector3): Vector3
	local impulse = Config.Impulse
	local offset = rootPosition - position
	local distance = offset.Magnitude
	local direction = if distance > MIN_DIRECTION_MAGNITUDE then offset / distance else Vector3.new(0, 1, 0)
	local closeness = 1 - math.clamp(distance / impulse.Radius, 0, 1)
	local speed = impulse.MinSpeed + (impulse.MaxSpeed - impulse.MinSpeed) * closeness
	return direction * speed
end

--[[
	The impulse grenade's blast: every player in the round within
	Config.Impulse.Radius -- the thrower and teammates too, because it is a
	movement tool -- with a clear line from the blast to their root is sent
	flying away from it (impulseVelocity).

	The velocity is computed here and APPLIED by the player's own client
	(Net.impulse, ImpulseController): the client owns its character's physics,
	and a velocity written by the server would be overwritten by the client's
	next step. Nobody is ragdolled or loses control; it is only a push.
]]
local function detonateImpulse(position: Vector3, scheduledGeneration: number, _thrower: Thrower)
	playBlast(position, scheduledGeneration, "ImpulseBlast", Config.Impulse.Radius, IMPULSE_COLOR)

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
		local humanoid = livingHumanoid(other)
		local root = if humanoid ~= nil then humanoid.RootPart else nil
		if root == nil then
			continue
		end
		local offset = root.Position - position
		if offset.Magnitude > Config.Impulse.Radius then
			continue
		end
		-- A wall between the blast and the player shields them.
		if offset.Magnitude > MIN_DIRECTION_MAGNITUDE and Workspace:Raycast(position, offset, params) ~= nil then
			continue
		end
		Net.impulse.sendTo({ velocity = impulseVelocity(position, root.Position) }, other)
	end
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
		Sticky = false,
		detonate = detonateFlash,
	},
	SmokeGrenade = {
		FuseDuration = Config.Smoke.FuseDuration,
		Sticky = false,
		detonate = detonateSmoke,
	},
	FragGrenade = {
		FuseDuration = Config.Frag.FuseDuration,
		Sticky = false,
		detonate = detonateFrag,
	},
	ShockGrenade = {
		FuseDuration = Config.Shock.FuseDuration,
		Sticky = false,
		detonate = detonateShock,
	},
	ImpulseGrenade = {
		FuseDuration = Config.Impulse.FuseDuration,
		Sticky = true,
		detonate = detonateImpulse,
	},
}

--[[
	What a grenade in flight can hit: the world, never a body. Characters are
	excluded because a grenade that bounces off a moving player is a grenade
	whose landing depends on where somebody else happened to step -- and the
	thrower's own body would otherwise catch the throw at the hand. Grenades
	and clouds are CanQuery false (applyAssemblyFlags), so they are skipped
	without being listed.
]]
local function flightParams(): RaycastParams
	local characters: { Instance } = {}
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character ~= nil then
			table.insert(characters, character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = characters
	return params
end

local function stepFlights(dt: number)
	local params = flightParams()
	for part, body in flights do
		if part.Parent == nil then
			-- The map went, and the part with it. The fuse still holds it and
			-- tidies liveParts up.
			flights[part] = nil
			continue
		end
		Ballistics.step(body, dt, params)
		part.CFrame = CFrame.new(body.position) * body.spin
		if body.resting then
			-- Where it will go off. Nothing moves it from here.
			flights[part] = nil
		end
	end

	if next(flights) == nil then
		local connection = flightConnection
		flightConnection = nil
		if connection ~= nil then
			connection:Disconnect()
		end
	end
end

local function startFlight(part: BasePart, body: Ballistics.Body)
	flights[part] = body
	if flightConnection == nil then
		flightConnection = RunService.Heartbeat:Connect(stepFlights)
	end
end

--[[
	Where the grenade leaves the hand: MUZZLE_OFFSET ahead of the eyes, or
	short of whatever is in the way. A player throwing with their face against
	a wall would otherwise start the grenade on the far side of it.
]]
local function launchPosition(eye: Vector3, direction: Vector3): Vector3
	local reach = direction * MUZZLE_OFFSET
	local blocked = Workspace:Raycast(eye, reach, flightParams())
	if blocked == nil then
		return eye + reach
	end
	local clearance = Config.Throw.ProjectileRadius + 0.05
	return eye + direction * math.max(blocked.Distance - clearance, 0)
end

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
	-- The Heartbeat sees an empty table on its next step and disconnects.
	table.clear(flights)
end

local function onThrow(data: { slot: number, direction: Vector3, charge: number }, player: Player)
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

	-- NaN first: it fails every comparison, so a clamp alone would pass it
	-- straight into the speed (quality-gate.md trap #8). Out-of-range is
	-- clamped rather than refused; a full charge is legal anyway.
	local charge = data.charge
	if charge ~= charge then
		return
	end
	charge = math.clamp(charge, 0, 1)

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

	local throw = Config.Throw
	local speed = throw.MinSpeed + (throw.MaxSpeed - throw.MinSpeed) * charge
	local start = launchPosition(root.Position + EYE_OFFSET, direction)

	local part = createProjectile(itemId, Items.byId(itemId))
	part.CFrame = CFrame.new(start)
	part.Parent = grenadeParent()
	liveParts[part] = true
	-- The camera's direction, exactly: looking up throws up.
	startFlight(part, Ballistics.new(start, direction * speed, grenade.Sticky))

	local thrower: Thrower = { player = player, team = TeamService.getTeam(player) }

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
		flights[part] = nil
		part:Destroy()

		grenade.detonate(position, scheduledGeneration, thrower)
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

--[[
	A frag's stun on one player, without the frag: the freeze, the sparks
	everyone sees, and the STUNNED warning on their own screen. For the admin
	panel, so an admin stun looks and behaves exactly like a real one rather
	than being a bare freeze nobody can see. False if there was no living body
	to stun.
]]
function GrenadeService.stunPlayer(player: Player, duration: number): boolean
	-- A NaN or negative duration would pin or skip the freeze (trap #8).
	if duration ~= duration or duration <= 0 then
		return false
	end
	if not SprintService.stun(player, duration) then
		return false
	end
	local character = player.Character
	if character ~= nil then
		attachStunEffect(character, duration)
	end
	Net.stunned.sendTo({ endsAt = Workspace:GetServerTimeNow() + duration }, player)
	return true
end

--[[
	A shock grenade's effect on one player, without the grenade: the slow and
	lost sprint, the arcs everyone sees, and the SHOCKED warning on their own
	screen. For the admin panel, like stunPlayer. False if there was no living
	body to shock.
]]
function GrenadeService.shockPlayer(player: Player, duration: number): boolean
	-- A NaN or negative duration would pin or skip the slow (trap #8).
	if duration ~= duration or duration <= 0 then
		return false
	end
	if not SprintService.slow(player, duration) then
		return false
	end
	local character = player.Character
	if character ~= nil then
		attachShockEffect(character, duration)
	end
	Net.shocked.sendTo({ endsAt = Workspace:GetServerTimeNow() + duration }, player)
	return true
end

function GrenadeService.Start()
	log.info("ready")
end

return GrenadeService
