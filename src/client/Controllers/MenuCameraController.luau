--!strict
--[[
	The camera behind the main menu, and the blur in front of it.

	Active only while the MainMenu screen is up, and that is the whole of its
	contract with the rest of the client: it holds no opinion about the match,
	it never decides when the menu is on screen, and it touches no GUI at all.
	MenuController opens and closes MainMenu; this follows.

	WHY IT TAKES AN OVERRIDE RATHER THAN JUST WRITING CameraType

	CameraController forces Player.CameraMode to LockFirstPerson and keeps
	re-forcing the arm parts visible, continuously, for as long as a character
	exists -- it is not a one-shot at spawn. A menu camera that only set
	CameraType = Scriptable would be fighting that every frame, and a player
	who spawned while the menu was up would be looking out of the inside of
	their own head. CameraController.override("MainMenu") lifts both for as
	long as we hold the release function it hands back, and reference-counts,
	so the killcam can hold one at the same time without either winning.

	WHY THE FALLBACK ORBIT IS NOT OPTIONAL

	The rail is authored per map: BaseParts tagged MenuCameraPoint inside the
	live map (Shared.Tags carries the authoring contract). In Lobby there IS no
	map -- Round.MapId is "" and Workspace.ActiveMap does not exist -- and
	Lobby is the state a joining player lands in. With no rail and no fallback
	the camera would sit wherever the engine last left it, which on a fresh
	join is a black screen: literally the first thing a new player sees.

	EVERY MOVE IS A BLEND FROM WHERE THE CAMERA ACTUALLY IS

	Next stop, new map, map unloaded, menu reopened -- every change of
	destination re-anchors the blend at the camera's current CFrame and eases
	from there over BLEND_DURATION. One mechanism covers all of them, so there
	is no separate "jump to the first point" path to get wrong, and a map that
	streams in one part at a time reads as a gentle re-aim rather than as a
	series of cuts.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CameraController = require(script.Parent.CameraController)
local Log = require(ReplicatedStorage.Shared.Log)
local MatchController = require(script.Parent.MatchController)
local Motion = require(script.Parent.Parent.UI.Motion)
local Tags = require(ReplicatedStorage.Shared.Tags)
local UIController = require(script.Parent.UIController)

local log = Log.new("MenuCameraController")

local player = Players.LocalPlayer

local SCREENS_FOLDER = "Screens"
local MENU_SCREEN = "MainMenu"

--[[
	Every screen the player looks at from OUTSIDE the world.

	TeamSelect belongs here and leaving it out was a real bug, not a missing
	nicety. These screens are all driven with the mouse, and the mouse is only
	free while CameraController is overridden -- so when MainMenu closed to let
	TeamSelect open, the override came back, first person locked the cursor to
	the centre of the screen, and the team buttons became unclickable. The
	player was left in a menu they could not answer.

	Keeping the map camera running behind TeamSelect is also the presentation
	the design asks for: in Team Deathmatch there is no character yet at this
	point, so the alternative is a locked first-person view of nothing.

	The menu's overlays (Inventory, Shop, Settings) are here for the same
	reason, and leaving them out was the same bug a second time. They are
	exclusive, so opening one closes MainMenu, and the cursor locked to the
	centre of a shop the player was trying to click. They only ever open from
	MainMenu (MenuController), so this never takes the camera mid-round.
]]
local MENU_SCREENS = { "MainMenu", "TeamSelect", "Inventory", "Shop", "Settings" }

-- How long to wait for the authored screen before deciding there isn't one.
-- Bounded, like HUDController's, so a place with no MainMenu surfaces as one
-- warning instead of a thread parked for the session.
local SCREEN_TIMEOUT = 10

-- Shown in CameraController's override bookkeeping, so it has to say who is
-- holding the camera when two things hold it in the same session.
local OVERRIDE_REASON = "MainMenu"

-- MapService parents the live map's clone under this name and sweeps
-- Workspace for the name at unload, which makes it the identity of the loaded
-- map rather than a label on it. Spelled again here because that service is
-- server-only and nothing shared carries the constant.
local ACTIVE_MAP_NAME = "ActiveMap"

-- Seconds to ease from one destination to the next. Long on purpose: the menu
-- camera is scenery, and anything fast enough to register as movement competes
-- with the menu for the player's attention.
local BLEND_DURATION = 6

-- Seconds parked at a stop before moving on to the next one.
local HOLD_DURATION = 3.5

-- Sine In-Out rather than the Motion presets: those are tuned for UI, where a
-- quarter of a second and a slight overshoot are the point. A camera that
-- overshoots looks like it was bumped.
local EASE_STYLE = Enum.EasingStyle.Sine
local EASE_DIRECTION = Enum.EasingDirection.InOut

-- The Lobby orbit. Wide and high enough to frame whatever is authored around
-- the origin, and slow enough that one revolution outlasts any intermission --
-- a player should never see it come back around to where it started.
local ORBIT_RADIUS = 60
local ORBIT_HEIGHT = 28
local ORBIT_FOCUS = Vector3.new(0, 8, 0)
local ORBIT_PERIOD = 90
local ORBIT_RADIANS_PER_SECOND = (math.pi * 2) / ORBIT_PERIOD
local FULL_TURN = math.pi * 2

local BLUR_SIZE = 18

local RENDER_BIND = "MenuCamera"

-- One slot AFTER the default camera script's own update, so our write is the
-- last one of the frame even during the moment before it notices CameraType
-- has gone Scriptable.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- Sort key for a point carrying no Order attribute. math.huge rather than a
-- big literal, so no authored Order can accidentally outrank "unordered".
local UNORDERED = math.huge

type Stop = {
	cframe: CFrame,
	order: number,
	name: string,
}

local MenuCameraController = {}

local active = false
local bound = false

-- nil whenever we do not hold the camera. Cleared BEFORE it is called (see
-- deactivate), so no path can call the same release twice.
local releaseOverride: (() -> ())? = nil

local blur: BlurEffect? = nil
local blurHandle: Motion.Handle? = nil

--[[
	CFrames, deliberately not the BaseParts they came from.

	The rail is rebuilt when the map changes, and the old map's parts are
	destroyed by then. Holding parts would mean both a table of dead instance
	references and a per-frame `part.Parent ~= nil` guard to avoid reading
	them; copying the pose at derive time removes both problems at once.
]]
local rail: { CFrame } = {}
local railDirty = true
local stopIndex = 1

local blendFrom = CFrame.new()
local blendElapsed = 0
local holdElapsed = 0
local orbitAngle = 0

--[[
	The point's sort key, or UNORDERED.

	The NaN test is not paranoia. A comparator built on `<` is inconsistent the
	moment one side is NaN -- every comparison against it is false -- and
	table.sort does not mis-sort in that case, it throws "invalid order
	function for sorting". One mis-typed attribute in one map would take the
	whole menu camera down rather than degrade it (quality-gate.md trap #8).
]]
local function readOrder(part: BasePart): number
	local value = part:GetAttribute(Tags.ATTRIBUTE_ORDER)
	if value == nil then
		return UNORDERED
	end
	if type(value) ~= "number" or value ~= value then
		log.warn(`{part:GetFullName()}.{Tags.ATTRIBUTE_ORDER} is not a usable number -- sorting it by name instead`)
		return UNORDERED
	end
	return value
end

-- Order first, then name -- which is exactly the authoring contract in
-- Shared.Tags: points with no Order fall in after the ordered ones, so naming
-- them CameraPoint1..CameraPoint4 works with no attributes at all.
local function compareStops(a: Stop, b: Stop): boolean
	if a.order ~= b.order then
		return a.order < b.order
	end
	return a.name < b.name
end

--[[
	The current map's camera rail, in order. Empty when no map is loaded.

	The IsDescendantOf filter is the whole function, for the same reason
	MapService gives on the server: GetTagged is GLOBAL. Anything tagged that a
	designer left parented in Workspace -- a rail saved into the place, a
	leftover from a Studio session -- would otherwise be stitched into the live
	map's rail and fly the camera off to coordinates from a different map.
]]
local function deriveRail(): { CFrame }
	local map = Workspace:FindFirstChild(ACTIVE_MAP_NAME)
	if map == nil then
		return {}
	end

	local stops: { Stop } = {}
	local misTagged = 0

	for _, instance in CollectionService:GetTagged(Tags.MENU_CAMERA_POINT) do
		if not instance:IsDescendantOf(map) then
			continue
		end
		if not instance:IsA("BasePart") then
			-- A tag on a Model or a Folder has no CFrame to fly to, and it
			-- otherwise vanishes without trace: the rail just comes up one
			-- stop short.
			misTagged += 1
			continue
		end
		table.insert(stops, {
			cframe = instance.CFrame,
			order = readOrder(instance),
			name = instance.Name,
		})
	end

	if misTagged > 0 then
		log.warn(`{misTagged} {Tags.MENU_CAMERA_POINT} tags in {map.Name} are not on BaseParts -- ignored`)
	end

	table.sort(stops, compareStops)

	local cframes: { CFrame } = table.create(#stops)
	for _, stop in stops do
		table.insert(cframes, stop.cframe)
	end
	return cframes
end

-- Aimed with lookAt rather than by rotating a CFrame: a stop carries its own
-- facing in the part's LookVector, but the orbit has no author to ask, so it
-- has to derive one -- and "point at the focus" is the only choice that keeps
-- something in frame all the way around.
local function orbitCFrame(angle: number): CFrame
	local position = Vector3.new(math.cos(angle) * ORBIT_RADIUS, ORBIT_HEIGHT, math.sin(angle) * ORBIT_RADIUS)
	return CFrame.lookAt(position, ORBIT_FOCUS)
end

local function rebuildRail(camera: Camera)
	rail = deriveRail()
	stopIndex = 1
	holdElapsed = 0
	blendFrom = camera.CFrame
	blendElapsed = 0
end

local function step(deltaTime: number)
	--[[
		Re-read from CurrentCamera every frame rather than caching it. The
		engine replaces the Camera instance on some respawn paths, and a cached
		reference would leave this driving a camera nobody is looking through
		while the live one runs the default script -- which looks exactly like
		the menu camera having crashed.
	]]
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	-- Guarded write, not an unconditional one: assigning a property every
	-- frame fires its changed signals every frame, and the default camera
	-- script listens to this one.
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	if railDirty then
		railDirty = false
		rebuildRail(camera)
	end

	local target: CFrame
	if #rail > 0 then
		-- The hold only starts once the move has actually finished. Counting
		-- it down during the blend would make a long ease and a short ease
		-- spend different amounts of time at rest.
		if blendElapsed >= BLEND_DURATION then
			holdElapsed += deltaTime
			if holdElapsed >= HOLD_DURATION then
				holdElapsed = 0
				stopIndex = stopIndex % #rail + 1
				blendFrom = camera.CFrame
				blendElapsed = 0
			end
		end
		target = rail[stopIndex]
	else
		-- Wrapped, so a client left in the menu for hours does not accumulate
		-- a float large enough to lose the precision the cosine needs.
		orbitAngle = (orbitAngle + deltaTime * ORBIT_RADIANS_PER_SECOND) % FULL_TURN
		target = orbitCFrame(orbitAngle)
	end

	blendElapsed = math.min(blendElapsed + deltaTime, BLEND_DURATION)

	--[[
		One expression for both modes. On the rail the target is fixed, so the
		camera settles exactly onto the stop and stays there through the hold.
		On the orbit the target moves every frame, so the blend is only the way
		IN -- once it reaches 1 the camera rides the orbit exactly, with the
		lerp costing nothing.
	]]
	local eased = TweenService:GetValue(blendElapsed / BLEND_DURATION, EASE_STYLE, EASE_DIRECTION)
	camera.CFrame = blendFrom:Lerp(target, eased)
end

--[[
	One BlurEffect for the controller's whole life, faded rather than popped.

	Reuse, not create-per-open: a menu closed and reopened inside the fade-out
	would otherwise leave two blurs in Lighting stacking on each other, and
	Lighting keeps whatever it is given forever.
]]
local function showBlur()
	if blurHandle ~= nil then
		blurHandle.cancel()
		blurHandle = nil
	end

	--[[
		Declared non-optional and assigned on both branches, rather than
		starting from `blur` and reassigning: refinement does not survive the
		reassignment, so the tween below would still see BlurEffect? and the
		checker would be right to reject it.
	]]
	local effect: BlurEffect
	local existing = blur
	if existing ~= nil then
		effect = existing
	else
		effect = Instance.new("BlurEffect")
		effect.Name = "MenuCameraBlur"
		effect.Size = 0
		effect.Parent = Lighting
		blur = effect
	end

	blurHandle = Motion.tween(effect, { Size = BLUR_SIZE }, "smooth")
end

local function hideBlur()
	if blurHandle ~= nil then
		blurHandle.cancel()
		blurHandle = nil
	end

	local effect = blur
	if effect == nil then
		return
	end

	-- Destroyed on completion rather than now: cutting a full-screen blur
	-- dead is more visible than the menu leaving. A reopen inside this fade
	-- cancels the handle, and Motion never runs onComplete for a cancelled
	-- tween, so this can never destroy the blur the menu is currently using.
	blurHandle = Motion.tween(effect, { Size = 0 }, "smooth", function()
		blur = nil
		blurHandle = nil
		effect:Destroy()
	end)
end

local function beginDriving()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		blendFrom = camera.CFrame
	end
	blendElapsed = 0
	holdElapsed = 0
	stopIndex = 1
	-- Always re-derived on open: the map can have changed, or gone, while the
	-- menu was closed and nothing was listening hard enough to care.
	railDirty = true

	showBlur()

	RunService:BindToRenderStep(RENDER_BIND, RENDER_PRIORITY, step)
	bound = true
end

--[[
	Idempotent, and safe to call from a half-finished activate() -- which is
	exactly what it is for.
]]
local function deactivate()
	if not active then
		return
	end
	active = false

	-- Unbind BEFORE restoring CameraType, or the step runs once more and puts
	-- it straight back to Scriptable.
	if bound then
		bound = false
		RunService:UnbindFromRenderStep(RENDER_BIND)
	end

	--[[
		The teardown between the unbind and the release is pcall'd, not because
		either half is expected to throw, but because both sit BETWEEN a taken
		override and the only code that gives it back. Luau has no finally
		(quality-gate.md Gate 2), so without this a throw here would strand the
		release -- and a stranded release is not a missing blur, it is first
		person never coming back for the rest of the session.
	]]
	local ok, err = pcall(function()
		hideBlur()

		local camera = Workspace.CurrentCamera
		if camera ~= nil and camera.CameraType == Enum.CameraType.Scriptable then
			-- Custom, not a CameraType remembered from activation. If the menu
			-- opened over something else that had already gone Scriptable,
			-- restoring that value would hand the player a frozen camera with
			-- nothing driving it. Custom is the only resting state this game has.
			camera.CameraType = Enum.CameraType.Custom
		end
	end)

	--[[
		Released last, and cleared before it is called. Clearing first means an
		error inside the release cannot leave a stale handle behind for a later
		deactivate to call a second time; releasing last means the first-person
		lock comes back only once the camera is already back under the default
		script, rather than for the frame in between.
	]]
	local release = releaseOverride
	releaseOverride = nil
	if release ~= nil then
		release()
	end

	-- Reported after the camera is back in the player's hands, never instead
	-- of handing it back.
	if not ok then
		log.error(`the menu camera did not tear down cleanly: {err}`)
	end
end

local function anyMenuScreenOpen(): boolean
	for _, name in MENU_SCREENS do
		if UIController.isOpen(name) then
			return true
		end
	end
	return false
end

local function activate()
	if active then
		return
	end
	active = true

	--[[
		Everything from taking the override to the render bind is inside one
		pcall, because Luau has no finally (quality-gate.md Gate 2) and this is
		what makes deactivate() reachable on the failure path. Without it the
		first-person lock would stay lifted for the rest of the session with no
		camera driving it -- a dead view the player cannot get out of, and a bug
		that would be blamed on CameraController.

		The assignment is inside the pcall and is the FIRST thing in it: a
		release taken and then dropped is the one leak this file cannot recover
		from, since nothing else holds the closure. And `active` is inside too,
		by way of deactivate() -- a throw from override() itself would otherwise
		leave the flag stuck true and refuse every later open.
	]]
	local ok, err = pcall(function()
		releaseOverride = CameraController.override(OVERRIDE_REASON)
		beginDriving()
	end)

	if not ok then
		deactivate()
		log.error(`could not start the menu camera, handing the camera back: {err}`)
	end
end

--[[
	Brings the camera into line with whether ANY menu screen is up.

	DEFERRED, and that is the whole point of it. UIController.open() hides the
	outgoing exclusive screen BEFORE it shows the incoming one, so on a
	MainMenu -> TeamSelect swap the close fires while TeamSelect is still shut.
	Acting on that immediately would tear the menu camera down and hand the
	camera back for the gap between the two -- one frame of first person and a
	cursor snapping to the centre, in the middle of a screen change. Deferring
	lets the matching open land first, and both listeners then agree on
	"still open" and activate(), which is idempotent.
]]
local function syncActivation()
	task.defer(function()
		if anyMenuScreenOpen() then
			activate()
		else
			deactivate()
		end
	end)
end

--[[
	Re-asks UIController whether the menu is up, every time PlayerGui hands over
	a new copy of the screen.

	onOpen alone does not cover the join, and a bare isOpen() at the end of
	Start() does not either -- both end with the player staring at a black
	screen, which is the one outcome this controller exists to prevent.

	UIController adopts a screen that was authored Enabled as ALREADY open and
	fires no onOpen for it (UIController.luau, register()), and MainMenu is
	authored Enabled because it is what the player spawns into. MenuController's
	route() does not rescue that either: its open("MainMenu") finds the screen
	already open and returns without firing anything. So the adoption is the
	normal join path and nothing announces it.

	Asking directly is the answer, but only once PlayerGui HAS the screen:
	StarterGui is copied into PlayerGui when the character spawns, which is many
	frames after every Start() body has run, so asking immediately reliably gets
	"not registered yet" dressed up as "closed".

	The loop is the second half of the same problem. ResetPlayerGuiOnSpawn is on
	by default and re-clones the whole of PlayerGui on every respawn, so the
	adoption happens again on every death and the camera has to be re-synced to
	it rather than bound once.
]]
local function syncLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		-- WaitForChild, not a direct index: PlayerGui is populated by
		-- replication from StarterGui, so the screens are reliably absent for
		-- the first frames even when they HAVE been authored.
		local screens = playerGui:WaitForChild(SCREENS_FOLDER, SCREEN_TIMEOUT)
		local gui = if screens ~= nil then screens:WaitForChild(MENU_SCREEN, SCREEN_TIMEOUT) else nil

		if gui == nil then
			log.warn(
				`no PlayerGui.{SCREENS_FOLDER}.{MENU_SCREEN} after {SCREEN_TIMEOUT}s -- the menu camera will only run if something opens that screen`
			)
			return
		end

		-- UIController registers the screen off the same ChildAdded that just
		-- resumed the WaitForChild above, and two handlers of one signal resume
		-- in no defined order. A frame later the registration has definitely
		-- landed, so isOpen() means "closed" rather than "not known yet".
		task.wait()

		-- Any of them, not just MainMenu: a PlayerGui re-clone that lands while
		-- the player is sitting on TeamSelect must not conclude the menu is
		-- closed and hand the camera back under them.
		if anyMenuScreenOpen() then
			activate()
		else
			deactivate()
		end

		-- Parks until PlayerGui is wiped and re-cloned. Destroying:Wait() rather
		-- than a connection: there is no handle to forget to disconnect, and
		-- this thread has nothing else to do in the meantime.
		gui.Destroying:Wait()

		-- Destroying fires BEFORE the instance leaves the tree. Rescanning on
		-- that same resumption can hand back the very copy on its way out, and
		-- waiting a second time on an already-destroyed instance's Destroying
		-- parks this thread for the rest of the session -- the menu camera
		-- would work until the player's first death and then never again.
		task.wait()
	end
end

local function markRailDirty()
	-- Only a flag: the rebuild itself happens in step(), where the camera to
	-- re-anchor the blend against is already in hand. It also collapses the
	-- burst of signals a streaming map produces into a single rebuild.
	railDirty = true
end

function MenuCameraController.Start()
	--[[
		Two independent triggers, because the rail has two independent halves.

		MapId is the contract's trigger and it is the one that fires when the
		map CHANGES. But the replica field and the map model travel on separate
		pipes, so MapId routinely lands before a single tagged part has
		replicated -- and the parts themselves arrive over several frames. The
		tag signals cover that, and cover a map unloading, which is the case
		where a stale rail would fly the camera into deleted geometry.

		Connected for the session and never disconnected: this controller is a
		singleton that exists for as long as the client does, so there is no
		later moment at which it stops caring. The flag they set is free while
		the menu is closed.
	]]
	local pointAdded = CollectionService:GetInstanceAddedSignal(Tags.MENU_CAMERA_POINT)
	pointAdded:Connect(markRailDirty)

	local pointRemoved = CollectionService:GetInstanceRemovedSignal(Tags.MENU_CAMERA_POINT)
	pointRemoved:Connect(markRailDirty)

	MatchController.observe({ "MapId" }, markRailDirty)

	-- Subscribed before syncLoop yields, so an open that lands while it is
	-- waiting for PlayerGui is seen. Both calls are idempotent, so the two
	-- paths agreeing costs nothing.
	for _, name in MENU_SCREENS do
		UIController.onOpen(name, syncActivation)
		UIController.onClose(name, syncActivation)
	end

	-- Parks for the session. The Loader spawns every Start(), so nothing is
	-- waiting on this one to return.
	syncLoop()
end

return MenuCameraController
