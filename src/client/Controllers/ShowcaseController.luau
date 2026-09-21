--!strict
--[[
	The local player's avatar, standing in the main menu's PlayerCard.

	Studio authored the ViewportFrame and its LoadingLabel; this controller only
	fills them. The three instances it creates -- a WorldModel, a Camera and the
	avatar clone -- are exactly the ones a ScreenGui cannot contain, and that is
	the whole of the exception to "never build UI in Luau" (ARCHITECTURE.md,
	"The map"). Nothing here touches the viewport's authored look: its Ambient,
	its LightDirection and its frame are a designer's to tune, not ours.

	WHY NOT player.Character

	ParticipantService turns Players.CharacterAutoLoads off, so a player sitting
	in the menu has no character AT ALL -- not one that is still loading, one
	that will not exist until they press Play. Cloning player.Character is
	therefore the exceptional path here rather than the obvious one, reached only
	if the fetch below fails during a round the player is already in.
	Players:CreateHumanoidModelFromUserId is the reliable source: it returns the
	published avatar whether or not the player is embodied.

	It is also a web call -- it yields, and it throws when Roblox's avatar
	endpoint is having a bad day. Both facts are why it lives in Start() inside a
	pcall: a menu that cannot draw a portrait is a poorer menu, not a broken one,
	so a failure leaves every button working and says so in LoadingLabel.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Log = require(ReplicatedStorage.Shared.Log)
local UIController = require(script.Parent.UIController)

local log = Log.new("ShowcaseController")

local player = Players.LocalPlayer

-- UIController addresses screens by name, but it finds them under this folder,
-- and so must anything that wants the instance itself.
local SCREENS_FOLDER = "Screens"
local SCREEN_NAME = "MainMenu"

-- Bounded waits. A screen nobody authored, or an element renamed in Studio, has
-- to surface as one warning naming what is missing -- never as a Start() that
-- returns some time never (HUDController takes the same shape for the same
-- reason).
local SCREEN_TIMEOUT = 10
local ELEMENT_TIMEOUT = 5

-- From the ScreenGui down, exactly as authored.
local VIEWPORT_PATH = { "Root", "PlayerCard", "AvatarViewport" }
local LOADING_LABEL_NAME = "LoadingLabel"
local FAILED_TEXT = "AVATAR UNAVAILABLE"

-- Where the clone is parked. Identity faces the model down -Z, so the camera
-- starts on +Z and the player opens the menu looking at their own face rather
-- than the back of their head.
local AVATAR_PIVOT = CFrame.identity

--[[
	A portrait lens, not the default 70. A wide camera close to the avatar
	distorts it, and that much perspective turns a nose into a beak. A narrow
	field of view backs the camera off to get the same crop, which is what
	flattens it out.
]]
local CAMERA_FIELD_OF_VIEW = 35

-- The slack left around the whole body, so the feet and the top of a hat do
-- not touch the card's edges and a narrow card does not clip a shoulder.
local FRAME_PADDING = 1.15

-- Seconds per full turn. Slow enough to read as an idle, not as a turntable.
local ROTATION_PERIOD = 18
local TAU = math.pi * 2

type Mount = {
	camera: Camera,
	worldModel: WorldModel,
	-- The point the camera orbits and its radius, both in the WorldModel's
	-- space. Computed once at mount: the avatar never changes size.
	focus: Vector3,
	distance: number,
	angle: number,
	spin: RBXScriptConnection?,
}

local ShowcaseController = {}

-- The fetched avatar, parented to nil and never shown. Every mount displays a
-- CLONE of it, so a PlayerGui reset costs a Clone() rather than a second round
-- trip to Roblox's avatar service.
local template: Model? = nil

local currentMount: Mount? = nil
local attaching = false
-- A screen died while we were still wiring its predecessor up; the in-flight
-- pass is walking a tree that no longer exists, so it has to run again.
local restartWanted = false
local warned: { [string]: boolean } = {}

--[[
	One warning per MESSAGE per session, not one per PlayerGui reset. A screen
	that was never authored is just as missing on the remount after every
	respawn, and forty identical warnings bury the first one -- which is the only
	one carrying any information. Keyed by text rather than by a single flag
	(PlayerCardController does the same) so the first warning cannot silence a
	second, different one about a different missing element.
]]
local function warnOnce(message: string)
	if warned[message] then
		return
	end
	warned[message] = true
	log.warn(message)
end

--[[
	Walks an authored path, waiting a bounded time at each step.

	Not a plain index: a ScreenGui replicates before its descendants do, so
	`screen.Root.PlayerCard` is a race that happens to pass on a fast machine.
	Not an unbounded WaitForChild either -- see SCREEN_TIMEOUT above.
]]
local function findPath(root: Instance, path: { string }): Instance?
	local current: Instance = root

	for _, name in path do
		local child = current:WaitForChild(name, ELEMENT_TIMEOUT)
		if child == nil then
			warnOnce(`{current:GetFullName()} has no "{name}" after {ELEMENT_TIMEOUT}s -- no avatar showcase`)
			return nil
		end
		current = child
	end

	return current
end

local function fetchAvatar(): Model?
	local fetched: Model? = nil

	local ok, err = pcall(function()
		fetched = Players:CreateHumanoidModelFromUserId(player.UserId)
	end)

	if fetched ~= nil then
		return fetched
	end

	local reason = if ok then "returned nothing" else `threw ({err})`
	log.warn(`CreateHumanoidModelFromUserId {reason} -- falling back to the live character`)

	--[[
		Usually there is nothing to fall back TO, which is the header's point:
		with CharacterAutoLoads off, a character exists only if this failed
		during a round the player is already in.

		Archivable is forced on first because Clone() on an instance with it off
		returns nil rather than erroring, and a nil here would read as "no
		character" -- the wrong diagnosis for whoever reads the log next.
	]]
	local character = player.Character
	if character == nil then
		return nil
	end
	character.Archivable = true

	return character:Clone()
end

--[[
	Put an accessory's Handle where its joint says it belongs.

	NOTHING SOLVES JOINTS IN A ViewportFrame. No physics runs in there, and a
	WorldModel does not change that -- it affects how parts are drawn, not
	whether anything simulates. The BODY survives that because
	CreateHumanoidModelFromUserId hands back parts already posed at their final
	CFrames, so anchoring them freezes a correct pose. An accessory does not:
	its Handle carries an AccessoryWeld and sits whereever it was authored until
	something applies that weld. Left alone it renders metres from the head --
	which is the "body parts everywhere" this used to draw, and it also wrecked
	the framing, because the camera distance is solved from a bounding box that
	a Handle 28 studs away had swollen to five times the size of a person.

	Three ways an accessory can be attached, tried in the order they actually
	occur:

	  Weld            the classic AccessoryWeld. Its constraint is
	                  Part0.CFrame * C0 == Part1.CFrame * C1, so the Handle's
	                  CFrame falls straight out of it.
	  RigidConstraint the newer form: two Attachments made coincident.
	  neither         the accessory was never welded because no Humanoid ever
	                  processed it. Fall back to what AddAccessory itself does
	                  -- match the Handle's attachment to the like-named one on
	                  the body.
]]
local function seatAccessory(model: Model, accessory: Accessory)
	local handle = accessory:FindFirstChild("Handle")
	if handle == nil or not handle:IsA("BasePart") then
		return
	end

	for _, child in handle:GetChildren() do
		if child:IsA("Weld") and child.Part0 ~= nil and child.Part1 ~= nil then
			if child.Part1 == handle then
				handle.CFrame = child.Part0.CFrame * child.C0 * child.C1:Inverse()
			else
				handle.CFrame = child.Part1.CFrame * child.C1 * child.C0:Inverse()
			end
			return
		end
	end

	for _, child in handle:GetChildren() do
		if child:IsA("RigidConstraint") then
			local a0, a1 = child.Attachment0, child.Attachment1
			if a0 ~= nil and a1 ~= nil then
				-- Whichever of the two lives on the Handle is the one that has
				-- to move to meet the other.
				if a1:IsDescendantOf(handle) then
					handle.CFrame = a0.WorldCFrame * a1.CFrame:Inverse()
				elseif a0:IsDescendantOf(handle) then
					handle.CFrame = a1.WorldCFrame * a0.CFrame:Inverse()
				end
				return
			end
		end
	end

	-- Unwelded: reproduce AddAccessory's own rule.
	local handleAttachment: Attachment? = nil
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") then
			handleAttachment = child
			break
		end
	end
	if handleAttachment == nil then
		return
	end

	for _, part in model:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		local target = part:FindFirstChild(handleAttachment.Name)
		if target ~= nil and target:IsA("Attachment") then
			handle.CFrame = target.WorldCFrame * handleAttachment.CFrame:Inverse()
			return
		end
	end
end

local function prepare(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BaseScript") then
			--[[
				A ViewportFrame lives in PlayerGui, so a LocalScript inside one
				is a LocalScript that RUNS. The Animate script every character
				ships with would wake up, claim the Humanoid and start loading
				animations for a rig sitting in a menu card. The clone has to be
				furniture, not an actor.
			]]
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			-- Anchored so the pose stays put: nothing simulates in a
			-- ViewportFrame, so an unanchored assembly is only ever one
			-- reparent away from falling out of frame.
			descendant.Anchored = true
		end
	end

	--[[
		AFTER the body parts are anchored, and after the scripts are gone.

		Order matters in one direction only: seatAccessory reads the CFrames of
		the body parts it attaches to, so the body has to be settled first. It
		is settled already -- the parts arrive posed -- but doing this in a
		second pass is what makes that dependency visible instead of incidental.
	]]
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Accessory") then
			seatAccessory(model, descendant)
		end
	end
end

--[[
	Where the camera has to sit to frame the whole body, feet to crown. It
	used to stop at the knee, and the card showed half a player.

	FieldOfView is the VERTICAL angle whatever the viewport's aspect ratio, so
	solving for the height of the band crops identically in a tall card and a
	squat one. FRAME_PADDING is what keeps the horizontal edges off the shoulders
	in the narrow case.
]]
local function framing(avatar: Model): (Vector3, number)
	local box, size = avatar:GetBoundingBox()
	local centre = box.Position

	local feet = centre.Y - size.Y / 2
	local crown = centre.Y + size.Y / 2

	local focus = Vector3.new(centre.X, (feet + crown) / 2, centre.Z)

	-- math.max, because a rig whose parts never arrived has a zero-height box,
	-- and a zero distance parks the camera exactly on the focus point -- a black
	-- card with no error to explain it.
	local framed = math.max((crown - feet) * FRAME_PADDING, 1)
	local distance = (framed / 2) / math.tan(math.rad(CAMERA_FIELD_OF_VIEW) / 2)

	return focus, distance
end

local function orbit(mount: Mount, angle: number)
	local offset = CFrame.Angles(0, angle, 0) * Vector3.new(0, 0, mount.distance)
	mount.camera.CFrame = CFrame.lookAt(mount.focus + offset, mount.focus)
end

--[[
	The idle turn orbits the CAMERA rather than pivoting the avatar: one CFrame
	write per frame instead of one per part on a fifteen-part R15 rig, for a
	picture nobody can tell apart. Cheapness matters because this runs every
	frame the menu is up, which on a lobby server is most of them.
]]
local function startSpin()
	local mount = currentMount
	if mount == nil or mount.spin ~= nil then
		return
	end

	mount.spin = RunService.RenderStepped:Connect(function(delta: number)
		-- Wrapped rather than accumulated: an angle left to grow across an hour
		-- of menu time loses enough float precision to visibly judder.
		mount.angle = (mount.angle + delta * TAU / ROTATION_PERIOD) % TAU
		orbit(mount, mount.angle)
	end)
end

local function stopSpin()
	local mount = currentMount
	if mount == nil then
		return
	end

	local spin = mount.spin
	if spin ~= nil then
		spin:Disconnect()
		mount.spin = nil
	end
	-- mount.angle is deliberately kept: reopening the menu resumes the turn where
	-- it stopped instead of snapping the avatar back to face-on.
end

local function unmount()
	local mount = currentMount
	if mount == nil then
		return
	end

	stopSpin()
	currentMount = nil

	-- Destroying the WorldModel takes the avatar clone with it. The camera is a
	-- sibling under the ViewportFrame, so it needs its own.
	mount.worldModel:Destroy()
	mount.camera:Destroy()
end

local function mountInto(viewport: ViewportFrame, avatar: Model)
	-- Never two at once: a second WorldModel in the same viewport draws on top
	-- of the first and leaks an entire rig per call.
	unmount()

	prepare(avatar)

	--[[
		A WorldModel, not the ViewportFrame directly -- for lighting and for
		Humanoid-aware rendering, NOT for assembly.

		It does not assemble anything, and an earlier comment here claimed it
		did. Nothing simulates inside a ViewportFrame: Motor6D joints are never
		solved and accessory welds are never applied. The avatar looks like a
		character because CreateHumanoidModelFromUserId returns its parts
		already posed, and because prepare() seats the accessories by hand.
	]]
	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "AvatarWorld"
	avatar.Parent = worldModel

	-- PivotTo with no PrimaryPart falls back to the bounding box centre, which
	-- has no opinion about which way the avatar faces. Naming the root first is
	-- what makes AVATAR_PIVOT mean "facing the camera".
	if avatar.PrimaryPart == nil then
		local root = avatar:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			avatar.PrimaryPart = root
		end
	end
	avatar:PivotTo(AVATAR_PIVOT)

	local focus, distance = framing(avatar)

	local camera = Instance.new("Camera")
	camera.Name = "AvatarCamera"
	camera.FieldOfView = CAMERA_FIELD_OF_VIEW
	camera.Parent = viewport

	local mount: Mount = {
		camera = camera,
		worldModel = worldModel,
		focus = focus,
		distance = distance,
		angle = 0,
		spin = nil,
	}
	currentMount = mount

	-- Pose the camera BEFORE the viewport has a world to draw, or the first
	-- frame renders from the camera's default CFrame at the origin -- which is
	-- inside the avatar's chest.
	orbit(mount, mount.angle)
	viewport.CurrentCamera = camera
	worldModel.Parent = viewport
end

--[[
	The screen instance, wherever under Screens/ it was authored.

	Subfolders there are organisation only -- UIController resolves a screen by
	name at any depth, so a controller that reached for playerGui.Screens.MainMenu
	and nothing else would break the moment someone tidied the tree. The recursive
	FindFirstChild catches a nested one as soon as it has replicated; the
	WaitForChild is the patient path for the flat layout, because a recursive find
	has no waiting form.
]]
local function findScreen(screens: Instance): Instance?
	local nested = screens:FindFirstChild(SCREEN_NAME, true)
	if nested ~= nil then
		return nested
	end
	return screens:WaitForChild(SCREEN_NAME, SCREEN_TIMEOUT)
end

local attach: () -> ()

local function attachOnce()
	local playerGui = player:WaitForChild("PlayerGui")

	local screens = playerGui:WaitForChild(SCREENS_FOLDER, SCREEN_TIMEOUT)
	if screens == nil then
		warnOnce(`no PlayerGui.{SCREENS_FOLDER} after {SCREEN_TIMEOUT}s -- no avatar showcase`)
		return
	end

	local screen = findScreen(screens)
	if screen == nil then
		warnOnce(`no {SCREENS_FOLDER}.{SCREEN_NAME} after {SCREEN_TIMEOUT}s -- no avatar showcase`)
		return
	end

	--[[
		StarterGui.ResetPlayerGuiOnSpawn wipes and re-clones the whole of
		PlayerGui on every respawn (UIController.Init says the same thing from
		the other end), destroying the screen found above along with our
		WorldModel and camera. Without this the showcase would work exactly once
		per session and be an empty card from the player's first death onwards.

		Connected HERE, before the element walk below, rather than after it. The
		walk yields, so a reset landing in the middle of it leaves that pass
		reading a tree that is already gone -- and if the retry were armed only
		at the end, that one unlucky pass would take the showcase out for the
		rest of the session.

		No Disconnect needed: Destroying fires once and the connection dies with
		the instance that owns it.
	]]
	screen.Destroying:Connect(function()
		unmount()
		-- Spawned: attach yields on WaitForChild, and yielding inside a
		-- Destroying handler stalls whatever is doing the destroying.
		task.spawn(attach)
	end)

	local found = findPath(screen, VIEWPORT_PATH)
	if found == nil then
		return -- findPath already named the step that was missing
	end
	if not found:IsA("ViewportFrame") then
		warnOnce(`{found:GetFullName()} is a {found.ClassName}, not a ViewportFrame -- no avatar showcase`)
		return
	end
	local viewport = found

	local source = template
	if source ~= nil then
		mountInto(viewport, source:Clone())
	end

	--[[
		WaitForChild, not FindFirstChild, and looked up AFTER the mount.

		A ViewportFrame replicates before its own children do, so reading the
		label the instant the viewport arrives can miss it -- and a missed label
		is not a silent failure, it is the word LOADING left sitting on top of a
		finished portrait. Bounded and still optional, because a designer who
		deleted the label has not broken anything. After the mount so that the
		pathological five seconds delay hiding a label rather than drawing the
		avatar.
	]]
	local label = viewport:WaitForChild(LOADING_LABEL_NAME, ELEMENT_TIMEOUT)
	local loading = if label ~= nil and label:IsA("TextLabel") then label else nil
	if loading ~= nil then
		if source == nil then
			-- The menu still works; only the portrait is missing, and the label
			-- the designer already put there is the right place to say so.
			loading.Text = FAILED_TEXT
		else
			loading.Visible = false
		end
	end

	-- MainMenu starts Enabled as authored, so on a cold boot it is already open
	-- here and the open hook registered in Init will never fire for it.
	if source ~= nil and UIController.isOpen(SCREEN_NAME) then
		startSpin()
	end
end

function attach()
	if attaching then
		--[[
			Recorded, not dropped. A respawn that lands while a pass is still
			yielding on WaitForChild leaves that pass walking a destroyed tree;
			returning here would mean the only request to rebuild the showcase
			was the one we just threw away, and the card would stay empty until
			the player died again.
		]]
		restartWanted = true
		return
	end
	attaching = true

	repeat
		restartWanted = false
		-- pcall, then loop. Luau has no finally, and a throw in here (PlayerGui
		-- destroyed mid-WaitForChild on a rejoin) would otherwise wedge the flag
		-- true and the showcase would never come back.
		local ok: boolean, err: string? = pcall(attachOnce)
		if not ok then
			log.warn(`attach failed: {err}`)
		end
	-- Not a spin risk: restartWanted is only ever set from a Destroying
	-- handler, which the engine raises while this thread is parked in a
	-- WaitForChild -- so an extra lap costs one real PlayerGui reset each.
	until not restartWanted

	attaching = false
end

function ShowcaseController.Init()
	--[[
		No packets and no replica, but these still belong in Init rather than
		Start: they are pure subscriptions, and registering them before any
		controller's Start can call UIController.open means the spin cannot miss
		the transition that put the menu back on screen.

		Both handlers are no-ops until Start() has something mounted.
	]]
	UIController.onOpen(SCREEN_NAME, startSpin)
	UIController.onClose(SCREEN_NAME, stopSpin)
end

function ShowcaseController.Start()
	--[[
		Fetch first, then mount. That way mounting is synchronous: attach() has
		either an avatar to clone or a failure to write into LoadingLabel, and
		never a half-built card waiting on a web call it might have to abandon
		when PlayerGui resets underneath it.
	]]
	template = fetchAvatar()

	attach()
end

return ShowcaseController
