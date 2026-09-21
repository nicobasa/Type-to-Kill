--!strict
--[[
	The Settings screen. One row today: DarkFlashEffect.

	THE DECISION IN THIS FILE: the click never moves the knob.

	SettingsService answers nothing. Accepted, rate-limited and rejected all
	look identical on the wire, because none of them sends a packet
	(Services/SettingsService.luau, "NOTHING IS EVER SENT BACK"). A switch that
	flipped itself on press and then waited for a reply would wait forever, and
	a write the limiter quietly swallowed would leave it reading ON over a
	profile that holds OFF -- for the rest of the session, with nothing that
	could ever correct it.

	So the click does exactly one thing: send. The knob is moved by
	DataController.observe({"Settings","DarkFlashEffect"}), which fires with the
	current value the moment it is registered and again on every change. The
	acknowledgement already exists and it is the replica, so the switch can only
	ever display a value the server actually wrote.

	The price is one round trip before the knob moves, and for a preference that
	is the right way round: a toggle that lies about what was saved is worse
	than a toggle that is sixty milliseconds late.

	THE SWITCH IS REBOUND, NOT CAPTURED

	StarterGui.ResetPlayerGuiOnSpawn is on by default and wipes PlayerGui on
	every respawn -- and in this game the player dies, watches a killcam and
	comes back to this menu between rounds. A binding taken once at join would
	be a destroyed Toggle and a destroyed CloseButton from the first death
	onwards: the row would stop responding to clicks and the panel would lose
	its only way back to MainMenu, with no error anywhere to say why. So the
	found elements live in one `bound` table that attachLoop refreshes after
	every wipe, the same shape PlayerCardController and HUDController use.

	The observer is registered ONCE, outside that loop, for the reason
	HUDController gives: DataController.observe has no unsubscribe, so a rebind
	that re-registered would stack another OnChange listener on every respawn.
	It writes the value into module state; the knob is only ever a view of it,
	and each bind pass re-applies that state to the screen it just found.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.DataController)
local Log = require(ReplicatedStorage.Shared.Log)
local Motion = require(script.Parent.Parent.UI.Motion)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("SettingsController")

local player = Players.LocalPlayer

-- The folder UIController watches, and the one this file looks inside.
local SCREENS_FOLDER = "Screens"

local SCREEN_NAME = "Settings"

-- The profile key AND the name of the authored row that writes it. One
-- constant does both jobs deliberately: a row whose name drifts from the key
-- it sets is a screen that silently edits the wrong preference.
local SETTING_KEY = "DarkFlashEffect"

-- How long a lookup waits before it says something. It is a budget for one
-- WaitForChild, not a deadline for the session: see waitForScreens for why the
-- folder is worth waiting past it and the screen inside it is not.
local SCREEN_TIMEOUT = 10

--[[
	Everything a bind pass found, replaced wholesale by the next one.

	The poses are read once per pass and kept, rather than re-derived from the
	knob when it is asked to move: after the first tween its Position is no
	longer the authored one, and mirroring THAT would walk the switch a little
	further across the track on every flip.
]]
type Bound = {
	knob: GuiObject,
	offPose: UDim2,
	onPose: UDim2,
}

--[[
	The last value the PROFILE reported, not the last thing the player pressed.
	The click reads this to decide what to ask for -- see onToggleClicked.
]]
local darkFlashEnabled = false

local bound: Bound? = nil
local knobHandle: Motion.Handle? = nil

local SettingsController = {}

--[[
	Walks an authored path and names the link that is missing, rather than the
	journey. "Settings.Root.Panel.Rows has no DarkFlashEffect" is a one-look fix
	in Studio; "the settings screen is malformed" is an evening.
]]
local function resolve(root: Instance, path: { string }): Instance?
	local current: Instance = root
	for _, name in path do
		local child = current:FindFirstChild(name)
		if child == nil then
			log.warn(`{current:GetFullName()} has no "{name}" -- the {SCREEN_NAME} screen will not be driven`)
			return nil
		end
		current = child
	end
	return current
end

--[[
	The thing that takes the click: the Toggle itself when it is a button, or
	the button inside it when it is not. A switch is just as reasonably authored
	as an ImageButton as it is a Frame wrapping one, and a settings row that
	cannot be clicked is a bug nobody reports because it looks entirely fine.
]]
local function clickTarget(instance: Instance): GuiButton?
	if instance:IsA("GuiButton") then
		return instance
	end
	local found = instance:FindFirstChildWhichIsA("GuiButton", true)
	if found ~= nil and found:IsA("GuiButton") then
		return found
	end
	return nil
end

--[[
	The authored Position is the OFF pose and ON is its mirror across the track,
	so the switch is laid out once in Studio, in the state Studio shows -- the
	same trade UIController makes by treating the authored `Enabled` as the
	starting state. A second authored position would be a second thing to keep
	in sync with the first.

	Mirrored on the knob's EDGES rather than on its Position, because Position
	means a different point at every AnchorPoint and an author who centres the
	knob at 0.5 has not made a mistake.
]]
local function mirrorAcrossTrack(knob: GuiObject): UDim2
	local position = knob.Position
	local size = knob.Size
	local anchor = knob.AnchorPoint.X

	local leftScale = position.X.Scale - anchor * size.X.Scale
	local leftOffset = position.X.Offset - anchor * size.X.Offset

	-- Left edge of the mirrored knob: as far from the right wall as the
	-- authored one sits from the left.
	local mirroredScale = 1 - leftScale - size.X.Scale
	local mirroredOffset = -leftOffset - size.X.Offset

	return UDim2.new(
		mirroredScale + anchor * size.X.Scale,
		mirroredOffset + anchor * size.X.Offset,
		position.Y.Scale,
		position.Y.Offset
	)
end

--[[
	"snappy", never "pop": Motion's pop preset overshoots, and a knob that
	overshoots inside a fixed track visibly leaves it. A switch should land
	under the finger with no personality at all.
]]
local function moveKnob(knob: GuiObject, pose: UDim2, animate: boolean)
	if knobHandle ~= nil then
		-- Cancelling rather than letting it finish means a fast double flip
		-- starts from wherever the knob actually is, instead of snapping back
		-- to the end of a tween the player already changed their mind about.
		knobHandle.cancel()
		knobHandle = nil
	end

	if not animate then
		knob.Position = pose
		return
	end

	knobHandle = Motion.tween(knob, { Position = pose }, "snappy", function()
		knobHandle = nil
	end)
end

--[[
	Shows whatever the profile last said. Safe to call with nothing bound: the
	observer fires on its own schedule and may well land while the player is
	mid-respawn, with the re-cloned screen not yet replicated.
]]
local function applyValue(animate: boolean)
	local ui = bound
	if ui == nil then
		return
	end
	moveKnob(ui.knob, if darkFlashEnabled then ui.onPose else ui.offPose, animate)
end

local function onToggleClicked()
	--[[
		`not darkFlashEnabled` is read off the OBSERVED value, never off a local
		the click just flipped. Two presses inside Config.RateLimit.SettingWrite
		therefore both ask for the same thing, so the one the limiter drops
		cannot leave the switch arguing with the profile.
	]]
	Net.setSetting.send({ key = SETTING_KEY, enabled = not darkFlashEnabled })
end

--[[
	Yields until PlayerGui holds a Screens folder, however long that takes.

	The give-up this replaces was measured, not imagined: a client boot in this
	place logs "no PlayerGui.Screens" from nine controllers at once, ten seconds
	after Start(). StarterGui is copied into PlayerGui when a character first
	SPAWNS, and in this game a player in the menu has no character at all
	(ShowcaseController's header says so, and builds a dummy avatar because of
	it). So ten seconds of empty PlayerGui is the normal join, not a
	misconfiguration -- and a controller that quits on it has disabled its
	screen for the session over a screen that turns up perfectly.

	One line at the timeout so a place that genuinely authored no Screens folder
	still says so once, then a wait that cannot miss: WaitForChild re-checks on
	entry, so looping it has no window between a timeout and the next call for
	the folder to arrive in unseen. It parks a thread the Loader already spawned
	and nothing is waiting on -- there is no boot to hold up.
]]
local function waitForScreens(playerGui: Instance): Instance
	local screens = playerGui:WaitForChild(SCREENS_FOLDER, SCREEN_TIMEOUT)
	if screens == nil then
		log.info(`no PlayerGui.{SCREENS_FOLDER} after {SCREEN_TIMEOUT}s -- waiting for the first character spawn`)
		repeat
			screens = playerGui:WaitForChild(SCREENS_FOLDER, SCREEN_TIMEOUT)
		until screens ~= nil
	end
	return screens :: Instance
end

--[[
	Finds the authored screen under a Screens folder that is still filling up.

	Recursive first, because subfolders under Screens are organisation only --
	UIController addresses a screen by name at any depth -- so a designer who
	files this one under Screens/Menus has not broken anything, and a rebind
	must not pay a ten-second timeout for that choice on every respawn.

	The bounded WaitForChild is the not-there-YET case: replication fills the
	folder over several frames, and an index is a race that passes on a fast
	machine and fails on a player's. It only sees direct children, so the
	recursive lookup is repeated after it rather than trusted to it.
]]
local function findScreen(screensFolder: Instance): Instance?
	local existing = screensFolder:FindFirstChild(SCREEN_NAME, true)
	if existing ~= nil then
		return existing
	end

	screensFolder:WaitForChild(SCREEN_NAME, SCREEN_TIMEOUT)
	return screensFolder:FindFirstChild(SCREEN_NAME, true)
end

--[[
	Wires one authored copy of the screen. False means the tree is not the one
	this file drives and retrying cannot help -- resolve() has already named the
	missing link.

	The Activated connections are deliberately not tracked: they were made on
	instances that the next wipe destroys, and Destroy takes an instance's own
	connections with it. The tween is the one thing it does not own.
]]
local function bind(screen: Instance): boolean
	local toggle = resolve(screen, { "Root", "Panel", "Rows", SETTING_KEY, "Toggle" })
	if toggle == nil then
		return false
	end

	local knobInstance = resolve(toggle, { "Knob" })
	if knobInstance == nil then
		return false
	end
	if not knobInstance:IsA("GuiObject") then
		log.warn(
			`{knobInstance:GetFullName()} is a {knobInstance.ClassName}, not a GuiObject -- the switch cannot move`
		)
		return false
	end

	-- Re-bound with the type spelled out because the table below outlives this
	-- refinement, and a refinement made out here does not follow a local into a
	-- closure.
	local knob: GuiObject = knobInstance

	bound = {
		knob = knob,
		offPose = knob.Position,
		onPose = mirrorAcrossTrack(knob),
	}

	--[[
		No animation on a fresh bind. The re-cloned screen arrives at its
		authored OFF pose regardless of what the profile holds, and a knob
		sliding across on the frame the player respawns looks like the game
		toggled the setting behind their back.
	]]
	applyValue(false)

	local button = clickTarget(toggle)
	if button ~= nil then
		button.Activated:Connect(onToggleClicked)
	else
		log.warn(`{toggle:GetFullName()} is a {toggle.ClassName} with no GuiButton inside -- the row cannot be clicked`)
	end

	local closeButton = resolve(screen, { "Root", "Panel", "CloseButton" })
	if closeButton ~= nil and closeButton:IsA("GuiButton") then
		closeButton.Activated:Connect(function()
			--[[
				Open MainMenu rather than close Settings: both are exclusive, so
				opening one closes the other -- that IS the swap (UIController's
				header). Closing ourselves first would leave a frame with
				nothing on screen. MenuController wires this same button, and a
				double wire is harmless because open() on an already-open screen
				returns without touching it.
			]]
			UIController.open("MainMenu")
		end)
	end

	return true
end

local function unbind()
	-- Cleared BEFORE the tween is cancelled, so nothing that runs in between
	-- can hand another pose to a knob on its way out.
	bound = nil

	if knobHandle ~= nil then
		knobHandle.cancel()
		knobHandle = nil
	end
end

--[[
	Binds the switch, then does it again after the next PlayerGui wipe.

	Destroying:Wait() rather than a connection, as in HUDController: there is no
	handle to forget to disconnect, and this thread has nothing else to do in
	the meantime.
]]
local function attachLoop()
	local playerGui = player:WaitForChild("PlayerGui")

	while true do
		local screensFolder = waitForScreens(playerGui)

		local screen = findScreen(screensFolder)
		if screen == nil then
			log.warn(`no Screens.{SCREEN_NAME} authored -- the {SETTING_KEY} toggle will not work`)
			return
		end

		if not bind(screen) then
			-- bind() named what is missing. The copy re-cloned on the next
			-- respawn is the same authored tree, so retrying would only repeat
			-- the same warning on a loop.
			return
		end

		screensFolder.Destroying:Wait()
		unbind()

		--[[
			Destroying fires while the folder is still parented, so an immediate
			WaitForChild("Screens") can be handed back the very instance that is
			on its way out -- and the next pass would bind to a corpse and then
			wait forever for it to be destroyed again. MenuController guards its
			own loop the same way.
		]]
		while playerGui:FindFirstChild(SCREENS_FOLDER) == screensFolder do
			playerGui.ChildRemoved:Wait()
		end
	end
end

function SettingsController.Init()
	--[[
		Nothing to register, and that is the point of the design above: settings
		have no inbound packet to miss. The one observer this file needs replays
		the current value the instant it is registered, so it belongs in Start()
		with the loop it feeds rather than here.
	]]
end

function SettingsController.Start()
	--[[
		Registered before the first bind, and exactly once for the session. The
		listener writes module state and then asks the current binding -- if any
		-- to show it, so it is correct whether it fires before the screen has
		replicated, between two respawns, or while the panel is closed.
	]]
	DataController.observe({ "Settings", SETTING_KEY }, function(value, old)
		-- A profile written before this key existed reads nil. Off is the right
		-- reading of "no preference stored": the white flash is the designed
		-- effect and the dark one replaces it (DataService's template says so),
		-- so nil must not land on the accessibility variant by accident.
		darkFlashEnabled = value == true

		--[[
			`old == nil` is observe's signal for its immediate first fire, and
			that one must not animate: the value was already whatever it is when
			the screen was authored shut, and a knob sliding across on the frame
			it first reads itself looks like the game toggled the setting.
		]]
		applyValue(old ~= nil)
	end)

	-- Parks for the session. The Loader spawns every Start(), so nothing is
	-- waiting on this one to return.
	attachLoop()
end

return SettingsController
