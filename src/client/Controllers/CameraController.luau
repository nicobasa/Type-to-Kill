--!strict
--[[
	Owns first-person presentation: an EMPTY-HANDED view, built from the
	player's OWN real character limbs -- not a separate viewmodel rig. Other
	players still see the normal avatar -- LocalTransparencyModifier is
	client-local, so nothing here ever replicates or needs to.

	Three things, all per character spawn:

	  1. Force Player.CameraMode to LockFirstPerson (unchanged from before).
	  2. Raise Humanoid.CameraOffset above the head, so the camera sits clear
	     of it instead of inside the skull.
	  3. Leave the engine's first-person fade alone -- with ONE exception. The
	     throwing arm and whatever is welded into it are forced back to visible
	     while ToolbarController says an item is in hand (setHoldingItem), and
	     hidden again the moment it is not.

	(3) USED TO SHOW BOTH ARMS ALL THE TIME, and that was wrong twice. A pair of
	arms floating in front of a player holding nothing is a weapon that is not
	there; and the character carries a headband whose code plate hangs in front
	of the face, so forcing character parts visible put the player's OWN number
	in the middle of their own screen all round. The default is now: show
	nothing. The arm is an event, not a state.

	A previous approach (ViewmodelController: a separate camera-attached arms
	rig) has been removed per design direction -- real limbs read better than
	a cloned viewmodel, and there is nothing left for that module to draw over.

	(1) and (3) are suspended while someone holds an override() -- the main-menu
	camera and the killcam both need the camera pointed somewhere that is not
	the player's own eyes, and a lock this controller re-applies on every
	CharacterAdded would otherwise yank it back mid-shot.

	(2) is deliberately NOT suspended. CameraOffset is read by the default
	camera module, which is not driving anything while an override holds a
	Scriptable camera, so leaving it applied is inert rather than wrong -- and
	it means a respawn mid-override (the killcam's normal case) still gets its
	offset without restore() having to re-walk the Humanoid to put it back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Log = require(ReplicatedStorage.Shared.Log)
local StaminaController = require(script.Parent.StaminaController)

local log = Log.new("CameraController")

local player = Players.LocalPlayer

-- How long to wait for Humanoid to exist before giving up on this spawn.
local HUMANOID_WAIT_TIMEOUT = 5

-- Raises the camera above the head. Designer-tuned; no forward component --
-- unlike the old full-body view, nothing here needs the camera to peek past
-- the head, since the head is never what's being looked around anyway. One
-- tunable constant rather than a scattered magic number.
local CAMERA_OFFSET = Vector3.new(0, 1, 0)

--[[
	The sprint zoom-out: degrees of field of view added while sprinting. A
	wider view is what makes the same speed read as fast. Kept small because
	the whole game is reading four digits off a distant plate, and a wide FOV
	shrinks every one of them.
]]
local SPRINT_FOV_BOOST = 8

-- How fast the field of view eases towards its target, per second. Around
-- a quarter second to settle: quick enough to feel tied to the key, slow
-- enough not to snap.
local FOV_EASE_RATE = 12

-- The real-limb parts that make up the arms-only view, across both rig types
-- this game supports. Matched by name rather than by class, since both an
-- R15 UpperArm/LowerArm/Hand and an R6 "Left Arm"/"Right Arm" are plain
-- BaseParts with nothing else distinguishing them from a torso or leg part.
--[[
	THE RIGHT ARM ONLY, AND ONLY WHILE SOMETHING IS IN IT.

	The view is empty-handed by default: no arms, no body, nothing but the world.
	That is a design decision, not an omission -- a pair of arms floating in
	front of a player who is holding nothing is a weapon that is not there.

	When the toolbar hands the character an item, ToolbarController calls
	setHoldingItem(true) and the throwing arm appears with the grenade in it. The
	LEFT arm never does: there is nothing in it to look at, and the asymmetry is
	what reads as "I am holding something" rather than "I have arms".

	Matched by name rather than by class because an R15 RightHand and an R6
	"Right Arm" are both plain BaseParts with nothing else to tell them apart
	from a leg.
]]
local HELD_ARM_PART_NAMES: { [string]: boolean } = {
	-- R15
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	-- R6
	["Right Arm"] = true,
}

--[[
	The item model LoadoutService welds into the hand. It is a descendant of the
	character, so LockFirstPerson fades it along with everything else -- which
	would leave the arm holding an invisible grenade.
]]
local HELD_ITEM_NAME = "HeldItem"

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

-- The arm parts of the CURRENT character only -- cleared by teardown() along
-- with everything else per-character. Kept as a list (processedParts already
-- covers dedup) purely so restore() can re-apply the forcing to whoever is
-- alive at that moment, which after a killcam is a different character than the
-- one that was alive when the override was taken.
local armParts: { BasePart } = {}

-- How many override() holders there are right now. Counted, not a boolean: the
-- menu camera and the killcam legitimately overlap when a round ends on the
-- same frame you die, and a boolean would let the first release restore first
-- person underneath the one still running.
local overrideCount = 0

--[[
	Whether the toolbar currently has something in the character's hand.

	Owned by ToolbarController through setHoldingItem, and deliberately a plain
	boolean rather than a count: there is exactly one hand and exactly one
	writer, so a refcount would only let a missed release leave the arm stuck on
	screen with nothing in it.
]]
local holdingItem = false

local CameraController = {}

local function forceFirstPerson()
	-- Deliberately silent while overridden. A character spawning mid-override
	-- is the killcam's NORMAL case (you respawn while still watching your
	-- killer), and restoring here would snap the camera into the new body's
	-- head. restore() re-applies it at the right moment instead.
	if overrideCount > 0 then
		return
	end
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

local function teardown()
	for _, connection in activeConnections do
		connection:Disconnect()
	end
	table.clear(activeConnections)
	table.clear(processedParts)
	table.clear(armParts)
end

--[[
	The single write point for arm transparency, so both guards live in exactly
	one place and every caller inherits them.

	The zero-check avoids writing (and re-entering the very signal handled in
	forcePartVisible below) on every change that already lands on 0.

	The override guard drops the write rather than disconnecting: an override
	that tore those signals down would have to rebuild them on restore, and the
	character may have been replaced in between. Dropping the write is the
	cheaper and the more correct half of that trade.
]]
--[[
	Show the part only while an item is actually in the hand.

	The engine drives LocalTransparencyModifier to 1 on the whole character in
	LockFirstPerson and keeps doing it, so "show" means forcing 0 back and
	holding it there; "hide" means letting go and leaving the engine's fade
	alone, which is why the false branch writes nothing.

	Silent while overridden for the same reason as forceFirstPerson: during a
	killcam the camera is looking at somebody else's body, and forcing our own
	arm opaque would put it across that shot. restore() re-applies afterwards.
]]
local function applyArmVisibility(part: BasePart)
	if overrideCount > 0 then
		return
	end
	if not holdingItem then
		return
	end
	if part.LocalTransparencyModifier ~= 0 then
		part.LocalTransparencyModifier = 0
	end
end

--[[
	Forces LocalTransparencyModifier back to 0 now, and keeps forcing it
	every time the engine (or anything else) changes it again -- LockFirstPerson
	re-applies its own fade continuously, not just once at spawn.

	Also records the part in armParts, so restore() can re-apply to it the
	writes an override suspended -- the engine will not re-fire the signal for
	a fade it applied before the override began.
]]
local function forcePartVisible(part: BasePart)
	table.insert(armParts, part)
	applyArmVisibility(part)

	local transparencyChanged = part:GetPropertyChangedSignal("LocalTransparencyModifier")
	local connection = transparencyChanged:Connect(function()
		applyArmVisibility(part)
	end)
	table.insert(activeConnections, connection)
end

local function processPart(part: BasePart)
	if processedParts[part] then
		return
	end
	processedParts[part] = true

	--[[
		The throwing arm, and whatever LoadoutService welded into it.

		Everything else -- head, torso, legs, the headband and its code plate,
		every accessory -- is left to the engine's first-person fade on purpose.
		The headband matters especially: it carries YOUR OWN code on a plate
		that floats in front of your face, so left visible it would sit in the
		middle of the screen for the whole round.
	]]
	local isHeldArm = HELD_ARM_PART_NAMES[part.Name]
	local isHeldItem = part.Name == HELD_ITEM_NAME or part:FindFirstAncestor(HELD_ITEM_NAME) ~= nil
	if not isHeldArm and not isHeldItem then
		return
	end

	forcePartVisible(part)
end

--[[
	Your own body, visible again once it is dead.

	LockFirstPerson fades the whole character to LocalTransparencyModifier 1
	and nothing ever faded it back, so a death left you watching the killcam
	next to an invisible corpse of your own. Forced to 0 and held there,
	because the engine's fade can still write it on the frames before the
	killcam's override lands.

	Ignores the override, unlike the arm. The arm is kept out of the killcam
	shot because it is a first-person prop; a dead body belongs in it.

	The code plate needs no exception here, as it does in processPart: the
	server takes the headband off the moment you die (CodeService.release).
]]
local function showWholeBody(character: Model)
	local function force(part: BasePart)
		if part.LocalTransparencyModifier ~= 0 then
			part.LocalTransparencyModifier = 0
		end
		local changed = part:GetPropertyChangedSignal("LocalTransparencyModifier")
		table.insert(
			activeConnections,
			changed:Connect(function()
				if part.LocalTransparencyModifier ~= 0 then
					part.LocalTransparencyModifier = 0
				end
			end)
		)
	end

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			force(descendant)
		end
	end
	table.insert(
		activeConnections,
		character.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				force(descendant)
			end
		end)
	)
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

		-- Connected into activeConnections, so the next spawn's teardown
		-- releases the corpse. Already dead covers a body that died while
		-- this thread was waiting for its Humanoid.
		if child.Health <= 0 then
			showWholeBody(character)
		else
			table.insert(
				activeConnections,
				child.Died:Connect(function()
					if currentCharacter == character then
						showWholeBody(character)
					end
				end)
			)
		end
	end)
end

local function onCharacterRemoving(character: Model)
	if currentCharacter ~= character then
		return
	end
	teardown()
	currentCharacter = nil
end

-- Classic is the only other CameraMode there is, and it is what actually frees
-- the mouse and the zoom. The arms need nothing done to them here: with the
-- write suppressed, the engine's own first-person fade stops being fought and
-- resolves itself on the next frame.
local function suspend()
	player.CameraMode = Enum.CameraMode.Classic
end

-- Re-applies to whatever character is current NOW, which is the whole reason
-- armParts is rebuilt per spawn rather than captured when the override began.
local function restore()
	forceFirstPerson()
	for _, part in armParts do
		applyArmVisibility(part)
	end
end

--[[
	Hands the camera to a caller -- the main-menu camera, the killcam -- without
	either of them having to know this controller re-applies its lock on every
	spawn, and without them having to know about each other.

		local release = CameraController.override("Killcam")
		-- ...later, on EVERY path, including the error one and the "killer left
		-- mid-cam" one...
		release()

	Reference counted: the lock lifts on the FIRST override and comes back only
	on the LAST release. Dying on the same frame a round ends puts the killcam
	and the menu camera both in flight, and a boolean would let whichever
	finished first slam first person back on underneath the other.

	The returned closure carries its own released flag rather than decrementing
	blindly, because the natural shape of a killcam is two exits racing (the
	respawn timer and the killer leaving) and both will call it. A bare decrement
	would take the count below the number of live holders, and the count would
	never reach 0 again for the holder that is still running -- first person
	would be restored under an active menu camera, and then never restored at
	all on the next round.
]]
function CameraController.override(reason: string): () -> ()
	overrideCount += 1
	if overrideCount == 1 then
		suspend()
	end
	log.debug(`camera overridden by {reason} ({overrideCount} holding)`)

	local released = false
	return function()
		if released then
			return
		end
		released = true

		overrideCount -= 1
		log.debug(`camera override released by {reason} ({overrideCount} holding)`)

		if overrideCount == 0 then
			restore()
		end
	end
end

function CameraController.isOverridden(): boolean
	return overrideCount > 0
end

--[[
	Show or hide the throwing arm. ToolbarController owns this: true while the
	selected slot holds an item, false the moment it does not.

	Hiding writes nothing. LockFirstPerson is already fading the whole character
	continuously, so letting go is enough -- and it is also the only correct
	thing to do, because writing a transparency of our own would fight the
	engine for the rest of the life of the part.

	Safe to call before a character exists and safe to call repeatedly with the
	same value: a spawn re-runs the forcing through processPart, and the flag is
	read there rather than captured.
]]
function CameraController.setHoldingItem(holding: boolean)
	if holdingItem == holding then
		return
	end
	holdingItem = holding

	if not holding then
		--[[
			Hand the arm straight back rather than waiting for the engine's next
			fade. LockFirstPerson re-applies on a schedule we do not control, and
			an arm that lingers for a few frames after the grenade left it is
			exactly the frames in which the player is looking for it to be gone.
		]]
		for _, part in armParts do
			if part.Parent ~= nil then
				part.LocalTransparencyModifier = 1
			end
		end
		return
	end

	for _, part in armParts do
		if part.Parent ~= nil then
			applyArmVisibility(part)
		end
	end
end

function CameraController.Init()
	--[[
		Shift lock is turned off in ParticipantService, on the SERVER, not here.

		Not a style choice -- `Player.DevEnableMouseLock` is simply not writable
		from a LocalScript ("lacking capability RobloxScript"), and because the
		Loader treats a throwing Init as fatal, attempting it here took the
		whole client down with it: no controllers, no UI, no game. If you are
		tempted to move it back for tidiness, that is what happens.
	]]

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
	--[[
		The field of view the place starts with, read rather than assumed, so
		a value set in Studio stays the resting value. The sprint zoom only
		ever adds to it.
	]]
	local baseFov = Workspace.CurrentCamera.FieldOfView

	RunService.RenderStepped:Connect(function(deltaTime: number)
		local camera = Workspace.CurrentCamera
		if camera == nil then
			return
		end

		--[[
			Eases back to the base under an override too, rather than freezing.
			Dying mid-sprint hands the camera to the killcam, and a frozen
			boost would show the killcam through the wide sprint lens, then
			carry that into the next spawn.
		]]
		local sprinting = overrideCount == 0 and StaminaController.isSprinting()
		local target = if sprinting then baseFov + SPRINT_FOV_BOOST else baseFov

		local current = camera.FieldOfView
		if math.abs(target - current) < 0.01 then
			if current ~= target then
				camera.FieldOfView = target
			end
			return
		end
		-- Frame-rate independent, so the ease takes as long at 30 FPS as at 240.
		local alpha = 1 - math.exp(-FOV_EASE_RATE * deltaTime)
		camera.FieldOfView = current + (target - current) * alpha
	end)

	log.info("ready")
end

return CameraController
