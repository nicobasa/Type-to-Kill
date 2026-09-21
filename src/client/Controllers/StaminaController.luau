--!strict
--[[
	Sprint input, and the bar that draws it.

	The client half of a pair. SprintService owns the sprint; this owns the
	picture of it. That split is why nothing below writes Humanoid.WalkSpeed:
	a client that could set its own speed would make Net.setSprinting a packet
	worth forging and the server's check theatre. What this sends is an INTENT
	and nothing else.

	WHY THE BAR IS PREDICTED RATHER THAN STREAMED

	Net.sprintState is a CORRECTION, not a stream (Net.luau says so at the
	packet definition): the server sends it only where its answer differs from
	the one this file would already have drawn. So the bar is simulated here,
	from the same Config.Stamina constants, in the same order of operations as
	SprintService.step -- and a correction SNAPS it rather than easing to it.
	An eased correction is a bar that is knowingly wrong for a quarter second,
	which is the one thing a corrective packet exists to prevent.

	RATES ARE DERIVED FROM DURATIONS, NEVER WRITTEN OUT

	Config.Stamina is stated in durations ("four seconds of sprint from full").
	Max/DrainDuration and Max/FullRegenDuration are spelled in exactly two
	places -- here and SprintService -- from the same constants. A rate typed
	as a literal on either side is a bar that empties at a different moment
	from the sprint it is drawing, and that divergence shows up on the first
	balance tweak rather than in review.

	RegenDelay is a HOLD, not a ramp. regenAt is pushed forward on every
	DRAINING frame rather than stamped once when sprint ends, so the bar sits
	at exactly the value it stopped at for exactly RegenDelay, moving neither
	up nor down -- otherwise a player who taps sprint repeatedly banks regen
	they never waited for. Mirrored from SprintService deliberately; the two
	curves are only identical while they are written the same way.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Binds = require(script.Parent.Parent.UI.Binds)
local Config = require(ReplicatedStorage.Shared.Config)
local Device = require(script.Parent.Parent.UI.Device)
local Log = require(ReplicatedStorage.Shared.Log)
local MatchController = require(script.Parent.MatchController)
local Net = require(ReplicatedStorage.Shared.Net)
local UIController = require(script.Parent.UIController)

local log = Log.new("StaminaController")

local player = Players.LocalPlayer

local MAX_STAMINA = Config.Stamina.Max
local DRAIN_RATE = Config.Stamina.Max / Config.Stamina.DrainDuration
local REGEN_RATE = Config.Stamina.Max / Config.Stamina.FullRegenDuration
local REGEN_DELAY = Config.Stamina.RegenDelay
-- Absolute stamina, not the fraction, for the same reason SprintService
-- converts once: every comparison below is against a stamina value, so no call
-- site can forget the multiply.
local RESUME_STAMINA = Config.Stamina.Max * Config.Stamina.ResumeThreshold
local LOW_STAMINA = Config.Stamina.Max * Config.Stamina.LowThreshold

-- MoveDirection is the DESIRED direction: a unit vector while a control is
-- held, zero otherwise. A player running into a wall still drains, because a
-- wall is not a rest. The epsilon is for a thumbstick idling inside its
-- deadzone, which reports a small non-zero magnitude indefinitely.
local MOVE_EPSILON = 0.1

local ACTION_NAME = "TypeToKillSprint"

--[[
	The HUD is NOT a child of PlayerGui. Screens are authored under
	StarterGui.Screens and arrive at PlayerGui.Screens (optionally inside
	subfolders of it, which UIController flattens only in ITS OWN name->screen
	table -- the instance tree keeps them). HUDController, MenuController,
	SettingsController and VoteController all reach the tree through that
	folder; indexing PlayerGui.HUD directly finds nothing, for ever, silently.
]]
local HUD_SCREEN = "HUD"
local SCREEN_TIMEOUT = 10
local BAR_PATH = { "Root", "StaminaPanel", "BarBackground" }
local SPRINT_BUTTON_PATH = { "Root", "MobileControls", "SprintButton" }

--[[
	A MODERATE pulse, and that ceiling is a safety limit rather than taste.
	This game already ships a full-screen flashbang; a bar strobing underneath
	one is how a photosensitive player gets hurt. Published flash-safety
	guidance puts the hazard band at 3Hz and up, so 1.2Hz sits well clear of
	it, and the swing is 0.9 -> 0.55 transparency rather than visible -> gone.
	The eye reads a breath, not a blink.
]]
local WARNING_PULSE_HZ = 1.2
local WARNING_PULSE_MIN = 0.55
local WARNING_PULSE_MAX = 0.9
-- Transparency units per second back to clear once stamina recovers. The
-- warning leaves by fading, so crossing the threshold twice in quick
-- succession does not read as a flicker.
local WARNING_FADE_RATE = 3

-- Smaller than a pixel on any bar anyone would author. Below it the Size write
-- is skipped: a property write that changes nothing still costs a trip through
-- the render pipeline, sixty times a second.
local FILL_EPSILON = 0.001

--[[
	Floor on how often this client may ASK to start sprinting.

	The release is deliberately NOT throttled -- dropping an `active = false`
	would leave the player sprinting until they pressed the key again, which is
	a limiter whose failure mode is granting the thing it guards. The grant is,
	because of one specific loop: a refusal (not in the round, stamina below
	ResumeThreshold) arrives as a correction that turns prediction back off,
	and a player still holding the key would otherwise re-ask on the very next
	frame, forever.
]]
local REQUEST_INTERVAL = 0.25

local StaminaController = {}

-- The predicted bar. Authoritative only until the next correction lands.
local stamina = MAX_STAMINA
local predictedActive = false
local regenAt = 0

-- What we believe the SERVER currently holds, which is what "send on change
-- only" has to be measured against. Not the same as predictedActive: a
-- force-cancel at zero turns prediction off while the server's own flag is
-- still the thing we are waiting to hear about.
local serverActive = false
local nextRequestAt = 0

-- Input intent, in two shapes at once: a hold on desktop and gamepad, a latch
-- on touch (design brief 52).
local keyHeld = false
local touchLatched = false

-- Resolved lazily in the loop rather than from CharacterAdded, the same trade
-- SprintService makes: the loop already visits the character every frame, so
-- "this is not the Humanoid I saw last frame" IS the spawn signal, and a
-- condition that is read costs nothing to disconnect.
local boundCharacter: Model? = nil
local boundHumanoid: Humanoid? = nil

-- Resolved in Start. Held at module scope because the rebind path has to
-- re-ask the TREE which HUD is live, rather than trust the one it was handed.
local playerGui: Instance? = nil

-- Authored elements, every one of them optional: the bar is presentation, and
-- sprint has to keep working on a client whose HUD never arrived.
local hudGui: ScreenGui? = nil
local barFill: GuiObject? = nil
local barFillHeight = UDim.new(1, 0)
local barWarning: GuiObject? = nil
local sprintButton: GuiButton? = nil
local sprintButtonRest = 0
local sprintButtonEngaged = 0

local activatedConnection: RBXScriptConnection? = nil
local destroyingConnection: RBXScriptConnection? = nil
-- Bumped on every bind. A bind that yields for a screen's frames checks it
-- before writing anything, so a slow bind cannot overwrite a newer one.
local bindGeneration = 0
local hudSeen = false
local missingWarned = false

local warningTransparency = 1
local pulseClock = 0
-- Last value actually written to each property. Sentinels no transparency or
-- scale can hold, so the first draw after a bind always writes.
local lastFillScale = -1
local lastWarningDrawn = -1
local lastButtonDrawn = -1

--[[
	Walks a path of child names, waiting a bounded time at each step.

	WaitForChild and not FindFirstChild: a ScreenGui is parented into PlayerGui
	before the last of its descendants has replicated, so a plain index is a
	race that passes on a fast machine and leaves a slow one with no bar
	(ToolbarController.bindHud makes the same point). Bounded, so a HUD that
	never had a StaminaPanel is one warning rather than a thread parked for
	the session.
]]
local function waitForDescendant(root: Instance, path: { string }): Instance?
	local current: Instance = root
	for _, name in path do
		local child = current:WaitForChild(name, SCREEN_TIMEOUT)
		if child == nil then
			return nil
		end
		current = child
	end
	return current
end

--[[
	Draws the current prediction. Kept separate from the simulation because the
	simulation must never stop and this may -- see step().
]]
local function draw(deltaTime: number)
	local fill = barFill
	if fill ~= nil then
		local scale = stamina / MAX_STAMINA
		if math.abs(scale - lastFillScale) > FILL_EPSILON then
			lastFillScale = scale
			-- X scale only. The authored height is carried through verbatim:
			-- Studio owns how the bar looks, and a UDim2.fromScale here would
			-- quietly flatten a bar authored with an offset height.
			fill.Size = UDim2.new(scale, 0, barFillHeight.Scale, barFillHeight.Offset)
		end
	end

	local warning = barWarning
	if warning ~= nil then
		if stamina < LOW_STAMINA then
			pulseClock += deltaTime
			-- Cosine, not sine, so the pulse STARTS at its dimmest. Crossing
			-- the threshold is then a fade-in; a sine would pop straight to
			-- mid-opacity on the first frame under it.
			local wave = (1 - math.cos(pulseClock * 2 * math.pi * WARNING_PULSE_HZ)) / 2
			warningTransparency = WARNING_PULSE_MAX - (WARNING_PULSE_MAX - WARNING_PULSE_MIN) * wave
		else
			pulseClock = 0
			warningTransparency = math.min(warningTransparency + WARNING_FADE_RATE * deltaTime, 1)
		end
		-- The overlay is the only thing that ever changes here. BarFill keeps
		-- its authored cyan: the warning is a second layer, not a recolour, so
		-- the bar never stops meaning "stamina".
		--
		-- Guarded for the same reason FILL_EPSILON guards the width: above the
		-- threshold this value is a settled 1, and rewriting it sixty times a
		-- second is sixty trips through the render pipeline that change
		-- nothing.
		if warningTransparency ~= lastWarningDrawn then
			lastWarningDrawn = warningTransparency
			warning.BackgroundTransparency = warningTransparency
		end
	end

	local button = sprintButton
	if button ~= nil then
		-- Two values, and it sits on one of them for minutes at a time.
		local target = if touchLatched then sprintButtonEngaged else sprintButtonRest
		if target ~= lastButtonDrawn then
			lastButtonDrawn = target
			button.BackgroundTransparency = target
		end
	end
end

--[[
	The live Humanoid, or nil, resetting the prediction when the character has
	been replaced.

	Non-yielding on purpose: this runs inside the per-frame loop, and a
	WaitForChild here would stall the bar behind a slow spawn.
]]
local function resolveHumanoid(): Humanoid?
	local character = player.Character

	if character ~= nil and character == boundCharacter and boundHumanoid ~= nil then
		return boundHumanoid
	end

	local found = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	-- IsA NARROWS where a `:: Humanoid` would only promise: FindFirstChildOfClass
	-- is typed as returning a plain Instance.
	local humanoid = if found ~= nil and found:IsA("Humanoid") then found else nil

	boundCharacter = character

	if humanoid == boundHumanoid then
		return humanoid
	end
	boundHumanoid = humanoid

	if humanoid == nil then
		-- The character went away. Drop the intent with it: a latch that
		-- survives death is a player who respawns already sprinting, having
		-- pressed nothing.
		predictedActive = false
		serverActive = false
		touchLatched = false
		return nil
	end

	--[[
		A character this controller has never seen is a fresh spawn, and
		SprintService refills on exactly the same condition. Matching it here is
		what stops the bar showing an empty tank for the round trip the server's
		first correction would take -- and on a clean spawn there is no
		correction at all, because nothing disagreed.
	]]
	stamina = MAX_STAMINA
	regenAt = 0
	predictedActive = false
	serverActive = false
	touchLatched = false

	return humanoid
end

-- Sends only where the server's flag would actually change. Every path that
-- alters prediction keeps serverActive honest, so this stays one comparison.
local function requestActive(active: boolean)
	if serverActive == active then
		return
	end
	serverActive = active
	Net.setSprinting.send({ active = active })
end

--[[
	One Heartbeat for the whole controller, and it is deliberately never
	unbound while a screen is hidden.

	"Don't leave a loop bound for something off screen" is a rule about
	animation; this is the simulation that lets the corrections be as sparse as
	they are. Stop it with the HUD closed and the prediction drifts from the
	server's for as long as the menu is up, so the bar is wrong the moment it
	comes back. What is skipped instead is the drawing, at the bottom.
]]
local function step(deltaTime: number)
	local now = os.clock()
	local humanoid = resolveHumanoid()

	if humanoid == nil or humanoid.Health <= 0 then
		-- No body to sprint with. Stamina is left where it stands because the
		-- next spawn refills it anyway, which is also what the server does.
		predictedActive = false
		touchLatched = false
		--[[
			And serverActive with them. SprintService clears its own flag on
			death and deliberately sends NO correction for it ("the client knows
			it died"), so this is the one death path where believing the server
			still holds `true` is simply wrong -- and requestActive is a single
			comparison against that belief. Left stale, a Humanoid whose Health
			came back without a new character would have its next sprint request
			swallowed by the early return, for good.
		]]
		serverActive = false
	else
		-- Phase-gated before asking rather than after being refused: outside
		-- Playing the server rejects every grant, and a client that asks anyway
		-- spends a packet per REQUEST_INTERVAL to be told so.
		local wants = (keyHeld or touchLatched) and MatchController.getPhase() == "Playing"

		if not wants then
			predictedActive = false
			requestActive(false)
			-- Letting go clears the throttle, and that is the whole reason it
			-- can be this coarse: the loop it guards is intent held DOWN while
			-- the server keeps refusing, which a release breaks. Charging a
			-- quarter second to someone tapping sprint is a limit a real player
			-- feels, for a flood no real player can produce.
			nextRequestAt = 0
		elseif not predictedActive and stamina >= RESUME_STAMINA and now >= nextRequestAt then
			-- Predicted BEFORE the reply, which is what buys a bar with no
			-- input latency. A refusal arrives as a correction and snaps it
			-- back; SprintService's own comment relies on this client re-asking
			-- once ResumeThreshold is crossed, because it never re-arms itself.
			predictedActive = true
			nextRequestAt = now + REQUEST_INTERVAL
			requestActive(true)
		end

		if predictedActive and humanoid.MoveDirection.Magnitude > MOVE_EPSILON then
			stamina = math.max(stamina - DRAIN_RATE * deltaTime, 0)
			regenAt = now + REGEN_DELAY

			if stamina <= 0 then
				-- Force-cancelled. No packet: the server initiates this one and
				-- is already sending its own correction, so a send here would
				-- only race it. The latch releases at zero (design brief 52) --
				-- a touch player has no key to feel go slack.
				predictedActive = false
				touchLatched = false
			end
		elseif stamina < MAX_STAMINA and now >= regenAt then
			-- Standing still with the key held regenerates, exactly as on the
			-- server: the player is standing, not sprinting, and a bar that
			-- froze would reward letting go of a key nobody thinks to let go of.
			stamina = math.min(stamina + REGEN_RATE * deltaTime, MAX_STAMINA)
		end
	end

	local gui = hudGui
	if gui ~= nil and not gui.Enabled then
		-- Nothing on screen to write to. Forget the last drawn width, so the
		-- frame the HUD comes back on redraws instead of trusting a cache taken
		-- before the simulation moved on without it.
		lastFillScale = -1
		return
	end

	draw(deltaTime)
end

local function onSprintAction(
	_action: string,
	state: Enum.UserInputState,
	_input: InputObject
): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		keyHeld = true
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		-- Cancel matters as much as End: it is what fires when the action is
		-- unbound or focus is lost mid-hold, and without it Shift sticks down
		-- and the player sprints until they press and release it again.
		keyHeld = false
	end

	-- Pass, not Sink. Sprint is a modifier rather than a mode, and TypeMode is
	-- the one thing here that may swallow keys wholesale (it binds digits,
	-- which this is not). Sinking Shift would take it from chat as well.
	return Enum.ContextActionResult.Pass
end

local function bindInput()
	local inputs: { Enum.KeyCode } = {}
	-- Read from Binds rather than naming keys here, so two controllers cannot
	-- claim the same key without it being visible in a single table.
	-- Read into locals first. Every field on a Bind is optional by design
	-- (Binds.luau), and a local is the one shape --!strict narrows without
	-- argument -- the same reason TypeModeController funnels its keys through
	-- a helper rather than indexing the table at the call.
	local keyboard = Binds.SPRINT.keyboard
	if keyboard ~= nil then
		table.insert(inputs, keyboard)
	end

	local gamepad = Binds.SPRINT.gamepad
	if gamepad ~= nil then
		table.insert(inputs, gamepad)
	end

	if #inputs == 0 then
		log.warn("Binds.SPRINT names no keyboard or gamepad input -- sprint is touch-only on this client")
		return
	end

	--[[
		Bound once, for the session. There is no unbind path because there is no
		teardown: a controller lives as long as the client does, and rebinding
		per spawn would be churn that buys nothing. The Cancel branch above is
		what keeps a permanent bind from becoming a stuck-key bug.

		createTouchButton is false -- the touch control is the authored
		MobileControls.SprintButton, not one ContextActionService invents at a
		position Studio never agreed to.
	]]
	ContextActionService:BindAction(ACTION_NAME, onSprintAction, false, table.unpack(inputs))
end

--[[
	Touch is the only device this has to show anything for. The group is turned
	on under the same predicate by every controller that owns a button inside
	it, so the duplicate write is idempotent rather than a fight over one
	property.
]]
local function applyDevice()
	local touch = Device.isTouch()

	if not touch then
		--[[
			The latch is released with the control that owns it. A player who
			puts the phone down and reaches for a keyboard would otherwise be
			left sprinting off a button that is no longer on screen, with
			nothing to press to stop it -- Shift only sets keyHeld. Same class
			of bug as a missed Cancel in onSprintAction, from the other end.
		]]
		touchLatched = false
	end

	local button = sprintButton
	if button == nil then
		return
	end

	button.Visible = touch

	local controls = button.Parent
	if controls ~= nil and controls:IsA("GuiObject") then
		controls.Visible = touch
	end
end

--[[
	Forgets the bound screen. Called before every bind and from the screen's
	own Destroying, so nothing here ever writes into a destroyed tree -- which
	matters precisely because those writes do NOT error, they just stop being
	visible.
]]
local function clearHud()
	if activatedConnection ~= nil then
		-- The old button is usually destroyed along with its PlayerGui, which
		-- disconnects this for us -- but "usually" is not a cleanup policy.
		activatedConnection:Disconnect()
		activatedConnection = nil
	end
	if destroyingConnection ~= nil then
		destroyingConnection:Disconnect()
		destroyingConnection = nil
	end

	hudGui = nil
	barFill = nil
	barWarning = nil
	sprintButton = nil
	-- No button on screen means no latch: see applyDevice.
	touchLatched = false

	lastFillScale = -1
	lastWarningDrawn = -1
	lastButtonDrawn = -1
end

-- Declared ahead of the two helpers below, which hand work back to it.
local bindHud: (hud: ScreenGui) -> ()

--[[
	The HUD that is actually parented under PlayerGui right now, or nil.

	NOT the instance DescendantAdded last handed us, and that distinction IS
	the bug this exists to close. On the first character spawn the engine
	copies StarterGui into PlayerGui, so a SECOND Screens folder -- carrying a
	second HUD -- lands beside the one UIController adopted at boot, and
	UIController destroys the newcomer ("discarded a duplicate Screens folder"
	in the log). DescendantAdded fires for that doomed copy and never again for
	the survivor, which was already parented before this controller started
	watching. UIController's own header names the symptom: binding the copy
	leaves a controller "bound to a destroyed tree with nothing to rebind to --
	the stamina bar stops drawing, and nothing errors".

	`ignore` is the instance whose Destroying is asking. Destroying fires while
	it is STILL parented (MenuController.attachLoop makes the same point), so a
	plain lookup here can be handed back the corpse.
]]
local function findLiveHud(ignore: Instance?): ScreenGui?
	local container = playerGui
	if container == nil then
		return nil
	end

	for _, descendant in container:GetDescendants() do
		if descendant ~= ignore and descendant.Name == HUD_SCREEN and descendant:IsA("ScreenGui") then
			return descendant
		end
	end

	return nil
end

--[[
	Takes the bar to whichever HUD is still in the tree, having just lost the
	one it held. Every exit says which happened: losing the screen used to be
	the one failure with nothing in the log at all, and that silence is what
	made this bug cost hours rather than minutes.
]]
local function rebindToLiveHud(ignore: Instance?, reason: string)
	local replacement = findLiveHud(ignore)
	if replacement ~= nil then
		log.debug(`{reason} -- rebinding to the {HUD_SCREEN} still in PlayerGui`)
		task.spawn(bindHud, replacement)
		return
	end

	local container = playerGui
	if container == nil or not container:IsDescendantOf(game) then
		-- PlayerGui is going away with the player, or Studio stopped the
		-- session. Not a failure, and a warning that cries wolf on every
		-- teardown is one nobody reads on the day it matters.
		return
	end

	-- The watcher in Start is still armed, so a HUD added later is still picked
	-- up. Said out loud anyway: until one is, there is no bar.
	log.warn(`{reason} and PlayerGui holds no other {HUD_SCREEN} -- the bar stops until one arrives`)
end

function bindHud(hud: ScreenGui)
	bindGeneration += 1
	local generation = bindGeneration

	clearHud()

	local background = waitForDescendant(hud, BAR_PATH)
	local fill = if background ~= nil then background:WaitForChild("BarFill", SCREEN_TIMEOUT) else nil
	local warning = if background ~= nil then background:WaitForChild("BarWarning", SCREEN_TIMEOUT) else nil
	local button = waitForDescendant(hud, SPRINT_BUTTON_PATH)

	if generation ~= bindGeneration then
		-- A newer HUD arrived while this one was waiting on its frames. That
		-- bind owns the state now, and everything below would replace it with
		-- elements from a screen that is already gone. Logged because this was
		-- the only exit in the file that left no trace whatsoever, and a bar
		-- that never draws is indistinguishable from one that draws wrong.
		log.debug(`{HUD_SCREEN} bind {generation} superseded by {bindGeneration} -- the newer bind owns the bar`)
		return
	end

	local container = playerGui
	if container ~= nil and not hud:IsDescendantOf(container) then
		--[[
			Destroyed while this bind was waiting on its frames -- which means
			its Destroying has ALREADY fired, so the connection below would
			never be made and nothing would ever come back for this controller.
			That is the same dead end the duplicate-HUD race reaches from the
			other side; see findLiveHud.
		]]
		rebindToLiveHud(hud, `the {HUD_SCREEN} being bound left PlayerGui mid-bind`)
		return
	end

	hudGui = hud
	destroyingConnection = hud.Destroying:Connect(function()
		if generation ~= bindGeneration then
			return
		end

		clearHud()

		--[[
			A REBIND, not merely a forget, and that is the whole fix. This fires
			just as often for a HUD that was never the live one -- the engine's
			spawn-time copy, destroyed by UIController seconds after it arrives
			-- and DescendantAdded does not replay for the survivor that was
			parented before Start ran. Clearing alone is how the bar went dead
			for the rest of the session with nothing in the log to say so.
		]]
		rebindToLiveHud(hud, `the bound {HUD_SCREEN} was destroyed`)
	end)

	if fill ~= nil and fill:IsA("GuiObject") then
		barFill = fill
		-- Captured once, from what Studio authored. The simulation only ever
		-- owns the X scale.
		barFillHeight = fill.Size.Y
	elseif not missingWarned then
		-- Once, not once per respawn: a re-clone of a HUD that never had the
		-- bar would otherwise warn every time the player dies.
		missingWarned = true
		log.warn(
			`{HUD_SCREEN}.{table.concat(BAR_PATH, ".")}.BarFill is missing -- sprint still works, the bar will not draw`
		)
	end

	if warning ~= nil and warning:IsA("GuiObject") then
		barWarning = warning
		warningTransparency = 1
		lastWarningDrawn = 1
		warning.BackgroundTransparency = 1
	end

	if button ~= nil and button:IsA("GuiButton") then
		sprintButton = button
		sprintButtonRest = button.BackgroundTransparency
		-- Derived from the authored value rather than replacing it. The latch
		-- still has to be visible: a touch player has no key held down to tell
		-- them sprint is on.
		sprintButtonEngaged = math.max(sprintButtonRest - 0.25, 0)

		activatedConnection = button.Activated:Connect(function()
			touchLatched = not touchLatched
		end)
	end

	applyDevice()
end

--[[
	Every HUD, now and after every respawn.

	Spawned rather than called: DescendantAdded must not yield and bindHud
	waits on the screen's own frames.

	Watched rather than scanned once -- but NOT because of respawns. This place
	keeps StarterGui.ResetPlayerGuiOnSpawn off, so PlayerGui is never wiped and
	the HUD adopted at boot outlives every death. What churns instead is the
	engine's spawn-time copy of StarterGui, which lands a second Screens folder
	on the first character spawn; that copy is what this signal fires for, and
	UIController destroys it moments later. So a HUD arriving here is as likely
	to be the doomed one as the real one, which is why binding it is only half
	the job and rebindToLiveHud is the other half. A write to a destroyed
	instance does not error, and a bind lost to one used to say nothing.

	DescendantAdded rather than ChildAdded because the screen is not a child of
	PlayerGui at all: it is under PlayerGui.Screens, and may be inside a
	subfolder of that which no code here can name.
]]
local function considerScreen(instance: Instance)
	if instance.Name ~= HUD_SCREEN or not instance:IsA("ScreenGui") then
		return
	end

	--[[
		Refuse anything outside the folder UIController adopted.

		At the first character spawn the engine copies StarterGui into PlayerGui
		anyway, so a SECOND, perfectly valid-looking HUD is announced through
		DescendantAdded moments before UIController destroys it. Binding to that
		one is how this bar came to be dead for a whole session while nothing
		errored and nothing warned (UIController.getScreensFolder).
	]]
	local folder = UIController.getScreensFolder()
	if folder == nil or not instance:IsDescendantOf(folder) then
		return
	end

	hudSeen = true

	local hud = instance
	task.spawn(function()
		bindHud(hud)
	end)
end

--[[
	True while this client is visibly sprinting: the predicted sprint is on
	and the body is actually moving, which is exactly when step() drains the
	bar. The prediction rather than the server's WalkSpeed, so an effect keyed
	to it starts on the frame the key goes down and not a round trip later.
	For presentation only. The server still decides the speed.
]]
function StaminaController.isSprinting(): boolean
	local humanoid = boundHumanoid
	return predictedActive
		and humanoid ~= nil
		and humanoid.Health > 0
		and humanoid.MoveDirection.Magnitude > MOVE_EPSILON
end

function StaminaController.Init()
	--[[
		Registered here, not in Start: the first correction can land while Start
		is still waiting on PlayerGui, and a packet fired at a client with no
		listener is dropped rather than queued. The bar catches up on the frame
		after it binds; the VALUE must not be the thing that was lost.
	]]
	Net.sprintState.listen(function(data)
		local value = data.stamina

		-- NaN passes every range check there is (quality-gate trap #8), and a
		-- NaN here is a bar width nothing downstream can compute plus a
		-- `stamina >= RESUME_STAMINA` that is false forever. Drop the packet:
		-- the prediction already in hand is a better answer than a poisoned one.
		if value ~= value then
			log.warn("sprintState carried a NaN stamina -- keeping the local prediction")
			return
		end

		-- SNAP. This packet exists precisely because the server disagrees with
		-- what is on screen, so easing to it would spend the whole ease drawing
		-- a value both sides already know is wrong.
		stamina = math.clamp(value, 0, MAX_STAMINA)
		predictedActive = data.active
		serverActive = data.active

		if not data.active then
			-- A refusal or a force-cancel. The latch must not re-arm a sprint
			-- the server just declined, or a touch player taps once and buys a
			-- request per REQUEST_INTERVAL for as long as they leave it on.
			touchLatched = false
		end
	end)
end

function StaminaController.Start()
	-- Before the GUI lookup, and deliberately not inside its failure path:
	-- sprint is gameplay. A client whose HUD never authored loses a bar, not a
	-- verb.
	bindInput()

	local gui = player:WaitForChild("PlayerGui")
	-- Kept at module scope as well: rebindToLiveHud has to re-ask this tree
	-- which HUD is live, because the one it was handed may be on its way out.
	playerGui = gui

	-- Watched, not scanned: see considerScreen.
	gui.DescendantAdded:Connect(considerScreen)

	-- And the one that is already there. UIController.Init parents Screens into
	-- PlayerGui during the Init phase, so by this line the HUD usually exists
	-- already -- and DescendantAdded does not replay for it.
	local existing = gui:FindFirstChild(HUD_SCREEN, true)
	if existing ~= nil then
		considerScreen(existing)
	end

	--[[
		Diagnostics only, and deliberately not a WaitForChild: saying it on a
		delay leaves the watcher above free to pick up a HUD added later in the
		session, where an inline wait would have given up on it for good.
	]]
	task.delay(SCREEN_TIMEOUT, function()
		if not hudSeen then
			log.warn(`no PlayerGui.Screens.{HUD_SCREEN} after {SCREEN_TIMEOUT}s -- sprint works, the bar will not draw`)
		end
	end)

	-- A device is what someone is USING, not what is plugged in, so the touch
	-- button can have to appear mid-session on a machine that also has a
	-- keyboard.
	Device.onChanged(applyDevice)

	RunService.Heartbeat:Connect(step)

	log.info(`ready -- {DRAIN_RATE}/s drain, {REGEN_RATE}/s regen`)
end

return StaminaController
