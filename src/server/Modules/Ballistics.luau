--!strict
--[[
	The flight of a thrown grenade, computed rather than left to the physics
	engine.

	A plain module (ARCHITECTURE.md Recipe 3): no lifecycle, no instances. It
	advances a Body -- a position and a velocity -- by a time step against the
	world, and GrenadeService moves an anchored part to wherever the Body says.

	WHY NOT ROBLOX PHYSICS

	An unanchored part with a launch velocity is at the mercy of the solver:
	it skates across the floor on low friction, tunnels through thin walls at
	speed, and bounces differently with every mass and material a designer
	gives the asset. A simulated body behaves the same on every map and for
	every asset, and every number that shapes it is in Config.Throw.

	HOW A STEP WORKS

	  1. On the ground (a short sphere cast straight down finds a floor, and
	     the body is not moving away from it): the speed into the floor is
	     removed, gravity along a slope still pulls, and RollDeceleration
	     bleeds the rest off. Below SettleSpeed with nothing pulling, the body
	     comes to rest and stops being stepped.
	  2. In the air: gravity.
	  3. The motion for the step is swept as a sphere (Workspace:Spherecast),
	     so a fast grenade cannot pass through a wall thinner than one step's
	     travel. On a hit the body stops at the contact, bounces (Restitution
	     on the normal part, BounceFriction on the tangential part), and the
	     rest of the step continues from there -- up to MAX_CONTACTS times, so
	     a grenade wedged in a corner cannot loop forever inside one frame.

	A STICKY body (the impulse grenade) skips the bounce and the roll: the
	first surface it touches, floor or wall, is where it stops for good.

	Spherecast does not report a shape it starts inside, so the body is kept
	SKIN studs off every surface it touches. Without that margin a resting
	grenade would sink into the floor and fall out of the map on the next
	step.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local THROW = Config.Throw
local RADIUS = THROW.ProjectileRadius

-- The gap kept between the body and any surface it rests on or bounces off.
local SKIN = 0.02
-- How far below the body the ground probe looks.
local GROUND_PROBE = 0.08
-- A surface counts as ground when its normal is at least this upright
-- (about 45 degrees). Steeper is a wall, and the body bounces off it.
local GROUND_NORMAL_Y = 0.7
-- Collisions resolved within one step, at most.
local MAX_CONTACTS = 4
-- Below this, a motion is not worth casting.
local MIN_TRAVEL = 1e-4

local ZERO = Vector3.zero
local UP = Vector3.new(0, 1, 0)

export type Body = {
	position: Vector3,
	velocity: Vector3,
	-- True once the body has come to rest; it is not stepped again.
	resting: boolean,
	-- Stops dead on the first surface it touches instead of bouncing (the
	-- impulse grenade).
	sticky: boolean,
	-- The visual rotation, rolled along with the travel so a grenade reads as
	-- rolling rather than sliding. Presentation only.
	spin: CFrame,
}

local Ballistics = {}

function Ballistics.new(position: Vector3, velocity: Vector3, sticky: boolean?): Body
	return {
		position = position,
		velocity = velocity,
		resting = false,
		sticky = sticky == true,
		spin = CFrame.identity,
	}
end

-- A sticky body stops where it touched, and stays.
local function stick(body: Body)
	body.velocity = ZERO
	body.resting = true
end

-- Where the body rests on, or nil in the air.
local function groundBelow(body: Body, params: RaycastParams): RaycastResult?
	local hit = Workspace:Spherecast(body.position, RADIUS, Vector3.new(0, -GROUND_PROBE, 0), params)
	if hit == nil or hit.Normal.Y < GROUND_NORMAL_Y then
		return nil
	end
	-- Moving away from it (the start of a bounce) is not resting on it.
	if body.velocity:Dot(hit.Normal) > THROW.SettleSpeed then
		return nil
	end
	return hit
end

-- Turns the visual rotation by the distance travelled, as a ball of RADIUS
-- rolling along `motion` would.
local function roll(body: Body, motion: Vector3)
	local flat = Vector3.new(motion.X, 0, motion.Z)
	local distance = flat.Magnitude
	if distance < MIN_TRAVEL then
		return
	end
	local axis = UP:Cross(flat / distance)
	body.spin = CFrame.fromAxisAngle(axis, distance / RADIUS) * body.spin
end

--[[
	Advances `body` by `dt` seconds. `params` decides what the grenade can hit
	(GrenadeService excludes characters and its own parts).
]]
function Ballistics.step(body: Body, dt: number, params: RaycastParams)
	if body.resting then
		return
	end

	local gravity = Vector3.new(0, -Workspace.Gravity, 0)
	local remaining = dt

	for _ = 1, MAX_CONTACTS do
		if remaining <= 0 then
			return
		end

		local ground = groundBelow(body, params)
		if ground ~= nil and body.sticky then
			stick(body)
			return
		end
		if ground ~= nil then
			local normal = ground.Normal
			-- Nothing goes into the floor, and what gravity pulls along a
			-- slope still rolls the body down it.
			local velocity = body.velocity - normal * math.min(body.velocity:Dot(normal), 0)
			local slopePull = gravity - normal * gravity:Dot(normal)
			velocity += slopePull * remaining

			local speed = velocity.Magnitude
			local slowed = math.max(speed - THROW.RollDeceleration * remaining, 0)
			if slowed < THROW.SettleSpeed * 0.1 and slopePull.Magnitude < THROW.RollDeceleration then
				body.velocity = ZERO
				body.resting = true
				return
			end
			body.velocity = if speed > 0 then velocity * (slowed / speed) else velocity
		else
			body.velocity += gravity * remaining
		end

		local motion = body.velocity * remaining
		local travel = motion.Magnitude
		if travel < MIN_TRAVEL then
			return
		end

		local hit = Workspace:Spherecast(body.position, RADIUS, motion, params)
		if hit == nil then
			body.position += motion
			roll(body, motion)
			return
		end

		-- Up to the contact, less the skin, and account for the time spent.
		local direction = motion / travel
		local reached = math.max(hit.Distance - SKIN, 0)
		body.position += direction * reached
		roll(body, direction * reached)
		remaining -= remaining * (hit.Distance / travel)

		if body.sticky then
			stick(body)
			return
		end

		-- Bounce: the part into the surface reverses and loses energy, the
		-- part along it keeps only BounceFriction of its speed.
		local normal = hit.Normal
		local into = body.velocity:Dot(normal)
		if into < 0 then
			local tangent = body.velocity - normal * into
			local outSpeed = -into * THROW.Restitution
			if outSpeed < THROW.SettleSpeed then
				outSpeed = 0
			end
			body.velocity = normal * outSpeed + tangent * THROW.BounceFriction
		end
		body.position += normal * SKIN
	end
end

return Ballistics
