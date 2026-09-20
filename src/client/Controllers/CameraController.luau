--!strict
--[[
	Owns first-person presentation: classic FPS arms-only view, built from the
	player's OWN real character limbs -- not a separate viewmodel rig. Other
	players still see the normal avatar -- LocalTransparencyModifier is
	client-local, so nothing here ever replicates or needs to.

	Three things, all per character spawn:

	  1. Force Player.CameraMode to LockFirstPerson (unchanged from before).
	  2. Raise Humanoid.CameraOffset above the head, so the camera sits clear
	     of it instead of inside the skull.
	  3. Counteract the engine's own first-person fade, but ONLY on the arm
	     parts (matched by name, covering both R15 and R6) -- LockFirstPerson
	     drives LocalTransparencyModifier to 1 on the whole character, and
	     this forces it back to 0 on the arms alone. Everything else (head,
	     torso, legs, every accessory) keeps the engine's default first-person
	     hiding untouched, which is exactly what an arms-only view wants.

	A previous approach (ViewmodelController: a separate camera-attached arms
	rig) has been removed per design direction -- real limbs read better than
	a cloned viewmodel, and there is nothing left for that module to draw over.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("CameraController")

local player = Players.LocalPlayer

-- How long to wait for Humanoid to exist before giving up on this spawn.
local HUMANOID_WAIT_TIMEOUT = 5

-- Raises the camera above the head. Designer-tuned; no forward component --
-- unlike the old full-body view, nothing here needs the camera to peek past
-- the head, since the head is never what's being looked around anyway. One
-- tunable constant rather than a scattered magic number.
local CAMERA_OFFSET = Vector3.new(0, 1, 0)

-- The real-limb parts that make up the arms-only view, across both rig types
-- this game supports. Matched by name rather than by class, since both an
-- R15 UpperArm/LowerArm/Hand and an R6 "Left Arm"/"Right Arm" are plain
-- BaseParts with nothing else distinguishing them from a torso or leg part.
local ARM_PART_NAMES: { [string]: boolean } = {
	-- R15
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	-- R6
	["Left Arm"] = true,
	["Right Arm"] = true,
}

-- The character currently wired up, so a CharacterAdded that fires between
-- Init's own connect and its "already have one" check is never processed
-- twice (see Init below).
local currentCharacter: Model? = nil

-- Every connection made for currentCharacter, torn down as a batch on
-- CharacterRemoving/respawn. Chosen over relying on Instance:Destroy() to
-- disconnect things implicitly -- that only fires for an instance destroyed
-- outright, and the character model itself is sometimes only reparented
-- (ResetOnSpawn-style flows) rather than destroyed, which would leak these.
local activeConnections: { RBXScriptConnection } = {}

-- Every BasePart already wired for the current character, so a part visited
-- both directly (character:GetDescendants() at spawn) and via DescendantAdded
-- (a late-added part whose parent is itself a fresh descendant) is only ever
-- connected once.
local processedParts: { [BasePart]: boolean } = {}

local CameraController = {}

local function forceFirstPerson()
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

local function teardown()
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
	table.clear(processedParts)
end

--[[
	Forces LocalTransparencyModifier back to 0 now, and keeps forcing it
	every time the engine (or anything else) changes it again -- LockFirstPerson
	re-applies its own fade continuously, not just once at spawn. The guard
	avoids writing (and re-entering the very signal being handled) on every
	change that already lands on 0.
]]
local function forcePartVisible(part: BasePart)
	if part.LocalTransparencyModifier ~= 0 then
		part.LocalTransparencyModifier = 0
	end

	local transparencyChanged = part:GetPropertyChangedSignal("LocalTransparencyModifier")
	local connection = transparencyChanged:Connect(function()
		if part.LocalTransparencyModifier ~= 0 then
			part.LocalTransparencyModifier = 0
		end
	end)
	table.insert(activeConnections, connection)
end

local function processPart(part: BasePart)
	if processedParts[part] then
		return
	end
	processedParts[part] = true

	if not ARM_PART_NAMES[part.Name] then
		-- Head, torso, legs, and every accessory: left untouched on purpose --
		-- the engine keeps them hidden in first person, which is the whole
		-- point of an arms-only view.
		return
	end

	forcePartVisible(part)
end

local function onCharacterAdded(character: Model)
	if currentCharacter == character then
		return
	end
	teardown()
	currentCharacter = character

	forceFirstPerson()

	-- Covers both a plain part added directly under the character AND a
	-- whole accessory Model added at once (whose Handle never fires its own
	-- DescendantAdded, since it was already parented under the accessory
	-- before the accessory itself was added) -- one entry point for both,
	-- rather than a separate ChildAdded connection alongside this one.
	local function considerInstance(instance: Instance)
		if instance:IsA("BasePart") then
			processPart(instance)
		end
		for _, descendant in instance:GetDescendants() do
			if descendant:IsA("BasePart") then
				processPart(descendant)
			end
		end
	end

	considerInstance(character)

	-- Character descendants replicate asynchronously, so arm parts that show
	-- up after this line (limbs frequently do) still need to be caught.
	local descendantConnection = character.DescendantAdded:Connect(considerInstance)
	table.insert(activeConnections, descendantConnection)

	--[[
		Humanoid may not exist yet when CharacterAdded fires. Init() must not
		yield (the Loader enforces this -- see Loader.luau), and Init() calls
		this function directly for a character that already existed at load
		time, so the wait is pushed onto its own thread rather than done inline.

		Bounded rather than an unbounded WaitForChild, so a genuinely broken
		character (no Humanoid ever) surfaces a warning instead of leaking a
		thread that waits forever.
	]]
	task.spawn(function()
		local child = character:WaitForChild("Humanoid", HUMANOID_WAIT_TIMEOUT)

		-- A respawn can happen while this was waiting -- re-check rather than
		-- stomping CameraOffset on a character that's already gone.
		if currentCharacter ~= character then
			return
		end

		if child == nil then
			log.warn(`{character.Name} has no Humanoid after {HUMANOID_WAIT_TIMEOUT}s -- cannot set CameraOffset`)
			return
		end
		if not child:IsA("Humanoid") then
			log.warn(`{character.Name}.Humanoid is a {child.ClassName}, not a Humanoid -- cannot set CameraOffset`)
			return
		end

		child.CameraOffset = CAMERA_OFFSET
	end)
end

local function onCharacterRemoving(character: Model)
	if currentCharacter ~= character then
		return
	end
	teardown()
	currentCharacter = nil
end

function CameraController.Init()
	-- Set now, in case a Character (and whatever camera scripts it wakes) is
	-- already around by the time this loads.
	forceFirstPerson()

	-- Connect before checking for an already-existing character -- if one
	-- spawns in the gap, onCharacterAdded's currentCharacter guard (above)
	-- deduplicates rather than wiring it twice.
	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(onCharacterRemoving)

	local existingCharacter = player.Character
	if existingCharacter ~= nil then
		onCharacterAdded(existingCharacter)
	end
end

function CameraController.Start()
	log.info("ready")
end

return CameraController
